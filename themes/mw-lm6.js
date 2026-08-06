/* Merriam-Webster offline behavior for Lexicon.
 * Runs after the repack's script and replaces website-only interactions with
 * small, deterministic controls that work inside the dict:// iframe. */
(function () {
  "use strict";

  if (!document.querySelector("karxdict")) return;

  // prepare_mw() queues an online jQuery .load() before DOM ready. Intercept
  // only remote loads; keep ordinary event shorthand and local loads intact.
  if (window.jQuery && window.jQuery.fn && window.jQuery.fn.load) {
    const originalLoad = window.jQuery.fn.load;
    window.jQuery.fn.load = function (url) {
      if (typeof url === "string" && /^https?:\/\//i.test(url)) return this;
      return originalLoad.apply(this, arguments);
    };
  }

  function cleanWebsiteArtifacts() {
    document.querySelectorAll("#zz, .mwswitch").forEach((node) => node.remove());
    document.querySelectorAll(".thread-anchor, a.vg-sseq-entry-item-thread-anchor")
      .forEach((anchor) => anchor.removeAttribute("href"));
    document.querySelectorAll("a[href='']").forEach((anchor) => {
      anchor.removeAttribute("href");
    });
    document.querySelectorAll("img[height], img[width]").forEach((image) => {
      image.removeAttribute("height");
      image.removeAttribute("width");
    });
    document.querySelectorAll("a[href^='sound:']").forEach((audio) => {
      // The native navigation delegate handles sound:// from the local MDD.
      audio.removeAttribute("onclick");
    });
  }

  function bindSections() {
    const initiallyClosed = new Set([
      "examples",
      "word-history",
      "related-phrases",
      "synonyms",
      "little-gems",
      "synonym-discussion",
      "faqs",
      "kidsdictionary",
      "legalDictionary",
      "geographicalDictionary",
      "medicalDictionary",
      "biographicalDictionary"
    ]);

    document.querySelectorAll(".content-section-with-header").forEach((section) => {
      if (section.dataset.lexiconBound === "true") return;
      const header = Array.from(section.children).find((child) =>
        child.matches(".content-section-header, .content-section-sub-header")
      );
      const body = Array.from(section.children).find((child) =>
        child.matches(".content-section-body")
      );
      if (!header || !body) return;

      section.dataset.lexiconBound = "true";
      section.dataset.lexiconCollapsed = initiallyClosed.has(section.id)
        ? "true"
        : "false";
      header.setAttribute("role", "button");
      header.setAttribute("tabindex", "0");
      header.setAttribute(
        "aria-expanded",
        section.dataset.lexiconCollapsed === "true" ? "false" : "true"
      );

      const toggle = (event) => {
        event.preventDefault();
        event.stopImmediatePropagation();
        const collapsed = section.dataset.lexiconCollapsed !== "true";
        section.dataset.lexiconCollapsed = collapsed ? "true" : "false";
        header.setAttribute("aria-expanded", collapsed ? "false" : "true");
      };
      header.addEventListener("click", toggle, true);
      header.addEventListener("keydown", (event) => {
        if (event.key === "Enter" || event.key === " ") toggle(event);
      }, true);
    });
  }

  function initialize() {
    document.documentElement.classList.add("lexicon-mw-unified");
    if (window.jQuery) {
      // Remove click handlers installed by mw.js before binding ours.
      window.jQuery(".content-section-header, .content-section-sub-header").off("click");
    }
    cleanWebsiteArtifacts();
    bindSections();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", () => {
      setTimeout(initialize, 0);
      setTimeout(cleanWebsiteArtifacts, 300);
      setTimeout(cleanWebsiteArtifacts, 1000);
    }, { once: true });
  } else {
    initialize();
  }
})();
