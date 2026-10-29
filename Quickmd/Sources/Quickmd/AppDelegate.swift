import AppKit
import WebKit

/// App 组装与生命周期：把各个零件串起来，并管理面板的两态切换。
///
/// 交互模型（v3 与 v2 一致）：
///   鼠标移到屏幕顶部刘海热区 → 面板滑出（被动预览，不抢键盘焦点）
///   点击面板 → 激活、接管键盘并「钉住」（不再因鼠标移开而消失）
///   Esc 关闭并存盘；菜单栏图标提供手动开关、打开文件、开机自启
///
/// 数据落盘在 ~/Documents/Quickmd/*.md，纯 Markdown 文件是唯一真相源。
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - 组件

    private let trigger = NotchTrigger()
    private let store: DocumentStore
    private var bridge: Bridge!
    private let statusMenu = StatusMenu()
    /// 在 init 里创建：需要先读它的快捷目录，才能决定打开哪个文档。
    private var workspace: Workspace!

    private var panel: NotchPanel!
    private var container: PanelContainerView!
    private var webView: WKWebView!

    // MARK: - 面板形态

    /// 两种形态，尺寸差很大，所以不能用一个常量。
    ///
    /// - `capture`：刘海快捕小卡片，330x285，实测对齐系统快速备忘录。
    ///   浏海一碰就出、只负责「写」，不打断当前工作。
    /// - `browse`：文件浏览态，680x520。访达式的「侧栏 + 正文」在
    ///   330pt 宽度里根本排不开（侧栏最少要 200pt），所以必须放大。
    ///   放大后不再是「抬头看一眼」的尺寸，因此只在用户主动展开时进入。
    enum PanelMode {
        case capture, browse
        var size: NSSize {
            switch self {
            case .capture: return NSSize(width: 330, height: 285)
            case .browse:  return NSSize(width: 680, height: 520)
            }
        }
    }

    private var panelMode: PanelMode = .capture
    /// 兼容旧代码里的 panelSize 引用（诊断脚本、点击测试坐标都基于它）
    private var panelSize: NSSize { panelMode.size }

    // MARK: - 状态

    private var panelVisible = false
    private var panelIsActive = false
    private var isPinned = false
    private var editorReady = false
    private var pendingContent: String?
    /// 诊断态：跑前端自检时不写盘，避免测试内容覆盖真实笔记
    private var diagnosticsReadOnly = false
    private var isDevelopmentMode: Bool { CommandLine.arguments.contains("--dev") }

    // MARK: - 外部改动监听
    //
    // 打开的是普通文件夹，里面的 .md 随时可能被 Obsidian / AI Agent / Finder 改动。
    // 没有监听的话，磁盘变了内存不知道，下一次自动保存就把对方的改动整文件覆盖掉。
    private let fileWatcher = FileWatcher()
    /// 自己刚写盘的时间。原子写会产生 rename 事件，不设抑制窗口就会「自己监听自己」
    /// 反复重载。窗口取 1.2 秒：大于一次写盘 + 事件投递的往返，又短于人手操作间隔。
    private var lastSelfWriteAt = Date.distantPast
    private let selfWriteWindow: TimeInterval = 1.2
    /// 当前文件被外部删掉了：此时再写盘会把文件「复活」成幽灵文件，必须停写。
    private var currentFileRemovedExternally = false

    // MARK: - 生命周期

    override init() {
        // 启动时打开「快捷目录里的第一个目录」里最近改过的 md；
        // 没有就开一个当天空文档（文件名先用日期，写了 # 标题会自动改名）。
        let ws = Workspace()
        workspace = ws
        let initialURL: URL
        var seedForTitle: URL?
        if let recent = ws.listMarkdown().first {
            initialURL = recent.url
        } else {
            initialURL = ws.newFileURL(title: nil)
            seedForTitle = initialURL
        }
        store = DocumentStore(defaultURL: initialURL)
        super.init()
        pendingTitleAdoption = seedForTitle
        // Bridge 用弱引用指回 AppDelegate，避免 WKUserContentController
        // 强持有 AppDelegate 形成引用环（v2 的隐患）
        bridge = Bridge()
        bridge.delegate = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)          // 不占程序坞
        setupPanel()
        setupWebView()
        setupStatusMenu()
        setupTriggers()
        configureLaunchAtLogin()
        setupWorkspaceWatcher()
        loadStoreIntoEditor()

        runDiagnosticsIfRequested()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 退出前强制落盘，避免最后几个字丢在内存里
        flushSave()
    }

    // MARK: - 面板与 WebView

    private func setupPanel() {
        panel = NotchPanel(contentRect: NSRect(origin: .zero, size: panelSize),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        panel.level = .statusBar + 2
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        panel.delegate = self

        container = PanelContainerView(frame: NSRect(origin: .zero, size: panelSize))
        container.wantsLayer = true
        container.layer?.cornerRadius = 14            // 备忘录式大圆角
        // 不开 masksToBounds：容器要负责投影，裁剪会让阴影消失。
        // WebView 的圆角由它自己的 layer 单独处理。
        container.layer?.masksToBounds = false
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        container.onClick = { [weak self] in self?.activatePanel() }

        panel.contentView = container

        // 边缘补一圈发丝线，让卡片在任意底色的桌面上都有清晰边界（备忘录质感）
        container.layer?.borderWidth = 0.5
        container.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor
    }

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        config.userContentController.add(bridge, name: "quickmd")

        let wv = EditorWebView(frame: container.bounds, configuration: config)
        wv.navigationDelegate = self
        wv.setValue(false, forKey: "drawsBackground")
        wv.autoresizingMask = [.width, .height]
        wv.allowsMagnification = false
        // 固定浅色外观：编辑器不跟随系统深浅色，任何主题下都是同一张暖纸面
        wv.appearance = NSAppearance(named: .aqua)
        // WebView 自己裁圆角（容器不裁，因为容器要留投影）
        wv.wantsLayer = true
        wv.layer?.cornerRadius = 14
        wv.layer?.masksToBounds = true
        // 点击 WebView 内容 = 点击面板：先激活拿键盘，再让 WebKit 处理点击落点
        wv.onActivateClick = { [weak self] in self?.activatePanel(fromClick: true) }
        webView = wv
        container.addSubview(wv)

        guard let html = Bundle.module.url(forResource: "editor", withExtension: "html") else {
            log("错误：找不到 editor.html 资源")
            return
        }
        // 允许读整个用户目录：正文里引用的图片是 file:// 绝对路径，
        // 页面本身在 App 资源包里，不给放行范围 WebKit 会拒载。
        // 风险可控——加载的 HTML 是本机资源，正文中的 HTML 已在 inline() 里全量转义。
        wv.loadFileURL(html, allowingReadAccessTo: FileManager.default.homeDirectoryForCurrentUser)
    }

    // MARK: - 开机自启

    /// 普通启动首次开启开机自启；开发脚本启动时关闭，避免调试版本常驻登录项。
    /// 开发模式暂存原状态；普通启动时恢复，保留用户之前的选择。
    private func configureLaunchAtLogin() {
        let key = "quickmd.launchAtLoginInitialized"
        let restoreKey = "quickmd.launchAtLoginBeforeDevelopment"
        let initializedBeforeDevelopmentKey = "quickmd.launchAtLoginInitializedBeforeDevelopment"
        let defaults = UserDefaults.standard
        let loginItem = LoginItemController()

        if isDevelopmentMode {
            if defaults.object(forKey: restoreKey) == nil {
                defaults.set(loginItem.isEnabled, forKey: restoreKey)
                defaults.set(defaults.bool(forKey: key), forKey: initializedBeforeDevelopmentKey)
            }
            _ = loginItem.setEnabled(false)
            statusMenu.rebuild()
            log("开发模式：暂时关闭开机自启；普通启动时恢复原设置")
            return
        }

        if let wasEnabled = defaults.object(forKey: restoreKey) as? Bool {
            let wasInitialized = defaults.bool(forKey: initializedBeforeDevelopmentKey)
            defaults.removeObject(forKey: restoreKey)
            defaults.removeObject(forKey: initializedBeforeDevelopmentKey)

            if wasInitialized {
                _ = loginItem.setEnabled(wasEnabled)
            } else {
                // 如果开发模式之前从未正常启动，首次正常启动仍按默认开启处理。
                _ = loginItem.setEnabled(true)
            }
            defaults.set(true, forKey: key)
            statusMenu.rebuild()
            log("普通启动：已恢复开机自启设置")
            return
        }

        guard !defaults.bool(forKey: key) else { return }
        defaults.set(true, forKey: key)
        let ok = loginItem.setEnabled(true)
        log("首次运行：开机自启\(ok ? "已开启" : "开启失败")")
    }

    // MARK: - 菜单栏

    private func setupStatusMenu() {
        statusMenu.onTogglePanel = { [weak self] in self?.togglePanel() }
        statusMenu.onOpenFile = { [weak self] in self?.openDocumentViaPanel() }
        statusMenu.onBrowse = { [weak self] in
            guard let self else { return }
            self.showPanelIfNeeded()
            self.activatePanel()
            self.setPanelMode(.browse)
        }
        statusMenu.onChooseFolder = { [weak self] in
            guard let self else { return }
            self.showPanelIfNeeded()
            self.activatePanel()
            self.chooseFolder()
        }
    }

    // MARK: - 触发

    private func setupTriggers() {
        trigger.panelFrameProvider = { [weak self] in self?.panel.frame }
        trigger.onEnterHotZone = { [weak self] in self?.showPanelIfNeeded() }
        trigger.onLeaveStayRegion = { [weak self] in self?.hidePanelIfNeeded() }
        trigger.start()

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            if ev.keyCode == 53 { self?.hidePanelIfNeeded(); return nil }   // Esc
            return ev
        }
    }

    // MARK: - 面板显示 / 隐藏 / 激活

    private func showPanelIfNeeded() {
        guard !panelVisible else { return }
        positionPanelAtNotch()
        panel.allowsKeyActivation = false
        panel.orderFrontRegardless()                  // 不激活 App，不抢焦点
        panelVisible = true
        log("面板显示 frame=\(panel.frame) isActive=\(NSApp.isActive)")
    }

    /// 激活面板并接管键盘。
    /// - Parameter fromClick: true 表示由面板内的点击触发。此时不能抢焦点——
    ///   WebKit 自己会根据点击位置落光标，强行 focus 第一块会把用户点的地方跳回首块。
    private func activatePanel(fromClick: Bool = false) {
        guard panelVisible, !panelIsActive else { return }
        panel.allowsKeyActivation = true
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panelIsActive = true
        isPinned = true
        trigger.isPinned = true
        panel.makeFirstResponder(webView)
        if !fromClick { focusEditor() }
        log("面板激活 fromClick=\(fromClick)")
    }

    private func hidePanelIfNeeded() {
        guard panelVisible else { return }
        flushSave()
        panel.orderOut(nil)
        panelVisible = false
        panelIsActive = false
        isPinned = false
        trigger.isPinned = false
        panel.allowsKeyActivation = false
        log("面板收起")
    }

    private func togglePanel() {
        if panelVisible { hidePanelIfNeeded() }
        else { showPanelIfNeeded(); activatePanel() }
    }

    // MARK: - 屏幕与刘海几何

    /// 把面板贴到刘海下方。两种形态尺寸不同，所以每次都重算 frame 而不是只挪位置；
    /// 浏览态比刘海宽得多，边缘要夹一下，否则在窄屏/副屏上会跑出屏幕。
    private func positionPanelAtNotch() {
        guard let screen = trigger.builtInScreen() else { return }
        let size = panelMode.size
        let margin: CGFloat = 12
        let idealX = trigger.notchCenterX(for: screen) - size.width / 2
        let x = max(screen.frame.minX + margin,
                    min(idealX, screen.frame.maxX - size.width - margin))
        // 顶边贴在刘海下沿（再减 safeAreaInsets.top），否则 32pt 深的刘海会盖住正文
        let y = screen.frame.maxY - screen.safeAreaInsets.top - size.height
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    /// 切换面板形态。浏览态会同时刷新侧栏数据（用户展开就是为了看文件列表）。
    private func setPanelMode(_ mode: PanelMode) {
        guard panelMode != mode else {
            if mode == .browse { pushWorkspaceToEditor() }
            return
        }
        panelMode = mode
        if panelVisible { positionPanelAtNotch() }
        container.layoutSubtreeIfNeeded()
        webView.evaluateJavaScript(
            "window.QN && window.QN.setMode(\(jsonString(mode == .browse ? "browse" : "capture")));")
        if mode == .browse { pushWorkspaceToEditor() }
        log("面板形态 -> \(mode == .browse ? "browse" : "capture") frame=\(panel.frame)")
    }

    // MARK: - 文档读写

    private func loadStoreIntoEditor() {
        currentFileRemovedExternally = false          // 换了文件就重新给一次写盘机会
        let content = store.read()
        if editorReady {
            pushToEditor(content, file: store.url.lastPathComponent)
        } else {
            pendingContent = content                          // 等编辑器 ready 再推
        }
    }

    private func pushToEditor(_ content: String, file: String) {
        let js = "window.QN && window.QN.load(\(jsonString(content)), \(jsonString(file)), "
               + "\(jsonString(store.directory.path)));"
        webView.evaluateJavaScript(js)
    }

    /// 粘贴/拖入的图片落到文档同目录的 `assets/` 下。
    ///
    /// 为什么放 `assets/` 而不是内联 base64：内联会让 md 文件膨胀几十倍，
    /// 而 .md 是纯文本、要能进 Git、要能被别的编辑器打开。
    /// 为什么用相对路径：文件连同 assets 一起搬走，图片不会断。
    private func saveImage(named rawName: String, base64: String) {
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
            log("图片解码失败"); return
        }
        var ext = (rawName as NSString).pathExtension.lowercased()
        if ext.isEmpty || ext.count > 5 { ext = "png" }
        let assetsDir = store.directory.appendingPathComponent("assets")
        try? FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let file = assetsDir.appendingPathComponent("img-\(stamp).\(ext)")
        do {
            try data.write(to: file, options: .atomic)
        } catch {
            log("图片写入失败: \(error.localizedDescription)"); return
        }
        let rel = "assets/\(file.lastPathComponent)"
        webView.evaluateJavaScript("window.QN && window.QN.insertImage(\(jsonString(rel)));")
        log("图片已保存 \(rel)")
    }

    private func focusEditor() {
        webView.evaluateJavaScript(
            "(function(){var b=document.querySelector('.qn-block'); if(b){b.focus();}})()")
    }

    /// 立即落盘（收起面板 / 切换文档 / 退出时调用，防止最后输入未写入）。
    /// 防抖已在 JS 端做，这里不再叠加延迟。
    private func flushSave() {
        guard editorReady else { return }
        let target = store.url                 // 捕获此刻的目标文件
        webView.evaluateJavaScript("window.QN && window.QN.getMarkdown ? window.QN.getMarkdown() : ''") {
            [weak self] result, _ in
            guard let self, let md = result as? String else { return }
            // 读内容这一来一回期间文档可能已经切换，此时这次保存已过时
            guard self.store.url == target else {
                self.log("跳过过期落盘 \(target.lastPathComponent)")
                return
            }
            guard !self.currentFileRemovedExternally else {
                self.log("跳过落盘：\(target.lastPathComponent) 已被外部删除")
                return
            }
            do {
                self.lastSelfWriteAt = Date()
                try md.write(to: target, atomically: true, encoding: .utf8)
                self.log("已保存 \(target.lastPathComponent)")
            } catch {
                self.log("保存失败: \(error.localizedDescription)")
            }
        }
    }

    private func openDocumentViaPanel() {
        let open = NSOpenPanel()
        open.allowedContentTypes = [.init(filenameExtension: "md")!]
        open.allowsMultipleSelection = false
        open.canChooseDirectories = false
        open.directoryURL = store.directory
        if open.runModal() == .OK, let url = open.url { switchDocument(to: url) }
    }

    // MARK: - 工作区：目录 / 文件列表 / 新建

    /// 新建时如果还没定名，记住「这个文件等着被标题改名」。
    /// 用户敲出 `# 标题` 后自动把 `2026-10-29.md` 变成 `标题.md`，只改一次。
    /// 用「延迟定名」而不是「新建时弹输入框」：多一个弹框就多一次打断，
    /// 而写便签的人通常标题是后补的（甚至不写）。
    private var pendingTitleAdoption: URL?

    // MARK: - 外部改动监听

    private func setupWorkspaceWatcher() {
        fileWatcher.onChange = { [weak self] paths in
            self?.handleExternalChanges(paths)
        }
        watchCurrentDirectory()
    }

    /// 监听当前工作目录。切目录后要重调，否则还在听旧目录。
    private func watchCurrentDirectory() {
        fileWatcher.start(directory: workspace.currentDirectory)
    }

    /// 统一的写盘入口。
    ///
    /// 所有落盘都要走这里，不能直接 `store.write`——只有这里会记住「我刚写过」，
    /// 外部监听才分得清「磁盘变了是我自己写的」和「磁盘变了是别人改的」。
    @discardableResult
    private func writeCurrent(_ md: String) -> Bool {
        guard !currentFileRemovedExternally else {
            log("跳过写盘：\(store.url.lastPathComponent) 已被外部删除")
            return false
        }
        lastSelfWriteAt = Date()
        do {
            try store.write(md)
            return true
        } catch {
            log("保存失败: \(error.localizedDescription)")
            return false
        }
    }

    /// 目录里发生了文件变动。可能是别的程序改了当前笔记，也可能是新建/删除/改名。
    private func handleExternalChanges(_ paths: Set<String>) {
        guard !diagnosticsReadOnly else { return }

        // 路径必须做一次「解析符号链接」再比：FSEvents 报的是内核视角的真实路径，
        // 而 NSTemporaryDirectory() 这类地方给的是 /var/...，真实路径是 /private/var/...，
        // standardizedFileURL 不处理这个链接，不解析就会漏事件（删除事件实测就漏了）。
        // 路径必须先统一再比：FSEvents 报的是内核视角的真实路径（/private/var/...），
        // 而 NSTemporaryDirectory() 这类地方给的是 /var/...。两者是同一个目录，
        // 但字符串不相等。实测「删除事件」就是因为这个差异被漏掉的。
        // 注意不能用 resolvingSymlinksInPath()——文件已被删除时它解不出符号链接。
        let normalized = Set(paths.map { Self.canonicalPath($0) })
        let currentPath = Self.canonicalPath(store.url.path)
        let dirPath = Self.canonicalPath(workspace.currentDirectory.path)
        log("文件事件: " + normalized.sorted().joined(separator: " | "))

        // 有新 .md 出现 / 文件增删改名 → 文件列表必然要刷（目录本身也可能被删）
        let markdownOnly = normalized.filter { $0.lowercased().hasSuffix(".md") }
        if !markdownOnly.isEmpty || normalized.contains(dirPath) {
            pushWorkspaceToEditor()
        }

        guard normalized.contains(currentPath) else { return }

        // 自己写盘的回声：内容本来就一样，重载只会把光标打回开头
        if Date().timeIntervalSince(lastSelfWriteAt) < selfWriteWindow { return }

        guard FileManager.default.fileExists(atPath: store.url.path) else {
            // 文件被外部删了。此时绝不能按原路径再写，否则收集箱里会多出
            // 一条「处理过的笔记」的幽灵副本。
            currentFileRemovedExternally = true
            log("当前文件已被外部删除：\(store.url.lastPathComponent)")
            webView.evaluateJavaScript("window.QN && window.QN.setNotice('磁盘已删除');")
            return
        }

        let disk = store.read()
        webView.evaluateJavaScript("window.QN ? window.QN.getMarkdown() : ''") { [weak self] result, _ in
            guard let self else { return }
            let memory = (result as? String) ?? ""
            guard disk != memory else { return }        // 内容一致，不用重载
            self.pushToEditor(disk, file: self.store.url.lastPathComponent)
            self.log("检测到外部改动，已重新载入 \(self.store.url.lastPathComponent)")
        }
    }

    /// 把当前目录、文件列表、快捷目录推给前端。
    /// 每次切换目录、新建、删除、重命名之后都要调——前端不做增量，
    /// 全量重推最简单也最不容易状态错乱（一个目录几百个文件，开销可忽略）。
    private func pushWorkspaceToEditor() {
        // 目录可能刚被切过，顺手把监听换到新目录（同目录时是空操作）
        watchCurrentDirectory()
        // 所有路径都过一遍 canonicalPath：`contentsOfDirectory` 返回的 URL 是
        // /private/var/... 形式，而 store.url / 快捷目录里存的是 /var/...，
        // 前端用字符串比对「哪个是当前文件」，不统一就永远对不上（实测高亮丢失）。
        let files = workspace.listMarkdown().map { f -> [String: Any] in
            ["path": Self.canonicalPath(f.url.path),
             "name": f.name,
             "modified": f.modified.timeIntervalSince1970,
             "size": f.size]
        }
        let shortcuts = workspace.shortcuts.map {
            ["path": Self.canonicalPath($0.path),
             "name": $0.lastPathComponent.isEmpty ? $0.path : $0.lastPathComponent]
        }
        let dirName = workspace.currentDirectory.lastPathComponent
        let payload: [String: Any] = [
            "dir": Self.canonicalPath(workspace.currentDirectory.path),
            "dirName": dirName.isEmpty ? workspace.currentDirectory.path : dirName,
            "files": files,
            "shortcuts": shortcuts,
            "current": Self.canonicalPath(store.url.path),
            "mode": panelMode == .browse ? "browse" : "capture"
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.QN && window.QN.setWorkspace(\(json));")
    }

    /// 切文档。
    ///
    /// 顺序很重要：必须**先**把当前编辑器的内容落盘，**再**换 url。
    /// 原来的实现是 flushSave() 后立刻 move(URL)，而 flushSave 走的是
    /// evaluateJavaScript 异步回调——回调回来时 store.url 已经指向新文件，
    /// 旧文档最后几个字会写进新文件里。这里改成回调里再切。
    private func switchDocument(to url: URL, then completion: (() -> Void)? = nil) {
        let target = url.standardizedFileURL
        guard Self.canonicalPath(target.path) != Self.canonicalPath(store.url.path) else {
            pushWorkspaceToEditor()
            completion?()
            return
        }
        guard editorReady else {
            store.move(to: target)
            loadStoreIntoEditor()
            pushWorkspaceToEditor()
            completion?()
            return
        }
        webView.evaluateJavaScript("window.QN ? window.QN.getMarkdown() : ''") { [weak self] result, _ in
            guard let self else { return }
            if let md = result as? String {
                self.writeCurrent(md)
            }
            self.store.move(to: target)
            self.pendingTitleAdoption = nil
            self.loadStoreIntoEditor()
            self.pushWorkspaceToEditor()
            completion?()
        }
    }

    /// 新建文档。标题为空时用当天日期（重名自动 -2），并预置一个空的 `# ` 标题行，
    /// 用户一敲标题就会触发自动改名。
    private func createNewDocument(title: String?) {
        let url = workspace.newFileURL(title: title)
        let seed = (title?.isEmpty == false) ? "" : "# "
        switchDocument(to: url) { [weak self] in
            guard let self else { return }
            // 文件先落一个占位，避免列表里看不到；内容由前端接管
            self.writeCurrent(seed)
            self.pendingTitleAdoption = url
            self.loadStoreIntoEditor()
            self.pushWorkspaceToEditor()
            self.focusEditor()
            // 光标落到标题行末尾
            self.webView.evaluateJavaScript(
                "(function(){var b=document.querySelector('.qn-block');"
                + "if(!b) return;b.focus();"
                + "var r=document.createRange();r.selectNodeContents(b);r.collapse(false);"
                + "var s=window.getSelection();s.removeAllRanges();s.addRange(r);})()")
            self.log("新建文档 \(url.lastPathComponent)")
        }
    }

    /// 保存后检查：这个文件是我新建的、还没定名，且正文里已经有 `# 标题` → 改名。
    private func maybeAdoptTitle(from md: String) {
        guard let pending = pendingTitleAdoption,
              pending.path == store.url.path,
              let title = Workspace.titleFromContent(md),
              let dest = Workspace.titleTargetURL(from: store.url, title: title) else {
            return
        }
        do {
            try FileManager.default.moveItem(at: store.url, to: dest)
            store.move(to: dest)
            pendingTitleAdoption = nil
            pushWorkspaceToEditor()
            log("按标题重命名 \(dest.lastPathComponent)")
        } catch {
            log("按标题重命名失败: \(error.localizedDescription)")
        }
    }

    private func deleteFile(at url: URL) {
        // 先移进废纸篓，不用 removeItem——便签没有别的副本，
        // 误删必须能从废纸篓捡回来。
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            log("删除失败: \(error.localizedDescription)")
            return
        }
        if Self.canonicalPath(url.path) == Self.canonicalPath(store.url.path) {
            // 删掉的是当前文件：切到目录里剩下的最近一条，没有就新建
            if let next = workspace.listMarkdown().first {
                store.move(to: next.url)
                loadStoreIntoEditor()
            } else {
                createNewDocument(title: nil)
            }
        }
        pushWorkspaceToEditor()
        log("已移入废纸篓 \(url.lastPathComponent)")
    }

    private func renameFile(at url: URL, to rawName: String) {
        let base = Workspace.sanitize(rawName)
        guard !base.isEmpty else { return }
        let dest = url.deletingLastPathComponent().appendingPathComponent("\(base).md")
        guard dest.path != url.path else { return }
        guard !FileManager.default.fileExists(atPath: dest.path) else {
            log("重命名失败：\(base).md 已存在")
            return
        }
        do {
            try FileManager.default.moveItem(at: url, to: dest)
            if Self.canonicalPath(url.path) == Self.canonicalPath(store.url.path) {
                store.move(to: dest)
                pendingTitleAdoption = nil
                loadStoreIntoEditor()
            }
            pushWorkspaceToEditor()
            log("重命名 -> \(dest.lastPathComponent)")
        } catch {
            log("重命名失败: \(error.localizedDescription)")
        }
    }

    /// 选一个目录作为当前工作区。选完自动钉进快捷目录——
    /// 用户特意选目录这个动作本身就说明「我以后还会来」。
    private func chooseFolder() {
        let open = NSOpenPanel()
        open.canChooseDirectories = true
        open.canChooseFiles = false
        open.allowsMultipleSelection = false
        open.prompt = "作为工作区"
        open.directoryURL = workspace.currentDirectory
        NSApp.activate(ignoringOtherApps: true)
        if open.runModal() == .OK, let url = open.url {
            workspace.setCurrent(url)
            workspace.addShortcut(url)
            if let first = workspace.listMarkdown().first {
                switchDocument(to: first.url) { [weak self] in self?.pushWorkspaceToEditor() }
            } else {
                pushWorkspaceToEditor()
            }
        }
        // 面板可能因为弹出系统对话框失焦而收起
        showPanelIfNeeded()
    }

    /// 切换当前目录（点侧栏里的快捷目录，或点文件夹名）
    private func openFolder(_ url: URL) {
        workspace.setCurrent(url)
        if let first = workspace.listMarkdown().first {
            switchDocument(to: first.url) { [weak self] in self?.pushWorkspaceToEditor() }
        } else {
            pushWorkspaceToEditor()
        }
    }

    // MARK: - 工具

    /// 用于「路径相等」比较的统一格式。
    ///
    /// macOS 上 `/var` 和 `/private/var` 指向同一个地方，两种写法都会出现：
    /// Foundation 给的通常是 `/var/...`，FSEvents 报的是内核视角的 `/private/var/...`。
    /// 比较前去掉 `/private` 前缀，两边就一致了。
    /// 只用于比较，不要拿去读写文件（读写用 `store.url.path` 原样即可）。
    static func canonicalPath(_ path: String) -> String {
        let s = URL(fileURLWithPath: path).standardizedFileURL.path
        return s.hasPrefix("/private/") ? String(s.dropFirst("/private".count)) : s
    }

    private func jsonString(_ s: String) -> String {
        (try? JSONSerialization.data(withJSONObject: [s]))
            .flatMap { String(data: $0, encoding: .utf8) }?.dropFirst().dropLast().description
            ?? "\"\""
    }

    /// 诊断日志：QUICKMD_DEBUG=1 时写入 ~/Documents/Quickmd/quickmd.log
    private func log(_ message: String) {
        guard ProcessInfo.processInfo.environment["QUICKMD_DEBUG"] == "1" else { return }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Quickmd")
        let file = dir.appendingPathComponent("quickmd.log")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        let line = "[\(Date())] \(message)\n"
        if let data = line.data(using: .utf8), let h = try? FileHandle(forWritingTo: file) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        }
    }

    // MARK: - 诊断开关

    private func runDiagnosticsIfRequested() {
        if CommandLine.arguments.contains("--nametest") { runNamingSelfTest() }
        if CommandLine.arguments.contains("--watchtest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.runWatchSelfTest()
            }
        }
        if CommandLine.arguments.contains("--logintest") {
            // 自检：切换一次开机自启并打印结果（用于验证注册链路）
            let c = LoginItemController()
            let before = c.isEnabled
            let ok = c.setEnabled(!before)
            let msg = "开机自启自检：之前=\(before) 之后=\(c.isEnabled) 切换成功=\(ok)"
            print(msg)
            log(msg)
        }
        if CommandLine.arguments.contains("--show-now") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.showPanelIfNeeded(); self?.activatePanel()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                    guard let self else { return }
                    var fr = "nil"
                    if let r = self.panel.firstResponder { fr = String(describing: type(of: r)) }
                    self.log("键盘自检 isKeyWindow=\(self.panel.isKeyWindow) "
                           + "canBecomeKey=\(self.panel.canBecomeKey) "
                           + "NSApp.isActive=\(NSApp.isActive) "
                           + "firstResponder=\(fr)")
                    self.webView.evaluateJavaScript(
                        "(function(){var a=document.activeElement;"
                        + "if(!a) return 'none';"
                        + "return a.className + '|' + a.isContentEditable;})()"
                    ) { r, _ in
                        self.log("焦点自检 activeElement=\(r as? String ?? "?")")
                    }
                }
            }
        }
        if CommandLine.arguments.contains("--shot") || CommandLine.arguments.contains("--shot-browse") {
            // 截图自检：塞一份示例文档，把面板渲染成 PNG 存到临时目录，
            // 用来肉眼检查 UI 质感（字体、间距、圆角、纸面颜色、侧栏排布）。
            let browse = CommandLine.arguments.contains("--shot-browse")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                if browse {
                    self.setPanelMode(.browse)
                    self.seedDemoWorkspaceForShot()
                }
                self.showPanelIfNeeded()
                self.activatePanel()
                self.pushToEditor(Self.sampleDocument, file: self.store.url.lastPathComponent)
                self.pushWorkspaceToEditor()
                // 浏览态截图往下滚一点，把表格和代码块也带进来。
                // 滚动后要等一帧再截，否则拿到的是滚动前的画面。
                let delay: Double = browse ? 0.5 : 0
                if browse {
                    self.webView.evaluateJavaScript(
                        "(function(){var s=document.getElementById('qn-scroll');"
                        + "if(s) s.scrollTop = 300;})()")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4 + delay) { [weak self] in
                    self?.capturePanelShot(named: browse ? "quickmd-browse" : "quickmd-shot")
                    // 截图是「跑完就完」的诊断：演示目录用完即删，
                    // 进程也跟着退出，不然会一直挂在后台占着菜单栏。
                    guard browse else { return }
                    try? FileManager.default.removeItem(
                        at: URL(fileURLWithPath: NSTemporaryDirectory())
                            .appendingPathComponent("quickmd-shot-demo"))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exit(0) }
                }
            }
        }
        if CommandLine.arguments.contains("--mdtest") {            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.runMarkdownRoundTrip()
            }
        }
        if CommandLine.arguments.contains("--blockcount") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.logBlockCount()
            }
        }
        if CommandLine.arguments.contains("--domtest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.runDOMInteractionTest()
            }
        }
        if CommandLine.arguments.contains("--wstest") {
            // 前端自检：侧栏渲染 / 搜索 / 表格单元格导航 / 图片路径。
            // 期间禁止写盘，免得把测试内容盖到真实笔记上。
            diagnosticsReadOnly = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                self.showPanelIfNeeded()
                self.activatePanel()
                self.setPanelMode(.browse)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    self?.runWorkspaceTest()
                }
            }
        }
        // 诊断：合成一次「预览态面板被点击」，验证点击 -> 激活 -> 可编辑链路。
        if CommandLine.arguments.contains("--clicktest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, let panel = self.panel else { return }
                self.showPanelIfNeeded()                     // 预览态：不激活
                let loc = NSPoint(x: self.panelSize.width / 2,
                                  y: self.panelSize.height / 2)
                func mouseEv(_ type: NSEvent.EventType, _ num: Int) -> NSEvent? {
                    NSEvent.mouseEvent(with: type, location: loc, modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: panel.windowNumber,
                                       context: nil, eventNumber: num,
                                       clickCount: 1, pressure: 1)
                }
                if let down = mouseEv(.leftMouseDown, 1) { panel.sendEvent(down) }
                if let up = mouseEv(.leftMouseUp, 2) { panel.sendEvent(up) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    guard let self else { return }
                    var fr = "nil"
                    if let r = self.panel.firstResponder { fr = String(describing: type(of: r)) }
                    self.log("点击测试 isKeyWindow=\(self.panel.isKeyWindow) "
                           + "NSApp.isActive=\(NSApp.isActive) firstResponder=\(fr)")
                    self.webView.evaluateJavaScript(
                        "(function(){var a=document.activeElement;"
                        + "if(!a) return 'none';"
                        + "return a.className + '|' + a.isContentEditable;})()"
                    ) { r, _ in
                        self.log("点击测试 activeElement=\(r as? String ?? "?")")
                    }
                }
            }
        }
    }

    /// 诊断：真实 WebView 里的 DOM 交互自检。
    /// 覆盖 Node 单测够不到的部分：前缀变形、任务列表、Tab 缩进 / Shift+Tab 减缩进。
    private func runDOMInteractionTest() {
        let js = """
        (function(){
          var out = [];
          var qn = window.QN;
          if (!qn) return 'QN_MISSING';
          var NL = String.fromCharCode(10);
          var flat = function (s) { return String(s).split(NL).join('/'); };

          function typeInto(el, text) {
            el.textContent = text;
            el.dispatchEvent(new Event('input', {bubbles: true}));
          }
          // 光标放到节点末尾（回车才会在后面生成新项）
          function caretToEnd(node) {
            var r = document.createRange();
            r.selectNodeContents(node); r.collapse(false);
            var s = window.getSelection();
            s.removeAllRanges(); s.addRange(r);
          }
          function press(el, init) {
            var opts = {bubbles: true, cancelable: true};
            for (var k in init) opts[k] = init[k];
            el.dispatchEvent(new KeyboardEvent('keydown', opts));
          }
          // 每步单独包 try/catch：一步炸了不影响后面的步骤继续跑
          function step(name, fn) {
            try { out.push(name + '=' + fn()); }
            catch (e) { out.push(name + '=ERR:' + (e && e.message ? e.message : String(e))); }
          }

          step('前缀标题', function () {
            qn.load('普通文字', 't.md');
            var el = document.querySelector('.qn-block');
            typeInto(el, '# 标题');
            return el.getAttribute('data-type') + '/' + el.textContent;
          });

          step('前缀任务', function () {
            qn.load('普通文字', 't.md');
            var el = document.querySelector('.qn-block');
            typeInto(el, '- [ ] 买牛奶');
            return el.getAttribute('data-type')
                   + '/有任务项=' + (el.innerHTML.indexOf('qn-task') >= 0)
                   + '/文本=' + el.textContent;
          });

          step('前缀列表', function () {
            qn.load('普通文字', 't.md');
            var el = document.querySelector('.qn-block');
            typeInto(el, '- 项目');
            return el.getAttribute('data-type');
          });

          // 4) Tab 缩进：把第 2 项缩进到第 1 项下面
          step('Tab缩进', function () {
            qn.load('- 甲' + NL + '- 乙', 't.md');
            var lis = document.querySelectorAll('.qn-block li');
            if (lis.length < 2) return 'NO_LI';
            var second = lis[1];
            var textNode = second.querySelector('span') ? second.querySelector('span').firstChild : second.firstChild;
            if (textNode) {
              caretToEnd(textNode);
              press(second, {key: 'Tab'});
            }
            var nested = document.querySelector('.qn-block ul ul li');
            return (nested ? nested.textContent : 'NONE') + '/md=' + flat(qn.getMarkdown());
          });

          // 5) Shift+Tab 减缩进
          step('ShiftTab减缩进', function () {
            var nestedLi = document.querySelector('.qn-block ul ul li');
            if (!nestedLi) return 'NO_NESTED';
            if (nestedLi.firstChild) {
              caretToEnd(nestedLi.firstChild);
              press(nestedLi, {key: 'Tab', shiftKey: true});
            }
            return flat(qn.getMarkdown());
          });

          // 6) 有序列表起始序号：Typora 行为，写 3. 就从 3 开始
          step('有序起始', function () {
            qn.load('3. 第三项', 't.md');
            var el = document.querySelector('.qn-block');
            var o = el.querySelector('ol');
            return (o ? o.getAttribute('start') : 'NONE') + '/md=' + flat(qn.getMarkdown());
          });

          // 7) 有序列表里回车 -> 新项接在后面，序号自动续
          step('有序续号', function () {
            qn.load('1. 甲', 't.md');
            var ol = document.querySelector('.qn-block ol');
            if (!ol) return 'NO_OL';
            var firstLi = ol.querySelector('li');
            if (firstLi.firstChild) {
              caretToEnd(firstLi.firstChild);
              press(firstLi, {key: 'Enter'});
            }
            return flat(qn.getMarkdown()) + '/项数=' + document.querySelectorAll('.qn-block ol li').length;
          });

          // 8) 连续回车两次 -> 第二个空项上再回车应退出列表
          step('空项退列表', function () {
            qn.load('1. 甲', 't.md');
            var li = document.querySelector('.qn-block ol li');
            if (!li) return 'NO_LI';
            if (li.firstChild) { caretToEnd(li.firstChild); press(li, {key: 'Enter'}); }
            // 现在有 2 项：甲 + 新建的空项
            var empty = document.querySelectorAll('.qn-block ol li')[1];
            if (!empty) return 'NO_EMPTY';
            press(empty, {key: 'Enter'});
            return flat(qn.getMarkdown()) + '/剩余列表项=' + document.querySelectorAll('.qn-block ol li').length;
          });

          // 9) 列表互转：ul -> ol 应按层级编号
          step('转有序', function () {
            qn.load('- 甲' + NL + '  - 甲一' + NL + '- 乙', 't.md');
            var el = document.querySelector('.qn-block');
            // 先把光标放进块里，applyBlockType 依赖 activeBlock
            var firstText = el.querySelector('li').firstChild;
            if (firstText) caretToEnd(firstText);
            press(el, {key: '8', metaKey: true});
            return flat(qn.getMarkdown());
          });

          return out.join(' ;; ');
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] result, error in
            guard let self else { return }
            if let error = error {
                self.log("DOM 交互自检失败: \(error.localizedDescription)")
                return
            }
            self.log("=== DOM 交互自检 ===")
            self.log((result as? String) ?? "无结果")
        }
    }

    /// 诊断：把当前面板渲染成 PNG，存到 /tmp/quickmd-shot.png。
    /// 用途：肉眼检查 UI 质感——字号层级、行距、圆角、纸面颜色。
    private func capturePanelShot(named name: String = "quickmd-shot") {
        guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else { return }
        container.cacheDisplay(in: container.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        let out = URL(fileURLWithPath: "/tmp/\(name).png")
        try? png.write(to: out)
        log("截图已保存 \(out.path)")
        print("截图已保存 \(out.path)")
    }

    /// --shot 用的示例文档：把各种块类型都放一遍，方便检查排版。
    private static let sampleDocument = """
    # 刘海速记

    段落文字：这是一段普通正文，用来检查**加粗**、*斜体*、`行内代码` 与~~删除线~~的显示。

    ## 二级标题

    - 无序列表项一
    - 无序列表项二
      - 嵌套的子项
    - [x] 已完成的任务
    - [ ] 没完成的任务

    ### 三级标题

    1. 有序列表第一项
    2. 有序列表第二项
    3. 有序列表第三项

    #### 四级小标题

    | 项目 | 结果 |
    | --- | :---: |
    | 分块渲染 | 通过 |
    | 表格 | 通过 |

    > 引用一段话，检查左侧竖线和次要文字颜色。

    ```swift
    let answer = 42
    print("hello")
    ```

    ---

    结尾。
    """

    /// 诊断：前端侧栏与新增格式在真实 WebView 里的行为自检。
    /// 覆盖纯函数测不到的部分：DOM 渲染、搜索过滤、表格单元格键盘导航、图片路径解析。
    private func runWorkspaceTest() {
        let js = """
        (function(){
          var out = [];
          var qn = window.QN;
          if (!qn) return 'QN_MISSING';
          var NL = String.fromCharCode(10);
          function step(name, fn) {
            try { out.push(name + '=' + fn()); }
            catch (e) { out.push(name + '=ERR:' + (e && e.message ? e.message : String(e))); }
          }
          function press(el, init) {
            var o = {bubbles: true, cancelable: true};
            for (var k in init) o[k] = init[k];
            el.dispatchEvent(new KeyboardEvent('keydown', o));
          }
          var now = Date.now() / 1000;
          var payload = {
            dir: '/tmp/qmd-x', dirName: '测试目录',
            files: [
              {path: '/tmp/qmd-x/a.md', name: '会议记录', modified: now, size: 10},
              {path: '/tmp/qmd-x/b.md', name: '读书笔记', modified: now - 86400, size: 20},
              {path: '/tmp/qmd-x/c.md', name: '2026-10-29', modified: now - 86400 * 40, size: 30}
            ],
            shortcuts: [{path: '/tmp/qmd-x', name: '测试目录'}],
            current: '/tmp/qmd-x/a.md',
            mode: 'browse'
          };

          step('侧栏文件数', function () {
            qn.setWorkspace(payload);
            return document.querySelectorAll('#qn-files .qn-row').length;
          });
          step('当前文件高亮', function () {
            return document.querySelectorAll('#qn-files .qn-row.is-active').length
                 + '/' + (document.querySelector('#qn-files .qn-row.is-active') || {}).textContent;
          });
          step('快捷目录数', function () {
            return document.querySelectorAll('#qn-shortcuts .qn-row').length;
          });
          step('模式=browse', function () {
            return document.getElementById('qn-app').getAttribute('data-mode');
          });
          step('目录名', function () {
            return document.getElementById('qn-dir-name').textContent;
          });
          step('搜索过滤', function () {
            var s = document.getElementById('qn-search');
            s.value = '笔记';
            s.dispatchEvent(new Event('input', {bubbles: true}));
            return document.querySelectorAll('#qn-files .qn-row').length;
          });
          step('搜索无结果提示', function () {
            var s = document.getElementById('qn-search');
            s.value = 'zzz';
            s.dispatchEvent(new Event('input', {bubbles: true}));
            return document.querySelectorAll('#qn-files .qn-empty').length;
          });
          step('清空搜索恢复', function () {
            var s = document.getElementById('qn-search');
            s.value = '';
            s.dispatchEvent(new Event('input', {bubbles: true}));
            return document.querySelectorAll('#qn-files .qn-row').length;
          });

          step('回到快捕态', function () {
            qn.setMode('capture');
            return document.getElementById('qn-app').getAttribute('data-mode');
          });

          // 表格单元格导航
          // 注意：contenteditable 里键盘事件的 target 是宿主块，不是 td，
          // 所以这里把光标真放进单元格、再把按键打到宿主块上，模拟真实输入。
          step('表格Tab跳格', function () {
            qn.load('| 甲 | 乙 |' + NL + '| --- | --- |' + NL + '| 1 | 2 |', 't.md', '/tmp');
            var block = document.querySelector('.qn-block');
            var ths = block.querySelectorAll('th');
            if (ths.length < 2) return 'NO_TH';
            block.focus();
            var r = document.createRange(); r.selectNodeContents(ths[0]); r.collapse(true);
            var s = window.getSelection(); s.removeAllRanges(); s.addRange(r);
            press(block, {key: 'Tab'});
            var sel = window.getSelection();
            var n = sel.anchorNode; if (n && n.nodeType === 3) n = n.parentNode;
            var c = (n && n.closest) ? n.closest('td, th') : null;
            return c ? c.tagName + ':' + c.textContent : 'NONE';
          });
          step('表格Enter加行', function () {
            qn.load('| 甲 |' + NL + '| --- |' + NL + '| 1 |', 't.md', '/tmp');
            var block = document.querySelector('.qn-block');
            var td = block.querySelector('tbody td');
            if (!td) return 'NO_TD';
            block.focus();
            var r = document.createRange(); r.selectNodeContents(td); r.collapse(true);
            var s = window.getSelection(); s.removeAllRanges(); s.addRange(r);
            press(block, {key: 'Enter'});
            var rows = block.querySelectorAll('tbody tr').length;
            var sel = window.getSelection();
            var n = sel.anchorNode; if (n && n.nodeType === 3) n = n.parentNode;
            var c = (n && n.closest) ? n.closest('td, th') : null;
            return '行数=' + rows + '/光标=' + (c ? c.tagName : 'NONE');
          });
          step('表格往返', function () {
            qn.load('| 甲 | 乙 |' + NL + '| --- | :---: |' + NL + '| 1 | 2 |', 't.md', '/tmp');
            return qn.getMarkdown().split(NL).join('/');
          });

          // 图片路径解析
          step('图片相对路径转file', function () {
            qn.load('![猫](assets/cat.png)', 't.md', '/Users/frog/Documents/Quickmd');
            var img = document.querySelector('.qn-block img');
            if (!img) return 'NO_IMG';
            var src = img.getAttribute('src');
            return (src.indexOf('file://') === 0 ? 'FILE:' : 'REL:') + src;
          });
          step('图片存回相对路径', function () {
            return qn.getMarkdown();
          });
          step('网络图片不改写', function () {
            qn.load('![x](https://e.com/a.png)', 't.md', '/Users/frog/Documents/Quickmd');
            var img = document.querySelector('.qn-block img');
            return img ? img.getAttribute('src') : 'NO_IMG';
          });

          return out.join(' ;; ');
        })()
        """
        webView.evaluateJavaScript(js) { [weak self] result, error in
            guard let self else { return }
            var msg = "=== 工作区自检 ===\n" + (result as? String ?? "nil")
            if let error { msg += "\nJS错误: \(error.localizedDescription)" }
            self.log(msg)
            print(msg)
            fflush(stdout)
        }
    }

    /// 诊断：验证「新建文件命名」规则。
    ///
    /// 规则来自需求原话：**填了标题就用标题命名，没填就按日期存档**。
    /// 这块最容易出错（非法字符、重名覆盖、超长文件名），所以单独跑一遍。
    private func runNamingSelfTest() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("qmd-name-\(UUID().uuidString)")
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        var out: [String] = []
        func check(_ name: String, _ got: String, _ want: String) {
            out.append(got == want ? "PASS \(name)"
                     : "FAIL \(name)  got=\(got)  want=\(want)")
        }

        let today = Workspace.dateStamp()
        check("无标题用日期", Workspace.uniqueURL(in: tmp, title: nil).lastPathComponent, "\(today).md")
        check("空白标题用日期", Workspace.uniqueURL(in: tmp, title: "   ").lastPathComponent, "\(today).md")
        check("有标题用标题", Workspace.uniqueURL(in: tmp, title: "会议记录").lastPathComponent, "会议记录.md")

        fm.createFile(atPath: tmp.appendingPathComponent("会议记录.md").path, contents: nil)
        check("重名加-2", Workspace.uniqueURL(in: tmp, title: "会议记录").lastPathComponent, "会议记录-2.md")
        fm.createFile(atPath: tmp.appendingPathComponent("会议记录-2.md").path, contents: nil)
        check("再重名加-3", Workspace.uniqueURL(in: tmp, title: "会议记录").lastPathComponent, "会议记录-3.md")

        check("斜杠转横线", Workspace.sanitize("a/b"), "a-b")
        check("冒号转横线", Workspace.sanitize("10:30 开会"), "10-30 开会")
        check("空白压缩", Workspace.sanitize("a   b"), "a b")
        check("超长截断60", "\(Workspace.sanitize(String(repeating: "字", count: 100)).count)", "60")

        check("抽取一级标题", Workspace.titleFromContent("# 你好\n正文") ?? "nil", "你好")
        check("跳过二级标题", Workspace.titleFromContent("## 小节\n# 真正的标题") ?? "nil", "真正的标题")
        check("无标题返回nil", Workspace.titleFromContent("只有正文") == nil ? "nil" : "x", "nil")

        // 按标题改名的目标路径（会真的移动文件，必须验证不覆盖）
        let dated = tmp.appendingPathComponent("\(today).md")
        fm.createFile(atPath: dated.path, contents: nil)
        check("改名目标=标题",
              Workspace.titleTargetURL(from: dated, title: "会议纪要")?.lastPathComponent ?? "nil",
              "会议纪要.md")
        fm.createFile(atPath: tmp.appendingPathComponent("会议纪要.md").path, contents: nil)
        check("改名重名顺延",
              Workspace.titleTargetURL(from: dated, title: "会议纪要")?.lastPathComponent ?? "nil",
              "会议纪要-2.md")
        let same = tmp.appendingPathComponent("已同名.md")
        fm.createFile(atPath: same.path, contents: nil)
        check("已同名不改", Workspace.titleTargetURL(from: same, title: "已同名") == nil ? "nil" : "x", "nil")
        check("标题为空不改", Workspace.titleTargetURL(from: dated, title: "  ") == nil ? "nil" : "x", "nil")
        check("标题里斜杠被清洗",
              Workspace.titleTargetURL(from: dated, title: "a/b")?.lastPathComponent ?? "nil",
              "a-b.md")

        let msg = "=== 命名自检 ===\n" + out.joined(separator: "\n")
        log(msg)
        print(msg)
        fflush(stdout)
        exit(0)          // 纯逻辑自检，不需要起事件循环
    }

    /// 诊断：外部改动监听（真实写盘 + 真实 FSEvents，不 mock）。
    ///
    /// 三步走：打开临时文件 → 模拟别的程序改写 → 校验编辑器是否自动跟上；
    /// 再模拟外部删除 → 校验是否停写（否则会按原路径复活一个幽灵文件）。
    private func runWatchSelfTest() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qm-watch-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let file = tmp.appendingPathComponent("watch.md")
        try? "# 原始内容\n第一行".write(to: file, atomically: true, encoding: .utf8)

        workspace.setCurrent(tmp, persist: false)   // 别把临时目录写进配置
        switchDocument(to: file) { [weak self] in
            guard let self else { return }
            self.showPanelIfNeeded()

            // ① 1.5 秒后：另一个程序改写这个文件
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                try? "# 外部改的标题\n第二行".write(to: file, atomically: true, encoding: .utf8)
            }

            // ② 3.2 秒后：看编辑器有没有跟上
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { [weak self] in
                guard let self else { return }
                self.webView.evaluateJavaScript("window.QN.getMarkdown()") { result, _ in
                    let md = (result as? String) ?? ""
                    let reloaded = md.contains("外部改的标题")

                    // ③ 模拟外部删除
                    try? FileManager.default.removeItem(at: file)

                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
                        guard let self else { return }
                        let stopped = self.currentFileRemovedExternally
                        self.writeCurrent("不该被写进去")          // 应被跳过
                        let revived = FileManager.default.fileExists(atPath: file.path)

                        let msg = "=== 外部改动自检 ===\n"
                            + "外部改写后自动重载=\(reloaded ? "通过" : "失败(内容=\(md))")\n"
                            + "外部删除后停写标记=\(stopped ? "通过" : "失败")\n"
                            + "删除后不复活文件=\(revived ? "失败(文件被重建)" : "通过")"
                        self.log(msg)
                        print(msg)
                        fflush(stdout)
                        try? FileManager.default.removeItem(at: tmp)   // 清掉临时目录
                        exit(0)
                    }
                }
            }
        }
    }

    /// --shot-browse 专用：搭一个临时演示目录。
    ///
    /// 直接截真实目录的话，侧栏里只有用户自己的文件（可能只有一张空白便签），
    /// 看不出「文件列表」长什么样。这里造三个假文件，截完就把目录删掉，
    /// 并且**不写入工作区配置**，不污染真实数据。
    private func seedDemoWorkspaceForShot() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quickmd-shot-demo")
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let samples: [(String, String)] = [
            ("会议记录", "# 会议记录\n\n- 确认排版口径\n- 补一版侧栏样式\n"),
            ("读书笔记", "# 读书笔记\n\n> 记一句最有用的。\n"),
            ("本周待办", "# 本周待办\n\n- [x] 收紧触发区\n- [ ] 写手动测试清单\n")
        ]
        for (name, body) in samples {
            try? body.write(to: dir.appendingPathComponent("\(name).md"),
                            atomically: true, encoding: .utf8)
        }
        workspace.setCurrent(dir, persist: false)
        // 只把「当前文件」指针挪到演示文件上（不读盘、不写盘），
        // 这样侧栏才会把其中一项标成选中；正文由调用方推进去。
        let first = dir.appendingPathComponent("会议记录.md")
        if FileManager.default.fileExists(atPath: first.path) {
            store.move(to: first)
        }
    }

    /// 诊断：报告当前文档渲染出的块数与文本量
    private func logBlockCount() {        let js = """
        (function(){
          var bs = document.querySelectorAll('.qn-block');
          var chars = 0;
          for (var i = 0; i < bs.length; i++) chars += (bs[i].textContent || '').length;
          return bs.length + '|' + chars;
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self, let s = result as? String else { return }
            let parts = s.split(separator: "|")
            self.log("块数诊断 blocks=\(parts.first ?? "?") 渲染字符=\(parts.count > 1 ? String(parts[1]) : "?")")
        }
    }

    /// 在真实 WebView 里做 DOM -> md 往返测试（Node 单测覆盖不到的部分）
    private func runMarkdownRoundTrip() {
        let probe = """
        # 标题一

        ## 标题二

        正文含**加粗**与*斜体*与`代码`与~~删除~~。

        - 列表甲
        - [x] 已完成
        - [ ] 未完成

        > 引用一行

        ```swift
        let a = 1
        ```

        ---

        收尾。
        """
        let js = """
        (function(){
          var qn = window.QN;
          if (!qn) return 'QN_MISSING';
          qn.load(\(jsonString(probe)), 'probe.md');
          var back = qn.getMarkdown();
          return back;
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] result, error in
            guard let self else { return }
            if let error = error {
                self.log("往返测试失败: \(error.localizedDescription)")
                return
            }
            let back = (result as? String) ?? ""
            self.log("=== 往返测试 输入 ===")
            self.log(probe)
            self.log("=== 往返测试 输出 ===")
            self.log(back)
            let ok = back.contains("# 标题一") && back.contains("**加粗**")
                && back.contains("[x] 已完成") && back.contains("let a = 1")
                && back.contains("> 引用一行") && back.contains("收尾。")
            self.log("=== 往返测试结果: \(ok ? "通过" : "失败") ===")
        }
    }
}

// MARK: - JS → Swift 消息

extension AppDelegate: BridgeDelegate {
    func handle(message: WKScriptMessage) {
        guard message.name == "quickmd",
              let dict = message.body as? [String: Any],
              let type = dict["type"] as? String else { return }

        switch type {
        case "ready":
            editorReady = true
            if let pending = pendingContent {
                pushToEditor(pending, file: store.url.lastPathComponent)
                pendingContent = nil
            } else {
                pushToEditor(store.read(), file: store.url.lastPathComponent)
            }
            pushWorkspaceToEditor()
            log("编辑器就绪")

        case "save":
            if diagnosticsReadOnly { break }
            // 核对来源文件：这条消息可能是切换文档前挂起的定时器发来的，
            // 写进去就会串档（A 的内容覆盖 B）。名字对不上直接丢弃。
            if let f = dict["file"] as? String, !f.isEmpty,
               f != store.url.lastPathComponent {
                log("丢弃过期保存（来自 \(f)）")
                break
            }
            if let md = dict["md"] as? String {
                if writeCurrent(md) {
                    maybeAdoptTitle(from: md)
                }
            }

        // ---------- 工作区 ----------
        case "mode":
            setPanelMode((dict["mode"] as? String) == "browse" ? .browse : .capture)

        case "refresh":
            pushWorkspaceToEditor()

        case "chooseFolder":
            chooseFolder()

        case "openFolder":
            if let p = dict["path"] as? String { openFolder(URL(fileURLWithPath: p)) }

        case "addShortcut":
            if let p = dict["path"] as? String {
                workspace.addShortcut(URL(fileURLWithPath: p))
                pushWorkspaceToEditor()
            }

        case "removeShortcut":
            if let p = dict["path"] as? String {
                workspace.removeShortcut(URL(fileURLWithPath: p))
                pushWorkspaceToEditor()
            }

        case "openFile":
            if let p = dict["path"] as? String { switchDocument(to: URL(fileURLWithPath: p)) }

        case "newFile":
            createNewDocument(title: dict["title"] as? String)

        case "deleteFile":
            if let p = dict["path"] as? String { deleteFile(at: URL(fileURLWithPath: p)) }

        case "renameFile":
            if let p = dict["path"] as? String, let name = dict["name"] as? String {
                renameFile(at: URL(fileURLWithPath: p), to: name)
            }

        case "reveal":
            if let p = dict["path"] as? String {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
            }

        // 粘贴/拖入的图片落到 `assets/` 子目录，返回相对路径给前端插入
        case "saveImage":
            if let name = dict["name"] as? String, let b64 = dict["data"] as? String {
                saveImage(named: name, base64: b64)
            }

        default:
            break
        }
    }
}

// MARK: - WebView 导航

extension AppDelegate: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        log("WebView 加载完成 \(webView.url?.lastPathComponent ?? "")")
    }
}

// MARK: - 窗口失焦

extension AppDelegate: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) {
        guard panelIsActive else { return }             // 未激活的预览态不触发
        hidePanelIfNeeded()
    }
}
