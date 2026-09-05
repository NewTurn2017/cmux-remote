// 폰에서 맥의 cmux 세션을 보고 지시하는 클라이언트.
//
// 서버가 주는 화면은 픽셀도, 바이트 스트림도 아니고 "행 단위 모델"이다:
//   screen.full  { rows: [ANSI 문자열], cols, rowsCount, cursor }
//   screen.diff  { ops: [{op:'row'|'cursor'|'clear', ...}] }
// 그래서 xterm 에는 커서를 옮겨가며 바뀐 줄만 덮어쓴다.

const BASE = location.origin;
const WSB = BASE.replace(/^http/, 'ws');
const $ = (id) => document.getElementById(id);

const state = {
  ws: null,
  workspaceId: null,
  surfaceId: null,
  rows: [], // 마지막으로 그린 화면. 서버가 매번 전체를 보내므로 여기서 직접 비교한다.
  cols: 0,
  paused: false,
  // 숫자면 그 배율, 'fit' 이면 화면 폭에 맞춤. 폰 크기가 제각각이라 값으로 기억해 둔다.
  zoom: localStorage.getItem('zoom') || 'fit',
  bytes: 0,
};

const ZOOM_MIN = 0.2;
const ZOOM_MAX = 3;

const rpc = new Map();
let nextId = 1;

function err(m) {
  $('log').textContent += m + '\n';
  $('logbox').hidden = false;
}
function status(m) { $('status').textContent = m; }

// ---- 접속 ----

async function token() {
  const saved = { tok: localStorage.getItem('tok'), dev: localStorage.getItem('dev') };
  if (saved.tok && saved.dev) return saved;
  const r = await fetch(BASE + '/v1/devices/me/register', { method: 'POST' });
  if (!r.ok) throw new Error(`등록 실패 HTTP ${r.status}`);
  const j = await r.json();
  localStorage.setItem('tok', j.token);
  localStorage.setItem('dev', j.device_id);
  return { tok: j.token, dev: j.device_id };
}

function connect({ tok, dev }) {
  return new Promise((resolve, reject) => {
    // 브라우저는 WS 에 Authorization 헤더를 못 붙이므로 토큰을 서브프로토콜로 보낸다.
    const ws = new WebSocket(WSB + '/v1/ws', ['cmuxremote.v1', 'bearer.' + tok]);
    state.ws = ws;
    ws.onopen = () => {
      // 첫 프레임은 JSON-RPC 봉투가 아니라 HelloFrame 자체여야 한다.
      // 형식이 틀리거나 100ms 안에 안 보내면 서버가 말없이 끊는다(code 1006).
      ws.send(JSON.stringify({ deviceId: dev, appVersion: 'web-0.2', protocolVersion: 1 }));
      status('연결됨');
      resolve();
    };
    ws.onmessage = onMessage;
    ws.onclose = (e) => {
      status('끊김 (' + e.code + ')');
      // 폰은 화면을 끄거나 네트워크가 바뀌면 소켓이 그냥 사라진다.
      // 사용자가 새로고침으로 알아채게 두지 말고 스스로 다시 붙는다.
      reject(new Error('WS 종료 code=' + e.code));
      scheduleReconnect();
    };
    ws.onerror = () => err('WS 오류');
  });
}

let reconnectDelay = 1000;
let reconnecting = false;

async function scheduleReconnect() {
  if (reconnecting) return;
  reconnecting = true;
  for (const { reject } of rpc.values()) reject(new Error('연결 끊김'));
  rpc.clear();
  while (true) {
    status(`재연결 대기 ${Math.round(reconnectDelay / 1000)}초…`);
    await new Promise((r) => setTimeout(r, reconnectDelay));
    try {
      await connect(await token());
      reconnectDelay = 1000;
      reconnecting = false;
      // 보던 화면이 있으면 그 화면으로 돌아간다. 화면 내용은 서버가 곧 통째로 다시 보낸다.
      state.rows = [];
      if (state.surfaceId) await subscribe();
      else await showList();
      return;
    } catch {
      reconnectDelay = Math.min(reconnectDelay * 2, 15000);
      // 몇 번을 실패하면 토큰이 폐기된 경우를 의심한다(맥에서 재등록하면 이전 토큰은 무효).
      // 저장분을 버리면 다음 시도에서 새로 등록한다.
      if (reconnectDelay >= 8000) { localStorage.removeItem('tok'); localStorage.removeItem('dev'); }
    }
  }
}

function call(method, params = {}) {
  return new Promise((resolve, reject) => {
    const id = String(nextId++);
    rpc.set(id, { resolve, reject });
    state.ws.send(JSON.stringify({ id, method, params }));
    setTimeout(() => {
      if (rpc.delete(id)) reject(new Error(method + ' 응답 없음'));
    }, 10000);
  });
}

