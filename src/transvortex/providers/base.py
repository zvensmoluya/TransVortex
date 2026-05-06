from __future__ import annotations

from abc import ABC, abstractmethod

from ..models import NormalizedRequest, NormalizedResponse


class ProviderClient(ABC):
    @abstractmethod
    def translate_request(self, req: NormalizedRequest) -> NormalizedResponse:
        raise NotImplementedError

    def translate_batch(self, lines: list[str], source_lang: str, target_lang: str, model: str) -> list[str]:
        req = NormalizedRequest(
            model=model,
            lines=lines,
            source_lang=source_lang,
            target_lang=target_lang,
        )
        return self.translate_request(req).numbered_lines
