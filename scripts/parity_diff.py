#!/usr/bin/env python3
"""Compare two runs of sql/parity/parity_snapshot.sql field by field.

    python scripts/parity_diff.py build/parity_before.txt build/parity_after.txt

The snapshot prints three result sets through run_sql.py: [5] objects (type, transient flag,
owner, relation comment fingerprint), [6] data (COUNT(*) and HASH_AGG(*) per object) and [7]
columns (ordinal, name, full type, nullability, column comment fingerprint). run_sql.py pads
columns to the widest value, so a plain line diff also flags rows whose padding changed; this
script parses the rows instead and compares them by key.

Verdict (exit 0 = parity, 1 = a difference that breaks parity, 2 = unreadable input):
  breaks parity     an object of the "before" run that is missing afterwards; a different row
                    count or row hash; a column added, dropped, moved, retyped or with a
                    different nullability; a different object type, transient flag or owner
  reported only     a changed relation or column comment (wording may change on purpose) and
                    objects that exist only afterwards (e.g. dbt seed tables)
Standard library only.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

SECTION = re.compile(r"^\[\s*(\d+)\]\s")


def parse(path: Path) -> dict[int, list[list[str]]]:
    """Return {statement index: rows as lists of cells} for the result sets of one run."""
    sections: dict[int, list[list[str]]] = {}
    current = None
    header_seen = False
    for line in path.read_text(encoding="utf-8").splitlines():
        match = SECTION.match(line)
        if match:
            current = int(match.group(1))
            sections[current] = []
            header_seen = False
            continue
        if current is None or not line.startswith("     "):
            continue
        cells = line.split()
        if not cells or cells[0] == "Statement":
            continue
        if not header_seen:          # the column header line of the result set
            header_seen = True
            continue
        sections[current].append(cells)
    return sections


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__)
        return 2
    before, after = parse(Path(argv[1])), parse(Path(argv[2]))
    try:
        objects = [{r[0]: r[1:] for r in run[5]} for run in (before, after)]
        data = [{r[0]: (r[1], r[2]) for r in run[6]} for run in (before, after)]
        columns = [{(r[0], r[2]): r for r in run[7]} for run in (before, after)]
    except (KeyError, IndexError) as exc:
        print(f"FAIL  cannot read the snapshot files ({type(exc).__name__}: {exc})")
        return 2

    breaks: list[str] = []
    notes: list[str] = []

    for name, b in objects[0].items():
        a = objects[1].get(name)
        if a is None:
            breaks.append(f"{name}: missing after")
            continue
        # TABLE_TYPE may contain a space ('BASE TABLE'): compare everything but the last two cells
        if b[:-2] != a[:-2]:
            breaks.append(f"{name}: type/transient/owner {' '.join(b[:-2])} -> {' '.join(a[:-2])}")
        if b[-1] != a[-1]:
            notes.append(f"{name}: relation comment changed (length {b[-2]} -> {a[-2]})")
    for name in sorted(set(objects[1]) - set(objects[0])):
        notes.append(f"{name}: new object ({' '.join(objects[1][name][:-2])})")

    n_equal = 0
    for name, b in data[0].items():
        a = data[1].get(name)
        if a != b:
            breaks.append(f"{name}: rows/hash {b} -> {a}")
        else:
            n_equal += 1

    n_cols = n_comment_changes = 0
    for key, b in columns[0].items():
        a = columns[1].get(key)
        n_cols += 1
        if a is None:
            breaks.append(f"{key[0]}.{key[1]}: column missing after")
            continue
        # cells: OBJECT, ORD, COLUMN, FULL_TYPE, IS_NULLABLE, COMMENT_LEN, COMMENT_MD5
        if b[1] != a[1] or b[3] != a[3] or b[4] != a[4]:
            breaks.append(f"{key[0]}.{key[1]}: ordinal/type/nullable {b[1]} {b[3]} {b[4]} -> {a[1]} {a[3]} {a[4]}")
        if b[6] != a[6]:
            n_comment_changes += 1
            notes.append(f"{key[0]}.{key[1]}: column comment {'added' if b[6] == '(none)' else 'changed'} "
                         f"(length {b[5]} -> {a[5]})")
    old_objects = set(objects[0])
    for key in sorted(set(columns[1]) - set(columns[0])):
        if key[0] in old_objects:
            breaks.append(f"{key[0]}.{key[1]}: column added")

    print(f"objects before: {len(objects[0])}, after: {len(objects[1])}")
    print(f"data fingerprints (COUNT + HASH_AGG): {n_equal} of {len(data[0])} identical")
    print(f"columns of the before objects: {n_cols}; comment changes: {n_comment_changes}")
    for line in notes:
        print(f"NOTE  {line}")
    for line in breaks:
        print(f"FAIL  {line}")
    if breaks:
        print(f"FAIL  parity broken: {len(breaks)} difference(s)")
        return 1
    print("OK    parity: every object, row count, row hash, column, type and nullability is identical "
          "(comment changes and new objects listed above)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