function onMessage(e) {
  const raw = String(e.data);
  state.bytes += raw.length;
  let m;
  try { m = JSON.parse(raw); } catch { return err('JSON 아님: ' + raw.slice(0, 80)); }

  if (m.id && rpc.has(m.id)) {
    const { resolve, reject } = rpc.get(m.id);
    rpc.delete(m.id);
    // 성공 응답은 ok 를 생략하고 result 를 준다. 실패만 ok:false + error.
    if (m.ok === false) reject(new Error(m.error?.code + ': ' + m.error?.message));
    else resolve(m.result ?? {});
    return;
  }
  if (m.type === 'screen.full') applyFull(m);
  else if (m.type === 'screen.diff') applyDiff(m);
  // screen.checksum·event·ping 은 화면에 영향이 없어 무시한다.
}

// ---- 화면 ----

const term = new Terminal({
  fontSize: 12,
  fontFamily: 'ui-monospace, Menlo, monospace',
  theme: { background: '#000000' },
  scrollback: 0, // 서버가 화면 전체를 주므로 xterm 자체 스크롤백은 쓰지 않는다
  convertEol: false,
  disableStdin: true,
});
term.open($('term'));

function ensureGeometry(cols, rowsCount) {
  if (state.cols === cols && state.rows.length === rowsCount) return;
  state.cols = cols;
  state.rows = new Array(rowsCount).fill(null);
  term.resize(cols, rowsCount);
  applyZoom();
}

// y 행(0부터)에 text 를 통째로 다시 그린다. 줄 끝은 지워서 이전 내용이 남지 않게 한다.
function writeRow(y, text) {
  term.write(`\x1b[${y + 1};1H${text}\x1b[K`);
}

function applyFull(f) {
  if (state.paused) return;
  ensureGeometry(f.cols, f.rowsCount);
  // 서버는 화면이 조금만 바뀌어도 전체(76KB)를 보낸다. 그대로 다 그리면 폰이 버티지 못하므로
  // 이전 화면과 비교해 실제로 바뀐 줄만 xterm 에 넘긴다.
  for (let y = 0; y < f.rows.length; y++) {
    if (state.rows[y] !== f.rows[y]) {
      writeRow(y, f.rows[y]);
      state.rows[y] = f.rows[y];
    }
  }
  moveCursor(f.cursor);
}

function applyDiff(d) {
  if (state.paused) return;
  for (const op of d.ops || []) {
    if (op.op === 'row') { writeRow(op.y, op.text); state.rows[op.y] = op.text; }
    else if (op.op === 'cursor') moveCursor({ x: op.x, y: op.y });
    else if (op.op === 'clear') { term.write('\x1b[2J'); state.rows.fill(null); }
  }
}

function moveCursor(c) {
  if (!c) return;
  term.write(`\x1b[${c.y + 1};${c.x + 1}H`);
}

function applyZoom() {
  const el = $('term');
  // transform 이 아니라 zoom 을 쓴다 — transform 은 배치 크기를 안 바꿔서
  // 축소해도 스크롤 영역이 원래 크기 그대로 남는다.
  el.style.zoom = 1;
  if (state.zoom === 'fit') {
    const natural = el.scrollWidth || 1;
    el.style.zoom = $('viewport').clientWidth / natural;
    $('zoomlabel').textContent = '맞춤';
  } else {
    el.style.zoom = state.zoom;
    $('zoomlabel').textContent = Math.round(state.zoom * 100) + '%';
  }
  localStorage.setItem('zoom', String(state.zoom));
}

// 배율을 바꾼다. 'fit' 상태에서 +/− 를 누르면 지금 보이는 크기에서 이어서 조절한다.
function nudgeZoom(factor) {
  const current = state.zoom === 'fit' ? Number($('term').style.zoom) || 1 : state.zoom;
  state.zoom = Math.min(ZOOM_MAX, Math.max(ZOOM_MIN, current * factor));
  applyZoom();
}

// ---- 워크스페이스 ----

async function showList() {
  $('screen').hidden = true;
  $('list').hidden = false;
  $('back').hidden = true;
  $('togglekeys').hidden = true;
  $('title').textContent = 'cmux 원격';
  await unsubscribe();

  const { workspaces = [] } = await call('workspace.list');
  $('list').innerHTML = '';
  for (const w of workspaces) {
    const b = document.createElement('button');
    b.className = 'ws' + (w.selected ? ' selected' : '');
    b.innerHTML = '';
    b.append(w.custom_title || w.title || '(제목 없음)');
    const sub = document.createElement('span');
    sub.className = 'sub';
    sub.textContent = w.latest_conversation_message || w.current_directory || '';
    b.append(sub);
    b.onclick = () => open(w).catch((e) => err(String(e.message || e)));
    $('list').append(b);
  }
  status(workspaces.length + '개');
}

