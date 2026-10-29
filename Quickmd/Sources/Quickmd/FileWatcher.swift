import Foundation
import CoreServices

/// 监听一个目录里的文件变化（外部程序新建 / 修改 / 删除 / 改名）。
///
/// 为什么必须有它：Quickmd 现在能打开任意文件夹，而这些文件夹里的 .md
/// 同时被别的程序改——Obsidian、AI Agent、Finder 里的拖拽、甚至别的编辑器。
/// 没有监听时，磁盘上已经变了，Quickmd 内存里还是旧内容，下一次自动保存
/// 会**整文件覆盖**掉对方的改动，属于静默丢数据。
///
/// 实现选 FSEvents 而不是 `DispatchSource`：后者绑在单个文件描述符上，
/// 而原子写（`write(atomically:)`）是先写临时文件再 rename，inode 直接换掉，
/// 原来的 fd 就指向一个已经被替换的旧 inode，之后再也不会有事件。
/// FSEvents 监听的是目录这个「路径」，rename 也在它的观察范围内。
///
/// 零第三方依赖：直接用 CoreServices 的 C API。
final class FileWatcher {
    /// 变化通知。参数是发生变化的文件绝对路径集合（已去重）。
    var onChange: ((Set<String>) -> Void)?

    private var stream: FSEventStreamRef?
    private var watchedPath: String?

    /// 同一批事件的合并窗口。0.35 秒足够把「写临时文件 + rename」合成一次通知，
    /// 又不会让人等太久才看到外部改动。
    private let latency: CFTimeInterval = 0.35

    deinit { stop() }

    /// 开始监听某个目录。重复调用同一路径是空操作（避免重建流导致丢事件）。
    func start(directory: URL) {
        let path = directory.standardizedFileURL.path
        if watchedPath == path, stream != nil { return }
        stop()

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        let flags = UInt32(kFSEventStreamCreateFlagFileEvents
                           | kFSEventStreamCreateFlagUseCFTypes
                           | kFSEventStreamCreateFlagWatchRoot)

        // 回调是 C 函数指针，拿不到 self，只能通过 context.info 传回来。
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            // UseCFTypes 时 paths 是 CFArray，元素是 CFString
            guard let cfPaths = unsafeBitCast(paths, to: CFArray?.self) else { return }
            var changed = Set<String>()
            for i in 0..<count {
                guard let raw = CFArrayGetValueAtIndex(cfPaths, i) else { continue }
                let str = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
                changed.insert(str)
            }
            watcher.emit(changed)
        }

        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(flags)
        ) else {
            NSLog("Quickmd: 文件监听创建失败 \(path)")
            return
        }

        // 回调在后台队列触发；真正处理统一丢回主线程，
        // 免得 UI 状态在后台线程被改。
        FSEventStreamSetDispatchQueue(s, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(s)
        stream = s
        watchedPath = path
        NSLog("Quickmd: 开始监听 \(path)")
    }

    func stop() {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
        stream = nil
        watchedPath = nil
    }

    private func emit(_ paths: Set<String>) {
        guard !paths.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onChange?(paths)
        }
    }
}
