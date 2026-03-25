// LEDMatrixController.swift
// ScreenMindMac — M10 LED 矩阵硬件控制器
//
// 架构说明
// ─────────────────────────────────────────────────────────────────────────────
// 本文件通过 POSIX 串口接口（纯 Darwin C 调用，无第三方依赖）
// 与 Arduino Nano 通信，控制连接在 Arduino 上的 16×16 WS2812B LED 矩阵。
//
// 通信协议（5 字节指令帧）：
//   Byte 0: 0xAA  —— 帧头（Start of Frame，固定魔数，Arduino 用于同步）
//   Byte 1: CMD   —— 指令类型（见 LEDCommand 枚举）
//   Byte 2: DATA1 —— 参数 1（CMD_FACE 时为表情 ID 0–4，CMD_BRIGHTNESS 时为亮度 0–255）
//   Byte 3: DATA2 —— 参数 2（暂时保留，固定为 0x00）
//   Byte 4: 0x55  —— 帧尾（End of Frame，固定魔数）
//
// 指令类型（CMD 字节）：
//   0x01  CMD_FACE        → 切换表情（DATA1 = 表情 ID，0–4）
//   0x02  CMD_BRIGHTNESS  → 设置全局亮度（DATA1 = 0–255）
//   0x03  CMD_CLEAR       → 全部熄灭（DATA1 = 0x00）
//   0x04  CMD_PING        → 心跳检测（Arduino 回复 0xBB）
//
// 硬件要求：
//   - Arduino Nano（或 Uno/Mega，任何有 UART 的板子）
//   - 16×16 WS2812B RGB LED 矩阵（256 颗灯，5V 电源，峰值电流 ≈ 15A，建议外接电源）
//   - USB-串口适配器（通常内置，设备名 /dev/cu.usbserial-XXXXXXXX 或 /dev/cu.usbmodem*）
//   - Arduino 固件：见 Arduino/ScreenMindMatrix.ino
//
// 电气连接建议：
//   Arduino 5V → WS2812B VCC（建议外接 5V/20A 电源，USB 输出电流不够）
//   Arduino GND → WS2812B GND（共地！）
//   Arduino D6  → WS2812B DIN（数据线，可在 Arduino 代码里改引脚）
//   100–500 Ω 电阻串接在 D6 → DIN 之间（保护数据线）
//   1000 μF 电容并联在 WS2812B 电源入口（防止上电瞬间电流冲击损坏第一颗灯）
//
// 为什么用 POSIX 而不是第三方库？
//   - macOS 可以直接用 open()/read()/write()/close() 访问串口设备
//   - termios 结构体（Darwin POSIX 标准）设置波特率 / 数据位 / 校验等
//   - 零依赖，不需要添加任何 SPM 包
// ─────────────────────────────────────────────────────────────────────────────

import Foundation

// Darwin 包含 POSIX 串口相关头文件（termios, fcntl, unistd）
// 这些函数在 Swift 里直接可用（Swift 自动桥接 C 标准库）
import Darwin

// MARK: - LED 指令类型

/// 发送给 Arduino 的指令类型枚举。
/// 每个 case 对应一个 CMD 字节值。
public enum LEDCommand: UInt8 {
    /// 切换显示的表情图案（DATA1 = FacePattern.id，0–4）
    case face       = 0x01
    /// 设置整个矩阵的全局亮度（DATA1 = 0–255，255 最亮，0 熄灭）
    case brightness = 0x02
    /// 全部熄灭（休眠 / App 退出时发送）
    case clear      = 0x03
    /// 心跳探测（Arduino 在收到 PING 后回复 0xBB，用于检测连接状态）
    case ping       = 0x04
}

// MARK: - 连接状态

/// LED 矩阵的连接状态，供 UI（菜单 / StatusBar 图标）显示。
public enum LEDConnectionState: String {
    case disconnected = "未连接"    // 没有找到 /dev/cu.usbserial-* 设备
    case connecting   = "连接中"    // 已找到设备，正在打开串口
    case connected    = "已连接"    // 串口已打开，PING 已确认
    case error        = "连接错误"  // 打开串口失败或 PING 超时
}

