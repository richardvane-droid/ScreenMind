/**
 * ScreenMindMatrix.ino
 * Arduino 固件 — M10 LED 矩阵情绪表情显示
 *
 * =============================================================================
 * 【功能说明】
 * 本固件运行在 Arduino Nano（或 Uno/Mega）上，通过 USB 串口接收来自
 * Mac ScreenMind App 的 5 字节指令帧，控制 16×16 WS2812B LED 矩阵
 * 显示不同的情绪表情（大笑 / 微笑 / 中性 / 担忧 / 痛苦）。
 *
 * 【硬件需求】
 *   - Arduino Nano（ATmega328P，任何有 UART 的 Arduino 都可以）
 *   - 16×16 WS2812B LED 矩阵（共 256 颗灯）
 *   - 5V/20A 外接电源（256颗灯全亮峰值 ≈ 15A，USB 口不够）
 *   - 100–500 Ω 限流电阻（串在 Arduino D6 → LED DIN 之间）
 *   - 1000 μF 电容（并联在 LED 模组 VCC 和 GND 之间，消除上电尖峰）
 *
 * 【接线方式】
 *   Arduino D6  →（100Ω电阻）→ WS2812B DIN（数据输入）
 *   外接5V 电源+ → WS2812B VCC
 *   外接5V 电源- → WS2812B GND
 *   外接5V 电源- → Arduino GND（共地！不共地会导致通信失败）
 *
 * 【通信协议（5字节帧）】
 *   Byte 0: 0xAA  帧头（Start of Frame）
 *   Byte 1: CMD   指令类型（0x01=换脸，0x02=亮度，0x03=全灭，0x04=PING）
 *   Byte 2: DATA1 参数1（换脸时=表情ID 0-4，亮度时=0-255）
 *   Byte 3: DATA2 参数2（当前版本固定 0x00，预留扩展用）
 *   Byte 4: 0x55  帧尾（End of Frame）
 *
 * 【依赖库】
 *   FastLED v3.x（Arduino Library Manager 搜索 "FastLED" 安装）
 *
 * 【安装方法】
 *   1. 在 Arduino IDE 中安装 FastLED 库
 *   2. 选择开发板：Arduino Nano / Uno
 *   3. 选择端口：/dev/cu.usbserial-* 对应的串口
 *   4. 上传固件
 *   5. 打开 ScreenMind App，菜单里确认"LED 矩阵：已连接"
 * =============================================================================
 */

#include <FastLED.h>

// ─── 硬件配置 ──────────────────────────────────────────────────────────────────

// WS2812B 数据线连接的 Arduino 数字引脚
// 如果你的接线不同，在这里修改
#define LED_PIN     6

// 矩阵总像素数（16 × 16 = 256）
#define NUM_LEDS    256

// 矩阵尺寸
#define MATRIX_W    16
#define MATRIX_H    16

// WS2812B 色彩顺序（大多数国产模组是 GRB，少数是 RGB）
// 如果颜色显示不对，把 GRB 改成 RGB 试试
#define COLOR_ORDER GRB

// LED 类型（WS2812B 对应这个宏）
#define LED_TYPE    WS2812B

// ─── 通信协议常量 ───────────────────────────────────────────────────────────────

#define SOF         0xAA   // Start of Frame 帧头
#define EOF_BYTE    0x55   // End of Frame 帧尾（避免和 EOF 宏名冲突）
#define CMD_FACE    0x01   // 切换表情指令
#define CMD_BRIGHT  0x02   // 设置亮度指令
#define CMD_CLEAR   0x03   // 全灭指令
#define CMD_PING    0x04   // 心跳探测指令
#define PING_REPLY  0xBB   // PING 回复字节

// 串口波特率（必须与 Mac 端 LEDMatrixController.swift 一致）
#define BAUD_RATE   115200

// ─── 全局变量 ──────────────────────────────────────────────────────────────────

