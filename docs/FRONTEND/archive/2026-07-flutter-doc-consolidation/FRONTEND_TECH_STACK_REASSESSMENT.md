# TransVortex 前端技术栈复盘：为什么值得验证 Flutter

本文是一次前端技术路线复盘，并在多轮评估后给出明确倾向：**Flutter 值得作为新的主体验前端做一次正式技术验证（spike）。** 它不是迁移命令，也不是立即废弃 Tauri 的决定；最终走向以 spike 实测为准（见 §10）。

复盘背景不是“追新技术”，而是两件事同时成立：

1. 当前前端设计目标已从“用 Web 技术快速做桌面壳”转向“固定、专属、自绘、强 App 感的桌面工作面，并预留字幕审看 / 时间轴 / 波形 / 视频叠字这类重交互未来”。
2. 现有 Tauri 前端**尚未执行**这套设计目标，本身就处在要被重做的阶段（见 §2）。

> **一句话结论**：决定性的轴不是“Flutter 能不能做出 App 感”（答案显然是能），而是**持续响应式 UI 的运行时流畅度 + 桌面工程落地成本**。在前者上 Flutter 有结构性优势且有实测与行业旁证支持；在后者上 Flutter 的真实成本集中在“多窗口”和“打包+通知”两处，且这两处相互咬合，应在 spike 早期集中戳穿。

---

## 1. 触发复盘的设计约束

项目早期选 Tauri 的合理性来自：能用 React/TS 快速搭桌面前端、复用 Web 生态与调试工具、Rust 侧做系统桥接、壳体轻。

但 `FRONTEND_DEVELOPMENT_GOALS.md` 与 `FRONTEND_DESIGN_SPEC.md` 现已形成更强的设计目标：

- 主窗口必须像固定的原生桌面 App 工作面，不允许路由、网页式纵向滚动、卡片流、Web 管理台结构。
- 不让通用组件库决定产品气质；状态以世界对象、形态、动画和直接操作表达。
- 明确预留重交互未来：字幕审看、字幕片段编辑、时间轴、波形、视频预览叠字。

这导致一个结构性观察：**Tauri 的主优势是 WebView，而当前设计目标在持续地反 WebView 的默认倾向，并把产品未来压在 WebView 不擅长的持续重交互上。**

需要说明：“反 Web 默认”这件事本身只是**附带收益**，不是选 Flutter 的主论据。主论据是性能与手感（§4）。

---

## 2. 当前 Tauri 前端的真实状态：本就要重做

这一节很重要，因为它直接消解了“换 Flutter = 丢弃已有资产”的反对意见。

仓库现状（已核对）：

- `desktop/` 下约 5350 行 TS/TSX + 758 行 Rust（`src-tauri/src/main.rs`），是 Tauri v2 + React 18。
- 但 **goal 与 design 两份文档尚未被实现**。`FRONTEND_DEVELOPMENT_GOALS.md` §1 把现实现当成“待解决的问题”逐条记录，代码亦印证：
  - 假进度环：`ClientHomePage.tsx` 的 `progressFor` 直接返回 `ready=12% / canceling=76% / failed=66%` 的伪百分比。
  - `position:absolute` 手摆 px 导致的真实包围盒碰撞；10px 中文；渲染不出的精细字重（950/930…）。
  - 互不相干的萌系母题拼盘（礼物盒 / 魔法挂件 / 笑脸轨道 / 缝纫线轴），失败态仍在笑；纯色小灯（`service-lamp`）承载状态。
  - 孤儿旧前端（`app/router.tsx`、旧 `*Page`）仍被 `tsc` 编译、仍拉 `lucide-react`。
- `tauri.conf.json` 里 `"bundle": { "active": false }`——**当前根本没有启用安装包流水线**。

结论：**现有 Tauri UI 不是要保护的资产，而是要拆的脚手架。** 因此“迁 Flutter 要重写 UI”这件事，在“无论如何都要重写 UI”的前提下不构成额外成本。真正可复用、且与 UI 框架无关的是 `domain/` `adapters/` `services/` 那层协议契约知识（见 §7）。

同时也要诚实记下反向一面：**当前这摊未完成的实现，证明的是“第一版没有设计纪律”，并不能直接证明“有纪律的 WebView 一定做不出 App 感”。** 所以选 Flutter 不能只靠“现有 Tauri 难看”，必须靠 §4 的性能论据站住。

