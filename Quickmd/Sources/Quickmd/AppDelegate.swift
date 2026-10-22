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

    private var panel: NotchPanel!
    private var container: PanelContainerView!
    private var webView: WKWebView!

    // MARK: - 常量

    /// 面板尺寸。实测系统快速备忘录约 330x285pt（±5%），常量便于日后校准。
    private let panelSize = NSSize(width: 330, height: 285)

    // MARK: - 状态

    private var panelVisible = false
    private var panelIsActive = false
    private var isPinned = false
    private var editorReady = false
    private var pendingContent: String?

    // MARK: - 生命周期

    override init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        store = DocumentStore(defaultURL: home.appendingPathComponent("Documents/Quickmd/scratch.md"))
        super.init()
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
        setupLaunchAtLoginFirstRun()
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
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        container.onClick = { [weak self] in self?.activatePanel() }

        panel.contentView = container
    }

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        config.userContentController.add(bridge, name: "quickmd")

        let wv = EditorWebView(frame: container.bounds, configuration: config)
        wv.navigationDelegate = self
        wv.setValue(false, forKey: "drawsBackground")
        wv.autoresizingMask = [.width, .height]
        wv.allowsMagnification = false
        // 点击 WebView 内容 = 点击面板：先激活拿键盘，再让 WebKit 处理点击落点
        wv.onActivateClick = { [weak self] in self?.activatePanel(fromClick: true) }
        webView = wv
        container.addSubview(wv)

        guard let html = Bundle.module.url(forResource: "editor", withExtension: "html") else {
            log("错误：找不到 editor.html 资源")
            return
        }
        wv.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
    }

    // MARK: - 开机自启

    /// 首次运行默认开启开机自启（这是本项目明确要的功能）。
    /// 之后不再自动改动——用户在菜单栏勾选框或系统「登录项」里自行开关。
    private func setupLaunchAtLoginFirstRun() {
        let key = "quickmd.launchAtLoginInitialized"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let ok = LoginItemController().setEnabled(true)
        log("首次运行：开机自启\(ok ? "已开启" : "开启失败")")
    }

    // MARK: - 菜单栏

    private func setupStatusMenu() {
        statusMenu.onTogglePanel = { [weak self] in self?.togglePanel() }
        statusMenu.onOpenFile = { [weak self] in self?.openDocumentViaPanel() }
        statusMenu.onSaveNow = { [weak self] in self?.flushSave() }
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

    private func positionPanelAtNotch() {
        guard let screen = trigger.builtInScreen() else { return }
        let x = trigger.notchCenterX(for: screen) - panelSize.width / 2
        // 顶边贴在刘海下沿（再减 safeAreaInsets.top），
        // 否则 32pt 深的刘海会盖住面板顶部的工具栏。
        let y = screen.frame.maxY - screen.safeAreaInsets.top - panelSize.height
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - 文档读写

    private func loadStoreIntoEditor() {
        let content = store.read()
        if editorReady {
            pushToEditor(content, file: store.url.lastPathComponent)
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

    /// 立即落盘（Esc / ⌘S / 切换文档 / 退出时调用）。
    /// 防抖已在 JS 端做，这里不再叠加延迟。
    private func flushSave() {
        guard editorReady else { return }
        webView.evaluateJavaScript("window.QN && window.QN.getMarkdown ? window.QN.getMarkdown() : ''") {
            [weak self] result, _ in
            guard let self, let md = result as? String else { return }
            do {
                try self.store.write(md)
                self.log("已保存 \(self.store.url.lastPathComponent)")
            } catch {
                self.log("保存失败: \(error.localizedDescription)")
            }
        }
    }

    private func openDocument(_ url: URL) {
        flushSave()                                   // 先把旧文档存盘
        store.move(to: url)
        loadStoreIntoEditor()
        showPanelIfNeeded()                            // 选完文件面板要回来（v2 修复点）
        log("打开文档 \(url.path)")
    }

    private func openDocumentViaPanel() {
        let open = NSOpenPanel()
        open.allowedContentTypes = [.init(filenameExtension: "md")!]
        open.allowsMultipleSelection = false
        open.canChooseDirectories = false
        open.directoryURL = store.directory
        if open.runModal() == .OK, let url = open.url { openDocument(url) }
    }

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

    // MARK: - 诊断开关

    private func runDiagnosticsIfRequested() {
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
        if CommandLine.arguments.contains("--domtest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.runDOMInteractionTest()
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
          function caretTo(node) {
            var r = document.createRange();
            r.setStart(node, 0); r.collapse(true);
            var s = window.getSelection();
            s.removeAllRanges(); s.addRange(r);
          }

          // 1) 段落 -> 标题
          qn.load('普通文字', 't.md');
          var el = document.querySelector('.qn-block');
          typeInto(el, '# 标题');
          out.push('前缀标题=' + el.getAttribute('data-type') + '/' + el.textContent);

          // 2) 段落 -> 任务列表
          qn.load('普通文字', 't.md');
          el = document.querySelector('.qn-block');
          typeInto(el, '- [ ] 买牛奶');
          out.push('前缀任务=' + el.getAttribute('data-type')
                   + '/有勾选框=' + (el.innerHTML.indexOf('qn-box') >= 0)
                   + '/文本=' + el.textContent);

          // 3) 段落 -> 无序列表
          qn.load('普通文字', 't.md');
          el = document.querySelector('.qn-block');
          typeInto(el, '- 项目');
          out.push('前缀列表=' + el.getAttribute('data-type'));

          // 4) Tab 缩进：把第 2 项缩进到第 1 项下面
          qn.load('- 甲' + NL + '- 乙', 't.md');
          var lis = document.querySelectorAll('.qn-block li');
          if (lis.length >= 2) {
            var second = lis[1];
            var textNode = second.querySelector('span') ? second.querySelector('span').firstChild : second.firstChild;
            if (textNode) {
              caretTo(textNode);
              second.dispatchEvent(new KeyboardEvent('keydown', {key: 'Tab', bubbles: true, cancelable: true}));
            }
            var nested = document.querySelector('.qn-block ul ul li');
            out.push('Tab缩进=' + (nested ? nested.textContent : 'NONE')
                     + '/md=' + flat(qn.getMarkdown()));

            // 5) Shift+Tab 减缩进
            var nestedLi = document.querySelector('.qn-block ul ul li');
            if (nestedLi && nestedLi.firstChild) {
              caretTo(nestedLi.firstChild);
              nestedLi.dispatchEvent(new KeyboardEvent('keydown', {key: 'Tab', shiftKey: true, bubbles: true, cancelable: true}));
            }
            out.push('ShiftTab减缩进=' + flat(qn.getMarkdown()));
          }
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
            log("编辑器就绪")

        case "save":
            if let md = dict["md"] as? String {
                do {
                    try store.write(md)
                } catch {
                    log("保存失败: \(error.localizedDescription)")
                }
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
