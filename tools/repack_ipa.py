#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""用本地已打补丁的 web/ 重新封装未签名 ipa（快速通道，不落盘解包、不依赖 GitHub artifact 下载）。

做法：流式读源 ipa，原样搬运非 web/ 条目（二进制/Frameworks/Info.plist 等），
      web/ 部分整体用本地目录重建。输出标准 Payload/ 结构。
"""
import os
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_IPA = os.path.join(ROOT, "dist", "QXZB-unsigned.ipa")
OUT_IPA = os.path.join(ROOT, "dist", "QXZB-unsigned-v2.ipa")
LOCAL_WEB = os.path.join(ROOT, "web")
SKIP_NAMES = {"index_dbg.html", ".DS_Store", "Thumbs.db"}


def main():
    if not os.path.exists(SRC_IPA):
        print("缺少源 ipa:", SRC_IPA)
        return 1

    with zipfile.ZipFile(SRC_IPA) as zin:
        prefix = None
        for n in zin.namelist():
            if n.startswith("Payload/") and "/web/" in n:
                prefix = n.split("/web/")[0] + "/web/"
                break
        if prefix is None:
            print("源 ipa 内未找到 Payload/*/web/")
            return 1
        print("[1/3] web 前缀:", prefix)

        if os.path.exists(OUT_IPA):
            os.remove(OUT_IPA)

        carried = 0
        with zipfile.ZipFile(OUT_IPA, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as zout:
            # 1) 搬运非 web 条目
            for info in zin.infolist():
                if info.is_dir():
                    continue
                if info.filename.startswith(prefix):
                    continue
                zout.writestr(info, zin.read(info.filename))
                carried += 1
            print("[2/3] 搬运非 web 条目:", carried)

            # 2) 本地 web 全量写入
            written = 0
            for base, _dirs, files in os.walk(LOCAL_WEB):
                for f in files:
                    if f in SKIP_NAMES:
                        continue
                    full = os.path.join(base, f)
                    rel = os.path.relpath(full, LOCAL_WEB).replace("\\", "/")
                    zout.write(full, prefix + rel)
                    written += 1
            print("      web 写入:", written)

    print("[3/3] 校验 ...")
    size = os.path.getsize(OUT_IPA)
    with zipfile.ZipFile(OUT_IPA) as z:
        names = set(z.namelist())
        bin_ok = any(n.startswith("Payload/") and n.count("/") == 2 and not n.endswith("/")
                     for n in names)
        idx = prefix + "index.html"
        mh = b"mobileHall" in z.read(idx) if idx in names else False
        tmj = prefix + "js/default.thm.js"
        skins = z.read(tmj).count(b".exml") if tmj in names else -1
    print("     %s  %.1f MB  entries=%d  bin=%s  mobileHall=%s  thmPaths=%d" % (
        os.path.basename(OUT_IPA), size / 1048576.0, len(names), bin_ok, mh, skins))
    return 0 if (bin_ok and mh) else 2


if __name__ == "__main__":
    sys.exit(main())
