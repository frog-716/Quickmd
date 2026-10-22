# Quickmd

> 刘海一碰就出来的 Markdown 快速便签。不换 App、不占程序坞、不花钱。

## 这是什么

一个常驻 macOS 菜单栏的超小进程：鼠标蹭一下屏幕顶部刘海 → 便签面板滑出（330×285pt，与系统「快速备忘录」同尺寸）→ 点一下就能打字 → Esc 收起，内容已自动存盘。

- **编辑器**：分块 WYSIWYG Markdown（飞书云文档式手感），敲 `#` 前缀即变形，光标不跳
- **交互**：v3 起**没有工具栏、没有功能按钮**——全部靠「前缀语法 + 快捷键」，界面只剩编辑区和一行状态栏
- **数据**：纯 `.md` 文件落在 `~/Documents/Quickmd/`，任何标准 Markdown 工具都能打开
- **权限**：零辅助功能权限（30Hz 轮询鼠标位置，不用全局监听）
- **开机自启**：首次运行自动注册登录项，菜单栏可随时开关
- **体积**：App 264KB；内存空闲约 33MB（主进程 18MB + 编辑器 15MB）

## 快速开始

```bash
cd Quickmd
./build.sh            # swift build -c release --disable-sandbox + 打包
open Quickmd.app      # 运行
```

> SwiftPM 需要 `--disable-sandbox`（build.sh 已内置）；无需 Xcode，纯 Command Line Tools 可构建。
> 首次运行会在 `~/Documents/Quickmd/` 创建 `scratch.md`（空白便签）。

## 怎么用（v3 速查表）

**没有工具栏。** 所有格式靠下面两样东西：敲前缀自动变形，或按快捷键。

| 想要 | 敲这个 | 快捷键 |
|---|---|---|
| 一级 / 二级 / 三级标题 | `# ` `## ` `### ` + 空格 | ⌘1 / ⌘2 / ⌘3 |
| 有序列表 | `1. ` + 空格 | ⌘8 |
| 无序列表 | `- ` 或 `* ` + 空格 | ⌘7 |
| 任务清单 | `- [ ] ` 或 `- [x] ` + 空格 | 点勾选框切换 |
| 引用 | `> ` + 空格 | ⌘9 |
| 加粗 / 斜体 / 删除线 | `**文字**` `*文字*` `~~文字~~` | ⌘B / ⌘I / ⇧⌘X |
| 分隔线 | `---` | — |
| 列表缩进 / 减缩进 | — | Tab / ⇧Tab |
| 立即保存 | — | ⌘S |
| 打开别的 .md | — | ⌘O（菜单栏图标 → 打开 Markdown 文件…） |
| 关闭面板（自动存盘） | — | Esc |

| 其他 | 方式 |
|---|---|
| 呼出 / 收起 | 鼠标碰刘海热区 / Esc |
| 激活打字 | 点击面板（预览态不抢键盘焦点） |
| 保存 | 停笔 0.4 秒自动存盘；⌘S 立即保存 |
| 开机自启 | 菜单栏 Quickmd 图标 →「开机自启」勾选 |

> 链接仍可写：`[文字](https://…)` 会渲染成可点链接。v3 起不再提供「选中文本弹框插链接」的按钮（该功能在 v2 因缺 `WKUIDelegate` 一直是坏的，且有 XSS 风险，已整体移除）。

## 开机自启怎么控制

三种方式，效果一致：

1. **App 菜单栏图标 →「开机自启」**（推荐）：勾选/取消即时生效
2. **系统设置 → 通用 → 登录项**：能看到 Quickmd，随时关掉
3. **命令行**：`QUICKMD_DEBUG=1 ./Quickmd.app/Contents/MacOS/Quickmd --logintest` 切换一次并打印结果

首次运行会自动开启（这是本项目的既定功能）。技术实现是苹果官方 `SMAppService`（macOS 13+）；若注册失败会自动降级为 `~/Library/LaunchAgents` 里的 plist，功能不丢。

## 目录导览

```
Quick-md/
├── README.md                        ← 本文件
├── MAP.md                           ← 项目地图：结构/链路/约定/问题清单
├── docs/
│   ├── 01-调研与选型/               # 前期调研：备忘录改 MD 可行性 ×2、中间层压力测试、
│   │                                #   工具选择手册、flomo 拆解
│   ├── 02-设计与方案/               # 技术方案、NotchNotes 刘海改造可行性
│   ├── 03-使用与实现/               # MVP 使用说明、v2 实现说明（四项规格）
│   └── 04-需求对齐/                 # v3 需求对齐清单与决策记录
├── memory/
│   └── 项目历史决策.md              # 从第一天起的决策链与踩坑记录
├── references/
│   └── NotchNotes-参考项目说明.md   # 参考了哪些模块、license 风险、为什么只参考不 fork
└── Quickmd/                         # App 源码（SwiftPM）
    ├── Package.swift
    ├── build.sh
    ├── Info.plist
    ├── Sources/Quickmd/
    │   ├── main.swift               # 入口（只负责起 App）
    │   ├── AppDelegate.swift        # 组装与生命周期
    │   ├── NotchPanel.swift         # 面板两态（预览/激活）
    │   ├── PanelContainerView.swift # 圆角容器 + 点击激活
    │   ├── EditorWebView.swift      # 内嵌编辑器（点击转激活）
    │   ├── NotchTrigger.swift       # 刘海几何 + 30Hz 轮询
    │   ├── DocumentStore.swift       # 文档读写（原子写）
    │   ├── Bridge.swift             # JS ↔ Swift 消息通道
    │   ├── StatusMenu.swift         # 菜单栏
    │   ├── LoginItemController.swift # 开机自启
    │   └── Resources/               # editor-core.js / editor.js / editor.html / editor.css
    └── Tests/editor-core.test.js    # 67 项 Node 单测
```

## 诊断开关

```bash
QUICKMD_DEBUG=1 ./Quickmd.app/Contents/MacOS/Quickmd --show-now    # 启动即展开 + 键盘自检
QUICKMD_DEBUG=1 ./Quickmd.app/Contents/MacOS/Quickmd --mdtest      # 真实 WebView DOM 往返测试
QUICKMD_DEBUG=1 ./Quickmd.app/Contents/MacOS/Quickmd --domtest     # 前缀变形 / 任务列表 / Tab 缩进自检
QUICKMD_DEBUG=1 ./Quickmd.app/Contents/MacOS/Quickmd --clicktest   # 合成点击，验证激活链路
QUICKMD_DEBUG=1 ./Quickmd.app/Contents/MacOS/Quickmd --blockcount  # 块数诊断
QUICKMD_DEBUG=1 ./Quickmd.app/Contents/MacOS/Quickmd --logintest   # 开机自启自检
```

日志写在 `~/Documents/Quickmd/quickmd.log`。

## 已知边界

- 不支持表格 / 图片 / 脚注 / 公式（刻意砍掉，快速便签用不到）
- 代码块无语法高亮（语言标签仅保留）
- 单活动文档（打开新文件即切换）
- 有序列表回车续项从 `1.` 重新编号
