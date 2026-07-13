from __future__ import annotations

from dataclasses import asdict, dataclass, field
from typing import Any


CATALOG_VERIFIED_AT = "2026-07-13"


@dataclass(frozen=True)
class ModelCatalogEntry:
    id: str
    label: str
    vendor: str
    aliases: tuple[str, ...]
    max_context_tokens: int
    max_input_tokens: int
    max_output_tokens: int
    max_batch_lines: int
    recommended_output_tokens: int
    reasoning_effort: str
    reasoning_efforts: tuple[str, ...]
    source_label: str
    source_url: str
    verified_at: str = CATALOG_VERIFIED_AT
    pricing: dict[str, Any] = field(default_factory=dict)

    def payload(self) -> dict[str, Any]:
        row = asdict(self)
        row["aliases"] = list(self.aliases)
        row["reasoning_efforts"] = list(self.reasoning_efforts)
        row["runtime"] = {
            "max_batch_lines": self.max_batch_lines,
            "max_context_tokens": self.max_context_tokens,
            "max_input_tokens": self.max_input_tokens,
            "max_output_tokens": self.max_output_tokens,
            "recommended_output_tokens": self.recommended_output_tokens,
            "reasoning_effort": self.reasoning_effort,
        }
        return row


def _pricing(
    *,
    source_url: str,
    input_per_million_usd: float | None = None,
    output_per_million_usd: float | None = None,
    threshold_input_tokens: int = 0,
    above_threshold_input_per_million_usd: float | None = None,
    above_threshold_output_per_million_usd: float | None = None,
    above_threshold_input_multiplier: float | None = None,
    above_threshold_output_multiplier: float | None = None,
    note: str = "",
) -> dict[str, Any]:
    return {
        "kind": "official_reference",
        "currency": "USD",
        "unit_tokens": 1_000_000,
        "input_per_million_usd": input_per_million_usd,
        "output_per_million_usd": output_per_million_usd,
        "threshold_input_tokens": threshold_input_tokens,
        "above_threshold_input_per_million_usd": above_threshold_input_per_million_usd,
        "above_threshold_output_per_million_usd": above_threshold_output_per_million_usd,
        "above_threshold_input_multiplier": above_threshold_input_multiplier,
        "above_threshold_output_multiplier": above_threshold_output_multiplier,
        "source_url": source_url,
        "note": note,
    }


def _entry(
    *,
    id: str,
    label: str,
    vendor: str,
    aliases: tuple[str, ...] = (),
    max_context_tokens: int,
    max_input_tokens: int,
    max_output_tokens: int,
    max_batch_lines: int = 240,
    recommended_output_tokens: int = 32_768,
    reasoning_effort: str = "",
    reasoning_efforts: tuple[str, ...] = (),
    source_label: str,
    source_url: str,
    pricing: dict[str, Any] | None = None,
) -> ModelCatalogEntry:
    return ModelCatalogEntry(
        id=id,
        label=label,
        vendor=vendor,
        aliases=aliases,
        max_context_tokens=max_context_tokens,
        max_input_tokens=max_input_tokens,
        max_output_tokens=max_output_tokens,
        max_batch_lines=max_batch_lines,
        recommended_output_tokens=min(recommended_output_tokens, max_output_tokens),
        reasoning_effort=reasoning_effort,
        reasoning_efforts=reasoning_efforts,
        source_label=source_label,
        source_url=source_url,
        pricing=pricing or {},
    )


_OPENAI_56_REASONING = ("none", "low", "medium", "high", "xhigh", "max")
_OPENAI_55_REASONING = ("none", "low", "medium", "high", "xhigh")
_OPENAI_LONG_CONTEXT_PRICE = {
    "threshold_input_tokens": 272_000,
    "above_threshold_input_multiplier": 2.0,
    "above_threshold_output_multiplier": 1.5,
}
_ANTHROPIC_PRICING_URL = "https://platform.claude.com/docs/en/about-claude/pricing"
_GOOGLE_PRICING_URL = "https://ai.google.dev/gemini-api/docs/pricing"


