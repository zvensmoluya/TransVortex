# TransVortex 前端生图提示构造指南

本文档定义 TransVortex 前端视觉探索和辅助资产的生图边界、硬约束和提示构造方法。

它不是固定 prompt 集合。不要机械复制本文档里的示例，也不要把示例当成唯一正确的视觉方向。Agent 应根据具体任务生成新的 prompt，只继承项目语义和禁用项。

生图只用于辅助设计探索和非核心视觉资产，不用于替代真实前端实现。

## 1. 使用入口

本项目使用 `$zven-imagegen` skill 进行生图：

```text
C:\Users\Administrator\.codex\skills\zven-imagegen\SKILL.md
```

优先使用该 skill 的 PowerShell wrapper：

```powershell
powershell -ExecutionPolicy Bypass -File "$HOME\.agents\skills\zven-imagegen\scripts\invoke-imagegen.ps1" generate `
  --prompt "<prompt>" `
  --size 1536x1024 `
  --quality medium `
  --partial-images 1 `
  --out output\imagegen\<name>.png
```

本项目的最终生图资产默认保存到：

```text
output/imagegen/
```

临时批量提示文件可以放在：

```text
tmp/imagegen/
```

## 2. 使用边界

`zven-imagegen` 的凭据解析、base URL、wrapper 行为以 skill 自身说明为准，本文档不重复维护工具用法。

前端文档只规定项目侧边界：

- 生图只用于视觉探索和辅助资产，不替代真实前端实现。
- 不在聊天、文档、日志或 commit message 中记录真实 imagegen 凭据。
- 不把 imagegen 凭据写入 provider YAML。
- 生图输出如果要进入项目，应保存到明确的项目路径，并说明用途。

## 3. 适用范围

适合使用生图：

- 前端视觉方向探索。
- 低光字幕工作台氛围图。
- 空状态插图。
- 文档配图。
- 任务完成页局部视觉。
- 术语表、服务连接、输出文件区的概念图。

不适合使用生图：

- 核心 UI 控件。
- 图标系统。
- 字幕列表。
- 任务详情真实界面。
- 结果检查真实交互界面。
- 可交互界面截图作为最终实现依据。
- 任何需要准确文字、真实数据、可访问性或稳定布局的内容。

核心界面必须用 React、CSS、真实组件和真实状态实现。

## 4. 提示构造原则

生图 prompt 应该约束产品语义和风格禁区，不要过早锁死构图、控件和页面细节。

应该固定：

- 产品是什么：本地字幕生产工作台。
- 气质是什么：安静、专业、低光、可检查、可恢复。
- 禁止什么：表情 UI、赛博风、霓虹、多颜色渐变、说明书式文字。
- 生图用途是什么：视觉探索、空状态、文档配图或辅助资产。

不应该过早固定：

- 每个面板的精确位置。
- 所有页面都必须同一个构图。
- 具体控件长什么样。
- 具体文案或假 UI 文本。
- 唯一的材质、光源和插图隐喻。

换句话说，prompt 应该给模型“方向边界”，不要提前替模型完成全部设计。

## 5. 必须继承的硬约束

所有 TransVortex 前端生图 prompt 都必须包含或等价表达这些禁用项：

```text
Avoid: emoji UI, cyberpunk, neon, hacker aesthetic, rainbow gradients, purple-blue neon gradients, glowing text, glassmorphism, heavy blur, marketing hero layout, decorative blobs, mascot, stock-photo vibe, explanatory text blocks, code comments, fake detailed UI text, watermark.
```

也要避免：

- 把生图做成真实可交互 UI 截图。
- 生成看似真实但不可控的 UI 文案。
- 使用任何 API key、token 或真实服务信息。
- 用大段说明文字代替视觉设计。

## 6. 可选提示片段

下面是可组合片段，不是完整 prompt。

### 产品语义

```text
Product: TransVortex, a local desktop subtitle production workbench.
```

```text
Purpose: help subtitle producers create tasks, monitor progress, review subtitle quality, manage terminology, and re-export subtitle files.
```

### 气质和风格

```text
Mood: quiet, professional, focused, low-pressure, suitable for long work sessions.
```

```text
Style: restrained desktop software direction, matte surfaces, readable hierarchy, compact but not crowded.
```

### 色彩方向

```text
Color direction: warm dark graphite base, muted gray panels, limited amber and teal status accents, restrained red only for blocking issues.
```

### 核心视觉对象

按任务选择少量对象，不要全部塞进一个 prompt：

```text
Visual elements: subtitle segment strips, timeline overview, quality status marks, service connection indicators, output file tray, organized terminology cards.
```

### 文字约束

```text
Text: no readable UI text; use abstract short labels only if unavoidable.
```

### 禁止项

```text
Avoid: emoji UI, cyberpunk, neon, rainbow gradients, glowing text, glassmorphism, marketing hero layout, explanatory text blocks, code comments, fake detailed UI text, watermark.
```

## 7. 开放式示例

这些示例只演示如何组织 prompt。实际使用时应根据任务重写。

### 整体视觉探索

```text
Use case: ui-mockup
Asset type: visual direction exploration
Product: TransVortex, a local desktop subtitle production workbench
Primary request: explore a quiet low-light desktop workbench feeling for subtitle production
Mood: professional, focused, readable, suitable for long work sessions
Style: restrained desktop software direction, matte surfaces, compact information hierarchy
Visual elements: subtitle segment strips, timeline overview, quality status marks, output file area
Text: no readable UI text; use abstract short labels only if unavoidable
Avoid: emoji UI, cyberpunk, neon, hacker aesthetic, rainbow gradients, purple-blue neon gradients, glowing text, glassmorphism, heavy blur, marketing hero layout, decorative blobs, mascot, stock-photo vibe, explanatory text blocks, code comments, fake detailed UI text, watermark
```

### 空状态或文档配图

```text
Use case: stylized-concept
Asset type: empty state or documentation image
Product: TransVortex, a local desktop subtitle production workbench
Primary request: create a restrained visual metaphor for organizing subtitle project assets
Mood: calm, organized, trustworthy
Style: quiet editorial illustration with matte dark surfaces and soft warm work light
Visual elements: subtitle segment cards, project folder tabs, small status marks, output tray
Text: no readable text
Avoid: emoji UI, mascot, sticky-note clutter, cyberpunk, neon, colorful gradients, glassmorphism, explanatory text, watermark
```

### 服务连接概念

```text
Use case: stylized-concept
Asset type: service connection concept image
Product: TransVortex, a local desktop subtitle production workbench
Primary request: explore a calm visual metaphor for connecting translation and speech recognition services
Mood: secure, clear, professional, not technical-overwhelming
Style: matte dark interface concept with subtle status indicators
Visual elements: separated service groups, restrained connection indicators, key status hint, model blocks
Text: no readable text; no exposed credentials
Avoid: network hacker aesthetic, cyberpunk, neon cables, glowing server racks, emoji UI, rainbow gradients, exposed API key text, watermark
```

## 8. 命令示例

生成一次视觉探索：

```powershell
powershell -ExecutionPolicy Bypass -File "$HOME\.agents\skills\zven-imagegen\scripts\invoke-imagegen.ps1" generate `
  --prompt "<task-specific prompt>" `
  --size 1536x1024 `
  --quality medium `
  --partial-images 1 `
  --out output\imagegen\transvortex-visual-exploration.png
```

只检查命令和环境，不发起网络请求：

```powershell
powershell -ExecutionPolicy Bypass -File "$HOME\.agents\skills\zven-imagegen\scripts\invoke-imagegen.ps1" generate `
  --prompt "TransVortex frontend imagegen dry run" `
  --out output\imagegen\dry-run.png `
  --dry-run
```

## 9. 验收标准

生成结果必须满足：

- 没有表情 UI。
- 没有赛博风、霓虹风、黑客风。
- 没有多颜色渐变、紫蓝霓虹渐变或发光字效。
- 没有营销页式 hero。
- 没有说明书式大段文字。
- 没有看似真实但不可控的 UI 文案。
- 没有 API key、token 或真实服务信息。
- 能强化“低光字幕制作工作台”的方向。
- 能服务前端设计判断，而不是替代真实前端实现。