// FastLED 像素数组：每个元素是一个 CRGB 结构体（r, g, b 各 1 字节）
CRGB leds[NUM_LEDS];

// 当前显示的表情 ID（0–4，-1 表示未设置）
int currentFaceID = -1;

// 当前全局亮度（0–255，默认 60，适合室内环境）
uint8_t brightness = 60;

// 串口接收缓冲区（存储一帧 5 字节）
uint8_t rxBuf[5];
int     rxPos = 0;    // 当前写入位置
bool    inFrame = 0;  // 是否正在接收一帧（等待帧头）

// ─── 颜色常量 ──────────────────────────────────────────────────────────────────

// 绿色系（大笑/微笑脸，焦虑分低）
const CRGB COL_GREEN      = CRGB(0, 255, 80);
const CRGB COL_GREEN_DARK = CRGB(0, 180, 50);

// 黄色（中性脸，焦虑分中等）
const CRGB COL_YELLOW     = CRGB(255, 220, 0);
const CRGB COL_YELLOW_DARK= CRGB(200, 160, 0);

// 橙色（担忧脸，焦虑分偏高）
const CRGB COL_ORANGE     = CRGB(255, 130, 0);
const CRGB COL_ORANGE_DARK= CRGB(200, 90, 0);

// 红色（痛苦脸，焦虑分极高）
const CRGB COL_RED        = CRGB(255, 40, 40);
const CRGB COL_RED_DARK   = CRGB(200, 0, 0);

// 近白（眼白/背景色，避免纯白刺眼）
const CRGB COL_WHITE      = CRGB(180, 180, 180);

// 熄灭
const CRGB COL_OFF        = CRGB(0, 0, 0);

// ─── 表情图案定义 ──────────────────────────────────────────────────────────────
//
// 每个表情用一个 16 字节长的数组表示（每字节代表一列，每 bit 代表该列中对应行的"脸色"）。
// 为了方便，我们用更直观的方式：直接在 drawFace 函数里用 setPixel 逐像素绘制。
//
// 矩阵寻址方式（蛇形/S型接线）：
//   偶数行（0、2、4…）：从左 → 右（列 0 → 列 15）
//   奇数行（1、3、5…）：从右 → 左（列 15 → 列 0）
// 即：第 n 行的像素在 leds[] 数组中的索引 = n * 16 + (偶数行 ? col : 15-col)

// ─── 坐标转索引 ─────────────────────────────────────────────────────────────────

/**
 * 把 (行, 列) 坐标转换为 leds[] 数组下标。
 * 支持蛇形（S型）布线方式：奇数行反向。
 *
 * @param row 行号（0=顶部，15=底部）
 * @param col 列号（0=左，15=右）
 * @return leds[] 数组下标
 */
int xyToIndex(int row, int col) {
  if (row < 0 || row >= MATRIX_H || col < 0 || col >= MATRIX_W) return 0;
  // 蛇形：奇数行从右往左
  if (row % 2 == 1) {
    return row * MATRIX_W + (MATRIX_W - 1 - col);
  } else {
    return row * MATRIX_W + col;
  }
}

/**
 * 在 (row, col) 位置设置一个像素颜色。
 * 内部调用 xyToIndex 计算 leds[] 下标。
 */
void setPixel(int row, int col, CRGB color) {
  int idx = xyToIndex(row, col);
  leds[idx] = color;
}

// ─── 辅助函数：填充矩形区域 ──────────────────────────────────────────────────

/**
 * 用指定颜色填充矩形区域（包含边界）。
 * 用于绘制脸部背景和大色块。
 *
 * @param r1, c1 左上角 (行, 列)
 * @param r2, c2 右下角 (行, 列)
 * @param color  填充颜色
 */
void fillRect(int r1, int c1, int r2, int c2, CRGB color) {
  for (int r = r1; r <= r2; r++) {
    for (int c = c1; c <= c2; c++) {
      setPixel(r, c, color);
    }
  }
}

