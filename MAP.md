# Quickmd 项目地图（MAP）

> 一句话：常驻 macOS 菜单栏的超小 Markdown 便签——鼠标碰屏幕刘海就出面板，所见即所得编辑，内容以纯 `.md` 文件落盘。
> 最后更新：2026-10-22（v3 极简化改造完成）

## 核心结构

```
Quick-md/                        # 仓库根
├── README.md                    # 项目门面：定位 / 速查表 / 开机自启 / 已知边界
├── MAP.md                       # 本文件
├── docs/                        # 01 调研 · 02 设计 · 03 使用与实现 · 04 需求对齐
├── assets/icons/                # 三款候选图标（PNG + .icns），ICON=1/2/3 切换
├── tools/                       # 图标生成脚本（CoreGraphics 绘制，可复现）
├── memory/项目历史决策.md        # 从第一天起的决策链与踩坑（为什么这么做）
└── Quickmd/                     # SwiftPM 包（App 源码，无 Xcode 工程）
    ├── Package.swift            # 平台 macOS 14+ / 资源声明（零第三方依赖）
    ├── build.sh                 # swift build release --disable-sandbox + 打包 .app + 装图标
    ├── Sources/Quickmd/
    │   ├── main.swift           # 入口：起 NSApplication + AppDelegate
    │   ├── AppDelegate.swift    # 组装与生命周期、面板两态、诊断开关、截图自检
    │   ├── NotchPanel.swift     # 面板：canBecomeKey 可切换（预览态/激活态）
    │   ├── PanelContainerView.swift # 圆角容器 + 柔和投影 + 点击激活
    │   ├── EditorWebView.swift  # 内嵌编辑器：把点击转成激活
    │   ├── NotchTrigger.swift   # 刘海几何 + 30Hz 轮询 + 停留区判定
    │   ├── DocumentStore.swift  # 当前文档读写（原子写）
    │   ├── Bridge.swift         # JS→Swift 消息通道（弱引用，避免引用环）
    │   ├── StatusMenu.swift     # 菜单栏（5 项，含开机自启勾选）
    │   ├── LoginItemController.swift # 开机自启：SMAppService，失败降级 LaunchAgent
    │   └── Resources/
    │       ├── editor-core.js   # 纯函数内核（esc/inline/parse/renderBlock），Node 可测
    │       ├── editor.js         # 浏览器层：DOM 序列化 / 块操作 / 事件 / 保存
    │       ├── editor.html       # 界面骨架（v3 起无工具栏）
    │       └── editor.css        # 样式：备忘录风暖纸面，深浅色自动适配
    └── Tests/editor-core.test.js# 79 项 Node 单测（只测纯函数层）
```

## 三条主链路

1. **触发**：30Hz 轮询 `NSEvent.mouseLocation` → 命中刘海热区 → `orderFrontRegardless` 预览态（不抢键盘）→ 点击激活（`makeKeyAndOrderFront` + 钉住）→ Esc / 失活收起
2. **编辑**：`editor-core.js` 分块 WYSIWYG —— md → `parse` → blocks → `renderBlock` → DOM；普通打字不动 DOM，仅「变形」时重渲染该块并按文本偏移恢复光标
3. **存取**：JS `getMarkdown()` 序列化 DOM → md → `postMessage({type:'save'})` → Swift 立即原子写盘 `~/Documents/Quickmd/*.md`（防抖只在 JS 端 400ms 一层）

## 关键约定

- JS↔Swift 桥：下行 `evaluateJavaScript(window.QN.load(md, file))`；上行 `WKScriptMessageHandler` 通道名 `quickmd`，消息只有 `ready` / `save` 两类
- 前缀语法即入口（v3 无工具栏）：`# ` `## ` `### ` `1. ` `- ` `> ` `- [ ] ` `---`；快捷键 ⌘B/⌘I/⇧⌘X/⌘S/⌘1-3/⌘7-9、Tab/⇧Tab 缩进
- 块间连接用 `\n\n`（CommonMark）；代码块语言标签存 `data-lang` 属性
- XSS 三件套：`esc()` 全量转义 + `safeURL` 协议白名单 + 属性边界转义（v3 起链接只能手写 md，插入入口已移除，绕过面消失）
- 面板两态：预览态（`canBecomeKey=false`，不抢焦点）/ 激活态（钉住不收起）；`EditorWebView` 负责把点击转成激活
- 开机自启：首次运行自动开启（`UserDefaults` 打标记，只做一次）；菜单栏勾选框可随时开关；系统「登录项」里也可见
- CSS 类名前缀 `qn-` 为内部实现标识；App 内外名称已统一为 Quickmd（历史文档里 Q便签/QNotes 是旧名）

