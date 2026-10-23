# Quickmd 项目地图（MAP）

> 一句话：常驻 macOS 菜单栏的超小 Markdown 便签——鼠标碰屏幕刘海就出面板，所见即所得编辑，内容以纯 `.md` 文件落盘。
> 最后更新：2026-10-23（砍掉深色模式固定浅色；文档只保留当前状态，删除历史设计与决策纪要）

## 核心结构

```
Quick-md/                        # 仓库根
├── README.md                    # 项目门面：定位 / 速查表 / 开发运行 / 开机自启 / 已知边界
├── MAP.md                       # 本文件
├── docs/                        # 01 调研选型 · 03 使用与实现（只留当前状态）
├── assets/icons/                # 应用图标（source-reference.jpg 源图 + Quickmd.icns）
├── tools/                       # make-doc-icon.swift：从源图裁剪合成 .icns（可复现）
├── memory/项目历史决策.md        # 从第一天起的决策链与踩坑（为什么这么做）
└── Quickmd/                     # SwiftPM 包（App 源码，无 Xcode 工程）
    ├── Package.swift            # 平台 macOS 14+ / 资源声明（零第三方依赖）
    ├── build.sh                 # swift build release --disable-sandbox + 打包 .app + 装图标
    ├── dev.sh                   # 开发入口：退出旧版、重建并启动；支持 stop 和诊断参数
    ├── Sources/Quickmd/
    │   ├── main.swift           # 入口：起 NSApplication + AppDelegate
    │   ├── AppDelegate.swift    # 组装与生命周期、面板两态、诊断开关、截图自检
    │   ├── NotchPanel.swift     # 面板：canBecomeKey 可切换（预览态/激活态）
    │   ├── PanelContainerView.swift # 圆角容器 + 柔和投影 + 点击激活
    │   ├── EditorWebView.swift  # 内嵌编辑器：把点击转成激活
    │   ├── NotchTrigger.swift   # 刘海几何 + 30Hz 轮询 + 停留区判定
    │   ├── DocumentStore.swift  # 当前文档读写（原子写）
    │   ├── Bridge.swift         # JS→Swift 消息通道（弱引用，避免引用环）
    │   ├── StatusMenu.swift     # 菜单栏（4 项：面板开关、打开文件、开机自启、退出）
    │   ├── LoginItemController.swift # 开机自启：SMAppService，失败降级 LaunchAgent
    │   └── Resources/
    │       ├── editor-core.js   # 纯函数内核（esc/inline/parse/renderBlock），Node 可测
    │       ├── editor.js         # 浏览器层：DOM 序列化 / 块操作 / 事件 / 保存
    │       ├── editor.html       # 界面骨架（v3 起无工具栏）
    │       └── editor.css        # 样式：固定浅色的备忘录风暖纸面（不跟随系统深浅色）
    └── Tests/editor-core.test.js# 79 项 Node 单测（只测纯函数层）
```

## 三条主链路

1. **触发**：30Hz 轮询 `NSEvent.mouseLocation` → 命中刘海热区 → `orderFrontRegardless` 预览态（不抢键盘）→ 点击激活（`makeKeyAndOrderFront` + 钉住）→ Esc / 失活收起
2. **编辑**：`editor-core.js` 分块 WYSIWYG —— md → `parse` → blocks → `renderBlock` → DOM；普通打字不动 DOM，仅「变形」时重渲染该块并按文本偏移恢复光标
3. **存取**：JS `getMarkdown()` 序列化 DOM → md → 停笔 200ms 后 `postMessage({type:'save'})` → Swift 立即原子写盘 `~/Documents/Quickmd/*.md`；Esc 和收起面板时立即保存

## 关键约定