---

## 3. Flutter 与设计目标的模型更接近（附带收益）

Flutter 原生窗口承载、UI 不走 WebView/DOM、用 Dart 写声明式 UI、engine 负责布局/绘制/合成/动画、自绘控件不依赖系统原生控件。

因此它默认就适合：固定尺寸工作面、自绘标题栏与状态对象、动画 / 形变 / 过场、物件化交互，以及字幕审看 / 时间轴 / 波形 / 叠字这类未来功能。

与 Tauri 相比，Flutter **不需要先规避网页心智**：Spec 花大量笔墨去消灭 WebView 默认行为（无滚动条、自绘焦点环、不可选中文本、无 FOUC/pop-in），这些默认在 Flutter 里根本不存在，是 opt-in 才有。这能少打一场“用设计禁令压住 WebView 默认”的仗——但再次强调，这是**附带收益**，不是主论据。

---

## 4. 核心论据：性能与手感

这是本次复盘真正决定方向的一节。

### 4.1 架构差异：WebView 在“持续响应式 UI”上天花板更低

WebView/JS 模型的结构性软肋不在“画不出来”，而在两点：

1. **JS 单主线程**：UI 渲染、事件处理、状态 reconciliation、IPC 消息处理全挤在一根主线程。任何同步重活——一次性处理积压事件、同步解析大段 JSON-RPC 响应、状态更新风暴引发整树重渲染——都会**冻住整个界面**。
2. **DOM 渲染管线昂贵**：每帧走 layout→paint→composite，一次状态变更可能触发大树同步布局。“复杂响应式状态”会放大这两点。

Flutter 在这件事上结构性更强（但**不是免疫**，见 4.4）：

- 渲染 / 合成在**独立 raster 线程**，UI 线程中等忙时滚动与动画仍可由 compositor 稳住。
- 每帧渲染成本低一个量级：retained-mode 场景树，无 CSS 级联、无 reflow。同样的状态变更，撞到掉帧线之前余量大得多。
- 重活可干净地丢去 **background isolate**（`compute()`/Isolate）。

### 4.2 项目内实测：拖拽与取消卡顿

在上一轮优化过程中，项目内出现过可复现的真实卡顿：

- **拖拽卡顿**：`onDragDropEvent` 每个 over 事件触发重渲染，叠加 `.is-drag-over` 的大面积 CSS 效果与大尺寸 SVG/PNG 重新合成。
- **取消任务导致整个 UI 冻住**：典型的“JS 主线程被同步阻塞”症状——取消时触发了一坨同步重活，整根线程没空，界面全冻。

这些症状**已在后续优化中被修复 / 规避**。记录它的意义不在“现在还卡”，而在于它**实证了上述架构天花板**：WebView 让人**很容易不小心**写出阻塞主线程、或重渲染过贵的代码；每一处都能单独修，但这种“容易踩坑、余量小”的倾向是结构性的。

### 4.3 行业旁证：Clash Verge vs FlClash

一个对症的真实对照：

- **Clash Verge / Clash Verge Rev**：Tauri + React + WebView2。
- **FlClash**：Flutter。
- 社区普遍观察：**FlClash 的 UI 明显比 Clash Verge 更流畅。**

为什么这个例子比泛跑分更有说服力：这类代理客户端的 UI 负载是**持续高频更新**——实时流量曲线、连接列表不停刷、节点延迟跳动，正是 DOM 最吃力、也正是 TransVortex 未来场景（任务事件流、字幕长列表、进度实时更新、波形/时间轴）的**同一类负载**。

诚实的 caveat：这是“应用对应用”对比，不是受控实验。FlClash 更顺也可能沾了它代码更克制、列表虚拟化做得好等因素。所以它**支持**“Flutter 在实时响应 UI 上更流畅”，但不是纯净因果证明。即便如此，因为工作负载高度同类，它仍是**方向可信、相关性高**的数据点。

### 4.4 诚实边界：优势在哪里、不在哪里

- Flutter **也是单 UI 线程（Dart isolate）**，UI isolate 上干同步重活照样冻。“单线程”不是浏览器独有原罪；Flutter 的赢面是“掉帧门槛高很多 + offload 更顺手”，不是“永不卡”。
- **静态 / 近乎 idle 的界面（当前 MVP：拖文件→显示状态→点开始）几乎没有可感性能差距。** WebView 在这种屏上不会卡。所以“Flutter 更流畅”**对当前这一版兑现不出来**。
- 性能优势真正兑现的地方，**全在持续重交互面**——也就是字幕审看 / 时间轴 / 波形 / 叠字这个**重编辑器未来**。

