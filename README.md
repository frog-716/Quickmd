# Quickmd

> 刘海一碰就出来的 Markdown 快速便签。不换 App、不占程序坞、不花钱。

## 这是什么

一个常驻 macOS 菜单栏的超小进程：鼠标蹭一下屏幕顶部刘海 → 便签面板滑出（330×285pt，与系统「快速备忘录」同尺寸）→ 点一下就能打字 → Esc 收起，内容已自动存盘。

- **编辑器**：分块 WYSIWYG Markdown（备忘录式手感），敲 `#` 前缀即变形，光标不跳
- **交互**：v3 起**没有工具栏、没有功能按钮**——全部靠「前缀语法 + 快捷键」，界面只剩编辑区
- **视觉**：参考 macOS 备忘录——暖白纸面、大标题层级、宽松行距、柔和投影
- **数据**：纯 `.md` 文件落在 `~/Documents/Quickmd/`，任何标准 Markdown 工具都能打开
- **权限**：零辅助功能权限（30Hz 轮询鼠标位置，不用全局监听）
- **开机自启**：普通启动首次自动注册登录项，菜单栏可随时开关；开发启动会暂时关闭，避免旧版本或调试版跟着登录启动
- **体积**：App 约 1.3MB（其中可执行文件 240KB、应用图标 1MB、编辑器资源 52KB）
- **内存**：日常约 34MB（主进程 20MB + 编辑器 14MB）；装一份 77KB 的碎文档也只涨到 44MB

## 快速开始

```bash
cd Quickmd
./build.sh            # swift build -c release --disable-sandbox + 打包
open Quickmd.app      # 运行
```

## 开发时怎么启动和更新

开发期间用这个入口：

```bash
cd Quickmd
./dev.sh              # 先退出正在运行的版本，再重新构建并启动最新代码
./dev.sh stop         # 只退出 Quickmd
./dev.sh --show-now   # 重建启动，并附带一个诊断参数
```

每次改完代码再运行一次 `./dev.sh`，就会把新代码打进 App 并重新打开。开发启动会临时关闭开机自启；普通启动时恢复进入开发模式前的设置。如果此前从未正常启动过，首次普通启动仍会按默认设置开启自启。

> SwiftPM 需要 `--disable-sandbox`（build.sh 已内置）；无需 Xcode，纯 Command Line Tools 可构建。
> 首次运行会在 `~/Documents/Quickmd/` 创建 `scratch.md`（空白便签）。
>
> **图标**：应用图标源图在 `assets/icons/source-reference.jpg`，构建时自动打入；想换图重跑 `tools/make-doc-icon.swift` 生成即可。

## 手动测试

功能逐条验收清单在 `docs/03-使用与实现/v3-手动测试清单.md`——照着表格从上往下点一遍即可。

## 怎么用（v3 速查表）

**没有工具栏。** 所有格式靠下面两样东西：敲前缀自动变形，或按快捷键。

| 想要 | 敲这个 | 快捷键 |
|---|---|---|
| 一级 / 二级 / 三级标题 | `# ` `## ` `### ` + 空格 | ⌘1 / ⌘2 / ⌘3 |
| 有序列表 | `1. ` + 空格 | ⌘8 |
| 有序列表（指定起始号） | `3. ` + 空格（渲染成 3、4、5…） | — |
| 无序列表 | `- ` 或 `* ` + 空格 | ⌘7 |
| 任务清单 | `- [ ] ` 或 `- [x] ` + 空格 | 点勾选框切换 |
| 引用 | `> ` + 空格 | ⌘9 |
| 加粗 / 斜体 / 删除线 | `**文字**` `*文字*` `~~文字~~` | ⌘B / ⌘I / ⇧⌘X |
| 分隔线 | `---` | — |
| 列表续号 / 缩进 | 回车自动续号 | Tab / ⇧Tab |
| 打开别的 .md | — | ⌘O（菜单栏图标 → 打开 Markdown 文件…） |
| 关闭面板（自动存盘） | — | Esc |

> **有序列表续号按 Typora 的规矩**：写 `1. ` 回车变 `2.`，再回车变 `3.`；
> 写 `3. ` 就从 3 开始（3、4、5…），存盘后重新打开序号不丢。
> 空列表项上再回车会**退出列表**变成普通段落。

| 其他 | 方式 |
|---|---|
| 呼出 / 收起 | **鼠标碰到刘海本体** / Esc |
| 激活打字 | 点击面板（预览态不抢键盘焦点） |
| 保存 | 停笔约 0.2 秒后自动存盘；不需要手动保存 |
| 开机自启 | 菜单栏 Quickmd 图标 →「开机自启」勾选 |

