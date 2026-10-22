/* Quickmd 编辑器内核 · 纯函数层
 * ---------------------------------------------------------------------------
 * 这个文件里没有任何 DOM 操作，只有「文本进文本出」的纯函数，
 * 因此可以在 Node 里直接 require 做单测（见 Tests/editor-core.test.js）。
 *
 *   md --parse--> blocks --renderBlock--> HTML
 *    ^                                    |
 *    |                                    v
 *    +------------- 序列化（DOM 层，在 editor.js 里）
 *
 * 块类型清单（加新类型要三处对称扩展：parse / renderBlock / editor.js 的 blockMD）：
 *   p 段落 · h1 h2 h3 标题 · ul ol 列表（含嵌套）· quote 引用
 *   code 代码块 · hr 分隔线
 */
(function (root) {
  'use strict';

  /* ============================ 行内渲染 ============================ */

  function esc(s) {
    return String(s)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  // 链接协议白名单。任何可疑协议一律降级为 '#'，阻断 javascript:/data:/vbscript: 等。
  function safeURL(u) {
    var s = String(u == null ? '' : u).trim();
    if (s === '') return '#';
    if (/^(https?:\/\/|mailto:|tel:|#|\/|\.\/|\.\.\/)/i.test(s)) return s;
    if (/^[a-z][a-z0-9+.\-]*:/i.test(s)) return '#';   // 带协议但不认识 -> 拦截
    return s;                                          // 相对路径放行
  }

  // 行内 Markdown -> HTML。代码段优先保护，避免内部符号被二次解析。
  function inline(text) {
    var codes = [];
    var t = String(text).replace(/`([^`\n]+)`/g, function (m, c) {
      codes.push(c);
      return '\u0000' + (codes.length - 1) + '\u0000';
    });
    t = esc(t);
    t = t.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
    t = t.replace(/(^|[^\w*])\*([^*\n]+)\*/g, '$1<em>$2</em>');
    t = t.replace(/(^|[^\w_])_([^_\n]+)_/g, '$1<em>$2</em>');
    t = t.replace(/~~([^~]+)~~/g, '<del>$1</del>');
    t = t.replace(/\[([^\]]*)\]\(([^)\s]*)\)/g, function (m, label, url) {
      return '<a href="' + esc(safeURL(url)) + '" target="_blank" rel="noreferrer">' + label + '</a>';
    });
    t = t.replace(/(^|[\s(])(https?:\/\/[^\s<]+)/g, function (m, pre, url) {
      return pre + '<a href="' + esc(safeURL(url)) + '" target="_blank" rel="noreferrer">' + url + '</a>';
    });
    t = t.replace(/\u0000(\d+)\u0000/g, function (m, i) {
      return '<code>' + esc(codes[+i]) + '</code>';
    });
    return t;
  }

  // 去掉行首块级标记，用于「降级为普通段落」
  function stripMarkers(md) {
    return String(md).split('\n').map(function (l, i) {
      return i === 0
        ? l.replace(/^\s*(#{1,3}\s+|>\s?|[-*+]\s+|\d+\.\s+|\[[ xX]\]\s+)/, '')
        : l.replace(/^\s*>\s?/, '');
    }).join('\n');
  }

  /* ============================ md -> blocks ============================ */

  function parse(src) {
    var out = [];
    var lines = String(src == null ? '' : src).replace(/\r\n/g, '\n').split('\n');
    var i = 0;
    var isBlank = function (l) { return /^\s*$/.test(l); };

    while (i < lines.length) {
      var line = lines[i];
      if (isBlank(line)) { i++; continue; }
      var trimmed = line.trim();

      // 代码围栏
      if (/^```/.test(trimmed)) {
        var buf = [line]; i++;
        while (i < lines.length && !/^\s*```/.test(lines[i])) { buf.push(lines[i]); i++; }
        if (i < lines.length) { buf.push(lines[i]); i++; }
        out.push({ type: 'code', md: buf.join('\n') });
        continue;
      }
      // 分隔线
      if (/^(-{3,}|\*{3,}|_{3,})$/.test(trimmed)) {
        out.push({ type: 'hr', md: '---' }); i++; continue;
      }
      // 标题
      var h = line.match(/^(#{1,3})\s+(.*)$/);
      if (h) { out.push({ type: 'h' + h[1].length, md: line }); i++; continue; }
      // 引用（连续行合并为一块）
      if (/^\s*>\s?/.test(line)) {
        var q = [];
        while (i < lines.length && /^\s*>\s?/.test(lines[i])) {
          q.push(lines[i].replace(/^\s*>\s?/, '')); i++;
        }
        out.push({ type: 'quote', md: q.map(function (l) { return '> ' + l; }).join('\n') });
        continue;
      }
      // 列表（有序/无序各自连续成块，含缩进嵌套）
      var ordered = /^\s*\d+\.\s+/.test(line);
      var bullet = /^\s*[-*+]\s+/.test(line);
      if (ordered || bullet) {
        var baseIndent = (line.match(/^\s*/) || [''])[0].length;
        var ls = [];
        while (i < lines.length) {
          var l = lines[i];
          if (/^\s*$/.test(l)) {
            var nxt = lines[i + 1];
            if (nxt !== undefined && /^\s*(?:[-*+]|\d+\.)\s+/.test(nxt) &&
                (nxt.match(/^\s*/) || [''])[0].length >= baseIndent) { i++; continue; }
            break;
          }
          var ind = (l.match(/^\s*/) || [''])[0].length;
          if (!/^\s*(?:[-*+]|\d+\.)\s+/.test(l) || ind < baseIndent) break;
          ls.push(l); i++;
        }
        out.push({ type: ordered ? 'ol' : 'ul', md: ls.join('\n') });
        continue;
      }
      // 普通段落（一行一块，往返时用 \n 连接保持原样）
      out.push({ type: 'p', md: line }); i++;
    }
    return out;
  }

  /* ============================ block -> HTML =========================== */

  // 按缩进把列表项渲染成嵌套 HTML。start/end 为 items 的区间，indent 为本层缩进。
  function renderListItems(items, start, indent, forcedTag) {
    var html = '';
    var i = start;
    var tag = forcedTag || (items[start] && items[start].ordered ? 'ol' : 'ul');
    html += '<' + tag + '>';
    while (i < items.length && items[i].indent >= indent) {
      if (items[i].indent > indent) { i++; continue; }   // 深层由上层消费
      var it = items[i];
      var nested = '';
      if (i + 1 < items.length && items[i + 1].indent > indent) {
        var r = renderListItems(items, i + 1, items[i + 1].indent, null);
        nested = r.html;
        i = r.next - 1;
      }
      var tm = it.text.match(/^\[( |x|X)\]\s*([\s\S]*)$/);
      if (tm) {
        html += '<li class="qn-task">' +
          '<span class="qn-box' + (tm[1].toLowerCase() === 'x' ? ' on' : '') +
          '" contenteditable="false"></span>' +
          '<span>' + inline(tm[2]) + '</span>' + nested + '</li>';
      } else {
        html += '<li>' + inline(it.text) + nested + '</li>';
      }
      i++;
    }
    html += '</' + tag + '>';
    return { html: html, next: i };
  }

  function renderBlock(b) {
    var md = b.md;
    switch (b.type) {
      case 'hr':
        return '<hr>';
      case 'h1':
        return '<h1>' + inline(md.replace(/^#\s+/, '')) + '</h1>';
      case 'h2':
        return '<h2>' + inline(md.replace(/^##\s+/, '')) + '</h2>';
      case 'h3':
        return '<h3>' + inline(md.replace(/^###\s+/, '')) + '</h3>';
      case 'code': {
        var lines = md.split('\n');
        var body = lines.slice(1);
        if (body.length && /^\s*```/.test(body[body.length - 1])) body.pop();
        return '<pre><code>' + esc(body.join('\n')) + '</code></pre>';
      }
      case 'quote':
        return '<blockquote>' + md.split('\n').map(function (l) {
          return '<p>' + inline(l.replace(/^>\s?/, '')) + '</p>';
        }).join('') + '</blockquote>';
      case 'ul':
      case 'ol': {
        var tag = b.type;
        var items = md.split('\n').map(function (l) {
          var m = l.match(/^(\s*)(?:[-*+]|\d+\.)\s+([\s\S]*)$/);
          return m ? { indent: m[1].length, ordered: /\d+\./.test(l.trim()), text: m[2] }
                   : { indent: 0, ordered: false, text: l };
        });
        return renderListItems(items, 0, 0, tag).html;
      }
      default:
        return '<p>' + md.split('\n').map(inline).join('<br>') + '</p>';
    }
  }

  /* ============================ 导出 ============================ */

  var QN_CORE = { esc: esc, inline: inline, parse: parse, renderBlock: renderBlock,
                  stripMarkers: stripMarkers, safeURL: safeURL };

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = QN_CORE;
    return;
  }
  root.QNCore = QN_CORE;
})(typeof window !== 'undefined' ? window : globalThis);
