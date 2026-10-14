/* Shared page behaviour: mobile menu, current-page marker, copy buttons,
   tabs and the screenshot lightbox. No dependencies. */
(function () {
  "use strict";

  /* ---- Mobile menu ---- */
  var toggle = document.querySelector(".menu-toggle");
  var links = document.getElementById("nav-links");
  if (toggle && links) {
    toggle.addEventListener("click", function () {
      var open = toggle.getAttribute("aria-expanded") !== "true";
      toggle.setAttribute("aria-expanded", String(open));
      links.classList.toggle("open", open);
    });
    links.addEventListener("click", function (e) {
      if (e.target.closest("a")) { toggle.setAttribute("aria-expanded", "false"); links.classList.remove("open"); }
    });
  }

  /* ---- Current page in the nav ---- */
  var page = document.body.getAttribute("data-page");
  if (page) {
    document.querySelectorAll('.nav-links a[data-nav="' + page + '"]').forEach(function (a) {
      a.setAttribute("aria-current", "page");
    });
  }
  var file = location.pathname.split("/").pop() || "index.html";
  document.querySelectorAll(".doc-nav a").forEach(function (a) {
    if (a.getAttribute("href") === file) a.setAttribute("aria-current", "page");
  });

  /* ---- Copy buttons on code blocks ---- */
  document.querySelectorAll("pre.code").forEach(function (pre) {
    if (pre.hasAttribute("data-nocopy")) return;
    var b = document.createElement("button");
    b.type = "button"; b.className = "copy-btn"; b.textContent = "Copy";
    b.addEventListener("click", function () {
      var text = (pre.querySelector("code") || pre).innerText
        .split("\n").filter(function (l) { return !/^\s*#/.test(l); }).join("\n").trim();
      var done = function () {
        b.textContent = "Copied"; b.classList.add("done");
        setTimeout(function () { b.textContent = "Copy"; b.classList.remove("done"); }, 1600);
      };
      if (navigator.clipboard) navigator.clipboard.writeText(text).then(done, function () {});
    });
    pre.appendChild(b);
  });

  /* ---- Tabs ---- */
  document.querySelectorAll(".tabs").forEach(function (box) {
    var tabs = Array.prototype.slice.call(box.querySelectorAll('[role="tab"]'));
    function select(tab, focus) {
      tabs.forEach(function (t) {
        var on = t === tab;
        t.setAttribute("aria-selected", String(on));
        t.tabIndex = on ? 0 : -1;
        var panel = document.getElementById(t.getAttribute("aria-controls"));
        if (panel) panel.hidden = !on;
      });
      if (focus) tab.focus();
    }
    tabs.forEach(function (t, i) {
      t.addEventListener("click", function () { select(t); });
      t.addEventListener("keydown", function (e) {
        var d = e.key === "ArrowRight" ? 1 : e.key === "ArrowLeft" ? -1 : 0;
        if (d) { e.preventDefault(); select(tabs[(i + d + tabs.length) % tabs.length], true); }
      });
    });
    // Preselect from the URL hash or the visitor's OS (data-os-tabs).
    var want = location.hash && box.querySelector('[role="tab"][data-key="' + location.hash.slice(1) + '"]');
    if (!want && box.hasAttribute("data-os-tabs")) want = box.querySelector('[role="tab"][data-key="' + detectOS() + '"]');
    select(want || tabs[0]);
  });

  function detectOS() {
    var ua = navigator.userAgent;
    if (/SteamOS|Steam Deck/i.test(ua)) return "deck";
    if (/Windows/i.test(ua)) return "windows";
    if (/iPhone|iPad|iPod/i.test(ua) || (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1)) return "apple";
    if (/Mac OS X|Macintosh/i.test(ua)) return "apple";
    if (/Linux|X11/i.test(ua)) return "linux";
    return "";
  }
  window.NovaOS = detectOS;

  /* ---- Lightbox for [data-lightbox] galleries ---- */
  var groups = document.querySelectorAll("[data-lightbox]");
  if (groups.length) {
    var lb = document.createElement("div");
    lb.className = "lightbox"; lb.setAttribute("role", "dialog"); lb.setAttribute("aria-modal", "true"); lb.setAttribute("aria-label", "Screenshot viewer");
    lb.innerHTML = '<img alt="" /><p></p><button class="lb-close" type="button" aria-label="Close">×</button>' +
      '<button class="lb-prev" type="button" aria-label="Previous">‹</button><button class="lb-next" type="button" aria-label="Next">›</button>';
    document.body.appendChild(lb);
    var img = lb.querySelector("img"), cap = lb.querySelector("p"), items = [], idx = 0, opener = null;
    function show(i) {
      idx = (i + items.length) % items.length;
      var a = items[idx], thumb = a.querySelector("img");
      img.src = a.getAttribute("href"); img.alt = thumb ? thumb.alt : "";
      cap.textContent = a.getAttribute("data-caption") || (thumb ? thumb.alt : "");
    }
    function close() { lb.classList.remove("open"); document.body.style.overflow = ""; if (opener) opener.focus(); }
    groups.forEach(function (g) {
      var list = Array.prototype.slice.call(g.querySelectorAll("a[href]"));
      list.forEach(function (a, i) {
        a.addEventListener("click", function (e) {
          e.preventDefault(); items = list; opener = a; show(i);
          lb.classList.add("open"); document.body.style.overflow = "hidden"; lb.querySelector(".lb-close").focus();
        });
      });
    });
    lb.querySelector(".lb-close").addEventListener("click", close);
    lb.querySelector(".lb-prev").addEventListener("click", function () { show(idx - 1); });
    lb.querySelector(".lb-next").addEventListener("click", function () { show(idx + 1); });
    lb.addEventListener("click", function (e) { if (e.target === lb) close(); });
    document.addEventListener("keydown", function (e) {
      if (!lb.classList.contains("open")) return;
      if (e.key === "Escape") close();
      else if (e.key === "ArrowLeft") show(idx - 1);
      else if (e.key === "ArrowRight") show(idx + 1);
    });
  }
})();