MODEL_CATALOG: tuple[ModelCatalogEntry, ...] = (
    *(
        _entry(
            id=model_id,
            label=label,
            vendor="OpenAI",
            aliases=aliases,
            max_context_tokens=1_050_000,
            max_input_tokens=922_000,
            max_output_tokens=128_000,
            reasoning_effort="low",
            reasoning_efforts=reasoning_efforts,
            source_label="OpenAI 官方模型文档",
            source_url=f"https://developers.openai.com/api/docs/models/{model_id}",
            pricing=_pricing(
                source_url=f"https://developers.openai.com/api/docs/models/{model_id}",
                **_OPENAI_LONG_CONTEXT_PRICE,
                note="输入超过 272K tokens 时，整个请求按长上下文倍率计费。",
            ),
        )
        for model_id, label, aliases, reasoning_efforts in (
            (
                "gpt-5.6-sol",
                "GPT-5.6 Sol",
                ("gpt-5.6", "openai/gpt-5.6", "openai/gpt-5.6-sol"),
                _OPENAI_56_REASONING,
            ),
            (
                "gpt-5.6-terra",
                "GPT-5.6 Terra",
                ("openai/gpt-5.6-terra",),
                _OPENAI_56_REASONING,
            ),
            (
                "gpt-5.6-luna",
                "GPT-5.6 Luna",
                ("openai/gpt-5.6-luna",),
                _OPENAI_56_REASONING,
            ),
            (
                "gpt-5.5",
                "GPT-5.5",
                ("gpt-5.5-2026-04-23", "openai/gpt-5.5"),
                _OPENAI_55_REASONING,
            ),
            (
                "gpt-5.4",
                "GPT-5.4",
                ("gpt-5.4-2026-03-05", "openai/gpt-5.4"),
                _OPENAI_55_REASONING,
            ),
        )
    ),
    _entry(
        id="gpt-4.1",
        label="GPT-4.1",
        vendor="OpenAI",
        aliases=("gpt-4.1-2025-04-14", "openai/gpt-4.1"),
        max_context_tokens=1_047_576,
        max_input_tokens=1_014_808,
        max_output_tokens=32_768,
        recommended_output_tokens=16_384,
        reasoning_efforts=(),
        source_label="OpenAI 官方模型文档",
        source_url="https://developers.openai.com/api/docs/models/gpt-4.1",
    ),
    _entry(
        id="claude-fable-5",
        label="Claude Fable 5",
        vendor="Anthropic",
        aliases=("anthropic/claude-fable-5", "anthropic.claude-fable-5"),
        max_context_tokens=1_000_000,
        max_input_tokens=0,
        max_output_tokens=128_000,
        source_label="Anthropic 官方模型文档",
        source_url="https://platform.claude.com/docs/en/about-claude/models/overview",
        pricing=_pricing(
            source_url=_ANTHROPIC_PRICING_URL,
            input_per_million_usd=10,
            output_per_million_usd=50,
        ),
    ),
    _entry(
        id="claude-opus-4-8",
        label="Claude Opus 4.8",
        vendor="Anthropic",
        aliases=(
            "claude-opus-4.8",
            "anthropic/claude-opus-4.8",
            "anthropic/claude-opus-4-8",
            "anthropic.claude-opus-4-8",
        ),
        max_context_tokens=1_000_000,
        max_input_tokens=0,
        max_output_tokens=128_000,
        source_label="Anthropic 官方模型文档",
        source_url="https://platform.claude.com/docs/en/about-claude/models/overview",
        pricing=_pricing(
            source_url=_ANTHROPIC_PRICING_URL,
            input_per_million_usd=5,
            output_per_million_usd=25,
        ),
    ),
    _entry(
        id="claude-sonnet-5",
        label="Claude Sonnet 5",
        vendor="Anthropic",
        aliases=("anthropic/claude-sonnet-5", "anthropic.claude-sonnet-5"),
        max_context_tokens=1_000_000,
        max_input_tokens=0,
        max_output_tokens=128_000,
        source_label="Anthropic 官方模型文档",
        source_url="https://platform.claude.com/docs/en/about-claude/models/overview",
        pricing=_pricing(
            source_url=_ANTHROPIC_PRICING_URL,
            input_per_million_usd=2,
            output_per_million_usd=10,
            note="官方推广价有效至 2026-08-31；之后应重新核对。",
        ),
    ),
    _entry(
        id="claude-sonnet-4-6",
        label="Claude Sonnet 4.6",
        vendor="Anthropic",
        aliases=("claude-sonnet-4.6", "anthropic/claude-sonnet-4.6", "anthropic/claude-sonnet-4-6"),
        max_context_tokens=1_000_000,
        max_input_tokens=0,
        max_output_tokens=128_000,
        source_label="Anthropic 官方模型文档",
        source_url="https://platform.claude.com/docs/en/about-claude/models/overview",
        pricing=_pricing(
            source_url=_ANTHROPIC_PRICING_URL,
            input_per_million_usd=3,
            output_per_million_usd=15,
        ),
    ),
    _entry(
        id="claude-haiku-4-5-20251001",
        label="Claude Haiku 4.5",
        vendor="Anthropic",
        aliases=(
            "claude-haiku-4-5",
            "claude-haiku-4.5",
            "anthropic/claude-haiku-4.5",
            "anthropic/claude-haiku-4-5",
            "anthropic.claude-haiku-4-5-20251001-v1:0",
            "claude-haiku-4-5@20251001",
        ),
        max_context_tokens=200_000,
        max_input_tokens=0,
        max_output_tokens=64_000,
        max_batch_lines=160,
        recommended_output_tokens=16_384,
        source_label="Anthropic 官方模型文档",
        source_url="https://platform.claude.com/docs/en/about-claude/models/overview",
        pricing=_pricing(
            source_url=_ANTHROPIC_PRICING_URL,
            input_per_million_usd=1,
            output_per_million_usd=5,
        ),
    ),
    *(
        _entry(
            id=model_id,
            label=label,
            vendor="Google",
            aliases=(f"models/{model_id}", f"google/{model_id}", f"publishers/google/models/{model_id}"),
            max_context_tokens=1_048_576,
            max_input_tokens=1_048_576,
            max_output_tokens=65_536,
            source_label="Google Gemini 官方模型文档",
            source_url=f"https://ai.google.dev/gemini-api/docs/models/{model_id}",
            pricing=pricing,
        )
        for model_id, label, pricing in (
            (
                "gemini-3.5-flash",
                "Gemini 3.5 Flash",
                _pricing(source_url=_GOOGLE_PRICING_URL, input_per_million_usd=1.5, output_per_million_usd=9),
            ),
            (
                "gemini-3.1-pro-preview",
                "Gemini 3.1 Pro Preview",
                _pricing(
                    source_url=_GOOGLE_PRICING_URL,
                    input_per_million_usd=2,
                    output_per_million_usd=12,
                    threshold_input_tokens=200_000,
                    above_threshold_input_per_million_usd=4,
                    above_threshold_output_per_million_usd=18,
                    note="预览型号的价格和可用性可能调整。",
                ),
            ),
            (
                "gemini-3.1-flash-lite",
                "Gemini 3.1 Flash-Lite",
                _pricing(source_url=_GOOGLE_PRICING_URL, input_per_million_usd=0.25, output_per_million_usd=1.5),
            ),
            (
                "gemini-2.5-pro",
                "Gemini 2.5 Pro",
                _pricing(
                    source_url=_GOOGLE_PRICING_URL,
                    input_per_million_usd=1.25,
                    output_per_million_usd=10,
                    threshold_input_tokens=200_000,
                    above_threshold_input_per_million_usd=2.5,
                    above_threshold_output_per_million_usd=15,
                ),
            ),
            (
                "gemini-2.5-flash",
                "Gemini 2.5 Flash",
                _pricing(source_url=_GOOGLE_PRICING_URL, input_per_million_usd=0.3, output_per_million_usd=2.5),
            ),
            (
                "gemini-2.5-flash-lite",
                "Gemini 2.5 Flash-Lite",
                _pricing(source_url=_GOOGLE_PRICING_URL, input_per_million_usd=0.1, output_per_million_usd=0.4),
            ),
        )
    ),
    *(
        _entry(
            id=model_id,
            label=label,
            vendor="DeepSeek",
            aliases=(f"deepseek/{model_id}",),
            max_context_tokens=1_000_000,
            max_input_tokens=0,
            max_output_tokens=384_000,
            max_batch_lines=240,
            recommended_output_tokens=32_768,
            reasoning_effort="high",
            reasoning_efforts=("high", "max"),
            source_label="DeepSeek 官方模型文档",
            source_url="https://api-docs.deepseek.com/quick_start/pricing",
        )
        for model_id, label in (
            ("deepseek-v4-flash", "DeepSeek V4 Flash"),
            ("deepseek-v4-pro", "DeepSeek V4 Pro"),
        )
    ),
)


