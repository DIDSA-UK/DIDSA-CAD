"""Pitch profiles for helices whose pitch varies smoothly - pure math, no OCCT, so it is testable on
its own. `app.document.curve` turns the samples into a wire (a variable-pitch Helix) and
`app.document.spring` uses the same for a Spring's centreline.

A helix's centreline is sampled as `(t, z)` pairs: `t` the turns travelled from the start (the angle
is `2 pi t`), `z` the height along the axis. The pitch is the axis advance per turn, `dz/dt`. Two
ways to say it:
- `pitch_at_height`: the pitch at axial distances from the start (a variable-pitch Helix, bug report:
  "state pitch at different lengths and pitch varies smoothly between values"), joined by a
  monotone cubic (PCHIP, Fritsch-Carlson), so the pitch never overshoots the values given and never
  reaches zero between two positive ones;
- `pitch_at_turn`: the pitch as a function of turns (a Spring's dead coils and smooth transitions).
Both are integrated with RK4 at `SAMPLES_PER_TURN` steps per turn, the samples a wire is then
interpolated through.
"""

from collections.abc import Callable
from dataclasses import dataclass

# Interpolation points per turn: a C2 cubic through 32 points a turn stays within about 1e-6 of
# the radius of a true helix (checked against OCCT's own helix builder in the tests).
SAMPLES_PER_TURN = 32


@dataclass(frozen=True)
class HelixSample:
    t: float
    z: float


def pchip(xs: list[float], ys: list[float]) -> Callable[[float], float]:
    """A monotone, C1 cubic through `(xs, ys)` (`xs` strictly increasing): Fritsch-Carlson slopes,
    so between two values it never leaves their range. Constant outside `xs`. Two points give the
    straight line."""
    n = len(xs)
    if n == 1:
        return lambda _x: ys[0]
    h = [xs[i + 1] - xs[i] for i in range(n - 1)]
    delta = [(ys[i + 1] - ys[i]) / h[i] for i in range(n - 1)]
    slopes = [0.0] * n
    if n == 2:
        slopes = [delta[0], delta[0]]
    else:
        for i in range(1, n - 1):
            if delta[i - 1] * delta[i] <= 0.0:
                slopes[i] = 0.0
            else:
                w1 = 2.0 * h[i] + h[i - 1]
                w2 = h[i] + 2.0 * h[i - 1]
                slopes[i] = (w1 + w2) / (w1 / delta[i - 1] + w2 / delta[i])
        slopes[0] = _pchip_end_slope(h[0], h[1], delta[0], delta[1])
        slopes[-1] = _pchip_end_slope(h[-1], h[-2], delta[-1], delta[-2])

    def value(x: float) -> float:
        if x <= xs[0]:
            return ys[0]
        if x >= xs[-1]:
            return ys[-1]
        i = max(k for k in range(n - 1) if xs[k] <= x)
        s = (x - xs[i]) / h[i]
        h00 = (1 + 2 * s) * (1 - s) ** 2
        h10 = s * (1 - s) ** 2
        h01 = s * s * (3 - 2 * s)
        h11 = s * s * (s - 1)
        return h00 * ys[i] + h10 * h[i] * slopes[i] + h01 * ys[i + 1] + h11 * h[i] * slopes[i + 1]

    return value


def _pchip_end_slope(h0: float, h1: float, d0: float, d1: float) -> float:
    slope = ((2 * h0 + h1) * d0 - h0 * d1) / (h0 + h1)
    if slope * d0 <= 0.0:
        return 0.0
    if d0 * d1 <= 0.0 and abs(slope) > abs(3 * d0):
        return 3 * d0
    return slope


def _rk4_step(rate: Callable[[float, float], float], t: float, z: float, dt: float) -> float:
    k1 = rate(t, z)
    k2 = rate(t + dt / 2, z + dt * k1 / 2)
    k3 = rate(t + dt / 2, z + dt * k2 / 2)
    k4 = rate(t + dt, z + dt * k3)
    return z + dt * (k1 + 2 * k2 + 2 * k3 + k4) / 6


def samples_to_height(pitch_of: Callable[[float, float], float], height: float) -> list[HelixSample]:
    """Samples from `z = 0` up to `z = height` (> 0) where `dz/dt = pitch_of(t, z)` (> 0): every
    1 / `SAMPLES_PER_TURN` turn, the last one landing exactly on `height` (its `t` is the turns)."""
    dt = 1.0 / SAMPLES_PER_TURN
    samples = [HelixSample(0.0, 0.0)]
    t, z = 0.0, 0.0
    while True:
        z_next = _rk4_step(pitch_of, t, z, dt)
        if z_next >= height - 1e-12:
            break
        t, z = t + dt, z_next
        samples.append(HelixSample(t, z))
    # The part step that lands on `height`: bisect its length (z rises monotonically with it).
    low, high = 0.0, dt
    for _ in range(60):
        mid = (low + high) / 2
        if _rk4_step(pitch_of, t, z, mid) < height:
            low = mid
        else:
            high = mid
    last = HelixSample(t + high, height)
    if last.t - samples[-1].t < dt * 1e-3 and len(samples) > 1:
        samples[-1] = last  # a sliver step would make the interpolation wobble: move the last sample
    else:
        samples.append(last)
    return samples


def samples_to_turns(pitch_of_turn: Callable[[float], float], turns: float) -> list[HelixSample]:
    """Samples from `t = 0` to `t = turns` where `dz/dt = pitch_of_turn(t)`: every 1 /
    `SAMPLES_PER_TURN` turn (and the end exactly). Each step is integrated in 4 sub-steps so a
    pitch that changes within a step (a Spring's transition) is still followed closely."""
    steps = max(1, round(turns * SAMPLES_PER_TURN))
    dt = turns / steps
    samples = [HelixSample(0.0, 0.0)]
    z = 0.0
    for k in range(steps):
        t = k * dt
        for sub in range(4):
            z = _rk4_step(lambda tt, _z: pitch_of_turn(tt), t + sub * dt / 4, z, dt / 4)
        samples.append(HelixSample((k + 1) * dt, z))
    return samples


def pitch_at_height(at: list[float], pitch: list[float]) -> Callable[[float, float], float]:
    """`dz/dt` for pitches stated at axial distances `at` (from 0, increasing; positive pitches):
    the pitch at the current height, smoothly joined (`pchip`)."""
    curve = pchip(at, pitch)
    return lambda _t, z: curve(z)
