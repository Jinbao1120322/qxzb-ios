import UIKit
import WebKit

final class ViewController: UIViewController {

    private var webView: WKWebView!
    private var schemeHandler: LocalSchemeHandler?
    private let logTag = "[QXZB]"

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupWebView()
        loadLocalGame()
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    private func setupWebView() {
        guard let webRoot = Bundle.main.url(forResource: "web", withExtension: nil) else {
            showFatal("App bundle 中缺少 web/ 目录，构建时未打包 H5 资源。")
            return
        }
        print("\(logTag) webRoot = \(webRoot.path)")

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        if #available(iOS 10.0, *) {
            config.mediaTypesRequiringUserActionForPlayback = []
        }
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        // 自定义 scheme，把 web/ 当站点提供
        schemeHandler = LocalSchemeHandler(rootDir: webRoot)
        config.setURLSchemeHandler(schemeHandler!, forURLScheme: LocalSchemeHandler.scheme)

        // 注入网络垫片（单机化：拦截发往游戏服务器的 XHR/fetch/WebSocket）
        let ucc = config.userContentController
        if let shimURL = Bundle.main.url(forResource: "network_shim", withExtension: "js"),
           let shim = try? String(contentsOf: shimURL, encoding: .utf8) {
            let script = WKUserScript(source: shim,
                                      injectionTime: .atDocumentStart,
                                      forMainFrameOnly: false)
            ucc.addUserScript(script)
            print("\(logTag) network_shim.js injected (\(shim.count) bytes)")
        } else {
            print("\(logTag) WARN: network_shim.js not found in bundle")
        }

        // 接收 JS 侧日志（shim 里通过 window.webkit.messageHandlers.log 上报）
        ucc.add(LogHandler(tag: logTag), name: "log")

        webView = WKWebView(frame: view.bounds, configuration: config)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.scrollView.bounces = false
        webView.scrollView.isScrollEnabled = true
        webView.allowsBackForwardNavigationGestures = false
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        if #available(iOS 11.0, *) {
            webView.scrollView.contentInsetAdjustmentBehavior = .never
        }
        view.addSubview(webView)
    }

    private func loadLocalGame() {
        guard webView != nil else { return }
        let url = URL(string: "\(LocalSchemeHandler.scheme)://local/index.html")!
        print("\(logTag) loading \(url.absoluteString)")
        webView.load(URLRequest(url: url))
    }

    private func showFatal(_ msg: String) {
        let label = UILabel(frame: view.bounds)
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .white
        label.text = msg
        view.addSubview(label)
    }
}

// MARK: - Navigation
extension ViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        print("\(logTag) page didFinish")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("\(logTag) didFail: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        print("\(logTag) didFailProvisional: \(error.localizedDescription)")
    }
}

// MARK: - JS alert/confirm
extension ViewController: WKUIDelegate {
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        completionHandler(defaultText)
    }
}

// MARK: - JS log bridge
final class LogHandler: NSObject, WKScriptMessageHandler {
    private let tag: String
    init(tag: String) { self.tag = tag }
    func userContentController(_ userContentController: WKUserContentController,
                              didReceive message: WKScriptMessage) {
        print("\(tag) JS: \(message.body)")
    }
}
