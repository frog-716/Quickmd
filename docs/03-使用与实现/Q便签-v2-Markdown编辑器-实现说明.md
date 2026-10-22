# Q便签 v2 — Markdown 所见即所得编辑器 · 实现说明

> 版本：v2（Markdown WYSIWYG 版）
> 日期：2026-10-22
> 状态：已构建、已测试、可直接运行
> 定位：不换 App、不加 Dock 图标、不花钱，获得接近系统「快速备忘录」的 Markdown 编辑体验

> **沿革注记（2026-10-22 迁移时补）**：本项目已从会话工作区迁移至 `/Users/frog/Projects/Quick-md/`，App 更名为 **Quickmd**。本文写于迁移前，文中旧名与现名的对应关系：
> - `QNotes/` 目录 → `Quickmd/`；`Sources/QNotes/` → `Sources/Quickmd/`
> - `QNotes.app` → `Quickmd.app`；菜单「退出 Q便签」→「退出 Quickmd」
> - `~/Documents/QuickMD/` → `~/Documents/Quickmd/`；`QNOTES_DEBUG` → `QUICKMD_DEBUG`
> - JS↔Swift 消息通道 `qnotes` → `quickmd`（CSS 类名 `qn-*` 前缀为内部实现标识，保留）
> - 当前最新结构以项目根目录 `README.md` 为准

---

## 0. 一句话概览

把 v1 的纯文本输入框换成了一个**分块 WYSIWYG Markdown 编辑器**：文档在内存里被切成「块」（标题/段落/列表/引用/代码/分隔线），每块独立渲染、独立编辑；保存时把 DOM 反序列化回标准 Markdown 写盘。敲 `#` 前缀、点工具栏、勾选任务时才重渲染，**普通打字不动 DOM，光标不跳**。

---

## 1. 规格一：核心编辑功能与格式规范

### 1.1 支持的格式（输入即 Markdown 语法，显示即渲染效果）

| 格式 | Markdown 写法 | 渲染效果 | 备注 |
|---|---|---|---|
| 一级/二级/三级标题 | `# ` `## ` `### ` | 大/中/小标题 | 敲完空格即变形 |
| 加粗 | `**文字**` | **文字** | |
| 斜体 | `*文字*` 或 `_文字_` | *文字* | |
| 删除线 | `~~文字~~` | ~~文字~~ | |
| 行内代码 | `` `代码` `` | 等宽底色 | 内容不参与其他行内解析 |
| 链接 | `[文字](https://…)` | 可点链接，新标签打开 | 协议白名单过滤（见 1.4） |
| 裸 URL | 直接粘贴 `https://…` | 自动变链接 | |
| 无序列表 | `- ` / `* ` / `+ ` | 圆点列表 | 支持缩进嵌套 |
| 有序列表 | `1. ` | 编号列表 | 支持缩进嵌套 |
| 任务列表 | `- [ ] ` / `- [x] ` | 可点击勾选框 | 点击方框切换完成态 |
| 引用 | `> ` | 左侧竖线引用块 | 连续行合并为一块 |
| 代码块 | ` ``` ` 围栏 | 等宽块，首行可写语言名 | 语言标签往返不丢 |
| 分隔线 | `---` / `***` / `___` | 水平分隔线 | |

### 1.2 快捷键

| 快捷键 | 功能 |
|---|---|
| `⌘B` / `⌘I` / `⇧⌘X` | 加粗 / 斜体 / 删除线 |
| `⌘E` | 行内代码（选中文字包裹） |
| `⌘K` | 插入链接 |
| `⌘S` | 立即保存（不等防抖） |
| `⌘1` `⌘2` `⌘3` | 当前块转一/二/三级标题 |
| `⌘7` `⌘8` `⌘9` | 当前块转无序/有序/引用 |
| `Enter` | 拆出新块；在列表项末按则续一个新列表项 |
| `Backspace` | 行首按下则剥掉块标记，降级为普通段落 |
| `Tab` | 插入两个空格（列表内即缩进嵌套） |
| `Esc` | 关闭面板（内容已保存） |

工具栏与快捷键一一对应，另有「代码块」「正文」两个按钮（无快捷键）。

### 1.3 编辑行为规则

- **敲前缀即变形**：在普通段落行首敲 `# `、`- `、`> ` 等，输入停顿即自动转成对应块，无需回车确认。
- **光标保持**：变形后用「文本偏移」恢复光标位置，不用浏览器 Selection 的 sticky 逻辑，光标不会跳到块尾。
- **点击空白聚焦最后一块**，与系统快速备忘录一致。
- **状态栏实时显示**：保存状态（就绪/未保存/已保存 时:分:秒）、字数（中日韩字符按字计，英文按词计）、当前文件名。

