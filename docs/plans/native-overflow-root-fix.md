# macOS 27 双箭头根因修复执行计划

2026-09-20，用户授权先核对 GitHub 案例、判断方案后实施。

## 取舍依据

- Hidden Bar v1.11.1、ice-2 2.16.0 使用私有 assertion 真正隐藏应用；系统控件副作用、
  按应用粒度限制仍存在。不能把它无条件升级为默认后端。
- Pelmet OverflowChevron.swift 证实 native overflow 是独立控制层。其 AXPress 优先、
  HID 回退方法可参考，但本实现加强即时同一 AX 元素命中校验，禁止模糊形状识别。
- OverflowBar README 只声称核心路径在15/26有效；menubar-hide 在27禁用面板，
  Glace 在27采用系统原生溢出流程。旧第二栏不能简单开启当作已验证的27解决方案。

参考链接：
https://github.com/dwarvesf/hidden/releases
https://github.com/teddychan/ice-2/blob/main/CHANGELOG.md
https://github.com/fif7y/pelmet/blob/main/Pelmet/App/OverflowChevron.swift
https://github.com/EvanProgramming/OverflowBar
https://github.com/junior-rj/menubar-hide
https://github.com/scorpion7slayer/Glace/blob/main/README.md

## 选定实现

默认：系统原生溢出后端。删除普通模式的宽 spacer 隐藏和假成功状态，固定 FloeBar
入口，点击按系统实时状态切换展开/收起。保留系统的双箭头，不宣称能移除系统控件。
系统决定溢出成员，普通模式不宣称按 FloeBar 分区精确隐藏；按应用隐藏仅属于明确
开启的实验模式。旧系统保留原后端。

识别必须同时满足：运行中的 MenuBarAgent PID、AXButton、系统 loctable 的精确
本地化含义、指定显示器菜单栏内的实时框。操作前重取对象、框与状态；HID回退要求
全局实时命中同一 AX 对象、无用户鼠标按下/修饰键，动作后复查系统状态。
本机原型 AXPress 返回 -25206（actionUnsupported），因此需要上述受控回退。
不自动扩展权限，不拦截全局点击，不改系统布局数据库，不以隐藏失败重试合成点击。

## 验收

- 回归：中文/英语/系统语言表、密码样式目标拒绝、错误owner/role/歧义拒绝。
- 正常前台、设置关闭时，单击 FloeBar 真正展开图标；再点收起。
- 直接点系统双箭头后再点 FloeBar，不能使用旧的本地逻辑状态。
- 不再改变自己的占位宽度；不误开密码；旧系统路径保留。
- 失败清楚提示，不报告“已隐藏”，界面删除不适用的精确分区承诺。
- 私有模式仍默认关闭、单独验收；一键恢复需处理 native overflow 的独立状态。

## 完成记录

已实施并安装 1334（0.13.0-macos27.5-dev）。最终包在设置关闭后通过 FloeBar
展开、收起，以及系统双箭头先展开再由 FloeBar 收起的交叉验收。11组纯回归、
216条九语言资源检查、双架构 Release 构建与签名校验通过。
布局文案也已完成最终本机核对；正常模式不再承诺按实验分区精确隐藏。
详细结果及未验收范围见 `docs/macos27-native-overflow-1334.md`。
私有模式仍未完成时钟兼容验收，保持默认关闭；本次没有推送或发布。

## 2026-10-31 审查后修复（同一计划续接）

用户授权按架构审查优先级修复，保留原生界面及现有未提交工作。基线保存于
`build/fix-20261031/before.tar.gz`；只由主代理写代码，独立代理只读复核。

- [x] 严格验证拖动 AX 身份、实际输入空闲与最终端点；消除位置导致的身份交换。
- [x] 移除间距调整的强退行为，处理拒绝退出、超时和跳过项目。
- [x] 修复 SwiftLint 构建门禁并完成完整构建。
- [x] 修复权限后补授权、快捷键录制、主题覆盖层和搜索窗口生命周期。
- [x] 隔离当前显示器快照与布局事务，保护重复系统项目。
- [x] 增加受影响的回归/集成检查，复核本轮差异，记录实测和未覆盖范围。

验收：错误/过期/跨屏端点不能发起输入；不会强退其他应用；现有回归与新增行为
检查通过；完整构建通过；实际界面或设备检查不足时明确保留限制。不开启私有实验、
不安装发布、不改授权设置。

完成：18 组回归、220 条九语言资源、SwiftLint 0.65.1 严格检查、arm64 Debug 干净重建及最终复核构建均通过。最终构建 0 error / 7 compiler warning；当前原生权限窗口已启动检查并正常退出，真实拖动/多屏等验收限制记录于审查报告的修复结果。
从修复前快照到本记录的墙钟时间约 28.9 分钟（含编译、工具等待和复核）；模型/返工记录见原审查报告，token/成本 unknown。

## 2026-10-31 运行反馈与默认后端研究（续接）

用户要求继续清理编译告警，并修复实际隐藏和排序无效；明确接受研究稳定默认隐藏后端及扩大架构改动。复用两个已有 Sol/high 定向审查代理，额外一个 Astra/high 做跨层后端研究；root 唯一写入。修复前基线：`build/followup-20261031/before.tar.gz`。

- [x] 修复原七条增量编译告警，完整构建由 13 条降为 1 条；旧离屏截图弃用告警因兼容性暂留。
- [x] 普通模式排序直接使用真实端点，移除无关分隔符前置和最终验证依赖；根据实机再修正历史 Visible 分区也可能位于 FloeBar 左侧的情况。
- [x] 接通实验模式编辑句柄及原生关窗后的已验证隐藏意图，补无 lease 恢复与空目标回归；真实私有隐藏仍未验收。
- [x] 根据一手实现与当前 SDK 完成稳定默认隐藏研究；用户确认保留原生系统行为，暂不默认启用私有后端。
- [x] 产出 1336 本地开发签名包，核对运行进程和代码哈希；20 组回归、受影响补测、严格 lint、干净构建、真实拖放及重启保持验证完成。

验收不能以纯测试代替真实排序或隐藏；API active 不等于真实已隐藏。保留原生界面、已有未提交工作和系统权限边界，不通过跳过身份验证、假成功状态、未经确认的系统项替代来取得表面成功。

用户在包生成后明确授权辅助功能及录屏，且亲自完成系统身份验证。unsigned 构建的 linker-only 签名不能形成有效应用身份；仅对本地测试包补 Apple Development 签名，保留 hardened runtime 和嵌套 entitlements，未修改项目发行设置或发布。重新建立本项目 TCC 记录后两项授权通过；系统要求录屏重启，已照做。

最终实机：无障碍向右排序、鼠标向左拖放均出现真实端点移动与 committed 日志；进程重启后顺序保持，随后恢复 Figma/WorkBuddy 原顺序。原生拖动存在有界重试，最后一次恢复约 9 秒后收敛，不能称为所有操作首试即时成功。普通模式拖到 Hidden 弹出明确不支持提示，未错误保存或隐藏。没有启用实验 assertion 或替代系统图标。

最终构建：`build/followup-20261031/VerifiedReorderBuild.xcresult`；结果 0 error / 1 deprecated warning。本地包 `build/FloeBar-1336.app`，版本 0.13.0-macos27.7-dev。详细证据、保留限制与模型执行记录续写于原架构审查报告，不另建计划。

## 2026-10-31 单次拖放稳定性（续接）

目标：一次用户拖放对应一次有效原生手势，在真实菜单栏收敛，不依赖重复发送整次拖动。保留原生界面、所有未提交改动、输入身份/同屏/空闲门禁及私有隐藏默认关闭。基线 `build/drag-stability-20261031/before.tar.gz`（273 文件）；复用两个只读代理分析投递与采样，root 唯一写入。

