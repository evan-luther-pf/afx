#!/usr/bin/env python3
"""Summarize hyperfine results into benchmark-action format and print a table."""

import json
import glob
import os

RESULTS_DIR = os.path.join(os.path.dirname(__file__), "results")

if not os.path.isdir(RESULTS_DIR):
    raise SystemExit(f"error: no results directory at {RESULTS_DIR}")

def ms(v):
    return f"{v * 1000:.1f}ms"

entries = []
rows = []

for f in sorted(glob.glob(os.path.join(RESULTS_DIR, "*.json"))):
    if os.path.basename(f) == "summary.json":
        continue
    data = json.load(open(f))
    r = data["results"][0]

    rows.append((r["command"], ms(r["mean"]), ms(r["stddev"]), ms(r["min"]), ms(r["max"])))
    entries.append(
        {
            "name": r["command"],
            "unit": "s",
            "value": round(r["mean"], 6),
            "range": f"\u00b1 {r['stddev']:.6f}",
            "extra": (
                f"min={r['min']:.6f}s max={r['max']:.6f}s "
                f"median={r['median']:.6f}s runs={len(r.get('times', []))}"
            ),
        }
    )

print(f"{'COMMAND':<25} {'MEAN':>10} {'STDDEV':>10} {'MIN':>10} {'MAX':>10}")
print(f"{'-------':<25} {'----':>10} {'------':>10} {'---':>10} {'---':>10}")
for name, mean, stddev, mn, mx in rows:
    print(f"{name:<25} {mean:>10} {stddev:>10} {mn:>10} {mx:>10}")
print()

out_path = os.path.join(RESULTS_DIR, "summary.json")
json.dump(entries, open(out_path, "w"), indent=2)
print(f"Results written to {out_path}")