// ─── 表情绘制函数 ──────────────────────────────────────────────────────────────

/**
 * 清除所有像素（全部熄灭）。
 */
void clearAll() {
  fill_solid(leds, NUM_LEDS, CRGB::Black);
}

/**
 * 绘制脸部基础结构（圆脸轮廓 + 白色填充）。
 * 所有表情共用同一个脸型，在此基础上绘制不同的眼睛和嘴巴。
 *
 * @param outline 轮廓颜色（根据焦虑等级选不同颜色）
 */
void drawFaceBase(CRGB outline) {
  // 外层轮廓（近似圆形，手工逐角调整）
  // 顶部弧（行 0）：列 2–13
  for (int c = 2; c <= 13; c++) setPixel(0, c, outline);
  // 上肩（行 1）：列 1–14
  for (int c = 1; c <= 14; c++) setPixel(1, c, outline);
  // 两侧（行 2–12）：列 0 和 15
  for (int r = 2; r <= 12; r++) {
    setPixel(r, 0, outline);
    setPixel(r, 15, outline);
  }
  // 下肩（行 13）：列 1–14
  for (int c = 1; c <= 14; c++) setPixel(13, c, outline);
  // 底部弧（行 14）：列 2–13
  for (int c = 2; c <= 13; c++) setPixel(14, c, outline);

  // 内部白色填充（行 1–13，列 1–14，轮廓内的部分）
  for (int r = 2; r <= 12; r++) {
    for (int c = 1; c <= 14; c++) {
      setPixel(r, c, COL_WHITE);
    }
  }
  // 补齐顶部和底部的白色区域
  for (int c = 2; c <= 13; c++) {
    setPixel(1, c, COL_WHITE);
    setPixel(13, c, COL_WHITE);
  }
}

/**
 * 绘制眼睛（两个 2×2 的深色方块）。
 *
 * @param eyeColor 眼睛颜色（一般比轮廓深一点）
 */
void drawEyes(CRGB eyeColor) {
  // 左眼：行 3–4，列 3–4
  fillRect(3, 3, 4, 4, eyeColor);
  // 右眼：行 3–4，列 10–11
  fillRect(3, 10, 4, 11, eyeColor);
}

// ─── 表情 0：大笑脸（绿色，焦虑分 < 0.40）──────────────────────────────────

void drawBigSmile() {
  clearAll();
  drawFaceBase(COL_GREEN);
  drawEyes(COL_GREEN_DARK);

  // 嘴角：左右两端上扬的弧线（大笑特征）
  // 左嘴角（行6，列2）
  setPixel(6, 2, COL_GREEN_DARK);
  // 右嘴角（行6，列13）
  setPixel(6, 13, COL_GREEN_DARK);
  // 嘴巴上弧（行7，列3–12）
  for (int c = 3; c <= 5; c++) setPixel(7, c, COL_GREEN_DARK);
  for (int c = 10; c <= 12; c++) setPixel(7, c, COL_GREEN_DARK);
  // 嘴巴中间（行8，牙齿区域，保持白色，不画）
  // 嘴巴下弧（行9，列4–11）
  for (int c = 4; c <= 11; c++) setPixel(9, c, COL_GREEN_DARK);
}

// ─── 表情 1：微笑脸（浅绿，焦虑分 0.40–0.60）──────────────────────────────

void drawSmile() {
  clearAll();
  drawFaceBase(COL_GREEN);
  // 眼睛小一点（1×1）
  setPixel(3, 4, COL_GREEN_DARK);
  setPixel(3, 11, COL_GREEN_DARK);
  // 嘴巴：温和弧线
  for (int c = 4; c <= 11; c++) setPixel(8, c, COL_GREEN_DARK);
  setPixel(7, 3, COL_GREEN_DARK);
  setPixel(7, 12, COL_GREEN_DARK);
}

// ─── 表情 2：中性脸（黄色，焦虑分 0.60–0.70）──────────────────────────────

