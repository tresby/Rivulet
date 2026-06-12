#!/usr/bin/env python3
"""
Parse an Instruments hitches.xml export and print a summary.
Same methodology used for the SwiftUI baseline; reusing here for the
UIKit carousel comparison.

Usage:
    xctrace export --input <trace.trace> \
        --xpath '/trace-toc/run[@number="1"]/data/table[@schema="hitches"]' \
        --output /tmp/hitches.xml
    python3 analyze_hitches.py /tmp/hitches.xml
"""
import re
import sys
from collections import Counter

def main(path: str) -> None:
    with open(path) as f:
        data = f.read()

    rows = re.findall(r'<row>(.*?)</row>', data, re.DOTALL)
    print(f"Total hitch events: {len(rows)}")
    if not rows:
        return

    events = []
    for row in rows:
        start = re.search(r'<start-time[^>]*?fmt="([^"]+)">(\d+)', row)
        dur = re.search(r'<duration[^>]*?fmt="([\d.]+) ms">(\d+)', row)
        all_strs = re.findall(r'<string[^>]*?fmt="([^"]*)"', row)
        narrative = all_strs[-1] if all_strs else ""
        if start and dur:
            events.append({
                "start_ns": int(start.group(2)),
                "dur_ms": float(dur.group(1)),
                "narrative": narrative,
            })
    events.sort(key=lambda e: e["start_ns"])

    durs = sorted([e["dur_ms"] for e in events])
    print(f"\n=== Hitch durations (ms) ===")
    print(f"  Min: {durs[0]:.2f}  p50: {durs[len(durs)//2]:.2f}  p95: {durs[int(len(durs)*0.95)]:.2f}  Max: {durs[-1]:.2f}")
    print(f"  Mean: {sum(durs)/len(durs):.2f}")
    print(f"  Total hitch time: {sum(durs):.0f} ms")

    tag_counts: Counter[str] = Counter()
    for e in events:
        for t in [t.strip() for t in e["narrative"].split(",")]:
            if t:
                tag_counts[t] += 1
    print(f"\n=== Narrative tag frequency ===")
    for tag, n in tag_counts.most_common():
        print(f"  {n:>4}x {tag[:90]}")

    offscreen_re = re.compile(r"(\d+)\s+offscreen\s+passes")
    counts = [int(m.group(1)) for e in events for m in [offscreen_re.search(e["narrative"])] if m]
    if counts:
        print(f"\n=== Offscreen passes per hitch ===")
        print(f"  Hitches reporting: {len(counts)} of {len(events)}")
        print(f"  Min: {min(counts)}  p50: {sorted(counts)[len(counts)//2]}  Max: {max(counts)}")
        print(f"  Mean: {sum(counts)/len(counts):.1f}")

    print(f"\n=== Top 10 worst hitches ===")
    if events:
        t0 = events[0]["start_ns"]
        worst = sorted(events, key=lambda e: -e["dur_ms"])[:10]
        for e in worst:
            t_s = (e["start_ns"] - t0) / 1e9
            print(f"  t={t_s:>5.2f}s dur={e['dur_ms']:>6.2f}ms  {e['narrative'][:120]}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <hitches.xml>", file=sys.stderr)
        sys.exit(1)
    main(sys.argv[1])
