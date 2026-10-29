/* Quickmd 工作区侧栏 · 文件浏览层
 * ---------------------------------------------------------------------------
 * 职责：把 Swift 推来的「当前目录 + md 文件列表 + 快捷目录」渲染成访达式侧栏，
 * 并把点击/右键/搜索/新建翻译成消息发回 Swift。
 *
 * 设计边界（很重要）：
 *   前端**不碰文件系统**，一行 fs 代码都没有。所有真实读写都在 Swift 侧，
 *   这里只负责「显示 Swift 给的数据」和「把用户意图告诉 Swift」。
 *   这样权限、错误处理、废纸篓回收只有一处实现，不会两边不一致。
 *
 *   Swift → 前端：QN.setWorkspace(payload) / QN.setMode(mode)
 *   前端 → Swift：{type:'openFile'|'openFolder'|'newFile'|'deleteFile'|...}
 */
(function (root) {
  'use strict';

  var QN = root.QN;
  if (!QN) return;

  /* ============================ 状态 ============================ */

  var ws = {
    dir: '',
    dirName: '',
    files: [],
    shortcuts: [],
    current: '',
    mode: 'capture'
  };

  var pendingDelete = null;      // 「点两次才删」的临时标记
  var renaming = null;           // 正在原地改名的文件路径

  /* ============================ 工具 ============================ */

  function $(id) { return document.getElementById(id); }

  function esc(s) {
    return String(s == null ? '' : s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;')
      .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }

  function post(msg) {
    if (root.webkit && root.webkit.messageHandlers && root.webkit.messageHandlers.quickmd) {
      root.webkit.messageHandlers.quickmd.postMessage(msg);
    }
  }

  function pad2(n) { return n < 10 ? '0' + n : '' + n; }

  /** 相对时间：今天给时分，昨天给「昨天」，今年给月日，更早给年月 */
  function relTime(ts) {
    if (!ts) return '';
    var d = new Date(ts * 1000);
    if (isNaN(d.getTime())) return '';
    var now = new Date();
    if (d.toDateString() === now.toDateString()) {
      return pad2(d.getHours()) + ':' + pad2(d.getMinutes());
    }
    var y = new Date(now.getTime());
    y.setDate(now.getDate() - 1);
    if (d.toDateString() === y.toDateString()) return '昨天';
    if (d.getFullYear() === now.getFullYear()) {
      return (d.getMonth() + 1) + '月' + d.getDate() + '日';
    }
    return d.getFullYear() + '/' + (d.getMonth() + 1);
  }

  var ICON_FILE =
    '<svg width="12" height="14" viewBox="0 0 12 14" fill="none" aria-hidden="true">' +
    '<path d="M1.55 1.6h4.9l4 3.9v7a1 1 0 0 1-1 1h-7.9a1 1 0 0 1-1-1v-9.9a1 1 0 0 1 1-1z" ' +
    'stroke="currentColor" stroke-width="1.1" stroke-linejoin="round"/>' +
    '<path d="M6.4 1.6v4h4" stroke="currentColor" stroke-width="1.1" stroke-linejoin="round"/></svg>';

  var ICON_FOLDER =
    '<svg width="13" height="12" viewBox="0 0 13 12" fill="none" aria-hidden="true">' +
    '<path d="M1 3.1v6.4a1 1 0 0 0 1 1h9a1 1 0 0 0 1-1V4.1a1 1 0 0 0-1-1H6.2L5 1.4H2a1 1 0 0 0-1 1z" ' +
    'stroke="currentColor" stroke-width="1.1" stroke-linejoin="round"/></svg>';

  /* ============================ 渲染：文件列表 ============================ */

  function renderFiles() {
    var list = $('qn-files');
    if (!list) return;
    var q = ($('qn-search') && $('qn-search').value || '').trim().toLowerCase();

    var files = ws.files.filter(function (f) {
      return !q || String(f.name).toLowerCase().indexOf(q) >= 0;
    });

    if (!files.length) {
      list.innerHTML = '<div class="qn-empty">' +
        (q ? '没有匹配的文件'
           : '这个文件夹还没有笔记<br>点标题右边「新」写一条') + '</div>';
      return;
    }

    var html = '';
    for (var i = 0; i < files.length; i++) {
      var f = files[i];
      var active = f.path === ws.current;
      html += '<div class="qn-row' + (active ? ' is-active' : '') + '"'
            + ' data-path="' + esc(f.path) + '" data-name="' + esc(f.name) + '"'
            + ' title="' + esc(f.name) + '">'
            + '<span class="qn-row-icon">' + ICON_FILE + '</span>'
            + '<span class="qn-row-name">' + esc(f.name) + '</span>'
            + '<span class="qn-row-meta">' + esc(relTime(f.modified)) + '</span>'
            + '</div>';
    }
    list.innerHTML = html;
  }

  /* ============================ 渲染：快捷目录 ============================ */

  function renderShortcuts() {
    var list = $('qn-shortcuts');
    if (!list) return;
    if (!ws.shortcuts.length) {
      list.innerHTML = '<div class="qn-empty">还没有快捷目录<br>点标题右边「＋」加一个</div>';
      return;
    }
    var html = '';
    for (var i = 0; i < ws.shortcuts.length; i++) {
      var s = ws.shortcuts[i];
      var active = s.path === ws.dir;
      html += '<div class="qn-row' + (active ? ' is-active' : '') + '"'
            + ' data-path="' + esc(s.path) + '" data-kind="shortcut"'
            + ' title="' + esc(s.path) + '">'
            + '<span class="qn-row-icon">' + ICON_FOLDER + '</span>'
            + '<span class="qn-row-name">' + esc(s.name) + '</span>'
            + '<span class="qn-row-x" data-remove="' + esc(s.path) + '" title="移出快捷目录">×</span>'
            + '</div>';
    }
    list.innerHTML = html;
  }

  function renderAll() {
    var name = $('qn-dir-name');
    if (name) {
      name.textContent = ws.dirName || 'Quickmd';
      name.title = ws.dir || '';
    }
    renderShortcuts();
    renderFiles();
  }

  /* ============================ 右键菜单 ============================ */

  function hideMenu() {
    var m = $('qn-menu');
    if (m) { m.hidden = true; m.innerHTML = ''; }
    pendingDelete = null;
  }

  /**
   * items: [{label, danger, onClick}] 或 'sep'
   * 位置会往回收，避免贴边被裁掉。
   */
  function showMenu(x, y, items) {
    var m = $('qn-menu');
    if (!m) return;
    var html = '';
    for (var i = 0; i < items.length; i++) {
      var it = items[i];
      if (it === 'sep') { html += '<div class="qn-menu-sep"></div>'; continue; }
      html += '<div class="qn-menu-item' + (it.danger ? ' is-danger' : '') + '"'
            + ' data-idx="' + i + '">' + esc(it.label) + '</div>';
    }
    m.innerHTML = html;
    m.hidden = false;
    // 先显示再量尺寸，才能算回收位置
    var rect = m.getBoundingClientRect();
    var vw = root.innerWidth, vh = root.innerHeight;
    if (x + rect.width > vw - 4) x = Math.max(4, vw - rect.width - 4);
    if (y + rect.height > vh - 4) y = Math.max(4, vh - rect.height - 4);
    m.style.left = x + 'px';
    m.style.top = y + 'px';

    m.onclick = function (e) {
      var row = e.target.closest('.qn-menu-item');
      if (!row) return;
      var item = items[parseInt(row.getAttribute('data-idx'), 10)];
      hideMenu();
      if (item && item.onClick) item.onClick();
    };
  }

  /* ============================ 原地改名 ============================ */

  /** 访达式改名：把名字变成输入框，回车确认、Esc 取消、失焦即提交。 */
  function startRename(row) {
    var path = row.getAttribute('data-path');
    var nameEl = row.querySelector('.qn-row-name');
    if (!nameEl || renaming) return;
    renaming = path;
    var old = row.getAttribute('data-name') || nameEl.textContent;

    var input = document.createElement('input');
    input.value = old;
    input.spellcheck = false;
    input.style.cssText = 'flex:1 1 auto;min-width:0;font:inherit;font-size:12px;'
      + 'border:1px solid rgba(10,124,255,.55);border-radius:4px;padding:0 4px;'
      + 'outline:none;background:#fff;-webkit-user-select:text;user-select:text;';
    nameEl.replaceWith(input);
    input.focus();
    input.select();

    var done = false;
    function commit(ok) {
      if (done) return;
      done = true;
      renaming = null;
      var v = input.value.trim();
      if (ok && v && v !== old) {
        post({ type: 'renameFile', path: path, name: v });
      } else {
        renderFiles();       // 还原显示
      }
    }
    input.addEventListener('keydown', function (e) {
      e.stopPropagation();
      if (e.key === 'Enter') { e.preventDefault(); commit(true); }
      if (e.key === 'Escape') { e.preventDefault(); commit(false); }
    });
    input.addEventListener('blur', function () { commit(true); });
  }

  /* ============================ 事件 ============================ */

  function bind() {
    // 点侧栏：文件 / 快捷目录
    var side = $('qn-side');
    if (side) {
      side.addEventListener('mousedown', function (e) {
        // 点空白处收起右键菜单
        if (!$('qn-menu').hidden && !e.target.closest('#qn-menu')) hideMenu();
      });

      side.addEventListener('click', function (e) {
        var rm = e.target.closest('[data-remove]');
        if (rm) {
          e.stopPropagation();
          post({ type: 'removeShortcut', path: rm.getAttribute('data-remove') });
          return;
        }
        var row = e.target.closest('.qn-row');
        if (!row) return;
        var path = row.getAttribute('data-path');
        if (row.getAttribute('data-kind') === 'shortcut') {
          if (path === ws.dir) return;
          post({ type: 'openFolder', path: path });
        } else {
          if (path === ws.current) return;
          post({ type: 'openFile', path: path });
        }
      });

      // 右键
      side.addEventListener('contextmenu', function (e) {
        var row = e.target.closest('.qn-row');
        if (!row) return;
        e.preventDefault();
        var path = row.getAttribute('data-path');
        if (row.getAttribute('data-kind') === 'shortcut') {
          showMenu(e.clientX, e.clientY, [
            { label: '在访达中显示', onClick: function () { post({ type: 'reveal', path: path }); } },
            { label: '移出快捷目录', onClick: function () { post({ type: 'removeShortcut', path: path }); } }
          ]);
          return;
        }
        showMenu(e.clientX, e.clientY, [
          { label: '打开', onClick: function () { post({ type: 'openFile', path: path }); } },
          { label: '重命名', onClick: function () { startRename(row); } },
          'sep',
          { label: '在访达中显示', onClick: function () { post({ type: 'reveal', path: path }); } },
          'sep',
          {
            label: pendingDelete === path ? '确认删除？' : '移到废纸篓',
            danger: true,
            onClick: null     // 下面单独处理两步确认
          }
        ]);
        // 两步确认：第一次点只换文案，第二次才真删
        var menu = $('qn-menu');
        var danger = menu.querySelector('.qn-menu-item.is-danger');
        if (danger) {
          var arm = function () {
            if (pendingDelete !== path) {
              pendingDelete = path;
              danger.textContent = '确认删除？';
              danger.addEventListener('mouseup', arm, { once: true });
              return;
            }
            hideMenu();
            post({ type: 'deleteFile', path: path });
          };
          danger.addEventListener('mouseup', arm, { once: true });
        }
      });
    }

    // 搜索
    var search = $('qn-search');
    if (search) {
      search.addEventListener('input', renderFiles);
      search.addEventListener('keydown', function (e) {
        e.stopPropagation();
        if (e.key === 'Escape') { search.value = ''; renderFiles(); search.blur(); }
      });
    }

    // 新建
    var newBtn = $('qn-new-file');
    if (newBtn) newBtn.addEventListener('click', function () {
      post({ type: 'newFile' });
    });

    // 选择工作文件夹（侧栏 ＋；也是自动钉快捷目录的入口）
    var pick = $('qn-pick-folder');
    if (pick) pick.addEventListener('click', function () {
      post({ type: 'chooseFolder' });
    });

    // 收起侧栏 → 回快捕态
    var collapse = $('qn-collapse');
    if (collapse) collapse.addEventListener('click', function () {
      post({ type: 'mode', mode: 'capture' });
    });

    // 状态栏「文件」按钮 → 展开浏览态
    var expand = $('qn-expand');
    if (expand) expand.addEventListener('click', function () {
      post({ type: 'mode', mode: 'browse' });
    });

    // 点别处收起右键菜单
    document.addEventListener('mousedown', function (e) {
      var m = $('qn-menu');
      if (m && !m.hidden && !e.target.closest('#qn-menu')) hideMenu();
    });
  }

  /* ============================ 对外接口 ============================ */

  QN.setWorkspace = function (payload) {
    if (!payload) return;
    ws.dir = payload.dir || '';
    ws.dirName = payload.dirName || '';
    ws.files = payload.files || [];
    ws.shortcuts = payload.shortcuts || [];
    ws.current = payload.current || '';
    if (payload.mode) QN.setMode(payload.mode);
    renderAll();
  };

  QN.setMode = function (mode) {
    ws.mode = mode === 'browse' ? 'browse' : 'capture';
    var app = $('qn-app');
    if (app) app.setAttribute('data-mode', ws.mode);
  };

  // 当前文件被改名后，状态栏文件名要跟着换（Swift 不重推内容，只推工作区）
  QN.currentFile = function () { return ws.current; };

  function init() {
    bind();
    renderAll();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})(typeof window !== 'undefined' ? window : globalThis);
