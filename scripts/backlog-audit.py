#!/usr/bin/env python3
# Vendored from swares/HomeLab scripts/backlog-audit.py on 2026-09-23, unchanged
# below this block. The history in the docstring (the section numbers, the dates,
# "25 orphans") is the LAB's BACKLOG, not this repo's. Like the Kyverno policies,
# this copy is a snapshot allowed to drift: do not edit it expecting the change to
# reach the lab, and do not treat a difference from upstream as a bug.
"""Audit BACKLOG.md's own bookkeeping.

WHY THIS EXISTS
---------------
On 2026-09-20 a five-line throwaway script counted the checkboxes in BACKLOG.md
and found 49 open / 69 done — of which **25 open items sat inside entries whose
heading announced completion** (RESOLVED, FIXED, ACCEPTED, or struck through).
Reading the headings said the work was finished; the boxes said otherwise.

Sweeping those 25 closed nine items. Seven of them needed no work at all: they
were already true and nobody had run the command. `docs/STANDUP.md` carried
"unresolved H4 CRC fault" as an open hardware concern for weeks while all four
disks reported zero CRC errors.

That is the same failure this file spends five thousand lines documenting in the
infrastructure — a green summary over unfinished work — occurring in the document
that records it. So the check is permanent now rather than a thing someone
remembers to do. See BACKLOG §7.y.

WHAT IT REPORTS
---------------
orphan    An open `- [ ]` inside an entry whose heading claims completion.
          The high-value category: these are usually done-and-unticked, or real
          work hiding behind a reassuring title.

unowned   A checkbox with no `### N.M` entry above it inside its section. §5 and
          §9 keep their items as bullets directly under `## N.`, so a parser that
          tracks "the last ### seen" silently attributes them to whichever entry
          came before — on 2026-09-20 that inflated the orphan count from 12 to
          17 and sent the reader looking for items in entries that never held
          them. Reported as its own category rather than misfiled.

unboxed   A prose bullet in a section that otherwise uses checkboxes. It can
          never be marked done, so it is invisible to any progress count. §7 and
          §9 hold 17 of these, and §9 is titled "Small, live, cheap" — precisely
          the work that should close in minutes.

GATING: AN INVARIANT AND A RATCHET
----------------------------------
These are two different kinds of thing and gating them the same way would make
the check useless.

`unowned` and `unboxed` are **structural invariants**. They should be zero and
stay zero; a non-zero value means someone added an item the file cannot track.
`--strict` fails on those, and it is safe to run on every PR.

`orphans` is a **backlog**. It was 25 on 2026-09-20 and is worked down by
sweeping, which takes measurement and judgement — gating on zero would block
every unrelated PR until the sweep finished, and the first person blocked would
delete the check. `--max-orphans N` is a ratchet instead: set it to today's
count, lower it as entries are swept, and it fails only on regression.

EXIT CODES
----------
0  clean, or no gate requested
1  a requested gate failed
2  the file does not exist

Usage:
    scripts/backlog-audit.py                  # summary
    scripts/backlog-audit.py --list           # every finding, with line numbers
    scripts/backlog-audit.py --strict         # fail on unowned/unboxed (CI-safe)
    scripts/backlog-audit.py --max-orphans 11 # ratchet; fail only if it grows
    scripts/backlog-audit.py --file X.md
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# A heading claims completion if it is struck through or carries one of these.
# Kept explicit rather than clever: a regex that tried to infer "doneness" from
# prose would be the kind of check that cannot say why it decided something.
#
# EVERY MARKER MUST DESCRIBE THE ENTRY'S SUBJECT, NOT AN ACTIVITY PERFORMED ON
# IT. "SWEPT" was in this list for one revision and was wrong: §7.y is titled
# SWEPT because a sweep happened, not because its subject is finished, so its
# legitimate follow-ups were reported as orphans. Two of them, which is how the
# defect was noticed — the entry's own text said 13 and its own script said 15.
# If a future marker is ambiguous in that way, leave it out; a missed orphan is
# cheaper than a false one, because a false one teaches people to ignore the
# report.
CLOSED_MARKERS = (
    "RESOLVED", "FIXED", "APPLIED", "ANSWERED",
    "ACCEPTED", "CLOSED", "DONE",
)

RE_SECTION = re.compile(r"^## (?!#)(.+)$")
RE_ENTRY = re.compile(r"^### (.+)$")
RE_BOX = re.compile(r"^\s*- \[([ xX])\]")
RE_BULLET = re.compile(r"^- (?!\[)")


# Markers are matched as substrings, so a NEGATED marker would match its own
# negation: "NOT YET APPLIED" contains "APPLIED". That is not hypothetical — it
# happened on 2026-09-23, on §1.14, whose heading says the fix is *not* applied
# and which the tool therefore counted as complete, turning four honest open items
# into four phantom orphans. §2.14 has carried "FIXED …, not yet applied" for weeks
# and escaped only because that one is also struck through.
#
# Stripping the negation before matching is deliberately dumber than parsing it:
# the phrase this repo actually writes is "not yet <marker>", so that is the phrase
# removed. A heading needing more nuance than this should be reworded, not
# accommodated.
RE_NEGATED = re.compile(r"\bnot\s+yet\s+\w+", re.IGNORECASE)


def heading_claims_done(text: str) -> bool:
    text = RE_NEGATED.sub("", text)
    return "~~" in text or any(m in text for m in CLOSED_MARKERS)


def short(text: str, n: int = 58) -> str:
    text = re.sub(r"\s+", " ", text).strip()
    return text if len(text) <= n else text[: n - 1] + "…"


def audit(path: Path) -> dict:
    section = entry = None
    entry_done = False
    sections: dict[str, dict] = {}
    orphans: list[tuple[int, str, str]] = []
    unowned: list[tuple[int, str, str]] = []
    unboxed: list[tuple[int, str, str]] = []

    for n, line in enumerate(path.read_text(encoding="utf-8").split("\n"), 1):
        m = RE_SECTION.match(line)
        if m:
            section = m.group(1).strip()
            sections.setdefault(section, {"open": 0, "done": 0, "boxes": 0})
            entry, entry_done = None, False
            continue

        m = RE_ENTRY.match(line)
        if m:
            entry = m.group(1).strip()
            entry_done = heading_claims_done(entry)
            continue

        if section is None:
            continue

        m = RE_BOX.match(line)
        if m:
            s = sections[section]
            s["boxes"] += 1
            if m.group(1) == " ":
                s["open"] += 1
                if entry is None:
                    unowned.append((n, section, line))
                elif entry_done:
                    orphans.append((n, entry, line))
            else:
                s["done"] += 1
            continue

        # A prose bullet with NO owning entry, in a section that uses checkboxes
        # elsewhere — i.e. a section-level item that looks like work but cannot
        # be ticked. The `entry is None` test is load-bearing: without it this
        # matched every narrative bullet inside every entry and reported 95,
        # which is noise, not a finding. §7 and §9 are the real cases.
        if entry is None and RE_BULLET.match(line) and "~~" not in line:
            unboxed.append((n, section, line))

    boxed_sections = {s for s, v in sections.items() if v["boxes"] > 0}
    unboxed = [u for u in unboxed if u[1] in boxed_sections]

    return {
        "sections": sections,
        "orphans": orphans,
        "unowned": unowned,
        "unboxed": unboxed,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--file", default="BACKLOG.md", type=Path)
    ap.add_argument("--list", action="store_true", help="show every finding")
    ap.add_argument("--strict", action="store_true",
                    help="exit 1 on unowned/unboxed items (structural invariants)")
    ap.add_argument("--max-orphans", type=int, default=None, metavar="N",
                    help="exit 1 if orphans exceed N (a ratchet, not a target)")
    args = ap.parse_args()

    if not args.file.exists():
        print(f"no such file: {args.file}", file=sys.stderr)
        return 2

    r = audit(args.file)
    secs = r["sections"]
    tot_o = sum(v["open"] for v in secs.values())
    tot_d = sum(v["done"] for v in secs.values())

    print(f"{args.file}\n")
    print(f"  {'section':<48} {'open':>5} {'done':>5}")
    print(f"  {'-' * 48} {'-' * 5} {'-' * 5}")
    for s, v in secs.items():
        if v["boxes"]:
            print(f"  {short(s, 48):<48} {v['open']:>5} {v['done']:>5}")
    print(f"  {'-' * 48} {'-' * 5} {'-' * 5}")
    print(f"  {'TOTAL':<48} {tot_o:>5} {tot_d:>5}\n")

    print(f"  orphans  {len(r['orphans']):>3}   open items inside entries titled as complete")
    print(f"  unowned  {len(r['unowned']):>3}   checkboxes with no ### entry in their section")
    print(f"  unboxed  {len(r['unboxed']):>3}   prose bullets that can never be marked done")

    if args.list:
        for name, rows in (("ORPHANS", r["orphans"]),
                           ("UNOWNED", r["unowned"]),
                           ("UNBOXED", r["unboxed"])):
            if not rows:
                continue
            print(f"\n{name}")
            for n, owner, line in rows:
                print(f"  L{n:<6} {short(owner, 40):<40} {short(line, 62)}")
    elif r["orphans"] or r["unowned"]:
        print("\n  (--list to see them)")

    failed = False
    if args.strict and (r["unowned"] or r["unboxed"]):
        print(f"\nFAIL: --strict — {len(r['unowned'])} unowned, "
              f"{len(r['unboxed'])} unboxed. Every item needs an owning "
              f"### entry and a checkbox, or nothing can track it.")
        failed = True
    if args.max_orphans is not None and len(r["orphans"]) > args.max_orphans:
        print(f"\nFAIL: orphans {len(r['orphans'])} > --max-orphans "
              f"{args.max_orphans}. Either sweep one, or an entry heading now "
              f"claims completion over work that is not done.")
        failed = True
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