def _normalized_model_id(value: str) -> str:
    return str(value or "").strip().lower()


_CATALOG_BY_ALIAS: dict[str, ModelCatalogEntry] = {}
for _catalog_entry in MODEL_CATALOG:
    for _alias in (_catalog_entry.id, *_catalog_entry.aliases):
        _normalized_alias = _normalized_model_id(_alias)
        if _normalized_alias in _CATALOG_BY_ALIAS:
            raise ValueError(f"duplicate model catalog alias: {_alias}")
        _CATALOG_BY_ALIAS[_normalized_alias] = _catalog_entry


def resolve_model_catalog(model_id: str) -> ModelCatalogEntry | None:
    """Resolve only reviewed, exact aliases; variants are never guessed."""

    return _CATALOG_BY_ALIAS.get(_normalized_model_id(model_id))


def model_catalog_runtime_config(model_id: str) -> dict[str, Any]:
    entry = resolve_model_catalog(model_id)
    if entry is None:
        return {}
    return {
        "max_batch_lines": entry.max_batch_lines,
        "max_context_tokens": entry.max_context_tokens,
        "max_input_tokens": entry.max_input_tokens,
        "max_output_tokens": entry.max_output_tokens,
        "recommended_output_tokens": entry.recommended_output_tokens,
        "reasoning_effort": entry.reasoning_effort,
    }


def model_catalog_payload() -> list[dict[str, Any]]:
    return [entry.payload() for entry in MODEL_CATALOG]
