from __future__ import annotations

from abc import ABC, abstractmethod


class ProviderClient(ABC):
    @abstractmethod
    def translate_batch(self, lines: list[str], source_lang: str, target_lang: str, model: str) -> list[str]:
        raise NotImplementedError
