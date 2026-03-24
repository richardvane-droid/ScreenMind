#!/bin/bash
# ScreenMind GitHub 项目一键初始化脚本
# 使用方法：GITHUB_TOKEN=your_token GITHUB_USER=your_username bash scripts/github_setup.sh

set -e

TOKEN="${GITHUB_TOKEN}"
USER="${GITHUB_USER}"
REPO="ScreenMind"
API="https://api.github.com"

if [ -z "$TOKEN" ] || [ -z "$USER" ]; then
    echo "❌ 请设置环境变量：GITHUB_TOKEN 和 GITHUB_USER"
    exit 1
fi

AUTH_HEADER="Authorization: Bearer $TOKEN"
CONTENT_HEADER="Content-Type: application/json"

echo "🚀 开始初始化 GitHub 项目..."

# 1. 创建仓库
echo "📁 创建仓库 $REPO..."
curl -s -X POST "$API/user/repos" \
  -H "$AUTH_HEADER" -H "$CONTENT_HEADER" \
  -d "{\"name\":\"$REPO\",\"description\":\"个人情绪健康监控助手 — macOS · iOS\",\"private\":true,\"auto_init\":false}" \
  | python3 -c "import sys,json; r=json.load(sys.stdin); print('✅ 仓库已创建：' + r.get('html_url','ERROR: '+str(r)))"

sleep 1

# 2. 推送代码
echo "📤 推送代码..."
git remote add origin "https://$USER:$TOKEN@github.com/$USER/$REPO.git"
git push -u origin main

# 3. 创建 develop 分支
git checkout -b develop
git push -u origin develop
git checkout main

# 4. 创建 Milestones
echo "🏁 创建 Milestones..."
create_milestone() {
    curl -s -X POST "$API/repos/$USER/$REPO/milestones" \
      -H "$AUTH_HEADER" -H "$CONTENT_HEADER" \
      -d "{\"title\":\"$1\",\"description\":\"$2\"}" \
      | python3 -c "import sys,json; r=json.load(sys.stdin); print('  ✓ Milestone: ' + r.get('title',''))"
}

create_milestone "M1: 项目骨架 & 基础设施" "Xcode多Target初始化、CloudKit配置、Core Data模型、App Groups、GitHub Actions CI"
create_milestone "M2: macOS 屏幕采集 & OCR" "ScreenCaptureKit截图模块、Vision Framework OCR、定时采样调度器、应用过滤"
create_milestone "M3: 内容焦虑分析引擎" "NaturalLanguage Stage 1过滤、Ollama Stage 2深度分析、滑动窗口均值、Prompt优化"
create_milestone "M4: HRV 集成 & 动态阈值" "HealthKit HRV读取、个人基线计算、动态阈值引擎、告警冷却管理器"
create_milestone "M5: iOS Layer 1 行为监控" "DeviceActivity行为监控、FamilyControls权限、iOS行为焦虑评分、通知内容拦截"
create_milestone "M6: iOS Layer 2 深度监控" "Broadcast Upload Extension、抖音+公众号触发检测、App Group通信、降采样OCR调度"
create_milestone "M7: 账号风格评估" "火山方舟API(豆包)集成、双引擎路由、账号画像缓存、置信度分级、Keychain存储"
create_milestone "M8: 放松建议系统 & MapKit" "CLGeocoder地址预处理、MKDirections并发车程、建议筛选引擎、SuggestionPanel浮窗"
create_milestone "M9: 配置界面" "macOS Web配置页(React+WKWebView)、iOS SwiftUI配置页、建议库CRUD、iPhone 16 Pro Action Button"
create_milestone "M10: 周报系统" "数据聚合引擎、Swift Charts图表、PDF导出、每周一触发、CloudKit存储"
create_milestone "M11: 联调优化 & 发布" "全流程联调、性能优化、权限引导流程、打包macOS .app + iOS .ipa"

echo ""
echo "✅ GitHub 项目初始化完成！"
echo "🔗 仓库地址：https://github.com/$USER/$REPO"