### 1.4 安全规范（自研编辑器必守的底线）

- 所有用户文本进 DOM 前 **HTML 转义**（`& < > "`），脚本标签无法注入。
- 链接协议**白名单**：仅放行 `https?://` `mailto:` `tel:` `#` `/` `./` `../` 及相对路径；`javascript:` `data:` `vbscript:` 等一律降级为 `#`。
- 属性边界转义：URL 进 `href` 前二次转义，防止 `"` 突破属性边界。
- 以上三条有单测覆盖（53 项测试中的 XSS 组）。

---

## 2. 规格二：文档的打开与加载方式

### 2.1 三种打开方式

| 方式 | 操作 | 说明 |
|---|---|---|
| 默认便签 | 无需操作，首次启动自动加载 | `~/Documents/QuickMD/scratch.md`，不存在则创建 |
| 菜单打开 | 状态栏菜单 →「打开 Markdown 文件…」或 `⌘O` | 系统文件面板选 `.md` |
| 拖入 | 把 `.md` 文件拖到面板上 | 松手即加载，非 `.md` 忽略 |

打开新文件后，自动保存的目标切换到新文件；状态栏文件名同步更新。

### 2.2 加载链路（代码级）

```
启动
 └─ AppDelegate 建 WKWebView，loadFileURL 加载 editor.html（本地资源包）
     └─ JS init() → post({type:'ready'})
         └─ Swift 收到 ready → 读 storeURL 内容
             └─ evaluateJavaScript: window.QN.load(JSON字符串, 文件名)
                 └─ JS: parse(md) → blocks → 逐块 createBlockEl → DOM
```

关键点：

- WebView 加载的是 **app 资源包内的本地 HTML**（`Bundle.module` → `editor.html`），不走网络，无远程依赖。
- Swift→JS 走 `evaluateJavaScript`，内容以 **JSON 字符串**传递（`JSONSerialization` 生成），避免引号注入 JS 上下文。
- JS→Swift 走 `WKScriptMessageHandler`（通道名 `qnotes`），只有两类消息：`ready`（编辑器就绪，可以推内容了）、`save`（携带序列化好的 md）。
- **pendingContent 机制**：若 `ready` 到达时 Swift 还没准备好内容（不会发生，但防御性编程），先挂起，ready 后补推。

### 2.3 保存链路

```
用户输入 → scheduleSave() → 400ms 防抖 → flush()
   └─ getMarkdown(): 遍历 .qn-block，blockMD() 逐块序列化，块间 '\n\n' 连接
       └─ post({type:'save', md})
           └─ Swift saveContent(md) → 写盘（storeURL 或当前打开的文件）
```

- **防抖 400ms**：停笔半秒才落盘，打字过程中不写文件。
- **⌘S / Esc / 关面板前强制 flush**：`saveTimer` 立即执行，不丢最后几个字。
- **块间空行**：序列化时块与块之间用空行连接（CommonMark 规范），存出的 `.md` 文件在 Typora/VS Code 等标准渲染器里段落不会并成一块；本编辑器重新打开时块结构也保持稳定（二次解析块数不变，有单测覆盖）。
- 写盘后状态栏显示「已保存 时:分:秒」，未保存时圆点变黄显示「未保存」。

---

## 3. 规格三：完整使用流程与交互方式

### 3.1 主流程

```
① 鼠标碰到屏幕顶部刘海区域（含左右各 10pt 余量）
      ↓  面板滑出（330×285pt，与系统快速备忘录同尺寸），此时是「预览态」——
      │  不抢键盘焦点，别的窗口照常打字
② 点击面板
      ↓  进入「激活态」：面板获得键盘焦点，可以打字；
      │  面板被「钉住」，鼠标移开也不收起
③ 编辑：所见即所得，⌘B/⌘1/点工具栏/敲前缀 随便用
      ↓  停笔 0.4 秒自动存盘；Esc 前再强制存一次
④ Esc（或点击面板外）
      ↓  面板收起，内容已在 ~/Documents/QuickMD/scratch.md
```

