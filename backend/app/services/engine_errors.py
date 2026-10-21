from __future__ import annotations


class UnknownEngineError(ValueError):
    def __init__(self, engine: str) -> None:
        super().__init__(f"Unknown engine: {engine}")
        self.engine = engine


class EngineNotInstalledError(Exception):
    def __init__(self, engine: str) -> None:
        super().__init__(
            f"{engine.capitalize()} is not installed. "
            "Download it in Voqora Settings, then try again."
        )
        self.engine = engine


class EngineBusyError(Exception):
    pass


class EngineInstallError(Exception):
    pass


class EngineWorkerError(Exception):
    pass