- [x] 通过事件投递及真实 AX 位置诊断区分未移动与误验证。
- [x] 修复单次原生手势，覆盖释放、取消和用户输入冲突边界。
- [x] 运行受影响测试、严格 lint、重建并用明确版本实测多个来回拖放及重启保持；恢复测试顺序。


完成：1337（0.13.0-macos27.8-dev）保持原生界面与私有隐藏默认关闭；持续轨迹、一次释放、两次真实位置验证及无完整手势重放已实现。连续编辑按依赖排序，22 组回归证据、1546 个合并排列、严格 lint、最终干净构建与真实左右/跨项/连续/重启验证通过。最终干净构建 0 error / 1 既有截图 API 弃用警告，最终包单次往返见 `runtime-clean-final.log`。用户确认实测期间曾同时使用鼠标，相关前置取消作为保护行为保留；所有测试图标恢复原顺序。报告与证据继续复用原文件和 build/drag-stability-20261031/。


## 2026-10-31 当前前三项修复（1338，续接）

目标：修复输入法身份迁移覆盖、普通模式隐藏界面误导及排序失败静默。保留原生
AppKit/SwiftUI、历史实验分区、输入保护和单手势不重放；私有隐藏默认关闭。
代码由本轮 GPT-6.1 Sol/high 代理唯一写入，root/native_review 只读复核；Terra 独占实机。
基线 `build/top3-fixes-20261031/before.tar.gz` 保存 277 个原文件及逐文件 SHA256。

- [x] 输入法仅迁移唯一当前项目的唯一已知旧标签；Item-N 独立保留，多项或未知标签不猜。
- [x] 普通模式显示一条从左到右的真实排序行，合并历史三分区；历史归属只读保留，普通拖放与 AX 动作不提供隐藏分配。
- [x] 排序底层保留输入中止、切屏、端点与验证原因；本代次实际回读发布后才显示终态。读回失败明确未确认，新编辑屏蔽过期结果，不保留自动重试手势。
- [x] 22 组回归、最终受影响补测、严格 lint、234 条九语言源/提取/编译资源及唯一 clean build 通过；1338 同身份本地开发签名通过。
- [x] Terra 验证 1338 单行历史项目、真实左右移动、输入取消反馈及重启保持；发现反馈行推动图标区域，最小修复后以新唯一 1339 完成位置稳定、排序/安全中止及恢复终验。

候选：`build/FloeBar-1338.app`，0.13.0-macos27.9-dev (1338)。代码 dylib SHA256
`24cf64839be38eef590f6e1bd31f157033d4be4e9ac6e7d89e765ac9dba202a0`。
证据、包身份与仅本轮补丁保存在 `build/top3-fixes-20261031/`。未提交、推送、发布、
安装到 /Applications、改变 TCC 或开启私有 assertion。实机结果待 Terra 回传后续写，
上述纯测试不代替实机通过声明。


最终交付改为 **1339（0.13.0-macos27.10-dev）**：反馈放至图标区域下方，
IceForm 顶端对齐保持图标位置。独立 `FinalUICleanBuild.xcresult` 仍为 0 error / 1 既有
截图弃用警告，严格 lint、资源及同身份 deep/strict 签名通过。最终运行 PID35728；
idle/成功/输入中断三状态图标中心均约 y234，真实排序及安全输入中止通过，新操作
成功并恢复 WorkBuddy/Figma/ChatGPT 原序。证据 `runtime-1339-pid35728.log`。
包 `build/FloeBar-1339.app`，dylib SHA256
`317f5d2d968bdabb1eb05fa8b01d2543574009febdcc6084c0c197c9d7d455f1`。
1338 历史包/日志和1339最终包分别保留，不混合哈希；1339未另做重启，复用1338
不受影响的重启证据。进行中瞬态、系统overflow实际展开、真实多屏/旧系统/私有隐藏
和多canonical输入法不在新增实机通过范围。完整执行记录续写于原架构报告。


终验补充：1339 输入中断那次为 observed=false / interrupted=true，清理已发送但
该次 release receipt 未确认；只确认明确中止、无重放及新操作恢复正常。277 个基线
文件均保留，旧220翻译条目与其他44个资源文件未变，本轮14文件清单及相对dirty
基线的补丁见 `preservation.json` / `repair-only.diff`。未新增源码或重复状态文档。


## 2026-10-31 拖入隐藏区域后失败/溢出的反馈与后续排期（续接）

用户要求优先处理“把隐藏图标拖到隐藏的图标栏时失败然后溢出”，并将此前未完成
事项加入同一排期。仍以本聊天、Sol唯一代码写入者 + Terra独占实机、root/native_review
只读复核推进。新dirty基线 `build/overflow-drop-20261031/before.tar.gz` 保存277个文件；
不覆盖1339或旧包、历史证据。以下按依赖分批，不凭空指定日期，不同时扩大所有P2。

| 批次 / 优先级 | 范围与依赖 | 可观察验收条件 |
|---|---|---|
| 本轮 B0 / P1 | 先确认复现窗口与进程版本、拖放来源/目标（设置行、系统菜单栏/overflow或实验分区），再最小修复。独立核对同bundle旧新版并存，不能把旧版行为或上轮代理输入中断当成本次用户失败。 | 单一已核对版本和代码哈希，能将用户动作与本PID日志对应；隐蔽/过期端点不注入，失败原因/后续操作明确。若确需展开，只用当前系统语义和精确命中，不自动重放整手势。普通模式不承诺逐项隐藏。 |
| 本轮 B0 条件分支 / P1 | 若确认旧版三分区窗口或并存进程造成操作混淆，再处理启动冲突。方案先核实，不未经说明退出别的版本。 | 原生界面展示版本/路径/PID，用户可选当前版或已运行版；仅正常退出并等确认，拒绝/超时保持门禁，禁止forceTerminate、静默改全局设置或修改TCC。 |
| 下一批 B1 / P2 | 已验证的B0安全修复交付后，处理扫描取消和主线程预算；先测单次/整轮AX读取与取消延迟，再决定执行器边界。另收敛身份持久化限制。真实collapsed恢复仅在系统提供入口时条件性验收，不阻塞B1。 | 取消/旧generation不发布结果，有有界整体读取预算与可复核耗时；保持AX串行安全。缺稳定identifier的会话token不虚称跨重启持久化，稳定标识/运行代次/显示器presentation不互相覆盖。 |
| 下一批 B2 / P2 | B0交付后处理间距操作部分成功与CI完整构建。间距依赖已有正常退出和逐项跳过保护；CI可独立推进，不与输入事务重构混改。 | 显示每项成功/跳过/失败，已应用与未应用状态可区分，保留明确重试，拒绝退出不强退。CI覆盖完整app/XPC、project文件和共享代码变更，固定lint版本、纯回归和完整build，不以纯测试代替可编译。 |
| 验收批 B3 | 从B0起逐项累积实机矩阵；使用当前候选唯一哈希，受影响项目优先，环境不具备则保留未测。为B1/B2和技术债提供兼容证据。 | 区分普通overflow展开/收起、隐藏端点恢复、拖放/AX、输入中止、多canonical、重启、单/多屏、全屏/自动隐藏、浅深色/缩放/中文长文与VoiceOver；旧14–26和实验私有assertion单独验收，不拿模拟或API active冒充真实成功。 |
| 技术债 B4 | 截图兼容迁移依赖B3离屏/overflow/动态项证据；架构拆分依赖B0/B1的稳定契约和回归，不先大重写。 | 新截图路径覆盖现有离屏用途才移除旧API；否则保留明确兼容回退及弃用债务。逐步分离capability/discovery/visibility/reorder与反馈契约，现有输入、身份、lease和发布边界不变。 |

