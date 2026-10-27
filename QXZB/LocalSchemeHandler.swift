import Foundation
import WebKit

/// 通过自定义 scheme (qxzb://) 把 App bundle 内的 web/ 目录当站点提供，
/// 从而让页面里的相对路径 (./manifest.json、js/xxx.js、resource/xxx.png)
/// 以及 XHR(fetch/arraybuffer) 都能正常工作 —— 比 loadFileURL 更稳，规避 file:// 的 XHR 限制。
final class LocalSchemeHandler: NSObject, WKURLSchemeHandler {

    static let scheme = "qxzb"

    private let rootDir: URL
    private let rootPath: String

    init(rootDir: URL) {
        self.rootDir = rootDir.standardizedFileURL
        self.rootPath = rootDir.standardizedFileURL.path
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            fail(urlSchemeTask, url: nil, code: 400)
            return
        }

        var path = url.path
        if path.isEmpty || path == "/" { path = "/index.html" }
        // 去掉前导斜杠
        let rel = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let decoded = rel.removingPercentEncoding ?? rel

        var fileURL = rootDir.appendingPathComponent(decoded)
        // 目录 -> index.html
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir), isDir.boolValue {
            fileURL = fileURL.appendingPathComponent("index.html")
        }

        // 防目录穿越
        let std = fileURL.standardizedFileURL.path
        guard std.hasPrefix(rootPath) else {
            fail(urlSchemeTask, url: url, code: 403)
            return
        }

        guard let data = try? Data(contentsOf: fileURL) else {
            fail(urlSchemeTask, url: url, code: 404)
            return
        }

        let mime = LocalSchemeHandler.mimeType(for: fileURL.pathExtension)
        let headers: [String: String] = [
            "Content-Type": mime,
            "Content-Length": String(data.count),
            "Access-Control-Allow-Origin": "*",
            "Cache-Control": "no-cache"
        ]
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // 无需处理
    }

    private func fail(_ task: WKURLSchemeTask, url: URL?, code: Int) {
        let u = url ?? URL(string: "\(LocalSchemeHandler.scheme)://local/__404__")!
        let body = Data("not found \(code)".utf8)
        let resp = HTTPURLResponse(url: u, statusCode: code, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "text/plain",
                                                  "Access-Control-Allow-Origin": "*"])!
        task.didReceive(resp)
        task.didReceive(body)
        task.didFinish()
    }

    static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs":   return "application/javascript; charset=utf-8"
        case "json":        return "application/json; charset=utf-8"
        case "css":         return "text/css; charset=utf-8"
        case "png":         return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif":         return "image/gif"
        case "webp":        return "image/webp"
        case "svg":         return "image/svg+xml"
        case "mp3":         return "audio/mpeg"
        case "ogg":         return "audio/ogg"
        case "wav":         return "audio/wav"
        case "mp4", "m4a":  return "video/mp4"
        case "zip":         return "application/zip"
        case "ttf":         return "font/ttf"
        case "woff":        return "font/woff"
        case "woff2":       return "font/woff2"
        case "bin":         return "application/octet-stream"
        default:            return "application/octet-stream"
        }
    }
}
