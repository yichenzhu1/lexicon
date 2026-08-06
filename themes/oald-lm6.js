/* Oxford Advanced Learner's 10 offline behavior for Lexicon.
 * The original 170 KB website/repack script defaults to a compact mode that
 * hides definitions and examples. Mark it initialized before DOM ready, then
 * provide only the interactions needed by the local dictionary. */
(function () {
  "use strict";

  const initialRoots = Array.from(document.querySelectorAll(".leon-oald, .oald"));
  if (!initialRoots.length) return;

  // oald.js checks this attribute at the start of its ready callback. Setting
  // it now prevents network/TTS/configuration code and unstable compact mode.
  initialRoots.forEach((root) => root.setAttribute("script-loaded", "true"));

  function showCoreContent(root) {
    root.classList.remove("compact");
    root.removeAttribute("concise");
    root.classList.add("lexicon-oald-unified");

    root.querySelectorAll(
      ".entry, .sense, .sensetop, .def, .examples, .examples > li, " +
      ".x, .xrefs, .topic-g, deft chn, xt chn, unxt chn, undt chn, ubx chn"
    ).forEach((node) => {
      node.style.removeProperty("display");
      node.style.removeProperty("visibility");
    });

    root.querySelectorAll("a[href^='sound:']").forEach((audio) => {
      audio.removeAttribute("onclick");
    });
  }

  function bindBoxes(root) {
    root.querySelectorAll(".collapse > .unbox").forEach((box) => {
      if (box.dataset.lexiconBound === "true") return;
      const title = Array.from(box.children).find((child) =>
        child.classList && child.classList.contains("box_title")
      );
      const content = title && title.nextElementSibling;
      if (!title || !content) return;

      box.dataset.lexiconBound = "true";
      box.dataset.lexiconCollapsed = "true";
      title.setAttribute("role", "button");
      title.setAttribute("tabindex", "0");
      title.setAttribute("aria-expanded", "false");

      const toggle = (event) => {
        event.preventDefault();
        event.stopImmediatePropagation();
        const collapsed = box.dataset.lexiconCollapsed !== "true";
        box.dataset.lexiconCollapsed = collapsed ? "true" : "false";
        title.setAttribute("aria-expanded", collapsed ? "false" : "true");
      };
      title.addEventListener("click", toggle, true);
      title.addEventListener("keydown", (event) => {
        if (event.key === "Enter" || event.key === " ") toggle(event);
      }, true);
    });
  }

  function bindImages(root) {
    root.querySelectorAll("#ox-enlarge").forEach((container) => {
      if (container.dataset.lexiconBound === "true") return;
      container.dataset.lexiconBound = "true";
      container.setAttribute("role", "button");
      container.setAttribute("tabindex", "0");
      const toggle = (event) => {
        event.preventDefault();
        event.stopImmediatePropagation();
        container.classList.toggle("lexicon-image-expanded");
      };
      container.addEventListener("click", toggle, true);
      container.addEventListener("keydown", (event) => {
        if (event.key === "Enter" || event.key === " ") toggle(event);
      }, true);
    });
  }

  function initialize() {
    document.documentElement.classList.add("lexicon-oald-unified");
    document.querySelectorAll(
      ".oaldk-config-gear, #LA_COLLECT, .chn-control, .examples-control, .more-control"
    ).forEach((node) => node.remove());
    // The repack can replace entry roots while its ready queue drains, so
    // query the live DOM on every pass instead of retaining stale elements.
    document.querySelectorAll(".leon-oald, .oald").forEach((root) => {
      root.setAttribute("script-loaded", "true");
      showCoreContent(root);
      bindBoxes(root);
      bindImages(root);
    });
  }

  // The entry markup has already been parsed when custom.js is loaded, but
  // keep the ready fallback for repacks that relocate scripts into <head>.
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", () => {
      // jQuery's ready queue can run later in the same event dispatch. Repeat
      // after it has drained so any generated compact-mode controls are removed.
      initialize();
      setTimeout(initialize, 0);
      setTimeout(initialize, 250);
    }, { once: true });
  } else {
    initialize();
    setTimeout(initialize, 0);
  }
})();