### 3.2 交互细节（v1 踩坑后的修正）

- **hover 不 activate**：预览态只 `orderFrontRegardless()`，绝不抢焦点——这是「不打扰」的关键。
- **停留区（stay region）**：鼠标从刘海移进面板的路径上有一片判定区，防止「一碰刘海→展面板→鼠标往下移→判定离开→面板抖一下收起」。
- **钉住（pin）**：点击面板后 `isPinned = true`，此时鼠标满屏跑面板都不收；只有 Esc 或失活（`windowDidResignKey`）才收。
- **30Hz 轮询 `NSEvent.mouseLocation`**：不用全局鼠标监听，因此**不需要辅助功能权限**，系统设置里零授权项。
- **刘海几何自适应**：`safeAreaInsets.top > 0` + `auxiliaryTopLeft/RightArea` 实时计算刘海宽度，外接屏（无刘海）时自动退化为「菜单呼出」模式，不会把面板放到屏幕外。

### 3.3 状态栏

```
● 已保存 14:32:05 · 128 字 · scratch.md · Esc 关闭 · 可拖入 .md 文件
```

- 圆点：黄=未保存，灰=已保存
- 字数：实时
- 文件名：当前文档（拖入/打开新文件后变化）

---

## 4. 规格四：内存占用与优化方向

### 4.1 实测数据（MacBook Air M5，`footprint` 差分法）

| 场景 | 主进程 | WebContent 子进程 | 总计 |
|---|---|---|---|
| 空文档（基线） | 20 MB | ≈17 MB | **≈37 MB** |
| 日常小文档（几百字） | 20 MB | ≈17 MB | **≈37 MB** |
| 大文档 72 KB / 1286 块 | 20 MB | ≈22 MB | **≈42 MB** |

### 4.2 结论

- **日常使用约 37 MB**，属于「迷你进程」量级——作为参照，一个 Chrome 标签页通常 100–300 MB。
- **文档规模对内存几乎不敏感**：1286 块的大文档也只多 5 MB。因为分块渲染后每块只是一个小的 contenteditable div，且只有变形时才重建 DOM。
- **主进程 20 MB 是固定底座**（Swift 运行时 + NSPanel + 刘海轮询定时器），与文档无关。

### 4.3 优化方向（按性价比排序）

1. **大文档懒渲染**（>300 块时）：只渲染视口附近 ±30 块，滚动时按需创建/回收。当前 42 MB 完全够用，此项是给「万字长文」预留的余量。
2. **轮询降频**：刘海检测从 30Hz 降到 15Hz 几乎无感（人手移动速度远低于此），可再省一丝 CPU；更激进的做法是仅在鼠标接近屏幕顶部 100pt 时才启用高频轮询。
3. **WebView 预热已做**：编辑器 HTML 只在启动时加载一次，之后所有文档切换都走 `window.QN.load()` 原地重建块，不重新创建 WKWebView——避免了重复的进程冷启动开销。
4. **保存合并**：400ms 防抖已保证连续打字只写一次盘；若接入 iCloud 同步，建议再加 2 秒写合并窗口，避免同步 API 被高频触发。

---

## 5. 代码结构与构建运行

### 5.1 文件清单

```
QNotes/
├── Package.swift                      # SwiftPM 清单（含资源声明）
├── build.sh                           # 一键构建 + 打包 .app
├── Sources/QNotes/
│   ├── main.swift                     # 527 行：AppKit 主程序
│   │   ├── NotchPanel                 #   NSPanel 子类，控制 canBecomeKey
│   │   ├── PanelContainerView         #   圆角容器 + 点击激活 + 拖入 .md
│   │   ├── AppDelegate                #   刘海几何/触发轮询/菜单/桥接
│   │   └── WKScriptMessageHandler     #   JS→Swift：ready / save
│   └── Resources/
│       ├── editor.html                # 工具栏 + 编辑区 + 状态栏骨架
│       ├── editor.css                 # 飞书云文档风样式，深浅色自动适配
│       └── editor.js                  # 793 行：编辑器内核（核心资产）
│           ├── 纯函数层                #   esc/safeURL/inline/parse/renderBlock
│           ├── DOM 序列化层            #   serializeNode/blockMD（保存的地基）
│           ├── 块操作层                #   createBlockEl/renderInto/focusBlock
│           └── 事件与接口层            #   keydown/工具栏/任务勾选/window.QN
└── Tests/
    └── editor-core.test.js             # 55 项 Node 单测（含 XSS 组）
```