> **触发区说明（v3 收紧）**：热区只认「刘海本体」这一条带子（实测 179×36pt），
> 鼠标必须真的碰到刘海才会唤出面板。旧版向下多延伸了 46pt，鼠标离刘海还有一段就弹出来，误触率高。
> 从刘海滑进面板不会导致面板抖动收起。

> 链接仍可写：`[文字](https://…)` 会渲染成可点链接。v3 起不再提供「选中文本弹框插链接」的按钮（该功能在 v2 因缺 `WKUIDelegate` 一直是坏的，且有 XSS 风险，已整体移除）。

## 开机自启怎么控制

目前没有单独的设置窗口；开机自启可以直接在菜单栏 Quickmd 菜单里开关。

平时有两种方式管理：

1. **App 菜单栏图标 →「开机自启」**（推荐）：勾选/取消即时生效
2. **系统设置 → 通用 → 登录项**：能看到 Quickmd，随时关掉

普通方式首次运行会自动开启（这是本项目的既定功能）。技术实现是苹果官方 `SMAppService`（macOS 13+）；若注册失败会自动降级为 `~/Library/LaunchAgents` 里的 plist，功能不丢。开发时运行 `./dev.sh` 会暂时关闭开机自启；下一次普通启动会恢复进入开发模式前的设置。

命令行自检：`QUICKMD_DEBUG=1 ./Quickmd.app/Contents/MacOS/Quickmd --logintest`。

## 目录导览

```
Quick-md/
├── README.md                        ← 本文件
├── MAP.md                           ← 项目地图：结构/链路/约定/问题清单
├── docs/
│   ├── 01-调研与选型/               # 前期调研：备忘录改 MD 可行性 ×2、中间层压力测试、
│   │                                #   工具选择手册、flomo 拆解
│   └── 03-使用与实现/               # 编辑器实现说明、v3 手动测试清单
├── assets/icons/                    # 应用图标（源图 + .icns）
├── tools/                           # 图标生成脚本（从源图裁剪合成，可复现）
├── memory/
│   └── 项目历史决策.md              # 从第一天起的决策链与踩坑记录
├── references/
│   └── NotchNotes-参考项目说明.md   # 参考了哪些模块、license 风险、为什么只参考不 fork
└── Quickmd/                         # App 源码（SwiftPM）
    ├── Package.swift
    ├── build.sh
    ├── dev.sh                       # 开发启动：停止旧版、重建并启动；支持 stop 和诊断参数
    ├── Info.plist
    ├── Sources/Quickmd/
    │   ├── main.swift               # 入口（只负责起 App）
    │   ├── AppDelegate.swift        # 组装与生命周期
    │   ├── NotchPanel.swift         # 面板两态（预览/激活）
    │   ├── PanelContainerView.swift # 圆角容器 + 柔和投影 + 点击激活
    │   ├── EditorWebView.swift      # 内嵌编辑器（点击转激活）
    │   ├── NotchTrigger.swift       # 刘海几何 + 30Hz 轮询
    │   ├── DocumentStore.swift       # 文档读写（原子写）
    │   ├── Bridge.swift             # JS ↔ Swift 消息通道
    │   ├── StatusMenu.swift         # 菜单栏
    │   ├── LoginItemController.swift # 开机自启
    │   └── Resources/               # editor-core.js / editor.js / editor.html / editor.css
    └── Tests/editor-core.test.js    # 79 项 Node 单测
```

## 诊断开关

```bash
QUICKMD_DEBUG=1 ./Quickmd.app/Contents/MacOS/Quickmd --show-now    # 启动即展开 + 键盘自检
QUICKMD_DEBUG=1 ./Quickmd.app/Contents/MacOS/Quickmd --mdtest      # 真实 WebView DOM 往返测试
QUICKMD_DEBUG=1 ./Quickmd.app/Contents/MacOS/Quickmd --domtest     # 前缀变形 / 任务列表 / Tab 缩进 / 有序续号 自检
QUICKMD_DEBUG=1 ./Quickmd.app/Contents/MacOS/Quickmd --clicktest   # 合成点击，验证激活链路
QUICKMD_DEBUG=1 ./Quickmd.app/Contents/MacOS/Quickmd --blockcount  # 块数诊断
QUICKMD_DEBUG=1 ./Quickmd.app/Contents/MacOS/Quickmd --logintest   # 开机自启自检
./Quickmd.app/Contents/MacOS/Quickmd --shot                       # 面板截图 -> /tmp/quickmd-shot.png
```

日志写在 `~/Documents/Quickmd/quickmd.log`。

## 已知边界

- 不支持表格 / 图片 / 脚注 / 公式（刻意砍掉，快速便签用不到）
- 代码块无语法高亮（语言标签仅保留）
- 单活动文档（打开新文件即切换）
- 面板尺寸固定 330×285（刘海下面就那么大）
