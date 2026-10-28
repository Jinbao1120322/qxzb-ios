#!/usr/bin/env python3
"""本机自验：起本地静态服务 + 无头 Edge 截图，用来判断 web/ 包本身能否加载出画面。

用法：
  python3 scripts/capture.py [输出png] [url] [虚拟时间预算ms]
"""
import functools
import http.server
import os
import socketserver
import subprocess
import sys
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WEB = os.path.join(ROOT, "web")
PORT = 8899
EDGE = r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    out = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "dist", "shots", "shot.png"))
    url = sys.argv[2] if len(sys.argv) > 2 else "http://127.0.0.1:%d/index.html" % PORT
    budget = sys.argv[3] if len(sys.argv) > 3 else "20000"

    os.makedirs(os.path.dirname(out), exist_ok=True)
    handler = functools.partial(QuietHandler, directory=WEB)
    httpd = Server(("127.0.0.1", PORT), handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    time.sleep(1)

    profile = os.path.join(os.environ.get("TEMP", "."), "edge-qxzb")
    cmd = [
        EDGE,
        "--headless=new",
        "--hide-scrollbars",
        "--window-size=720,1280",
        "--user-data-dir=" + profile,
        "--screenshot=" + out,
        "--virtual-time-budget=" + budget,
    ]
    netlog = os.environ.get("NETLOG")
    if netlog:
        cmd.append("--log-net-log=" + os.path.abspath(netlog))
        cmd.append("--net-log-capture-mode=Everything")
    cmd.append(url)
    try:
        subprocess.run(cmd, timeout=150, stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
    except subprocess.TimeoutExpired:
        print("edge timeout")
    finally:
        httpd.shutdown()

    if os.path.exists(out):
        print("shot -> %s  %.1f KB" % (out, os.path.getsize(out) / 1024))
    else:
        print("shot MISSING")


if __name__ == "__main__":
    main()