→ 因此性能这条最终收敛成一个产品判断：**产品重心是否在那个重编辑器未来？** 是 → Flutter 的性能优势从“看场合”变“明显”，值得现在就赌；否 → 在 MVP 上它兑现不出来。

---

## 5. 能力对比：多窗口与原生功能

### 5.1 多窗口：Tauri 明显占优——但原因不是“Flutter 画不出来”

关键区分：**“自绘 UI”解决“在画布上画像素”；“子窗口”解决“向操作系统申请一个新顶层窗口”（Windows 上 = 独立 HWND + 自己的消息循环 + 自己的渲染表面）。这是 OS 窗口管理层，不是渲染层，两者互不相干。**

- **Flutter 弱**：架构原本是“一个 engine → 一个 view”（移动端基因）。历史上开第二个 OS 窗口要**再起一个完整 engine 实例**（独立 isolate、独立 widget 树），两窗不共享内存，跨窗状态要自己搭 method-channel 桥。`desktop_multi_window` 即如此——重、挑、跨窗状态同步是个消息传递问题。官方 multi-view/多窗口在推进，但仍在成熟中。
- **Tauri 强**：本职就是“原生壳 + web 内容”。每个 `WebviewWindow` 是真·OS 窗口，由 Rust 直接调系统窗口 API；多窗都连同一个 Rust 后端，共享状态天然简单。当前配置窗（`openConfigWindow`）正是用它的运行时窗口创建。

缓冲：本项目窗口规模小（主窗 + 翻译设置 + ASR 设置 ≈ 3 个），社区插件应付得了，只是比 Tauri 费手。另有设计取巧空间——Spec 禁的是“主窗口内嵌**网页 modal**”；Flutter 里 in-engine 的自绘面板**不是**网页 modal，严格按字面未必违规，但是否符合“真·工具窗”本意需确认，不算白捡。

### 5.2 系统弹窗 / 文件选择：打平，甚至更合规

- **文件 / 目录选择**：`file_picker` 成熟，直调 Windows 原生 `IFileOpenDialog`，与现有 `plugin-dialog` 体验对等。**不卡手。**
- **确认 / 提示对话框**：Flutter 无一方原生 MessageBox，但通常用自绘 `showDialog`——这**恰好符合** Spec（自绘、不泄漏 web/原生 chrome）。**不但不卡手，反而更对路。**

### 5.3 系统通知：唯一的真卡手点——且与打包同根

Windows 要弹带 App 身份、能进通知中心、点击可回调的正经 toast，系统层面要求：**AppUserModelID (AUMID) + 带该 AUMID 的开始菜单快捷方式（非打包应用），或 MSIX 打包（自带身份）。**

- 这是 **Windows toast 的硬要求，不是 Flutter 的锅**——Tauri 也要满足。
- 区别一：Flutter 这边靠社区插件（`local_notifier` / `flutter_local_notifications`），点击回调 / 动作按钮在 Windows 上有粗糙边缘；Tauri 的 `plugin-notification` 更顺。
- 区别二：Tauri 安装器顺手建带 AUMID 的快捷方式；Flutter **无内置安装器**，这套“身份 + 快捷方式 / MSIX”要你自己在打包时接上。

→ 所以**通知卡手 ≈ 打包卡手，同一个根**：都源于“Flutter 不替你管 Windows 应用身份/安装”。把打包搭好，通知也就通了。

补一条事实：**通知现在 Tauri 这边也没做**（Spec §7 注明当前 capabilities 只有 dialog/opener）。所以通知是**两边都要新建**的功能。

### 5.4 张力总表

| 维度 | 占优方 | 强度 | 备注 |
| --- | --- | --- | --- |
| 多窗口 / OS 窗口管理 | **Tauri** | 明显 | Flutter 靠多开 engine 实例，小规模可补 |
| 实时响应 UI 流畅度 | **Flutter** | 明显 | 项目内实测 + Clash/FlClash 旁证 |
| 文件 / 目录选择 | 打平 | — | `file_picker` 对等 |
| 自绘对话框 | **Flutter** | 轻 | 更合 Spec |
| 系统通知 | **Tauri** | 轻~中 | 但两边都没做；Flutter 与打包同根 |
| 自带引擎 / 跨机器一致 | **Flutter** | 中 | 不依赖用户机器 WebView2 版本 |

