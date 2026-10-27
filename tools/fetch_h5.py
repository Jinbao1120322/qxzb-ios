#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
fetch_h5.py - 下载《七雄争霸H5》(qxzb) 完整离线 Web 包

来源: 腾讯云 CDN (公开、无需鉴权)
  https://qxzbh5-1251003022.file.myqcloud.com/qx-app/

产物目录结构 (可直接被 iOS WKWebView / 浏览器 file:// 加载):
  <out>/index.html                 (由 index4.html 改名)
  <out>/manifest.json
  <out>/js/*.js
  <out>/js.zip
  <out>/resource/default.res.json
  <out>/resource/assets/**         (按 default.res.json 全量抓取)

用法:
  python3 tools/fetch_h5.py --out QXZB/web --jobs 24
  python3 tools/fetch_h5.py --out QXZB/web --jobs 24 --essential-only   # 只抓核心(快速冒烟)
  python3 tools/fetch_h5.py --out QXZB/web --jobs 24 --no-resources     # 不抓美术资源

特性: 并发 + 重试 + 断点续传(已存在且非空则跳过)
"""
import argparse
import json
import os
import sys
import time
import urllib.request
import urllib.error
from concurrent.futures import ThreadPoolExecutor, as_completed

CDN_BASE = "https://qxzbh5-1251003022.file.myqcloud.com/qx-app"
UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"


def log(msg):
    sys.stdout.write(msg + "\n")
    sys.stdout.flush()


def http_get(url, timeout=30, retries=3):
    """返回 bytes；失败返回 None。"""
    last = None
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return resp.read()
        except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, OSError) as e:
            last = e
            time.sleep(0.4 * (attempt + 1))
    return None


def save(path, data):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = path + ".part"
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, path)


def fetch_one(out_root, rel_url, base=CDN_BASE):
    """rel_url 形如 'js/egret.min.js' 或 'js.zip' 或 'resource/assets/x.png?v=1'。
    返回 (rel_path, ok, size)."""
    # 去掉 query，得到磁盘路径
    clean = rel_url.split("?", 1)[0]
    disk = os.path.join(out_root, clean.replace("/", os.sep))
    if os.path.isfile(disk) and os.path.getsize(disk) > 0:
        return (clean, True, os.path.getsize(disk), "skip")
    url = base + "/" + rel_url
    data = http_get(url)
    if data is None:
        return (clean, False, 0, "fail")
    save(disk, data)
    return (clean, True, len(data), "get")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="QXZB/web", help="输出目录")
    ap.add_argument("--jobs", type=int, default=16, help="并发数")
    ap.add_argument("--essential-only", action="store_true", help="只抓核心文件，跳过全量美术资源")
    ap.add_argument("--no-resources", action="store_true", help="完全不抓美术资源")
    ap.add_argument("--base", default=CDN_BASE, help="CDN 根地址")
    args = ap.parse_args()

    out = os.path.abspath(args.out)
    base = args.base.rstrip("/")
    os.makedirs(out, exist_ok=True)
    log("[*] 输出目录: %s" % out)

    # ---------- 1) 核心文件 ----------
    core = [
        "manifest.json",
        "js.zip?v=v11.0.1014",
        "resource/default.res.json",
    ]
    got = 0
    failed = []
    for rel in core:
        r = fetch_one(out, rel, base)
        log("  [%s] %-40s %d B" % (r[3], r[0], r[2]))
        if r[1]:
            got += 1
        else:
            failed.append(r[0])
    if failed:
        log("[!] 核心文件缺失: %s" % failed)
        return 2

    # manifest.json -> 动态取 js 列表
    with open(os.path.join(out, "manifest.json"), "rb") as f:
        manifest = json.loads(f.read().decode("utf-8-sig"))
    js_list = list(manifest.get("initial", []))
    js_list.append("js/EgretSubPackageLoading.js")
    for g in manifest.get("game", []):
        js_list.append(g)

    # ---------- 2) JS ----------
    log("[*] 下载 JS (%d 个) ..." % len(js_list))
    for rel in js_list:
        r = fetch_one(out, rel, base)
        log("  [%s] %-45s %d B" % (r[3], r[0], r[2]))
        if not r[1]:
            failed.append(r[0])

    # ---------- 3) HTML / 杂项 ----------
    log("[*] 下载 HTML 与页面杂项 ...")
    # index4.html 改名为 index.html
    html = http_get(base + "/index4.html")
    if html is None:
        log("[!] index4.html 下载失败")
        return 2
    save(os.path.join(out, "index.html"), html)
    log("  [get] index.html %d B" % len(html))

    misc = [
        "icon.png",
        "resource/assets/gameBg/logo.jpg",
        "resource/assets/gameBg/preloading.gif",
        "resource/assets/gameBg/gonggao_bg.jpg",
        "resource/assets/gameUI/close.png",
    ]
    for rel in misc:
        r = fetch_one(out, rel, base)
        log("  [%s] %-45s %d B" % (r[3], r[0], r[2]))

    # ---------- 4) 美术资源 ----------
    if args.no_resources:
        log("[*] --no-resources 跳过美术资源")
    else:
        with open(os.path.join(out, "resource", "default.res.json"), "rb") as f:
            resjson = json.loads(f.read().decode("utf-8-sig"))
        entries = [x for x in resjson.get("resources", []) if isinstance(x, dict) and x.get("url")]
        if args.essential_only:
            # 只抓默认 group (通常第一个/最小的一组) 以保证能启动
            groups = resjson.get("groups", [])
            keys = set()
            if groups:
                for k in groups[0].get("keys", "").split(","):
                    if k:
                        keys.add(k.strip())
            entries = [x for x in entries if x.get("name") in keys] or entries[:60]
            log("[*] essential-only: 抓取 %d 个核心资源" % len(entries))
        else:
            log("[*] 下载美术资源 (%d 个, 并发 %d) ..." % (len(entries), args.jobs))

        total_n = len(entries)
        done = 0
        okn = 0
        byten = 0
        res_fail = []
        with ThreadPoolExecutor(max_workers=args.jobs) as ex:
            futures = {
                ex.submit(fetch_one, out, "resource/" + e["url"], base): e for e in entries
            }
            for fut in as_completed(futures):
                done += 1
                try:
                    r = fut.result()
                except Exception as e:
                    continue
                if r[1]:
                    okn += 1
                    byten += r[2]
                else:
                    res_fail.append(r[0])
                if done % 200 == 0 or done == total_n:
                    log("    进度 %d/%d  成功 %d  已下 %.1f MB  失败 %d"
                        % (done, total_n, okn, byten / 1048576.0, len(res_fail)))

        log("[*] 资源完成: 成功 %d / %d, 失败 %d" % (okn, total_n, len(res_fail)))
        if res_fail:
            log("    失败样本: %s" % res_fail[:10])

    # ---------- 汇总 ----------
    core_ok = all(os.path.isfile(os.path.join(out, p)) for p in ["index.html", "manifest.json", "js.zip"])
    log("[=] 核心文件就绪: %s" % core_ok)
    log("[=] 完成。产物: %s" % out)
    if failed:
        log("[!] 有缺失的 JS/核心: %s" % failed)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