本轮初始证据：Terra读到1339 PID35728为中文普通单行且私有off；另有旧AppTranslocation
1330 PID97461，英文布局确有Visible10 / Hidden7 / AlwaysHidden0并承诺拖入隐藏。
当前用户操作哪个窗口尚未确认，最近日志未出现可归属的新失败，不能据此宣称根因已定。
静态审查另发现收起后保留的tile仍可能允许发起排序、而底层exact-hit才拒绝；这属于
需随B0复现核对的交互边界，不能通过降低identity门禁取得假成功。


### B0 实施候选 1340（待 Terra 实机）

- [x] 新版本启动前冲突门禁：同步preflight在App.init返回前完成，AppState为lazy且
  delegate授权生命周期在runloop重入时不迁移/不setup；Settings场景仅在通过后构造。
  原生界面显示版本/路径，仅用户选择此版本才正常请求旧版退出并按uptime有界等待；
  拒绝/超时结束本次。可靠launchDate按时间/PID仲裁较晚启动者，缺日期时要求人工
  先关闭另一版，不以缺元数据宣称已证明启动顺序。
- [x] 两处resolved/刷新后ordinal快路径都验证双方真实命中；过期或不可见端点拒绝，
  即使保存顺序已相邻也不能报告已完成。
- [x] endpoint失败的原生内联按钮固定展开系统overflow，保留Layout编辑；恢复与
  native drag共用输入锁，锁后重验代次/无新intent/同屏/模式/编辑上下文，释放后才
  扫描。展开后不重放旧排序，用户重新拖动；关闭/重开通过独立token隔离旧回调。
- [x] 23组纯回归、受影响恢复补测、严格lint、247条九语言源/提取/编译资源和
  arm64完整clean build通过；0error/1既有截图弃用警告，同身份deep/strict签名通过。
- [x] Terra在最终1341验证受控版本冲突两选择分支及一般左右排序/恢复。
- [ ] 条件性验收：系统实际提供overflow入口时，再验证collapsed端点拒绝、显式展开/再次新拖放；不以一般排序代替，不阻塞B1。

候选 `build/FloeBar-1340.app`，0.13.0-macos27.11-dev (1340)，dylib SHA256
`acc25c9de854704004f3d1d21c9dcec23ca88578430368f6246f38b891b34f91`。
此启动门禁只能约束含新逻辑的版本启动；旧1330日后再次启动不受其约束，运行期间
检测旧包后来启动并暂停操作/提示切换列入B1加固，不宣称实现绝对单实例。
新症状原始操作窗口尚未得到用户确认；本次修复是已证实的边界，非无证据断言原始
投诉必由1339或旧版造成。证据继续保存在 `build/overflow-drop-20261031/`。


1340 当前状态：**构建签名完成，实机待手动解锁**。Terra已核对候选哈希，但机器随后
处于锁定状态，CUA自动解锁失败，尚未启动1340。旧1330已正常退出，最后核对运行的
仍是1339；本轮未以1339结果替代1340实机。用户原操作区域仍待确认。解锁后继续同一
聊天派Terra做受控启动冲突与collapsed overflow/显式恢复终验，B0实机复选框保持未完成。


### B0 1340 启动实机回归与 1341 修正（续接，待终验）

解锁后Terra尝试启动1340，进程PID44366存在，但两次AX读取超时、看不到可用选择框。
只读sample确认主线程为FloeBarApp.init → ApplicationLaunchGate.mayStart:76 →
NSAlert.runModal，说明把原生modal置于SwiftUI App.init会阻塞启动可达性；纯policy测试
未覆盖这一真实UI生命周期，不能用其通过代替实机。1340未完成授权/setup。

修正以新唯一 **1341（0.13.0-macos27.12-dev）** 交付：App.init不再modal；AppDelegate
在didFinish回调返回后的MainQueue才呈现门禁，AppState为published optional，nil期间
Settings/Permissions只构造空工作内容，不构造业务View、环境对象或扫描task；用户
授权且旧实例退出后才构造state，完成同步迁移后发布。既有IceWindow空shell的创建/
立即隐藏行为保留，没有触及业务对象。门禁政策、正常退出及排序/恢复逻辑不变。

1341受影响启动回归、strict lint、247条九语言资源、独立clean build和同身份deep/strict
签名通过；clean build仍0error/1既有截图告警。dylib SHA256
`326110a83ae06cd94f71f523b53787911a553ed591f1a02928ece1085a589038`，包
`build/FloeBar-1341.app`。Terra继续做真实dialog和overflow恢复终验，本节不先勾通过。

1340包、hash、sample与前后源码快照均保留。诊断清理只针对已再次核对路径和sample
启动时间的未初始化PID44366：普通NSRunningApplication.terminate返回true并成功退出；
未发送SIGTERM或更强信号，不触碰1339/第三方应用。证据`cleanup-1340.log`。


### B0 最新验收状态：1341 启动/一般排序通过，collapsed 恢复仍待验

最终包为 `build/FloeBar-1341.app`，PID46785继续运行，哈希见package-1341.json。
Terra验证“使用运行中版本”后仅1339，“使用此版本”后旧版正常退出、仅1341；
普通模式单行、私有隐藏off、辅助功能已授权。右拖和落在明确左侧间隙的回拖均真实
提交generation4/5并恢复原序。原1339在本次受控基线前曾已不在，原因未确认；Terra
通过CUA重新启动1339 PID46645用于门禁验收，不将其先前退出归因于本次产品逻辑。

本轮工具只取得应用窗口裁切，未识别到可验证的菜单栏双箭头/隐藏目标；Finder调用
耗时202秒仍只得到普通窗口，未构造实际collapsed endpoint，显式展开按钮无实机
覆盖。此202秒是工具调用，不能直接当成FloeBar扫描性能数据。早先落目标中心的
左拖没有生成请求，不算原生拖动失败或成功。原始用户surface仍未确认。
真实collapsed链路保留为自然具备入口时的条件性验收，不要求用户寻找不存在按钮或
改变权限，不阻塞B1–B4按前述依赖推进。原用户surface如后续明确，仍在同一聊天核对，
不将其尚未明确归因为本轮已复现。


### 用户确认无双箭头：1342 最小反馈修正（待普通烟测）

用户已明确当前屏幕**没有系统双箭头**，不能再要求其寻找不存在入口或把缺少
collapsed endpoint测试条件说成权限未开启。1341普通单行、私有off，旧1330已退出；
原拖放surface仍未明确，真实“隐藏端点→展开恢复”继续保留为自然具备条件时的验收。

源码确认：NativeOverflowController找不到可安全识别target时，在AXPress/HID发送前
返回nil，不点空气、不换系统项；上层当前只知道不可用或未确认，无法断言是哪一种。
1342仅把失败说明改成“当前系统溢出入口不可用，或尚未确认展开。可刷新列表后调整
菜单栏中实际显示的项目。”失败态按钮复用原refreshID列表刷新，不再重复展开或要求
手动找箭头。首次endpointUnavailable保留一次明确展开尝试，供其他具备入口的环境使用。

刷新仅在本代次失败态且无新desired时允许，递增恢复token并清反馈；不重放排序，
不直接改历史分区，旧回调不能覆盖刷新或新arranging。NativeOverflowController/API、
扫描架构、私有默认值和启动门禁不变，没有测试专用入口或快捷键变更。

