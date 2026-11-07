# macOS 27 排查与九语言适配（2026-09-20）

状态：已实现代码修复并完成自动验证；新版实际隐藏、图像清晰度及语言排版仍待解锁后的交互验收。不能将本记录视为稳定版发布验收。

## 基线和范围

- GitHub 主分支 `787a67f`，原版本 `0.13.0-macos27.1 (1330)`；本地工作区原本只有一个无提交的 Git 仓库。
- 本次工作分支 `codex/macos27-localization`，开发版本 `0.13.0-macos27.2-dev (1331)`。
- 主机 macOS 27.0 `26A428`，Xcode 27.0 `27A266a`。
- 本机既有安装包 `/Applications/Ice.app` 是 `0.12.0-macos27.130 (1329)`，其 bundle identifier 与 FloeBar 相同。没有覆盖该安装包或重置其偏好、权限。
- 用户确认：关闭设置后仍无法隐藏；语言为英语、简体中文、繁体中文、日语、韩语、德语、法语、西班牙语、葡萄牙语（巴西）。

## 架构及上游核对

项目是 GPLv3 的 Ice 独立分支，主要使用 Swift、AppKit 和 SwiftUI。SwiftUI 承载设置，AppKit 管理原生 NSStatusItem、窗口及拖放；Combine 传播状态。AXSwift 负责辅助功能枚举，ScreenCaptureKit 提供截图，Sparkle 负责更新，LaunchAtLogin 管理登录启动。XPC 服务负责旧系统菜单项目的来源识别。

macOS 27 将菜单栏项目托管到 MenuBarAgent，旧系统按独立窗口枚举、截图和超宽分隔符隐藏的路径不能直接复用。当前实现采用 AX 原生项目身份和位置、FloeBar 自有空白边界的受限宽度、系统原生拖动及溢出。布局归属、原生位置、可见性请求、截图缓存是四层不同状态；设置里出现“隐藏”归属，不代表系统已实际遮蔽该项目。

已核对 GitHub：

