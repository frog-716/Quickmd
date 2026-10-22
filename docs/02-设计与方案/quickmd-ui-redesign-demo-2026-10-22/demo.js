(function () {
  'use strict';

  var params = new URLSearchParams(window.location.search);
  var view = params.get('state') || 'ready';
  var storageKey = 'quickmd-ui-redesign-demo-content';
  var fileKey = 'quickmd-ui-redesign-demo-file';
  var sample = [
    '# 今天的重点',
    '',
    '先把编辑区改顺手，再把保存流程检查一遍。',
    '',
    '- [x] 确认浅色界面的方向',
    '- [ ] 调整便签编辑区',
    '- [ ] 补齐保存状态的检查'
  ].join('\n');

  var fileName = localStorage.getItem(fileKey) || 'scratch.md';
  var initial = view === 'empty'
    ? ''
    : (view === 'unsaved' ? sample : (localStorage.getItem(storageKey) || sample));

  window.webkit = window.webkit || {};
  window.webkit.messageHandlers = window.webkit.messageHandlers || {};
  window.webkit.messageHandlers.quickmd = {
    postMessage: function (message) {
      if (message.type === 'ready') {
        window.QN.load(initial, fileName);
        document.documentElement.dataset.state = view;
        if (view === 'ready') {
          try {
            localStorage.setItem(storageKey, initial);
            localStorage.setItem(fileKey, fileName);
            document.getElementById('qn-savestate').textContent = '已保存';
          } catch (error) {
            console.error('Demo local save failed', error);
          }
        }
        if (view === 'unsaved') {
          var status = document.getElementById('qn-status');
          status.classList.add('qn-dirty');
          document.getElementById('qn-savestate').textContent = '未保存';
        }
      }
      if (message.type === 'save') {
        try {
          localStorage.setItem(storageKey, message.md);
          localStorage.setItem(fileKey, fileName);
        } catch (error) {
          console.error('Demo local save failed', error);
        }
      }
    }
  };

  document.addEventListener('DOMContentLoaded', function () {
    var editor = document.getElementById('qn-editor');
    function focusTaskText(task) {
      var text = task && task.querySelector(':scope > span:last-child');
      if (!text) return;
      var block = task.closest('.qn-block');
      if (block) block.focus();
      var range = document.createRange();
      range.selectNodeContents(text);
      range.collapse(true);
      var selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
    }

    editor.addEventListener('mousedown', function (event) {
      var task = event.target.closest && event.target.closest('li.qn-task');
      if (!task || (event.target.closest && event.target.closest('.qn-box'))) return;

      var text = task.querySelector(':scope > span:last-child');
      if (!text || event.clientX >= text.getBoundingClientRect().left) return;

      // 点击复选框左侧的留白时，把光标放进文字开头，避免落在复选框前面。
      event.preventDefault();
      focusTaskText(task);
    });

    editor.addEventListener('click', function (event) {
      var box = event.target.closest && event.target.closest('.qn-box');
      if (!box) return;
      var task = box.closest('li.qn-task');
      // 勾选框不接收文字输入；点击后把光标挪到标签开头。
      requestAnimationFrame(function () { focusTaskText(task); });
    });

    var picker = document.getElementById('qn-file-picker');
    document.getElementById('qn-open-file').addEventListener('click', function () {
      picker.click();
    });
    picker.addEventListener('change', function () {
      var file = picker.files && picker.files[0];
      if (!file) return;
      var reader = new FileReader();
      reader.onload = function () {
        fileName = file.name;
        var content = String(reader.result || '');
        window.QN.load(content, fileName);
        try {
          localStorage.setItem(storageKey, content);
          localStorage.setItem(fileKey, fileName);
          document.getElementById('qn-savestate').textContent = '已保存';
        } catch (error) {
          console.error('Demo local save failed', error);
        }
      };
      reader.readAsText(file, 'UTF-8');
      picker.value = '';
    });
  });
})();
