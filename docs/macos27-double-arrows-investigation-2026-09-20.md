# 双箭头与仅显示密码图标：1333 本机深度排查

日期：2026-09-20。只做本机对照、代码审查和主来源核对；本轮未修改应用二进制。

## 结论

两个箭头来自不同控制层：FloeBar 的 `Ice.ControlItem.Visible` 与 MenuBarAgent
的系统溢出按钮。当前实验模式关闭，FloeBar 仍运行占位条方案。该方案改变可用空间，
不等于掌握系统溢出状态。用户描述属于可复现的兼容问题；不是需要重新授权或重装。

## 本机对照

1. 当前高级设置“仅本次运行启用”为 off，版本为 0.13.0-macos27.4-dev。
2. 点击 FloeBar 箭头，方向从右变左，但系统按钮仍名为“显示隐藏菜单栏项目”。
   ChatGPT、微信等在 AX 中仍存在，截图没有在常显区域展示它们。
3. 点击系统双箭头，其名称变成“隐藏菜单栏项目”，截图中 Notion、Figma、微信、
   ChatGPT、WPS 等才展开到左侧。
4. 完全退出 FloeBar，自己的箭头消失，但系统双箭头仍存在。这排除双份 FloeBar
   和私有断言残留为本次双箭头的必要成因。
5. 已重新启动 FloeBar；实验开关仍维持启动默认关闭。

密码图标位于截图中的可见/溢出边缘。占位条伸缩引起排布变化时，它可成为先出现或
先消失的项目。这是位置与空间阈值效应的有力解释，不是代码只选择 Passwords。
本轮没有观察到密码应用窗口被打开；“图标出现”与前次合成点击误开密码是不同问题。

## 可定位的代码问题

- `MacOS27NativeMenuBarHiding.swift:23`：`isConcealing` 仅检查自己记录的 section
  与 spacer.item.isVisible，没有验证任何目标图标是否真正隐藏。
- 同文件 `setHidden` 将自己的 length/isVisible 修改后立即记录 concealedSections。
  Xcode 27 NSStatusItem.h 说明 length 只表示分给接收者的空间；isVisible 即使被
  应用菜单遮挡仍可为 true。因此两者不能作为跨应用隐藏结果的证明。
- `MenuBarManager.swift:219` 后的稳态分支直接将请求状态写入 isConcealingItems，
  不是物理可见性观测结果。
- `MenuBarSection.show/hide` 先修改箭头状态再调用隐藏后端；实验断言 release
  只取消 allowlist 限制，不会展开系统 overflow。两条路径都可能让箭头与实际可见
  图标不一致。
- 布局页仍使用“关闭设置后应用隐藏”“FloeBar 左侧的项目会被隐藏”等无条件文案，
  未区分普通占位模式、私有断言状态与系统溢出。它会强化错误预期。
- 控制器将物理左右位置作为分区来源；系统溢出重排可能改变报告位置。现有私有
  隐藏冻结只能覆盖断言期间，不能代替全局溢出状态识别。此项是进一步验证风险，
  不是本轮已证明的分区数据损坏。

## 其他用户是否受影响

会遇到同类问题，但不能声称每个 macOS 27 用户都出现“只有密码”这一细节。
触发概率与刘海屏可用区域、缩放、图标数量/宽度、当前应用菜单宽度、图标顺序及
系统溢出状态有关。无刘海大屏在足够拥挤时也可能触发。macOS 26 及以前不能直接
套用本轮结论，必须保留旧后端与独立回归。

主来源：
- Hidden Bar v1.11.1 发布说明：macOS 27 采用私有 Apple framework；按应用隐藏；
  App Store 沙盒版本不具备该能力。https://github.com/dwarvesf/hidden/releases
- Thaw 3.0.0-alpha.5 发布说明：原生系统项目缺失/隐藏、同一应用多图标限制。
  https://github.com/thaw-app/Thaw/releases
- 用户实际报告（同 app 图标无法分离等），不是双箭头精确同例：
  https://github.com/thaw-app/Thaw/issues/1125
- Pelmet 的 OverflowChevron.swift 单独管理系统溢出。识别系统本地化语义及
  MenuBarAgent 归属；它仍采用输入合成回退，并未提供官方跨应用隐藏 API。
  https://github.com/fif7y/pelmet/blob/main/Pelmet/App/OverflowChevron.swift
- Pelmet ClockClickRelay.swift 记录断言期间时钟问题，并用全局点击拦截、释放、
  重放、重新激活绕过；不能将其概括为无副作用的兼容实现。
  https://github.com/fif7y/pelmet/blob/main/Pelmet/Events/ClockClickRelay.swift

## 修复方向与验收门槛

1. macOS 27 普通模式不再将 spacer 的可见状态宣称为成功隐藏。普通模式明确交由
   系统溢出控制，FloeBar 使用设置/整理入口或受限状态，避免第二个虚假隐藏开关。
2. 实验模式继续默认关闭。单独管理“请求隐藏”“断言生效”“系统溢出收起/展开”
   “目标实际可见/未知”四种状态；解除断言后不能直接宣称所有项目已展示。
3. 检测溢出必须使用 MenuBarAgent 身份、原生本地化含义和实时状态。不能恢复
   旧的按形状找按钮、用旧坐标点击方案；之前误开密码就是该方案的反例。
4. 若产品要求用户只点一次 FloeBar 就能使用所有隐藏项，需要选择并实现独立的
   展示层（例如适配后的 Floe Bar），或者对系统溢出做严格目标校验的显式联动。
   两者均不是调 spacer 宽度即可完成；且不等于获得移除系统双箭头的官方能力。
   单纯独立面板只解决访问入口，真正隐藏仍需可靠后端。
5. 同时验收系统溢出收起/展开 × 普通/实验模式；逐项核对隐藏对象、允许对象、
   FloeBar 入口、时钟、控制中心、密码点击，以及空间不足、切换前台、冷启动。
   AX 项存在、箭头变化或私有接口回调成功都不能单独判定通过。

本次明确：1333 不能作为“单箭头完整替代系统溢出”的稳定版本。调整权限、重装、
去掉45秒保护或强行默认开启私有模式，都不是此问题的根治办法。
