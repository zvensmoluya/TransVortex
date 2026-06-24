# TransVortex 前端图片资源生成记录

本文档记录当前首屏原型的无背景 PNG 资源制造方法。

目标不是追求一次生成最终美术，而是建立一条稳定链路：

1. 先生成候选资源。
2. 验证它是否真的有透明通道。
3. 只把通过验证的资源放进原型。
4. 失败样本保留在 `output/imagegen/` 里用于对照，不直接进入 `docs/FRONTEND/prototypes/.../assets/`。

## 1. 当前结论

我们确实能生成真正无背景的资源。

已验证成功样本：

- `output/imagegen/main-screen-v1-batch/assistant.png`
- `output/imagegen/main-screen-v1-batch/sticky-note.png`

它们的文件格式是 `Format32bppArgb`，四角和边缘 alpha 都是 `0`，可以作为真正透明物件叠放。

已验证失败样本：

- `docs/FRONTEND/prototypes/main-screen-v1/assets/*.png`
- `output/imagegen/main-screen-v1-batch/source-envelope.png`
- `output/imagegen/transparent-tests/*.png`

这些文件大多是 `Format24bppRgb`，没有 alpha 通道，边缘 alpha 是 `255`。它们会被迫表现成矩形插画，不能作为工作桌物件直接使用。

## 2. 当前阻塞与复试结果

2026-06-23 的 live 试验中，`zven-imagegen` 端点返回：

```text
503 No available compatible accounts
```

流式和非流式调用都出现同样错误。

这说明本轮无法继续通过 live 调用验证新提示词，不代表透明参数或本地 wrapper 失效。端点恢复后应直接复用本文档的命令继续试验。

随后端点恢复，可正常返回图片，但透明输出仍不稳定：

- `output/imagegen/transparent-method-tests/single-sticker-transparent-retry.png`
  - 请求：`--size 1024x1024 --background transparent --output-format png`
  - 实际：`1536x1024`，`Format24bppRgb`，边缘 alpha 为 `255`
- `output/imagegen/transparent-method-tests/sticky-note-success-shape-retry.png`
  - 请求：流式，沿用之前成功的 sticky-note 提示词形态
  - 实际：`1254x1254`，`Format24bppRgb`，边缘 alpha 为 `255`
- `output/imagegen/transparent-method-tests/sticky-note-success-shape-retry-nostream.png`
  - 请求：非流式，沿用同一提示词
  - 实际：`1402x1122`，`Format24bppRgb`，边缘 alpha 为 `255`

因此当前判断是：端点已经恢复，但它背后的生成路径不稳定遵守 `background=transparent` 和 `size` 参数。透明成功不只取决于 prompt，也取决于实际被路由到的后端能力。每次生成后必须做 alpha 验证，不能把命令成功等同于资源成功。

2026-06-23 继续指定模型探测：

- `--model gpt-image-1.5`
  - 流式与非流式都返回 `503 No available compatible accounts`
- `--model gpt-image-1`
  - 返回 `503 No available compatible accounts`
- `--model gpt-image-1-mini`
  - 返回 `503 No available compatible accounts`
- `--model gpt-image-2`
  - 探测请求超时；此前默认 `gpt-image-2` 可返回图片，但不稳定遵守透明背景参数

所以当前 zven 端点虽然接受 `--model` 参数，但可用账号池没有稳定提供支持原生透明的模型。继续指定这些别名不能解决透明资源生产问题，除非端点侧确认模型路由和账号可用性。

## 3. 生成原则

图片资源只用于核心世界对象：

- 少女助手。
- 片源投递盒。
- 片源封套。
- 制作便签。
- 识别小机。
- 翻译小机。
- 交付包。
- 修理贴。

不要生成普通按钮、输入框、表格、导航、长文本容器。

提示词必须同时约束：

- `Transparent background PNG asset`
- `isolated object only`
- `no background panel`
- `no room`
- `no table`
- `no text`
- `no letters`
- `no logo`
- `crisp cutout silhouette`
- `transparent around the object`

如果资源需要承载 HTML 文本，只让图片提供纸张、胶带、夹子、标签等材质，不让模型生成文字。

## 4. 推荐单张生成命令

