/*
 * network_shim.js —— 在页面脚本之前注入（WKUserScript atDocumentStart）
 *
 * 两个作用：
 *  1) 协议采集（mode=log）：把游戏发往服务器的 XHR / fetch / WebSocket 请求
 *     全部转发到原生日志（Xcode 控制台），用于离线化时还原接口。
 *  2) 单机打桩（mode=mock）：拦截发往 youxigu/tanwan 等游戏域的请求，
 *     直接返回本地构造的 JSON，从而在无服务器时也能跑。
 *
 * 切换方式（二选一）：
 *   - 原生侧设置：在 Swift 注入前执行 evaluateJavaScript("localStorage.setItem('qxzb_mode','mock')")
 *   - 页面控制台：window.__qxzb.setMode('mock' | 'log')
 *
 * 默认 mode=log：真实联网可玩，同时把协议打进 Xcode 控制台。
 */
(function () {
  'use strict';

  var NATIVE = (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.log) || null;
  function log() {
    var parts = Array.prototype.slice.call(arguments);
    if (NATIVE) { try { NATIVE.postMessage(parts.join(' ')); return; } catch (e) {} }
    try { console.log.apply(console, ['[shim]'].concat(parts)); } catch (e) {}
  }

  var CFG = window.__QXZB_SHIM__ || {};
  var MODE = (function () {
    try { return (localStorage.getItem('qxzb_mode') || CFG.mode || 'log'); }
    catch (e) { return CFG.mode || 'log'; }
  })();

  var GAME_HOST = /youxigu\.com|tanwan\.com|h5youyou|datapool|360-api|alipay|qq\.com/i;
  function trunc(s, n) {
    s = String(s == null ? '' : s);
    return s.length > n ? (s.slice(0, n) + '…(' + s.length + ')') : s;
  }

  log('shim installed mode=' + MODE);

  /* ---------------- XMLHttpRequest ---------------- */
  var OX = window.XMLHttpRequest;
  if (OX) {
    function WrappedXHR() {
      var x = new OX();
      var _url = '', _method = 'GET';
      var _open = x.open, _send = x.send;

      x.open = function (m, u) { _method = m; _url = String(u || ''); return _open.apply(x, arguments); };

      x.send = function (body) {
        var game = GAME_HOST.test(_url);
        if (game) {
          log('XHR ' + _method + ' ' + _url + ' body=' + trunc(body, 300));
          if (MODE === 'mock') {
            var resp = (CFG.mock && CFG.mock[_url]) ||
                       CFG.defaultBody ||
                       '{"code":0,"ret":0,"result":0,"msg":"ok","data":{}}';
            setTimeout(function () {
              try {
                Object.defineProperty(x, 'readyState', { value: 4, configurable: true });
                Object.defineProperty(x, 'status', { value: 200, configurable: true });
                Object.defineProperty(x, 'responseText', { value: resp, configurable: true });
                Object.defineProperty(x, 'response', { value: resp, configurable: true });
                if (x.onreadystatechange) x.onreadystatechange();
                if (x.onload) x.onload();
              } catch (e) { log('mockXHR err ' + e); }
            }, 1);
            return;
          }
        }
        if (game) {
          try {
            x.addEventListener('load', function () {
              try { log('XHR<- ' + _url + ' status=' + x.status + ' head=' + trunc(x.responseText, 240)); } catch (e) {}
            });
            x.addEventListener('error', function () { log('XHR!! ' + _url + ' error'); });
          } catch (e) {}
        }
        return _send.apply(x, arguments);
      };
      return x;
    }
    WrappedXHR.prototype = OX.prototype;
    window.XMLHttpRequest = WrappedXHR;
  }

  /* ---------------- fetch ---------------- */
  if (window.fetch) {
    var _fetch = window.fetch;
    window.fetch = function (input, init) {
      var u = (typeof input === 'string') ? input : ((input && input.url) || '');
      var game = GAME_HOST.test(u);
      if (game) {
        log('FETCH ' + ((init && init.method) || 'GET') + ' ' + u);
        if (MODE === 'mock') {
          var b = (CFG.mock && CFG.mock[u]) || CFG.defaultBody || '{"code":0,"ret":0,"msg":"ok","data":{}}';
          return Promise.resolve(new Response(b, {
            status: 200,
            headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' }
          }));
        }
      }
      var p = _fetch.apply(this, arguments);
      if (game) {
        try {
          p.then(function (res) {
            try { res.clone().text().then(function (t) { log('FETCH<- ' + u + ' ' + trunc(t, 240)); }); } catch (e) {}
          });
        } catch (e) {}
      }
      return p;
    };
  }

  /* ---------------- WebSocket ---------------- */
  var OW = window.WebSocket;
  if (OW) {
    function WrappedWS(url, protocols) {
      var game = GAME_HOST.test(String(url || ''));
      var ws = (protocols !== undefined) ? new OW(url, protocols) : new OW(url);
      if (game) {
        log('WS ' + (url || ''));
        try {
          var _send = ws.send.bind(ws);
          ws.send = function (d) { try { log('WS-> ' + trunc(d, 320)); } catch (e) {} return _send(d); };
          ws.addEventListener('message', function (ev) { try { log('WS<- ' + trunc(ev.data, 320)); } catch (e) {} });
          ws.addEventListener('open', function () { log('WS open ' + url); });
          ws.addEventListener('close', function () { log('WS close ' + url); });
        } catch (e) {}
      }
      return ws;
    }
    WrappedWS.prototype = OW.prototype;
    try { WrappedWS.CONNECTING = 0; WrappedWS.OPEN = 1; WrappedWS.CLOSING = 2; WrappedWS.CLOSED = 3; } catch (e) {}
    window.WebSocket = WrappedWS;
  }

  /* ---------------- 便捷开关 ---------------- */
  window.__qxzb = {
    mode: function () { return MODE; },
    setMode: function (m) { MODE = m; try { localStorage.setItem('qxzb_mode', m); } catch (e) {} log('mode -> ' + m); },
    mock: (CFG.mock || {}),
    defaultBody: CFG.defaultBody
  };
})();