void drawNeutral() {
  clearAll();
  drawFaceBase(COL_YELLOW);
  // 眼睛
  fillRect(3, 3, 4, 4, COL_YELLOW_DARK);
  fillRect(3, 10, 4, 11, COL_YELLOW_DARK);
  // 嘴巴：直线（既不上扬也不下弯）
  for (int c = 4; c <= 11; c++) setPixel(8, c, COL_YELLOW_DARK);
}

// ─── 表情 3：担忧脸（橙色，焦虑分 0.70–0.85）──────────────────────────────

void drawWorried() {
  clearAll();
  drawFaceBase(COL_ORANGE);
  // 眉毛（皱眉：内侧高外侧低）
  setPixel(2, 3, COL_ORANGE_DARK);
  setPixel(2, 5, COL_ORANGE_DARK);
  setPixel(3, 2, COL_ORANGE_DARK);
  setPixel(3, 4, COL_ORANGE_DARK);
  setPixel(2, 10, COL_ORANGE_DARK);
  setPixel(2, 12, COL_ORANGE_DARK);
  setPixel(3, 11, COL_ORANGE_DARK);
  setPixel(3, 13, COL_ORANGE_DARK);
  // 眼睛
  fillRect(5, 3, 6, 4, COL_ORANGE_DARK);
  fillRect(5, 10, 6, 11, COL_ORANGE_DARK);
  // 嘴巴：两角向下弯
  for (int c = 4; c <= 11; c++) setPixel(8, c, COL_ORANGE_DARK);
  setPixel(9, 3, COL_ORANGE_DARK);
  setPixel(9, 12, COL_ORANGE_DARK);
}

// ─── 表情 4：痛苦脸（红色，焦虑分 ≥ 0.85）──────────────────────────────────

void drawDistressed() {
  clearAll();
  drawFaceBase(COL_RED);
  // 眉毛（深度皱眉：交叉 X 形眉毛）
  setPixel(2, 3, COL_RED_DARK); setPixel(2, 5, COL_RED_DARK);
  setPixel(3, 2, COL_RED_DARK); setPixel(3, 4, COL_RED_DARK);
  setPixel(2, 10, COL_RED_DARK); setPixel(2, 12, COL_RED_DARK);
  setPixel(3, 11, COL_RED_DARK); setPixel(3, 13, COL_RED_DARK);
  // 眼睛：X 形（痛苦/昏厥）
  setPixel(5, 3, COL_RED_DARK); setPixel(5, 5, COL_RED_DARK);
  setPixel(6, 4, COL_RED_DARK);
  setPixel(7, 3, COL_RED_DARK); setPixel(7, 5, COL_RED_DARK);
  setPixel(5, 10, COL_RED_DARK); setPixel(5, 12, COL_RED_DARK);
  setPixel(6, 11, COL_RED_DARK);
  setPixel(7, 10, COL_RED_DARK); setPixel(7, 12, COL_RED_DARK);
  // 嘴巴：大幅下弯（哭脸）
  setPixel(9, 3, COL_RED_DARK);
  setPixel(9, 12, COL_RED_DARK);
  for (int c = 4; c <= 11; c++) setPixel(10, c, COL_RED_DARK);
}

// ─── 根据 ID 绘制对应表情 ─────────────────────────────────────────────────────

/**
 * 根据表情 ID（0–4）绘制对应表情。
 * 绘制完成后调用 FastLED.show() 刷新到硬件。
 *
 * @param faceID 表情 ID（0=大笑，1=微笑，2=中性，3=担忧，4=痛苦）
 */
void showFace(int faceID) {
  switch (faceID) {
    case 0: drawBigSmile();   break;
    case 1: drawSmile();      break;
    case 2: drawNeutral();    break;
    case 3: drawWorried();    break;
    case 4: drawDistressed(); break;
    default: clearAll();      break;
  }
  FastLED.show();
}

// ─── Arduino 初始化 ─────────────────────────────────────────────────────────────

