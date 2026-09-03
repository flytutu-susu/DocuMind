import Foundation

/// 内嵌的局域网 Web 前端（单文件，无外部依赖）。
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
  .container { max-width: 920px; margin: 0 auto; padding: 24px 16px 64px; }
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
  .btn { display: inline-block; padding: 10px 20px; border-radius: 10px; border: none; background: #4f7cff; color: #fff; font-size: 14px; cursor: pointer; transition: opacity .15s; }
  .btn:disabled { opacity: .45; cursor: not-allowed; }
  .btn.secondary { background: #2a3348; }
  .status { margin: 14px 0; font-size: 13px; color: #8b93a7; min-height: 18px; }
  .status.error { color: #ff7a7a; }
  .status.ok { color: #6fe3a5; }
  textarea, select, input[type=text] { width: 100%; background: #0f1420; border: 1px solid #2a3348; border-radius: 10px; color: #e6e9f0; padding: 10px 12px; font-size: 14px; font-family: inherit; }
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
  .msg.system-note { align-self: center; background: none; color: #6b7386; font-size: 12px; }
  .spinner { display: inline-block; width: 14px; height: 14px; border: 2px solid #4f7cff; border-top-color: transparent; border-radius: 50%; animation: spin .8s linear infinite; vertical-align: middle; margin-right: 6px; }
  @keyframes spin { to { transform: rotate(360deg); } }
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
    <button class="tab" data-tab="chat">AI 对话</button>
  </div>

  <!-- OCR -->
  <div class="panel" id="panel-ocr">
    <div class="dropzone" id="ocrDrop">
      <div class="icon">🖼️</div>
      <div>点击选择或拖拽文件到此处</div>
      <div class="hint">支持 PDF / 图片(png, jpg…) / docx / xlsx，单文件 ≤ 100MB</div>
      <input type="file" id="ocrFile" accept=".pdf,.png,.jpg,.jpeg,.bmp,.webp,.gif,.docx,.xlsx" style="display:none">
    </div>
    <div class="status" id="ocrStatus"></div>
    <pre class="result hidden" id="ocrResult"></pre>
    <div class="row" style="margin-top:12px" id="ocrActions" hidden>
      <button class="btn secondary" onclick="copyText('ocrResult')">复制文本</button>
      <button class="btn secondary" onclick="sendToChat()">发送到 AI 对话</button>
    </div>
  </div>

  <!-- PDF to Word -->
  <div class="panel hidden" id="panel-convert">
    <div class="dropzone" id="pdfDrop">
      <div class="icon">📑</div>
      <div>点击选择或拖拽 PDF 文件</div>
      <div class="hint">文字版 PDF 直接提取文本层；扫描版自动逐页 OCR 后排版为 Word</div>
      <input type="file" id="pdfFile" accept=".pdf" style="display:none">
    </div>
    <div class="status" id="pdfStatus"></div>
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

// ---------- Tab 切换 ----------
document.querySelectorAll('.tab').forEach(btn => {
  btn.addEventListener('click', () => {
    document.querySelectorAll('.tab').forEach(b => b.classList.remove('active'));
    btn.classList.add('active');
    ['ocr', 'convert', 'chat'].forEach(t => {
      document.getElementById('panel-' + t).classList.toggle('hidden', t !== btn.dataset.tab);
    });
  });
});

// ---------- 工具 ----------
function setStatus(id, msg, cls) {
  const el = document.getElementById(id);
  el.className = 'status ' + (cls || '');
  el.innerHTML = msg || '';
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

// ---------- OCR ----------
bindDrop('ocrDrop', 'ocrFile', async file => {
  setStatus('ocrStatus', '<span class="spinner"></span>识别中：' + file.name + '（大文件可能需要几十秒）…');
  document.getElementById('ocrResult').classList.add('hidden');
  document.getElementById('ocrActions').hidden = true;
  try {
    const resp = await fetch('/api/ocr', { method: 'POST', headers: { 'X-File-Name': encodeURIComponent(file.name) }, body: file });
    const data = await resp.json();
    if (!resp.ok) throw new Error(data.error || ('HTTP ' + resp.status));
    lastOCRText = data.text;
    const result = document.getElementById('ocrResult');
    result.textContent = data.text;
    result.classList.remove('hidden');
    document.getElementById('ocrActions').hidden = false;
    setStatus('ocrStatus', '✅ 识别完成 · 引擎：' + data.engine + ' · 页数：' + data.pageCount + ' · 字数：' + data.text.length, 'ok');
  } catch (err) {
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
  setStatus('pdfStatus', '<span class="spinner"></span>转换中：' + file.name + ' …');
  try {
    const resp = await fetch('/api/pdf-to-word', { method: 'POST', headers: { 'X-File-Name': encodeURIComponent(file.name) }, body: file });
    if (!resp.ok) {
      const data = await resp.json().catch(() => ({}));
      throw new Error(data.error || ('HTTP ' + resp.status));
    }
    const blob = await resp.blob();
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = file.name.replace(/\.pdf$/i, '') + '.docx';
    document.body.appendChild(a); a.click(); a.remove();
    URL.revokeObjectURL(url);
    const engine = resp.headers.get('X-Engine') || '';
    setStatus('pdfStatus', '✅ 转换完成，已开始下载 · ' + engine, 'ok');
  } catch (err) {
    setStatus('pdfStatus', '❌ ' + err.message, 'error');
  }
});

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
      data.app + ' v' + data.version + ' · ' + (data.ocrEngine || 'OCR') + (data.ocrConfigured ? '' : ' · ⚠️ 未配置（请在 App 设置中检查）');
  } catch (e) {}
  loadProviders();
})();
</script>
</body>
</html>
"""#
}