## v3 改造记录（2026-10-22）

| 项 | v2 | v3 |
|---|---|---|
| 界面 | 13 键工具栏 + 状态栏 | 无工具栏，只有编辑区 + 一行状态栏（保存态/字数/文件名） |
| 功能入口 | 工具栏按钮 + 快捷键 + 插入链接弹窗 | 只剩前缀语法 + 快捷键；链接插入整体移除 |
| 拖拽打开文件 | 支持（高亮是半残的） | 移除，菜单 ⌘O 保留 |
| 保存 | JS 400ms + Swift 350ms 双防抖 | 只留 JS 400ms 一层 |
| 开机自启 | 无 | 首次运行自动注册（SMAppService，失败降级 LaunchAgent） |
| 代码结构 | main.swift 594 行单文件 | 拆成 10 个 Swift 文件 + JS 拆纯函数/浏览器两层 |
| 引用环 | AppDelegate ↔ WKWebView 成环 | Bridge 弱引用包装，环已断 |
| 光标恢复 | 变形后跳块尾 | 按「减去前缀长度」的文本偏移恢复 |

## 问题清单（2026-10-22 梳理，v3 已修的标注 ✅）

| 级别 | 问题 | 状态 |
|---|---|---|
| 高 | 插入链接失效（无 `WKUIDelegate`，prompt 返回 null） | ✅ v3 移除该功能 |
| 高 | `insertLink` 的 URL 未过 `safeURL` | ✅ 随功能移除 |
| 中 | 工具栏「代码块」按钮 `data-cmd` 撞车 | ✅ 工具栏整体移除 |
| 中 | 拖拽高亮死代码 | ✅ 拖拽功能移除 |
| 中 | `maybeTransform` 后光标跳块尾 | ✅ 已修（文本偏移恢复） |
| 中 | 打开文件后面板不回来 | ✅ 已修（`openDocument` 后重新显示） |
| 中 | 内容稀疏时点空白不聚焦（空白属 `#qn-scroll` 而非 `#qn-editor`） | ✅ 已修（`#qn-editor` 撑满滚动区） |
| 低 | 无 git 仓库 | ✅ 已建仓并推 GitHub |
| 低 | AppDelegate ↔ WKWebView 引用环 | ✅ 已修 |
| 低 | 双防抖冗余 | ✅ 已修 |
| 低 | 测试文件末尾 6 行写在 `process.exit` 之后永不执行 | ✅ 已修并补了 12 项新用例 |
| 低 | 有序列表回车续项恒为 `1.` | ✅ 已修（Typora 式续号：回车接上一个数，`3.` 开头就 3/4/5；空项回车退出列表） |
| 低 | 首次启动不生成演示便签（README 曾误称会生成） | ✅ 文档已更正 |
| 中 | 刘海热区向下多延伸 46pt，离刘海一段距离就误触发 | ✅ v3 收紧为刘海本体（实测 179×36pt）+ 4pt 容差 |
| 中 | UI 质感偏「工具感」，不像备忘录 | ✅ v3 重做 CSS：暖纸面 / 大标题层级 / 宽松行距 / 发丝线 / 柔和投影 |
| 低 | 有序↔无序互转会把序号全刷成 `1.` | ✅ 已修（按层级编号，`toOrdered`/`toBullet`） |
| 低 | 多行列表整体降级只去第一行标记 | ✅ 已修（`stripMarkers` 逐行去 + 任务标记连续剥两层） |

## 运行

```bash
cd Quickmd && ./build.sh && open Quickmd.app        # 构建 + 运行
ICON=2 ./build.sh                                   # 换图标（1 终端绿 / 2 蓝图靛蓝 / 3 像素琥珀）
node Tests/editor-core.test.js                      # 单测（79 项）
QUICKMD_DEBUG=1 ./Quickmd.app/Contents/MacOS/Quickmd --mdtest|--domtest|--clicktest|--blockcount|--logintest|--show-now
./Quickmd.app/Contents/MacOS/Quickmd --shot|--dark-shot   # 面板截图（UI 观感自检）
```

日志：`~/Documents/Quickmd/quickmd.log`

## 文档导航

- 想了解「为什么这么设计」→ `memory/项目历史决策.md`
- 想了解编辑器完整规格（格式/快捷键/行为规则/安全规范）→ `docs/03-使用与实现/Q便签-v2-Markdown编辑器-实现说明.md`
- 想逐条手动验收功能 → `docs/03-使用与实现/v3-手动测试清单.md`
- 想看 v3 的需求对齐与决策记录 → `docs/04-需求对齐/v3-需求对齐清单.md`
- 想加新块类型（表格/图片等）→ 按 `parse → renderBlock → blockMD` 三处对称扩展，并补 Node 单测
