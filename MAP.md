# Quickmd 项目地图（MAP）

> 一句话：常驻 macOS 菜单栏的超小 Markdown 便签——鼠标碰屏幕刘海就出面板，所见即所得编辑，内容以纯 `.md` 文件落盘。
> 最后更新：2026-10-22（接手梳理）

## 核心结构

```
Quick-md/                        # 仓库根
├── README.md                    # 项目门面：定位 / 快速开始 / 已知边界
├── docs/                        # 01 调研与选型 · 02 设计与方案 · 03 使用与实现
├── memory/项目历史决策.md        # 从第一天起的决策链与踩坑（为什么这么做）
└── Quickmd/                     # SwiftPM 包（App 源码，无 Xcode 工程）
    ├── Package.swift            # 平台 macOS 14+ / 资源声明（零第三方依赖）
    ├── build.sh                 # swift build release --disable-sandbox + 打包 .app
    ├── Sources/Quickmd/
    │   ├── main.swift           # AppKit 壳 594 行：刘海几何 / 30Hz 触发 / 菜单 / JS 桥接
    │   └── Resources/           # editor.html / editor.js / editor.css（Web 编辑器）
    └── Tests/editor-core.test.js# 55 项 Node 单测（只测纯函数层）
```

## 三条主链路

1. **触发**：30Hz 轮询 `NSEvent.mouseLocation` → 命中刘海热区 → `orderFrontRegardless` 预览态（不抢键盘）→ 点击激活（`makeKeyAndOrderFront` + 钉住）→ Esc / 失活收起
2. **编辑**：`editor.js` 分块 WYSIWYG —— md → `parse` → blocks → `renderBlock` → DOM；普通打字不动 DOM，仅「变形」时重渲染该块并按文本偏移恢复光标
3. **存取**：JS `getMarkdown()` 序列化 DOM → md → `postMessage({type:'save'})` → Swift 双防抖（JS 400ms + Swift 350ms）→ 原子写盘 `~/Documents/Quickmd/*.md`

## 关键约定

- JS↔Swift 桥：下行 `evaluateJavaScript(window.QN.load(md, file))`；上行 `WKScriptMessageHandler` 通道名 `quickmd`，消息只有 `ready` / `save` 两类
- 块间连接用 `\n\n`（CommonMark 规范）；代码块语言标签存 `data-lang` 属性，往返不丢
- XSS 三件套：`esc()` 全量转义 + `safeURL` 协议白名单 + 属性边界转义（注意 `insertLink` 路径未过白名单，见问题清单）
- 面板两态：预览态（`canBecomeKey=false`，不抢焦点）/ 激活态（钉住不收起）；`EditorWebView` 子类负责把点击转成激活
- CSS 类名前缀 `qn-` 为内部实现标识；App 内外名称已统一为 Quickmd（历史文档里 Q便签/QNotes 是旧名）

## 问题清单（2026-10-22 接手梳理，均已验证）

| 级别 | 问题 | 位置 |
|---|---|---|
| 高 | 插入链接（⌘K / 工具栏）完全失效：WKWebView 未设 `WKUIDelegate`，`window.prompt` 直接返回 null（已写探针实测） | editor.js `insertLink` + main.swift 无 `WKUIDelegate` |
| 高 | `insertLink` 生成的 URL 未过 `safeURL`，`javascript:` 等可注入，与项目安全规范 1.4 相违 | editor.js:644 |
| 中 | 工具栏「代码块」按钮 `data-cmd="code"` 与行内代码按钮撞车，点击走 `wrapCode()`，无选区时无效 | editor.html:25 |
| 中 | 拖拽高亮是死代码：Swift 侧 `dragHighlight` 只调 `invalidateShadow()`，CSS `.qn-dragging` 类永远加不上 | main.swift `PanelContainerView` |
| 中 | `maybeTransform` 后 `focusBlock(el)` 未传 offset，光标跳到块尾（与文档宣称的「文本偏移恢复」不符） | editor.js:507 等 6 处 |
| 中 | 经 NSOpenPanel 打开文件后面板不自动回来（OpenPanel 抢 key → `windowDidResignKey` → 收起） | main.swift `openDocumentViaPanel` |
| 低 | 无 git 仓库；AppDelegate ↔ WKWebView retain cycle；双防抖冗余；有序列表续项恒为 `1.`；测试文件末尾 6 行在 `process.exit` 后永不执行 | 多处 |

## 运行

```bash
cd Quickmd && ./build.sh && open Quickmd.app        # 构建 + 运行
node Tests/editor-core.test.js                      # 单测（55 项）
QUICKMD_DEBUG=1 ./Quickmd.app/Contents/MacOS/Quickmd --mdtest   # 诊断（日志在 ~/Documents/Quickmd/quickmd.log）
```

诊断开关：`--show-now`（启动即展开+键盘自检）/ `--mdtest`（真实 WebView 往返）/ `--clicktest`（合成点击验证激活链）/ `--blockcount`。

## 文档导航

- 想了解「为什么这么设计」→ `memory/项目历史决策.md`
- 想了解编辑器完整规格（格式/快捷键/行为规则/安全规范）→ `docs/03-使用与实现/Q便签-v2-Markdown编辑器-实现说明.md`
- 想加新块类型（表格/图片等）→ 按 `parse → renderBlock → blockMD` 三处对称扩展，并补 Node 单测
