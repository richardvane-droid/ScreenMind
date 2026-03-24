#!/bin/bash

# ScreenMind 开发环境一键配置脚本
# 在 Mac 上运行：bash scripts/setup.sh

set -e

echo "🧠 ScreenMind 环境配置"
echo "========================"

# 检查 macOS 版本
MACOS_VERSION=$(sw_vers -productVersion)
echo "✓ macOS 版本：$MACOS_VERSION"

# 检查 Xcode Command Line Tools
if ! xcode-select -p &>/dev/null; then
    echo "⚙️  安装 Xcode Command Line Tools..."
    xcode-select --install
    echo "请完成安装后重新运行此脚本"
    exit 1
fi
echo "✓ Xcode Command Line Tools 已安装"

# 检查 Homebrew
if ! command -v brew &>/dev/null; then
    echo "⚙️  安装 Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
echo "✓ Homebrew 已安装"

# 安装 Ollama
if ! command -v ollama &>/dev/null; then
    echo "⚙️  安装 Ollama..."
    brew install ollama
else
    echo "✓ Ollama 已安装：$(ollama --version)"
fi

# 启动 Ollama 服务
echo "⚙️  启动 Ollama 服务..."
brew services start ollama
sleep 2

# 检查并下载 qwen2.5:3b 模型
echo "⚙️  检查 qwen2.5:3b 模型（约 2GB，首次下载需要时间）..."
if ! ollama list | grep -q "qwen2.5:3b"; then
    echo "📥 下载 qwen2.5:3b 模型..."
    ollama pull qwen2.5:3b
else
    echo "✓ qwen2.5:3b 模型已存在"
fi

# 安装 Node.js（用于 web-config React 前端）
if ! command -v node &>/dev/null; then
    echo "⚙️  安装 Node.js..."
    brew install node
fi
echo "✓ Node.js：$(node --version)"

# 安装 React 前端依赖
if [ -d "web-config" ]; then
    echo "⚙️  安装 web-config 前端依赖..."
    cd web-config && npm install && cd ..
    echo "✓ 前端依赖安装完成"
fi

echo ""
echo "✅ 环境配置完成！"
echo ""
echo "下一步："
echo "  1. 在 https://www.volcengine.com/product/ark 申请豆包 API Key"
echo "  2. 用 Xcode 打开 ScreenMind.xcodeproj"
echo "  3. 在 App 首次启动后，于配置页填入豆包 API Key"
echo ""
