from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


@dataclass
class ProviderLimits:
    concurrency: int = 8
    timeout_seconds: int = 30
    retry: int = 3


@dataclass
class ProviderConfig:
    name: str
    api_type: str
    base_url: str
    env_key: str
    models: list[str]
    limits: ProviderLimits = field(default_factory=ProviderLimits)


@dataclass
class RouteTarget:
    provider: str
    model: str


@dataclass
class RoutingConfig:
    primary: RouteTarget
    fallback: list[RouteTarget] = field(default_factory=list)


@dataclass
class PipelineConfig:
    artifacts_dir: Path
    chunk_seconds: int = 60
    chunk_overlap_seconds: int = 1
    translation_batch_size: int = 40
    default_concurrency: int = 8
    timeout_seconds: int = 30
    retry: int = 3
    max_cps: int = 20
    asr_model_size: str = "small"
    asr_device: str = "auto"
    asr_compute_type: str = "int8"


@dataclass
class AppConfig:
    pipeline: PipelineConfig
    providers: dict[str, ProviderConfig]
    routing: RoutingConfig


@dataclass
class Segment:
    id: int
    start: float
    end: float
    text_src: str
    text_tgt: str | None = None
    confidence: float | None = None
    meta: dict[str, Any] = field(default_factory=dict)


@dataclass
class Chunk:
    chunk_id: str
    segment_ids: list[int]
    lines: list[str]


@dataclass
class TaskRecord:
    task_id: str
    input_file: str
    source_lang: str
    target_lang: str
    bilingual: bool
    status: str
    created_at: str
    updated_at: str
    output_path: str | None = None
    error: str | None = None
    settings: dict[str, Any] = field(default_factory=dict)
