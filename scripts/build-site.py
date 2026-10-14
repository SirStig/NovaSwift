#!/usr/bin/env python3
"""Stamp the shared nav and footer into every page of site/.

Each page keeps its own <head> and content. The blocks between
<!-- nav:start --> / <!-- nav:end --> and <!-- footer:start --> / <!-- footer:end -->
are replaced with site/_partials/nav.html and footer.html. Run it after
editing a partial; GitHub Pages serves site/ as-is, so commit the result.
"""
import pathlib, re, sys

site = pathlib.Path(__file__).resolve().parent.parent / "site"
parts = {n: (site / "_partials" / f"{n}.html").read_text().rstrip("\n") for n in ("nav", "footer", "guidenav")}
changed = 0
for page in sorted(site.glob("*.html")):
    text = page.read_text()
    new = text
    for name, body in parts.items():
        pat = re.compile(rf"<!-- {name}:start -->.*?<!-- {name}:end -->", re.S)
        new = pat.sub(lambda m: f"<!-- {name}:start -->\n{body}\n{'      ' if name == 'guidenav' else '  '}<!-- {name}:end -->", new)
    if new != text:
        page.write_text(new)
        changed += 1
        print("updated", page.name)
missing = [p.name for p in site.glob("*.html") if "<!-- nav:start -->" not in p.read_text()]
if missing:
    print("no nav markers:", ", ".join(missing), file=sys.stderr)
print(f"{changed} page(s) updated")
