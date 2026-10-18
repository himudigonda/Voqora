from __future__ import annotations

import math
import time
from collections.abc import Callable


class TokenBucket:
    def __init__(
        self,
        capacity: int,
        refill_per_second: float,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        if capacity < 1 or refill_per_second <= 0:
            raise ValueError("capacity and refill rate must be positive")
        self._capacity = float(capacity)
        self._refill_per_second = refill_per_second
        self._clock = clock
        self._tokens = float(capacity)
        self._updated = clock()

    def try_acquire(self) -> bool:
        self._refill()
        if self._tokens < 1.0:
            return False
        self._tokens -= 1.0
        return True

    def retry_after_seconds(self) -> int:
        self._refill()
        missing = max(0.0, 1.0 - self._tokens)
        return max(1, math.ceil(missing / self._refill_per_second))

    def _refill(self) -> None:
        now = self._clock()
        elapsed = max(0.0, now - self._updated)
        self._tokens = min(
            self._capacity, self._tokens + elapsed * self._refill_per_second
        )
        self._updated = now
