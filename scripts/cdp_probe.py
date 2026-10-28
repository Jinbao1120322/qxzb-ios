#!/usr/bin/env python3
"""CDP 探针：本地静态服务 + 无头 Edge + 全量网络请求记录 + 注入 JS + 截图。

用途：定位 web/ 包在本地加载到哪一步、游戏向哪些域名/接口发请求（离线化的输入清单）。

用法：
  python scripts/cdp_probe.py --wait 45 --shot dist/shots/p1.png
  python scripts/cdp_probe.py --wait 30 --eval "xxx()" --shot dist/shots/p2.png
  python scripts/cdp_probe.py --url http://127.0.0.1:8899/index_dbg.html --wait 40

输出：
  dist/logs/<name>.requests.txt   全部请求（URL / method / status / type）
  dist/logs/<name>.console.txt    console + exception
"""
import argparse
import functools
import http.server
import json
import os
import socketserver
import subprocess
import sys
import threading
import time

import websocket

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WEB = os.path.join(ROOT, "web")
EDGE = r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
HTTP_PORT = 8899
CDP_PORT = 9333


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


class CDP:
    def __init__(self, ws_url):
        self.ws = websocket.create_connection(ws_url, timeout=30,
                                              suppress_origin=True,
                                              header=["Origin: http://localhost"])
        self.mid = 0
        self.reqs = {}
        self.events = []
        self.console = []

    def send(self, method, params=None, wait=True):
        self.mid += 1
        mid = self.mid
        self.ws.send(json.dumps({"id": mid, "method": method, "params": params or {}}))
        if not wait:
            return None
        while True:
            msg = json.loads(self.ws.recv())
            if msg.get("id") == mid:
                return msg
            self._on_event(msg)

    def pump(self, seconds):
        end = time.time() + seconds
        self.ws.settimeout(0.4)
        while time.time() < end:
            try:
                msg = json.loads(self.ws.recv())
            except Exception:
                continue
            if "id" in msg:
                continue
            self._on_event(msg)

    def _on_event(self, msg):
        m = msg.get("method", "")
        p = msg.get("params", {})
        if m == "Network.requestWillBeSent":
            r = p["request"]
            self.reqs[p["requestId"]] = {
                "url": r["url"], "method": r["method"], "type": p.get("type", ""),
                "post": (r.get("postData") or "")[:400], "status": None, "mime": "",
            }
        elif m == "Network.responseReceived":
            rid = p["requestId"]
            if rid in self.reqs:
                self.reqs[rid]["status"] = p["response"].get("status")
                self.reqs[rid]["mime"] = p["response"].get("mimeType", "")
        elif m == "Network.loadingFailed":
            rid = p["requestId"]
            if rid in self.reqs:
                self.reqs[rid]["status"] = "FAIL:" + str(p.get("errorText"))[:60]
        elif m in ("Runtime.consoleAPICalled",):
            args = []
            for a in p.get("args", []):
                v = a.get("value")
                if v is None:
                    v = a.get("description") or a.get("type")
                args.append(str(v)[:300])
            self.console.append("[%s] %s" % (p.get("type"), " ".join(args)))
        elif m == "Runtime.exceptionThrown":
            d = p.get("exceptionDetails", {})
            txt = d.get("text", "")
            exc = (d.get("exception") or {}).get("description", "")
            self.console.append("[EXC] %s %s" % (txt, str(exc)[:400]))
        elif m == "Log.entryAdded":
            e = p["entry"]
            self.console.append("[%s] %s %s" % (e.get("level"), e.get("text", ""),
                                                e.get("url", "")))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://127.0.0.1:%d/index.html" % HTTP_PORT)
    ap.add_argument("--wait", type=int, default=45)
    ap.add_argument("--shot", default="dist/shots/probe.png")
    ap.add_argument("--eval", action="append", default=[])
    ap.add_argument("--click", action="append", default=[])
    ap.add_argument("--act", action="append", default=[])
    ap.add_argument("--name", default="")
    ap.add_argument("--winsize", default="720,1280")
    args = ap.parse_args()

    name = args.name or time.strftime("%H%M%S")
    logdir = os.path.join(ROOT, "dist", "logs")
    os.makedirs(logdir, exist_ok=True)
    shot = args.shot if os.path.isabs(args.shot) else os.path.join(ROOT, args.shot)
    os.makedirs(os.path.dirname(shot), exist_ok=True)

    handler = functools.partial(QuietHandler, directory=WEB)
    httpd = Server(("127.0.0.1", HTTP_PORT), handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()

    profile = os.path.join(os.environ.get("TEMP", "."), "edge-qxzb-cdp-%d" % int(time.time()))
    proc = subprocess.Popen([
        EDGE, "--headless=new", "--hide-scrollbars", "--mute-audio",
        "--window-size=" + args.winsize,
        "--user-data-dir=" + profile,
        "--remote-debugging-port=%d" % CDP_PORT,
        "--remote-allow-origins=*",
        "--no-first-run", "--no-default-browser-check",
        "--disable-features=Translate",
        "about:blank",
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    ws_url = None
    for _ in range(80):
        time.sleep(0.25)
        try:
            import urllib.request
            data = json.load(urllib.request.urlopen("http://127.0.0.1:%d/json" % CDP_PORT, timeout=2))
            pages = [t for t in data if t.get("type") == "page"]
            if pages:
                ws_url = pages[0]["webSocketDebuggerUrl"]
                break
        except Exception:
            pass
    if not ws_url:
        print("CDP 连接失败")
        proc.kill()
        sys.exit(1)

    cdp = CDP(ws_url)
    cdp.send("Network.enable")
    cdp.send("Network.setCacheDisabled", {"cacheDisabled": True})
    cdp.send("Runtime.enable")
    cdp.send("Log.enable")
    cdp.send("Page.enable")
    cdp.send("Emulation.setDeviceMetricsOverride", {
        "width": 720, "height": 1280, "deviceScaleFactor": 1, "mobile": False})
    cdp.send("Page.navigate", {"url": args.url})
    print("navigate", args.url)

    step = max(1, args.wait // max(1, len(args.eval) + len(args.click) + len(args.act) + 1))

    def do_eval(js):
        r = cdp.send("Runtime.evaluate", {"expression": js, "awaitPromise": False,
                                          "returnByValue": True})
        res = r.get("result", {})
        val = res.get("result", {})
        if "value" in val:
            print("eval ->", str(val["value"])[:300])
        else:
            print("eval !!", json.dumps(res, ensure_ascii=False)[:500])

    def do_click(c):
        x, y = [float(v) for v in c.split(",")]
        cdp.send("Input.dispatchMouseEvent", {"type": "mouseMoved", "x": x, "y": y})
        cdp.send("Input.dispatchMouseEvent", {"type": "mousePressed", "x": x, "y": y,
                                              "button": "left", "clickCount": 1})
        cdp.send("Input.dispatchMouseEvent", {"type": "mouseReleased", "x": x, "y": y,
                                              "button": "left", "clickCount": 1})
        print("click ->", x, y)

    for js in args.eval:
        cdp.pump(step)
        do_eval(js)

    for c in args.click:
        cdp.pump(step)
        do_click(c)

    for a in args.act:
        cdp.pump(step)
        kind, _, body = a.partition(":")
        if kind == "click":
            do_click(body)
        elif kind == "eval":
            do_eval(body)
        elif kind == "wait":
            cdp.pump(int(body))
    cdp.pump(step)

    # 截图
    r = cdp.send("Page.captureScreenshot", {"format": "png"})
    import base64
    data = r.get("result", {}).get("data")
    if data:
        open(shot, "wb").write(base64.b64decode(data))
        print("shot ->", shot)

    # 落盘
    rows = sorted(cdp.reqs.values(), key=lambda x: x["url"])
    with open(os.path.join(logdir, name + ".requests.txt"), "w", encoding="utf-8") as f:
        for x in rows:
            f.write("%-6s %-5s %s\n        %s\n" % (x["status"], x["method"], x["url"], x["mime"]))
            if x["post"]:
                f.write("        POST " + x["post"].replace("\n", " ") + "\n")
    with open(os.path.join(logdir, name + ".console.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(cdp.console))

    # 汇总外部域名
    from collections import Counter
    hosts = Counter()
    calls = []
    for x in rows:
        u = x["url"]
        if u.startswith("http") and "127.0.0.1" not in u:
            host = u.split("/")[2]
            hosts[host] += 1
            calls.append(x)
    print("\n== 外部请求 %d 条，域名 %d 个 ==" % (len(calls), len(hosts)))
    for h, c in hosts.most_common(30):
        print("  %5d  %s" % (c, h))

    cdp.ws.close()
    proc.kill()
    httpd.shutdown()


if __name__ == "__main__":
    main()
