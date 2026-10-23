import Foundation

/// 当前文档的读写。
///
/// 职责单一：记住「现在是哪个文件」，负责读和写。写盘一律原子写
/// （`atomically`），避免断电或崩溃时留下半截文件。
///
/// 防抖只在 JS 端做一次（200ms），Swift 收到消息后立即原子写盘。
final class DocumentStore {
    private(set) var url: URL
    private let fileManager = FileManager.default

    init(defaultURL: URL) {
        url = defaultURL
    }

    /// 读取当前文档内容；文件不存在或读失败时返回空串
    func read() -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// 写入当前文档。失败由调用方记日志。
    func write(_ content: String) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// 切换当前文档（切换前调用方应先把旧文档落盘）
    func move(to newURL: URL) {
        url = newURL
    }

    /// 文档所在目录
    var directory: URL { url.deletingLastPathComponent() }
}
