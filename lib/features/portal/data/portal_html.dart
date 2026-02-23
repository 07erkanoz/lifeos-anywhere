/// Self-contained HTML page for the Web Portal.
///
/// This is served at `/portal` by the local Shelf server, giving any
/// device on the LAN a browser-based file upload/download interface.
const String portalHtml = r'''
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>LifeOS AnyWhere — Portal</title>
<style>
  :root {
    --bg: #0A0A0F;
    --surface: #12121A;
    --card: #161622;
    --border: rgba(255,255,255,0.08);
    --blue: #00B4FF;
    --green: #00FF88;
    --text: #E8E8ED;
    --text2: #8E8E93;
    --text3: #636366;
    --radius: 14px;
  }
  @media (prefers-color-scheme: light) {
    :root {
      --bg: #F2F2F7;
      --surface: #FFFFFF;
      --card: #FFFFFF;
      --border: rgba(0,0,0,0.08);
      --blue: #007AFF;
      --green: #34C759;
      --text: #1C1C1E;
      --text2: #8E8E93;
      --text3: #AEAEB2;
    }
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
    background: var(--bg);
    color: var(--text);
    min-height: 100vh;
    padding: 24px;
  }
  .container { max-width: 640px; margin: 0 auto; }
  header {
    text-align: center;
    padding: 32px 0 24px;
  }
  header h1 {
    font-size: 24px;
    font-weight: 700;
    letter-spacing: -0.5px;
  }
  header h1 span { color: var(--blue); }
  header p {
    color: var(--text2);
    font-size: 14px;
    margin-top: 6px;
  }
  #device-info {
    color: var(--text3);
    font-size: 12px;
    margin-top: 4px;
  }

  /* Upload area */
  .upload-zone {
    border: 2px dashed var(--border);
    border-radius: var(--radius);
    background: var(--card);
    padding: 40px 20px;
    text-align: center;
    transition: all 0.2s;
    cursor: pointer;
    margin-bottom: 24px;
  }
  .upload-zone:hover, .upload-zone.dragover {
    border-color: var(--blue);
    background: color-mix(in srgb, var(--blue) 5%, var(--card));
  }
  .upload-zone svg {
    width: 48px; height: 48px;
    stroke: var(--blue);
    margin-bottom: 12px;
  }
  .upload-zone p { color: var(--text2); font-size: 14px; }
  .upload-zone .hint { color: var(--text3); font-size: 12px; margin-top: 4px; }
  #file-input { display: none; }

  /* Progress */
  .progress-bar {
    height: 4px;
    background: var(--border);
    border-radius: 2px;
    margin: 12px 0;
    overflow: hidden;
    display: none;
  }
  .progress-bar .fill {
    height: 100%;
    background: var(--blue);
    border-radius: 2px;
    transition: width 0.3s;
    width: 0%;
  }
  #upload-status {
    text-align: center;
    font-size: 13px;
    color: var(--green);
    min-height: 20px;
    margin-bottom: 16px;
  }

  /* File list */
  .section-title {
    font-size: 16px;
    font-weight: 600;
    margin-bottom: 12px;
    display: flex;
    align-items: center;
    justify-content: space-between;
  }
  .section-title button {
    background: none;
    border: none;
    color: var(--blue);
    cursor: pointer;
    font-size: 13px;
  }
  .file-list { list-style: none; }
  .file-item {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 12px 16px;
    background: var(--card);
    border: 1px solid var(--border);
    border-radius: 12px;
    margin-bottom: 8px;
    transition: background 0.15s;
  }
  .file-item:hover { background: var(--surface); }
  .file-name {
    font-size: 14px;
    font-weight: 500;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    flex: 1;
    margin-right: 12px;
  }
  .file-meta {
    color: var(--text3);
    font-size: 12px;
    white-space: nowrap;
    margin-right: 12px;
  }
  .file-item a {
    color: var(--blue);
    text-decoration: none;
    font-size: 13px;
    font-weight: 500;
    white-space: nowrap;
  }
  .empty {
    text-align: center;
    color: var(--text3);
    font-size: 14px;
    padding: 32px 0;
  }
</style>
</head>
<body>
<div class="container">
  <header>
    <h1>LifeOS <span>AnyWhere</span></h1>
    <p>Web Portal</p>
    <div id="device-info">Connecting…</div>
  </header>

  <div class="upload-zone" id="dropZone" onclick="document.getElementById('file-input').click()">
    <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5">
      <path stroke-linecap="round" stroke-linejoin="round" d="M3 16.5v2.25A2.25 2.25 0 005.25 21h13.5A2.25 2.25 0 0021 18.75V16.5m-13.5-9L12 3m0 0l4.5 4.5M12 3v13.5"/>
    </svg>
    <p>Drop files here or click to browse</p>
    <div class="hint">Files will be saved to this device</div>
  </div>
  <input type="file" id="file-input" multiple>

  <div class="progress-bar" id="progressBar">
    <div class="fill" id="progressFill"></div>
  </div>
  <div id="upload-status"></div>

  <div class="section-title">
    <span>Files</span>
    <button onclick="loadFiles()">Refresh</button>
  </div>
  <ul class="file-list" id="fileList">
    <li class="empty">Loading…</li>
  </ul>
</div>

<script>
const dropZone = document.getElementById('dropZone');
const fileInput = document.getElementById('file-input');
const progressBar = document.getElementById('progressBar');
const progressFill = document.getElementById('progressFill');
const uploadStatus = document.getElementById('upload-status');
const fileList = document.getElementById('fileList');

// Prevent default drag behaviors.
['dragenter','dragover','dragleave','drop'].forEach(e => {
  dropZone.addEventListener(e, ev => ev.preventDefault());
  document.body.addEventListener(e, ev => ev.preventDefault());
});
dropZone.addEventListener('dragenter', () => dropZone.classList.add('dragover'));
dropZone.addEventListener('dragleave', () => dropZone.classList.remove('dragover'));
dropZone.addEventListener('drop', e => {
  dropZone.classList.remove('dragover');
  if (e.dataTransfer.files.length) uploadFiles(e.dataTransfer.files);
});
fileInput.addEventListener('change', () => {
  if (fileInput.files.length) uploadFiles(fileInput.files);
});

function formatSize(bytes) {
  if (bytes < 1024) return bytes + ' B';
  if (bytes < 1048576) return (bytes/1024).toFixed(1) + ' KB';
  if (bytes < 1073741824) return (bytes/1048576).toFixed(1) + ' MB';
  return (bytes/1073741824).toFixed(2) + ' GB';
}

async function uploadFiles(files) {
  const fd = new FormData();
  for (const f of files) fd.append('file', f);

  progressBar.style.display = 'block';
  progressFill.style.width = '0%';
  uploadStatus.textContent = 'Uploading…';
  uploadStatus.style.color = 'var(--text2)';

  try {
    const xhr = new XMLHttpRequest();
    xhr.open('POST', '/portal/api/upload');
    xhr.upload.onprogress = e => {
      if (e.lengthComputable) {
        progressFill.style.width = Math.round(e.loaded/e.total*100) + '%';
      }
    };
    await new Promise((resolve, reject) => {
      xhr.onload = () => {
        if (xhr.status === 200) {
          const res = JSON.parse(xhr.responseText);
          uploadStatus.textContent = res.count + ' file(s) uploaded successfully';
          uploadStatus.style.color = 'var(--green)';
          resolve();
        } else {
          reject(new Error('Upload failed: ' + xhr.status));
        }
      };
      xhr.onerror = () => reject(new Error('Network error'));
      xhr.send(fd);
    });
    loadFiles();
  } catch (e) {
    uploadStatus.textContent = e.message;
    uploadStatus.style.color = '#FF453A';
  }
  setTimeout(() => { progressBar.style.display = 'none'; }, 2000);
  fileInput.value = '';
}

async function loadFiles() {
  try {
    const res = await fetch('/portal/api/files');
    const files = await res.json();
    if (!files.length) {
      fileList.innerHTML = '<li class="empty">No files yet</li>';
      return;
    }
    fileList.innerHTML = files.map(f => `
      <li class="file-item">
        <span class="file-name">${escapeHtml(f.name)}</span>
        <span class="file-meta">${formatSize(f.size)}</span>
        <a href="/portal/api/download/${encodeURIComponent(f.name)}">Download</a>
      </li>
    `).join('');
  } catch (e) {
    fileList.innerHTML = '<li class="empty">Failed to load files</li>';
  }
}

function escapeHtml(s) {
  const d = document.createElement('div');
  d.textContent = s;
  return d.innerHTML;
}

async function loadDeviceInfo() {
  try {
    const res = await fetch('/portal/api/info');
    const info = await res.json();
    document.getElementById('device-info').textContent =
      info.name + ' · ' + info.platform + ' · v' + info.version;
  } catch (_) {
    document.getElementById('device-info').textContent = 'Connected';
  }
}

loadDeviceInfo();
loadFiles();
</script>
</body>
</html>
''';
