// Page-world adapters for dictionary fetch/WebSocket services. They expose
// familiar browser APIs while the isolated bridge retains user authorization.
extension EntryWebView.Coordinator {
    static let dictionaryServiceScript = #"""
    (() => {
      const nativeFetch = window.fetch.bind(window);
      const NativeWebSocket = window.WebSocket;
      const pendingTranslations = new Map();
      const requestPrefix = crypto.getRandomValues(new Uint32Array(4)).join('-');
      let requestSequence = 0;

      class TranslationFailure extends Error {
        constructor(message, status = 502) { super(message); this.status = status; }
      }

      function translationPrompt(messages) {
        const message = Array.isArray(messages) ? messages.findLast(item => item?.role === 'user') : null;
        return typeof message?.content === 'string' ? message.content.trim() : '';
      }

      function safeTranslationMarkup(value, allowDictionaryTags) {
        let text = String(value || '')
          .replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')
          .replaceAll('"', '&quot;').replaceAll("'", '&#39;');
        if (allowDictionaryTags) {
          // OED intentionally round-trips only these three inert markup
          // tags. Everything else stays escaped before jQuery appends it.
          text = text.replace(/&lt;(\/?)(m|n|o)&gt;/gi, '<$1$2>');
        }
        return text;
      }

      addEventListener('lexicon-translation-response', event => {
        let payload;
        try { payload = JSON.parse(String(event.detail || '')); } catch (_) { return; }
        if (!payload || typeof payload !== 'object') return;
        pendingTranslations.get(payload.requestID)?.(
          payload.text, payload.error ? new TranslationFailure(String(payload.error)) : null
        );
      });

      function abortReason(signal) {
        return signal?.reason ?? new DOMException('The translation was cancelled.', 'AbortError');
      }

      // One owner for every request, regardless of its browser API. Settling
      // removes ownership before callbacks run, so late replies and repeated
      // abort/close events cannot complete or cancel it a second time.
      function startTranslation(prompt, signal) {
        if (signal?.aborted) throw abortReason(signal);
        const requestID = `${requestPrefix}-${++requestSequence}`;
        const cancel = (reason = abortReason()) => pendingTranslations.get(requestID)?.(null, reason, true);
        const result = new Promise((resolve, reject) => {
          const onAbort = () => cancel(abortReason(signal));
          const timer = setTimeout(() => cancel(new TranslationFailure('Translation timed out', 504)), 60000);
          pendingTranslations.set(requestID, (text, error, cancelled = false) => {
            pendingTranslations.delete(requestID);
            clearTimeout(timer);
            signal?.removeEventListener('abort', onAbort);
            if (cancelled) window.postMessage({kind:'lexicon-translation-cancel', requestID}, '*');
            if (error !== null) reject(error); else resolve(text);
          });
          signal?.addEventListener('abort', onAbort, {once:true});
          window.postMessage({kind:'lexicon-translation-request', requestID, prompt}, '*');
        });
        return {result, cancel};
      }

      async function fetchTranslation(prompt, signal) {
        try {
          const text = await startTranslation(prompt, signal).result;
          const content = safeTranslationMarkup(text, true);
          const chunk = JSON.stringify({choices:[{delta:{content}}]});
          return new Response(`data: ${chunk}\n\ndata: [DONE]\n\n`, {
            headers:{'Content-Type':'text/event-stream; charset=utf-8'}
          });
        } catch (error) {
          if (!(error instanceof TranslationFailure)) throw error;
          if (error.status === 504) return new Response('', {status:504, statusText:error.message});
          return new Response(JSON.stringify({error:{message:error.message}}), {
            status:502, statusText:'Translation failed',
            headers:{'Content-Type':'application/json'}
          });
        }
      }

      addEventListener('pagehide', () => {
        for (const settle of pendingTranslations.values()) settle(null, abortReason(), true);
      });

      class TranslationWebSocket extends EventTarget {
        constructor(url) {
          super();
          this.url = String(url);
          this.protocol = '';
          this.extensions = '';
          this.binaryType = 'blob';
          this.bufferedAmount = 0;
          this._readyState = NativeWebSocket.CONNECTING;
          this._request = null;
          this.onopen = null;
          this.onmessage = null;
          this.onerror = null;
          this.onclose = null;
          queueMicrotask(() => {
            if (this._readyState !== NativeWebSocket.CONNECTING) return;
            this._readyState = NativeWebSocket.OPEN;
            this._emit('open', new Event('open'));
          });
        }

        get readyState() { return this._readyState; }

        send(data) {
          if (this._readyState !== NativeWebSocket.OPEN) {
            throw new DOMException('WebSocket is not open', 'InvalidStateError');
          }
          if (this._request) {
            this.fail('A translation is already in progress on this connection.'); return;
          }
          let request;
          try { request = JSON.parse(String(data)); } catch (_) { this.fail(); return; }
          const prompt = translationPrompt(request?.payload?.message?.text);
          if (!prompt) { this.fail(); return; }

          const handle = startTranslation(prompt);
          this._request = handle;
          handle.result.then(text => {
            if (this._request !== handle) return;
            this._request = null;
            this.succeed(safeTranslationMarkup(text, false));
          }, error => {
            if (this._request !== handle) return;
            this._request = null;
            if (error?.name === 'AbortError') this.close();
            else this.fail(error.message);
          });
        }

        close(code = 1000, reason = '') {
          if (this._readyState === NativeWebSocket.CLOSED) return;
          this._readyState = NativeWebSocket.CLOSED;
          this._request?.cancel();
          this._request = null;
          this._emit('close', new CloseEvent('close', {code, reason, wasClean:code === 1000}));
        }

        succeed(text) {
          if (this._readyState !== NativeWebSocket.OPEN) return;
          // Match the iFlytek Spark/MAAS response shape consumed by the
          // Longman 6 repack. Its existing renderer remains unchanged.
          const data = JSON.stringify({
            header:{code:0, status:2},
            payload:{choices:{status:2, text:[{role:'assistant', content:text, index:0}]}}
          });
          this._emit('message', new MessageEvent('message', {data}));
          this.close();
        }

        fail(message = 'Translation failed') {
          if (this._readyState === NativeWebSocket.CLOSED) return;
          this._emit('error', new ErrorEvent('error', {message}));
          this.close(1011, message);
        }

        _emit(type, event) {
          this.dispatchEvent(event);
          const handler = this[`on${type}`];
          if (typeof handler === 'function') {
            try { handler.call(this, event); } catch (error) { setTimeout(() => { throw error; }); }
          }
        }
      }

      function isLongmanTranslationSocket(url) {
        try {
          const parsed = new URL(String(url), location.href);
          return parsed.protocol === 'wss:'
            && parsed.hostname.endsWith('.xf-yun.com')
            && parsed.hostname.startsWith('maas-api.')
            && parsed.pathname.endsWith('/chat');
        } catch (_) { return false; }
      }

      function CompatibleWebSocket(url, protocols) {
        if (!new.target) throw new TypeError("Failed to construct 'WebSocket': use 'new'");
        if (isLongmanTranslationSocket(url)) return new TranslationWebSocket(url);
        return protocols === undefined
          ? new NativeWebSocket(url) : new NativeWebSocket(url, protocols);
      }
      CompatibleWebSocket.prototype = NativeWebSocket.prototype;
      Object.defineProperties(CompatibleWebSocket, {
        CONNECTING:{value:NativeWebSocket.CONNECTING}, OPEN:{value:NativeWebSocket.OPEN},
        CLOSING:{value:NativeWebSocket.CLOSING}, CLOSED:{value:NativeWebSocket.CLOSED}
      });
      window.WebSocket = CompatibleWebSocket;

      window.fetch = function(input, init) {
        const request = input instanceof Request ? input : null;
        let url;
        try { url = new URL(request ? request.url : input, location.href); }
        catch (_) { return nativeFetch(input, init); }
        const method = String(init?.method ?? request?.method ?? 'GET').toUpperCase();
        if (url.protocol === 'https:' && url.hostname === 'tts.dxde.de' && method === 'POST') {
          try {
            const body = typeof init?.body === 'string' ? JSON.parse(init.body) : null;
            if (body && typeof body.text === 'string') {
              window.postMessage({
                kind:'lexicon-tts-request',
                detail:JSON.stringify({text:body.text, language:body.language_code})
              }, '*');
              return Promise.resolve(new Response(new Blob([], {type:'audio/mpeg'}), {status:200}));
            }
          } catch (_) {}
        }

        const dashScopeHost = url.hostname === 'dashscope.aliyuncs.com'
          || url.hostname === 'dashscope-intl.aliyuncs.com'
          || url.hostname === 'dashscope-us.aliyuncs.com'
          || url.hostname.endsWith('.maas.aliyuncs.com');
        if (url.protocol === 'https:' && dashScopeHost
            && url.pathname.endsWith('/chat/completions') && method === 'POST') {
          const signal = init?.signal ?? request?.signal;
          if (signal?.aborted) return Promise.reject(abortReason(signal));
          return (async () => {
            let body;
            try {
              const raw = init?.body !== undefined
                ? await new Response(init.body).text()
                : request ? await request.clone().text() : '';
              body = JSON.parse(raw);
            } catch (_) {
              return new Response('', {status:400, statusText:'Invalid translation request'});
            }
            const prompt = translationPrompt(body?.messages);
            if (prompt) {
              // Never forward the dictionary bundle's Authorization header.
              return fetchTranslation(prompt, signal);
            }
            return new Response('', {status:400, statusText:'Invalid translation request'});
          })();
        }
        return nativeFetch(input, init);
      };
    })();
    """#
}
