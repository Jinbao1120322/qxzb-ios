#!/usr/bin/env bash
# 一键：创建仓库 -> 推送 -> 触发 GitHub Actions -> 轮询 -> 下载未签名 IPA
# 用法（在本目录）：
#   GITHUB_TOKEN=ghp_xxx bash scripts/push-to-github.sh
# 可选环境变量：
#   REPO_NAME=qxzb-ios   PRIVATE=true|false
#
# 注意：token 需具备 repo + workflow 权限（否则推 .github/workflows 会被拒）。
set -euo pipefail
cd "$(dirname "$0")/.."

: "${GITHUB_TOKEN:?请先设置 GITHUB_TOKEN（需 repo + workflow 权限）}"
REPO_NAME="${REPO_NAME:-qxzb-ios}"
PRIVATE="${PRIVATE:-true}"
API="https://api.github.com"
AUTH=(-H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json")

pyjson() { python3 -c "import sys,json;d=json.load(sys.stdin);print(eval(sys.argv[1]))" "$1"; }

echo "[1/6] 校验 token"
LOGIN=$(curl -sf "${AUTH[@]}" "$API/user" | pyjson "d['login']") || { echo "token 无效"; exit 1; }
echo "    账号: $LOGIN"

echo "[2/6] 确保仓库存在 ($LOGIN/$REPO_NAME, private=$PRIVATE)"
CODE=$(curl -s -o /dev/null -w '%{http_code}' "${AUTH[@]}" "$API/repos/$LOGIN/$REPO_NAME")
if [ "$CODE" != "200" ]; then
  curl -sf -X POST "${AUTH[@]}" "$API/user/repos" \
    -d "{\"name\":\"$REPO_NAME\",\"private\":$PRIVATE,\"auto_init\":false}" >/dev/null
  echo "    已创建"
else
  echo "    已存在"
fi

echo "[3/6] 推送源码"
git remote remove origin 2>/dev/null || true
git remote add origin "https://x-access-token:${GITHUB_TOKEN}@github.com/$LOGIN/$REPO_NAME.git"
git branch -M main
git push -u origin main --force

echo "[4/6] 触发构建"
sleep 2
curl -sf -X POST "${AUTH[@]}" \
  "$API/repos/$LOGIN/$REPO_NAME/actions/workflows/build-ipa.yml/dispatches" \
  -d '{"ref":"main"}' >/dev/null || echo "    (dispatch 失败，可能 push 已自动触发)"
echo "    https://github.com/$LOGIN/$REPO_NAME/actions"

echo "[5/6] 等待构建 (最长 40 分钟)"
RUN_ID=""
for i in $(seq 1 40); do
  sleep 60
  RUN_ID=$(curl -s "${AUTH[@]}" \
    "$API/repos/$LOGIN/$REPO_NAME/actions/workflows/build-ipa.yml/runs?per_page=1" \
    | pyjson "d['workflow_runs'][0]['id'] if d.get('workflow_runs') else ''" 2>/dev/null || echo "")
  [ -z "$RUN_ID" ] && continue
  ST=$(curl -s "${AUTH[@]}" "$API/repos/$LOGIN/$REPO_NAME/actions/runs/$RUN_ID" \
    | pyjson "d['status']" 2>/dev/null || echo "?")
  CC=$(curl -s "${AUTH[@]}" "$API/repos/$LOGIN/$REPO_NAME/actions/runs/$RUN_ID" \
    | pyjson "d.get('conclusion') or ''" 2>/dev/null || echo "")
  echo "    [$i] run=$RUN_ID status=$ST conclusion=$CC"
  if [ "$ST" = "completed" ]; then
    if [ "$CC" != "success" ]; then echo "构建失败，请看上面的 Actions 页面"; exit 2; fi
    break
  fi
done

echo "[6/6] 下载 IPA 产物"
mkdir -p dist
ART_URL=$(curl -s "${AUTH[@]}" "$API/repos/$LOGIN/$REPO_NAME/actions/runs/$RUN_ID/artifacts" \
  | pyjson "d['artifacts'][0]['archive_download_url'] if d.get('artifacts') else ''")
[ -z "$ART_URL" ] && { echo "没找到产物"; exit 3; }
curl -sL -H "Authorization: Bearer ${GITHUB_TOKEN}" "$ART_URL" -o dist/artifact.zip
python3 - <<'PY'
import zipfile, shutil, os
os.makedirs('dist', exist_ok=True)
with zipfile.ZipFile('dist/artifact.zip') as z:
    z.extractall('dist')
for f in os.listdir('dist'):
    if f.endswith('.ipa'):
        shutil.move(os.path.join('dist', f), 'dist/QXZB-unsigned.ipa')
print("IPA 就绪 -> dist/QXZB-unsigned.ipa")
PY
ls -lh dist/*.ipa