两个明显项**方向相反**：Tauri 赢多窗口，Flutter 赢实时流畅。而 TransVortex **两个都要**。所以选型收敛成：**Flutter 在“3 窗口”小规模下的多窗口能力，够不够用？** 够用 → Flutter 拿下（它赢的实时流畅是产品未来核心，输的多窗口在小规模可补）；不够用 / 太多坑 → 回到“有纪律的 WebView”。

---

## 6. 引入 Flutter 的工程复杂度

### 6.1 开发环境：不重（重型工具链多半已付费）

| 项 | 无重 | 是否已有 |
| --- | --- | --- |
| VS 2022 +「C++ 桌面开发」（MSVC / Windows SDK / CMake） | 重（~5–10GB） | **多半已有**——Rust/Tauri 构建用 MSVC 链接器 |
| Flutter SDK（含 Dart） | ~2GB | 新增 |
| VS Code + Flutter/Dart 插件 | 轻 | 新增（轻） |

**实际净增加 ≈ Flutter SDK 一次下载。** 最重的 C++ 工具链已随 Rust/Tauri 装好。日常开发循环（hot reload、Dart 工具链）顺。**开发环境谈不上重。**

### 6.2 打包：这才是 Flutter 真实的 DIY 成本

`flutter build windows --release` 产出**一个文件夹**（exe + `flutter_windows.dll` + `icudtl.dat` + `data/` + 插件 DLL），不是单 exe。

- **无官方安装包生成器**：Tauri 的 `tauri build` 给 MSI/NSIS + 更新器 + 签名钩子；Flutter 要自己拼——`msix` 包，或自写 Inno Setup / NSIS / WiX，或 zip。代码签名也自己接。
- 缓冲：**Tauri 的 bundler 当前是关着的（`active:false`）**，所以这不是“丢掉已用流水线”，而是“两边都要新建，Flutter 这边更费手”。**这是引入 Flutter 最实在的一次性成本，且与 §5.3 通知是同一套要解决的事。**

同时必须补充一条边界：**Tauri release 分发在本项目里也尚未完成项目级验证。** Python sidecar、worker、ffmpeg、模型 / 资源、用户级凭据、安装后路径、WebView2 环境等都没有走过真实安装包流水线。因此不能把“release 打包风险”单独归给 Flutter；更准确的说法是：

- release 分发是两条路线都未验证的共同风险；
- Tauri 的 bundler 与 Windows 身份 / 安装器路径更成型；
- Flutter 需要自己补安装、Windows 应用身份和通知回调这部分工程。

所以 Flutter spike 不必在第一小时纠结完整安装包，但在路线决策前必须跑过 release 构建与至少一条可安装 / 可启动 / 可通知的验证路径；必要时用 Tauri release baseline 作为对照。

### 6.3 体积与鲁棒性

Flutter 引擎多带 ~15–20MB；但分发体积大头是 Python + ffmpeg + 模型缓存，这 20MB 是噪声。好处：Flutter **自带引擎**，不依赖用户机器 WebView2 版本，消除“在我机器好好的、到客户白屏”这类分发期方差。

---

## 7. Python JSON-RPC sidecar 作为共享后端边界

当前 Python sidecar（`src/transvortex/app_service.py`）是整个复盘中最值得保留的架构资产，与前端框架选择**正交**。

它已通过 `stdin/stdout JSON-RPC` 暴露桌面 API：`desktop.snapshot`、`tasks.list`、`tasks.events`、`runtime.submitRun`、`runtime.cancel`、`provider.save`、`provider.test`、`result.open`、`result.reexport`。

Flutter 可直接用 Dart 的 `Process.start()` 启动 sidecar：启动 `python -m transvortex.app_service` → 向 stdin 写 JSON-RPC → 从 stdout 按行读 → 用 `id` 匹配 → 转 Dart model。这与当前 Tauri/Rust 桥接本质相同，甚至更直接。

现有 `domain/` `adapters/` `services/` 那层（TS）虽不能直接搬到 Dart，但它**编码的协议契约知识可作为设计直接迁移**。

### 7.1 不要过度抽象协议

