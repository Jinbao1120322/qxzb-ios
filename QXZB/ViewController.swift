import UIKit
import WebKit

final class ViewController: UIViewController {

    private var webView: WKWebView!
    private let logView = UITextView()
    private var logLines: [String] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        setupLogOverlay()
        QLogCenter.shared.onAppend = { [weak self] line in
            DispatchQueue.main.async { self?.appendLog(line) }
        }

        boot()
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    // MARK: - 启动流程

    private func boot() {
        QLog("app boot, iOS \(UIDevice.current.systemVersion)")

        guard let webRoot = Bundle.main.url(forResource: "web", withExtension: nil) else {
            QLog("FATAL: bundle 内缺少 web/ 目录")
            return
        }
        QLog("web root = \(webRoot.path)")

        LocalHTTPServer.shared.start(root: webRoot) { [weak self] port in
            guard let self = self else { return }
            guard let port = port, port > 0 else {
                QLog("FATAL: 本地 HTTP 服务启动失败")
                return
            }
            DispatchQueue.main.async {
                self.setupWebView()
                let url = URL(string: "http://127.0.0.1:\(port)/index.html")!
                QLog("loading \(url.absoluteString)")
                self.webView.load(URLRequest(url: url))
            }
        }
    }

    private func setupWebView() {
        guard webView == nil else { return }

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        if #available(iOS 10.0, *) {
            config.mediaTypesRequiringUserActionForPlayback = []
        }
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.websiteDataStore = .default()

        let ucc = config.userContentController
        ucc.add(LogHandler(), name: "log")

        for name in ["console_shim", "network_shim"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "js"),
                  let src = try? String(contentsOf: url, encoding: .utf8) else {
                QLog("WARN: \(name).js 未打包进 bundle")
                continue
            }
            ucc.addUserScript(WKUserScript(source: src,
                                           injectionTime: .atDocumentStart,
                                           forMainFrameOnly: false))
            QLog("injected \(name).js (\(src.count) bytes)")
        }

        webView = WKWebView(frame: view.bounds, configuration: config)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.scrollView.bounces = false
        webView.allowsBackForwardNavigationGestures = false
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        if #available(iOS 11.0, *) {
            webView.scrollView.contentInsetAdjustmentBehavior = .never
        }
        view.addSubview(webView)
        view.bringSubviewToFront(logView)
    }

    // MARK: - 屏内日志（截图即可定位卡点）

    private func setupLogOverlay() {
        logView.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: view.bounds.height * 0.55)
        logView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        logView.backgroundColor = UIColor.black.withAlphaComponent(0.70)
        logView.textColor = .white
        logView.font = UIFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        logView.isEditable = false
        logView.isSelectable = false
        logView.textContainerInset = UIEdgeInsets(top: 30, left: 6, bottom: 6, right: 6)
        logView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(toggleLog)))
        view.addSubview(logView)
    }

    @objc private func toggleLog() {
        logView.isHidden = !logView.isHidden
    }

    private func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > 140 { logLines.removeFirst(logLines.count - 140) }
        logView.text = logLines.joined(separator: "\n")
        let len = (logView.text as NSString).length
        logView.scrollRangeToVisible(NSRange(location: len, length: 0))
        if !logView.isHidden { view.bringSubviewToFront(logView) }
    }
}

// MARK: - Navigation

extension ViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        QLog("nav start")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        QLog("nav didFinish")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        QLog("nav didFail: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        QLog("nav didFailProvisional: \(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        QLog("web content process terminated (可能 OOM)，即将 reload")
        webView.reload()
    }
}

// MARK: - JS alert/confirm

extension ViewController: WKUIDelegate {
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        QLog("JS alert: \(message)")
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
    func userContentController(_ userContentController: WKUserContentController,
                              didReceive message: WKScriptMessage) {
        QLogCenter.shared.append("JS \(message.body)")
    }
}
