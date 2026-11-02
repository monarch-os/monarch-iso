"""Fine-grained elapsed times in the existing installation log."""

import time
from contextlib import contextmanager


@contextmanager
def timed(label: str):
    started = time.monotonic()
    status = 'failed'
    try:
        yield
        status = 'ok'
    finally:
        print(f'TIMING {label}: {time.monotonic() - started:.3f}s ({status})', flush=True)