避免把“双前端”变成“大平台协议设计”。分层：
1. **保留现有 desktop API**：Flutter 先只接核心产品流，Tauri（若保留）继续接配置 / 维护。
2. **稳定关键契约**：常用方法写 request/response 文档；保留 `request_version`/`api_version`；统一错误结构 `{ code, message, details }`；后端 redaction 不让前端处理 secret 泄露。
3. **只在重复痛点出现后再抽象**：两端都需要的 payload 再稳定为共享 schema，不提前平台化。

协议边界的目标是复用后端，不是制造额外产品平台。

---

## 8. Slint 与 Qt Quick 的评估结论

**Qt Quick / QML**：能力强、桌面经验丰富，但技术栈重、C++/QML 工程复杂、授权 / 打包 / 模块依赖需额外治理，与现有 Python 后端轻量衔接不如 Flutter 直接。不优先。

**Slint**（原 SixtyFPS，Rust 核心，desktop + embedded）：痛点很贴合（不要 WebView、不背 Qt 重量、声明式自绘轻量），但生态年轻、复杂桌面案例少、主攻 embedded/HMI，中文输入 / 字幕编辑 / 长列表 / 复杂工具窗需大量实测；且当前后端核心非 Rust，其 Rust 亲和优势被削弱。可作轻量对照 spike，不优先于 Flutter。

---

## 9. 推荐定位

- **Flutter：主体验前端**——主窗口、任务状态主体、拖入片源、运行进度、失败修复、完成态打开结果、配置工具窗的产品化版本、结果审看，以及后续字幕编辑 / 时间轴 / 波形 / 叠字。验收遵守现有 design 文档。
- **Tauri：维护台 / fallback / 紧急恢复（可选、且很可能是后期才需要）**——provider 配置、凭据检查、doctor 诊断、task catalog 检查、任务事件查看、手动触发后端、开发调试。这类界面允许更接近配置台，不参与主产品 UI 设计验收，坦然利用 WebView 在表单 / 列表 / JSON / 诊断上的长处。

注意：**“双前端”不是目标，而是一个可选的、很可能很后期的兜底。** 近期路线是 Flutter 单主体验；是否长期保留 Tauri 作维护台，待主体验稳定后再定，避免过早承担两套维护成本。

---

## 10. 验证计划：一次目标明确的 Flutter spike

spike 不验证“Flutter 能不能做出 App 感 / 好不好看”（答案显然是能）。它**只验证两类会一票否决的风险**，以及在真实条件下的性能。

当前仓库内的验证落点是 `desktop_flutter/`。这个目录采用正式候选前端命名，而不是临时 `spike` 命名：它可以承载后续主体验实现，但在本节验收通过前，仍不代表迁移完成，也不替换现有 `desktop/` Tauri 前端。

### 10.1 两级门槛：Phase A / Phase B

为了避免第一轮 spike 被安装器工程拖慢，同时又不把分发风险藏起来，验证拆成两级：

- **Phase A（当前阶段）**：验证 Flutter 是否值得继续作为主体验前端推进。必须覆盖三窗口、多窗口状态同步、中文 IME、release 文件夹运行、最小 Python sidecar 链路、1000 条字幕审看性能。
- **Phase B（进入正式主体验实现前）**：补齐完整打包与通知验证。包括 MSIX 或 Inno/NSIS、AUMID / 开始菜单身份、系统通知弹出与点击聚焦。

Phase A 不做安装器、不建开始菜单快捷方式、不接系统通知点击；但 Phase B 未通过前，不得把 Flutter 路线视为完成迁移。

### 10.2 真实条件（硬性）

- 在**真实目标机器**（Windows LTSC 2021 等）上、**release 构建**下验证；不以 debug / 浏览器端口为准。
- Phase A 的 release 要求是 `flutter build windows --release` 产出的**文件夹可直接运行**；不要求安装包。
- 关键性能项**量化**：帧时间（有无掉帧）、内存占用、跨机器鲁棒性（换几台不同显卡 / WebView2 版本的机器看白屏率）。

### 10.3 Phase A 必验风险

1. **多窗口 + 跨窗状态 + 中文 IME（最高优先）**
   - 用 `desktop_multi_window`（或官方多窗口）开主窗 + 翻译设置窗 + ASR 设置窗。
   - 验证：窗口创建 / 关闭 / 焦点 / 固定尺寸 / 自绘标题栏；**跨窗状态同步**（在设置窗改默认模型 → 主窗 job 描述即时更新）。
   - **中文 IME**：在设置窗的 base_url / 模型名 / key 输入，以及未来字幕编辑场景里实测候选窗位置、组合输入、焦点切换、滚动中编辑、复制粘贴——**Windows release 下**。
