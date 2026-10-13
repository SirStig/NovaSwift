#!/usr/bin/env python3
"""Recolour the function grid so it agrees with FIDELITY_PLAN.md.

The grid (site/assets/progress.json, docs/branding/progress-blocks.svg) is drawn
by evnova-re/tools/scripts/progress_blocks.py from the decompile's function map
and the addresses each plan item cites. That drawing treats a plan item as done
only if its heading says **DONE**. This script applies the same idea to the data
already in progress.json, so it needs nothing outside this repository.

Rule (reproducible from the two inputs):
  A function whose status is "done" or "mapped" (the evnova-re generator paints a function
  cited only by open items as "mapped") and which is cited by at least one plan
  item, where EVERY citing item is not marked **DONE** in FIDELITY_PLAN.md
  (that is, **OPEN**, or with no marker), becomes "partly"
  (amber, "Differs: fix in progress").
  Functions cited by at least one DONE item, functions with no citing item
  (matched by the line-by-line sweeps), teal, and every other status are left alone.

It then recomputes, from the squares, every count that quotes them: totals,
gameplay totals, per-group counts and percentages, and the plan-item tally
(counted from the headings). It redraws:
  site/assets/progress.json
  docs/branding/progress-blocks.svg
  docs/branding/fidelity-summary.svg and its copy site/assets/fidelity-summary.svg
and refreshes the ?v= cache tags on the image links in README.md, docs/STATUS.md and site/index.html.

Running it twice changes nothing. Re-running progress_blocks.py would overwrite
the result (it has no amber rule for open items and would paint those squares
blue), so run this script after it.

Usage: python3 scripts/reopen-progress.py [--check]
  --check   print the counts and exit without writing anything
"""
import argparse, hashlib, json, os, re, sys
from xml.sax.saxutils import escape

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLAN = os.path.join(ROOT, "docs", "reverse-engineering", "FIDELITY_PLAN.md")
JSON = os.path.join(ROOT, "site", "assets", "progress.json")
BRAND = os.path.join(ROOT, "docs", "branding")
ITEM = re.compile(r"^#### ([A-Z]{2}-\d+)\b(.*)$")
STATUS_COLOR = {"done": "#3fb950", "replaced": "#3aa6b9", "partly": "#e3a52b", "gap": "#d1495b",
                "deferred": "#a371f7", "mapped": "#3d5f8c", "unexplored": "none", "library": "#3a3236"}
INTERNAL = ("C runtime & Win32 glue", "QuickTime", "Image & audio libraries", "Networking",
            "Shareware registration")


def plan_items():
    """{item id: 'done' | 'open'} from the #### headings."""
    out = {}
    for line in open(PLAN, encoding="utf-8"):
        m = ITEM.match(line)
        if m:
            out[m.group(1)] = "done" if "**DONE**" in m.group(2) else "open"
    return out


def recolour(data, items):
    changed = 0
    for g in data["groups"]:
        for f in g["f"]:
            ids = list(dict.fromkeys(f[5]))
            if f[4] in ("done", "mapped") and ids and all(items.get(i, "open") != "done" for i in ids):
                f[4] = "partly"
                changed += 1
    keys = [s["key"] for s in data["statuses"]]
    tot = {k: 0 for k in keys}
    game = {k: 0 for k in keys}
    n = gn = 0
    for g in data["groups"]:
        c = {k: 0 for k in keys}
        for f in g["f"]:
            c[f[4]] += 1
            tot[f[4]] += 1
            if g["gameplay"]:
                game[f[4]] += 1
        g["counts"] = c
        port = len(g["f"]) - c["library"]
        g["pct"] = round(100 * (c["done"] + c["replaced"]) / port) if port else 100
        n += len(g["f"])
        gn += len(g["f"]) if g["gameplay"] else 0
    t = data["totals"]
    t["n"], t["counts"], t["gameplay_n"], t["gameplay_counts"] = n, tot, gn, game
    t["items"] = len(items)
    t["item_status"] = {"done": sum(v == "done" for v in items.values()), "partly": 0, "deferred": 0,
                        "open": sum(v == "open" for v in items.values())}
    return changed


# ---- drawing (same layout as progress_blocks.py) -------------------------------

