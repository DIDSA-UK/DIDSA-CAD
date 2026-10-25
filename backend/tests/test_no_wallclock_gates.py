"""Guard: no test may gate on elapsed time. A wall-clock ceiling fails whenever the CI runner is slow, which is a false positive (see tests/timing.py);
use `check_timing`, which reports and enforces only with DIDSA_ENFORCE_TIMING=1."""

import re
from pathlib import Path

_GATE = re.compile(r"\bassert\b[^\n]*\b(elapsed|latency|duration|seconds_taken|wall_?clock)\w*\s*<|\bassert\b[^\n]*\bmin\(times\)|\bassert\b[^\n]*time\.(perf_counter|monotonic|process_time)\(\)[^\n]*<")


def test_no_test_asserts_on_elapsed_time():
    offenders = []
    for path in sorted(Path(__file__).parent.glob("test_*.py")):
        if path.name == Path(__file__).name:
            continue
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if _GATE.search(line):
                offenders.append(f"{path.name}:{number}: {line.strip()}")
    assert not offenders, "wall-clock gates (use tests.timing.check_timing):\n" + "\n".join(offenders)