1342（0.13.0-macos27.13-dev）候选 `build/FloeBar-1342.app`；dylib SHA256
`50eab078b3e41151733ab67b5e3fe325ca1cffb76a7ca6ab951d1c9d1a1a8f2b`。受影响回归、
严格lint、249条九语言提取/编译资源、独立clean build及同身份deep/strict签名通过，
仍0error/1既有截图弃用告警。复用未变的23组和1341两启动分支证据；Terra本轮只
做最终切换/普通布局排序烟测，不宣称新失败分支或collapsed恢复已实机触发。


### B0 最终交付：1342；条件性验收不阻塞 B1

Terra通过原生“使用此版本”正常切换到1342，最终唯一PID58889。普通模式单行、
私有off、辅助功能授权保持；Figma真实右拖和明确左侧间隙回拖均began/released
observed=true/committed，generation2/3，原序恢复，1342继续运行。证据
`runtime-1342-pid58889.log`对应`package-1342.json`最终哈希。

用户no-arrow是已确认现场条件，当前无需解锁、寻找按钮或再开权限。入口不存在/
展开未确认时的保守说明与只读刷新已在本轮实现并由源码/模型回归验证；新失败态
未真实触发，不标UI分支通过。真实collapsed→expand恢复仅在系统实际提供入口时
再验，不作为B1扫描预算/身份持久化等下一批的无限前置。原用户surface仍未明确，
保留“未唯一复现/归因”边界。已通过的普通布局/排序、输入保护及门禁证据继续复用。


## B1a · 扫描取消与整体 AX 预算（1345，限定验收完成）

- [x] 枚举保持main串行小批读取，统一取消/deadline；完整性贯通缓存、排序、图片与
  absence，未完成结果不发布/不退休/不确认。关闭重开请求由fresh Task承接。
- [x] 生产解析、假时钟/慢读/heartbeat/排队取消/required-owner/首屏换屏/重开回归通过；
  24组完整测试、受影响AXFrame主备几何补测、strict lint、构建与同身份签名通过。
- [x] 最终1345 PID92663布局/图像/切页、真实往返gen2/3及恢复通过；短自然观察36个
  枚举context全complete、0incomplete。实际取消14.378875ms复用1343同路径，1345未再触发。

最终包`build/FloeBar-1345.app`（0.13.0-macos27.16-dev），dylib
`b42850c8435c43eb06f1697e722271557606a1021262949d250f080050fbbd9a`。
预算cache/capture3s、targeted1.5s，单读请求上限40ms；OS超时非硬实时，当前不可中断
读返回后才可拒绝结果。1345枚举total min/median/max28.73/65.03/1059.57ms，最长main
枚举read34.33ms；不代表全App或existing nativeHit/own-control探针上界。

保留边界：1343曾持续incomplete，1345修复明确AXFrame源码兼容差异，但未唯一证明
其解释所有现场变化；WPS/Focus17/18项不同不作因果保证。旧系统/多屏/自然慢服务
矩阵及B1b身份持久化/运行中旧包监控未展开，B2–B4继续原排期。基线280文件全保留，
45资源文件全字节未改；证据、patch与receipt在`build/scan-budget-20261031/`。


## 核心能力修复 · 原生箭头与系统按应用隐藏（进行中）

用户已授权先修自身原生展开/折叠箭头，再验证系统每应用“允许在菜单栏显示”路线；
普通模式应用列表采用bundle图标与名称，后续移除截图/录屏依赖，保留旧/实验路径。
禁止使用PRK闭源组件、开启现有私有assertion或改TCC。新基线283文件与旧产物均保留于
`build/app-hiding-20261031/`。

- 1346访问阶段：固定矩形改左右chevron及fallback，追加自身真实AX frame/hit诊断；
  通用设置提供限定`group.com.apple.controlcenter.plist`的原生单文件picker，读取schema
  与Figma/FloeBar目标记录，不写系统值。访问确认不等于隐藏实现完成。
- 授权后首验：只对明确第三方Figma，journal先耐久、精确entry写后状态+真实AX/菜单栏
  消失恢复验证；自身/Apple/未知拒绝、同app联动。正常退出及异常重启仅恢复自身改过
  且无外部冲突记录，失败保留journal，不整域回灌、不假承诺所有用户意图可辨。
- 本轮验收继续至真正按app隐藏/原位展开及恢复实证；1346不是终点。其他B1b/B2–B4仍
  按原依赖，不扩scanner或PRK逆向。


### 本轮最小验证完成 · 1352（仅单 Figma）

- [x] 自身原生chevron真实可见，真实控件`Ice.ControlItem.Visible`可收起/展开所选
  Figma，保持原生菜单栏位置；新单目标入口采用bundle图标/名称，无截图/录屏依赖。
- [x] 用户明确批准后仅一次MenuBarAgent1059→33936重建，此后CF系统路线真实生效；
  未再重启服务、未重启cfprefsd，产品无自动重启功能、实验私有隐藏保持off。
- [x] 1352 PID57315：Hide真实消失→CUA原生箭头restore真实重现且UI已核实→再Hide→
  正常Cmd-Q退出后Figma恢复。重启PID59191自动ready，无需重选文件；原生箭头再一轮
  collapse/expand真实往返通过，最终Figma on/私有off，1352继续运行。
- [x] 旧/新PID分别4/2次CF接受，2/1次journal durable及2/1次clear，0变更/退出错误。
  每意图一次SetValue；六次CF接受读回0.405–0.709ms（不含写前journal/后续AX验证）。
  最终journal文件不存在，当前运行路径/三MachO hash均匹配1352 manifest。
- [x] 1351首轮实机未过：CF实时false而授权文件快照true持续超过2s，pair位置也不同；
  不能唯一归因磁盘延迟或URL旧快照。1352将CF Set+Synchronize及fresh CF作为权威，
  文件快照旧仅诊断，仍严格验证双方目标身份/归属；真实AX另作显示确认，原值不重采。
  scope/async deadline/cancel、startup pending state、termination等待门禁均保留。
- [x] 必要async/Model/stale回归、strictlint、编译无新增告警、同Apple Development
  deep/strict签名、272条九语言提取/编译资源通过；复用未变套件及1348完整clean证据。

最终候选`build/FloeBar-1352.app`（0.13.0-macos27.23-dev），dylib
`901bb7a1b022177781421f63fc55bcf63862a65c530ae0dd407148633c357a00`；
`package-1352.json`、`source-1352.json`、`core-1352-validation.json`及双PID运行日志。
真实截图包括`1352-first-hide.png`、`1352-arrow-collapse.png`、`1352-arrow-expand.png`，
其它quit/恢复截图由Terra保留同证据目录。本轮不再扩大扫描或改变系统设置。

后续按依赖推进，均不冒充本轮已覆盖：
- 隐藏自动确认：owner AX树保留1旧节点，完整读取但exact_hit=0；单纯hit0不足证明
  真隐藏。UI诚实显示“已应用；尚未自动确认”，恢复时exactHit>0可显示已核实。本轮
  以真实菜单栏截图/原生控件/CF闭环验收；下一批仅在正向宿主可见身份或标准可见性
  属性可证时增强，不重构整套scanner、不把匿名节点缺名当不存在。
- 泛化全应用目标选择/多bundle journal及同应用多项目矩阵，再统一旧hotkey/section
  仍走system overflow的分支；旧Layout全部capture尚未迁移，当前仅Figma最小验证。
- 实际异常崩溃、撤销AX权限后的启动恢复、多屏/旧系统/长期矩阵仍未实机覆盖；相应
  取消/恢复状态和pending启动边界有模型/定向只读审查证据，不改TCC来造验收条件。
其他B1b/B2–B4仍沿前文依赖；所有dirty/untracked、旧包与失败证据保留。


### 2026-11-06 · 安全多应用 1353（限定实机验收完成）

