"""Results for a runs directory laid out as <runs>/<sketch>/<model>-r<n>/ (see ../README.md).

Pass table: P = matches the answer key, F = built the wrong part, V = failed validation, N = no plan,
? = not built. Each run is scored on its latest build: fixed/ (after "Ask the AI to fix it"), else
retry/ (after the automatic validation retry), else the run folder itself.

Check table: how the render-back check's verdict (verdict.json, next to the build it judged) compares with
that build's score - a mismatch on a wrong part is a catch, a mismatch on a right part a false alarm, a
match on a wrong part a miss."""
import json
import os
import sys
from collections import Counter, defaultdict


def _load(path):
    return json.load(open(path)) if os.path.exists(path) else None


def latest_build(run):
    for sub in ("fixed", "retry", ""):
        d = os.path.join(run, sub)
        if os.path.exists(os.path.join(d, "result.json")):
            return d
    return None


def cell(run):
    d = latest_build(run)
    if d is None:
        return "?"
    result, score = _load(os.path.join(d, "result.json")), _load(os.path.join(d, "score.json"))
    if score and score.get("pass"):
        return "P"
    if not result.get("plan_detected"):
        return "N"
    return "V" if result.get("outcome") == "validationFailed" else "F"


def check_outcomes(run):
    for sub in ("", "retry", "fixed"):
        d = os.path.join(run, sub)
        verdict, score = _load(os.path.join(d, "verdict.json")), _load(os.path.join(d, "score.json"))
        if verdict is None or score is None:
            continue
        right, flagged = bool(score.get("pass")), verdict.get("matches") is not True
        yield {(False, True): "catch", (True, True): "false alarm", (False, False): "miss", (True, False): "ok"}[
            (right, flagged)
        ]


def main(base):
    rows, models, checks = defaultdict(dict), set(), defaultdict(Counter)
    for sketch in sorted(os.listdir(base)):
        if not os.path.isdir(os.path.join(base, sketch)):
            continue
        for run in sorted(os.listdir(os.path.join(base, sketch))):
            if "-r" not in run:
                continue
            model = run.rsplit("-r", 1)[0]
            models.add(model)
            path = os.path.join(base, sketch, run)
            rows[sketch][model] = rows[sketch].get(model, "") + cell(path)
            checks[model].update(check_outcomes(path))
    models = sorted(models)
    print("| sketch | " + " | ".join(models) + " |")
    print("|---|" + "---|" * len(models))
    totals = defaultdict(lambda: [0, 0])
    for sketch, cells in rows.items():
        print(f"| {sketch} | " + " | ".join(cells.get(m, "") for m in models) + " |")
        for m in models:
            totals[m][0] += cells.get(m, "").count("P")
            totals[m][1] += len(cells.get(m, ""))
    print("| **total** | " + " | ".join(f"**{totals[m][0]}/{totals[m][1]}**" for m in models) + " |")
    if any(checks.values()):
        print("\n| render-back check | " + " | ".join(models) + " |")
        print("|---|" + "---|" * len(models))
        for outcome in ("catch", "miss", "false alarm", "ok"):
            print(f"| {outcome} | " + " | ".join(str(checks[m][outcome]) for m in models) + " |")


if __name__ == "__main__":
    main(sys.argv[1])
