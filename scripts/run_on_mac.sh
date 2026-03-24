#!/bin/bash
# ============================================================
# ScreenMind — 在你的 Mac 上运行此脚本完成 GitHub 全部初始化
# 用法：bash scripts/run_on_mac.sh
# ============================================================

set -e

TOKEN="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"
USER="richardvane-droid"
REPO="ScreenMind"
API="https://api.github.com"
AUTH="-H \"Authorization: Bearer $TOKEN\" -H \"Accept: application/vnd.github+json\" -H \"Content-Type: application/json\""

echo "🚀 ScreenMind GitHub 初始化开始..."
echo ""

# ── 步骤 1：创建 GitHub 仓库 ────────────────────────────────
echo "📁 步骤1：创建私有仓库 $REPO..."
CREATE_RESULT=$(curl -s -X POST "$API/user/repos" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.github+json" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"$REPO\",\"description\":\"个人情绪健康监控助手 — macOS · iOS\",\"private\":true,\"auto_init\":false}")

REPO_URL=$(echo $CREATE_RESULT | python3 -c "import sys,json; r=json.load(sys.stdin); print(r.get('html_url',''))" 2>/dev/null)

if [ -z "$REPO_URL" ]; then
  # 可能仓库已存在
  echo "  ℹ️  仓库可能已存在，继续..."
else
  echo "  ✅ 仓库已创建：$REPO_URL"
fi

# ── 步骤 2：推送代码 ────────────────────────────────────────
echo ""
echo "📤 步骤2：推送代码到 GitHub..."

# 设置远端（如已存在则更新）
git remote remove origin 2>/dev/null || true
git remote add origin "https://$USER:$TOKEN@github.com/$USER/$REPO.git"
git push -u origin main
echo "  ✅ main 分支已推送"

# 创建并推送 develop 分支
git checkout -b develop 2>/dev/null || git checkout develop
git push -u origin develop
git checkout main
echo "  ✅ develop 分支已推送"

# ── 步骤 3：创建 Labels 和 Milestones + Issues ──────────────
echo ""
echo "🏷  步骤3：创建 Labels、Milestones 和 Issues..."
GITHUB_TOKEN="$TOKEN" GITHUB_USER="$USER" python3 scripts/github_issues.py

echo ""
echo "🎉 全部完成！"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔗 仓库：  https://github.com/$USER/$REPO"
echo "📋 Issues：https://github.com/$USER/$REPO/issues"
echo "🏁 里程碑：https://github.com/$USER/$REPO/milestones"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
