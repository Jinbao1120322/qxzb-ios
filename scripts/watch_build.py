#!/usr/bin/env python3
"""轮询 build-ipa.yml 最新一次运行，成功后自动下载 artifact 并落成 dist/QXZB-unsigned.ipa"""
import json, os, shutil, subprocess, sys, time, urllib.request, zipfile

REPO = os.environ.get("REPO", "Jinbao1120322/qxzb-ios")
WF = os.environ.get("WF", "build-ipa.yml")
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
TOKEN = open(os.path.join(ROOT, "dist", ".gh_token"), encoding="utf-8").read().strip()
API = "https://api.github.com"


def api(path):
    req = urllib.request.Request(
        API + path,
        headers={
            "Authorization": "Bearer " + TOKEN,
            "Accept": "application/vnd.github+json",
            "User-Agent": "qxzb-watcher",
        },
    )
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


runs = api(f"/repos/{REPO}/actions/workflows/{WF}/runs?per_page=1")["workflow_runs"]
if not runs:
    print("[watch] 没有找到运行记录", flush=True)
    sys.exit(1)
rid = runs[0]["id"]
print(f"[watch] run {rid} status={runs[0]['status']}", flush=True)

last, st, cc = None, runs[0]["status"], runs[0].get("conclusion") or ""
deadline = time.time() + 3600
while time.time() < deadline:
    d = api(f"/repos/{REPO}/actions/runs/{rid}")
    st, cc = d["status"], d.get("conclusion") or ""
    if st != last:
        print(f"[watch] {time.strftime('%H:%M:%S')} status={st} conclusion={cc}", flush=True)
        last = st
    if st == "completed":
        break
    time.sleep(30)

if st != "completed" or cc != "success":
    print(f"[watch] 构建未成功: status={st} conclusion={cc}", flush=True)
    try:
        jobs = api(f"/repos/{REPO}/actions/runs/{rid}/jobs")
        for j in jobs.get("jobs", []):
            print(f"  JOB {j['name']} => {j['conclusion']}", flush=True)
            for s in j.get("steps", []):
                print(f"    [{s.get('conclusion')}] {s['name']}", flush=True)
    except Exception as e:
        print("  (job 详情读取失败)", e, flush=True)
    sys.exit(2)

print("[watch] 构建成功，下载产物", flush=True)
arts = api(f"/repos/{REPO}/actions/runs/{rid}/artifacts").get("artifacts") or []
if not arts:
    print("[watch] 无 artifact", flush=True)
    sys.exit(3)

os.makedirs("dist", exist_ok=True)
subprocess.run(
    ["curl", "-sL", "-H", "Authorization: Bearer " + TOKEN,
     arts[0]["archive_download_url"], "-o", "dist/artifact.zip"],
    check=True,
)
shutil.rmtree("dist/_art", ignore_errors=True)
with zipfile.ZipFile("dist/artifact.zip") as z:
    z.extractall("dist/_art")
found = None
for dp, _, fns in os.walk("dist/_art"):
    for f in fns:
        if f.endswith(".ipa"):
            found = os.path.join(dp, f)
if not found:
    print("[watch] 产物里没有 .ipa", flush=True)
    sys.exit(4)
dst = "dist/QXZB-unsigned.ipa"
shutil.move(found, dst)
print(f"[watch] IPA 就绪 -> {dst}  {os.path.getsize(dst)/1048576:.1f} MB", flush=True)
print(f"[watch] 仓库: https://github.com/{REPO}", flush=True)