void setup() {
  // 初始化串口（波特率 115200，与 Mac 端一致）
  Serial.begin(BAUD_RATE);

  // 初始化 FastLED
  // LEDS.addLeds<类型, 引脚, 色彩顺序> 是 FastLED 的模板函数
  FastLED.addLeds<LED_TYPE, LED_PIN, COLOR_ORDER>(leds, NUM_LEDS);

  // 设置初始亮度（全局亮度，相当于 gamma 校正前的最大值）
  FastLED.setBrightness(brightness);

  // 上电时先全灭（避免残留图案）
  clearAll();
  FastLED.show();

  // 延迟 500ms 让 FastLED 和 WS2812B 都稳定下来
  delay(500);

  // 开机动画：从表情 0 到 4 各亮 300ms（类似自检）
  for (int i = 0; i <= 4; i++) {
    showFace(i);
    delay(300);
  }

  // 开机结束：显示微笑脸等待 Mac 连接
  showFace(1);
  currentFaceID = 1;

  Serial.println("ScreenMindMatrix ready");  // 调试用，Mac 端不解析这行
}

// ─── 主循环：串口帧解析 ──────────────────────────────────────────────────────────

/**
 * Arduino 主循环。
 * 每次循环从串口读取所有可用字节，尝试解析 5 字节指令帧。
 *
 * 解析状态机：
 *   等待帧头（0xAA）→ 收集 4 字节（CMD + DATA1 + DATA2 + 帧尾）→
 *   验证帧尾（0x55）→ 执行指令 → 回到等待帧头
 */
void loop() {
  // 读取所有可用字节（Serial.available() 返回缓冲区中未读字节数）
  while (Serial.available() > 0) {
    uint8_t byte = Serial.read();

    if (!inFrame) {
      // 等待帧头
      if (byte == SOF) {
        inFrame = true;
        rxPos = 0;
        rxBuf[rxPos++] = byte;  // 把帧头存进缓冲区（rxBuf[0] = 0xAA）
      }
      // 收到的不是帧头，丢弃（防止串口噪声）
    } else {
      // 正在接收帧的第 2–5 字节（rxBuf[1]–rxBuf[4]）
      rxBuf[rxPos++] = byte;

      if (rxPos == 5) {
        // 已收到 5 字节，验证帧尾
        inFrame = false;
        rxPos = 0;

        if (rxBuf[4] == EOF_BYTE) {
          // 帧完整，解析并执行指令
          processCommand(rxBuf[1], rxBuf[2], rxBuf[3]);
        }
        // 帧尾错误：丢弃这帧（可能发生了字节丢失，等待下一帧）
      }
    }
  }
}

// ─── 指令执行 ──────────────────────────────────────────────────────────────────

/**
 * 根据 CMD 字节执行对应操作。
 *
 * @param cmd   指令类型（0x01–0x04）
 * @param data1 参数 1
 * @param data2 参数 2（暂时未用）
 */
void processCommand(uint8_t cmd, uint8_t data1, uint8_t data2) {
  switch (cmd) {

    case CMD_FACE:
      // 切换表情：DATA1 = 表情 ID（0–4）
      if (data1 <= 4 && data1 != currentFaceID) {
        currentFaceID = data1;
        showFace(currentFaceID);
      }
      break;

    case CMD_BRIGHT:
      // 设置亮度：DATA1 = 0–255
      brightness = data1;
      FastLED.setBrightness(brightness);
      FastLED.show();  // 亮度变化需要立即 show 才生效
      break;

    case CMD_CLEAR:
      // 全灭：关掉所有灯
      currentFaceID = -1;
      clearAll();
      FastLED.show();
      break;

    case CMD_PING:
      // 心跳探测：回复 0xBB 告诉 Mac 端"我还在"
      Serial.write(0xBB);
      break;

    default:
      // 未知指令，忽略（防止固件在未知指令下崩溃）
      break;
  }
}
