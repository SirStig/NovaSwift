/* Live data for the site, all read straight from public GitHub files:
   - releases      GitHub Releases API (news + download buttons)
   - servers.json  the public server directory (NovaSwift-Plugins)
   - status.json   last probe of every listed server (written by a scheduled
                   workflow in NovaSwift-Plugins; browsers can't send the UDP
                   status query themselves)
   - catalog.json  the community plug-in catalog
   Everything is escaped before it reaches the page: these files take
   community pull requests. Every widget degrades to a plain link. */
(function () {
  "use strict";

  var RAW = "https://raw.githubusercontent.com/SirStig/NovaSwift-Plugins/";
  var SRC = {
    releases: "https://api.github.com/repos/SirStig/NovaSwift/releases?per_page=10",
    servers: RAW + "main/servers/servers.json",
    status: RAW + "status/status.json",
    catalog: RAW + "main/catalog.json"
  };
  var REGIONS = { "na-east": "N. America East", "na-west": "N. America West", sa: "South America", eu: "Europe", af: "Africa", me: "Middle East", as: "Asia", oc: "Oceania", global: "Global" };
  var RULES = { safe: "Safe (no real PvP losses)", full: "Full stakes", custom: "Custom rules" };

  function esc(s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }
  function safeURL(u) { return /^https:\/\//i.test(u || "") ? esc(u) : ""; }
  function mb(bytes) { return bytes ? (bytes / 1048576).toFixed(bytes > 104857600 ? 0 : 1) + " MB" : ""; }
  function date(s) {
    var d = new Date(s); if (isNaN(d)) return "";
    return d.toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" });
  }
  function ago(s) {
    var m = Math.round((Date.now() - new Date(s)) / 60000);
    if (!(m >= 0)) return "";
    if (m < 2) return "just now";
    if (m < 60) return m + " min ago";
    var h = Math.round(m / 60); if (h < 48) return h + " h ago";
    return Math.round(h / 24) + " days ago";
  }

  /* fetch JSON with a short session cache so page hops don't refetch */
  var memo = {};
  function getJSON(key) {
    if (memo[key]) return memo[key];
    var ck = "nova:" + key, hit = null;
    try { hit = JSON.parse(sessionStorage.getItem(ck) || "null"); } catch (e) {}
    if (hit && Date.now() - hit.t < 5 * 60000) return (memo[key] = Promise.resolve(hit.v));
    memo[key] = fetch(SRC[key], { cache: "no-cache" }).then(function (r) {
      if (!r.ok) throw new Error(key + " " + r.status);
      return r.json();
    }).then(function (v) {
      try { sessionStorage.setItem(ck, JSON.stringify({ t: Date.now(), v: v })); } catch (e) {}
      return v;
    });
    return memo[key];
  }

  /* ================= Releases ================= */
  function pickAsset(release, kind) {
    var tests = {
      linux: /linux.*\.(tar\.gz|tgz|zip|AppImage)$/i,
      windows: /windows.*\.(zip|exe|msi)$/i,
      "macos-godot": /macos.*\.(zip|dmg)$/i,
      "server-linux": /server.*linux.*\.(tar\.gz|tgz|zip)$/i,
      "server-windows": /server.*windows.*\.(zip|exe|msi)$/i,
      "server-macos": /server.*macos.*\.(zip|tar\.gz|dmg)$/i
    };
    var re = tests[kind]; if (!re) return null;
    var isServer = /^server/.test(kind);
    return (release.assets || []).filter(function (a) {
      return re.test(a.name) && (isServer || !/server/i.test(a.name));
    })[0] || null;
  }

  function wireDownloads(releases) {
    document.querySelectorAll("[data-asset]").forEach(function (el) {
      var kind = el.getAttribute("data-asset");
      for (var i = 0; i < releases.length; i++) {
        if (releases[i].draft) continue;
        var a = pickAsset(releases[i], kind);
        if (a) {
          el.href = a.browser_download_url;
          el.removeAttribute("aria-disabled");
          var label = el.querySelector("[data-label]");
          if (label && el.hasAttribute("data-ready")) label.textContent = el.getAttribute("data-ready");
          var meta = document.querySelector('[data-asset-meta="' + kind + '"]');
          if (meta) meta.textContent = releases[i].tag_name + " · " + a.name + " · " + mb(a.size);
          return;
        }
      }
    });
  }

  function renderNews(box, releases) {
    var n = parseInt(box.getAttribute("data-releases"), 10) || 3;
    var list = releases.filter(function (r) { return !r.draft; }).slice(0, n);
    if (!list.length) return;
    box.innerHTML = list.map(function (r) {
      var body = (r.body || "").replace(/\r/g, "").split("\n")
        .map(function (l) { return l.replace(/^[#>*\-\s]+/, "").replace(/[*_`]/g, "").replace(/\[([^\]]+)\]\([^)]+\)/g, "$1").trim(); })
        .filter(function (l) { return l.length > 30; })[0] || "";
      if (body.length > 220) body = body.slice(0, 217).replace(/\s+\S*$/, "") + "…";
      return '<article><time datetime="' + esc(r.published_at) + '">' + esc(date(r.published_at)) +
        (r.prerelease ? ' · <span class="badge warn">Beta</span>' : "") + "</time>" +
        "<h3>" + esc(r.name || r.tag_name) + "</h3>" +
        (body ? "<p>" + esc(body) + "</p>" : "") +
        '<a class="more" href="' + safeURL(r.html_url) + '" target="_blank" rel="noopener">Release notes →</a></article>';
    }).join("");
  }

  if (document.querySelector("[data-asset], [data-releases]")) {
    getJSON("releases").then(function (rel) {
      if (!Array.isArray(rel)) return;
      wireDownloads(rel);
      document.querySelectorAll("[data-releases]").forEach(function (b) { renderNews(b, rel); });
      document.querySelectorAll("[data-latest-version]").forEach(function (el) {
        var r = rel.filter(function (x) { return !x.draft; })[0];
        if (r) el.textContent = r.tag_name;
      });
    }).catch(function () {});
  }

  /* ================= Servers ================= */
  function loadServers() {
    return Promise.all([
      getJSON("servers"),
      getJSON("status").catch(function () { return null; })
    ]).then(function (v) {
      var dir = (v[0] && Array.isArray(v[0].servers)) ? v[0].servers : [];
      var st = v[1] && v[1].servers ? v[1] : null;
      dir.forEach(function (s) { s._st = st ? st.servers[s.id] || { online: false } : null; });
      return { list: dir, status: st };
    });
  }

  function serverRow(s) {
    var st = s._st, online = st && st.online;
    var state = !st ? '<span class="badge">Status unknown</span>'
      : online ? '<span class="badge ok"><span class="dot ok"></span>Online</span>'
      : '<span class="badge bad">Offline</span>';
    var addr = esc(s.host) + (s.port && s.port !== 53735 ? ":" + esc(s.port) : "");
    var players = online ? '<div class="players">' + esc(st.players | 0) + "<small> / " + esc(st.max || s.maxPlayers) + "</small></div>"
      : '<div class="players"><small>max ' + esc(s.maxPlayers) + "</small></div>";
    var plugins = (s.plugins || []).map(function (p) { return esc(p.name || p.id); }).join(", ");
    var facts = [
      "<span><b>Region</b> " + esc(REGIONS[s.region] || s.region) + "</span>",
      "<span><b>Rules</b> " + esc(RULES[s.rules] || s.rules) + "</span>",
      "<span><b>Plug-ins</b> " + (plugins || "None (stock EV Nova)") + "</span>",
      st && st.ver ? "<span><b>Version</b> " + esc(st.ver) + "</span>" : "",
      st && st.pw ? "<span><b>Password</b> required</span>" : "",
      s.owner ? "<span><b>Host</b> " + esc(s.owner.name) + "</span>" : "",
      s.website && safeURL(s.website) ? '<span><a href="' + safeURL(s.website) + '" target="_blank" rel="noopener nofollow">Website</a></span>' : ""
    ].join("");
    return '<article class="server' + (st && !online ? " offline" : "") + '" data-region="' + esc(s.region) + '">' +
      "<div><h3>" + esc(s.name) + " " + state + "</h3>" +
      (s.description ? "<p>" + esc(s.description) + "</p>" : "") +
      '<div class="facts">' + facts + "</div></div>" +
      '<div class="right">' + players + '<span class="addr" title="Paste this into Join in the game">' + addr + "</span>" +
      '<button class="btn btn-ghost sm" type="button" data-copy="' + addr + '">Copy address</button></div></article>';
  }

  function serverBrowser(box) {
    var listEl = box.querySelector(".server-list");
    var q = box.querySelector('input[type="search"]');
    var region = box.querySelector("select[name=region]");
    var onlyOnline = box.querySelector("input[name=online]");
    var note = box.querySelector("[data-status-note]");
    var data = [];

    function draw() {
      var term = (q && q.value || "").toLowerCase();
      var reg = region ? region.value : "";
      var shown = data.filter(function (s) {
        if (reg && s.region !== reg) return false;
        if (onlyOnline && onlyOnline.checked && !(s._st && s._st.online)) return false;
        if (term && (s.name + " " + s.description + " " + s.host).toLowerCase().indexOf(term) < 0) return false;
        return true;
      }).sort(function (a, b) {
        var ao = a._st && a._st.online ? 1 : 0, bo = b._st && b._st.online ? 1 : 0;
        if (ao !== bo) return bo - ao;
        var ap = a._st ? a._st.players | 0 : 0, bp = b._st ? b._st.players | 0 : 0;
        return bp - ap || String(a.name).localeCompare(b.name);
      });
      if (!data.length) {
        listEl.innerHTML = '<div class="empty"><h3>No public servers listed yet</h3>' +
          "<p>The directory is brand new. Be the first: run a dedicated server and open a pull request to list it.</p>" +
          '<p><a class="btn btn-primary sm" href="dedicated-server.html">Host a server</a> <a class="btn btn-ghost sm" href="https://github.com/SirStig/NovaSwift-Plugins/tree/main/servers" target="_blank" rel="noopener">How listing works</a></p></div>';
        return;
      }
      listEl.innerHTML = shown.length ? shown.map(serverRow).join("")
        : '<div class="empty"><p>No servers match these filters.</p></div>';
    }

    listEl.addEventListener("click", function (e) {
      var b = e.target.closest("[data-copy]"); if (!b || !navigator.clipboard) return;
      navigator.clipboard.writeText(b.getAttribute("data-copy")).then(function () {
        b.textContent = "Copied"; setTimeout(function () { b.textContent = "Copy address"; }, 1500);
      });
    });
    [q, region, onlyOnline].forEach(function (el) { if (el) el.addEventListener("input", draw); });

    loadServers().then(function (r) {
      data = r.list;
      if (note) note.textContent = r.status
        ? "Status checked " + ago(r.status.updated) + ". In the game, the Public tab pings each server live."
        : "Live status isn't available right now. In the game, the Public tab pings each server live.";
      draw();
    }).catch(function () {
      listEl.innerHTML = '<div class="empty"><p>Couldn\'t load the server list. <a href="https://github.com/SirStig/NovaSwift-Plugins/blob/main/servers/servers.json" target="_blank" rel="noopener">View it on GitHub</a>.</p></div>';
    });
  }
  document.querySelectorAll("[data-servers]").forEach(serverBrowser);

  /* ================= Plug-in catalog ================= */
  function pluginCard(p) {
    var ico = safeURL(p.iconURL);
    var pic = ico ? '<img src="' + ico + '" alt="" loading="lazy" referrerpolicy="no-referrer" onerror="this.remove()" />' : "";
    var initial = esc((p.name || "?").replace(/^the\s+/i, "").charAt(0).toUpperCase());
    var tags = (p.isTotalConversion ? ['<span class="tc">Total conversion</span>'] : [])
      .concat((p.tags || []).slice(0, 4).map(function (t) { return "<span>" + esc(t) + "</span>"; })).join("");
    var home = safeURL(p.homepageURL);
    return '<article class="plugin"><header><div class="pic">' + (pic || initial) + "</div><div>" +
      "<h3>" + esc(p.name) + "</h3>" +
      '<div class="by">by ' + esc(p.author || "unknown") + (p.version ? " · v" + esc(p.version) : "") + "</div></div></header>" +
      "<p>" + esc(p.summary || "") + "</p>" +
      '<div class="tags">' + tags + "</div>" +
      "<footer><span>" + esc(mb(p.sizeBytes)) + "</span>" +
      (home ? '<a href="' + home + '" target="_blank" rel="noopener nofollow">Homepage</a>' : "") + "</footer></article>";
  }

  function catalogBrowser(box) {
    var grid = box.querySelector(".plugin-grid");
    var q = box.querySelector('input[type="search"]');
    var sort = box.querySelector("select[name=sort]");
    var chips = box.querySelector(".chips");
    var count = box.querySelector("[data-count-shown]");
    var all = [], filter = "all";

    function draw() {
      var term = (q && q.value || "").toLowerCase();
      var shown = all.filter(function (p) {
        if (filter === "tc" && !p.isTotalConversion) return false;
        if (filter !== "all" && filter !== "tc" && (p.tags || []).indexOf(filter) < 0) return false;
        if (!term) return true;
        return (p.name + " " + p.author + " " + p.summary + " " + (p.tags || []).join(" ")).toLowerCase().indexOf(term) >= 0;
      });
      var how = sort ? sort.value : "popular";
      shown.sort(function (a, b) {
        if (how === "name") return String(a.name).localeCompare(b.name);
        if (how === "new") return String(b.addedDate || "").localeCompare(a.addedDate || "");
        return (b.popularity || 0) - (a.popularity || 0);
      });
      grid.innerHTML = shown.length ? shown.map(pluginCard).join("") : '<div class="empty"><p>No plug-ins match.</p></div>';
      if (count) count.textContent = shown.length + " of " + all.length;
    }

    getJSON("catalog").then(function (c) {
      all = (c && c.plugins) || [];
      if (chips) {
        var tally = {};
        all.forEach(function (p) { (p.tags || []).forEach(function (t) { tally[t] = (tally[t] || 0) + 1; }); });
        var top = Object.keys(tally).sort(function (a, b) { return tally[b] - tally[a]; }).slice(0, 9);
        chips.innerHTML = '<button type="button" data-f="all" aria-pressed="true">All</button>' +
          '<button type="button" data-f="tc" aria-pressed="false">Total conversions</button>' +
          top.map(function (t) { return '<button type="button" data-f="' + esc(t) + '" aria-pressed="false">' + esc(t) + "</button>"; }).join("");
        chips.addEventListener("click", function (e) {
          var b = e.target.closest("button"); if (!b) return;
          filter = b.getAttribute("data-f");
          chips.querySelectorAll("button").forEach(function (x) { x.setAttribute("aria-pressed", String(x === b)); });
          draw();
        });
      }
      draw();
    }).catch(function () {
      grid.innerHTML = '<div class="empty"><p>Couldn\'t load the catalog. <a href="https://github.com/SirStig/NovaSwift-Plugins" target="_blank" rel="noopener">Browse it on GitHub</a>.</p></div>';
    });
    [q, sort].forEach(function (el) { if (el) el.addEventListener("input", draw); });
  }
  document.querySelectorAll("[data-catalog]").forEach(catalogBrowser);

  /* ================= Counters ================= */
  var counters = document.querySelectorAll("[data-count]");
  if (counters.length) {
    var need = {};
    counters.forEach(function (el) { need[el.getAttribute("data-count")] = true; });
    if (need.plugins) getJSON("catalog").then(function (c) {
      document.querySelectorAll('[data-count="plugins"]').forEach(function (el) { el.textContent = ((c && c.plugins) || []).length; });
    }).catch(function () {});
    if (need.servers || need.online || need.players) loadServers().then(function (r) {
      var online = r.list.filter(function (s) { return s._st && s._st.online; });
      var players = online.reduce(function (n, s) { return n + (s._st.players | 0); }, 0);
      var vals = { servers: r.list.length, online: r.status ? online.length : "–", players: r.status ? players : "–" };
      Object.keys(vals).forEach(function (k) {
        document.querySelectorAll('[data-count="' + k + '"]').forEach(function (el) { el.textContent = vals[k]; });
      });
    }).catch(function () {});
  }
})();