- [PR #1](https://github.com/JackFloyd007/FloeBar/pull/1)：修复无 Team ID 的本地构建与 XPC 校验冲突、空缓存导致的无限加载。
- [PR #2](https://github.com/JackFloyd007/FloeBar/pull/2)：引入实验性 macOS 27 原生路径，明确保留快速切换、多屏和 MenuBarAgent 崩溃风险。
- [PR #3](https://github.com/JackFloyd007/FloeBar/pull/3)：独立签名和更新通道。
- [PR #4](https://github.com/JackFloyd007/FloeBar/pull/4)：更名 FloeBar，保留持久化身份和 bundle ID。

上述 PR 的历史通过记录不构成本次开发版本的交互验证。

## 已确认的问题与修复

### 1. 隐藏事务因为空白边界无法命中而失败

旧安装版在本次会话中的日志：

```text
19:46:02 Preparing native boundary (858.5, 4.5, 3.0, 24.0) beside Ice (918.0, 4.5, 24.0, 24.0)
19:46:02 Refusing boundary drag: hit target none does not match Ice's boundary
19:46:02 Keeping items expanded because Ice's boundary could not be verified
```

这证明至少一次真实失败发生在边界对齐阶段，并不是“配置没有保存”。此前只写日志并将状态重置为显示，用户无法知道失败。

修复：仅在边界确实需要移动时，将自有拖动手柄扩大到 24 点，重新读取托管后的坐标；必要时沿用已有的原生溢出展开路径取得端点。命中元素可能是无 identifier 的子元素，因此最多向上核对四层，但必须证明准确的进程、边界 identifier 和几何位置，不能仅凭同进程或保存的位置发送拖动。最终仍要求原生顺序验证。

设置页和右键菜单增加失败提示；布局页说明编辑期间临时展开的行为，并提供“隐藏并关闭设置”。真正完成隐藏仍依赖系统接受宽度变化；本次尚未获得新版实际成功的设备证据。

### 2. Retina 截图在采样时已损失一半线性分辨率

本机只读显示器数据：

| 属性 | 值 |
|---|---:|
| 显示器逻辑宽度 | 1470 点 |
| CGDisplayPixelsWide | 1470 |
| CGDisplayMode.pixelWidth | 2940 像素 |
| NSScreen.backingScaleFactor | 2 |

旧代码用 `CGDisplayPixelsWide / CGDisplayBounds.width`，结果是 1。40 点高的菜单栏因此只截成 40 像素，而正确的 Retina 输入应是 80 像素；后续去背景或禁用插值无法恢复已经损失的细节。

改为使用对应显示器的 backingScaleFactor，后备读取显示模式的 pixelWidth/width；尺寸转换抽出为可测试的 MenuBarCaptureGeometry。仍保留真实截图、像素对齐、前后 AX 位置校验，不替换成应用图标。

依据：[Apple 的 backingScaleFactor 定义](https://developer.apple.com/documentation/appkit/nsscreen/backingscalefactor)、[截图 width 使用像素单位](https://developer.apple.com/documentation/screencapturekit/scscreenshotconfiguration/width)。这解决了已证实的欠采样原因；背景提取算法、跨不同倍率显示器的绘制以及快速切换时的系统渐隐仍需视觉验收。

### 3. 同时发现并处理的相关缺陷

| 问题 | 本次处理 | 验证边界 |
|---|---|---|
| 自有边界的重复 AX presentation 被当成多个项目 | 同坐标去重；冲突坐标拒绝猜测 | 纯逻辑回归通过，设备待验收 |
| 始终隐藏分区未校验边界位置 | 与普通隐藏使用相同对齐流程，目标为普通隐藏区最左项或 FloeBar 按钮 | 设备待验收 |
| 扩大的拖动手柄被缓存刷新误认为已完成隐藏 | 按分区跟踪异步事务；完成前禁止缓存刷新重复改变宽度 | 代码审查、原有拖动生命周期测试；真实竞态待验收 |
| 旧的“隐藏 FloeBar 图标”设置可能移除必要定位锚点 | macOS 27 保留可点击的原生按钮，移除不适用的开关；旧系统偏好不修改 | 构建通过，设备待验收 |
| 英文动态字符串绕过 SwiftUI 本地化 | 连接原生菜单、权限模型、图标选项、错误提示、快捷键辅助功能和空状态 | 编译产物核验通过 |
| 时间文字通过拼接英文 second/seconds 构造 | 改用系统 Duration 本地化格式 | 编译通过 |
| 仅有 lint CI，没有可统一执行的回归入口 | 添加 scripts/test.sh、资源检查脚本及 macOS 回归工作流 | 本机通过，远程 CI 尚未运行 |

## 多语言

`Localizable.xcstrings` 包含 203 个键、九种完整的资源译文。系统菜单栏项目的名称继续由其所属应用提供；不会翻译 bundle ID、持久化 key 或 AX identity。权限用途另有九份 `InfoPlist.strings`。语言跟随 macOS 为应用选择的语言，未添加需要重启状态管理的应用内语言切换器。

范围覆盖常用设置、布局、外观、快捷键、权限、原生右键菜单、更新、移动错误，以及 macOS 14–26 仍可用的旧功能。时长和日期使用系统格式化。测试检查每个键的九语言资源、格式参数以及已编译 app 内的实际 Localizable.strings；版面长度、语感和 VoiceOver 的整条流程仍需人工检查。

## 已完成的验证

- 九组独立 Swift 回归程序：截图尺寸、字形提取、原生边界、拖动可见性、动态身份、布局 owner 生命周期、平均色、覆盖层几何、Space C/Swift ABI。
- 新增 Retina / 1× / 副屏尺寸与非法输入测试，以及边界重复 presentation、不同进程/邻居/缺失 identity/陈旧坐标的拒绝测试。
- `python3 scripts/check-localizations.py --extracted <Objects-normal/arm64> --bundle <FloeBar.app>`：资源键、翻译、占位符和实际打包结果核对。
- Xcode 27 Debug 构建及本地 ad-hoc 签名成功；Universal Release 构建成功，`lipo -archs` 确认为 x86_64、arm64，`codesign --verify --deep --strict` 通过。
- `git diff --check` 通过。SwiftLint 未安装，未宣称 lint 通过。

测试脚本不会操纵真实菜单栏、改变系统权限或移动其他应用的项目。新增 CI 需推送后才会运行，本次没有推送。

## 尚未通过的验收与限制

首轮 UI 验证被锁屏阻断。用户随后授权本机升级，已继续进行实际安装和菜单栏测试。最新设备结果以文末追加记录为准，构建成功不能替代功能验收。

继续验收应覆盖：已有失败布局直接点击隐藏、关闭布局后隐藏、快速连续点击/切换快捷键、普通与始终隐藏互相切换、关闭再打开设置、重启后布局恢复；随后检查时钟/控制中心/第三方菜单的原生点击，以及浅色/深色、缩放、副屏、全屏/Spaces 和九语言截断。

仍存在架构限制：

- 原生溢出由 macOS 27 决定，源代码无法保证每种系统构建/屏幕组合均接受空白边界宽度。当前只验证对齐，不把 NSStatusItem.length 已赋值误称为物理遮蔽已证明。
- 项目历史记录的快速切换渐隐、MenuBarAgent 崩溃尚无本次复现和根治证据。
- 未验证多显示器 AX presentation 冲突的全面支持；当前采取拒绝歧义的策略。
- 原生窗口/Space 路径仍依赖私有系统桥接，不是完全由稳定公开 API 支撑的实现。
- macOS 27 暂不开放独立 Floe Bar、搜索、全局悬停/滚动唤出及自动重隐藏；不应在产品说明中把旧系统的这些能力等同于 macOS 27 已实现。
- 首轮 ad-hoc 包实际启动时遭到 dyld 拒绝，主程序与 Sparkle 的 Team ID 不一致。改用本机既有 Developer ID 同团队签名后正常启动；没有绕过或重置 TCC，没有关闭 hardened runtime。未公证、未发布 GitHub Release。


## 本地交付

- 开发测试包：`build/FloeBar-0.13.0-macos27.2-dev.zip`。
- 解压后的应用：`build/FloeBar.app`。
- 构建及回归日志：`build/verification/`（Git 忽略的本地产物）。
- ZIP SHA-256：`409db3663f7fc94282a4af4055c1c15104e74bda2ce11a7729332e35f66b4609`（最终 Developer ID 包）。
- 源码改动保留在当前工作分支，未提交、推送或发布；用户追加授权后已进行本机安装。

## 本机升级追加记录

- 原 `/Applications/Ice.app`（1329）保存在 `build/backups/Ice-1329.app`，升级前偏好保存在 `build/backups/preferences-before-upgrade.plist`。新版安装在 `/Applications/FloeBar.app`。
- Developer ID 同团队签名解决 Sparkle 启动校验问题；已实际启动，旧辅助功能与截屏权限得到继承。
- 系统音视频指示器位于自有边界和控制按钮之间，导致原始相邻验证误判并反复尝试拖动。排序验证改为比较可隐藏项目和自有控制项，排除不可隐藏的系统指示器。
- 固定近全屏宽边界改为根据刘海屏实际空间计算，增加有限数值和空间不足检查。
- 实测发现 FloeBar 展开状态与系统溢出区状态彼此独立，后续同步依据真实项目的原生命中状态判断，不依赖系统按钮的本地化文案。

### 本机实际验收结果

| 检查 | 结果 |
|---|---|
| 本机签名安装、冷启动与退出后再启动 | 通过；原权限继承，无需重置 TCC |
| FloeBar 点击展开、再次点击隐藏 | 前台应用稳定时通过两轮；原生隐藏项出现在刘海左侧，收起后消失。前台切换场景未完全通过 |
| 收起后 FloeBar 按钮可再次使用 | 通过，按钮保留在右侧原生状态区 |
| 布局页“隐藏并关闭设置” | 通过，关闭后恢复收起 |
| 时钟原生点击 | 通过，打开通知中心 |
| 隐藏项目真实缩略图 | 手动展开系统溢出区后，微信、ChatGPT、Figma、Notion 等真实图像可见；Retina 采样修复已生效 |
| 布局页自动展开系统溢出区 | 未完全通过；设置窗口焦点仍可能使原生溢出区收起，首次缩略图可呈省略号，需要点击系统溢出按钮 |
| 缩略图背景提取 | 输入法、电池等部分图像仍有彩色边角，尚未完成视觉修复 |
| 右键菜单、Wi-Fi 菜单 | 自动化分别受 offscreen/timeout 限制，不记为通过 |
| 九语言 | 203 个键的资源、参数及已编译产物通过；仅简体中文做了当前设备界面检查 |

尚未验收副屏、无刘海屏、长时间运行、快速连续操作与始终隐藏分区。不能据此宣称 macOS 27 全场景兼容。原生按钮 AXPress 返回成功但无实际展开的尝试已撤回，交付保留已验证的原生点击路径。

最终安装后再次冷启动、关闭设置及收起成功，运行日志见 `build/verification/local-install-runtime.log`。前台应用变化时，系统可能自行收起原生溢出区，而 FloeBar 逻辑状态仍为展开；持续状态同步仍为已知缺陷，不能将一次成功开合等同于全部展开场景已修复。

最终安装与交付主程序的 SHA-256 均为 `f455d8746bd1f09b0362b5580e91f96e161ebefe5c52790c2b89c10c76b8b48f`；两者的 `codesign --verify --deep --strict` 在可访问系统信任存储的环境中通过。九组回归及九语言资源检查通过。
