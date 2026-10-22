/* Quickmd 编辑器内核单测（Node 直接跑，无需依赖）
 * 用法：node Tests/editor-core.test.js
 * 只测 editor-core.js 里的纯函数——DOM 交互层（变形、缩进、Enter）需要真实浏览器，
 * 走 App 的 --mdtest / --clicktest 诊断开关验证。
 */
const QN = require('../Sources/Quickmd/Resources/editor-core.js');
let pass = 0, fail = 0;
function eq(name, got, want) {
  const ok = got === want;
  ok ? pass++ : fail++;
  console.log((ok ? 'PASS ' : 'FAIL ') + name);
  if (!ok) console.log('   got : ' + JSON.stringify(got) + '\n   want: ' + JSON.stringify(want));
}
function has(name, got, needle) {
  const ok = got.indexOf(needle) !== -1;
  ok ? pass++ : fail++;
  console.log((ok ? 'PASS ' : 'FAIL ') + name);
  if (!ok) console.log('   got : ' + JSON.stringify(got) + '\n   want contains: ' + JSON.stringify(needle));
}
function not(name, got, needle) {
  const ok = got.indexOf(needle) === -1;
  ok ? pass++ : fail++;
  console.log((ok ? 'PASS ' : 'FAIL ') + name);
  if (!ok) console.log('   got: ' + JSON.stringify(got));
}

// ---- 行内渲染 ----
eq('行内-加粗', QN.inline('**粗**'), '<strong>粗</strong>');
eq('行内-斜体星', QN.inline('*斜*'), '<em>斜</em>');
eq('行内-斜线下划', QN.inline('_斜_'), '<em>斜</em>');
eq('行内-删除线', QN.inline('~~删~~'), '<del>删</del>');
eq('行内-代码', QN.inline('`x`'), '<code>x</code>');
eq('行内-链接', QN.inline('[a](https://b.c)'), '<a href="https://b.c" target="_blank" rel="noreferrer">a</a>');
eq('行内-URL自动', QN.inline('见 https://a.b ').indexOf('href="https://a.b"') > -1 ? 'y' : 'n', 'y');
not('行内-代码内星号不解析', QN.inline('`a**b**`'), '<strong>');
not('行内-HTML转义', QN.inline('<script>'), '<script>');
has('行内-HTML转义结果', QN.inline('<script>alert(1)</script>'), '&lt;script&gt;');
not('行内-词内星号不误判', QN.inline('a*b*c'), '<em>');

// ---- 块解析与渲染 ----
eq('块-h1', QN.parse('# 标题')[0].type, 'h1');
eq('块-h2', QN.parse('## 标题')[0].type, 'h2');
eq('块-h3', QN.parse('### 标题')[0].type, 'h3');
eq('块-段落', QN.parse('普通文字')[0].type, 'p');
eq('块-引用', QN.parse('> 引用内容')[0].type, 'quote');
eq('块-无序列表', QN.parse('- 甲\n- 乙')[0].type, 'ul');
eq('块-有序列表', QN.parse('1. 甲\n2. 乙')[0].type, 'ol');
eq('块-代码', QN.parse('```\ncode\n```')[0].type, 'code');
eq('块-分隔线', QN.parse('---')[0].type, 'hr');
eq('块-列表合并', QN.parse('- a\n- b\n- c')[0].md.split('\n').length, 3);
eq('块-引用合并', QN.parse('> a\n> b')[0].md, '> a\n> b');
eq('块-空文档', QN.parse('').length, 0);

has('渲染-h1', QN.renderBlock({type:'h1', md:'# T'}), '<h1>T</h1>');
has('渲染-列表', QN.renderBlock({type:'ul', md:'- a\n- b'}), '<li>a</li><li>b</li>');
has('渲染-任务未完成', QN.renderBlock({type:'ul', md:'- [ ] todo'}), 'qn-box');
not('渲染-任务未完成无on', QN.renderBlock({type:'ul', md:'- [ ] todo'}), 'qn-box on');
has('渲染-任务已完成', QN.renderBlock({type:'ul', md:'- [x] done'}), 'qn-box on');
has('渲染-代码', QN.renderBlock({type:'code', md:'```\nlet a=1;\n```'}), '<code>let a=1;</code>');
has('渲染-引用', QN.renderBlock({type:'quote', md:'> hi'}), '<blockquote>');
eq('渲染-分隔线', QN.renderBlock({type:'hr', md:'---'}), '<hr>');

// ---- 往返一致性：parse -> md 重组（与 getMarkdown 的 '\n\n' 连接保持一致）----
const doc = '# 标题\n\n正文**加粗**一段。\n\n- 甲\n- [x] 已完成\n\n> 引用行\n\n1. 第一\n2. 第二\n\n```\nlet a = 1;\n```\n\n---\n\n结尾段';
const blocks = QN.parse(doc);
const roundTrip = blocks.map(b => b.md).join('\n\n');
eq('往返-块数', blocks.length, 8);
has('往返-标题保留', roundTrip, '# 标题');
has('往返-任务保留', roundTrip, '- [x] 已完成');
has('往返-代码保留', roundTrip, 'let a = 1;');
has('往返-分隔线', roundTrip, '---');
has('往返-引用', roundTrip, '> 引用行');
has('往返-段间空行', roundTrip, '正文**加粗**一段。\n\n- 甲');
eq('往返-二次解析稳定', QN.parse(roundTrip).length, blocks.length);

// ---- stripMarkers ----
eq('降级-h1', QN.stripMarkers('# 标题'), '标题');
eq('降级-列表', QN.stripMarkers('- 甲'), '甲');
eq('降级-引用', QN.stripMarkers('> 话'), '话');
eq('降级-有序', QN.stripMarkers('1. 甲'), '甲');