PowerShell 示例：

```powershell
$env:PYTHONIOENCODING = "utf-8"
$Imagegen = "$env:USERPROFILE\.codex\skills\zven-imagegen\scripts\invoke_imagegen.py"

python $Imagegen generate `
  --prompt "Transparent background PNG asset, isolated object only, no background panel, no room, no table, no text, no letters, no logo. A hand-drawn production memo sticky note sheet for a personal subtitle workflow, blank note paper with light tape and small clip, enough empty space for real HTML text to be placed on top, warm white paper, subtle strawberry pink border, soda blue tape, pudding yellow tab, cute anime stationery style, flat front-facing object, crisp cutout silhouette, transparent around the object." `
  --size 1024x1024 `
  --quality medium `
  --background transparent `
  --output-format png `
  --partial-images 1 `
  --out output\imagegen\main-screen-v2-assets\sticky-note.png `
  --force
```

如果流式调用失败，但不是账号/服务侧错误，可以再试非流式：

```powershell
python $Imagegen generate `
  --prompt "Transparent background PNG asset, isolated object only, no background panel, no room, no table, no text, no letters, no logo. A hand-drawn production memo sticky note sheet for a personal subtitle workflow, blank note paper with light tape and small clip, enough empty space for real HTML text to be placed on top, warm white paper, subtle strawberry pink border, soda blue tape, pudding yellow tab, cute anime stationery style, flat front-facing object, crisp cutout silhouette, transparent around the object." `
  --size 1024x1024 `
  --quality medium `
  --background transparent `
  --output-format png `
  --no-stream `
  --out output\imagegen\main-screen-v2-assets\sticky-note-nostream.png `
  --force
```

## 5. 推荐批量输入

批量 JSONL 仍可使用，但每行必须显式写入透明相关字段，不依赖默认值。

```jsonl
{"out":"output/imagegen/main-screen-v2-assets/assistant.png","size":"1024x1024","quality":"medium","background":"transparent","output_format":"png","partial_images":1,"prompt":"Transparent background PNG asset, isolated object only, no background panel, no room, no table, no text, no letters, no logo. A friendly anime-style young female assistant for a personal subtitle translation studio, waist-up pose, warm and helpful expression, small headphones, hair clip, light apron over casual jacket, holding a few blank subtitle paper strips and subtly gesturing toward the center, cute hand-drawn Japanese doujin workspace feeling, clean line art, soft pastel colors, strawberry pink, soda blue, pudding yellow accents, crisp cutout silhouette, transparent around the object."}
{"out":"output/imagegen/main-screen-v2-assets/sticky-note.png","size":"1024x1024","quality":"medium","background":"transparent","output_format":"png","partial_images":1,"prompt":"Transparent background PNG asset, isolated object only, no background panel, no room, no table, no text, no letters, no logo. A hand-drawn production memo sticky note sheet for a personal subtitle workflow, blank note paper with light tape and small clip, enough empty space for real HTML text to be placed on top, warm white paper, subtle strawberry pink border, soda blue tape, pudding yellow tab, cute anime stationery style, flat front-facing object, crisp cutout silhouette, transparent around the object."}
```

运行：

```powershell
$env:PYTHONIOENCODING = "utf-8"
$Imagegen = "$env:USERPROFILE\.codex\skills\zven-imagegen\scripts\invoke_imagegen.py"

python $Imagegen generate-batch `
  --input output\imagegen\main-screen-v2-prompts.jsonl `
  --out-dir output\imagegen\main-screen-v2-assets `
  --force
```

## 6. 透明验证命令

生成后必须验证，不用肉眼判断。

PowerShell：

```powershell
Add-Type -AssemblyName System.Drawing
$files = Get-ChildItem -LiteralPath output\imagegen\main-screen-v2-assets -Filter *.png
$rows = @()