沿用本计划与原架构报告；本轮 GPT-6.1 Sol/high 唯一代码/文档/构建写入，
root/native_batch_review 只读审查，Terra 保留实机独占。新基线
`build/app-hiding-20261106/before.tar.gz` 保存291文件；旧包和全部历史证据保留。

- [x] 双源唯一且严格通过 Bool/location/menuItemLocations 归属的第三方记录形成候选；
  新选择仅允许已安装且运行中的可解析 bundle，名称/图标来自应用包。原Figma选择
  一次迁移为v2集合，空选择仍使用系统overflow。按应用Toggle仅选择箭头目标，
  明确Hide/Show执行；有owned恢复记录时先Show才允许改选择，停止的选择可保留。
- [x] Hide跳过未运行/不可用及原系统hidden项目，显示跳过数量；0可用明确说明。
  每目标首次系统写前合并且耐久保存v2 journal（兼容v1），同reader预检容量/schema；
  fresh CF为权威，授权文件仅身份/schema验证；只patch fresh entry的isAllowed。
  Show、启动与退出对owned全集逐项尽力恢复，成功仅删本条，失败保留且退出门禁不放行。
- [x] 箭头、普通菜单/快捷键走同一所选应用入口；形态按owned journal聚合。
  普通Refresh List只读，即使刷新失败再刷新也不隐式恢复；startup恢复重试独立保留。
  缺乏可靠宿主可见身份，本轮所有隐藏自动确认维持未确认；恢复exactHit仅表明该应用
  至少一项可见，未把hit0、匿名缺名或残留代理当成已隐藏。
- [x] 新27.2编译器下27组纯回归、定向多目标/旧journal/重复/归属/部分恢复/停止选择
  跳过/保守AX fixture通过；strictlint0.65.1、280条九语言源/提取/编译检查通过。
  独立Xcode27.2(27B52)全新DD完整构建及最终必要增量通过，新增显式self告警已修复；
  既有ScreenCapture弃用及新工具链AppIntents无依赖metadata提示保留。
- [x] 用户确认桌面就绪后，Terra以唯一1353 PID19654/20285完成两个严格目标
  `com.openai.codex`/`com.steipete.codexbar`的3轮真实hide/restore：首轮Hide→
  Refresh List保持隐藏→实际`Ice.ControlItem.Visible`箭头恢复；第二轮Hide→正常
  Cmd-Q退出恢复→重启自动ready与选择保留；第三轮在新PID补完整菜单栏像素
  visible→hidden→arrow-restored。AX/截图/逐目标CF共同确认，未把CF独自当物理证据。
  未运行Figma选择始终保留并跳过；最后恢复初始选择（仅Figma选中），两测试目标
  最终原allowed=true且可见，journal空，私有off；1353 PID20285继续运行。
  隐藏自动确认仍保守“已应用，尚未确认”，未声称全应用/多项目全部自动验证。

候选 `build/FloeBar-1353.app`，0.13.0-macos27.24-dev；dylib SHA256
`8694a7630265b725a478ff4952b077e0992fb81274eb67a5162daf248feeea1b`。
同开发签名身份1A6A46C1853D50F4C3AA385F4B4328A71E6A4B2B、team JD8S6QP43G，
hardened runtime/deep/strict通过。源码/签名/包hash、完整与增量xcresult、失败下载
日志和官方Sparkle校验保存在本轮证据目录；未复用27.1/Prism编译缓存。
SPM artifact停顿后，仅中断本轮自有xcodebuild；新下载官方2.8.0 zip与新checkout
固定SHA256完全一致，再预置原始artifact缓存后成功，未自动重启任何系统服务。
未改TCC、未启用实验私有assertion、未提交/推送/安装发行。


### 2026-11-06 · 隐藏反馈分层与异常退出恢复（1357限定收口）

用户明确优先解决隐藏后持续未确认，再做一次精确FloeBar进程的异常退出恢复。
延用本计划/原架构报告，Sol唯一写入、Terra独占GUI与未来唯一SIGKILL；新基线
`build/visibility-confirmation-20261106/before.tar.gz`保存291文件，旧包/证据均保留。

- [x] 1354加入独立可选只读证据原型：写前源原对象/正global-hit/明确父引用，写后
  标准VisibleChildren、稳定对象集合/进程与显示器、正可见sentinel/两轮连续排除；
  unsupported/缺名/hit0/旧对象缺席绝不自动当隐藏。退出取消可选验证，backend迟到
  返回若已退出则不再新建验证任务；owned恢复不依赖AX。
- [x] 1354 PID30674真实两目标Hide已生效，CF false与v2两条durable journal通过。
  但写前source parent分别为目标自身PID6267/39342，Children/VisibleChildren各1；
  写后两目标各4次公开可见列表仍1，status=post.no-stable-visible-exclusion，ax_code=0。
  **不是属性不支持，也不是宿主重建，而是源AX仍保留视图；不能证明物理隐藏。**
  原始proof/CF日志、当时journal bytes/hash见本轮`runtime-1354-pid30674-hidden.*`、
  `proof-1354-hidden-checkpoint.json`、`journal-1354-hidden-checkpoint.plist`。
- [x] 最后有界真实MenuBarAgent路径已构建为1356：公开menu/extras完整first-order，
  所有候选均须属性表证无Children或成功empty才是leaf，仅源原对象直接CFEqual唯一
  绑定；post全部保留节点再次证leaf。仅batch已绑定T可删/保留，R不增换且原可见
  sentinel保留，source全集/host父/所有代次/display稳定才可能连续两轮确认。
  1355未验包因“未知引用当无关联/R内部替换”审查缺口已弃为非验收候选，保留勿启动。
- [x] 新模型覆盖正向可见子集、未知替换/重复/无sentinel/无baseline/批次遗漏；定向
  测试、strictlint0.65.1、281条九语言提取/编译、同27.2有效DD增量构建及同身份
  deep/strict签名通过。首AX常量桥接编译、self告警与审查门禁返工保留，未跳检查。
- [x] 用户解锁后1356 PID72773实际Hide两目标；source baseline正向成立，但真实
  MenuBarAgent路径在process-generation/ax_code0停止，严格宿主存活代次前提不能闭合。
  尚未成功读取host Children/VisibleChildren，不能称这些属性unsupported或0关联。
  到此停止拓扑探测；按已批条件实施1357成功状态分层，默认不再跑无效probe。
- [x] 1357主状态仅承诺“已应用系统隐藏/显示设置”，真access/journal/CF失败保留。
  物理核验信息只在原生收起的“状态详情”中显示；不加用户AX设置。既有严格原型仅
  DEBUG且FLOEBAR_VISIBILITY_DIAGNOSTICS=1显式开启，正常路径日志proof=0。
- [x] 唯一真实异常退出：Terra核并SIGKILL精确1357 PID75588，写前两owned条先耐久
  后CF false接受，original=true/lastWritten=false；kill后journal hash保持。目标App
  PID6267/39342未动；重启同包PID77289自动两项CF true→clear→startup recovery完成
  后ready，两图标AX/像素重现。23:02成功检查点journal确实不存在；没有重做crash。

最终候选：`build/FloeBar-1357.app`，0.13.0-macos27.28-dev；dylib SHA256
`8ce3f7dfc45e9aa40d7642579abaadd0aa15d61809c276ca76e75ee7981685e7`，唯一PID77289。
strictlint、285条九语言源/提取/编译、27.2必要增量构建、同身份deep/strict签名通过。
默认Hide成功主状态与收起详情、真实两目标隐藏、一次crash恢复均已由Terra验证；
源码签名后不再变更，未重复构建/全套测试。

