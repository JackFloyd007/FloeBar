# macOS 27 compatibility and localization

Source: GitHub JackFloyd007/FloeBar main at 787a67f. Workspace was an empty Git repository before importing this baseline. Host: macOS 27.0 (26A428), Xcode 27.0 (27A266a).

## Scope

Investigate hiding that remains ineffective after Settings closes, blurred Layout thumbnails, adjacent compatibility defects; implement English, Simplified/Traditional Chinese, Japanese, Korean, German, French, Spanish and Portuguese localization. Preserve user settings and installed applications. No publishing or release authorized.

## Work

- [x] Fetch source and inspect prior compatibility evidence.
- [x] Reproduce the old installed app boundary failure in logs and confirm the Retina scale mismatch.
- [x] Implement boundary repair, duplicate-presentation rejection, transaction guards and actionable failure UI. New-device behavior remains unverified.
- [x] Add 203 keys in nine locales, including dynamic/AppKit text and permission resources.
- [x] Run nine pure Swift suites, localization source/extraction/bundle validation, Debug and Universal Release builds, signature verification and diff review.
- [x] Record evidence and produce local dev ZIP; see docs/macos27-review-2026-09-20.md.
- [ ] Physical-device acceptance: blocked by locked Mac; user asked to unlock. No new app launch, TCC change or installation performed.

## 本机升级（用户追加授权）

用户已明确要求安装并测试。旧 `/Applications/Ice.app` 已正常退出，移动至 `build/backups/Ice-1329.app`；原偏好导出至 `build/backups/preferences-before-upgrade.plist`。新版安装至 `/Applications/FloeBar.app`。

- 已发现并复现临时签名 Release 的 dyld 库校验失败，正在改用本机既有 Developer ID 签署全部组件，保留 hardened runtime。
- [ ] 启动、权限连续性和中文设置。
- [ ] 隐藏/展开、关闭设置和重启恢复。
- [ ] Retina 缩略图及原生点击。
- [ ] 更新交付包与最终测试证据。

### 2026-09-20 本机升级复测追加发现

- 已保留 `build/backups/Ice-1329.app` 和升级前偏好备份；安装目录改为 `/Applications/FloeBar.app`。
- ad-hoc hardened-runtime 构建实际启动遭到 dyld 拒绝（Sparkle Team ID 不一致）。改用本机既有 Developer ID 同团队签名后正常启动，原权限继承。
- 真实菜单栏测试暴露系统音视频指示器穿插在本应用边界和按钮之间；普通项目排序验证必须忽略不可隐藏的系统指示器，否则会反复尝试无效边界拖动。
- 正在复测按实际刘海屏空间计算的边界宽度；构建成功不能替代运行验收。

### 本机交付状态

- 已安装最终 Developer ID 双架构版本至 `/Applications/FloeBar.app` 并保持运行；本地 ZIP 和安装二进制一致，签名验证通过。
- 冷启动、原权限继承、关闭设置后隐藏、稳定前台下重复开合、按钮保留、时钟点击通过。
- 九组回归和九语言编译资源校验通过，日志保存在 `build/verification/`。
- 已知未通过：前台应用改变后原生溢出区状态持续同步；设置首次打开隐藏缩略图的自动展开；部分缩略图背景边角。右键及 Wi-Fi 自动化受工具限制，未记为通过。
- 因此本机升级已完成，整体 macOS 27 兼容性验收仍未完成；详细结果见 `docs/macos27-review-2026-09-20.md`。

### 用户反馈误触后的修正（1332）

上一轮“核心隐藏通过”判定撤回：系统溢出动作不能被视为 FloeBar 独立隐藏。1332 已安装，移除全部系统溢出合成点击，禁止普通隐藏触发自动拖动修复，新增密码类按钮误分类测试。两次本机点击未打开密码；构建和回归通过。详细规范对标见 `docs/macos27-input-safety-2026-09-20.md`。

仍待决定：是否允许实验性 MenuBarClientCore 私有 assertion（有既有时钟/系统项回归证据）。已经向用户提出架构选择；此前个人规则要求此类取舍交由用户，不把未回复当作同意。当前不启用该机制，独立隐藏目标未完成。


### 1333 默认关闭实验模式（最新）

用户已明确授权继续开发，替代上一节待决定状态。已完成会话内开关、私有运行时桥接、按应用隐藏、跨分区冲突拒绝、系统项保留、3秒激活超时、45秒释放及恢复入口。已构建签名并安装。新增语言条目覆盖九种语言。独立验收和限制见 `docs/experimental-private-hiding.md`；没有把实验结果升级为整体兼容性通过。
