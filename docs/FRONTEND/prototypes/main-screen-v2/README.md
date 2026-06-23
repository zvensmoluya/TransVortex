# TransVortex Main Screen Prototype V2

本目录用于修正 `main-screen-v1` 的素材问题。

V1 已经验证了首屏方向的大致形状，但素材没有通过验收：

- 请求了透明背景，实际 PNG 没有 alpha 通道。
- 素材带有暗色渐变背景，不能作为可组合 UI 物件。
- 部分提示词把“物件素材”引向了“场景插画”。
- 缺少生成后的自动检查，失败素材直接进入了原型。

V2 先解决素材生产流程，不直接进入 React/Tauri 实现。

## 目标

- 每个核心物件都是真正可叠加的透明 PNG。
- 素材是 isolated cutout asset，不是带背景的场景图。
- 生成后必须检查 alpha 通道和透明边角。
- 先单张试跑，通过后再批量生成。

## 生图命令

先单张测试：

```powershell
python C:\Users\admin\.codex\skills\zven-imagegen\scripts\invoke_imagegen.py generate `
  --model gpt-image-2 `
  --prompt-file docs\FRONTEND\prototypes\main-screen-v2\prompts\sticky-note.txt `
  --size 1024x1024 `
  --quality medium `
  --background transparent `
  --output-format png `
  --partial-images 1 `
  --out docs\FRONTEND\prototypes\main-screen-v2\assets\sticky-note.png `
  --force
```

批量生成：

```powershell
python C:\Users\admin\.codex\skills\zven-imagegen\scripts\invoke_imagegen.py generate-batch `
  --input docs\FRONTEND\prototypes\main-screen-v2\prompts.jsonl `
  --fail-fast
```

验收：

```powershell
python docs\FRONTEND\prototypes\main-screen-v2\check_assets.py docs\FRONTEND\prototypes\main-screen-v2\assets
```

## 当前生图环境观察

2026-06-21 测试时，`zven-imagegen` wrapper 可以正确传递：

- `--background transparent`
- `--output-format png`
- `generate-batch` 中每行的 `background`

但连续两次调用当前 image endpoint 返回 Cloudflare `502 Bad gateway`，没有成功生成新素材。

这说明当前阻塞不是本地命令参数，而是上游生图服务暂时不可用。服务恢复后，应先跑单张测试并执行 `check_assets.py`，确认真的有 alpha 通道，再批量生成。

