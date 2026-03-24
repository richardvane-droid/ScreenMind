#!/bin/bash
# ScreenMind — 一键推送到 GitHub
# 用法：bash push.sh
# 或者：bash push.sh "自定义提交信息"

set -e

BRANCH=$(git branch --show-current)
MSG="${1:-"chore: sync from Claude session"}"

echo "📁 当前分支：$BRANCH"
echo "📝 提交信息：$MSG"
echo ""

# 如果有未提交的改动，先自动暂存并提交
if ! git diff --quiet || ! git diff --cached --quiet || [ -n "$(git ls-files --others --exclude-standard)" ]; then
  echo "▶ 检测到未提交的改动，正在提交..."
  git add -A
  git commit -m "$MSG"
fi

echo "▶ 推送到 GitHub ($BRANCH)..."
git push -u origin "$BRANCH"

echo ""
echo "✅ 推送完成！"
echo "   👉 https://github.com/richardvane-droid/ScreenMind/tree/$BRANCH"
