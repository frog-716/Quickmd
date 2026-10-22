/* Quickmd Markdown 编辑器内核 + UI
 * ---------------------------------------------------------------------------
 * 架构：分块 WYSIWYG。文档被切成一串「块」（段落/标题/列表/引用/代码/分隔线），
 * 每块是独立 contenteditable 元素。
 *
 *   md --parse--> blocks --renderBlock--> HTML --> contenteditable 编辑
 *    ^                                                    |
 *    |                                                    v
 *    +------- serializeNode/blockMD（DOM 反序列化）<--- 用户输入
 *
 * 关键点：
 *  - 只有「需要变形」时才重渲染（敲出 # 前缀、点工具栏、勾选任务），
 *    普通打字不动 DOM，因此光标永远不会跳。
 *  - 重渲染后用「文本偏移」恢复光标，不用浏览器 Selection 的 sticky 逻辑。
 *  - DOM -> md 的序列化是核心原语，保存与重渲染都依赖它。
 *
 * Node 环境下导出纯函数（esc/inline/parse/renderBlock/stripMarkers）便于单测。
 */
(function (root) {
  'use strict';

  /* ============================ 纯函数：行内渲染 ============================ */

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

  /* ============================ 纯函数：md -> blocks ======================== */

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

  /* ============================ 纯函数：block -> HTML ======================= */

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

  /* ============================ Node 导出（可单测） ========================= */

  var QN_CORE = { esc: esc, inline: inline, parse: parse, renderBlock: renderBlock,
                  stripMarkers: stripMarkers, safeURL: safeURL };

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = QN_CORE;
    return;
  }
  if (root.QNCore) { root.QNCore = QN_CORE; }

  /* ============================ 以下为浏览器专用 ============================ */

  var editorRoot = null;
  var saveTimer = null;
  var state = { file: '', dirty: false, lastSaved: null };

  /* ---------- 光标偏移（文本维度，跨 <br> 计数） ---------- */

  function nodeTextLen(node) {
    if (!node) return 0;
    if (node.nodeType === 3) return node.nodeValue.length;
    if (node.nodeType === 1) {
      if (node.tagName === 'BR') return 1;
      var n = 0;
      for (var i = 0; i < node.childNodes.length; i++) n += nodeTextLen(node.childNodes[i]);
      return n;
    }
    return 0;
  }

  // 选区起点相对于 root 的纯文本偏移
  function caretOffset(root) {
    var sel = window.getSelection();
    if (!sel || !sel.rangeCount) return null;
    var r = sel.getRangeAt(0);
    if (!root.contains(r.startContainer)) return null;
    var acc = 0, done = false;
    (function walk(node) {
      if (done) return;
      if (node === r.startContainer) {
        if (node.nodeType === 3) { acc += r.startOffset; done = true; return; }
        for (var k = 0; k < r.startOffset && k < node.childNodes.length; k++) {
          acc += nodeTextLen(node.childNodes[k]);
        }
        done = true; return;
      }
      if (node.nodeType === 3) { acc += node.nodeValue.length; return; }
      for (var i = 0; i < node.childNodes.length; i++) {
        walk(node.childNodes[i]);
        if (done) return;
      }
    })(root);
    return acc;
  }

  function setCaretAtOffset(root, offset) {
    var remaining = offset, placed = false;
    (function walk(node) {
      if (placed || !node) return;
      if (node.nodeType === 3) {
        if (node.nodeValue.length >= remaining) {
          var r = document.createRange();
          r.setStart(node, remaining); r.collapse(true);
          var s = window.getSelection(); s.removeAllRanges(); s.addRange(r);
          placed = true; return;
        }
        remaining -= node.nodeValue.length; return;
      }
      if (node.nodeType === 1) {
        if (node.tagName === 'BR') {
          if (remaining <= 0) {
            var rb = document.createRange();
            rb.setStartBefore(node); rb.collapse(true);
            var sb = window.getSelection(); sb.removeAllRanges(); sb.addRange(rb);
            placed = true; return;
          }
          remaining -= 1; return;
        }
        for (var i = 0; i < node.childNodes.length; i++) {
          walk(node.childNodes[i]);
          if (placed) return;
        }
      }
    })(root);
    if (!placed) {
      var r2 = document.createRange();
      r2.selectNodeContents(root); r2.collapse(false);
      var s2 = window.getSelection(); s2.removeAllRanges(); s2.addRange(r2);
    }
  }

  /* ---------- DOM -> md 序列化 ---------- */

  function serializeNode(node) {
    if (!node) return '';
    if (node.nodeType === 3) return node.nodeValue;     // 文本节点：直接取值
    if (node.nodeType !== 1) return '';
    var out = '';
    var kids = node.childNodes;
    for (var i = 0; i < kids.length; i++) {
      var n = kids[i];
      if (n.nodeType === 3) { out += n.nodeValue; continue; }
      if (n.nodeType !== 1) continue;
      var tag = n.tagName.toLowerCase();
      var inner = serializeNode(n);
      if (tag === 'br') out += '\n';
      else if (tag === 'strong' || tag === 'b') out += '**' + inner + '**';
      else if (tag === 'em' || tag === 'i') out += '*' + inner + '*';
      else if (tag === 'code') out += '`' + inner + '`';
      else if (tag === 'del' || tag === 's' || tag === 'strike') out += '~~' + inner + '~~';
      else if (tag === 'a') out += '[' + inner + '](' + (n.getAttribute('href') || '') + ')';
      else out += inner; // span / label / 其它容器：取其文本
    }
    return out;
  }

  function blockMD(el) {
    var type = el.getAttribute('data-type') || 'p';
    if (type === 'hr') return '---';
    if (type === 'code') {
      var code = el.querySelector('code');
      var text = code ? code.textContent : el.textContent;
      var lang = el.getAttribute('data-lang') || '';
      return '```' + lang + '\n' + text.replace(/\n+$/, '') + '\n```';
    }
    if (type === 'ul' || type === 'ol') {
      // 注意：块元素是 div，真正的列表容器是它的 ul/ol 子元素，
      // 必须取到 list 才能枚举 li——直接读 div.children 只会拿到 ul 本身。
      var list = el.querySelector('ul, ol');
      if (!list) return '';
      return serializeList(list, 0).join('\n');
    }
    if (type === 'quote') {
      var ps = el.querySelectorAll('p');
      var parts = ps.length
        ? Array.prototype.map.call(ps, serializeNode)
        : [serializeNode(el)];
      return parts.join('\n').split('\n').map(function (l) { return '> ' + l; }).join('\n');
    }
    var text = serializeNode(el);
    if (type === 'h1') return '# ' + text;
    if (type === 'h2') return '## ' + text;
    if (type === 'h3') return '### ' + text;
    return text;
  }

  // 序列化列表（含嵌套），返回行数组。depth 控制缩进。
  function serializeList(listEl, depth) {
    var lines = [];
    var ordered = listEl.tagName.toLowerCase() === 'ol';
    var lis = listEl.children;
    var pad = new Array(depth + 1).join('  ');
    for (var i = 0; i < lis.length; i++) {
      var li = lis[i];
      var isTask = li.classList && li.classList.contains('qn-task');
      var body = '';
      var nestedLists = [];
      var kids = li.childNodes;
      for (var j = 0; j < kids.length; j++) {
        var n = kids[j];
        if (n.nodeType === 1) {
          var t = n.tagName.toLowerCase();
          if (t === 'ul' || t === 'ol') { nestedLists.push(n); continue; }
          if (isTask && n.classList && n.classList.contains('qn-box')) continue;
        }
        body += serializeNode(n);
      }
      var prefix = (ordered ? (i + 1) + '. ' : '- ');
      if (isTask) {
        var box = li.querySelector('.qn-box');
        prefix += (box && box.classList.contains('on') ? '[x] ' : '[ ] ');
      }
      lines.push(pad + prefix + body);
      for (var k = 0; k < nestedLists.length; k++) {
        lines = lines.concat(serializeList(nestedLists[k], depth + 1));
      }
    }
    return lines;
  }

  /* ---------- 块操作 ---------- */

  function createBlockEl(type, md) {
    var el = document.createElement('div');
    el.className = 'qn-block';
    el.setAttribute('data-type', type);
    el.setAttribute('contenteditable', 'true');
    el.innerHTML = renderBlock({ type: type, md: md });
    // 代码块记住语言标签，往返时才不会丢 ```swift
    if (type === 'code') {
      var fm = String(md).match(/^```([^\s`]*)/);
      el.setAttribute('data-lang', fm ? fm[1] : '');
    }
    return el;
  }

  function renderInto(el, type, md) {
    el.setAttribute('data-type', type);
    el.innerHTML = renderBlock({ type: type, md: md });
    if (type === 'code') {
      var fm = String(md).match(/^```([^\s`]*)/);
      el.setAttribute('data-lang', fm ? fm[1] : '');
    } else {
      el.removeAttribute('data-lang');
    }
  }

  function blockOf(node) {
    if (!node) return null;
    if (node.nodeType === 3) node = node.parentNode;
    if (!node || !node.closest) return null;
    var el = node.closest('.qn-block');
    return el && editorRoot.contains(el) ? el : null;
  }

  function activeBlock() {
    var sel = window.getSelection();
    if (!sel || !sel.rangeCount) return null;
    return blockOf(sel.anchorNode);
  }

  function focusBlock(el, offset) {
    el.focus();
    if (offset == null) offset = nodeTextLen(el);
    setCaretAtOffset(el, offset);
  }

  /* ---------- 文档级序列化 ---------- */

  function getMarkdown() {
    var els = editorRoot.querySelectorAll('.qn-block');
    var parts = [];
    for (var i = 0; i < els.length; i++) {
      var md = blockMD(els[i]);
      if (md.trim() !== '') parts.push(md);
    }
    // 块间用空行连接：符合 CommonMark 规范，存出的文件在
    // Typora/VS Code 等标准渲染器里段落不会并成一块。
    return parts.join('\n\n');
  }

  function countText(md) {
    var cjk = (md.match(/[\u3400-\u9fff\u3040-\u30ff\uac00-\ud7af]/g) || []).length;
    var words = (md.replace(/[\u3400-\u9fff\u3040-\u30ff\uac00-\ud7af]/g, ' ')
                   .match(/[A-Za-z0-9_'-]+/g) || []).length;
    return cjk + words;
  }

  /* ---------- 状态栏 ---------- */

  function updateStatus() {
    var md = getMarkdown();
    var count = countText(md);
    var el = document.getElementById('qn-count');
    if (el) el.textContent = count + ' 字';
    var app = document.getElementById('qn-app');
    if (app) app.classList.toggle('is-empty', md.trim() === '');
    editorRoot.classList.toggle('is-empty', md.trim() === '');
    var st = document.getElementById('qn-status');
    if (st) st.classList.toggle('qn-dirty', state.dirty);
    var sv = document.getElementById('qn-savestate');
    if (sv) sv.textContent = state.dirty ? '未保存' : (state.lastSaved ? '已保存 ' + state.lastSaved : '就绪');
    var fn = document.getElementById('qn-file');
    if (fn) fn.textContent = state.file || '未命名';
  }

  /* ---------- 保存（防抖 + 立即通道） ---------- */

  function post(msg) {
    if (root.webkit && root.webkit.messageHandlers && root.webkit.messageHandlers.quickmd) {
      root.webkit.messageHandlers.quickmd.postMessage(msg);
    }
  }

  function scheduleSave(delay) {
    state.dirty = true;
    updateStatus();
    if (saveTimer) clearTimeout(saveTimer);
    saveTimer = setTimeout(function () { flush(); }, delay == null ? 400 : delay);
  }

  function flush() {
    if (saveTimer) { clearTimeout(saveTimer); saveTimer = null; }
    var md = getMarkdown();
    post({ type: 'save', md: md });
    state.dirty = false;
    var d = new Date();
    var p = function (n) { return (n < 10 ? '0' : '') + n; };
    state.lastSaved = p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds());
    updateStatus();
  }

  /* ---------- 「敲出前缀即变形」 ---------- */

  function maybeTransform(el) {
    if (el.getAttribute('data-type') !== 'p') return false;
    var text = serializeNode(el);
    var m;
    if ((m = text.match(/^(#{1,3})\s/))) {
      renderInto(el, 'h' + m[1].length, m[1] + ' ' + text.replace(/^#{1,3}\s+/, ''));
      focusBlock(el);
      return true;
    }
    if ((m = text.match(/^([-*+])\s/))) {
      renderInto(el, 'ul', '- ' + text.replace(/^[-*+]\s+/, ''));
      focusBlock(el);
      return true;
    }
    if ((m = text.match(/^\d+\.\s/))) {
      renderInto(el, 'ol', '1. ' + text.replace(/^\d+\.\s+/, ''));
      focusBlock(el);
      return true;
    }
    if ((m = text.match(/^>\s?/))) {
      renderInto(el, 'quote', '> ' + text.replace(/^>\s?/, ''));
      focusBlock(el);
      return true;
    }
    if (/^(-{3,}|\*{3,}|_{3,})$/.test(text.trim())) {
      var hr = document.createElement('div');
      hr.className = 'qn-block';
      hr.setAttribute('data-type', 'hr');
      hr.setAttribute('contenteditable', 'false');
      hr.innerHTML = '<hr>';
      el.parentNode.insertBefore(hr, el.nextSibling);
      var next = createBlockEl('p', '');
      hr.parentNode.insertBefore(next, hr.nextSibling);
      el.parentNode.removeChild(el);
      focusBlock(next);
      return true;
    }
    return false;
  }

  /* ---------- Enter：拆分块 / 续列表 ---------- */

  function handleEnter(e) {
    var el = blockOf(e.target);
    if (!el) return;
    var type = el.getAttribute('data-type');
    if (type === 'code' || type === 'hr') return; // 代码块内默认换行

    e.preventDefault();
    var sel = window.getSelection();
    if (!sel.rangeCount) return;
    var r = sel.getRangeAt(0);
    var after = r.cloneRange();
    after.selectNodeContents(el);
    after.setStart(r.endContainer, r.endOffset);
    var frag = after.extractContents();
    var tmp = document.createElement('div');
    tmp.appendChild(frag);
    var tail = serializeNode(tmp);
    var headMD = blockMD(el);

    var newType = 'p', newMD = tail;
    if (type === 'ul' || type === 'ol') {
      var onlyEmpty = el.children.length === 1 && serializeNode(el).trim() === '';
      if (onlyEmpty) {                       // 空列表项回车 -> 退出列表
        renderInto(el, 'p', '');
        focusBlock(el);
        scheduleSave();
        return;
      }
      newType = type;
      newMD = (type === 'ol' ? '1. ' : '- ') + tail;
    } else if (type === 'quote') {
      if (tail.trim() === '') { newType = 'p'; newMD = ''; }
      else { newType = 'quote'; newMD = '> ' + tail; }
    }

    var newEl = createBlockEl(newType, newMD);
    el.parentNode.insertBefore(newEl, el.nextSibling);
    renderInto(el, type, headMD);
    focusBlock(newEl);
    scheduleSave();
  }

  /* ---------- Backspace：行首降级 / 删除空块 ---------- */

  function handleBackspace(e) {
    var el = blockOf(e.target);
    if (!el) return;
    var off = caretOffset(el);
    if (off !== 0) return;                    // 只在块首生效
    e.preventDefault();
    var type = el.getAttribute('data-type');
    var text = type === 'hr' ? '' : serializeNode(el);

    if (text.trim() === '') {                 // 空块 -> 删除并聚焦上一块
      var prev = el.previousElementSibling;
      if (prev) {
        el.parentNode.removeChild(el);
        focusBlock(prev);
      } else {
        renderInto(el, 'p', '');
        focusBlock(el);
      }
      scheduleSave();
      return;
    }
    if (type !== 'p') {                       // 有内容的块 -> 降级为普通段落
      renderInto(el, 'p', stripMarkers(blockMD(el)));
      focusBlock(el, 0);
      scheduleSave();
    }
  }

  /* ---------- 工具栏 / 快捷键 ---------- */

  function wrapCode() {
    var el = activeBlock();
    if (!el) return;
    var sel = window.getSelection();
    if (!sel.rangeCount || sel.isCollapsed) return;
    var r = sel.getRangeAt(0);
    var code = document.createElement('code');
    try {
      r.surroundContents(code);
    } catch (err) {
      code.appendChild(r.extractContents());
      r.insertNode(code);
    }
    sel.removeAllRanges();
    var nr = document.createRange();
    nr.setStartAfter(code); nr.collapse(true);
    sel.addRange(nr);
    scheduleSave();
  }

  function insertLink() {
    var el = activeBlock();
    if (!el) return;
    var sel = window.getSelection();
    var text = sel && sel.rangeCount ? sel.toString() : '';
    var url = root.prompt('链接地址：', 'https://');
    if (!url) return;
    document.execCommand('insertHTML', false,
      '<a href="' + url.replace(/"/g, '&quot;') + '">' + esc(text || url) + '</a>');
    scheduleSave();
  }

  function applyBlockType(type) {
    var el = activeBlock();
    if (!el) return;
    var text = serializeNode(el);
    var md;
    if (type === 'h1') md = '# ' + text;
    else if (type === 'h2') md = '## ' + text;
    else if (type === 'h3') md = '### ' + text;
    else if (type === 'quote') md = '> ' + text.split('\n').join('\n> ');
    else if (type === 'ul') md = '- ' + text.split('\n').join('\n- ');
    else if (type === 'ol') md = '1. ' + text.split('\n').join('\n1. ');
    else if (type === 'code') md = '```\n' + text + '\n```';
    else md = stripMarkers(blockMD(el));
    renderInto(el, type, md);
    focusBlock(el);
    scheduleSave();
  }

  function toggleTask(box) {
    box.classList.toggle('on');
    scheduleSave();
    flush();
  }

  function execInline(cmd) {
    document.execCommand(cmd);
    scheduleSave();
  }

  /* ---------- 事件绑定 ---------- */

  function bindEvents() {
    // 输入：变形检测 + 保存
    editorRoot.addEventListener('input', function (e) {
      var el = blockOf(e.target);
      if (!el) return;
      if (el.getAttribute('data-type') !== 'code') maybeTransform(el);
      scheduleSave();
    });

    // 键盘
    editorRoot.addEventListener('keydown', function (e) {
      var mod = e.metaKey || e.ctrlKey;
      var k = e.key.toLowerCase();

      if (mod && !e.altKey) {
        if (k === 'b') { e.preventDefault(); execInline('bold'); return; }
        if (k === 'i') { e.preventDefault(); execInline('italic'); return; }
        if (k === 'x' && e.shiftKey) { e.preventDefault(); execInline('strikeThrough'); return; }
        if (k === 'e') { e.preventDefault(); wrapCode(); return; }
        if (k === 'k') { e.preventDefault(); insertLink(); return; }
        if (k === 's') { e.preventDefault(); flush(); return; }
        if (k === '1') { e.preventDefault(); applyBlockType('h1'); return; }
        if (k === '2') { e.preventDefault(); applyBlockType('h2'); return; }
        if (k === '3') { e.preventDefault(); applyBlockType('h3'); return; }
        if (k === '7') { e.preventDefault(); applyBlockType('ul'); return; }
        if (k === '8') { e.preventDefault(); applyBlockType('ol'); return; }
        if (k === '9') { e.preventDefault(); applyBlockType('quote'); return; }
      }
      if (e.key === 'Enter') { handleEnter(e); return; }
      if (e.key === 'Backspace') { handleBackspace(e); return; }
      if (e.key === 'Tab') {
        e.preventDefault();
        document.execCommand('insertText', false, '  ');
        scheduleSave();
      }
    });

    // 工具栏
    var tb = document.getElementById('qn-toolbar');
    tb.addEventListener('click', function (e) {
      var btn = e.target.closest ? e.target.closest('.qn-btn') : null;
      if (!btn) return;
      var cmd = btn.getAttribute('data-cmd');
      if (cmd === 'bold') execInline('bold');
      else if (cmd === 'italic') execInline('italic');
      else if (cmd === 'strike') execInline('strikeThrough');
      else if (cmd === 'code') wrapCode();
      else if (cmd === 'link') insertLink();
      else applyBlockType(cmd);
    });
    // mousedown 阻止按钮抢焦点
    tb.addEventListener('mousedown', function (e) {
      if (e.target.closest && e.target.closest('.qn-btn')) e.preventDefault();
    });

    // 任务勾选
    editorRoot.addEventListener('click', function (e) {
      var box = e.target.closest ? e.target.closest('.qn-box') : null;
      if (box) { e.preventDefault(); toggleTask(box); }
    });

    // 点击空白处聚焦最后一块
    document.getElementById('qn-scroll').addEventListener('mousedown', function (e) {
      if (e.target === editorRoot) {
        e.preventDefault();
        var els = editorRoot.querySelectorAll('.qn-block');
        var last = els[els.length - 1];
        if (last) focusBlock(last);
        else focusBlock(createAndAppend('p', ''));
      }
    });
  }

  function createAndAppend(type, md) {
    var el = createBlockEl(type, md);
    editorRoot.appendChild(el);
    return el;
  }

  /* ---------- 对外接口 ---------- */

  function load(md, file) {
    state.file = file || '';
    state.dirty = false;
    state.lastSaved = null;
    editorRoot.innerHTML = '';
    var blocks = QN_CORE.parse(md || '');
    if (!blocks.length) blocks = [{ type: 'p', md: '' }];
    blocks.forEach(function (b) { editorRoot.appendChild(createBlockEl(b.type, b.md)); });
    updateStatus();
  }

  function init() {
    editorRoot = document.getElementById('qn-editor');
    if (!editorRoot) return;
    bindEvents();
    load('', '');
    post({ type: 'ready' });
  }

  root.QN = {
    load: load,
    getMarkdown: getMarkdown,
    flush: flush,
    init: init,
    core: QN_CORE
  };

  if (typeof document !== 'undefined') {
    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', init);
    } else {
      init();
    }
  }
})(typeof window !== 'undefined' ? window : globalThis);