用户间隔期间新增极空间形成新基线：四选择Figma、com.openai.codex、
com.steipete.codexbar、com.zentraedi.zspaceMacApp，后三者当时owned隐藏。基线原始
journal/选择/hash保存后经原生Show临时恢复再做测试。最终极空间已停止运行，NSWorkspace
正控和ps均确认、安装bundle解析正常；无法唯一解释其退出原因，不归因本次crash。
保留四选择，仅当前可用两目标重新隐藏，主状态applied/skipped2；两目标AX/像素消失。
最终新journal恰2owned是用户保留隐藏意图，**不是异常恢复未清理**；极空间不可用，
未启动第三方、未为其新写false，三项隐藏基线只能恢复其中2项，明确保留此限制。
1355仍为review拒绝未验历史包勿启动；1354/1356诊断原型及所有失败证据保留。

证据：`crash-1357-before.*`、`crash-1357-recovery-complete.json`为先耐久/真实恢复
清空检查点；`final-1357-user-state.json`、`journal-1357-final-user-intent.plist`为后续
用户意图新journal。两PID总6 accepted/5durable/1clear、0 mutation错误/0默认proof；
CF接受读回0.217250–0.261458ms，不代表journal、AX、像素或整操作耗时。当前没有可靠
全自动物理隐藏确认承诺；未覆盖撤权、多屏、旧系统、真实局部冲突及全部多项目矩阵。


### 2026-11-06 · 原生菜单栏workspace（1358完成，最终渲染见1359）

用户选择第3个设计，唯一视觉修订为最右checkbox换原生switch；SwiftUI原生实施，
不做网页、不改全局Ice样式/窗口825×500下限。新292文件dirty基线与旧包均保留于
`build/menu-bar-workspace-20261106/`；Sol唯一代码/文档/构建写入，Terra独占实机。

- [x] 菜单栏布局原生segmented“图标排序/按应用隐藏”，隐藏从General迁入；排序
  提为独立child，正文/原权限及截图task逐字保留，按子页挂载/离开管理原生命周期。
- [x] 隐藏页仅应用列表滚动；固定header/Refresh和底部主Show/Hide、选择/不可用计数。
  图标占位/名字弹性/110pt状态/120pt switch尾列共用，缺icon原生app占位，true配置态
  为“允许显示”，开关仍只是箭头目标选择。旧disabled/restore-first/skip与所有后端不变。
- [x] 状态/文件访问为次级原生披露区，父State保持展开态；短高窗并排/缩紧局部间距，
  不增嵌套滚动。General只留启动及leading短说明，不改旧系统设置。
- [x] strictlint、297条九语言源/提取/编译、同27.2有效DD必要增量构建及同身份deep/
  strict签名通过，无新增compiler warning；仅原metadata提示。未动权限/capture后端。
- [x] 1358原生UI核心/隐藏箭头已通过；后续1359补齐内容825×500与1150×750、双披露
  展开/列与footer可见和跨resize状态保持，原排序/隐藏烟测通过。截图外框含52pt顶部
  chrome，不把外框825×552误作未达到内容500。切版前后四选择/2hidden基线已保全。

候选`build/FloeBar-1358.app`，0.13.0-macos27.29-dev，dylib
`0b1e686ca3db34edfe1509a238ea0c4273bb16fff697c9457cb8ff2f30021bf0`。
权限弹窗本轮用户和Terra均未复现，用户明确要求先跳过、留观察；没有实施讨论过的
权限/自动截图改动，没有新增权限测试，不将此UI交付称为权限问题已修复。未提交/push。


### 2026-11-06 · direct capture精确弹窗后恢复修复（1359限定完成）

1358之前用户/Terra两次进入未复现记录保留；随后用户提供“绕过系统窗口选择器直接
访问屏幕和音频”精确系统弹窗截图（reported-capture-alert.png），因此恢复此问题处理。
只基于direct截图链，不声称App录音。1358签名包保留，后基线292文件另存
`build/menu-bar-workspace-20261106/permission-1359/before.tar.gz`。

- [x] 27导航/启动AppState/3秒后台cache默认入口零像素：imageCache需明确单次user
  intent，legacy captureWindows在27中央拒绝。排序默认应用图标+名称或旧有效glyph，
  原AX拖动保留，不以录屏权限阻挡整页；手动加载/刷新才可能提交一次SCScreenshot。
- [x] request先刷新非弹窗权限，已授权不CGRequest；直接观察权限对象，未授权仅
  内联说明/用户明确按钮，不自动开设置。27不再用window title推定像素授权。
- [x] intent绑定按钮按下时编辑代次、消费后不因重现重放；orderedOut清AX/image
  active/pending。截图所有await后fresh nonprompt preflight+Task/current-window/导航/
  generation检查，返回再拒旧结果；失败/无预览内联反馈，AX排序仍可用。
- [x] 注入回归验证默认0、explicit granted1、fresh revoked0、await cancel0、晚结果
  不发布、已消费/关闭重开intent不重放；权限observer/请求恢复回归过。strictlint、
  303九语言源/提取/编译、27.2必要增量及同身份deep/strict签名通过，无新增告警。
- [x] Terra1359 PID11300默认order/General/hidden切换和后台多周期未再见prompt，
  实际提交notice计数0；应用图标/名称可辨，WorkBuddy AX右/左确认且原序恢复，
  Hide→原生arrowShow→Hide通过。内容825×500与1150×750工具内联图中双披露展开、
  列/footer可见，跨resize展开态保持；未导出新截图文件。
- [x] 四selected与ChatGPT/CodexBar两条新owned隐藏状态保留，Figma/极空间不可用
  skip2。Cmd-W→Cmd-,状态保持，但CUA会返回隐藏window树，中间真实close事件未
  严格证明；不把此分项写成实机pass，消费/取消保证来自源码和注入回归。
  代理未点击Allow，真实新授予/拒绝与显式像素截图未实测，未来显式请求仍可能系统确认。

1359：0.13.0-macos27.30-dev，dylib
`dde169fe9f8949ec71f2317cb3390f578e72765df51d3c9a44e6d73c676d05a1`。
mac27自动平均色/壁纸像素读停用，按原nil fallback保留tint/shadow/border等，壁纸圆角
像素填充/动态取色可能降级；不改用户appearance配置，不称全部外观等价。旧14–26路径
保留但未本轮实机覆盖。隐藏backend/journal/DEBUG proof默认off及1358隐藏UI字节未变。


### 2026-11-07 · 独立项目名称与隐藏中局部选择（1361限定实机完成）

本轮按用户反馈只修复显示身份与开关交互。新294文件dirty基线保留在
`build/item-label-selection-20261107/before.tar.gz`，1359默认零截图门禁保持。

- [x] 原AX对象按已有预算可选读取Help，第三方显示优先真实description/title/help；
  Stats模块差异词优先进入tile、tooltip/VoiceOver同时更新，不取截图/猜图标/位置拼宿主。
  不能确定用途的同app项目用绑定runtime identity的会话编号；同名也编号，不按名称去重。
  原tag/identityTitle/AX端点/持久布局身份保持，原生app图标不冒充菜单glyph。
- [x] 展开时选择只改名单；隐藏时关闭只恢复本bundle owned条再提交选择，新增只隐藏
  本bundle并在耐久journal+fresh false后提交，其它隐藏项不恢复/重藏。非owned外部false
  取消选择不写系统。新增在lease内fresh candidates/运行/安装二判，失败不提交choice。
- [x] mutation失败独立requiresRecovery阻新编辑/Hide/排序，Refresh不清门禁；Show不依赖
  selected非空或ready，允许orphan与空journal恢复；清门禁只在restoreAll+fresh读成功后。
  箭头/菜单/快捷键统一route覆盖selected或owned或recovery。退出/启动restoreAll保留。
