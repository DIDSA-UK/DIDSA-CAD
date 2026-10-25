"""Timing is reported by the suite, never a pass / fail gate on a shared CI runner.

A wall-clock ceiling on a test fails whenever the machine is slow (a cold runner, a busy neighbour, another architecture) and says nothing about
the code: those failures were reruns of the same commit passing. `check_timing` always prints the measurement and enforces the ceiling only when
`DIDSA_ENFORCE_TIMING=1` (a developer's own machine, a benchmark job). What a test is really about is asserted by its other, deterministic lines."""

import os


def check_timing(measured: float, ceiling: float, label: str, unit: str = "s") -> None:
    print(f"\nTIMING {label}: {measured:.3f} {unit} (ceiling {ceiling} {unit}, {'enforced' if enforced() else 'reported only'})")
    if enforced():
        assert measured < ceiling, f"{label}: {measured:.3f} {unit} is over the {ceiling} {unit} ceiling"


def enforced() -> bool:
    return os.environ.get("DIDSA_ENFORCE_TIMING") == "1"
