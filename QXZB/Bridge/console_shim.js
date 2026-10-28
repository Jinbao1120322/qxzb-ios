/*
 * console_shim.js —— 页面脚本执行前注入。
 * 作用：把 JS 侧 console / 未捕获异常 / 资源加载失败，全部转发到原生日志（屏内可见）。
 * 目的：真机上排障不需要连 Xcode，截图就能定位卡在哪一步。
 */
(function () {
  'use strict';

  var NATIVE = (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.log) || null;
  function send(s) {
    if (NATIVE) { try { NATIVE.postMessage(String(s)); return; } catch (e) {} }
    try { console.log(s); } catch (e) {}
  }

  function fmt(a) {
    try {
      if (typeof a === 'string') return a;
      if (a instanceof Error) return a.stack || (a.name + ': ' + a.message);
      return JSON.stringify(a);
    } catch (e) { return String(a); }
  }

  ['log', 'info', 'warn', 'error', 'debug'].forEach(function (k) {
    var orig = console[k] ? console[k].bind(console) : function () {};
    console[k] = function () {
      var parts = Array.prototype.map.call(arguments, fmt);
      send('console.' + k + ': ' + parts.join(' ').slice(0, 900));
      orig.apply(null, arguments);
    };
  });

  window.addEventListener('error', function (e) {
    var t = e && e.target;
    if (t && t.tagName) {
      send('resource error: <' + t.tagName + '> ' + (t.src || t.href || ''));
    } else {
      send('window.error: ' + (e.message || '') + ' @ ' + (e.filename || '') + ':' + (e.lineno || 0));
    }
  }, true);

  window.addEventListener('unhandledrejection', function (e) {
    send('unhandledrejection: ' + fmt(e.reason));
  });

  // 环境自检：这几项直接决定 Egret 能不能跑起来
  function envProbe() {
    var r = [];
    r.push('origin=' + location.origin + ' href=' + location.href);
    try {
      localStorage.setItem('__probe', '1');
      localStorage.removeItem('__probe');
      r.push('localStorage=OK');
    } catch (e) { r.push('localStorage=FAIL(' + e.name + ')'); }
    try { r.push('indexedDB=' + (window.indexedDB ? 'OK' : 'missing')); }
    catch (e) { r.push('indexedDB=FAIL'); }
    try {
      var c = document.createElement('canvas');
      var gl = c.getContext('webgl') || c.getContext('experimental-webgl');
      r.push('webgl=' + (gl ? 'OK' : 'FAIL'));
    } catch (e) { r.push('webgl=EXC'); }
    try { r.push('AudioContext=' + (window.AudioContext || window.webkitAudioContext ? 'OK' : 'FAIL')); }
    catch (e) { r.push('AudioContext=EXC'); }
    send('ENV ' + r.join(' | '));
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', envProbe);
  } else {
    envProbe();
  }

  send('console_shim installed');
})();
