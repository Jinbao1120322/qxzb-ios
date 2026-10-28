#!/usr/bin/env python3
"""补抓 eui 主题依赖的 .exml 皮肤文件（不在 default.res.json 清单里，需单独从 thm.json 解析）。

用法：
  python3 tools/fetch_extra.py --web web --jobs 32
"""
import argparse
import json
import os
import sys
import threading
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

BASE = "https://qxzbh5-1251003022.file.myqcloud.com/qx-app/"
THM = "resource/default.thm.json"

lock = threading.Lock()
done = [0, 0]  # ok, fail


def download(web, rel, retries=3):
    dst = os.path.join(web, rel.replace("/", os.sep))
    if os.path.isfile(dst) and os.path.getsize(dst) > 0:
        with lock:
            done[0] += 1
        return True
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    url = BASE + urllib.parse.quote(rel)
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
            with urllib.request.urlopen(req, timeout=30) as r:
                data = r.read()
            with open(dst, "wb") as f:
                f.write(data)
            with lock:
                done[0] += 1
            return True
        except Exception:
            if attempt == retries - 1:
                with lock:
                    done[1] += 1
                    if done[1] <= 10:
                        print("  FAIL", rel, file=sys.stderr)
                return False
            time.sleep(0.6 * (attempt + 1))
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--web", default="web")
    ap.add_argument("--jobs", type=int, default=32)
    a = ap.parse_args()

    thm_path = os.path.join(a.web, THM.replace("/", os.sep))
    if not os.path.isfile(thm_path):
        print("下载", THM)
        os.makedirs(os.path.dirname(thm_path), exist_ok=True)
        with urllib.request.urlopen(BASE + THM, timeout=60) as r:
            open(thm_path, "wb").write(r.read())

    d = json.load(open(thm_path, encoding="utf-8"))
    targets = list(dict.fromkeys(d.get("exmls") or []))
    print("thm 引用 exml:", len(targets))

    missing = [t for t in targets
               if not (os.path.isfile(os.path.join(a.web, t.replace("/", os.sep)))
                       and os.path.getsize(os.path.join(a.web, t.replace("/", os.sep))) > 0)]
    print("本地缺失:", len(missing))

    if missing:
        with ThreadPoolExecutor(max_workers=a.jobs) as ex:
            list(ex.map(lambda r: download(a.web, r), missing))

    print("完成: ok=%d fail=%d" % (done[0], done[1]))
    if done[1]:
        print("有失败项，可重跑一次补齐")


if __name__ == "__main__":
    main()
