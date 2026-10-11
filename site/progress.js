/* Progress grids: one square per function in the original executable
   (assets/progress.json) and one per task in NovaSwift's own features
   (assets/features.json). No dependencies. */
(function () {
  var tip = document.createElement("div");
  tip.className = "tip";
  tip.setAttribute("role", "tooltip");
  tip.hidden = true;
  document.body.appendChild(tip);

  // Site palette (overrides the colours in the JSON). Picked to stay apart
  // under red-green colour blindness; "partly" squares are also drawn
  // half-filled in styles.css so status never relies on colour alone.
  var PALETTE = {
    done: "#2fc39a", partly: "#f2b33d", partial: "#f2b33d", gap: "#e8603c",
    deferred: "#d17fb5", mapped: "#4d78b8", library: "#3b3a40"
  };
  function paint(node, key, color) {
    var c = PALETTE[key] || color;
    if (c && c !== "none") node.style.setProperty("--c", c);
  }

  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  }

  function showTip(sq, x, y) {
    tip.innerHTML = "";
    var lines = sq._tip;
    tip.appendChild(el("b", null, lines[0]));
    for (var i = 1; i < lines.length; i++) if (lines[i]) tip.appendChild(el("span", null, lines[i]));
    tip.hidden = false;
    var r = tip.getBoundingClientRect();
    var left = Math.min(x + 14, window.innerWidth - r.width - 8);
    var top = y + 16;
    if (top + r.height > window.innerHeight - 8) top = y - r.height - 12;
    tip.style.left = Math.max(8, left) + "px";
    tip.style.top = Math.max(8, top) + "px";
  }

  function wire(root) {
    root.addEventListener("pointermove", function (e) {
      if (e.target._tip) showTip(e.target, e.clientX, e.clientY);
      else tip.hidden = true;
    });
    root.addEventListener("pointerleave", function () { tip.hidden = true; });
    root.addEventListener("click", function (e) {
      if (e.target._tip) { showTip(e.target, e.clientX, e.clientY); e.stopPropagation(); }
    });
    document.addEventListener("click", function () { tip.hidden = true; });
  }

  // statuses: [{key, color, label, count}]; groups: [{title, note, squares:[{status, tip:[...]}]}]
  function render(root, statuses, groups) {
    root.innerHTML = "";
    var hidden = {};
    var legend = el("div", "legend");
    statuses.forEach(function (s) {
      if (!s.count) return;
      var b = el("button", "key");
      b.type = "button";
      b.setAttribute("aria-pressed", "true");
      var sw = el("i", "sq st-" + s.key);
      paint(sw, s.key, s.color);
      b.appendChild(sw);
      b.appendChild(el("span", null, s.label + " "));
      b.appendChild(el("small", null, s.count.toLocaleString()));
      b.addEventListener("click", function (e) {
        e.stopPropagation();
        hidden[s.key] = !hidden[s.key];
        b.setAttribute("aria-pressed", hidden[s.key] ? "false" : "true");
        root.classList.toggle("hide-" + s.key, !!hidden[s.key]);
      });
      legend.appendChild(b);
    });
    root.appendChild(legend);

    var colors = {};
    statuses.forEach(function (s) { colors[s.key] = s.color; });
    groups.forEach(function (g) {
      var box = el("div", "grp");
      var head = el("div", "grp-head");
      head.appendChild(el("h3", null, g.title));
      head.appendChild(el("span", null, g.note));
      box.appendChild(head);
      var cells = el("div", "cells");
      var frag = document.createDocumentFragment();
      g.squares.forEach(function (q) {
        var sq = el("i", "sq st-" + q.status);
        paint(sq, q.status, colors[q.status]);
        sq._tip = q.tip;
        frag.appendChild(sq);
      });
      cells.appendChild(frag);
      box.appendChild(cells);
      root.appendChild(box);
    });
    wire(root);
  }

  function load(url, cb) {
    fetch(url).then(function (r) { return r.json(); }).then(cb).catch(function () {});
  }

  // The original's runtime, QuickTime, libraries, networking and shareware code:
  // NovaSwift replaces them with its own engine, so they get their own section.
  var INTERNAL = ["C runtime & Win32 glue", "QuickTime", "Image & audio libraries",
                  "Networking", "Shareware registration"];

  var exe = document.getElementById("grid-exe");
  var internalBox = document.getElementById("grid-internal");
  if (exe) load("assets/progress.json", function (d) {
    var label = {};
    d.statuses.forEach(function (s) { label[s.key] = s.label; });
    function toGroup(g) {
      var note = g.f.length + " functions";
      if (INTERNAL.indexOf(g.title) < 0 && g.f.length - g.counts.library > 0) note += " · " + g.pct + "% done";
      return {
        title: g.title,
        note: note,
        squares: g.f.map(function (f) {
          return {
            status: f[4],
            tip: [f[1], "0x" + f[0] + " · " + f[2].toLocaleString() + " bytes · " + f[3],
                  label[f[4]], f[5].length ? "Plan items: " + f[5].join(", ") : ""]
          };
        })
      };
    }
    function statusesFor(groups) {
      var count = {};
      groups.forEach(function (g) { g.squares.forEach(function (q) { count[q.status] = (count[q.status] || 0) + 1; }); });
      return d.statuses.map(function (s) {
        return { key: s.key, color: s.color, label: s.label, count: count[s.key] || 0 };
      });
    }
    var main = d.groups.filter(function (g) { return INTERNAL.indexOf(g.title) < 0; }).map(toGroup);
    var internal = d.groups.filter(function (g) { return INTERNAL.indexOf(g.title) >= 0; }).map(toGroup);
    render(exe, statusesFor(main), main);
    if (internalBox) render(internalBox, statusesFor(internal), internal);
  });

  var feat = document.getElementById("grid-features");
  if (feat) load("assets/features.json", function (d) {
    var defs = [
      { key: "done", color: "#3fb950", label: "Done" },
      { key: "partial", color: "#e3a52b", label: "Partly done" },
      { key: "planned", color: "none", label: "Planned" }
    ];
    var count = { done: 0, partial: 0, planned: 0 };
    var label = { done: "Done", partial: "Partly done", planned: "Planned" };
    var groups = d.features.map(function (f) {
      var done = 0;
      var squares = f.tasks.map(function (t) {
        count[t.status]++;
        if (t.status === "done") done++;
        return { status: t.status, tip: [t.name, f.name, label[t.status]] };
      });
      return { title: f.name, note: done + " of " + f.tasks.length + " done", squares: squares };
    });
    defs.forEach(function (s) { s.count = count[s.key]; });
    render(feat, defs, groups);
    feat.classList.add("big");
  });
})();
