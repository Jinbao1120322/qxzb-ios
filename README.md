# 七雄争霸H5 · iOS 未签名 IPA 工程（qxzb-ios）

把《七雄争霸H5》(qxzb) 的 H5 游戏包封装成 iOS App，产出一个**未签名 `.ipa`**，由你在 Mac 上
或 **GitHub Actions** 编译，再用侧载工具签名安装到 iPhone/iPad。

游戏本体是 **Egret(H5/JavaScript)**，全部代码与资源已在公开 CDN 上；本工程只做「iOS 外壳 + 离线包 + 网络拦截」，
不修改游戏业务逻辑。

---

## 一、它怎么工作

```
┌────────────────────────────── iPhone / iPad ──────────────────────────────┐
│  QXZB.app                                                                  │
│   ├─ WKWebView                                                             │
│   │    └─ 加载 qxzb://local/index.html   ← 自定义 scheme，由本地代码提供    │
│   │         ├─ ./manifest.json / js/*.js / js.zip   → 游戏引擎 + 逻辑       │
│   │         └─ ./resource/**  (7022 个美术资源)      → 资源                 │
│   └─ WKUserScript: Bridge/network_shim.js                                   │
│        ├─ mode=log  : 放行真实请求，并把 URL/回包打到 Xcode 控制台(抓协议)   │
│        └─ mode=mock : 拦截发往 youxigu/tanwan 的请求，返回本地 JSON(离线)   │
└────────────────────────────────────────────────────────────────────────────┘
```

- **不用改 APK、不用脱壳**：安卓包的 `lib39285EFA.so` 加固、加密 DEX 与 iOS 无关，直接弃用。
- **资源不落库**：`web/` 约 500MB，构建时由 `tools/fetch_h5.py` 从 CDN 全量抓取。
- **单机化开关**：垫片默认 `log` 模式（能联网正常玩 + 顺带采集协议）；切成 `mock` 即离线打桩。

---

## 二、目录结构

```
qxzb-ios/
├── project.yml                      # XcodeGen 工程描述
├── QXZB/
│   ├── AppDelegate.swift            # 入口，创建 UIWindow
│   ├── ViewController.swift         # WKWebView 宿主 + 注入垫片 + 日志桥
│   ├── LocalSchemeHandler.swift     # qxzb:// 提供 web/ 目录（支持 XHR）
│   ├── Bridge/network_shim.js       # 网络拦截/采集垫片（单机化核心）
│   ├── Assets.xcassets/             # App 图标
│   └── Info.plist                   # 由 xcodegen 生成
├── web/                             # H5 离线包（构建时抓取，不入库）
├── tools/fetch_h5.py                # CDN 全量抓取脚本
├── scripts/build-ipa.sh             # Mac 本地一键构建
└── .github/workflows/build-ipa.yml  # GitHub Actions 构建
```

---

## 三、构建方式

### 方式 A：GitHub Actions（推荐，无需 Mac）

1. 新建 GitHub 仓库，把本目录内容推上去（**不要**把 500MB 的 `web/` 推上去；已在 `.gitignore` 排除）。
2. 推送到 `main` 分支，或到 **Actions → Build unsigned IPA → Run workflow** 手动触发。
3. 跑完在 **Artifacts** 下载 `QXZB-unsigned-ipa`，得到 `QXZB-unsigned.ipa`。

工作流做的事：`checkout → 抓 web/ → brew install xcodegen → xcodegen → xcodebuild(CODE_SIGNING_ALLOWED=NO) → 打包 Payload → 上传`。

> 首次构建会从腾讯云 CDN 抓约 500MB/7000 个文件，耗时约 5–15 分钟；之后有缓存会快些。

### 方式 B：Mac 本地

```bash
brew install xcodegen
./scripts/build-ipa.sh
# 产物：qxzb-ios/QXZB-unsigned.ipa
```

### 方式 C：不要 App，直接 iPhone Safari 玩

把 `web/` 整个目录起个本地/远程静态服务，iPhone 用 Safari 打开 `index.html` →
「分享 → 添加到主屏幕」，体验等同 App，**零签名、零 Mac**。

```bash
# 任意静态服务器，例如
cd web && python3 -m http.server 8080
# 手机同网段访问 http://<电脑IP>:8080/index.html
```

---

## 四、给未签名 IPA 签名安装

未签名 `.ipa` 不能直接装。任选其一：

| 工具 | 说明 | 是否需要付费 Apple ID |
|---|---|---|
| **Sideloadly**（Win/Mac） | 拖入 ipa + Apple ID，自动重签安装 | 免费即可（7 天有效，可重签） |
| **AltStore** | 自签商店，自动续签 | 免费即可 |
| **TrollStore** | 需设备存在 CoreTrust 漏洞（iOS 14–16.x 部分版本） | 不需要，永久签名 |
| **Xcode** | 打开工程直接 Run 到真机 | 免费即可 |

签名只需对 `.ipa` 里的 `Payload/QXZB.app` 重签，Bundle ID 可自定义（如 `com.yourname.qxzb`）。

---

## 五、单机化现状与后续

- **现在**：`log` 模式下 App 能正常加载游戏、联网可玩，同时把游戏所有服务端请求
  （XHR/fetch/WebSocket 的 URL、请求体、回包）打到你运行 App 时的日志里。这就是**协议采集**。
- **离线化**：用采集到的接口，在 `network_shim.js` 顶部的 `CFG.mock` 里按
  `"接口URL": "返回JSON"` 填好，再把模式切成 `mock`，即可断网运行。
  切换：`window.__qxzb.setMode('mock')`，或把默认模式改成 `mock`。

> 战斗结算/存档若为服务端权威，需要按采集到的协议在本地重放或重算，这是后续主要工作量。

---

## 六、常见问题

- **白屏/黑屏**：Xcode 控制台看 `[QXZB]` 日志；多半是 `web/` 没抓到或 `index.html` 缺失。
- **卡在加载**：看是否是游戏要连服务器（`log` 模式会打印目标 URL）；无网络时 game 会卡在登录。
- **改了 `project.yml` 不生效**：重新 `xcodegen generate`。
- **IPA 太大**：`web/` 全量约 500MB；可裁剪 `default.res.json` 中不用的资源组后再打包。

---

*本工程仅用于个人离线游玩与逆向学习。*