// MARK: - LEDMatrixController

/// 控制 16×16 WS2812B LED 矩阵的串口驱动。
///
/// 生命周期：
///   1. StatusBarController.init() 里创建实例
///   2. 调用 connect() —— 自动扫描并连接 Arduino 串口
///   3. 调用 showFace(for:) —— 根据焦虑分数切换表情
///   4. App 退出时调用 disconnect()
///
/// 线程安全：
///   所有串口 I/O 都在 serialQueue（串行队列）上执行，
///   不阻塞主线程，不需要 @MainActor。
///   onStateChanged 回调会切换到主线程执行（UI 安全）。
@MainActor
public final class LEDMatrixController {

    // MARK: - 属性

    /// 当前连接状态（UI 可绑定）
    public private(set) var connectionState: LEDConnectionState = .disconnected {
        didSet {
            onStateChanged?(connectionState)
        }
    }

    /// 当前显示的表情 ID（0–4）
    public private(set) var currentFaceID: Int = -1

    /// 状态变化回调（StatusBarController 用于更新菜单项标题）
    public var onStateChanged: ((LEDConnectionState) -> Void)?

    /// 当前打开的串口文件描述符（-1 表示未连接）
    /// POSIX 的 open() 返回 Int32 文件描述符，-1 表示失败
    private var fd: Int32 = -1

    /// 串口 I/O 专用串行队列（所有读写都在这里执行，避免主线程阻塞）
    private let serialQueue = DispatchQueue(label: "com.screenmind.ledmatrix.serial", qos: .utility)

    /// 心跳定时器（每 30 秒发送一次 PING，检测 Arduino 是否还在线）
    private var pingTimer: Timer?

    /// 当前连接的设备路径（如 /dev/cu.usbserial-1420）
    private var connectedDevicePath: String?

    // MARK: - 协议常量

    private let SOF: UInt8 = 0xAA  // Start of Frame（帧头）
    private let EOF: UInt8 = 0x55  // End of Frame（帧尾，注意不要和 Swift EOF 混淆）

    // MARK: - 初始化

    public init() {}

    // MARK: - 连接管理

    /// 自动扫描 /dev/cu.usbserial-* 和 /dev/cu.usbmodem* 设备，
    /// 找到第一个可打开的设备并建立串口连接。
    ///
    /// 调用时机：StatusBarController.startMonitoring() 时调用。
    /// 不会阻塞主线程（串口 I/O 在 serialQueue 上）。
    public func connect() {
        connectionState = .connecting
        serialQueue.async { [weak self] in
            self?.attemptConnection()
        }
    }

    /// 关闭串口连接，停止心跳定时器，发送 CLEAR 指令（熄灭所有灯）。
    public func disconnect() {
        pingTimer?.invalidate()
        pingTimer = nil
        // 先把灯全关了，再关串口（避免 Arduino 端残留图案）
        sendCommand(.clear, data1: 0x00)
        serialQueue.async { [weak self] in
            guard let self, self.fd >= 0 else { return }
            close(self.fd)  // POSIX close()
            self.fd = -1
        }
        connectionState = .disconnected
    }

    // MARK: - 表情控制（对外接口）

    /// 根据焦虑分数切换 LED 矩阵显示的表情。
    /// 这是 StatusBarController 最常用的接口。
    ///
    /// - Parameter anxietyScore: 焦虑分数 0.0–1.0
    public func showFace(for anxietyScore: Double) {
        // 先通过 FacePatterns 查找对应图案
        let pattern = FacePatterns.pattern(for: anxietyScore)

        // 同一个 ID 不重复发送（避免 LED 矩阵频繁刷新产生闪烁）
        guard pattern.id != currentFaceID else { return }
        currentFaceID = pattern.id

        // 发送 CMD_FACE 指令（DATA1 = pattern.id）
        sendCommand(.face, data1: UInt8(pattern.id))
    }

