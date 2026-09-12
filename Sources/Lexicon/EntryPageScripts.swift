import WebKit

// The isolated bridge owns native permissions; page-world adapters own browser
// API compatibility. Neither participates in the native view lifecycle.
extension EntryWebView.Coordinator {
    static let bridgeScript = #"""
    (() => {
      const send = payload => {
        try {
          webkit.messageHandlers.lexiconBridge.postMessage(Object.assign({}, payload, {
            dictionaryRoot:window !== top && parent === top
          }));
        } catch (_) {}
      };
      const host = location.hostname.toLowerCase();
      const ready = callback => document.readyState === 'loading'
        ? addEventListener('DOMContentLoaded', callback, {once:true}) : callback();

      if (host === 'page') {
        ready(() => {
          document.querySelectorAll('details[data-uuid]').forEach(card => {
            card.addEventListener('toggle', () => send({kind:'collapse', dictionaryUUID:card.dataset.uuid,
              collapsed:!card.open}));
          });
        });
        return;
      }

      function scrollToAnchor(anchor, behavior = 'auto') {
        const target = document.getElementById(anchor) || document.getElementsByName(anchor)[0];
        if (target) send({kind:'scroll', mode:'element', offset:target.getBoundingClientRect().top, behavior});
      }
      window.__lexiconScrollToAnchor = scrollToAnchor;
      let scheduled = false, scheduledDeep = false, settleTimer = 0;
      let lastFlowSent = -1, lastVisualSent = -1;
      let lastTrustedClick = -Infinity;
      let translationUsedForClick = false;
      addEventListener('click', event => {
        if (event.isTrusted) {
          lastTrustedClick = performance.now();
          translationUsedForClick = false;
        }
      }, true);
      function forwardTTSRequest(detail) {
        // Page scripts cannot invoke the native bridge directly. Accept a
        // compatibility request only immediately after a real user click.
        if (performance.now() - lastTrustedClick > 2000) return;
        let request;
        try { request = JSON.parse(String(detail || '')); } catch (_) { return; }
        const text = String(request.text || '').trim();
        const language = String(request.language || '').toLowerCase() === 'en-gb'
          ? 'en-GB' : 'en-US';
        if (!text || new TextEncoder().encode(text).length > 5000) return;
        send({kind:'tts', text, language});
      }
      function forwardTranslationRequest(request) {
        // One translation per physical click. The page selects the passage;
        // the isolated world authorizes native work.
        const requestID = typeof request.requestID === 'string' ? request.requestID : '';
        const prompt = typeof request.prompt === 'string' ? request.prompt.trim() : '';
        if (!/^[A-Za-z0-9-]{1,80}$/.test(requestID)) return;
        let error;
        if (!prompt || new TextEncoder().encode(prompt).length > 20000) {
          error = 'This dictionary passage is empty or too long to translate.';
        } else if (translationUsedForClick || performance.now() - lastTrustedClick > 2000) {
          error = 'Click the passage again to translate.';
        }
        if (error) {
          window.dispatchEvent(new CustomEvent('lexicon-translation-response', {
            detail:JSON.stringify({requestID, error})
          }));
          return;
        }
        translationUsedForClick = true;
        send({kind:'translation', requestID, prompt});
      }
      function measure(deep) {
        scheduled = false;
        deep = deep === true || scheduledDeep;
        scheduledDeep = false;
        const root = document.documentElement, body = document.body;
        if (!root || !body) return;
        // Measure the body's own box, never scrollHeight/offsetHeight:
        // those never drop below the viewport, so they feed the frame's
        // current height back into the measurement — pinning the frame
        // too tall when content shrinks, or oscillating between the
        // viewport size and the content size and shaking the page.
        const bodyRect = body.getBoundingClientRect();
        const flowHeight = Math.ceil(bodyRect.height);
        // Keep a previously measured overlay open through the resize event
        // caused by enlarging its iframe. Attribute/mutation events request
        // a deep measurement immediately, so closing it still shrinks on
        // the next animation frame.
        let visualHeight = !deep && lastFlowSent >= 0
          && Math.abs(flowHeight - lastFlowSent) < 2
          ? Math.max(flowHeight, lastVisualSent) : flowHeight;
        if (deep) {
          // DOMRect coordinates already include the body's padding. Scan
          // for positioned overflow relative to the body, but do not add
          // paddingBottom again: doing so made the fast and settled paths
          // alternate forever by exactly the 14px wrapper padding.
          let bottom = bodyRect.bottom;
          // Descendants of an overflow-clipping box (line-clamped fold
          // boxes, nested scrollboxes) keep their laid-out client rects
          // even where the box clips them away. Counting that invisible
          // overflow made the settled height thousands of points taller
          // than the body box on OED entries, so the fast and settled
          // paths alternated forever and the resize compensation bounced
          // the outer page on every scroll.
          const clipBottoms = new Map();
          // A bottom-anchored fixed subtree moves when its iframe is made
          // taller. Normalize it back to the flow viewport so measuring
          // the overlay cannot recursively grow the frame.
          const fixedShifts = new Map();
          document.querySelectorAll('*').forEach(element => {
            const style = getComputedStyle(element);
            let fixedShift = fixedShifts.get(element.parentElement) || 0;
            if (style.position === 'fixed') {
              fixedShift = style.top === 'auto' && style.bottom !== 'auto'
                ? Math.max(0, innerHeight - flowHeight) : 0;
              fixedShifts.set(element, fixedShift);
            } else if (fixedShifts.has(element.parentElement)) {
              fixedShifts.set(element, fixedShift);
            }
            if (style.overflowY !== 'visible') {
              clipBottoms.set(element, element.getBoundingClientRect().bottom - fixedShift);
            }
            if (style.visibility === 'hidden') return;
            for (const rect of element.getClientRects()) {
              const rectBottom = rect.bottom - fixedShift;
              if (rectBottom <= bottom) continue;
              let clipped = false;
              for (let p = element.parentElement; p && p !== body; p = p.parentElement) {
                const clipBottom = clipBottoms.get(p);
                if (clipBottom !== undefined && rectBottom > clipBottom + 1) {
                  clipped = true;
                  break;
                }
              }
              if (!clipped) bottom = rectBottom;
            }
          });
          visualHeight = Math.max(flowHeight, Math.ceil(bottom - bodyRect.top));
        }
        // Sub-2px churn is ignored: resizing the frame re-fires this very
        // measurement, so tiny deltas would ping-pong the frame height
        // and visibly twitch the card.
        const roundedFlow = Math.ceil(flowHeight);
        const roundedVisual = Math.ceil(visualHeight);
        if (lastFlowSent >= 0 && Math.abs(roundedFlow - lastFlowSent) < 2
            && Math.abs(roundedVisual - lastVisualSent) < 2) return;
        lastFlowSent = roundedFlow;
        lastVisualSent = roundedVisual;
        send({kind:'height', flowHeight:roundedFlow, visualHeight:roundedVisual});
      }
      function requestMeasure(deepSoon) {
        scheduledDeep ||= deepSoon === true;
        if (!scheduled) { scheduled = true; requestAnimationFrame(() => measure(false)); }
        clearTimeout(settleTimer); settleTimer = setTimeout(() => measure(true), 240);
      }
      ready(() => {
        new ResizeObserver(() => requestMeasure(false)).observe(document.documentElement);
        if (document.body) {
          new ResizeObserver(() => requestMeasure(false)).observe(document.body);
          new MutationObserver(records => requestMeasure(records.some(record =>
            record.type === 'attributes' || record.type === 'childList'))).observe(document.body,
            {subtree:true, childList:true, attributes:true, characterData:true});
        }
        document.querySelectorAll('img,video,audio').forEach(item => {
          item.addEventListener('load', () => requestMeasure(true));
          item.addEventListener('error', () => requestMeasure(true));
        });
        document.fonts?.ready.then(() => requestMeasure(true));
        ['click','toggle','input','change','transitionend','animationend'].forEach(name =>
          document.addEventListener(name, () => requestMeasure(true), true));
        requestMeasure(true);
        const anchor = new URLSearchParams(location.search).get('anchor');
        if (anchor) setTimeout(() => scrollToAnchor(anchor), 80);
      });
      addEventListener('resize', () => requestMeasure(false));
      visualViewport?.addEventListener('resize', () => requestMeasure(false));
      addEventListener('message', event => {
        if (event.source === window && event.data?.kind === 'lexicon-tts-request') {
          forwardTTSRequest(event.data.detail);
          return;
        }
        if (event.source === window && event.data?.kind === 'lexicon-translation-request') {
          forwardTranslationRequest(event.data);
          return;
        }
        if (event.source === window && event.data?.kind === 'lexicon-translation-cancel'
            && typeof event.data.requestID === 'string'
            && /^[A-Za-z0-9-]{1,80}$/.test(event.data.requestID)) {
          send({kind:'translationCancel', requestID:event.data.requestID});
          return;
        }
        if (event.data?.kind !== 'lexicon-anchor' || typeof event.data.anchor !== 'string') return;
        scrollToAnchor(event.data.anchor);
      });

      addEventListener('click', event => {
        if (!event.isTrusted) return;
        const link = event.target?.closest?.('a[href],area[href]');
        if (!link) return;
        const href = (link.getAttribute('href') || '').trim();
        const lower = href.toLowerCase();
        if (href.startsWith('#') || lower.startsWith('entry://#') || lower.startsWith('bword://#')) {
          const raw = href.startsWith('#') ? href.slice(1) : href.slice(href.indexOf('#') + 1);
          let id = raw; try { id = decodeURIComponent(raw); } catch (_) {}
          scrollToAnchor(id, getComputedStyle(document.documentElement).scrollBehavior);
          event.preventDefault(); event.stopImmediatePropagation(); return;
        }
        const scheme = href.includes(':') ? href.slice(0, href.indexOf(':')).toLowerCase() : '';
        if (['entry','bword','sound','http','https','mailto'].includes(scheme)) {
          event.preventDefault(); event.stopImmediatePropagation(); send({kind:'link', href});
        }
      }, true);
      addEventListener('dblclick', event => {
        if (!event.isTrusted || event.target?.closest?.('a[href],input,textarea,select,[contenteditable]')) return;
        const word = String(getSelection()?.toString() || '').trim();
        if (word && word.length <= 64 && !/\s/.test(word)) send({kind:'lookup', word});
      }, true);
      addEventListener('wheel', event => {
        if (!event.deltaX && !event.deltaY) return;
        send({kind:'scroll', mode:'by', offset:event.deltaY}); event.preventDefault();
      }, {passive:false, capture:true});
      addEventListener('keydown', event => {
        if (!event.isTrusted || event.defaultPrevented || event.metaKey || event.ctrlKey || event.altKey
            || event.target?.matches?.('input,textarea,select,[contenteditable]')) return;
        const page = Math.max(120, innerHeight * .85);
        if (event.key === 'PageDown') send({kind:'scroll', mode:'by', offset:page});
        else if (event.key === 'PageUp') send({kind:'scroll', mode:'by', offset:-page});
        else if (event.key === 'Home') send({kind:'scroll', mode:'home'});
        else if (event.key === 'End') send({kind:'scroll', mode:'end'});
        else return;
        event.preventDefault();
      }, true);
      addEventListener('lexicon-scroll-request', event => {
        const detail = event.detail || {};
        send({kind:'scroll', mode:detail.kind === 'by' ? 'by' : 'element', offset:detail.value || 0,
          behavior:detail.behavior || 'auto'});
      });
    })();
    """#

    /// Compatibility adapters for optional services embedded by common
    /// dictionary repacks. Requests are intercepted before credentials or
    /// text can leave the page, then handed to the isolated native bridge.
    static let dictionaryCompatibilityScript = #"""
    (() => {
      if (!Number.isFinite(Number(window.__lexiconVirtualScrollY))) {
        window.__lexiconVirtualScrollY = 0;
      }
      if (!Number.isFinite(Number(window.__lexiconVirtualViewportHeight))) {
        window.__lexiconVirtualViewportHeight = window.innerHeight;
      }

      // Dictionary pages live in full-content-height iframes, so their
      // native window scroll offset is always zero even while the outer
      // results page is far down the entry. jQuery-based dictionaries use
      // $(window).scrollTop() around fold/show operations to keep the
      // clicked control stationary. Feed those calls the outer page's
      // dictionary-local offset and route setters back through the narrow
      // scroll compatibility shim.
      function installJQueryScrollAdapter() {
        const jq = window.jQuery;
        if (!jq?.fn || typeof jq.fn.scrollTop !== 'function') return false;
        if (!jq.fn.scrollTop.__lexiconVirtualScroll) {
          const originalScrollTop = jq.fn.scrollTop;
          function adaptedScrollTop(value) {
            const target = this[0];
            const isViewport = target === window || target === document;
            if (!isViewport) return originalScrollTop.apply(this, arguments);
            if (!arguments.length) return Number(window.__lexiconVirtualScrollY) || 0;
            const top = Number(value);
            const current = Number(window.__lexiconVirtualScrollY) || 0;
            const delta = top - current;
            // jQuery dictionaries use a getter/setter pair around a DOM
            // mutation to preserve the clicked control. Treat the result
            // as a relative correction: interpreting it as an absolute
            // iframe offset is what sent the outer page back toward the
            // dictionary's top when WebKit reported a stale zero.
            if (Number.isFinite(delta) && Math.abs(delta) > .5) {
              window.__lexiconVirtualScrollY = top;
              window.scrollBy({top:delta, left:0, behavior:'auto'});
            }
            return this;
          }
          Object.defineProperty(adaptedScrollTop, '__lexiconVirtualScroll', {value:true});
          jq.fn.scrollTop = adaptedScrollTop;
        }
        if (typeof jq.fn.height === 'function' && !jq.fn.height.__lexiconVirtualViewport) {
          const originalHeight = jq.fn.height;
          function adaptedHeight(value) {
            const target = this[0];
            if (!arguments.length && (target === window || target === document)) {
              return Number(window.__lexiconVirtualViewportHeight) || window.innerHeight;
            }
            return originalHeight.apply(this, arguments);
          }
          Object.defineProperty(adaptedHeight, '__lexiconVirtualViewport', {value:true});
          jq.fn.height = adaptedHeight;
        }
        return true;
      }

      let jqueryInstallAttempts = 0;
      const jqueryInstallTimer = setInterval(() => {
        jqueryInstallAttempts += 1;
        if (installJQueryScrollAdapter() || jqueryInstallAttempts >= 200) {
          clearInterval(jqueryInstallTimer);
        }
      }, 50);
      addEventListener('DOMContentLoaded', installJQueryScrollAdapter, {once:true});
      function receiveScrollState(offset, viewportHeight) {
        const next = Number(offset);
        const viewport = Number(viewportHeight);
        if (!Number.isFinite(next) || next < 0) return;
        const changed = Math.abs(next - Number(window.__lexiconVirtualScrollY)) > .5;
        window.__lexiconVirtualScrollY = next;
        if (Number.isFinite(viewport) && viewport > 0) {
          window.__lexiconVirtualViewportHeight = viewport;
        }
        installJQueryScrollAdapter();
        if (changed) dispatchEvent(new Event('scroll'));
      }
      Object.defineProperty(window, '__lexiconReceiveScrollState', {
        value:receiveScrollState, configurable:true
      });

    })();
    """# + dictionaryServiceScript
}
