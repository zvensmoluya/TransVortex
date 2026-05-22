# TransVortex Imagegen Guide

这个仓库里，图片生成只负责**位图插画**，不负责 UI 图标、按钮符号或密集信息图。
稳定入口是仓库脚本 `scripts/imagegen_stream.py`；`zven-imagegen` 只是本机 Codex 里的可选快捷入口。
上游协作者不需要安装你的本地 skill，也可以按下面的资产约定，用别的图像工具手动生成同类素材。

## 适合用它做什么

- 首次打开页的主视觉或空状态图
- 任务/方案卡片封面
- 导出成功、预检通过、无任务、无结果这类状态图
- 轻量的品牌插画
- 报告封面

## 不适合用它做什么

- 按钮、标签、状态徽标
- 表格、时间轴、编辑器控件
- 代码驱动更合适的 UI 图形
- 需要精确线条和可交互语义的 SVG 结构图

## 这个项目的视觉语言

TransVortex 的画面应该像一个安静的本地字幕工作台：

- 有任务感，但不做营销页
- 有模型、时间线、文件、检查、导出这些元素
- 颜色克制，偏深青绿、灰白、少量琥珀色
- 构图清楚，信息层次比装饰更重要
- 画面要让人一眼知道“这是在处理字幕工作流”

## 推荐的资产清单

建议先做这些：

- `first-open-hero`
- `empty-state-no-task`
- `empty-state-no-result`
- `preset-card-quick`
- `preset-card-stable`
- `preset-card-high-quality`
- `export-cover`

建议输出到 `output/imagegen/`。

## 稳定入口

安装可选依赖：

```powershell
python -m pip install -e ".[imagegen]"
```

使用仓库内流式脚本：

```powershell
.\.venv\Scripts\python scripts\imagegen_stream.py generate `
  --prompt "TransVortex desktop first-open empty state illustration, quiet local subtitle workstation, video file, subtitle timeline, model cards, clean flat geometric style, no text, no logo" `
  --size 1024x1024 `
  --quality low `
  --out output\imagegen\first-open-hero.png `
  --force
```

默认使用流式请求，并请求 1 张中间图：

- `--partial-images 1`：让长连接中途有事件返回，降低被中间代理断开的概率
- `--partial-images 0`：只流最终图，进度反馈较少
- `--no-stream`：退回普通同步请求，主要用于排查兼容问题

本地 Codex 可以继续用 `zven-imagegen`，但它不再承担核心能力；如果系统 skill 被 Codex 更新覆盖，仓库脚本仍然在。

## Prompt 写法

把 prompt 写成四段会更稳：

1. 用途
2. 画面内容
3. 视觉风格
4. 禁止项

示例：

```text
用途：TransVortex 桌面端首次打开页空状态插画。
画面内容：一个安静的本地字幕工作台，包含视频文件、字幕时间线、模型方案卡、检查通过标记。
视觉风格：扁平、干净、几何化、低细节、专业、克制。
禁止项：不要文字、不要照片、不要渐变光球、不要卡通人物、不要品牌 logo、不要复杂纹理。
```

## 运行时约定

- 最终文件放在 `output/imagegen/`
- 临时批处理 JSONL 放在 `tmp/imagegen/`
- 本地图片生成配置优先用 `.agentonlyenv`、`.imagegen.env` 或 `.env.imagegen`
- 不要把真实 key 写进仓库
- `.imagegen.env.example` 只保留占位模板，不包含真实配置

## 和 SVG 的分工

如果是按钮、图标、状态符号、流程小图，优先继续用 SVG 或代码绘制。
如果是空状态、封面、主视觉、产品插画，才用 `zven-imagegen`。
