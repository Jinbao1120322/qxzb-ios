import Foundation
import Network

/// 内置极简 HTTP/1.1 静态文件服务器（127.0.0.1 随机端口）。
///
/// 为什么不用 WKURLSchemeHandler：
///   - 自定义 scheme 下 WKWebView 的 XHR + responseType=arraybuffer 在真机上会失败，
///     而 Egret 引擎拉 js.zip / *.bin 全靠 arraybuffer；
///   - 自定义 scheme 的 origin 拿不到 localStorage，Egret 启动即抛 SecurityError。
/// 用真实 http origin 后，这两个问题一起消失。
final class LocalHTTPServer {

    static let shared = LocalHTTPServer()

    private(set) var port: UInt16 = 0
    private var root: URL = URL(fileURLWithPath: "/")
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "qxzb.http.server", qos: .userInitiated)
    private var reported = false

    var baseURL: URL? {
        guard port > 0 else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/")
    }

    func start(root: URL, completion: @escaping (UInt16?) -> Void) {
        self.root = root.standardizedFileURL
        do {
            let l = try NWListener(using: .tcp)
            l.newConnectionHandler = { [weak self] conn in
                self?.handle(conn)
            }
            l.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    self.port = l.port?.rawValue ?? 0
                    QLog("HTTP server ready port=\(self.port) root=\(self.root.path)")
                    completion(self.port)
                case .failed(let err):
                    QLog("HTTP server failed: \(err)")
                    completion(nil)
                case .cancelled:
                    QLog("HTTP server cancelled")
                default:
                    break
                }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            QLog("HTTP server create error: \(error)")
            completion(nil)
        }
    }

    // MARK: - 连接处理

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        readRequest(conn, buffer: Data())
    }

    private func readRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            var buf = buffer
            if let data = data { buf.append(data) }

            if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[..<range.lowerBound], as: UTF8.self)
                self.respond(conn, header: head)
                return
            }
            if isComplete || error != nil || buf.count > 2 * 1024 * 1024 {
                conn.cancel()
                return
            }
            self.readRequest(conn, buffer: buf)
        }
    }

    private func respond(_ conn: NWConnection, header: String) {
        let lines = header.split(separator: "\r\n", omittingEmptySubsequences: false)
        let requestLine = lines.first.map(String.init) ?? ""
        let parts = requestLine.split(separator: " ").map(String.init)
        guard parts.count >= 2 else { return sendError(conn, 400) }
        let method = parts[0].uppercased()
        var path = parts[1]

        if let i = path.firstIndex(of: "?") { path = String(path[..<i]) }
        if let i = path.firstIndex(of: "#") { path = String(path[..<i]) }
        path = path.removingPercentEncoding ?? path
        if path.isEmpty || path == "/" { path = "/index.html" }

        let rel = path.hasPrefix("/") ? String(path.dropFirst()) : path
        var fileURL = root.appendingPathComponent(rel)

        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir), isDir.boolValue {
            fileURL.appendPathComponent("index.html")
        }
        // 防目录穿越
        guard fileURL.standardizedFileURL.path.hasPrefix(root.path) else {
            return sendError(conn, 403)
        }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              FileManager.default.fileExists(atPath: fileURL.path) else {
            QLog("404 \(path)")
            return sendError(conn, 404)
        }

        let mime = LocalHTTPServer.mimeType(fileURL.pathExtension)
        let head = """
        HTTP/1.1 200 OK\r
        Content-Type: \(mime)\r
        Content-Length: \(size)\r
        Access-Control-Allow-Origin: *\r
        Cache-Control: no-cache\r
        Connection: close\r
        \r

        """
        conn.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] err in
            if err != nil { conn.cancel(); return }
            if method == "HEAD" { conn.cancel(); return }
            self?.sendFile(conn, url: fileURL)
        })
    }

    private func sendFile(_ conn: NWConnection, url: URL) {
        guard let fh = try? FileHandle(forReadingFrom: url) else {
            conn.cancel()
            return
        }
        sendChunk(conn, handle: fh)
    }

    private func sendChunk(_ conn: NWConnection, handle: FileHandle) {
        // iOS 13 兼容写法（read(upToCount:) 需要 13.4+）
        let chunk = handle.readData(ofLength: 256 * 1024)
        if chunk.isEmpty {
            try? handle.close()
            conn.cancel()
            return
        }
        conn.send(content: chunk, completion: .contentProcessed { [weak self] err in
            if err != nil {
                try? handle.close()
                conn.cancel()
                return
            }
            self?.sendChunk(conn, handle: handle)
        })
    }

    private func sendError(_ conn: NWConnection, _ code: Int) {
        let body = "error \(code)"
        let head = """
        HTTP/1.1 \(code) Error\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r

        """
        conn.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    static func mimeType(_ ext: String) -> String {
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
        case "fnt":         return "application/octet-stream"
        case "bin":         return "application/octet-stream"
        default:            return "application/octet-stream"
        }
    }
}
