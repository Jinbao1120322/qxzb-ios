#!/usr/bin/env bash
# 使用系统凭据库（Git Credential Manager）中已登录的 GitHub 账号，
# 自动完成：建私有仓库 -> 推送 -> 触发 Actions -> 轮询 -> 下载未签名 IPA
#
# 前置：先执行一次浏览器登录
#   git-credential-manager github login --browser
#
# 用法：
#   bash scripts/login-build.sh
# 可选：
#   REPO_NAME=qxzb-ios PRIVATE=false bash scripts/login-build.sh
set -uo pipefail
cd "$(dirname "$0")/.."

REPO_NAME="${REPO_NAME:-qxzb-ios}"
PRIVATE="${PRIVATE:-true}"
API="https://api.github.com"

echo "[0/7] 从系统凭据库读取 GitHub 凭据"
CRED="$(printf 'protocol=https\nhost=github.com\n\n' | GCM_INTERACTIVE=never GIT_TERMINAL_PROMPT=0 git credential fill 2>/dev/null || true)"
TOKEN="$(printf '%s\n' "$CRED" | sed -n 's/^password=//p' | tr -d '\r')"
if [ -z "${TOKEN}" ]; then
  echo "  ✗ 凭据库中没有 GitHub token。请先跑："
  echo "    git-credential-manager github login --browser"
  exit 1
fi
echo "  账户: $(printf '%s\n' "$CRED" | sed -n 's/^username=//p' | tr -d '\r')  token: ${TOKEN:0:7}… (${#TOKEN} 字符)"

echo "[0.5] 校验 token 与权限范围"
HDR="$(curl -s -D - -o /dev/null -H "Authorization: Bearer ${TOKEN}" "$API/user" | tr -d '\r')"
LOGIN="$(curl -s -H "Authorization: Bearer ${TOKEN}" "$API/user" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("login",""))')"
[ -z "$LOGIN" ] && { echo "  ✗ token 无效或已过期"; exit 1; }
SCOPES="$(printf '%s\n' "$HDR" | grep -i '^x-oauth-scopes:' | sed 's/^[^:]*: *//')"
echo "  账号: $LOGIN"
echo "  scopes: ${SCOPES:-（fine-grained token 或未返回）}"
SCOPES_N="$(printf '%s' "$SCOPES" | tr -d ' ')"
case ",${SCOPES_N}," in
  *,workflow,*|"") : ;;
  *) echo "  ⚠ 缺少 workflow scope，推送 .github/workflows 会被拒。请重新登录并授权 workflow。" ;;
esac

echo "[1/7] 确保仓库存在 ($LOGIN/$REPO_NAME, private=$PRIVATE)"
CODE="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${TOKEN}" "$API/repos/$LOGIN/$REPO_NAME")"
if [ "$CODE" != "200" ]; then
  curl -sf -X POST -H "Authorization: Bearer ${TOKEN}" -H "Accept: application/vnd.github+json" \
    "$API/user/repos" -d "{\"name\":\"$REPO_NAME\",\"private\":$PRIVATE,\"auto_init\":false}" >/dev/null \
    && echo "  已创建" || { echo "  ✗ 创建失败（token 可能缺 repo 权限）"; exit 1; }
else
  echo "  已存在"
fi

echo "[2/7] 推送源码"
git remote remove origin 2>/dev/null || true
git remote add origin "https://x-access-token:${TOKEN}@github.com/$LOGIN/$REPO_NAME.git"
git branch -M main
git push -u origin main --force 2>&1 | tail -6
# 推送后清掉 URL 里的 token，避免残留
git remote set-url origin "https://github.com/$LOGIN/$REPO_NAME.git"

echo "[3/7] Actions 页面"
echo "  https://github.com/$LOGIN/$REPO_NAME/actions"

echo "[4/7] 等待工作流注册"
RUN_ID=""
for i in $(seq 1 20); do
  sleep 15
  RUN_ID="$(curl -s -H "Authorization: Bearer ${TOKEN}" \
    "$API/repos/$LOGIN/$REPO_NAME/actions/workflows/build-ipa.yml/runs?per_page=1" \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);r=d.get("workflow_runs") or [];print(r[0]["id"] if r else "")' 2>/dev/null || true)"
  [ -n "$RUN_ID" ] && break
done
[ -z "$RUN_ID" ] && { echo "  ✗ 未发现构建（可能是 workflow 文件未推上去，或缺 workflow scope）"; exit 2; }
echo "  run id: $RUN_ID"

echo "[5/7] 跟踪构建（最长 60 分钟，每 45s 一次）"
for i in $(seq 1 80); do
  sleep 45
  J="$(curl -s -H "Authorization: Bearer ${TOKEN}" "$API/repos/$LOGIN/$REPO_NAME/actions/runs/$RUN_ID")"
  ST="$(printf '%s' "$J" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("status",""))')"
  CC="$(printf '%s' "$J" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("conclusion") or "")')"
  echo "  [$i] status=$ST conclusion=$CC"
  if [ "$ST" = "completed" ]; then
    if [ "$CC" != "success" ]; then
      echo "  ✗ 构建失败，日志：https://github.com/$LOGIN/$REPO_NAME/actions/runs/$RUN_ID"
      exit 3
    fi
    break
  fi
done

echo "[6/7] 下载产物"
mkdir -p dist
ART_URL="$(curl -s -H "Authorization: Bearer ${TOKEN}" \
  "$API/repos/$LOGIN/$REPO_NAME/actions/runs/$RUN_ID/artifacts" \
  | python3 -c 'import sys,json;a=json.load(sys.stdin).get("artifacts") or [];print(a[0]["archive_download_url"] if a else "")')"
[ -z "$ART_URL" ] && { echo "  ✗ 无产物"; exit 4; }
curl -sL -H "Authorization: Bearer ${TOKEN}" "$ART_URL" -o dist/artifact.zip
python3 - <<'PY'
import zipfile, os, shutil
os.makedirs('dist', exist_ok=True)
with zipfile.ZipFile('dist/artifact.zip') as z:
    z.extractall('dist/_art')
ipa = None
for dp, _, fns in os.walk('dist/_art'):
    for f in fns:
        if f.endswith('.ipa'):
            ipa = os.path.join(dp, f)
if ipa:
    dst = 'dist/QXZB-unsigned.ipa'
    shutil.move(ipa, dst)
    print("  IPA 就绪 ->", dst, "%.1f MB" % (os.path.getsize(dst)/1024/1024))
else:
    print("  ! 产物里没有 .ipa")
PY
echo "[7/7] 完成"
ls -lh dist/*.ipa 2>/dev/null || true
echo "  仓库: https://github.com/$LOGIN/$REPO_NAME"
