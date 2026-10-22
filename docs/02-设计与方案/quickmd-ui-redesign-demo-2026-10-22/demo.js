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
    : (view === 'ready' || view === 'unsaved' ? sample : (localStorage.getItem(storageKey) || sample));

  window.webkit = window.webkit || {};
  window.webkit.messageHandlers = window.webkit.messageHandlers || {};
  window.webkit.messageHandlers.quickmd = {
    postMessage: function (message) {
      if (message.type === 'ready') {
        window.QN.load(initial, fileName);
        document.documentElement.dataset.state = view;
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
        window.QN.load(String(reader.result || ''), fileName);
      };
      reader.readAsText(file, 'UTF-8');
      picker.value = '';
    });
  });
})();
