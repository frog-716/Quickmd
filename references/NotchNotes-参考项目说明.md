# NotchNotes 参考项目说明

> 本项目的架构参考来源。**只参考思路，未 fork、未复制代码。**

## 项目信息

- **仓库**：https://oil-oil.github.io/NotchNotes/（GitHub: oil-oil/NotchNotes）
- **技术栈**：Swift + AppKit（浮层/窗口层级/定位/触发）+ SwiftUI（UI）+ UserDefaults + Vendor swift-markdown-engine
- **平台**：macOS 14+，`swift run` 可构建，无需 Xcode
- **规模**：92 stars，维护至 2026-10

## ⚠️ License 风险（本项目选择自研的根本原因）

- **仓库无 LICENSE 文件（license: null）** → 按版权法默认保留所有权利
- fork 改造再分发有法律风险；个人私用属灰色地带
- 正路是开 issue 请作者授权，或仅参考架构思路
- **本项目决策：只参考架构，从零自研**（2026-10-21 用户拍板）

## 参考了哪些模块

| NotchNotes 的做法 | 本项目的对应实现 | 差异 |
|---|---|---|
| 刘海 hover 检测 | `main.swift` 的 30Hz 轮询 `NSEvent.mouseLocation` | NotchNotes 用全局 mouseMoved 监听（需辅助功能权限）；本项目改用轮询实现**零权限** |
| Hover 展开 / Click 激活 | `showPanelIfNeeded()`（不 activate）/ `activatePanel()`（钉住） | 增加「停留区」判断，防止鼠标移进面板即触发收起 |
| NSPanel 层级与定位 | `level = .statusBar + 2`，`collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]` | 刘海宽度用 `auxiliaryTopLeftArea/RightArea` 实时推算，不硬编码 |
| Menu Bar Only 模式 | 菜单栏图标 + 完整菜单 | — |

## 未采用的部分

- **编辑器内核**：NotchNotes 用 Vendor 的 swift-markdown-engine；本项目自研分块 WYSIWYG（WKWebView + contenteditable），因为要飞书式编辑手感且需要完全掌控序列化往返
- **触发方式**：本项目用户场景是「碰刘海」而非 NotchNotes 的上滑手势

## 备注

- 参考用克隆未随项目迁移（外部仓库副本，不构成本项目沉淀）；如需查阅可按上方地址重新 clone
