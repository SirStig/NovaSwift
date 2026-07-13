/* Lightweight parallax starfield + scroll reveals. No dependencies. */
(function () {
  var reduce = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* ---- Starfield ---- */
  var canvas = document.getElementById("stars");
  if (canvas) {
    var ctx = canvas.getContext("2d");
    var stars = [];
    var w, h, dpr;

    function seed() {
      dpr = Math.min(window.devicePixelRatio || 1, 2);
      w = canvas.width = Math.floor(innerWidth * dpr);
      h = canvas.height = Math.floor(innerHeight * dpr);
      canvas.style.width = innerWidth + "px";
      canvas.style.height = innerHeight + "px";
      var count = Math.min(220, Math.floor((innerWidth * innerHeight) / 9000));
      stars = [];
      for (var i = 0; i < count; i++) {
        var layer = Math.random();
        stars.push({
          x: Math.random() * w,
          y: Math.random() * h,
          r: (0.4 + layer * 1.5) * dpr,
          z: 0.25 + layer * 0.9,          // parallax depth
          tw: Math.random() * Math.PI * 2, // twinkle phase
          hue: Math.random() < 0.16 ? "crimson" : "white"
        });
      }
    }

    var scrollY = window.pageYOffset;
    window.addEventListener("scroll", function () { scrollY = window.pageYOffset; }, { passive: true });

    var t = 0;
    function draw() {
      ctx.clearRect(0, 0, w, h);
      t += 0.014;
      for (var i = 0; i < stars.length; i++) {
        var s = stars[i];
        var py = (s.y - scrollY * dpr * s.z * 0.12) % h;
        if (py < 0) py += h;
        var a = reduce ? 0.7 : 0.35 + 0.45 * (0.5 + 0.5 * Math.sin(t * s.z + s.tw));
        ctx.beginPath();
        ctx.arc(s.x, py, s.r, 0, Math.PI * 2);
        if (s.hue === "crimson") {
          ctx.fillStyle = "rgba(255,90,80," + a + ")";
          ctx.shadowColor = "rgba(255,60,70,0.9)";
          ctx.shadowBlur = 6 * dpr;
        } else {
          ctx.fillStyle = "rgba(232,224,214," + a + ")";
          ctx.shadowColor = "rgba(200,190,255,0.5)";
          ctx.shadowBlur = 3 * dpr;
        }
        ctx.fill();
      }
      ctx.shadowBlur = 0;
      if (!reduce) requestAnimationFrame(draw);
    }

    seed();
    draw();
    var rt;
    window.addEventListener("resize", function () {
      clearTimeout(rt);
      rt = setTimeout(function () { seed(); if (reduce) draw(); }, 150);
    });
    if (reduce) draw();
  }

  /* ---- Scroll reveals ---- */
  var reveals = document.querySelectorAll(".reveal");
  if ("IntersectionObserver" in window && !reduce) {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); }
      });
    }, { threshold: 0.12 });
    reveals.forEach(function (el) { io.observe(el); });
  } else {
    reveals.forEach(function (el) { el.classList.add("in"); });
  }
})();