- JS↔Swift 桥：下行 `evaluateJavaScript(window.QN.load(md, file))`；上行 `WKScriptMessageHandler` 通道名 `quickmd`，消息只有 `ready` / `save` 两类
- 前缀语法即入口（v3 无工具栏）：`# ` `## ` `### ` `1. ` `- ` `> ` `- [ ] ` `---`；快捷键 ⌘B/⌘I/⇧⌘X/⌘1-3/⌘7-9、Tab/⇧Tab 缩进
- 界面方向：像 macOS 备忘录一样用暖纸面和清楚的标题层级；**固定浅色**（WebView 外观强制 aqua）；主动作是点开后直接写 Markdown；面板固定 330×285pt；无底栏，任务框要看得出能点
- 块间连接用 `\n\n`（CommonMark）；代码块语言标签存 `data-lang` 属性
- XSS 三件套：`esc()` 全量转义 + `safeURL` 协议白名单 + 属性边界转义（v3 起链接只能手写 md，插入入口已移除，绕过面消失）
- 面板两态：预览态（`canBecomeKey=false`，不抢焦点）/ 激活态（钉住不收起）；`EditorWebView` 负责把点击转成激活
- 开机自启：普通启动首次运行自动开启（`UserDefaults` 打标记）；菜单栏可随时开关。`dev.sh` 以 `--dev` 启动时会暂存原设置并关闭自启，下次普通启动时恢复
- 开发运行：`cd Quickmd && ./dev.sh` 会退出旧进程、重建 App、再启动新版本；`./dev.sh stop` 只退出 App；诊断参数可直接跟在命令后
- CSS 类名前缀 `qn-` 为内部实现标识；App 内外名称统一为 Quickmd

## 当前产品形态（v3 起，2026-10-23 核对）

| 维度 | 现状 |
|---|---|
| 界面 | 无工具栏、无底栏、无状态栏；正文区铺满面板，功能全走「前缀语法 + 快捷键」 |
| 视觉 | 备忘录风暖纸面；**固定浅色**，WebView 外观强制 aqua，不跟随系统深浅色 |
| 功能入口 | 只剩前缀语法 + 快捷键；链接插入整体移除（链接只能手写 md） |
| 文件打开 | 菜单 ⌘O；**不支持拖拽打开** |
| 保存 | JS 停笔 200ms 后触发，Swift 收到即原子写盘；无手动保存 |
| 开机自启 | 首次运行自动注册（SMAppService，失败降级 LaunchAgent） |
| 代码结构 | 10 个 Swift 文件 + JS 拆纯函数/浏览器两层 |
| 光标恢复 | 变形后按「减去前缀长度」的文本偏移恢复，不跳块尾 |
| 内存 | 日常约 34MB（主进程 20MB + 编辑器 14MB）；77KB 碎文档也只到 44MB |

## 已知问题清单

| 级别 | 问题 | 状态 |
|---|---|---|
| 低 | `AppDelegate.swift` 里诊断自检代码约占一半篇幅，与产品逻辑混在一起 | 未处理（当前不影响功能，动它需先跑通 `--domtest`） |
| 低 | `editor-core.js` 的 `esc` / `safeURL` 只在模块内部使用，外部无消费者 | 未处理（属过度导出，删除无风险） |
| 低 | `editor.js` 的 `state.file` 只用于记录当前文件名，无其他用途 | 未处理（无害） |

## 运行

```bash
cd Quickmd
./dev.sh                                             # 开发：退出旧版、重建并启动最新版本
./dev.sh stop                                        # 退出 App
./dev.sh --show-now                                  # 重建启动并带诊断参数
./build.sh && open Quickmd.app                       # 普通启动（首次会开启开机自启）
cd ..
node Tests/editor-core.test.js                      # 单测（79 项）
QUICKMD_DEBUG=1 ./Quickmd.app/Contents/MacOS/Quickmd --mdtest|--domtest|--clicktest|--blockcount|--logintest|--show-now
./Quickmd.app/Contents/MacOS/Quickmd --shot                    # 面板截图（UI 观感自检）
```

日志：`~/Documents/Quickmd/quickmd.log`

## 文档导航

- 想了解「为什么这么设计」→ `memory/项目历史决策.md`
- 想了解编辑器完整规格（格式/快捷键/行为规则/安全规范）→ `docs/03-使用与实现/编辑器-实现说明.md`
- 想逐条手动验收功能 → `docs/03-使用与实现/v3-手动测试清单.md`
- 想加新块类型（表格/图片等）→ 按 `parse → renderBlock → blockMD` 三处对称扩展，并补 Node 单测
