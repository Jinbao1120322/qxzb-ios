#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""apply_patches.py - 让 H5 包在「无原生 SDK 的 WKWebView」里跑起来

背景：这套 H5 游戏是为「安卓 APK + 原生 JSBridge」编译的。
直接丢进 iOS WKWebView 会出现三个断点，本脚本逐一修掉（幂等，可重复执行）：

  1. 主题皮肤缺失
     resource/default.thm.json 的 skins 只有 13 个 eui 内建皮肤，
     js/default.thm.js 的 generateEUI.skins 同样只有 13 个，
     但 generateEUI.paths 里有 3555 个业务 EXML（LoginSkin 等）。
     eui.Theme 只从 skins 建 skinMap，因此 3555 个界面全部无皮肤 -> 全透明 -> 只剩启动图。
     修复：用 generateEUI.paths 反推 {皮肤名: exml路径} 全量写进 skins。

  2. 启动链路等原生回调
     LoginControler.createdCallBack 里 isPublish && !isTest 时走
     JSBridge.initGame()（安卓 Java 桥），WebView 里没人回调 -> 永久卡住。
     修复：改为直接走 getDefaultServerData()（纯 HTTP，公开接口）。

  3. UID 来源
     getUID() 原先只从原生 SDK 拿。修复：优先读 window.mobileHall.params.gameopenid。

配套：index.html 注入 window.mobileHall（参数 9200 = 官网 H5 渠道）。
"""
import json
import os
import re
import sys

WEB = sys.argv[1] if len(sys.argv) > 1 else "web"


def log(msg):
    print("[patch] " + msg)


# ---------------------------------------------------------------- 1. thm.js skins
def patch_thm_js():
    path = os.path.join(WEB, "js", "default.thm.js")
    if not os.path.exists(path):
        log("SKIP default.thm.js (缺失)")
        return
    s = open(path, encoding="utf-8", errors="replace").read()
    keys = re.findall(r'generateEUI\.paths\["([^"]+)"\]=', s)
    if not keys:
        log("SKIP default.thm.js (无 paths，可能已处理)")
        return
    i = s.find("generateEUI.skins=")
    if i < 0:
        log("SKIP default.thm.js (无 skins)")
        return
    j = i + len("generateEUI.skins=")
    depth = 0
    end = -1
    for k in range(j, len(s)):
        if s[k] == "{":
            depth += 1
        elif s[k] == "}":
            depth -= 1
            if depth == 0:
                end = k + 1
                break
    if end < 0:
        log("SKIP default.thm.js (skins 括号不匹配)")
        return
    try:
        cur = json.loads(s[j:end])
    except Exception as e:
        log("SKIP default.thm.js (skins 非法 JSON: %s)" % e)
        return
    before = len(cur)
    new = dict(cur)
    for p in keys:
        name = p.rsplit("/", 1)[-1]
        if name.endswith(".exml"):
            name = name[:-5]
        new.setdefault(name, p)
    if len(new) == before:
        log("OK   default.thm.js 皮肤已完整 (%d)" % before)
        return
    body = json.dumps(new, ensure_ascii=False, separators=(",", ":"))
    out = s[:j] + body + s[end:]
    open(path, "w", encoding="utf-8").write(out)
    log("FIX  default.thm.js skins %d -> %d (%d 个 EXML)" % (before, len(new), len(keys)))


# ---------------------------------------------------------------- 2. thm.json skins
def patch_thm_json():
    path = os.path.join(WEB, "resource", "default.thm.json")
    if not os.path.exists(path):
        log("SKIP default.thm.json (缺失)")
        return
    try:
        d = json.load(open(path, encoding="utf-8"))
    except Exception as e:
        log("SKIP default.thm.json (解析失败: %s)" % e)
        return
    skins = d.get("skins") or {}
    exmls = d.get("exmls") or []
    if not isinstance(exmls, list) or not exmls:
        log("SKIP default.thm.json (无 exmls)")
        return
    paths = [x for x in exmls if isinstance(x, str)]
    if not paths:
        # 已经是内嵌 gjs 格式，无需处理
        log("OK   default.thm.json 已是内嵌格式")
        return
    before = len(skins)
    for p in paths:
        name = p.rsplit("/", 1)[-1]
        if name.endswith(".exml"):
            name = name[:-5]
        skins.setdefault(name, p)
    if len(skins) == before:
        log("OK   default.thm.json 皮肤已完整 (%d)" % before)
        return
    d["skins"] = skins
    # exmls 置空：走 generateEUI.paths 内存取，避免 3555 个 exml 的 404 风暴
    d["exmls"] = []
    json.dump(d, open(path, "w", encoding="utf-8"), ensure_ascii=False, separators=(",", ":"))
    log("FIX  default.thm.json skins %d -> %d，exmls 清空" % (before, len(skins)))


# ---------------------------------------------------------------- 3. main.min.js
def patch_main_js():
    path = os.path.join(WEB, "js", "main.min.js")
    if not os.path.exists(path):
        log("SKIP main.min.js (缺失)")
        return
    s = open(path, encoding="utf-8", errors="replace").read()
    n = 0

    a1 = "getUID=function(){return u.Utils.isTest()&&"
    b1 = ("getUID=function(){if(window.mobileHall&&window.mobileHall.params&&"
          "window.mobileHall.params.gameopenid)return this.uid="
          "window.mobileHall.params.gameopenid;return u.Utils.isTest()&&")
    if a1 in s and s.count(a1) == 1:
        s = s.replace(a1, b1)
        n += 1
        log("FIX  main.min.js getUID -> mobileHall.gameopenid")
    elif s.count(b1) == 1:
        log("OK   main.min.js getUID 已处理")

    a2 = ("u.Utils.isPublish()&&!u.Utils.isTest()?u.JSBridge.Instance.initGame()"
          ":this.getDefaultServerData()")
    if a2 in s and s.count(a2) == 1:
        s = s.replace(a2, "this.getDefaultServerData()")
        n += 1
        log("FIX  main.min.js 跳过 JSBridge.initGame -> getDefaultServerData()")
    elif "this.getDefaultServerData(),u.GameConfig.isQQ" in s:
        log("OK   main.min.js 启动链路已处理")

    if n:
        open(path, "w", encoding="utf-8").write(s)
    if not n:
        log("OK   main.min.js 无需修改")


# ---------------------------------------------------------------- 4. index.html
def patch_index_html():
    path = os.path.join(WEB, "index.html")
    if not os.path.exists(path):
        log("SKIP index.html (缺失)")
        return
    s = open(path, encoding="utf-8").read()
    if "mobileHall" in s:
        log("OK   index.html 已注入 mobileHall")
        return
    anchor = '<script egret="lib" src="js/jszip.min.js"></script>'
    if anchor not in s:
        log("SKIP index.html (找不到注入点)")
        return
    inject = ('<script>window.mobileHall={params:{gameopenid:"qxzblocal001",'
              'gameopenkey:"local-session"}};</script>\n    ' + anchor)
    s = s.replace(anchor, inject, 1)
    open(path, "w", encoding="utf-8").write(s)
    log("FIX  index.html 注入 window.mobileHall (plantform 9200 自动登录)")


def main():
    if not os.path.isdir(WEB):
        print("web 目录不存在: " + WEB)
        sys.exit(1)
    patch_thm_js()
    patch_thm_json()
    patch_main_js()
    patch_index_html()
    log("done")


if __name__ == "__main__":
    main()