### 5.2 架构图

```
   Markdown 文本                用户看到的/编辑的
        │                            ▲
        ▼                            │
  ┌───────────┐   renderBlock   ┌──────────┐
  │  parse()  │ ──────────────▶ │   DOM    │
  │  md→blocks│                 │ 分块渲染  │
  └───────────┘                 └──────────┘
        ▲                            │
        │   blockMD/serializeNode    │ 打字（不动 DOM）
        └────────────────────────────┘
                 保存时（400ms 防抖）
```

**核心设计决策**：只有「需要变形」的操作（敲前缀、点工具栏、勾任务、⌘B 包裹）才走「序列化当前块 → 改 md → 重渲染该块 → 按文本偏移恢复光标」；普通输入交给浏览器原生 contenteditable 处理。这就是光标不跳、性能够好的根本原因。

### 5.3 构建与运行

```bash
cd QNotes
./build.sh          # swift build -c release --disable-sandbox + 打包 QNotes.app
open QNotes.app     # 运行
```

> 注意：SwiftPM 在本机需要 `--disable-sandbox`（沙箱会拦资源拷贝），build.sh 已内置。

**诊断开关**（排障用，日常无视）：

| 启动参数 | 作用 |
|---|---|
| `--show-now` | 启动即展开面板 + 打印键盘焦点自检 |
| `--mdtest` | 跑一遍 DOM→md 往返测试，控制台打印结果 |
| `--blockcount` | 打印当前文档块数 |
| `QNOTES_DEBUG=1` | 写日志到 `~/Documents/QuickMD/qnotes.log` |

### 5.4 测试结论

| 测试 | 结果 |
|---|---|
| Swift 编译 | 零 error 零 warning |
| JS 内核单测（Node） | **55 通过 / 0 失败** |
| 真实 WebView DOM 往返 | 标题/正文/列表/任务/引用/代码/分隔线**全部原样还原**，块间空行符合 CommonMark |
| 大文档渲染（72KB/1286 块） | 正常渲染，内存 42 MB |
| 键盘焦点自检 | `isKeyWindow=true canBecomeKey=true NSApp.isActive=true` |
| 面板定位 | 刘海居中，330×285pt，frame `(570, 671, 330, 285)` |

---

## 6. 版本修订记录

### v2.1（2026-10-22，用户实测反馈修复）

| # | 问题 | 根因 | 修复 |
|---|---|---|---|
| 1 | 工具栏被刘海挡住 | 面板顶边贴屏幕顶（`y = maxY - height`），32pt 刘海盖住顶部 | `y = maxY - safeAreaInsets.top - height`，顶边贴刘海下沿（实测 y 671→639） |
| 2 | 点击后打不了字 | WKWebView 铺满面板，点击落在 WebView 子视图上，容器的 `mouseDown` 不触发 → `activatePanel()` 从不执行 → 面板停在 `canBecomeKey=false` 预览态，键盘进不去 | 新增 `EditorWebView` 子类：mouseDown 里先激活再 `super`；`activatePanel(fromClick:)` 区分点击/菜单路径，点击路径不抢焦点（光标落在点击处） |

> 教训：v2 的自检走 `--show-now` 显式激活路径，覆盖不到「预览态被点击」这条真实用户路径。现已新增 `--clicktest` 诊断开关（合成鼠标事件走 AppKit 真实分发，无需辅助功能权限），验证输出 `面板激活 fromClick=true` + `isKeyWindow=true` + `activeElement=qn-block|true`。

## 7. 已知边界（诚实清单）

1. **不支持表格、图片、脚注、公式**——刻意砍掉：快速便签场景用不到，且每加一种块类型，序列化往返的测试面就翻一倍。需要时按现有块模式扩展即可（parse → renderBlock → blockMD 三处对称加）。
2. **`⌘0`（转正文）没有快捷键**，只能用工具栏「正文」按钮。
3. **多文档不并存**：同时只有一个活动文档，打开新文件即切换。符合「快速备忘录」心智。
4. **代码块内不语法高亮**：只做等宽 + 底色，语言标签仅作标记保留。

---

## 8. 附：初始便签内容
首次运行会在 `~/Documents/QuickMD/scratch.md` 写入一份示例便签，演示全部格式。删掉它，下次启动会重建一份空的。
