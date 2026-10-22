import AppKit
import WebKit

// MARK: - Quickmd v2 · Markdown 所见即所得
// ---------------------------------------------------------------------------
// 交互模型：
//  - 鼠标移到屏幕顶部刘海热区 -> 面板滑出（被动预览，不抢键盘焦点）。
//  - 点击面板 -> 激活、接管键盘并「钉住」（不再因鼠标移开而消失）。
//  - Esc 关闭并存盘；菜单栏 Q 图标提供手动开关、打开文件等入口。
//  - 编辑器是 WKWebView + Resources/editor.{html,js,css}，分块 WYSIWYG。
//  - 数据落盘在 ~/Documents/Quickmd/*.md，备忘录是唯一真相源，
//    便签只是草稿（v3 再接「追加 Markdown 到备忘录」快捷指令）。
//
// 权限：全程零辅助功能权限。触发靠 30Hz 轮询 NSEvent.mouseLocation。

// MARK: - 可切换键盘激活的 NSPanel

final class NotchPanel: NSPanel {
    var allowsKeyActivation = false

    override var canBecomeKey: Bool { allowsKeyActivation }
    override var canBecomeMain: Bool { allowsKeyActivation }
}

// MARK: - 圆角容器 + 点击激活 + 拖入 .md

final class PanelContainerView: NSView {
    var onClick: (() -> Void)?
    var onFileDropped: ((URL) -> Void)?
    private var dragHighlight = false

    override func mouseDown(with event: NSEvent) {
        onClick?()                                   // 先激活拿键盘，再传递事件
        super.mouseDown(with: event)
    }

    override var acceptsFirstResponder: Bool { true }

    // 拖入 .md 文件
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let url = draggedMDURL(sender) else { return [] }
        _ = url
        dragHighlight = true
        window?.invalidateShadow()
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dragHighlight = false
        window?.invalidateShadow()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dragHighlight = false
        window?.invalidateShadow()
        guard let url = draggedMDURL(sender) else { return false }
        onFileDropped?(url)
        return true
    }

    private func draggedMDURL(_ sender: NSDraggingInfo) -> URL? {
        guard let urls = sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL],
              let url = urls.first,
              url.pathExtension.lowercased() == "md" else { return nil }
        return url
    }

    override var wantsUpdateLayer: Bool { true }
}

// MARK: - 能把点击转成「激活」的 WebView

/// WKWebView 铺满整个面板，点击落在它身上时容器的 mouseDown 不会触发，
/// 面板就永远停在「预览态」（canBecomeKey=false）拿不到键盘，打不了字。
/// 这里在 WebView 自己的 mouseDown 里先激活，再照常把事件传给 WebKit。
final class EditorWebView: WKWebView {
    /// 点击时回调（用于激活面板）。fromClick=true 时由调用方决定是否抢焦点。
    var onActivateClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onActivateClick?()
        super.mouseDown(with: event)
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var panel: NotchPanel!
    private var container: PanelContainerView!
    private var webView: WKWebView!

    /// 面板尺寸。实测系统快速备忘录约 330x285pt（±5%），常量便于日后校准。
    private let panelSize = NSSize(width: 330, height: 285)

    /// 当前文档路径，默认 scratch.md
    private var storeURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/Quickmd/scratch.md")

