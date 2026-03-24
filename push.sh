#!/bin/bash
# ScreenMind — 一键推送到 GitHub
# 用法：
#   bash push.sh                     # 用已有提交直接推
#   bash push.sh "自定义提交信息"    # 先提交再推
#   bash push.sh --token <新token>   # 更新 token

set -e

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_DIR"

# ── token 更新模式 ──────────────────────────────────────────
if [ "$1" = "--token" ]; then
  if [ -z "$2" ]; then
    echo "用法: bash push.sh --token <你的新token>"
    exit 1
  fi
  TOKEN="$2"
  git remote set-url origin "https://richardvane-droid:${TOKEN}@github.com/richardvane-droid/ScreenMind.git"
  echo "✅ token 已更新"
  # 保存 token 到本地文件（gitignore 中排除）
  echo "$TOKEN" > .gh_token
  echo "   token 已备份到 .gh_token（已在 .gitignore 中排除）"
  exit 0
fi

# ── 读取已保存的 token ──────────────────────────────────────
if [ -f ".gh_token" ]; then
  TOKEN=$(cat .gh_token)
  git remote set-url origin "https://richardvane-droid:${TOKEN}@github.com/richardvane-droid/ScreenMind.git"
fi

BRANCH=$(git branch --show-current)
MSG="${1:-"chore: sync from Claude session"}"

echo "📁 当前分支：$BRANCH"

# ── 有未提交改动则先提交 ────────────────────────────────────
if ! git diff --quiet || ! git diff --cached --quiet || [ -n "$(git ls-files --others --exclude-standard)" ]; then
  echo "📝 提交信息：$MSG"
  git add -A
  git -c user.email="richardvane@gmail.com" -c user.name="豆沙包" commit -m "$MSG"
fi

echo "▶ 推送到 GitHub ($BRANCH)..."
git push -u origin "$BRANCH"

echo ""
echo "✅ 推送完成！"
echo "   👉 https://github.com/richardvane-droid/ScreenMind/tree/$BRANCH"
