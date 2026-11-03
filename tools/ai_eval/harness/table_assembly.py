"""Pass table for every scored Assembly-mode run: runs/asm_<sketch>/<model>-r<n>/score.json.
Usage: table_assembly.py <runs_dir>"""
import glob
import json
import os
import sys

rows = []
for f in sorted(glob.glob(os.path.join(sys.argv[1], "asm_*", "*", "score.json"))):
    run = os.path.dirname(f)
    s = json.load(open(f))
    rows.append((os.path.basename(os.path.dirname(run)), os.path.basename(run), s))
print("| Sketch | Run | Parts | Assembly | Mates | Retries | Pass | Notes |")
print("|---|---|---|---|---|---|---|---|")
for sketch, run, s in rows:
    notes = []
    if s.get("stopped"):
        notes.append(s["stopped"])
    if s.get("parts_wrong"):
        notes.append("wrong: " + ", ".join(s["parts_wrong"]))
    if s.get("solids") and s["solids"].split("/")[0] != s["solids"].split("/")[1]:
        notes.append(f"components {s['solids']}")
    if s.get("overlap_pct"):
        notes.append(f"overlap {s['overlap_pct']}%")
    if s.get("placement_max_err"):
        notes.append(f"placement off {s['placement_max_err']} mm")
    if not s.get("confirmed"):
        notes.append("key unconfirmed")
    print(f"| {sketch} | {run} | {s.get('parts_ok')} | {'ok' if s.get('assembly_ok') else s.get('assembly_outcome') or '-'} "
          f"| {s.get('mates', '-')} | {s.get('retries', 0)} | {'P' if s.get('pass') else '-'} | {'; '.join(notes)} |")