    /// 手动显示指定 ID 的表情（供调试用）
    public func showFace(id: Int) {
        let clamped = max(0, min(4, id))  // 限制在 0–4
        guard clamped != currentFaceID else { return }
        currentFaceID = clamped
        sendCommand(.face, data1: UInt8(clamped))
    }

    /// 设置全局亮度（0–255，255 最亮，室内建议 60–120）
    public func setBrightness(_ value: UInt8) {
        sendCommand(.brightness, data1: value)
    }

    /// 熄灭所有灯（监控暂停时调用）
    public func clear() {
        currentFaceID = -1
        sendCommand(.clear, data1: 0x00)
    }

    // MARK: - 私有：连接实现

    /// 扫描系统串口设备，找到 Arduino 并打开连接。
    /// 在 serialQueue 上执行，不得调用 @MainActor 方法。
    private func attemptConnection() {
        // 扫描候选设备路径（Arduino Nano 的 USB 串口驱动名称因系统/芯片不同）
        let candidatePaths = findArduinoPorts()

        guard !candidatePaths.isEmpty else {
            print("[LEDMatrix] 未找到 Arduino 设备（/dev/cu.usbserial-* 或 /dev/cu.usbmodem*）")
            DispatchQueue.main.async { self.connectionState = .error }
            return
        }

        for path in candidatePaths {
            print("[LEDMatrix] 尝试连接: \(path)")
            if tryOpen(path: path) {
                // 打开成功，发送 PING 确认 Arduino 在线
                connectedDevicePath = path
                DispatchQueue.main.async {
                    self.connectionState = .connected
                    self.startPingTimer()
                }
                print("[LEDMatrix] ✅ 已连接到 \(path)，波特率 115200")
                return
            }
        }

        print("[LEDMatrix] ❌ 所有候选设备均无法打开")
        DispatchQueue.main.async { self.connectionState = .error }
    }

    /// 扫描 /dev 目录，返回所有匹配 Arduino 串口命名规律的设备路径。
    private func findArduinoPorts() -> [String] {
        // FileManager 列出 /dev 目录下的所有文件
        let devContents = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []

        // 筛选 Arduino 常见串口设备名：
        //   cu.usbserial-*  → CH340/CP2102 USB 串口芯片（最常见的 Arduino Nano 克隆）
        //   cu.usbmodem*    → ATmega32U4 内建 USB（Arduino Micro/Leonardo）
        let matched = devContents.filter {
            $0.hasPrefix("cu.usbserial-") || $0.hasPrefix("cu.usbmodem")
        }.map { "/dev/\($0)" }

        // 按名称排序，保证每次扫描顺序一致（避免多个设备时随机选）
        return matched.sorted()
    }

