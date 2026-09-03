import Foundation

/// 内嵌的局域网 Web 前端（单文件，无外部依赖）。
/// v2：任务化异步接口（上传 -> task_id -> 轮询）、任务列表、文档库。
enum WebPage {
    static let html = #"""
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>DocuMind · 文档智能</title>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body { font-family: -apple-system, "PingFang SC", "Microsoft YaHei", sans-serif; background: #0f1420; color: #e6e9f0; min-height: 100vh; }
  .container { max-width: 960px; margin: 0 auto; padding: 24px 16px 64px; }
  header { display: flex; align-items: center; gap: 12px; margin-bottom: 20px; }
  .logo { width: 40px; height: 40px; border-radius: 10px; background: linear-gradient(135deg, #4f7cff, #9b5cff); display: flex; align-items: center; justify-content: center; font-size: 20px; }
  h1 { font-size: 22px; font-weight: 600; }
  .subtitle { color: #8b93a7; font-size: 13px; }
  .tabs { display: flex; gap: 8px; margin-bottom: 20px; flex-wrap: wrap; }
  .tab { padding: 9px 18px; border-radius: 999px; border: 1px solid #2a3348; background: #171d2e; color: #aab2c5; cursor: pointer; font-size: 14px; transition: all .15s; }
  .tab.active { background: #4f7cff; border-color: #4f7cff; color: #fff; }
  .panel { background: #171d2e; border: 1px solid #2a3348; border-radius: 14px; padding: 22px; }
  .hidden { display: none; }
  .dropzone { border: 2px dashed #3a4560; border-radius: 12px; padding: 36px 16px; text-align: center; color: #8b93a7; cursor: pointer; transition: border-color .15s; }
  .dropzone:hover, .dropzone.dragover { border-color: #4f7cff; color: #c6d2ff; }
  .dropzone .icon { font-size: 34px; margin-bottom: 8px; }
  .hint { font-size: 12px; color: #6b7386; margin-top: 6px; }
  .btn { display: inline-block; padding: 10px 20px; border-radius: 10px; border: none; background: #4f7cff; color: #fff; font-size: 14px; cursor: pointer; transition: opacity .15s; text-decoration: none; }
  .btn:disabled { opacity: .45; cursor: not-allowed; }
  .btn.secondary { background: #2a3348; }
  .status { margin: 14px 0; font-size: 13px; color: #8b93a7; min-height: 18px; }
  .status.error { color: #ff7a7a; }
  .status.ok { color: #6fe3a5; }
  textarea, select { width: 100%; background: #0f1420; border: 1px solid #2a3348; border-radius: 10px; color: #e6e9f0; padding: 10px 12px; font-size: 14px; font-family: inherit; }
  textarea { resize: vertical; }
  pre.result { background: #0f1420; border: 1px solid #2a3348; border-radius: 10px; padding: 14px; margin-top: 14px; max-height: 420px; overflow: auto; white-space: pre-wrap; word-break: break-word; font-size: 13px; line-height: 1.7; }
  .row { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; }
  .row > * { flex: 1; }
  .row > .shrink { flex: 0 0 auto; }
  .meta { font-size: 12px; color: #6b7386; margin-top: 10px; }
  .chat-list { display: flex; flex-direction: column; gap: 12px; margin-bottom: 14px; max-height: 480px; overflow-y: auto; padding: 4px; }
  .msg { max-width: 85%; padding: 10px 14px; border-radius: 14px; font-size: 14px; line-height: 1.7; white-space: pre-wrap; word-break: break-word; }
  .msg.user { align-self: flex-end; background: #4f7cff; color: #fff; border-bottom-right-radius: 4px; }
  .msg.assistant { align-self: flex-start; background: #232b40; border-bottom-left-radius: 4px; }
  .spinner { display: inline-block; width: 14px; height: 14px; border: 2px solid #4f7cff; border-top-color: transparent; border-radius: 50%; animation: spin .8s linear infinite; vertical-align: middle; margin-right: 6px; }
  @keyframes spin { to { transform: rotate(360deg); } }
  .progressbar { height: 6px; background: #0f1420; border-radius: 3px; overflow: hidden; margin-top: 8px; }
  .progressbar > div { height: 100%; background: linear-gradient(90deg, #4f7cff, #9b5cff); transition: width .3s; }
  table.list { width: 100%; border-collapse: collapse; font-size: 13px; }
  table.list th, table.list td { text-align: left; padding: 10px 8px; border-bottom: 1px solid #232b40; }
  table.list th { color: #6b7386; font-weight: 500; font-size: 12px; }
  table.list tr:hover td { background: #1c2438; }
  .badge { display: inline-block; padding: 2px 10px; border-radius: 999px; font-size: 12px; }
  .badge.pending { background: #3a3320; color: #ffd479; }
  .badge.running { background: #1d3350; color: #7db6ff; }
  .badge.success { background: #173a2a; color: #6fe3a5; }
  .badge.failed { background: #402020; color: #ff7a7a; }
  .doc-item { padding: 12px 14px; border: 1px solid #2a3348; border-radius: 10px; margin-bottom: 8px; cursor: pointer; transition: border-color .15s; }
  .doc-item:hover { border-color: #4f7cff; }
  .doc-item .name { font-size: 14px; }
  .doc-item .sub { font-size: 12px; color: #6b7386; margin-top: 4px; }
</style>
</head>
<body>
<div class="container">
  <header>
    <div class="logo">📄</div>
    <div>
      <h1>DocuMind</h1>
      <div class="subtitle" id="serverInfo">局域网文档智能服务</div>
    </div>
  </header>

  <div class="tabs">
    <button class="tab active" data-tab="ocr">文字识别 OCR</button>
    <button class="tab" data-tab="convert">PDF 转 Word</button>
    <button class="tab" data-tab="tasks">任务队列</button>
    <button class="tab" data-tab="library">文档库</button>
    <button class="tab" data-tab="chat">AI 对话</button>
  </div>

  <!-- OCR -->
  <div class="panel" id="panel-ocr">
    <div class="dropzone" id="ocrDrop">
      <div class="icon">🖼️</div>
      <div>点击选择或拖拽文件到此处</div>
      <div class="hint">支持 PDF / 图片(png, jpg…) / docx / xlsx · 上传后进入任务队列异步识别</div>
      <input type="file" id="ocrFile" accept=".pdf,.png,.jpg,.jpeg,.bmp,.webp,.gif,.docx,.xlsx" style="display:none">
    </div>
    <div class="status" id="ocrStatus"></div>
    <div class="progressbar hidden" id="ocrProgressWrap"><div id="ocrProgress" style="width:0%"></div></div>
    <pre class="result hidden" id="ocrResult"></pre>
    <div class="row" style="margin-top:12px" id="ocrActions" hidden>
      <button class="btn secondary" onclick="copyText('ocrResult')">复制文本</button>
      <button class="btn secondary" onclick="sendToChat()">发送到 AI 对话</button>
      <a class="btn secondary hidden" id="ocrDownload" href="#">下载 TXT</a>
    </div>
  </div>

  <!-- PDF to Word -->
  <div class="panel hidden" id="panel-convert">
    <div class="dropzone" id="pdfDrop">
      <div class="icon">📑</div>
      <div>点击选择或拖拽 PDF 文件</div>
      <div class="hint">本地版面引擎：标题/正文/表格/插图 结构化还原为 Word（表格为真表格，插图按版面裁剪嵌入）</div>
      <input type="file" id="pdfFile" accept=".pdf" style="display:none">
    </div>
    <div class="status" id="pdfStatus"></div>
    <div class="progressbar hidden" id="pdfProgressWrap"><div id="pdfProgress" style="width:0%"></div></div>
  </div>

  <!-- 任务队列 -->
  <div class="panel hidden" id="panel-tasks">
    <div class="row" style="margin-bottom:12px">
      <div class="status" style="margin:0">队列中的任务（每 3 秒自动刷新）</div>
      <button class="btn secondary shrink" onclick="loadTasks()">刷新</button>
    </div>
    <table class="list">
      <thead><tr><th>文件</th><th>类型</th><th>状态</th><th>进度</th><th>引擎</th><th></th></tr></thead>
      <tbody id="taskList"><tr><td colspan="6" style="color:#6b7386">暂无任务</td></tr></tbody>
    </table>
  </div>

  <!-- 文档库 -->
  <div class="panel hidden" id="panel-library">
    <div class="row" style="margin-bottom:12px">
      <div class="status" style="margin:0">已入库的文档</div>
      <button class="btn secondary shrink" onclick="loadDocuments()">刷新</button>
    </div>
    <div id="docList"></div>
    <pre class="result hidden" id="docText"></pre>
  </div>

  <!-- Chat -->
  <div class="panel hidden" id="panel-chat">
    <div class="row" style="margin-bottom:14px">
      <select id="providerSelect" class="shrink" style="width:auto;min-width:220px"></select>
      <button class="btn secondary shrink" onclick="clearChat()">清空对话</button>
    </div>
    <div class="chat-list" id="chatList"></div>
    <textarea id="chatInput" rows="3" placeholder="输入问题，Enter 发送 / Shift+Enter 换行"></textarea>
    <div class="row" style="margin-top:10px">
      <div class="status" id="chatStatus" style="margin:0"></div>
      <button class="btn shrink" id="sendBtn" onclick="sendChat()">发送</button>
    </div>
  </div>

  <div class="meta">DocuMind 本机服务 · 仅在局域网内可访问 · 请勿暴露到公网</div>
</div>

<script>
let lastOCRText = "";
let chatHistory = [];
let tasksTimer = null;

// ---------- Tab 切换 ----------
document.querySelectorAll('.tab').forEach(btn => {
  btn.addEventListener('click', () => {
    document.querySelectorAll('.tab').forEach(b => b.classList.remove('active'));
    btn.classList.add('active');
    ['ocr', 'convert', 'tasks', 'library', 'chat'].forEach(t => {
      document.getElementById('panel-' + t).classList.toggle('hidden', t !== btn.dataset.tab);
    });
    if (tasksTimer) { clearInterval(tasksTimer); tasksTimer = null; }
    if (btn.dataset.tab === 'tasks') { loadTasks(); tasksTimer = setInterval(loadTasks, 3000); }
    if (btn.dataset.tab === 'library') { loadDocuments(); }
  });
});

// ---------- 工具 ----------
function setStatus(id, msg, cls) {
  const el = document.getElementById(id);
  el.className = 'status ' + (cls || '');
  el.innerHTML = msg || '';
}
function setProgress(wrapId, barId, p) {
  const wrap = document.getElementById(wrapId);
  wrap.classList.toggle('hidden', p == null);
  if (p != null) document.getElementById(barId).style.width = Math.round(p * 100) + '%';
}
function copyText(id) {
  const text = document.getElementById(id).innerText;
  navigator.clipboard.writeText(text).then(() => alert('已复制到剪贴板'));
}
function bindDrop(dropId, inputId, onFile) {
  const drop = document.getElementById(dropId);
  const input = document.getElementById(inputId);
  drop.addEventListener('click', () => input.click());
  input.addEventListener('change', () => { if (input.files[0]) onFile(input.files[0]); input.value = ''; });
  drop.addEventListener('dragover', e => { e.preventDefault(); drop.classList.add('dragover'); });
  drop.addEventListener('dragleave', () => drop.classList.remove('dragover'));
  drop.addEventListener('drop', e => {
    e.preventDefault(); drop.classList.remove('dragover');
    if (e.dataTransfer.files[0]) onFile(e.dataTransfer.files[0]);
  });
}
async function upload(url, file) {
  const resp = await fetch(url, { method: 'POST', headers: { 'X-File-Name': encodeURIComponent(file.name) }, body: file });
  const data = await resp.json().catch(() => ({}));
  if (!resp.ok) throw new Error(data.error || ('HTTP ' + resp.status));
  return data.task_id;
}
// 轮询任务直到完成
function pollTask(taskId, onProgress) {
  return new Promise((resolve, reject) => {
    const timer = setInterval(async () => {
      try {
        const resp = await fetch('/api/tasks/' + taskId);
        const t = await resp.json();
        if (!resp.ok) { clearInterval(timer); return reject(new Error(t.error || '查询失败')); }
        onProgress(t);
        if (t.status === 'success') { clearInterval(timer); resolve(t); }
        else if (t.status === 'failed') { clearInterval(timer); reject(new Error(t.error || '任务失败')); }
      } catch (e) { clearInterval(timer); reject(e); }
    }, 1500);
  });
}

// ---------- OCR ----------
bindDrop('ocrDrop', 'ocrFile', async file => {
  setStatus('ocrStatus', '<span class="spinner"></span>已入队：' + file.name);
  document.getElementById('ocrResult').classList.add('hidden');
  document.getElementById('ocrActions').hidden = true;
  try {
    const taskId = await upload('/api/ocr', file);
    const task = await pollTask(taskId, t => {
      setStatus('ocrStatus', '<span class="spinner"></span>' + (t.message || '处理中…'));
      setProgress('ocrProgressWrap', 'ocrProgress', t.progress);
    });
    setProgress('ocrProgressWrap', 'ocrProgress', null);
    const detail = await (await fetch('/api/tasks/' + taskId)).json();
    lastOCRText = detail.text || '';
    const result = document.getElementById('ocrResult');
    result.textContent = lastOCRText;
    result.classList.remove('hidden');
    document.getElementById('ocrActions').hidden = false;
    const dl = document.getElementById('ocrDownload');
    dl.classList.remove('hidden');
    dl.href = '/api/tasks/' + taskId + '/download';
    setStatus('ocrStatus', '✅ 识别完成 · 引擎：' + (task.engine || '') + ' · 字数：' + lastOCRText.length, 'ok');
  } catch (err) {
    setProgress('ocrProgressWrap', 'ocrProgress', null);
    setStatus('ocrStatus', '❌ ' + err.message, 'error');
  }
});

function sendToChat() {
  if (!lastOCRText) return;
  document.querySelector('[data-tab="chat"]').click();
  const snippet = lastOCRText.length > 12000 ? lastOCRText.slice(0, 12000) + '\n…（已截断）' : lastOCRText;
  document.getElementById('chatInput').value = '以下是文档识别的内容，请阅读并等待我的问题：\n\n' + snippet;
  document.getElementById('chatInput').focus();
}

// ---------- PDF 转 Word ----------
bindDrop('pdfDrop', 'pdfFile', async file => {
  setStatus('pdfStatus', '<span class="spinner"></span>已入队：' + file.name);
  try {
    const taskId = await upload('/api/pdf-to-word', file);
    const task = await pollTask(taskId, t => {
      setStatus('pdfStatus', '<span class="spinner"></span>' + (t.message || '处理中…'));
      setProgress('pdfProgressWrap', 'pdfProgress', t.progress);
    });
    setProgress('pdfProgressWrap', 'pdfProgress', null);
    setStatus('pdfStatus', '✅ 转换完成 · ' + (task.engine || '') + ' · 开始下载…', 'ok');
    const a = document.createElement('a');
    a.href = '/api/tasks/' + taskId + '/download';
    a.download = file.name.replace(/\.pdf$/i, '') + '.docx';
    document.body.appendChild(a); a.click(); a.remove();
  } catch (err) {
    setProgress('pdfProgressWrap', 'pdfProgress', null);
    setStatus('pdfStatus', '❌ ' + err.message, 'error');
  }
});

// ---------- 任务队列 ----------
function statusBadge(s) {
  const map = { pending: '排队中', running: '执行中', success: '成功', failed: '失败' };
  return '<span class="badge ' + s + '">' + (map[s] || s) + '</span>';
}
async function loadTasks() {
  try {
    const resp = await fetch('/api/tasks');
    const data = await resp.json();
    const tbody = document.getElementById('taskList');
    const tasks = data.tasks || [];
    if (!tasks.length) {
      tbody.innerHTML = '<tr><td colspan="6" style="color:#6b7386">暂无任务</td></tr>';
      return;
    }
    tbody.innerHTML = tasks.map(t =>
      '<tr><td>' + escapeHtml(t.file_name) + '</td>' +
      '<td>' + t.kind_name + '</td>' +
      '<td>' + statusBadge(t.status) + (t.error ? '<div style="color:#ff7a7a;font-size:12px;margin-top:4px">' + escapeHtml(t.error) + '</div>' : '') + '</td>' +
      '<td>' + Math.round((t.progress || 0) * 100) + '%<div style="font-size:12px;color:#6b7386">' + escapeHtml(t.message || '') + '</div></td>' +
      '<td style="font-size:12px">' + escapeHtml(t.engine || '—') + '</td>' +
      '<td>' + (t.download_url ? '<a class="btn secondary" style="padding:4px 12px;font-size:12px" href="' + t.download_url + '">下载</a>' : '') + '</td></tr>'
    ).join('');
  } catch (e) { /* 忽略 */ }
}
function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

// ---------- 文档库 ----------
async function loadDocuments() {
  try {
    const resp = await fetch('/api/documents');
    const data = await resp.json();
    const list = document.getElementById('docList');
    const docs = data.documents || [];
    if (!docs.length) {
      list.innerHTML = '<div style="color:#6b7386">文档库为空，先在「文字识别」上传文件</div>';
      return;
    }
    list.innerHTML = docs.map(d =>
      '<div class="doc-item" onclick="showDocument(\'' + d.id + '\')">' +
      '<div class="name">📄 ' + escapeHtml(d.name) + '</div>' +
      '<div class="sub">' + d.kind_name + ' · 版本 ' + d.versions + (d.has_ocr_result ? ' · 已识别' : '') + ' · ' + (d.created_at || '').slice(0, 16).replace('T', ' ') + '</div>' +
      '</div>'
    ).join('');
  } catch (e) { /* 忽略 */ }
}
async function showDocument(id) {
  try {
    const resp = await fetch('/api/documents/' + id);
    const d = await resp.json();
    const pre = document.getElementById('docText');
    pre.textContent = d.text ? d.text : '（该文档尚无识别结果）';
    pre.classList.remove('hidden');
    pre.scrollIntoView({ behavior: 'smooth' });
  } catch (e) { /* 忽略 */ }
}

// ---------- Chat ----------
async function loadProviders() {
  try {
    const resp = await fetch('/api/llm/providers');
    const data = await resp.json();
    const select = document.getElementById('providerSelect');
    select.innerHTML = '';
    (data.providers || []).forEach(p => {
      const opt = document.createElement('option');
      opt.value = p.name;
      opt.textContent = p.name + '（' + p.model + '）' + (p.hasKey ? '' : ' · 未填Key');
      select.appendChild(opt);
    });
    if (!select.children.length) {
      select.innerHTML = '<option value="">（App 中尚未配置服务商）</option>';
    }
  } catch (e) { /* 忽略 */ }
}

function appendMsg(role, text) {
  const list = document.getElementById('chatList');
  const div = document.createElement('div');
  div.className = 'msg ' + role;
  div.textContent = text;
  list.appendChild(div);
  list.scrollTop = list.scrollHeight;
  return div;
}

async function sendChat() {
  const input = document.getElementById('chatInput');
  const text = input.value.trim();
  if (!text) return;
  const provider = document.getElementById('providerSelect').value;
  appendMsg('user', text);
  chatHistory.push({ role: 'user', content: text });
  input.value = '';
  document.getElementById('sendBtn').disabled = true;
  setStatus('chatStatus', '<span class="spinner"></span>等待模型回复…');
  const thinking = appendMsg('assistant', '…');
  try {
    const resp = await fetch('/api/chat', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ provider: provider || undefined, messages: chatHistory.slice(-20) })
    });
    const data = await resp.json();
    if (!resp.ok) throw new Error(data.error || ('HTTP ' + resp.status));
    thinking.textContent = data.reply;
    chatHistory.push({ role: 'assistant', content: data.reply });
    setStatus('chatStatus', data.provider + ' · ' + data.model, 'ok');
  } catch (err) {
    thinking.remove();
    setStatus('chatStatus', '❌ ' + err.message, 'error');
  }
  document.getElementById('sendBtn').disabled = false;
}

function clearChat() {
  chatHistory = [];
  document.getElementById('chatList').innerHTML = '';
  setStatus('chatStatus', '');
}

document.getElementById('chatInput').addEventListener('keydown', e => {
  if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); sendChat(); }
});

// ---------- 初始化 ----------
(async () => {
  try {
    const resp = await fetch('/api/status');
    const data = await resp.json();
    document.getElementById('serverInfo').textContent =
      data.app + ' v' + data.version + ' · ' + (data.ocrEngine || 'OCR') +
      (data.engineState ? ' · ' + data.engineState : '') +
      (data.ocrConfigured ? '' : ' · ⚠️ 引擎未就绪');
  } catch (e) {}
  loadProviders();
})();
</script>
</body>
</html>
"""#
}