foreach ($file in $files) {
  $bmp = [System.Drawing.Bitmap]::FromFile($file.FullName)
  $right = $bmp.Width - 1
  $bottom = $bmp.Height - 1
  $midX = [int]($bmp.Width / 2)
  $midY = [int]($bmp.Height / 2)
  $alphas = @(
    $bmp.GetPixel(0, 0).A,
    $bmp.GetPixel($right, 0).A,
    $bmp.GetPixel(0, $bottom).A,
    $bmp.GetPixel($right, $bottom).A,
    $bmp.GetPixel($midX, 0).A,
    $bmp.GetPixel(0, $midY).A
  )
  $rows += [pscustomobject]@{
    Name = $file.Name
    PixelFormat = $bmp.PixelFormat.ToString()
    EdgeAlpha = ($alphas -join ",")
  }
  $bmp.Dispose()
}

$rows | Format-Table -AutoSize
```

通过标准：

- `PixelFormat` 必须是 `Format32bppArgb` 或同等带 alpha 的格式。
- `EdgeAlpha` 应该全部或大部分为 `0`。
- 如果是 `Format24bppRgb`，直接判定为失败资源。
- 如果边缘 alpha 是 `255`，即使文件扩展名是 PNG，也不能作为无背景物件使用。

## 7. 进入原型前的处理规则

通过验证后，才能复制到：

```text
docs/FRONTEND/prototypes/main-screen-v1/assets/
```

复制前保留原始输出路径和 prompt 记录。

进入原型后，CSS 不应该再把这些资源作为矩形背景裁切：

- 不要对透明物件使用 `object-fit: cover`。
- 不要用大圆角裁切透明物件。
- 不要用半透明白底覆盖整张图片来“修背景”。
- 应优先用 `img` 以 `object-fit: contain` 叠放。
- 阴影应该服务物件轮廓，而不是制造矩形卡片。

如果资源必须裁成矩形才能看起来正常，说明它不是合格的透明物件资源，应回到生成阶段。

## 8. 伪透明棋盘格后处理

部分模型不会返回真正 alpha，而是把“透明背景”画成棋盘格。这个结果不是合格资源，但如果棋盘格规则、主体边缘清楚，可以通过后处理转换为真实透明 PNG。

已验证样本：

- 输入：`output/imagegen/transparent-method-tests/sticky-note-success-shape-retry.png`
  - 原始：`Format24bppRgb`，边缘 alpha 为 `255`
  - 后处理输出：`output/imagegen/transparent-method-tests/extracted/sticky-note-alpha.png`
  - 验证：`Format32bppArgb`，边缘 alpha 为 `0`
- 输入：`output/imagegen/transparent-method-tests/single-sticker-transparent-retry.png`
  - 原始：`Format24bppRgb`，边缘 alpha 为 `255`
  - 后处理输出：`output/imagegen/transparent-method-tests/extracted/single-sticker-alpha.png`
  - 验证：`Format32bppArgb`，边缘 alpha 为 `0`

脚本：

```text
scripts/extract_checkerboard_alpha.py
```

运行示例：

```powershell
.\.venv\Scripts\python.exe scripts\extract_checkerboard_alpha.py `
  --input output\imagegen\transparent-method-tests\sticky-note-success-shape-retry.png `
  --out output\imagegen\transparent-method-tests\extracted\sticky-note-alpha.png
```

依赖：

```powershell
.\.venv\Scripts\python.exe -m pip install pillow
```

算法边界：

- 适合规则浅灰/白棋盘格背景。
- 适合纸张、贴纸、封套、便签这类边缘明确的物件。
- 脚本只删除与图片边界连通的背景色，避免误删主体内部浅色区域。
- 不适合头发、烟雾、玻璃、半透明材质、强阴影、复杂渐变背景。
- 如果主体边缘混入大量棋盘格颜色，可能出现毛边或误删，需要重新生成或改用纯色 chroma-key 流程。

后处理后仍必须运行第 6 节的 alpha 验证命令。必要时再把结果合成到纯色背景上肉眼检查边缘：

```powershell
@'
from pathlib import Path
from PIL import Image

src = Path("output/imagegen/transparent-method-tests/extracted/sticky-note-alpha.png")
out = src.with_name(src.stem + "-preview.png")
img = Image.open(src).convert("RGBA")
bg = Image.new("RGBA", img.size, (255, 214, 230, 255))
bg.alpha_composite(img)
bg.save(out)
print(out)
'@ | .\.venv\Scripts\python.exe -
```