- [x] 生产事务编排+真实Model.hide/restore定向回归通过，含局部保持、persist-before-write、
  failed choice不提交、orphan/空journal恢复、post-write missing/true拒绝；标签拖动/刷新
  编号稳定与重复模块不合并通过。scan/model/readback/preview保留定向回归通过。
- [x] strictlint、309条九语言源校验、1360首次编译/同身份签名通过。签后只读review发现
  UI闭包忙态缺发布的灰开关风险，已最小改为自身Published UI条件+入口同步busy拒绝，
  保留任务二判；递增1361不覆盖1360历史包，1361必要增量构建/同身份deep strict签名及309条源/提取/编译资源检查均通过。
  最终候选`build/FloeBar-1361.app`（0.13.0-macos27.32-dev），dylib SHA256
  `ca8931472d0ea1b0a580735c3891e971f85485977938ecdda25cb675cc0fcf4c`。
- [x] Terra1361 PID30866：Stats网络/CPU/内存/磁盘4个独立真实语义可辨；网络右/左
  原生AX排序确认，标签跟原项且恢复原序。Hide两目标后ChatGPT off只恢复它，CodexBar
  保持隐藏；on只重新隐藏ChatGPT。journal2→1→2，CodexBar完整条目三次字节相同。
  最终四选择/2owned隐藏恢复；Figma/极空间仍不可用，未启动/终止第三方或改TCC/服务。
- [x] PID30866路径/code hashes核实，CF accepted恰4次false2/ChatGPT true1/false1，
  局部off/on各一次commit，无额外CodexBar写入；0 mutation错误/0实际pixel提交/0proof。
  `final-1361-runtime.json`与双格式日志、三阶段原journal均在本轮artifact目录。
  stopped所选off与recovery gate故障边界仅fixture覆盖，未伪称真实撤权或全部异常实测。

GPT-6.1 Sol/high唯一writer，Terra/high实机，root/native_batch_review只读。定向测试首编译
有Swift throwing autoclosure返工一次后通过；1360首app build通过，1361为review后小增量，
耗时约20.4分钟（含实现、审查、构建与实机），token/cost unknown。1361实机核心首遍通过。
1359外观fallback/旧OS/显式预览权限限制继续适用；没有新增截图、私有隐藏或物理自动确认承诺。


### 2026-11-07 · WPS漏项/真实鼠标拖动/说明精简（1362历史诊断阶段）

新298文件dirty基线`build/wps-drag-cleanup-20261107/before.tar.gz`保留。实际用户基线
已变为6selected（Figma/UU/ChatGPT/WorkBuddy/微信/极空间）及四个可用目标owned隐藏，
其中四hidden为UU/ChatGPT/WorkBuddy/微信，CodexBar未选且显示；不得恢复旧四选两隐藏。
切版前选择/原始journal字节与hash在`user-state-before-1362.json`及journal基线保全。

- [x] 只用真实menu item namespace/sourcePID发现owner，额外列出已发现却不能安全控制
  的运行owner并标短原因；控制资格仍为原strict双源唯一bundle/Bool/location归属。
  现有App书签scope内有界记录live/file缺失、重复计数或schema/ownership拒绝原因，
  不猜WPS helper归主app，不直接读取受保护系统文件，不创建/修复系统记录。
- [x] 源码确认27 editor为本地mouseDragged/mouseUp，无需用户⌘；删除误导及重复标题、
  overflow/历史section等解释，仅一条普通拖动指引。保留明确预览按钮和文件/状态详情，
  成功状态精简为“已设置隐藏/显示”，默认等待说明去重，真实忙态/错误恢复行动保留。
- [x] 27静稳等待复用既有canStartDrag操作修饰键规则，静态CapsLock不再永久阻塞；
  200ms静稳/2s总限、80ms hover、真实新move/button/key/flags/scroll中止、端点/同屏/
  token与单gesture无自动重放全部保留。仅新增阶段/首个事件类型/来源分类/时序元数据，
  不记录键内容或鼠标全局轨迹。旧系统等待不改。
- [x] interaction/session/strict Model/单项事务定向回归、strictlint、316九语言源/提取/
  编译、Xcode27.2首次构建及同身份deep strict签名通过；仅既有AppIntents metadata提示。
- [x] 当时1362尚未证明WPS可写；后续1364 typed分组事实与1366真实控制/恢复详见最新段落。
  真实鼠标排序已由1362实际gesture与AX读回确认，不使用1361仅AX左右移动冒充。
  shell只读运行身份确认主app9354 com.kingsoft.wpsoffice.mac及cloud51614
  cn.wps.wpscloudsvr均精确安装可解析；shell公开CF没有返回数据，不推断记录缺失。
  1362候选供App既有授权scope唯一诊断，不声称WPS隐藏已修好。

候选`build/FloeBar-1362.app`（0.13.0-macos27.33-dev），dylib SHA256
`cff17e4aa8f6dcf7e35c06f0458a10b1646067bbd7816f467afc6b14724b14ef`。
GPT-6.1 Sol/high唯一writer，Terra/high实机、root/native_batch_review只读。316=309旧值
保留+7；测试/app首编译过，lint格式小返工后通过；耗时最终记录，token/cost unknown。
默认capture0/私有off/恢复/单项事务原有边界保留，未提交或发布。


### 2026-11-07 · WPS系统分组与安全恢复（1366限定实机完成）

WPS真实source为cn.wps.wpscloudsvr/PID51614。1364在既有授权scope内两源均30pairs、
complete=true/opaque_data=0，精确发现唯一typed root/location均为
com.kingsoft.wpsoffice.mac，menuItemLocations[0]直接引用helper。并非系统没有记录；
原exact-only策略因helper无独立key而漏项。只对这样的系统声明组建立独立Target，
未知foreign/member、重复root/双源分组不一致仍拒绝，原exact策略保持。

- [x] root唯一原生行控制其全部已验证成员；安装proof用注册root、规范嵌套/相对helper
  路径、exact标识、当前同leaf+Team、parent严格封装/helper标准签名及全部helper链接
  不逃root。不是只按名字或Team映射。root只读CLI主strict=0/helper标准=0，helper
  strict=1仅3条链接目的规则且均存在/root内，不称签名失效；production inspect只读
  实测通过1.371s。SecCode对象只留worker，不在MainActor执行重验资源工作。
- [x] bounded worker/cache；实际写前fresh安装proof、await后全成员双源唯一+CF/stamp/
  注册路径重核；新owned即使AX节点消失且selected尚未commit仍延续root资格。
  helper只作真实来源与排序端点，不改tag或持久排序身份；默认物理自动proof仍off。
- [x] 新entry2带typed安装绑定，旧entry1及envelope2混合兼容，journal先fsync再单写root
  isAllowed，field-only合并fresh元数据。冷恢复不依赖selected/running/AX；已original
  的fresh typed root只清自己journal，不为noop强求旧安装证明。false→original必须重验，
  一组失败保留并继续恢复其它owned。绑定/成员变化不猜新归属。
- [x] 1364曾UU写成功、第二ChatGPT条耐久后精确文件Data读257/underlyingEPERM，
  第二CF写未发生；显式Show成功，授权仍可用。原子替换原因未实证。1365仅该精确
  canonical错误允许一次现有bookmark withoutUI重新resolve/startscope/validatedData
  返回并正确释放fresh scope；随后重新copy live CF，不重放CF写/整hide/权限请求。
- [x] 真实Backend隔离IO/journal fixtures覆盖混合与旧single journal、冷/未选恢复、局部
  组失败仍恢复exact、成员变化false拒/true仅清、proof await竞态、新owned/AX空选择
  窗口、on→refresh→off、helper→root owned映射、EPERM最多重开一次/保新CF元数据/
  每目标单写/再次失败留journal，parse错误不重开。旧Bool/location/ownership回归通过。
