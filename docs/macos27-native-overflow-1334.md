# macOS 27 双箭头修复：1334

版本：0.13.0-macos27.5-dev（1334），2026-09-20。本机 macOS 27.0（26A428）。

## 根因与方案选择

旧普通模式通过加宽占位项把其他图标推离可见区；macOS 27 已有自己的溢出区。
改变 FloeBar 分区状态只改变占位和边缘项目（本机表现为密码），不会同步系统
溢出区。两个入口实际控制两层状态，自己的占位不可见也不能证明其他应用已隐藏。
这是结构性兼容问题；具有相似菜单栏拥挤程度的其他用户也可能遇到，具体边缘图标
取决于布局，并非只影响“密码”应用。

实施前比较的 GitHub 案例：

- [Hidden Bar 发布记录](https://github.com/dwarvesf/hidden/releases)：1.11.1 引入私有接口；沙盒限制也说明这种能力不是通用公开接口。
- [ice-2 变更记录](https://github.com/teddychan/ice-2/blob/main/CHANGELOG.md)：27 使用私有 assertion，保留系统行为副作用与功能限制。
- [Pelmet 原生溢出控制](https://github.com/fif7y/pelmet/blob/main/Pelmet/App/OverflowChevron.swift)：按系统本地化语义寻找原生按钮，AXPress 不支持时采用输入回退。
- [Glace](https://github.com/scorpion7slayer/Glace/blob/main/README.md) 在27采用系统溢出；[menubar-hide](https://github.com/junior-rj/menubar-hide) 在27禁用独立面板。
- [OverflowBar](https://github.com/EvanProgramming/OverflowBar) 的15/26验证不能当作27已验证证据。

因此默认选系统原生溢出协作，私有隐藏保留默认关闭并单独验收。这是针对当前系统
和稳定性要求的取舍，不代表公开 API 已允许任意逐图标隐藏。

## 实现

- 普通模式移除宽占位隐藏；临时窄句柄仅用于布局拖动。
- FloeBar 使用固定菜单栏图标。每次点击读取系统当前状态再切换，不依赖自己的旧箭头状态。
- 系统双箭头保留；两个入口操作同一个系统溢出区。系统决定哪些项目溢出，普通模式不承诺按分区精确隐藏。
- 目标同时验证 MenuBarAgent PID、AXButton、系统 loctable 精确文本、当前显示器菜单栏坐标范围。
- 本机 AXPress 返回 -25206。仅对不支持操作的返回值启用回退；重新解析目标，并要求当前位置实时命中同一 AX 元素后才发送一次成对点击。用户按住鼠标或修饰键时拒绝；没有全局点击拦截和重复点击重试。
- 操作后重新读取系统展开状态；未确认时显示失败提示，不标记为成功。没有目标、歧义目标、密码图标等均不能通过语义校验。
- 14–26 保留原后端。实验模式仍只在本次运行启用，每次测试45秒恢复；释放私有隐藏与展开原生溢出被视为不同操作。
- 设置明确区分系统溢出与实验分区；九语言资源保留。

## 验证与边界

- 11组纯逻辑回归通过，包括精确标签/语言表、错误owner/role、密码目标和歧义拒绝；216条字符串的九语言、占位符与权限资源检查通过。
- Release arm64/x86_64 构建、Developer ID 签名及严格校验通过。本地安装到 `/Applications/FloeBar.app`。
- 本机设置关闭时：FloeBar 点击展开真实溢出项目，再点收起，通过；直接点系统双箭头后再点 FloeBar，按系统最新状态收起，通过。测试未误开密码。
- 冷启动实验开关关闭，布局页说明与普通模式行为一致。
- 这不是完整兼容认证：旧系统实机、多显示器、自动隐藏菜单栏、极端快速连续点击未完成本次验收。UI移动和系统后续更新仍可能导致请求拒绝，不能保证输入竞态绝对不存在。
- 私有模式的时钟兼容问题仍未解决，不纳入本次普通模式验收；参考 [独立实验记录](experimental-private-hiding.md)。没有公证、推送或公开发布。

验证日志：`build/verification/tests-1334.log`、`developer-id-build-1334.log`、
`native-overflow-runtime-1334.log`。交付包：`build/FloeBar-0.13.0-macos27.5-dev.zip`。
