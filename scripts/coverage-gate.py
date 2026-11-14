#!/usr/bin/env python3
"""Fail unless every Solidity source file in an lcov report is fully covered.

Usage: coverage-gate.py lcov.info --include '^src/' [--exclude '/test/'] [--allow-branch FILE:LINE ...]

Lines, functions and branches must all be 100%. --allow-branch names a branch that cannot be reached without changing
deployed source; each one must still exist and still be uncovered, so the allowance cannot outlive the reason for it.
"""
import argparse
import re
import sys


def parse(path):
    files, cur = {}, None
    for raw in open(path):
        line = raw.strip()
        if line.startswith("SF:"):
            cur = files.setdefault(line[3:], {"lines": {}, "fns": {}, "branches": {}})
        elif cur is None:
            continue
        elif line.startswith("DA:"):
            n, hits = line[3:].split(",")[:2]
            cur["lines"][int(n)] = max(cur["lines"].get(int(n), 0), int(hits))
        elif line.startswith("FNDA:"):
            hits, name = line[5:].split(",", 1)
            cur["fns"][name] = max(cur["fns"].get(name, 0), int(hits))
        elif line.startswith("BRDA:"):
            n, block, branch, taken = line[5:].split(",")
            key = (int(n), block, branch)
            cur["branches"][key] = max(cur["branches"].get(key, 0), 0 if taken == "-" else int(taken))
        elif line == "end_of_record":
            cur = None
    return files


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("lcov")
    ap.add_argument("--include", required=True)
    ap.add_argument("--exclude", default=None)
    ap.add_argument("--allow-branch", action="append", default=[])
    a = ap.parse_args()
    files = {f: d for f, d in parse(a.lcov).items()
             if re.search(a.include, f) and not (a.exclude and re.search(a.exclude, f))}
    if not files:
        sys.exit(f"coverage-gate: no files match {a.include!r} in {a.lcov}")
    allowed = {(f, int(n)) for f, n in (x.rsplit(":", 1) for x in a.allow_branch)}
    used, failures = set(), []
    print(f"{'file':52} {'lines':>11} {'funcs':>9} {'branches':>9}")
    for f in sorted(files):
        d = files[f]
        lh, lf = sum(1 for h in d["lines"].values() if h), len(d["lines"])
        fh, ff = sum(1 for h in d["fns"].values() if h), len(d["fns"])
        bh, bf = sum(1 for h in d["branches"].values() if h), len(d["branches"])
        print(f"{f:52} {lh:>5}/{lf:<5} {fh:>4}/{ff:<4} {bh:>4}/{bf:<4}")
        failures += [f"{f}:{n} line never executed" for n, h in sorted(d["lines"].items()) if not h]
        failures += [f"{f} function {n} never called" for n, h in sorted(d["fns"].items()) if not h]
        for (n, _, _), h in sorted(d["branches"].items()):
            if h:
                continue
            if (f, n) in allowed:
                used.add((f, n))
            else:
                failures.append(f"{f}:{n} branch never taken")
    stale = sorted(allowed - used)
    failures += [f"{f}:{n} is allowed as unreachable but is covered or gone; drop the allowance" for f, n in stale]
    if failures:
        print("\nFAIL\n  " + "\n  ".join(failures))
        sys.exit(1)
    if used:
        print(f"\nPASS: {len(files)} files, 100% lines and functions; every branch taken except {len(used)} allowed as"
              f" unreachable ({', '.join(f'{f}:{n}' for f, n in sorted(used))})")
    else:
        print(f"\nPASS: {len(files)} files, 100% lines, functions and branches")


if __name__ == "__main__":
    main()