def grid_svg(path, data):
    label = {s["key"]: s["label"] for s in data["statuses"]}
    t = data["totals"]
    legend = [(STATUS_COLOR[k], f"{label[k]} ({t['counts'][k]})") for k in label if t["counts"][k]]
    groups = []
    for g in data["groups"]:
        if not g["f"]:
            continue
        c = g["counts"]
        note = f'{len(g["f"])} functions'
        if c["done"] or c["partly"]:
            note += f' · {c["done"]} matched'
        if c["gap"]:
            note += f' · {c["gap"]} differ'
        sq = []
        for a, name, size, _sub, st, ids in g["f"]:
            tip = f'{name} @ 0x{a} ({size} B) — {label[st]}' + (f' — {", ".join(ids)}' if ids else "")
            sq.append((STATUS_COLOR[st], tip))
        groups.append((g["title"], note, sq))
    render_grid(path, f"EV Nova CE executable: {t['n']} functions, one square each", legend, groups)


def render_grid(path, title, legend, groups, per_row=50, cell=7, gap=1):
    pitch, left = cell + gap, 16
    width = left + per_row * pitch + 16
    parts, y = [f'<text x="{left}" y="32" class="h1">{escape(title)}</text>'], 46
    lx = left
    for color, txt in legend:
        need = 14 + int(len(txt) * 6.2) + 18
        if lx + need > width - 16:
            lx, y = left, y + 18
        fill = f'fill="{color}"' if color != "none" else 'fill="none" stroke="#8d807c"'
        parts.append(f'<rect x="{lx}" y="{y}" width="9" height="9" {fill}/>')
        parts.append(f'<text x="{lx + 14}" y="{y + 9}" class="lg">{escape(txt)}</text>')
        lx += need
    y += 34
    for gtitle, note, squares in groups:
        parts.append(f'<text x="{left}" y="{y}" class="gh">{escape(gtitle)}</text>'
                     f'<text x="{width - 16}" y="{y}" class="gn" text-anchor="end">{escape(note)}</text>')
        top = y + 7
        for i, (color, tip) in enumerate(squares):
            x, yy = left + (i % per_row) * pitch, top + (i // per_row) * pitch
            if color == "none":
                parts.append(f'<rect x="{x + 0.5}" y="{yy + 0.5}" width="{cell - 1}" height="{cell - 1}" '
                             f'fill="none" stroke="#8d807c"><title>{escape(tip)}</title></rect>')
            else:
                parts.append(f'<rect x="{x}" y="{yy}" width="{cell}" height="{cell}" fill="{color}">'
                             f'<title>{escape(tip)}</title></rect>')
        y = top + ((len(squares) - 1) // per_row + 1 if squares else 1) * pitch + 22
    write_svg(path, width, y + 4, parts,
              ".h1{font-size:14px;font-weight:600;fill:#f0e6da}.gh{font-size:12px;font-weight:600;fill:#f0e6da}"
              ".gn{font-size:11px;fill:#a89a95}.lg{font-size:11px;fill:#c6bab5}", nl=True)


def write_svg(path, width, height, parts, style, nl=False):
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
           f'viewBox="0 0 {width} {height}" font-family="-apple-system, Segoe UI, Helvetica, Arial, sans-serif">\n'
           f'<style>{style}</style>\n'
           f'<rect width="{width}" height="{height}" rx="10" fill="#0d0a0e"/>\n' + "\n".join(parts) + "\n</svg>\n")
    with open(path, "w", encoding="utf-8") as f:
        f.write(svg)


def summary_svg(path, data, matched, port, n_open, n_amber):
    """One row per part of the original; 20 squares of 5% each (done, teal, amber, red). The number
    at the end of a row is matched/portable functions, not a percentage, so a full row is not read as "finished"."""
    blocks, cell, gap, left, name_w = 20, 14, 3, 20, 210
    strip_w = blocks * (cell + gap)
    width = left + name_w + strip_w + 80
    y, parts = 34, [f'<text x="{left}" y="34" class="hl">Compared and matching: {matched} of {port} functions</text>']
    y += 22
    parts.append(f'<text x="{left}" y="{y}" class="sb">{n_open} plan items are open; the {n_amber} functions only they cite '
                 f'are amber, not green.</text>')
    y += 22
    for g in data["groups"]:
        c = g["counts"]
        port = len(g["f"]) - c["library"]
        if g["title"] in INTERNAL or port < 5:
            continue
        done, part, repl, gp = (c["done"] / port, c["partly"] / port, c["replaced"] / port, c["gap"] / port)
        nd = round(done * blocks)
        nr = min(blocks - nd, round((done + repl) * blocks) - nd)
        npart = min(blocks - nd - nr, round(part * blocks))
        if c["partly"] and npart == 0 and nd + nr < blocks:
            npart = 1  # never hide an amber function behind rounding
        ngap = min(blocks - nd - nr - npart, round(gp * blocks))
        parts.append(f'<text x="{left}" y="{y + cell - 2}" class="nm">{escape(g["title"])}</text>')
        for i in range(blocks):
            color = ("#3fb950" if i < nd else "#3aa6b9" if i < nd + nr else "#e3a52b" if i < nd + nr + npart
                     else "#d1495b" if i < nd + nr + npart + ngap else "#2b2730")
            parts.append(f'<rect x="{left + name_w + i * (cell + gap)}" y="{y}" width="{cell}" height="{cell}" rx="2" fill="{color}"/>')
        parts.append(f'<text x="{left + name_w + strip_w + 10}" y="{y + cell - 2}" class="pc">'
                     f'{c["done"] + c["replaced"]}/{port}</text>')
        y += cell + 10
    y += 8
    for dx, col, txt in ((0, "#3fb950", "matching"), (80, "#3aa6b9", "done differently by design"),
                         (250, "#e3a52b", "differs, fix in progress"), (410, "#2b2730", "not matching yet")):
        parts.append(f'<rect x="{left + dx}" y="{y}" width="12" height="12" rx="2" fill="{col}"/>'
                     f'<text x="{left + dx + 18}" y="{y + 11}" class="sb">{txt}</text>')
    write_svg(path, width, y + 30, parts,
              ".hl{font-size:22px;font-weight:700;fill:#f0e6da}.sb{font-size:11px;fill:#a89a95}"
              ".nm{font-size:13px;fill:#f0e6da}.pc{font-size:13px;font-weight:600;fill:#f0e6da}")


def bust_cache():
    """Tag each image link with a hash of its SVG so GitHub's proxy and browsers refetch it."""
    names = ("progress-blocks.svg", "fidelity-summary.svg", "feature-blocks.svg", "features-summary.svg")
    docs = ("README.md", os.path.join("docs", "STATUS.md"), os.path.join("site", "index.html"))
    for name in names:
        tag = hashlib.sha1(open(os.path.join(BRAND, name), "rb").read()).hexdigest()[:8]
        for doc in docs:
            p = os.path.join(ROOT, doc)
            text = open(p, encoding="utf-8").read()
            new = re.sub(r"(\]\((?:docs/)?branding/" + re.escape(name) + r"|src=\"assets/" + re.escape(name) + r")"
                         r"(\?v=[0-9a-zA-Z]+)?(?=[)\"])", lambda m: m.group(1) + "?v=" + tag, text)
            if new != text:
                open(p, "w", encoding="utf-8").write(new)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    data = json.load(open(JSON, encoding="utf-8"))
    items = plan_items()
    changed = recolour(data, items)
    t = data["totals"]
    port = sum(len(g["f"]) - g["counts"]["library"] for g in data["groups"] if g["title"] not in INTERNAL)
    matched = sum(g["counts"]["done"] + g["counts"]["replaced"] for g in data["groups"] if g["title"] not in INTERNAL)
    overall = round(100 * matched / port)
    print(f"recoloured this run: {changed}; functions {t['n']}: {t['counts']}")
    print(f"gameplay {t['gameplay_n']}: {t['gameplay_counts']}")
    print(f"plan items {t['items']}: {t['item_status']}; matched/portable {matched}/{port} = {overall}%")
    if a.check:
        return
    with open(JSON, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, separators=(",", ":"))
    grid_svg(os.path.join(BRAND, "progress-blocks.svg"), data)
    summary_svg(os.path.join(BRAND, "fidelity-summary.svg"), data, matched, port, t["item_status"]["open"], t["counts"]["partly"])
    with open(os.path.join(BRAND, "fidelity-summary.svg"), "rb") as s, \
            open(os.path.join(ROOT, "site", "assets", "fidelity-summary.svg"), "wb") as d:
        d.write(s.read())
    bust_cache()


if __name__ == "__main__":
    main()