2. **Python sidecar 最小链路**
   - 用 Dart `Process.start()` 启动 `python -m transvortex.app_service`。
   - 调通 `desktop.snapshot`；同时验证一条错误响应和 sidecar 退出。
   - 不重写协议，不提前抽象平台层。
3. **字幕审看性能小样**
   - 1000 条字幕片段，滚动 / 选择 / 编辑 / 质量标记，在 release 下观察帧时间、内存和输入延迟。

### 10.4 Phase B 必验风险

1. **打包 + 通知（同根，一起解决）**
   - 用 MSIX 或 Inno/NSIS 产出可安装包，建立带 AUMID 的快捷方式 / 身份。
   - 在此基础上让系统通知能弹、能点击聚焦（“字幕已生成·点击打开”“制作失败·点击查看”）。
   - 该项不阻塞 Phase A，但在进入主体验实现前必须补上真实验证。

### 10.5 性能与流畅度对照

- **结果审看小样**：1000 条字幕片段，滚动 / 选择 / 编辑 / 质量标记，在 release 下观察帧时间。
- 有条件就做**同题对比**：用主启动器**同一屏**，各做“有纪律的 WebView 版”和“Flutter 版”，量各自为贴合北极星而“对抗默认值”花的力气与帧表现。这才是公平的同口径比较，避免拿“烂 WebView”对“新 Flutter”。

### 10.6 其它桌面能力（顺带验证）

文件选择（`file_picker`）、拖文件（`desktop_drop`）、打开路径、无边框 + 自绘标题栏 + 固定尺寸（`window_manager`）、托盘（`tray_manager`）。

### 10.7 通过 / 不通过判据

**Phase A 通过（→ 继续 Flutter spike，准备 Phase B）需全部满足：**
- 同样设计约束下，Flutter 明显更容易做出非 WebView 的 App 手感。
- 中文输入与字幕编辑在 Windows release 下**无硬阻塞**。
- 3 窗口模型 + 跨窗状态同步**可控、不踩明显坑**。
- 1000 条字幕审看在 release 下**无可感卡顿**。
- Python sidecar 对接简单，协议不需大改。

**Phase B 通过（→ 进入 Flutter 主体验实现阶段）需满足：**
- 打包 + 通知能跑通（可安装、能弹通知、能点击聚焦）。

**不通过（→ 继续 WebView，但收紧定位）：**
- 不再追求“完全反 Web”，改为定义“**强约束的 WebView 桌面 App**”，用一次有纪律的重做兑现 goal/design；多窗口继续用 Tauri 原生能力。

---

## 11. 当前结论

- **Flutter 值得作为新主体验前端做正式 spike。** 主论据是**持续响应式 UI 的运行时流畅度**（架构差异 + 项目内实测 + Clash/FlClash 旁证），反 Web 默认只是附带收益。
- **现有 Tauri UI 本就要重做**，所以“迁 Flutter 重写 UI”不构成额外成本；但“现有难看”不能单独当作选 Flutter 的理由，须靠性能论据。
- **Flutter 的真实成本与风险集中在两处且相互咬合**：① 多窗口（Tauri 更强，小规模可补）；② 打包 + 通知（同一套 Windows 身份 / 安装方案）。开发环境本身不重。需要注意的是，Tauri 的项目级 release 分发同样尚未实测；区别在于 Tauri 工具链路径更成型，Flutter 需要补更多安装与应用身份工程。
- **决定性产品判断**：重心是否在“字幕审看 / 时间轴 / 波形 / 叠字”这个重编辑器未来。是 → Flutter 优势明显；否 → 收紧的 WebView 已足够。
- **Python JSON-RPC sidecar** 作为共享后端边界继续保留，与前端选择正交。
- **Tauri** 可在后期转为维护台 / fallback，但“双前端”是可选兜底、非目标，避免过早承担两套维护成本。

这不是“推翻已有工程”，而是在设计约束成型、且现有实现本就待重做的前提下修正技术路线，让每种技术回到它擅长的位置——并用一次目标明确的 spike 把剩余风险一次性戳穿。
