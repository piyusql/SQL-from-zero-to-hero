// Page-turn animation for chapter navigation.
// mdbook navigates with full page loads, so the turn happens in two halves:
// animate out here, record the direction, then animate in after the load.
(function () {
  "use strict";

  var KEY = "book-turn-direction";
  var MS = 380;

  var reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  function content() {
    return document.querySelector("#mdbook-content") || document.querySelector(".content");
  }

  // --- incoming half: runs on every load -----------------------------------
  var dir = null;
  try { dir = sessionStorage.getItem(KEY); sessionStorage.removeItem(KEY); } catch (e) { /* private mode */ }

  if (dir && !reduced) {
    var el = content();
    if (el) {
      var cls = dir === "back" ? "turning-in-back" : "turning-in-forward";
      el.classList.add(cls);
      setTimeout(function () { el.classList.remove(cls); }, MS + 40);
    }
  }

  // --- outgoing half: intercept navigation ---------------------------------
  function turn(href, direction) {
    var el = content();
    try { sessionStorage.setItem(KEY, direction); } catch (e) { /* ignore */ }

    if (!el || reduced) { window.location.href = href; return; }

    el.classList.add(direction === "back" ? "turning-out-back" : "turning-out-forward");
    // Navigate as the animation finishes so the two halves meet.
    setTimeout(function () { window.location.href = href; }, MS - 60);
  }

  function directionOf(link) {
    return link.classList.contains("previous") ? "back" : "forward";
  }

  // mdbook renders prev/next twice: in the page margins and in the mobile bar.
  document.querySelectorAll("a.nav-chapters, .mobile-nav-chapters a").forEach(function (link) {
    link.addEventListener("click", function (ev) {
      if (ev.metaKey || ev.ctrlKey || ev.shiftKey || ev.button !== 0) return; // let new-tab through
      var href = link.getAttribute("href");
      if (!href) return;
      ev.preventDefault();
      turn(href, directionOf(link));
    });
  });

  // Keyboard arrows drive the same chapter links, so route them through too.
  document.addEventListener("keydown", function (ev) {
    if (ev.metaKey || ev.ctrlKey || ev.altKey) return;
    if (document.activeElement && /INPUT|TEXTAREA/.test(document.activeElement.tagName)) return;

    var sel = ev.key === "ArrowRight" ? "a.nav-chapters.next"
            : ev.key === "ArrowLeft"  ? "a.nav-chapters.previous"
            : null;
    if (!sel) return;

    var link = document.querySelector(sel);
    if (!link) return;
    ev.preventDefault();
    turn(link.getAttribute("href"), ev.key === "ArrowLeft" ? "back" : "forward");
  }, true); // capture, so we run before mdbook's own arrow handler
})();