async function open(w) {
  const { surfaces = [] } = await call('surface.list', { workspace_id: w.id });
  const s = surfaces.find((x) => x.focused) || surfaces.find((x) => x.type === 'terminal') || surfaces[0];
  if (!s) throw new Error('이 워크스페이스에는 화면이 없다');

  state.workspaceId = w.id;
  state.surfaceId = s.id;
  state.rows = [];
  state.cols = 0;
  term.reset();

  $('list').hidden = true;
  $('screen').hidden = false;
  $('back').hidden = false;
  $('togglekeys').hidden = false;
  $('title').textContent = w.custom_title || w.title || '';
  await subscribe();
}

async function subscribe() {
  if (!state.surfaceId) return;
  await call('surface.subscribe', {
    workspace_id: state.workspaceId,
    surface_id: state.surfaceId,
    lines: 200,
  });
  state.paused = false;
  $('pause').textContent = '일시정지';
}

async function unsubscribe() {
  if (!state.surfaceId) return;
  try { await call('surface.unsubscribe', { surface_id: state.surfaceId }); } catch { /* 이미 끊겼으면 그만 */ }
}

// ---- 입력 ----

async function sendKey(key) {
  await call('surface.send_key', {
    workspace_id: state.workspaceId,
    surface_id: state.surfaceId,
    key,
  });
}

async function sendText(text) {
  await call('surface.send_text', {
    workspace_id: state.workspaceId,
    surface_id: state.surfaceId,
    text,
  });
}

for (const b of document.querySelectorAll('#keys button[data-key]')) {
  b.onclick = () => sendKey(b.dataset.key).catch((e) => err(String(e.message || e)));
}

$('input').onsubmit = async (e) => {
  e.preventDefault();
  const text = $('text').value;
  if (!text.trim()) return;
  try {
    // 보내기 = 내용 전송 + Enter. 폰 받아쓰기로 길게 말한 뒤 확인하고 보낼 수 있다.
    await sendText(text);
    await sendKey('enter');
    $('text').value = '';
  } catch (e2) { err(String(e2.message || e2)); }
};

$('back').onclick = () => showList().catch((e) => err(String(e.message || e)));

$('zoomin').onclick = () => nudgeZoom(1.25);
$('zoomout').onclick = () => nudgeZoom(1 / 1.25);
// 가운데 배율 표시를 누르면 '맞춤' 과 100% 를 오간다.
$('zoomlabel').onclick = () => { state.zoom = state.zoom === 'fit' ? 1 : 'fit'; applyZoom(); };

$('logclose').onclick = () => { $('log').textContent = ''; $('logbox').hidden = true; };

$('togglekeys').onclick = () => {
  const hide = !$('keys').hidden;
  $('keys').hidden = hide;
  localStorage.setItem('keysHidden', hide ? '1' : '');
};
$('keys').hidden = localStorage.getItem('keysHidden') === '1';

// 손가락 두 개로 오므리고 벌려서도 조절되게 한다 — 버튼만으로는 답답하다.
let pinchStart = null;
const spread = (t) => Math.hypot(t[0].clientX - t[1].clientX, t[0].clientY - t[1].clientY);
$('viewport').addEventListener('touchstart', (e) => {
  if (e.touches.length !== 2) return;
  const base = state.zoom === 'fit' ? Number($('term').style.zoom) || 1 : state.zoom;
  pinchStart = { dist: spread(e.touches), base };
}, { passive: true });
$('viewport').addEventListener('touchmove', (e) => {
  if (!pinchStart || e.touches.length !== 2) return;
  e.preventDefault(); // 브라우저 자체 확대가 끼어들면 화면이 두 겹으로 커진다
  const ratio = spread(e.touches) / pinchStart.dist;
  state.zoom = Math.min(ZOOM_MAX, Math.max(ZOOM_MIN, pinchStart.base * ratio));
  applyZoom();
}, { passive: false });
$('viewport').addEventListener('touchend', () => { pinchStart = null; }, { passive: true });
$('pause').onclick = async () => {
  if (state.paused) { await subscribe(); }
  else { await unsubscribe(); state.paused = true; $('pause').textContent = '재개'; }
};

// 화면이 안 보이는 동안에도 초당 수백 KB 가 계속 흐르므로 반드시 끊는다.
document.addEventListener('visibilitychange', () => {
  if (document.hidden) unsubscribe().then(() => { state.paused = true; });
  else if (state.paused && state.surfaceId) subscribe().catch(() => {});
});

// 초당 수신량은 데이터 소모를 가늠하는 유일한 단서라 항상 띄워 둔다.
setInterval(() => {
  if (!state.surfaceId || state.paused) return;
  status(Math.round(state.bytes / 1024) + 'KB/s');
  state.bytes = 0;
}, 1000);

window.onerror = (m, src, line) => err(`JS 오류: ${m} (${line}행)`);

(async () => {
  try {
    await connect(await token());
    await showList();
  } catch (e) {
    err(String(e.message || e));
    status('실패');
  }
})();
