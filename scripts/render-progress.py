#!/usr/bin/env python3
"""Render the feature progress graphics from site/assets/features.json:

  docs/branding/feature-blocks.svg     one square per task, every group
  docs/branding/features-summary.svg   a 20-square bar and percentage per group
  site/assets/features-summary.svg     (copy of the summary, for the website)

Run it after editing features.json:  python3 scripts/render-progress.py
"""
import json, os
from xml.sax.saxutils import escape

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DONE, PART, PLAN_STROKE, TODO = "#3fb950", "#e3a52b", "#8d807c", "#2b2730"
FONT = "-apple-system, Segoe UI, Helvetica, Arial, sans-serif"
LABEL = {"done": "Done", "partial": "Partly done", "planned": "Planned"}


def counts(tasks):
    d = sum(t["status"] == "done" for t in tasks)
    p = sum(t["status"] == "partial" for t in tasks)
    return d, p, len(tasks) - d - p


def blocks(features):
    per_row, step, x0 = 14, 15, 216
    all_tasks = [t for f in features for t in f["tasks"]]
    d, p, n = counts(all_tasks)
    body, y = [], 92
    for f in features:
        fd, _, _ = counts(f["tasks"])
        name = escape(f["name"])
        body.append(f'<text x="16" y="{y}" class="gh">{name}</text>'
                    f'<text x="576" y="{y}" class="gn" text-anchor="end">{fd} of {len(f["tasks"])} done</text>')
        for i, t in enumerate(f["tasks"]):
            x, ry = x0 + (i % per_row) * step, y - 12 + (i // per_row) * step
            title = f'<title>{name}: {escape(t["name"])} — {LABEL[t["status"]]}</title>'
            if t["status"] == "planned":
                body.append(f'<rect x="{x + 0.5}" y="{ry + 0.5}" width="11" height="11" fill="none" '
                            f'stroke="{PLAN_STROKE}">{title}</rect>')
            else:
                c = DONE if t["status"] == "done" else PART
                body.append(f'<rect x="{x}" y="{ry}" width="12" height="12" fill="{c}">{title}</rect>')
        y += 27 + 15 * ((len(f["tasks"]) - 1) // per_row)
    h = y - 27 + 19
    # Legend: each label is followed by the next swatch, ~6.2 px per character.
    l1, l2, l3 = f"Done ({d})", f"Partly done ({p})", f"Planned ({n})"
    x2 = round(30 + len(l1) * 6.2 + 18)
    x3 = round(x2 + 14 + len(l2) * 6.2 + 18)
    head = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="592" height="{h}" viewBox="0 0 592 {h}" font-family="{FONT}">',
        '<style>.h1{font-size:14px;font-weight:600;fill:#f0e6da}.gh{font-size:12px;font-weight:600;fill:#f0e6da}'
        '.gn{font-size:11px;fill:#a89a95}.lg{font-size:11px;fill:#c6bab5}</style>',
        f'<rect width="592" height="{h}" rx="10" fill="#0d0a0e"/>',
        '<text x="16" y="32" class="h1">Beyond the original: NovaSwift\'s own features, one square per task</text>',
        f'<rect x="16" y="46" width="9" height="9" fill="{DONE}"/>',
        f'<text x="30" y="55" class="lg">{l1}</text>',
        f'<rect x="{x2}" y="46" width="9" height="9" fill="{PART}"/>',
        f'<text x="{x2 + 14}" y="55" class="lg">{l2}</text>',
        f'<rect x="{x3}" y="46" width="9" height="9" fill="none" stroke="{PLAN_STROKE}"/>',
        f'<text x="{x3 + 14}" y="55" class="lg">{l3}</text>',
    ]
    return "\n".join(head + body + ["</svg>"]) + "\n"


def summary(features):
    all_tasks = [t for f in features for t in f["tasks"]]
    d, p, _ = counts(all_tasks)
    overall = round(100 * (d + p / 2) / len(all_tasks))
    rows, y = [], 90
    for f in features:
        fd, fp, _ = counts(f["tasks"])
        m = len(f["tasks"])
        g, a = round(fd / m * 20), round(fp / m * 20)
        rows.append(f'<text x="20" y="{y}" class="nm">{escape(f["name"])}</text>')
        for i in range(20):
            c = DONE if i < g else PART if i < g + a else TODO
            rows.append(f'<rect x="{230 + 17 * i}" y="{y - 12}" width="14" height="14" rx="2" fill="{c}"/>')
        rows.append(f'<text x="580" y="{y}" class="pc">{round(100 * fd / m)}%</text>')
        y += 24
    h = y + 26
    legend = (f'<rect x="20" y="{h - 30}" width="12" height="12" rx="2" fill="{DONE}"/><text x="38" y="{h - 19}" class="sb">done</text>'
              f'<rect x="90" y="{h - 30}" width="12" height="12" rx="2" fill="{PART}"/><text x="108" y="{h - 19}" class="sb">in progress</text>'
              f'<rect x="200" y="{h - 30}" width="12" height="12" rx="2" fill="{TODO}"/><text x="218" y="{h - 19}" class="sb">to do</text>')
    head = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="640" height="{h}" viewBox="0 0 640 {h}" font-family="{FONT}">',
        '<style>.hl{font-size:22px;font-weight:700;fill:#f0e6da}.sb{font-size:12px;fill:#a89a95}'
        '.nm{font-size:13px;fill:#f0e6da}.pc{font-size:13px;font-weight:600;fill:#f0e6da}</style>',
        f'<rect width="640" height="{h}" rx="10" fill="#0d0a0e"/>',
        f'<text x="20" y="34" class="hl">NovaSwift\'s own features: {overall}% done</text>',
        '<text x="20" y="56" class="sb">Things the original never had. Partly done tasks count as half.</text>',
    ]
    return "\n".join(head + rows + [legend, "</svg>"]) + "\n"


def main():
    features = json.load(open(os.path.join(ROOT, "site/assets/features.json")))["features"]
    out = {
        "docs/branding/feature-blocks.svg": blocks(features),
        "docs/branding/features-summary.svg": summary(features),
        "site/assets/features-summary.svg": summary(features),
    }
    for path, svg in out.items():
        open(os.path.join(ROOT, path), "w").write(svg)
        print("wrote", path)


if __name__ == "__main__":
    main()