- [x] 1362可见Stats真实无Cmd鼠标往返两次：native began/released、fresh AX验证和UI
  confirmed、原序恢复，0input stop；不是只AX左右命令。hidden WorkBuddy负例先报
  endpointUnavailable；1363晚门禁反馈未覆盖更早confirmedEndpointOrder，1364已改
  missing/failed-hit具体端惰性owned分类。可见旧journal不挡真实hit、无自动展开/重试。
  冗余标题/overflow/历史section/General说明已移除，必要组控制短句与恢复行动保留。
- [x] 1365 PID65704第一轮WPS on→refresh→off实机Eric消失/重现，其它4hidden保持，
  CF false/true分别01:53:37/51 accepted。4条快照01:54:06在此轮之后，**没有捕获此轮
  on5快照**。第二次on于01:55:08 entry2耐久后12.134s error=deadline，无该轮CF写接受、
  choice未commit。5journal与runtime保全；一次Restore清WPS已original条并恢复其它4，
  后按当前六选择重新Hide原4。不能称1365重复控制/正常退出已全过。
- [x] 1366仅proof时间语义/QoS窄修：同锁记queued/began/finished/result，以queued→
  finished≤原12s判worker预算、结果龄也独立≤12s；真晚/未完成/过旧仍拒，所有取消、
  max2/slot identity/注册+stamp/CFfresh门禁保留。fresh=userInitiated，catalog=utility；
  仅阶段/时序日志。历史deadline不能倒推出UI迟消费已证。production timing边界与
  原worker回归、strictlint、首次增量build和327条九语言源/提取/编译通过，同身份deep/
  strict签名通过，无新告警（仅原AppIntents metadata提示）。Backend/group/scope/capture
  与1365逐字一致。
- [x] 1366 PID52814严格握手两轮：4baseline→WPS on5→refresh/off4→再on5；Eric
  消失/重现，其它4保持隐藏。三阶段原4 original/lastWritten及完整entry字节全部等
  baseline，off4整journal hash也相同。携5正常Quit五target各true accepted、journal清、
  PID止，下一launch五目标fresh allowed；物理明确回现Eric/ChatGPT，其余3不以匿名
  AX作物理结论，恢复设置由CF/allowed UI确认。
- [x] entry2真实异常退出：1366新PID56098七选Hide5，typed journal先耐久/五false接受。
  经proc_pidpath/完整起始身份/三个code hash核验后，用户/root明确授权仅该实例一次
  SIGKILL。进程止，5journal原bytes/hash255ea707…ae447完全不变；不触第三方/系统服务。
  同包重启PID57609自动五true→journal clear→startup recovery完成，代码随后才ready；
  Terra在新编辑前确认七选/五allowed/可编辑。crash恢复检查点journal确实不存在。
- [x] 最终PID57609展开态取消WPS只改choice，不产生WPS新CF写；再Hide原4，恢复
  六选择/四条v1 true→false的新journal，WPS唯一root off且可用、Eric显示，Figma/极空间
  不可用skip2。最终4journal是用户隐藏意图，不是恢复残留；新进程fresh原值快照不要求
  与此前已清journal跨实例字节相同。WorkBuddy一次hidden普通drag正确提示先展开应用，
  无overflow按钮/顺序变化；日志applicationHidden为预期stop，0 native gesture。
- [x] General仅登录switch、排序一条简短指引、隐藏列/footer对齐、Stats网络/CPU/内存/
  磁盘原序保持。三PID共26 accepted（false15/true11，WPS false/true各3），0 unexpected
  mutation错误/0实际pixel提交/0AX自动proof。六次fresh安装proof均finished-in-budget，
  run0.919–1.720s/结果龄0.680–20.499ms；没有观测到新的deadline/late-consume分类。
  1365历史超时具体慢因仍未知，不倒推为已证UI迟消费。scope重开本轮未自然触发，
  其限定EPERM行为已由真实Backend注入回归覆盖，未改TCC或主动制造撤权。


最终运行包build/FloeBar-1366.app，0.13.0-macos27.37-dev，dylib SHA256
2961ca4e3ac05ef685610fc64ce925b6c1aed2163a5c6f49608db945fc8e94a1。
保留所有dirty/旧包/原证据，不提交或发布；默认0capture/私有off/TCC与系统服务均未改。
GPT-6.1 Sol/high唯一writer、Terra/high实机、root/native_batch_review只读。App各版本
首编译通过；fixture有Swift语法/异步等待返工，GUI反馈早入口及proof时序也有返工，非
first-pass全部成功。额度审批失败时动作未执行，恢复额度后重做同只读guard；到源码签名冻结约89.4分钟；冻结后至实机首基线等待约413.2分钟（锁屏/用户等待），
最终验收阶段约22.7分钟，wall总约525.3分钟，token/cost unknown。真实worker/结果年龄超预算仍安全停止；1366上述正常/异常恢复与最后用户状态已实机通过。

### 2026-11-07 · 源码收口与正式发行准备

用户确认 bug 已修复，授权收口、推送 GitHub 和制作可下载更新包。原126个dirty/
untracked文件已保全至 `build/release-closeout-20261107/before.tar.gz`，未覆盖旧包、
历史证据或运行状态。当前生产源码与1366冻结manifest逐文件SHA256一致，复用原
构建及实机证据；本轮仅更新README、MACOS27和distribution的当前能力/发行说明。

- [x] 完整 `bash scripts/test.sh` 通过，包括327条九语言资源检查；固定本机SwiftLint
  严格检查139文件，0 violation；1366包deep/strict签名校验通过。`git diff --check`
  通过；独立只读gitleaks 8.30.1扫描126文件无secret。完整app/XPC构建的CI扩展仍是
  原计划待办，不以纯回归冒充CI完整编译。
- [x] 核对GitHub公共main仍为787a67f、最新公开标签仍为v0.13.0-macos27.1。
  命令行无推送凭据，改用已有仓库写权限的GitHub连接器提交源码；不改其他远端分支。
- [ ] 正式发行需补齐项目团队JD8S6QP43G的Developer ID Application证书/私钥及
  名为FloeBar的notarytool凭据。当前仅Apple Development身份；用户已明确选择补齐后
  再发布正式自动更新包。因此保持现有release/appcast，暂不上传开发包或宣称公证完成。
  凭据就绪后递增版本/构建、双架构Release archive、签名/公证/stapler、Sparkle签名、
  公开精确源码tag、旧版本发现/安装更新验证按distribution原清单继续。

本轮root唯一文档写入、release_review独立只读审查；实际root/审查模型与effort运行时
未提供，记录unknown。回归/lint首跑通过；命令行认证失败后切换连接器，非全流程首试
成功。墙钟耗时续记本目录closeout证据；token/cost unknown。未新增生产逻辑或修改TCC。

云端首跑续接：源码已由a270b29进入main，本地树与远端树完全一致。CI旧Swift5容器
报告15条lint错误，而本机0.65.1为0；改为官方0.65.1 portable包、固定官方SHA256并
显式检查版本，保留原strict规则。纯回归云端在InstallationProof fixture顶层deadline
失败；原fixture把健康重试也限制到60ms，并用固定150ms sleep假设worker仍未完成。
改为有界信号量握手、健康重试2s、overlap默认12s及有界harness等待。60ms真超时、
所有completionBudget数值边界、未完成slot占位/旧waiter隔离/最多两个worker断言均
保留，生产12s门禁及源码不变。定向fixture重编译/运行通过；再次云端验证继续跟进，
不把首轮失败记录改写为通过。CI完整app/XPC构建仍未新增。
