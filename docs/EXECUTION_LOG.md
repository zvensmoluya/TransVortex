# TransVortex 执行记录（2026-02-13）

## 本次执行目标
- 落地“真实配置接入 + 零 Token 协议预检”方案。

## 已完成
- 配置分层与优先级
  - 新增 `providers.example.yaml`
  - 支持 `providers.local.yaml`（本地私有）
  - `load_app_config()` 优先级：
    1. `--providers-file`
    2. `providers.local.yaml`
    3. `providers.yaml`
    4. `providers.example.yaml`
- 本地私有配置保护
  - `.gitignore` 已加入 `providers.local.yaml`
- VectorEngine 示例配置
  - `providers.yaml` 与 `providers.example.yaml` 已改为：
    - `api_type: anthropic`
    - `compat_mode: anthropic_messages`
    - `base_url: https://api.vectorengine.ai/v1`
    - `model: claude-haiku-4-5-20251001`
    - `endpoint.path_template: /v1/messages`
    - `env_key: VECTORENGINE_API_KEY`
- URL 规范化
  - 新增 URL 拼接去重逻辑，避免 `/v1/v1/messages`
- 新增零 Token 预检命令
  - `transvortex probe-provider`
  - 支持参数：`--provider` `--model` `--providers-file` `--source-lang` `--target-lang` `--strict`
  - 输出 JSON 检查报告（PASS/WARN/FAIL）
  - `--strict` 下有 FAIL 返回退出码 1
- CLI 接线
  - `run/resume/status/probe-provider` 均支持 `--providers-file`
- 测试补充
  - `tests/test_config.py`：配置文件优先级、CLI 显式覆盖
  - `tests/test_provider_factory.py`：`/v1` 去重与 anthropic header 回归
  - `tests/test_probe_provider.py`：预检核心行为覆盖
- 文档更新
  - `docs/CONFIG_GUIDE.md`
  - `docs/运行与测试指南.md`
  - `README.md`

## 运行验证状态
- 语法检查：通过（`src/` 与 `tests/`）
- pytest：当前环境未安装 pytest，未完成自动化执行
  - 报错：`No module named pytest`

## 建议本地验证命令
```powershell
# 1) 设置 key
$env:VECTORENGINE_API_KEY = "你的key"

# 2) 零 Token 预检
transvortex probe-provider --providers-file .\providers.local.yaml --strict

# 3) 单元测试（先安装 pytest）
python -m pip install -e .[test]
python -m pytest -q

# 4) 端到端
transvortex run --providers-file .\providers.local.yaml --input demo.mp4 --src en --tgt zh-CN --bilingual
```
