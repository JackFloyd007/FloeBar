# macOS 27 输入误触与开发接口复核

本记录取代上一份报告中“稳定前台下开合通过即可视为隐藏修复”的结论。用户实际复现了箭头误触“密码”，系统双箭头仍在，隐藏仍由系统控制。此前验收不充分。

## 1332 安全修复

- 删除所有自动点击系统溢出按钮的路径，包括箭头开合、设置临时展开、边界校正和拖动后备路径。
- 删除缓存系统按钮坐标后发送普通鼠标 down/up 的实现。此前该坐标在后续异步 AX 扫描期间可能失效。
- 普通隐藏请求不再通过模拟 Command-drag 自动校正边界。只有明确进入布局编辑后的拖动操作可以走原生拖动路径；不可见端点直接报失败。
- 系统溢出按钮的枚举过滤增加所属进程与标题检查；有标题的按钮（例如“密码”）或其他进程托管的同尺寸按钮不再仅凭形状被认作系统溢出控制。这个过滤仅用于枚举，绝不能授权输入。
- 不修改“密码”应用、系统双箭头、TCC 或系统菜单栏偏好。

这些修改消除本应用代点其他状态项的路径，不等于实现跨应用的独立隐藏。

## 开发规范对标

| 项目 | 结论与处理 |
|---|---|
| `NSStatusItem.length` | 公开含义是本状态项所需宽度，不是其他应用的隐藏 API；扩宽空白项只是空间挤压策略 |
| `NSStatusItem.isVisible` | 表示状态项参与显示，空间不足时仍可能为 true；不能作为物理显示/隐藏验收依据 |
| macOS 27 系统双箭头 | 属于系统溢出管理；现有 SDK 没有允许第三方移除或接管它的公开接口。不能把它的动作归功于 FloeBar |
| `expandedInterfaceDelegate`（27 新增） | 管理本状态项自己的展开窗口生命周期，不管理其他应用图标；本项目当前关闭 27 独立 Floe Bar，不能借此获得跨应用隐藏能力 |
| 普通箭头操作 | 1332 禁止其发出合成鼠标点击及自动修复拖动 |
| 明确的布局拖动 | 保留 AX 端点验证；不可见、错进程或不明确端点拒绝，不自动点击系统按钮 |
| 14–26 分支 | 保留原有分区长度、独立 Floe Bar、搜索及悬停逻辑；27 专用变更有 availability 边界 |
| 最低版本与架构 | 部署目标 14.0；构建 arm64/x86_64 不等于已在每个旧系统完成运行验收 |
| 截图 | 27 路径使用 ScreenCaptureKit、对应显示器 backing scale；14–26 旧 CGWindow 截图路径仍有废弃 API 警告，尚非全面现代化 |
| 状态与设置 | 27 的 hover/search/单独面板等不可用项已有隐藏，但“始终隐藏”仍暴露；真正独立隐藏确定前不能承诺这些分区语义 |
| 私有接口 | 原项目 Spaces/WindowServer 桥接已有 CGS/SLS 私有符号；不能宣称整个项目只用公开 API 或符合 App Store 全部规则 |
| 签名 | Developer ID + hardened runtime，主程序和 Sparkle 同团队；不以放宽库验证修复启动 |
| 异步错误 | Xcode 27 发现旧悬停、旧 Floe Bar、搜索等未消费 throwing Task 警告，需后续旧系统运行回归后修整，不能记为无警告 |

## 独立隐藏的架构选择（待用户决定）

A. 不新增私有隐藏机制：交付误触修复并明确菜单栏空间由系统管理，不能承诺移除系统双箭头。当前独立隐藏需求仍未满足。

B. 实验性私有隐藏机制：运行时解析 `MenuBarClientCore` 的菜单栏配置 assertion，并明确提供开关和 API 缺失时恢复显示。按应用 bundle 分组，不假装支持同应用多个状态项任意独立隐藏。仓库既有隔离实验发生时钟点击失效和被允许项目消失，不能直接启用。参考项目目前用全局点击拦截、释放 assertion、重放时钟点击补偿，仍不是原生点击保持不变。需单独决定是否接受该取舍，再做可回退实验及原生时钟、控制中心、密码、输入法等验收。

未集成或激活私有 assertion，也未增加全局时钟点击代理。用户的个人规则要求架构取舍交由用户决定，已提出选择；等待答复期间完成安全修复与构建。

## 证据

- 本机 Xcode 27 SDK `AppKit.framework/Headers/NSStatusItem.h`、`NSStatusBar.h`。
- [Apple NSStatusItem](https://developer.apple.com/documentation/appkit/nsstatusitem)
- [Apple isVisible](https://developer.apple.com/documentation/appkit/nsstatusitem/isvisible)
- [Apple expandedInterfaceDelegate](https://developer.apple.com/documentation/appkit/nsstatusitem/expandedinterfacedelegate)
- [App Review Guidelines 2.5.1](https://developer.apple.com/app-store/review/guidelines/#software-requirements)：App Store 公共 API 要求不能与 Developer ID 公证混为一谈。
- 仓库历史：`docs/assessment-isolation-2026-09-05.md`（原生时钟点击失败的隔离实验）。
- [参考项目私有隐藏入口](https://github.com/fif7y/pelmet/blob/main/Packages/PelmetEngine/Sources/PelmetEngine/AssessmentMode.swift)
- [参考项目时钟代理及其已知代价](https://github.com/fif7y/pelmet/blob/main/Pelmet/Events/ClockClickRelay.swift)

## 本轮交付与验证

- 已安装 `/Applications/FloeBar.app`，版本 `0.13.0-macos27.3-dev (1332)`，Developer ID 同团队签名、hardened runtime、arm64/x86_64；签名验证通过。
- 九组回归程序通过，新增两个同尺寸按钮误识别回归；九语言 203 个键及打包资源检查通过。最低部署目标 14.0 的双架构构建成功，不能替代旧系统实机验收。
- 本机两次箭头点击后，未出现密码界面，系统溢出按钮保持其原有状态。确认的是“不再合成代点”，不是独立隐藏成功。
- 1331 已从本地默认交付位置撤回并保存在 `build/backups/`。新包为 `build/FloeBar-0.13.0-macos27.3-dev.zip`，SHA-256 `55f3601bbe88b532066b55c49bede13ad239658aaf365cab35a4e5846fb027be`。
- 独立隐藏、移除/取代系统双箭头、全部旧系统实机验收尚未完成。私有机制待用户架构选择，未擅自启用。
