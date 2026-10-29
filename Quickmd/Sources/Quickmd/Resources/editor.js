/* Quickmd 编辑器 · 浏览器层（DOM + 交互）
 * ---------------------------------------------------------------------------
 * 纯函数（parse / renderBlock / inline / esc）在 editor-core.js 里，
 * 本文件只负责：把 md 变成可编辑的块、把 DOM 变回 md、处理键盘与保存。
 *
 * 架构：分块 WYSIWYG。文档被切成一串「块」（段落/标题/列表/引用/代码/分隔线），
 * 每块是独立 contenteditable 元素。
 *
 * 关键点：
 *  - 只有「需要变形」时才重渲染（敲出 # 前缀、勾选任务），
 *    普通打字不动 DOM，因此光标永远不会跳。
 *  - 重渲染后用「文本偏移」恢复光标，不用浏览器 Selection 的 sticky 逻辑。
 *  - DOM -> md 的序列化是核心原语，保存与重渲染都依赖它。
 *
 * v3 变化：去掉工具栏与全部功能按钮，只保留「前缀语法 + 快捷键」；
 *          新增任务列表前缀（- [ ] 空格）与列表项真实缩进（Tab / Shift+Tab）。
 */
(function (root) {
  'use strict';

  var QN_CORE = (typeof module !== 'undefined' && module.exports)
    ? require('./editor-core.js')
    : root.QNCore;

  /* ============================ 浏览器专用状态 ============================ */

  var editorRoot = null;
  var saveTimer = null;
  var state = { file: '', baseDir: '' };

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
      else if (tag === 'img') {
        // 行内图片：序列化用 data-rel（相对路径），保证存回去的 md 可移植
        out += '![' + (n.getAttribute('alt') || '') + ']('
             + (n.getAttribute('data-rel') || n.getAttribute('src') || '') + ')';
      }
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
    if (type === 'table') return tableMD(el);
    if (type === 'image') {
      var img = el.querySelector('img');
      if (!img) return '';
      // 优先 data-rel（原始相对路径）：src 在显示时被换成了 file:// 绝对路径，
      // 写回 md 必须是相对路径，否则文件一搬走图片就断。
      var rel = img.getAttribute('data-rel') || img.getAttribute('src') || '';
      var alt = img.getAttribute('alt') || '';
      return '![' + alt + '](' + rel + ')';
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
    if (/^h[1-6]$/.test(type)) {
      var lv = parseInt(type.charAt(1), 10);
      return new Array(lv + 1).join('#') + ' ' + text;
    }
    return text;
  }

  /// 表格 -> Markdown。表头行后面必须补一行分隔行，否则别的渲染器不认表格。
  function tableMD(el) {
    var table = el.querySelector('table');
    if (!table) return '';
    var rows = table.querySelectorAll('tr');
    var lines = [];
    for (var i = 0; i < rows.length; i++) {
      var cells = rows[i].children;
      var parts = [];
      for (var j = 0; j < cells.length; j++) {
        // 单元格内的换行降级为空格：Markdown 表格不支持单元格内多行
        var t = cells[j].textContent.replace(/\n/g, ' ').replace(/\|/g, '\\|').trim();
        parts.push(t);
      }
      lines.push('| ' + parts.join(' | ') + ' |');
      if (i === 0) {
        var seps = [];
        for (var k = 0; k < cells.length; k++) {
          var al = (cells[k].style.textAlign || '').toLowerCase();
          seps.push(al === 'center' ? ':---:' : al === 'right' ? '---:'
                   : al === 'left' ? ':---' : '---');
        }
        lines.push('| ' + seps.join(' | ') + ' |');
      }
    }
    return lines.join('\n');
  }

  // 序列化列表（含嵌套），返回行数组。depth 控制缩进。
  function serializeList(listEl, depth) {
    var lines = [];
    var ordered = listEl.tagName.toLowerCase() === 'ol';
    // 有序列表的起始序号：<ol start="3"> 表示 3. 4. 5.，序列化时必须保号，
    // 否则「3. 起」保存出去就变成了「1. 起」，下次打开就丢了用户写的序号。
    var startNum = ordered ? (parseInt(listEl.getAttribute('start') || '1', 10) || 1) : 1;
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
        }
        body += serializeNode(n);
      }
      var prefix = (ordered ? (startNum + i) + '. ' : '- ');
      if (isTask) {
        prefix += (li.classList.contains('qn-done') ? '[x] ' : '[ ] ');
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
    el.innerHTML = QN_CORE.renderBlock({ type: type, md: md });
    // 代码块记住语言标签，往返时才不会丢 ```swift
    if (type === 'code') {
      var fm = String(md).match(/^```([^\s`]*)/);
      el.setAttribute('data-lang', fm ? fm[1] : '');
    }
    return el;
  }

  function renderInto(el, type, md) {
    el.setAttribute('data-type', type);
    el.innerHTML = QN_CORE.renderBlock({ type: type, md: md });
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

  // 变形后恢复光标：前缀被吃掉后偏移要前移，调用方传「减去前缀长度」后的值
  function restoreCaret(el, offset) {
    var len = nodeTextLen(el);
    focusBlock(el, Math.max(0, Math.min(offset == null ? 0 : offset, len)));
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

  /* ---------- 编辑器状态 ---------- */

  function updateEditorState() {
    var md = getMarkdown();
    var app = document.getElementById('qn-app');
    if (app) app.classList.toggle('is-empty', md.trim() === '');
    editorRoot.classList.toggle('is-empty', md.trim() === '');
    var fn = document.getElementById('qn-file');
    if (fn) fn.textContent = state.file || '未命名';
  }

  /// 保存状态：绿点 = 已落盘，橙点 = 有改动没写出去。
  function setDirty(on) {
    var st = document.getElementById('qn-status');
    if (st) st.classList.toggle('is-dirty', !!on);
    var sv = document.getElementById('qn-save');
    if (sv) sv.textContent = on ? '编辑中' : '已保存';
  }

  /// 状态栏异常提示（外部删除等）。不传或传空则恢复常规保存态。
  /// 注意：警告态只在「换了文件 / 主动清除」时消失，普通打字不会把它盖掉——
  /// 盖掉了用户就以为在正常存盘，而实际上写盘已经被跳过。
  function setNotice(text) {
    var st = document.getElementById('qn-status');
    var sv = document.getElementById('qn-save');
    if (!text) {
      if (st) st.classList.remove('is-warn');
      setDirty(false);
      return;
    }
    if (st) st.classList.add('is-warn');
    if (sv) sv.textContent = text;
  }

  /// 把相对图片路径解析成 file:// 绝对路径。
  ///
  /// 为什么不直接渲染成绝对路径：md 文件里必须存相对路径（文件连同 assets
  /// 一起搬走才不会断），只有显示时才需要绝对路径给 WebView 加载。
  /// 两个用途分开，谁也别污染谁。
  function resolveImages() {
    if (!state.baseDir) return;
    var imgs = editorRoot.querySelectorAll('img');
    for (var i = 0; i < imgs.length; i++) {
      var img = imgs[i];
      var rel = img.getAttribute('data-rel');
      if (!rel) continue;
      if (/^(https?:|data:|file:|\/\/|\/)/i.test(rel)) continue;
      img.setAttribute('src', 'file://' + encodeURI(state.baseDir + '/' + rel));
    }
  }

  /* ---------- 保存（防抖 + 立即通道） ---------- */

  function post(msg) {
    if (root.webkit && root.webkit.messageHandlers && root.webkit.messageHandlers.quickmd) {
      root.webkit.messageHandlers.quickmd.postMessage(msg);
    }
  }

  function scheduleSave(delay) {
    updateEditorState();
    setDirty(true);
    if (saveTimer) clearTimeout(saveTimer);
    saveTimer = setTimeout(function () { flush(); }, delay == null ? 200 : delay);
  }

  function flush() {
    if (saveTimer) { clearTimeout(saveTimer); saveTimer = null; }
    var md = getMarkdown();
    // 带上文件名：Swift 侧会核对它是不是当前文档。
    // 防抖定时器和「切换文件」是两条独立的时间线，timer 有可能在切换之后才到，
    // 没有这个字段就会把 A 的内容写进 B。
    post({ type: 'save', md: md, file: state.file });
    setDirty(false);
  }

  /* ---------- 「敲出前缀即变形」 ---------- */

  function maybeTransform(el) {
    if (el.getAttribute('data-type') !== 'p') return false;
    var text = serializeNode(el);
    var off = caretOffset(el);          // 变形前的光标位置
    var m;

    // 任务列表：- [ ] 空格 / - [x] 空格
    if ((m = text.match(/^([-*+])\s+\[([ xX])\]\s+/))) {
      var mark = m[2].toLowerCase() === 'x' ? '[x]' : '[ ]';
      var rest = text.replace(/^[-*+]\s+\[[ xX]\]\s+/, '');
      renderInto(el, 'ul', '- ' + mark + ' ' + rest);
      restoreCaret(el, off == null ? 0 : off - m[0].length);
      return true;
    }
    // 标题（1-6 级都能靠前缀变形，一次敲完整前缀）
    if ((m = text.match(/^(#{1,6})\s/))) {
      var headRest = text.replace(/^#{1,6}\s+/, '');
      renderInto(el, 'h' + m[1].length, m[1] + ' ' + headRest);
      restoreCaret(el, off == null ? 0 : off - m[0].length);
      return true;
    }
    // 无序列表
    if ((m = text.match(/^([-*+])\s/))) {
      renderInto(el, 'ul', '- ' + text.replace(/^[-*+]\s+/, ''));
      restoreCaret(el, off == null ? 0 : off - m[0].length);
      return true;
    }
    // 有序列表：保留用户写下的序号（Typora 行为：写 "3. " 就是 3、4、5）
    if ((m = text.match(/^(\d+)\.\s/))) {
      renderInto(el, 'ol', m[1] + '. ' + text.replace(/^\d+\.\s+/, ''));
      restoreCaret(el, off == null ? 0 : off - m[0].length);
      return true;
    }
    // 引用
    if ((m = text.match(/^>\s?/))) {
      renderInto(el, 'quote', '> ' + text.replace(/^>\s?/, ''));
      restoreCaret(el, off == null ? 0 : off - m[0].length);
      return true;
    }
    // 分隔线
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

  // 列表项的纯文本（去掉嵌套列表）
  function listItemText(li) {
    var out = '';
    for (var i = 0; i < li.childNodes.length; i++) {
      var n = li.childNodes[i];
      if (n.nodeType === 1) {
        var t = n.tagName.toLowerCase();
        if (t === 'ul' || t === 'ol') continue;                       // 嵌套列表不算本项内容
      }
      out += serializeNode(n);
    }
    return out;
  }

  // li 里最后一个「非嵌套列表」的节点，用来确定行尾边界
  function lastInlineNode(li) {
    for (var i = li.childNodes.length - 1; i >= 0; i--) {
      var n = li.childNodes[i];
      if (n.nodeType === 1) {
        var t = n.tagName.toLowerCase();
        if (t === 'ul' || t === 'ol') continue;
      }
      return n;
    }
    return null;
  }

  // 退出列表：空项上回车 -> 删掉该项；若列表空了则整块退回段落
  function exitList(el, li, list) {
    var isLast = (li === list.lastElementChild);
    var prev = li.previousElementSibling;
    list.removeChild(li);
    if (!list.children.length) {          // 列表空了 -> 这一块变成普通段落
      renderInto(el, 'p', '');
      focusBlock(el);
      return;
    }
    if (isLast) {                        // 末项回车 -> 列表后面接一个新段落
      var p = createBlockEl('p', '');
      el.parentNode.insertBefore(p, el.nextSibling);
      focusBlock(p);
    } else {                             // 中间项 -> 直接删掉，光标回到前一项
      focusBlock(el);
      if (prev) setCaretAtOffset(prev, 0);
    }
  }

  // 列表里回车：在同一个 <ul>/<ol> 内插入新项，不拆块。
  // 有序列表的序号交给浏览器自动续（配合 <ol start> 保住起始序号），
  // 这就是 Typora 的行为：写 1. 回车变 2.、3.
  function handleListEnter(e, el, sel) {
    var li = closestLi(e.target);
    if (!li) return;
    var list = li.parentNode;
    if (!list || (list.tagName.toLowerCase() !== 'ul' && list.tagName.toLowerCase() !== 'ol')) return;
    var isTask = !!(li.classList && li.classList.contains('qn-task'));

    if (listItemText(li).trim() === '') {   // 空项 -> 退出列表
      exitList(el, li, list);
      return;
    }

    var r = sel.getRangeAt(0);
    var last = lastInlineNode(li);
    if (!last) { exitList(el, li, list); return; }

    // 取出光标之后的文字，交给新的一项
    var after = r.cloneRange();
    after.setStart(r.endContainer, r.endOffset);
    after.setEndAfter(last);
    var frag = after.extractContents();

    var newLi = document.createElement('li');
    if (isTask) {
      newLi.className = 'qn-task';
      var span = document.createElement('span');
      span.appendChild(frag);
      newLi.appendChild(span);
    } else {
      newLi.appendChild(frag);
    }
    list.insertBefore(newLi, li.nextSibling);

    focusBlock(el);
    var target = isTask ? newLi.querySelector('span:last-child') : newLi;
    setCaretAtOffset(target, 0);
  }

  function handleEnter(e) {
    var el = blockOf(e.target);
    if (!el) return;
    var type = el.getAttribute('data-type');
    if (type === 'code' || type === 'hr') return; // 代码块内默认换行

    e.preventDefault();
    var sel = window.getSelection();
    if (!sel.rangeCount) return;

    if (type === 'ul' || type === 'ol') {        // 列表走专用逻辑
      handleListEnter(e, el, sel);
      scheduleSave();
      return;
    }

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
    if (type === 'quote') {
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
      renderInto(el, 'p', QN_CORE.stripMarkers(blockMD(el)));
      focusBlock(el, 0);
      scheduleSave();
    }
  }

  /* ---------- Tab / Shift+Tab：列表项缩进 ---------- */

  function closestLi(node) {
    if (!node) return null;
    if (node.nodeType === 3) node = node.parentNode;
    if (!node || !node.closest) return null;
    return node.closest('li');
  }

  // 当前光标是否在某个列表块里；是则返回 { li, block }
  function currentListContext() {
    var sel = window.getSelection();
    if (!sel || !sel.rangeCount) return null;
    var li = closestLi(sel.anchorNode);
    if (!li) return null;
    var block = blockOf(li);
    if (!block) return null;
    var type = block.getAttribute('data-type');
    if (type !== 'ul' && type !== 'ol') return null;
    return { li: li, block: block };
  }

  // 缩进：把当前项挪进上一个兄弟项的子列表
  function indentListItem(li) {
    var prev = li.previousElementSibling;
    if (!prev) return false;                  // 第一项没法再缩
    var nested = null;
    for (var i = 0; i < prev.children.length; i++) {
      var c = prev.children[i];
      var t = c.tagName.toLowerCase();
      if (t === 'ul' || t === 'ol') { nested = c; break; }
    }
    if (!nested) {
      var tag = li.parentNode && li.parentNode.tagName.toLowerCase() === 'ol' ? 'ol' : 'ul';
      nested = document.createElement(tag);
      prev.appendChild(nested);
    }
    nested.appendChild(li);
    return true;
  }

  // 减缩进：把当前项提到上一层（与父项同级）
  function outdentListItem(li) {
    var parent = li.parentNode;               // 当前所在的 ul/ol
    var grandLi = parent && parent.parentNode;
    if (!grandLi || grandLi.tagName.toLowerCase() !== 'li') return false;  // 顶层项没法再减
    grandLi.parentNode.insertBefore(li, grandLi.nextSibling);
    if (parent.children.length === 0 && parent.parentNode) {
      parent.parentNode.removeChild(parent);   // 清空嵌套列表
    }
    return true;
  }

  function handleTab(e, isIndent) {
    var ctx = currentListContext();
    if (!ctx) {
      // 不在列表里：Tab 插入两个空格；Shift+Tab 去掉行首缩进
      if (isIndent) {
        document.execCommand('insertText', false, '  ');
        scheduleSave();
      } else {
        var el = activeBlock();
        if (el) {
          var t = serializeNode(el);
          if (/^ {1,2}/.test(t)) {
            renderInto(el, el.getAttribute('data-type'), t.replace(/^ {1,2}/, ''));
            focusBlock(el, 0);
            scheduleSave();
          }
        }
      }
      return;
    }

    e.preventDefault();
    var offInLi = caretOffset(ctx.li);
    var changed = isIndent ? indentListItem(ctx.li) : outdentListItem(ctx.li);
    if (!changed) return;
    // DOM 移动会丢光标，用「项内文本偏移」恢复
    focusBlock(ctx.block);
    if (offInLi != null) setCaretAtOffset(ctx.li, offInLi);
    scheduleSave();
  }

  /* ---------- 块类型切换（快捷键） ---------- */

  function applyBlockType(type) {
    var el = activeBlock();
    if (!el) return;
    var cur = el.getAttribute('data-type');
    var md;

    if (type === 'ul' || type === 'ol') {
      var marker = type === 'ol' ? '1. ' : '- ';
      if (cur === 'ul' || cur === 'ol') {
        // 有序 <-> 无序互转：保留内容与缩进层级，编号按层级重新排
        var raw = blockMD(el);
        md = (type === 'ol') ? QN_CORE.toOrdered(raw) : QN_CORE.toBullet(raw);
      } else {
        md = serializeNode(el).split('\n').map(function (l) { return marker + l; }).join('\n');
      }
    } else if (cur === 'ul' || cur === 'ol') {
      md = QN_CORE.stripMarkers(blockMD(el));          // 列表转段落
    } else {
      var text = serializeNode(el);
      if (type === 'h1') md = '# ' + text;
      else if (type === 'h2') md = '## ' + text;
      else if (type === 'h3') md = '### ' + text;
      else if (type === 'quote') md = '> ' + text.split('\n').join('\n> ');
      else md = QN_CORE.stripMarkers(blockMD(el));
    }
    renderInto(el, type, md);
    focusBlock(el);
    scheduleSave();
  }

  function toggleTask(task) {
    task.classList.toggle('qn-done');
    // 已完成的项整行变淡。用 JS 加 class，而不是 CSS :has()——
    // 后者在老版本 WebKit 上不一定认。
    scheduleSave();
    flush();
  }

  function execInline(cmd) {
    document.execCommand(cmd);
    scheduleSave();
  }

  /* ---------- 表格单元格导航 ---------- */

  function selectCell(cell) {
    // contenteditable 容器里的子元素不能被 focus()，必须先把宿主块拿到焦点，
    // 再用 Range 把光标落进单元格。直接 cell.focus() 是空操作。
    var block = cell.closest ? cell.closest('.qn-block') : null;
    if (block) block.focus();
    var r = document.createRange();
    r.selectNodeContents(cell);
    r.collapse(true);
    var s = window.getSelection();
    s.removeAllRanges();
    s.addRange(r);
  }

  /// 光标所在的表格单元格。
  ///
  /// 不能用 e.target：contenteditable 里键盘事件的 target 是编辑宿主（.qn-block），
  /// 不是里面的 td——直接 closest('td') 永远是 null，表格导航会静默失效。
  /// 必须从 Selection 的锚点节点往上找。
  function cellAtCaret() {
    var sel = window.getSelection();
    if (!sel || !sel.rangeCount) return null;
    var n = sel.anchorNode;
    if (!n) return null;
    if (n.nodeType === 3) n = n.parentNode;
    return (n && n.closest) ? n.closest('td, th') : null;
  }

  /// 表格里 Enter / Tab 不拆块：Tab 前后跳格，Enter 下移一行（末尾自动加行）。
  /// 不做「Enter 换行」——Markdown 表格不支持单元格内多行，
  /// 允许换行会让存盘内容丢格式。
  function handleTableNav(e, cell) {
    e.preventDefault();
    e.stopPropagation();
    var table = cell.closest('table');
    if (!table) return;
    var row = cell.parentNode;
    var rows = Array.prototype.slice.call(table.querySelectorAll('tr'));
    var rowIdx = rows.indexOf(row);
    var colIdx = Array.prototype.indexOf.call(row.children, cell);

    if (e.key === 'Tab') {
      var flat = [];
      for (var r = 0; r < rows.length; r++) {
        var cs = rows[r].children;
        for (var c = 0; c < cs.length; c++) flat.push(cs[c]);
      }
      var idx = flat.indexOf(cell);
      var next = flat[idx + (e.shiftKey ? -1 : 1)];
      if (next) selectCell(next);
      return;
    }

    // Enter
    var nextRow = rows[rowIdx + 1];
    if (!nextRow) {
      var cols = row.children.length;
      var tr = document.createElement('tr');
      for (var i = 0; i < cols; i++) {
        var td = document.createElement('td');
        td.setAttribute('contenteditable', 'true');
        tr.appendChild(td);
      }
      (table.querySelector('tbody') || table).appendChild(tr);
      selectCell(tr.children[Math.min(colIdx, cols - 1)]);
      scheduleSave();
      return;
    }
    var target = nextRow.children[Math.min(colIdx, nextRow.children.length - 1)];
    if (target) selectCell(target);
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

      // 表格单元格优先：Enter / Tab 在格内移动，不触发拆块
      var cell = cellAtCaret();
      if (cell && (e.key === 'Enter' || e.key === 'Tab')) {
        handleTableNav(e, cell);
        return;
      }

      if (mod && !e.altKey) {
        if (k === 'b') { e.preventDefault(); execInline('bold'); return; }
        if (k === 'i') { e.preventDefault(); execInline('italic'); return; }
        if (k === 'x' && e.shiftKey) { e.preventDefault(); execInline('strikeThrough'); return; }
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
        handleTab(e, !e.shiftKey);
        return;
      }
    });

    // 任务勾选
    editorRoot.addEventListener('click', function (e) {
      var task = e.target.closest ? e.target.closest('li.qn-task') : null;
      if (!task) return;
      var taskRect = task.getBoundingClientRect();
      var marker = window.getComputedStyle(task, '::before');
      var markerLeft = taskRect.left + parseFloat(marker.left || '0');
      var markerTop = taskRect.top + parseFloat(marker.top || '0');
      var markerRight = markerLeft + parseFloat(marker.width || '0');
      var markerBottom = markerTop + parseFloat(marker.height || '0');
      if (e.clientX < markerLeft || e.clientX >= markerRight ||
          e.clientY < markerTop || e.clientY >= markerBottom) return;
      e.preventDefault();
      toggleTask(task);
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

    // 粘贴图片：交给 Swift 落盘到文档旁的 assets/，回来再插成图片块。
    // 不内联 base64——md 是纯文本，内联会让文件膨胀几十倍且进不了 Git。
    editorRoot.addEventListener('paste', function (e) {
      var cd = e.clipboardData;
      if (!cd || !cd.items) return;
      for (var i = 0; i < cd.items.length; i++) {
        var it = cd.items[i];
        if (it.kind !== 'file' || String(it.type).indexOf('image/') !== 0) continue;
        e.preventDefault();
        var f = it.getAsFile();
        if (!f) return;
        sendImageFile(f);
        return;
      }
    });

    // 拖图进来：同一个落盘通道
    document.addEventListener('dragover', function (e) { e.preventDefault(); });
    document.addEventListener('drop', function (e) {
      var dt = e.dataTransfer;
      if (!dt || !dt.files || !dt.files.length) return;
      var f = dt.files[0];
      if (String(f.type).indexOf('image/') !== 0) return;
      e.preventDefault();
      sendImageFile(f);
    });
  }

  function sendImageFile(file) {
    var reader = new FileReader();
    reader.onload = function () {
      var res = String(reader.result || '');
      var comma = res.indexOf(',');
      if (comma < 0) return;
      var ext = (String(file.type).split('/')[1] || 'png').toLowerCase()
        .replace('jpeg', 'jpg').replace('svg+xml', 'svg');
      post({ type: 'saveImage', name: 'pasted.' + ext, data: res.slice(comma + 1) });
    };
    reader.readAsDataURL(file);
  }

  function createAndAppend(type, md) {
    var el = createBlockEl(type, md);
    editorRoot.appendChild(el);
    return el;
  }

  /* ---------- 对外接口 ---------- */

  function load(md, file, baseDir) {
    // 清掉挂起的保存定时器。切文件时必须做：否则 200ms 后那次 flush
    // 会把「上一份文档的内容」写给「刚切换到的这个文件」（串档）。
    if (saveTimer) { clearTimeout(saveTimer); saveTimer = null; }
    state.file = file || '';
    state.baseDir = baseDir || '';
    editorRoot.innerHTML = '';
    var blocks = QN_CORE.parse(md || '');
    if (!blocks.length) blocks = [{ type: 'p', md: '' }];
    blocks.forEach(function (b) { editorRoot.appendChild(createBlockEl(b.type, b.md)); });
    resolveImages();
    updateEditorState();
    setNotice('');            // 换文件即清掉上一份的异常提示
  }

  function init() {
    editorRoot = document.getElementById('qn-editor');
    if (!editorRoot) return;
    bindEvents();
    load('', '');
    post({ type: 'ready' });
  }

  /// Swift 把图片落盘后回调这里：在当前块后面插入图片块，并补一个空段落接着写。
  function insertImage(rel) {
    var cur = activeBlock();
    var el = createBlockEl('image', '![](' + rel + ')');
    if (cur && cur.parentNode) cur.parentNode.insertBefore(el, cur.nextSibling);
    else editorRoot.appendChild(el);
    resolveImages();
    var p = createBlockEl('p', '');
    el.parentNode.insertBefore(p, el.nextSibling);
    focusBlock(p, 0);
    scheduleSave();
    flush();
  }

  root.QN = {
    load: load,
    getMarkdown: getMarkdown,
    flush: flush,
    init: init,
    insertImage: insertImage,
    setNotice: setNotice,
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
