#!/usr/bin/env bash
# MeChat 一键创建 GitHub 仓库并推送（需要 Personal Access Token，仅从环境变量读取、不落盘）
# 用法：GITHUB_TOKEN=ghp_xxx bash push-to-github.sh
# Token 需勾选 repo 权限；仓库默认建在 thuki20 账号下，可用 GITHUB_REPO 覆盖。
set -euo pipefail

: "${GITHUB_TOKEN:?请先提供 GitHub Personal Access Token：export GITHUB_TOKEN=ghp_xxx}"
GITHUB_REPO="${GITHUB_REPO:-thuki20/MeChat}"
REPO_NAME="${GITHUB_REPO##*/}"
OWNER="${GITHUB_REPO%%/*}"
cd "$(dirname "$0")"

echo "==> 检查仓库是否已存在：$GITHUB_REPO"
CODE=$(curl -s -o /tmp/mechat-repo-check.json -w '%{http_code}' \
  -H "Authorization: Bearer $GITHUB_TOKEN" -H 'Accept: application/vnd.github+json' \
  "https://api.github.com/repos/$GITHUB_REPO")
if [ "$CODE" = "200" ]; then
  echo "    已存在，跳过创建"
elif [ "$CODE" = "404" ]; then
  echo "==> 创建仓库"
  curl -fsS -X POST -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H 'Accept: application/vnd.github+json' \
    https://api.github.com/user/repos \
    -d "{\"name\":\"$REPO_NAME\",\"description\":\"MeChat - macOS 原生即时通讯客户端 (Swift)\",\"private\":false,\"has_issues\":true}" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print("    ✔", d["full_name"], d["html_url"])'
else
  echo "✗ 查询失败 HTTP $CODE"; cat /tmp/mechat-repo-check.json; exit 1
fi

echo "==> 推送代码"
git remote remove origin 2>/dev/null || true
git remote add origin "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPO}.git"
git push -u origin HEAD:main
git remote set-url origin "https://github.com/${GITHUB_REPO}.git"
echo "✔ 完成：https://github.com/$GITHUB_REPO"