    /// 打开指定路径的串口，配置 115200-8N1（8位数据，无校验，1位停止位）。
    /// 返回 true 表示成功打开。
    private func tryOpen(path: String) -> Bool {
        // O_RDWR:   可读可写（我们需要发送命令 + 接收 PING 回复）
        // O_NOCTTY: 不把这个串口作为进程的控制终端（防止串口信号干扰 App）
        // O_NDELAY: 非阻塞打开（open() 立即返回，不等待 DCD 信号）
        let openFd = open(path, O_RDWR | O_NOCTTY | O_NDELAY)
        guard openFd >= 0 else {
            print("[LEDMatrix] 无法打开 \(path): errno=\(errno)")
            return false
        }

        // 配置串口参数（termios 结构体）
        // termios 是 POSIX 串口配置的标准 C 结构体
        var options = termios()
        tcgetattr(openFd, &options)  // 读取当前配置（作为基础进行修改）

        // 设置波特率为 115200（发送 + 接收都设置）
        // cfsetispeed / cfsetospeed 是 POSIX 标准函数
        cfsetispeed(&options, speed_t(B115200))
        cfsetospeed(&options, speed_t(B115200))

        // c_cflag：控制标志（数据位、停止位、校验位等）
        options.c_cflag &= ~UInt(PARENB)   // 禁用奇偶校验
        options.c_cflag &= ~UInt(CSTOPB)   // 1 位停止位（不设置 CSTOPB = 1 位）
        options.c_cflag &= ~UInt(CSIZE)    // 清除数据位设置
        options.c_cflag |=  UInt(CS8)      // 8 位数据位
        options.c_cflag |=  UInt(CLOCAL)   // 忽略调制解调器控制线
        options.c_cflag |=  UInt(CREAD)    // 允许接收数据

        // c_iflag：输入标志（禁用软件流控制，原始模式）
        options.c_iflag &= ~UInt(IXON | IXOFF | IXANY)  // 禁用 XON/XOFF 软件流控

        // c_oflag：输出标志（原始输出，不做任何处理）
        options.c_oflag &= ~UInt(OPOST)

        // c_lflag：本地标志（原始模式：禁用回显、禁用信号处理）
        options.c_lflag &= ~UInt(ICANON | ECHO | ECHOE | ISIG)

        // 超时设置：VMIN=0, VTIME=10 表示"非阻塞读，等待最多 1 秒"
        // （VTIME 单位是 1/10 秒，10 = 1 秒）
        options.c_cc.16 = 0   // VMIN（最少读取字节数）注：Darwin 里用元组下标
        options.c_cc.17 = 10  // VTIME

        // 应用新配置（TCSANOW 表示立即生效，不等待缓冲区清空）
        tcsetattr(openFd, TCSANOW, &options)

        // 等待 Arduino 复位完成（Arduino 在串口连接时会自动复位，需要等 ≈2 秒）
        Thread.sleep(forTimeInterval: 2.0)

        fd = openFd
        return true
    }

    // MARK: - 私有：心跳定时器

    /// 启动心跳定时器（每 30 秒发送一次 PING）。
    /// 在主线程上调度（Timer 需要在 RunLoop 线程上）。
    private func startPingTimer() {
        pingTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.serialQueue.async {
                self?.sendPingAndCheck()
            }
        }
    }

    /// 发送 PING，读取回应，如果超时或回应不对则标记为断开。
    private func sendPingAndCheck() {
        guard fd >= 0 else { return }
        let frame: [UInt8] = [SOF, LEDCommand.ping.rawValue, 0x00, 0x00, EOF]
        writeFrame(frame)

        // 读取 Arduino 回复（预期是 0xBB）
        var reply: UInt8 = 0
        let bytesRead = read(fd, &reply, 1)
        if bytesRead < 1 || reply != 0xBB {
            print("[LEDMatrix] PING 超时或回应错误（收到 0x\(String(reply, radix: 16))），标记断开")
            DispatchQueue.main.async {
                self.connectionState = .error
                self.fd = -1
            }
        } else {
            print("[LEDMatrix] ♥ PING OK，设备在线: \(self.connectedDevicePath ?? "?")")
        }
    }

    // MARK: - 私有：指令发送

    /// 构造并发送一个 5 字节指令帧。
    /// - Parameters:
    ///   - command: 指令类型
    ///   - data1:   参数 1（含义由 command 决定）
    public func sendCommand(_ command: LEDCommand, data1: UInt8) {
        guard fd >= 0 else {
            // 串口未连接时忽略（不 crash，不打扰用户）
            return
        }
        let frame: [UInt8] = [SOF, command.rawValue, data1, 0x00, EOF]
        serialQueue.async { [weak self] in
            self?.writeFrame(frame)
        }
    }

    /// 把字节数组写入串口（POSIX write 调用）。
    /// 必须在 serialQueue 上调用。
    private func writeFrame(_ frame: [UInt8]) {
        guard fd >= 0 else { return }
        // 把 [UInt8] 转成 C 指针再写入
        // withUnsafeBytes 是 Swift 安全访问原始内存的方式
        frame.withUnsafeBytes { ptr in
            let written = write(fd, ptr.baseAddress!, frame.count)
            if written < 0 {
                print("[LEDMatrix] 串口写入失败: errno=\(errno)")
            }
        }
    }
}