    private var panelVisible = false
    private var panelIsActive = false
    private var isPinned = false
    private var editorReady = false
    private var pendingContent: String?
    private var saveWorkItem: DispatchWorkItem?

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)          // 不占程序坞
        setupPanel()
        setupStatusMenu()
        setupTriggers()
        loadStoreIntoEditor()

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
        if CommandLine.arguments.contains("--mdtest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.runMarkdownRoundTrip()
            }
        }
        if CommandLine.arguments.contains("--blockcount") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.logBlockCount()
            }
        }
        // 诊断：合成一次「预览态面板被点击」，验证点击 -> 激活 -> 可编辑链路。
        // 走 AppKit 真实事件分发（panel.sendEvent 会 hitTest 到 EditorWebView），
        // 不需要辅助功能权限，也不依赖真实鼠标。
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

    /// 诊断：报告当前文档渲染出的块数与文本量
    private func logBlockCount() {
        let js = """
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
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        container.registerForDraggedTypes([.fileURL])
        container.onClick = { [weak self] in self?.activatePanel() }
        container.onFileDropped = { [weak self] url in self?.openDocument(url) }

        setupWebView(in: container)
        panel.contentView = container
    }

    private func setupWebView(in parent: PanelContainerView) {
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "quickmd")
        // 关掉默认的双指缩放与右键菜单之外的干扰项
        let wv = EditorWebView(frame: parent.bounds, configuration: config)
        wv.navigationDelegate = self
        wv.setValue(false, forKey: "drawsBackground")
        wv.autoresizingMask = [.width, .height]
        wv.allowsMagnification = false
        // 点击 WebView 内容 = 点击面板：先激活拿键盘，再让 WebKit 处理点击落点
        wv.onActivateClick = { [weak self] in self?.activatePanel(fromClick: true) }
        webView = wv
        parent.addSubview(wv)

        guard let html = Bundle.module.url(forResource: "editor", withExtension: "html") else {
            log("错误：找不到 editor.html 资源")
            return
        }
        wv.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
    }

    // MARK: - 屏幕与刘海几何

    private func builtInScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    /// 刘海宽度（pt）。frame.width 减两侧辅助区，避免非主屏坐标错位。
    private func notchWidth(for screen: NSScreen) -> CGFloat {
        guard let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea,
              screen.safeAreaInsets.top > 0 else { return 0 }
        let w = screen.frame.width - left.width - right.width
        return (w > 0 && w < screen.frame.width) ? w : 0
    }

    private func notchCenterX(for screen: NSScreen) -> CGFloat { screen.frame.midX }

    private func positionPanelAtNotch() {
        guard let screen = builtInScreen() else { return }
        let x = notchCenterX(for: screen) - panelSize.width / 2
        // 顶边贴在刘海下沿（再减 safeAreaInsets.top），
        // 否则 32pt 深的刘海会盖住面板顶部的工具栏。
        let y = screen.frame.maxY - screen.safeAreaInsets.top - panelSize.height
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - 触发

    private func setupTriggers() {
        let timer = Timer(timeInterval: 1.0 / 30.0,
                          target: self, selector: #selector(mouseTick),
                          userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            if ev.keyCode == 53 { self?.hidePanelIfNeeded(); return nil }   // Esc
            return ev
        }
    }

    @objc private func mouseTick() {
        guard let screen = builtInScreen() else { return }
        let notchW = notchWidth(for: screen)
        guard notchW > 0 else { return }               // 无刘海屏：仅菜单栏入口

        let p = NSEvent.mouseLocation
        let hot = NSRect(x: notchCenterX(for: screen) - notchW / 2 - 10,
                         y: screen.frame.maxY - screen.safeAreaInsets.top - 40,
                         width: notchW + 20,
                         height: screen.safeAreaInsets.top + 48)

        if hot.contains(p), (NSEvent.pressedMouseButtons & 1) == 0 {
            showPanelIfNeeded()
        } else if !isPinned, !isPointInStayRegion(p) {
            hidePanelIfNeeded()
        }
    }

    private func isPointInStayRegion(_ p: NSPoint) -> Bool {
        if panel.frame.insetBy(dx: -10, dy: -10).contains(p) { return true }
        guard let screen = builtInScreen() else { return false }
        let notchW = notchWidth(for: screen)
        guard notchW > 0 else { return false }
        let hot = NSRect(x: notchCenterX(for: screen) - notchW / 2 - 10,
                         y: screen.frame.maxY - screen.safeAreaInsets.top - 40,
                         width: notchW + 20,
                         height: screen.safeAreaInsets.top + 48)
        return hot.contains(p)
    }

    // MARK: - 显示 / 隐藏 / 激活

    private func showPanelIfNeeded() {
        guard !panelVisible else { return }
        positionPanelAtNotch()
        panel.allowsKeyActivation = false
        panel.orderFrontRegardless()                  // 不激活 App，不抢焦点
        panelVisible = true
        log("面板显示 frame=\(panel.frame) screen=\(builtInScreen()?.frame ?? .zero) isActive=\(NSApp.isActive)")
    }

    /// 激活面板并接管键盘。
    /// - Parameter fromClick: true 表示由面板内的点击触发。此时不能抢焦点——
    ///   WebKit 自己会根据点击位置落光标，强行 focus 第一块会把用户点的
    ///   地方跳回首块。菜单/快捷键等无点击位置的入口才需要聚焦首块。
    private func activatePanel(fromClick: Bool = false) {
        guard panelVisible, !panelIsActive else { return }
        panel.allowsKeyActivation = true
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panelIsActive = true
        isPinned = true
        panel.makeFirstResponder(webView)
        if !fromClick { focusEditor() }
        log("面板激活 frame=\(panel.frame) fromClick=\(fromClick)")
    }

    private func hidePanelIfNeeded() {
        guard panelVisible else { return }
        flushSave()
        panel.orderOut(nil)
        panelVisible = false
        panelIsActive = false
        isPinned = false
        panel.allowsKeyActivation = false
        log("面板收起")
    }

    @objc private func togglePanel(_ sender: Any?) {
        if panelVisible { hidePanelIfNeeded() }
        else { showPanelIfNeeded(); activatePanel() }
    }

    // MARK: - 文档读写

    private func readStore() -> String {
        (try? String(contentsOf: storeURL, encoding: .utf8)) ?? ""
    }

    private func loadStoreIntoEditor() {
        let content = readStore()
        if editorReady {
            pushToEditor(content, file: storeURL.lastPathComponent)
        } else {
            pendingContent = content                          // 等编辑器 ready 再推
        }
    }

    private func pushToEditor(_ content: String, file: String) {
        let js = "window.QN && window.QN.load(\(jsonString(content)), \(jsonString(file)));"
        webView.evaluateJavaScript(js)
    }

    private func focusEditor() {
        webView.evaluateJavaScript(
            "(function(){var b=document.querySelector('.qn-block'); if(b){b.focus();}})()")
    }

    private func saveContent(_ content: String) {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            do {
                try FileManager.default.createDirectory(
                    at: self.storeURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try content.write(to: self.storeURL, atomically: true, encoding: .utf8)
            } catch {
                self.log("保存失败: \(error.localizedDescription)")
            }
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func flushSave() {
        guard editorReady else { return }
        webView.evaluateJavaScript("window.QN && window.QN.getMarkdown ? window.QN.getMarkdown() : ''") {
            [weak self] result, _ in
            guard let self, let md = result as? String else { return }
            self.saveWorkItem?.cancel()
            do {
                try FileManager.default.createDirectory(
                    at: self.storeURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try md.write(to: self.storeURL, atomically: true, encoding: .utf8)
            } catch {
                self.log("保存失败: \(error.localizedDescription)")
            }
        }
    }

    private func openDocument(_ url: URL) {
        flushSave()
        storeURL = url
        loadStoreIntoEditor()
        log("打开文档 \(url.path)")
    }

    private func openDocumentViaPanel() {
        let open = NSOpenPanel()
        open.allowedContentTypes = [.init(filenameExtension: "md")!]
        open.allowsMultipleSelection = false
        open.canChooseDirectories = false
        open.directoryURL = storeURL.deletingLastPathComponent()
        if open.runModal() == .OK, let url = open.url { openDocument(url) }
    }

    private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([storeURL])
    }

    // MARK: - 菜单栏

    private func setupStatusMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.title = "Quickmd"
            btn.toolTip = "Quickmd"
            btn.action = #selector(togglePanel(_:))
            btn.target = self
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "打开 / 关闭面板", action: #selector(togglePanel(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "打开 Markdown 文件…", action: #selector(openFromMenu), keyEquivalent: "o")
        menu.addItem(withTitle: "立即保存", action: #selector(saveFromMenu), keyEquivalent: "s")
        menu.addItem(withTitle: "在 Finder 中显示", action: #selector(revealFromMenu), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Quickmd", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
    }

    @objc private func openFromMenu() { openDocumentViaPanel() }
    @objc private func saveFromMenu() { flushSave() }
    @objc private func revealFromMenu() { revealInFinder() }

    // MARK: - 工具

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
}

// MARK: - WKScriptMessageHandler（JS -> Swift）

extension AppDelegate: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "quickmd",
              let dict = message.body as? [String: Any],
              let type = dict["type"] as? String else { return }

        switch type {
        case "ready":
            editorReady = true
            if let pending = pendingContent {
                pushToEditor(pending, file: storeURL.lastPathComponent)
                pendingContent = nil
            } else {
                pushToEditor(readStore(), file: storeURL.lastPathComponent)
            }
            log("编辑器就绪")

        case "save":
            if let md = dict["md"] as? String { saveContent(md) }

        default:
            break
        }
    }
}

extension AppDelegate: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        log("WebView 加载完成 \(webView.url?.lastPathComponent ?? "")")
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) {
        guard panelIsActive else { return }             // 未激活的预览态不触发
        hidePanelIfNeeded()
    }
}

// MARK: - 入口

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
