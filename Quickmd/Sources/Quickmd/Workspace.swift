import Foundation

/// 工作区：管理「当前目录 + 快捷目录 + 目录内的 md 文件」。
///
/// 为什么单独一个文件：这三件事（记忆目录、扫描文件、给新文件起名）都是纯逻辑，
/// 不碰 UI、不碰面板，可以独立看懂、独立改。AppDelegate 只负责调度。
///
/// 持久化位置：`~/Documents/Quickmd/workspaces.json`
/// 用明文 JSON 而不是 UserDefaults——用户能自己看、自己备份、自己修，
/// 迁移机器时复制这个文件就带走了所有快捷目录。
final class Workspace {

    // MARK: - 数据模型

    struct FileEntry {
        let url: URL
        let name: String            // 不含 .md 后缀的显示名
        let modified: Date
        let size: Int
    }

    private struct Persisted: Codable {
        var current: String?
        var shortcuts: [String]
    }

    /// 配置文件位置
    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Quickmd/workspaces.json")
    }

    /// 默认工作目录（首次运行、配置损坏时的兜底）
    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Quickmd")
    }

    /// 当前浏览/编辑的目录。所有新建文件都落在这里。
    private(set) var currentDirectory: URL

    /// 快捷目录（用户钉住的常用文件夹，顺序即列表顺序）
    private(set) var shortcuts: [URL]

    private let fm = FileManager.default

    // MARK: - 初始化

    init() {
        let loaded = Self.loadPersisted()
        currentDirectory = loaded.current.map { URL(fileURLWithPath: $0) }
            ?? Self.defaultDirectory
        shortcuts = loaded.shortcuts.map { URL(fileURLWithPath: $0) }
        ensureDirectory(currentDirectory)
        // 首次运行（或配置被清空）时把当前目录钉进快捷目录：
        // 侧栏空着会让用户以为功能没生效，而默认目录本来就是他要待的地方。
        if shortcuts.isEmpty {
            shortcuts = [currentDirectory]
            persist()
        }
    }

    // MARK: - 持久化

    private static func loadPersisted() -> (current: String?, shortcuts: [String]) {
        guard let data = try? Data(contentsOf: configURL),
              let p = try? JSONDecoder().decode(Persisted.self, from: data) else {
            return (nil, [])
        }
        return (p.current, p.shortcuts)
    }

    func persist() {
        let payload = Persisted(current: currentDirectory.path,
                                shortcuts: shortcuts.map(\.path))
        do {
            try fm.createDirectory(at: Self.configURL.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(payload).write(to: Self.configURL, options: .atomic)
        } catch {
            // 持久化失败不应让 App 崩掉：下次启动退回默认目录而已。
            NSLog("Quickmd: 工作区配置写入失败 \(error.localizedDescription)")
        }
    }

    // MARK: - 目录

    @discardableResult
    private func ensureDirectory(_ url: URL) -> Bool {
        if fm.fileExists(atPath: url.path) { return true }
        return (try? fm.createDirectory(at: url, withIntermediateDirectories: true)) != nil
    }

    /// 切换当前目录。目录不存在时自动创建（选中一个刚被删掉的路径时会走到这里）。
    /// 切当前目录。
    ///
    /// `persist: false` 给诊断用：跑自检时会把目录切到临时目录，
    /// 要是也写进配置，用户下次启动就落在 /var/folders 里了（实测踩过）。
    func setCurrent(_ url: URL, persist shouldPersist: Bool = true) {
        currentDirectory = url
        ensureDirectory(url)
        if shouldPersist { persist() }
    }

    // MARK: - 快捷目录

    /// 添加快捷目录；已存在则提到最前（相当于「最近使用」下沉）。
    func addShortcut(_ url: URL) {
        shortcuts.removeAll { $0.path == url.path }
        shortcuts.insert(url, at: 0)
        persist()
    }

    func removeShortcut(_ url: URL) {
        shortcuts.removeAll { $0.path == url.path }
        persist()
    }

    func isShortcut(_ url: URL) -> Bool {
        shortcuts.contains { $0.path == url.path }
    }

    // MARK: - 文件列表

    /// 列出目录里的 Markdown 文件，按修改时间倒序（最近改的排最前）。
    /// 只认 .md / .markdown，跳过隐藏文件与子目录——侧栏不是文件管理器，
    /// 混进图片和附件只会让列表变噪音。
    func listMarkdown(in directory: URL? = nil) -> [FileEntry] {
        let dir = directory ?? currentDirectory
        guard let items = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return items.compactMap { url -> FileEntry? in
            let ext = url.pathExtension.lowercased()
            guard ext == "md" || ext == "markdown" else { return nil }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey,
                                                           .fileSizeKey,
                                                           .isRegularFileKey])
            guard values?.isRegularFile != false else { return nil }
            return FileEntry(url: url,
                             name: url.deletingPathExtension().lastPathComponent,
                             modified: values?.contentModificationDate ?? .distantPast,
                             size: values?.fileSize ?? 0)
        }.sorted { $0.modified > $1.modified }
    }

    // MARK: - 新建文件命名

    /// 从 Markdown 正文里取标题：第一个 `# ` 开头的行。
    /// 只认一级标题——正文里随手写的 `##` 小标题不该决定文件名。
    static func titleFromContent(_ md: String) -> String? {
        for raw in md.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("# ") else { continue }
            let title = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { return title }
        }
        return nil
    }

    /// 文件名清洗：去掉路径分隔符和冒号（冒号在 Finder 里显示为 `/`，
    /// 会被用户误认成目录），压缩连续空白，截断到 60 字（HFS+/APFS 上限 255 字节，
    /// 中文一个字 3 字节，60 字留足余量）。
    static func sanitize(_ raw: String) -> String {
        var s = raw
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        s = s.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        s = s.trimmingCharacters(in: .whitespaces)
        if s.count > 60 { s = String(s.prefix(60)).trimmingCharacters(in: .whitespaces) }
        // 纯点号或空串在文件系统里没意义
        if s.isEmpty || s.allSatisfy({ $0 == "." }) { return "" }
        return s
    }

    /// 按当天日期生成基础名：`2026-10-29`
    static func dateStamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// 为新文件决定路径：
    ///   有标题 → 用标题；没有 → 用日期。重名自动追加 `-2`、`-3`，绝不覆盖已有文件。
    func newFileURL(title: String?) -> URL {
        Self.uniqueURL(in: currentDirectory, title: title)
    }

    /// 纯函数版（不依赖实例），便于单测直接打临时目录。
    static func uniqueURL(in dir: URL, title: String?) -> URL {
        let cleaned = title.map(sanitize) ?? ""
        let base = cleaned.isEmpty ? dateStamp() : cleaned
        var candidate = dir.appendingPathComponent("\(base).md")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base)-\(n).md")
            n += 1
        }
        return candidate
    }

    /// 按标题算出改名的目标路径。
    /// 返回 nil 表示不用改（标题为空，或文件名已经就是它）。
    ///
    /// 这块会真的移动用户文件，所以单独抽出来测：
    /// 目标已存在时必须顺延成 `-2`，绝不能覆盖别人的笔记。
    static func titleTargetURL(from current: URL, title: String) -> URL? {
        let base = sanitize(title)
        guard !base.isEmpty else { return nil }
        if current.deletingPathExtension().lastPathComponent == base { return nil }
        let dir = current.deletingLastPathComponent()
        var dest = dir.appendingPathComponent("\(base).md")
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("\(base)-\(n).md")
            n += 1
        }
        return dest
    }
}