// ---- 安全性：XSS ----
not('安全-script不注入', QN.renderBlock({type:'p', md:'<script>alert(1)</script>'}), '<script>');
not('安全-img不注入', QN.renderBlock({type:'p', md:'<img src=x onerror=alert(1)>'}), '<img');
not('安全-链接协议', QN.renderBlock({type:'p', md:'[x](javascript:alert(1))'}), 'javascript:');
not('安全-js协议拦截', QN.renderBlock({type:'p', md:'[x](javascript:alert(1))'}), 'javascript:');
not('安全-data协议拦截', QN.renderBlock({type:'p', md:'[x](data:text/html,<b>)'}), 'data:text');
// 属性注入的判定标准是「有没有裸属性逃逸」，不是「文本里有没有这个词」：
// `onmouseover="alert(1))` 里的引号被转义成 &quot; 后只是可见文本，不会变成属性。
not('安全-属性注入', QN.renderBlock({type:'p', md:'[x](https://a" onmouseover="alert(1))'}), 'onmouseover="');
not('安全-属性注入-未转义引号', QN.renderBlock({type:'p', md:'[x](https://a" onmouseover="alert(1))'}), 'onmouseover=alert');
has('安全-正常链接保留', QN.renderBlock({type:'p', md:'[ok](https://example.com)'}), 'href="https://example.com"');
has('安全-相对链接保留', QN.renderBlock({type:'p', md:'[ok](./doc.md)'}), 'href="./doc.md"');

// ---- 嵌套列表 ----
var nested = '- 甲\n  - 甲一\n  - 甲二\n- 乙';
var nb = QN.parse(nested);
eq('嵌套-解析为单块', nb.length, 1);
eq('嵌套-类型ul', nb[0].type, 'ul');
has('嵌套-渲染出ul', QN.renderBlock(nb[0]), '<ul>');
has('嵌套-渲染出嵌套ul', QN.renderBlock(nb[0]), '<li>甲<ul><li>甲一</li>');
has('嵌套-保留缩进md', nb[0].md, '- 甲\n  - 甲一\n  - 甲二\n- 乙');

// ---- 代码块语言标签 ----
eq('代码-语言解析', QN.parse('```swift\nlet a=1\n```')[0].md.split('\n')[0], '```swift');

// ---- 任务列表标记往返 ----
var taskDoc = '- [ ] 未完成\n- [x] 已完成';
var tb = QN.parse(taskDoc);
has('任务-渲染未完成', QN.renderBlock(tb[0]), 'qn-box');
has('任务-渲染已完成', QN.renderBlock(tb[0]), 'qn-box on');
has('任务-md保留', tb[0].md, '[x] 已完成');

// ---- v3 新增：任务列表前缀（- [ ] 空格）能被解析成任务项 ----
var taskPrefix = QN.parse('- [ ] 待办');
eq('任务前缀-类型ul', taskPrefix[0].type, 'ul');
has('任务前缀-渲染出勾选框', QN.renderBlock(taskPrefix[0]), 'qn-box');
has('任务前缀-正文保留', QN.renderBlock(taskPrefix[0]), '待办');

// ---- v3 新增：缩进层级在 md 里的表达（Tab 一次 = 两个空格）----
eq('缩进-一级', QN.parse('- 甲\n  - 乙')[0].md, '- 甲\n  - 乙');
eq('缩进-两级', QN.parse('- 甲\n    - 乙')[0].md, '- 甲\n    - 乙');
has('缩进-渲染出两层嵌套', QN.renderBlock(QN.parse('- 甲\n  - 乙')[0]), '<li>甲<ul><li>乙</li></ul></li>');

// ---- v3 新增：有序列表起始序号（Typora 行为：写 3. 就从 3 开始）----
var olDoc = QN.parse('3. 第三\n4. 第四');
eq('有序-解析为ol', olDoc[0].type, 'ol');
has('有序-起始序号写入start', QN.renderBlock(olDoc[0]), '<ol start="3">');
has('有序-首项内容保留', QN.renderBlock(olDoc[0]), '<li>第三</li>');
has('有序-序号1不写start', QN.renderBlock(QN.parse('1. 一\n2. 二')[0]), '<ol>');
has('有序-嵌套保序号', QN.renderBlock(QN.parse('1. 外\n   5. 内')[0]), '<ol start="5">');

// ---- v3 新增：列表标记互转（ul <-> ol）按层级重新编号 ----
eq('互转-转有序从1开始', QN.toOrdered('- 甲\n- 乙'), '1. 甲\n2. 乙');
eq('互转-转有序嵌套分层', QN.toOrdered('- 甲\n  - 甲一\n- 乙'), '1. 甲\n  1. 甲一\n2. 乙');
eq('互转-转有序保留原号', QN.toOrdered('3. 甲\n4. 乙'), '3. 甲\n4. 乙');
eq('互转-转无序', QN.toBullet('1. 甲\n2. 乙'), '- 甲\n- 乙');
eq('互转-转无序保缩进', QN.toBullet('1. 甲\n   2. 乙'), '- 甲\n   - 乙');

// ---- v3 新增：多行列表整体降级时，每行标记都要去掉 ----
eq('降级-多行列表去干净', QN.stripMarkers('1. 甲\n2. 乙'), '甲\n乙');
eq('降级-任务行去标记', QN.stripMarkers('- [ ] 待办'), '待办');

console.log('\n===== ' + pass + ' 通过, ' + fail + ' 失败 =====');
process.exit(fail ? 1 : 0);
