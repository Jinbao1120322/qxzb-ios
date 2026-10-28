import Foundation

/// 全局日志汇聚：原生 + JS 都往这里写，ViewController 把它显示在屏内浮层上。
final class QLogCenter {
    static let shared = QLogCenter()
    private let lock = NSLock()
    private var buffer: [String] = []
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var onAppend: ((String) -> Void)?

    func append(_ raw: String) {
        lock.lock()
        let line = "[\(formatter.string(from: Date()))] \(raw)"
        buffer.append(line)
        if buffer.count > 400 { buffer.removeFirst(buffer.count - 400) }
        let handler = onAppend
        lock.unlock()
        handler?(line)
    }

    func dump() -> String {
        lock.lock()
        let s = buffer.joined(separator: "\n")
        lock.unlock()
        return s
    }
}

/// 用法：QLog("xxx")
func QLog(_ message: String) {
    print("[QXZB] \(message)")
    QLogCenter.shared.append(message)
}
