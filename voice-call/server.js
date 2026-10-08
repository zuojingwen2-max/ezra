// AI 语音来电 · 后端(零依赖,Node 18+)
// 流程:/api/ring -> Telegram 推送链接 -> 手机打开 call.html -> 接听 -> 说话(STT 在浏览器)
//       -> /api/say -> LLM webhook -> SSE 推回回复 -> /api/tts 合成语音 -> 挂断存档
const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const env = (k, d = '') => process.env[k] ?? d;
const CFG = {
  port: +env('PORT', 8787),
  publicUrl: env('PUBLIC_URL').replace(/\/$/, ''), // 例如 https://call.example.com
  ringToken: env('RING_TOKEN'), // 调用 /api/ring、/api/push 的口令
  dataDir: env('DATA_DIR', path.join(__dirname, 'data')),
  retainDays: +env('RETAIN_DAYS', 30), // 录音/记录自动删除天数
  // Telegram(大陆服务器需把 TELEGRAM_API_BASE 指向中转)
  tgToken: env('TELEGRAM_BOT_TOKEN'),
  tgChat: env('TELEGRAM_CHAT_ID'),
  tgBase: env('TELEGRAM_API_BASE', 'https://api.telegram.org'),
  // ElevenLabs(同上,可用 ELEVENLABS_BASE_URL 指向中转)
  elKey: env('ELEVENLABS_API_KEY'),
  elVoice: env('ELEVENLABS_VOICE_ID'),
  elModel: env('ELEVENLABS_MODEL', 'eleven_v3'),
  elBase: env('ELEVENLABS_BASE_URL', 'https://api.elevenlabs.io'),
  // LLM:POST {call_id,event,text,history} -> {reply}
  llmWebhook: env('LLM_WEBHOOK_URL'),
  llmWebhookToken: env('LLM_WEBHOOK_TOKEN'),
};

fs.mkdirSync(path.join(CFG.dataDir, 'calls'), { recursive: true });

const calls = new Map(); // id -> {id,state,startedAt,answeredAt,history[],clients:Set,reason}
const send = (res, code, body, type = 'application/json') => {
  res.writeHead(code, { 'Content-Type': type, 'Cache-Control': 'no-store' });
  res.end(typeof body === 'string' || Buffer.isBuffer(body) ? body : JSON.stringify(body));
};
const readJson = (req) =>
  new Promise((resolve, reject) => {
    let s = '';
    req.on('data', (c) => { s += c; if (s.length > 1e6) req.destroy(); });
    req.on('end', () => { try { resolve(s ? JSON.parse(s) : {}); } catch (e) { reject(e); } });
  });
const authed = (req) => {
  const t = (req.headers.authorization || '').replace(/^Bearer /, '');
  const a = Buffer.from(t), b = Buffer.from(CFG.ringToken);
  return CFG.ringToken && a.length === b.length && crypto.timingSafeEqual(a, b);
};
const emit = (call, event, data) => {
  for (const r of call.clients) r.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
};
const addLine = (call, role, text) => {
  const line = { role, text, t: Date.now() };
  call.history.push(line);
  return line;
};

async function askLLM(call, event, text) {
  if (!CFG.llmWebhook) return '(还没配置 LLM_WEBHOOK_URL,我现在只会复读:' + (text || '喂') + ')';
  const r = await fetch(CFG.llmWebhook, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      ...(CFG.llmWebhookToken && { Authorization: 'Bearer ' + CFG.llmWebhookToken }),
    },
    body: JSON.stringify({ call_id: call.id, event, text, history: call.history }),
  });
  if (!r.ok) throw new Error('LLM webhook ' + r.status);
  return ((await r.json()).reply || '').trim();
}

function saveCall(call) {
  const out = {
    id: call.id,
    startedAt: call.startedAt,
    answeredAt: call.answeredAt || null,
    endedAt: call.endedAt,
    durationSec: call.answeredAt ? Math.round((call.endedAt - call.answeredAt) / 1000) : 0,
    reason: call.reason,
    history: call.history,
  };
  fs.writeFileSync(path.join(CFG.dataDir, 'calls', call.id + '.json'), JSON.stringify(out, null, 1));
  return out;
}

function cleanup() {
  const dir = path.join(CFG.dataDir, 'calls');
  const limit = Date.now() - CFG.retainDays * 864e5;
  for (const f of fs.readdirSync(dir)) {
    const p = path.join(dir, f);
    if (fs.statSync(p).mtimeMs < limit) fs.unlinkSync(p);
  }
}
setInterval(cleanup, 6 * 3600e3).unref();

const idOk = (id) => /^[a-f0-9]{32}$/.test(id || '');
const getCall = (id) => (idOk(id) ? calls.get(id) : null);

const routes = {
  // AI 主动来电:Authorization: Bearer RING_TOKEN, body {"text":"可选的来电说明"}
  'POST /api/ring': async (req, res) => {
    if (!authed(req)) return send(res, 401, { error: 'unauthorized' });
    const { text = '' } = await readJson(req);
    const id = crypto.randomBytes(16).toString('hex');
    calls.set(id, { id, state: 'ringing', startedAt: Date.now(), history: [], clients: new Set() });
    const link = `${CFG.publicUrl}/call.html?id=${id}`;
    if (CFG.tgToken && CFG.tgChat) {
      const r = await fetch(`${CFG.tgBase}/bot${CFG.tgToken}/sendMessage`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ chat_id: CFG.tgChat, text: `📞 来电${text ? ':' + text : ''}\n${link}` }),
      });
      if (!r.ok) return send(res, 502, { error: 'telegram ' + r.status, link });
    }
    setTimeout(() => { // 60 秒无人接听 -> 未接
      const c = calls.get(id);
      if (c && c.state === 'ringing') { c.state = 'ended'; c.endedAt = Date.now(); c.reason = 'missed'; saveCall(c); emit(c, 'hangup', { reason: 'missed' }); }
    }, 60e3).unref();
    send(res, 200, { id, link });
  },

  // 手机点开链接后,页面检查来电状态
  'GET /api/state': (req, res, url) => {
    const c = getCall(url.searchParams.get('id'));
    send(res, c ? 200 : 404, c ? { state: c.state } : { error: 'not found' });
  },

  // 接听:AI 先开口
  'POST /api/answer': async (req, res) => {
    const { id } = await readJson(req);
    const c = getCall(id);
    if (!c || c.state !== 'ringing') return send(res, 409, { error: 'not ringing' });
    c.state = 'active';
    c.answeredAt = Date.now();
    send(res, 200, { ok: true });
    try {
      const reply = await askLLM(c, 'answered', '');
      if (reply) { addLine(c, 'ai', reply); emit(c, 'say', { text: reply }); }
    } catch (e) { emit(c, 'error', { message: e.message }); }
  },

  // 用户说的话(浏览器 STT 的结果)
  'POST /api/say': async (req, res) => {
    const { id, text } = await readJson(req);
    const c = getCall(id);
    if (!c || c.state !== 'active' || !text?.trim()) return send(res, 400, { error: 'bad request' });
    addLine(c, 'user', text.trim());
    send(res, 200, { ok: true });
    try {
      const reply = await askLLM(c, 'user', text.trim());
      if (reply) { addLine(c, 'ai', reply); emit(c, 'say', { text: reply }); }
    } catch (e) { emit(c, 'error', { message: e.message }); }
  },

  // 让外部的 AI 直接往通话里插话(可选):Bearer RING_TOKEN, body {id,text}
  'POST /api/push': async (req, res) => {
    if (!authed(req)) return send(res, 401, { error: 'unauthorized' });
    const { id, text } = await readJson(req);
    const c = getCall(id);
    if (!c || c.state !== 'active') return send(res, 409, { error: 'not active' });
    addLine(c, 'ai', text);
    emit(c, 'say', { text });
    send(res, 200, { ok: true });
  },

  // SSE:AI -> 页面
  'GET /api/stream': (req, res, url) => {
    const c = getCall(url.searchParams.get('id'));
    if (!c) return send(res, 404, { error: 'not found' });
    res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-store', Connection: 'keep-alive', 'X-Accel-Buffering': 'no' });
    res.write(`event: hello\ndata: ${JSON.stringify({ state: c.state })}\n\n`);
    c.clients.add(res);
    const ka = setInterval(() => res.write(': ka\n\n'), 20e3);
    req.on('close', () => { clearInterval(ka); c.clients.delete(res); });
  },

  // TTS:返回 mp3
  'GET /api/tts': async (req, res, url) => {
    const c = getCall(url.searchParams.get('id'));
    const text = url.searchParams.get('text') || '';
    if (!c || !text || text.length > 1000) return send(res, 400, { error: 'bad request' });
    if (!CFG.elKey || !CFG.elVoice) return send(res, 501, { error: 'tts not configured' });
    const r = await fetch(`${CFG.elBase}/v1/text-to-speech/${CFG.elVoice}?output_format=mp3_44100_128`, {
      method: 'POST',
      headers: { 'xi-api-key': CFG.elKey, 'Content-Type': 'application/json' },
      body: JSON.stringify({ text, model_id: CFG.elModel }),
    });
    if (!r.ok) return send(res, 502, { error: 'elevenlabs ' + r.status });
    send(res, 200, Buffer.from(await r.arrayBuffer()), 'audio/mpeg');
  },

  'POST /api/hangup': async (req, res) => {
    const { id } = await readJson(req);
    const c = getCall(id);
    if (!c) return send(res, 404, { error: 'not found' });
    if (c.state !== 'ended') {
      c.state = 'ended'; c.endedAt = Date.now(); c.reason = c.answeredAt ? 'hangup' : 'declined';
      emit(c, 'hangup', { reason: c.reason });
      for (const r of c.clients) r.end();
      var out = saveCall(c);
      askLLM(c, 'ended', '').catch(() => {}); // 通知聊天侧:通话结束(回复忽略)
    }
    send(res, 200, out || { ok: true });
  },

  // 通话记录
  'GET /api/calls': (req, res) => {
    if (!authed(req)) return send(res, 401, { error: 'unauthorized' });
    const dir = path.join(CFG.dataDir, 'calls');
    const list = fs.readdirSync(dir).map((f) => JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8')))
      .map(({ history, ...m }) => m).sort((a, b) => b.startedAt - a.startedAt);
    send(res, 200, list);
  },
  'GET /api/call': (req, res, url) => {
    const id = url.searchParams.get('id');
    if (!idOk(id)) return send(res, 400, { error: 'bad id' });
    const f = path.join(CFG.dataDir, 'calls', id + '.json');
    fs.existsSync(f) ? send(res, 200, fs.readFileSync(f)) : send(res, 404, { error: 'not found' });
  },
};

const MIME = { '.html': 'text/html; charset=utf-8', '.png': 'image/png', '.json': 'application/json' };
const PUBLIC = path.join(__dirname, 'public');

http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  const h = routes[`${req.method} ${url.pathname}`];
  try {
    if (h) return await h(req, res, url);
    if (req.method !== 'GET') return send(res, 404, { error: 'not found' });
    const rel = url.pathname === '/' ? '/call.html' : url.pathname;
    const f = path.normalize(path.join(PUBLIC, rel));
    if (!f.startsWith(PUBLIC + path.sep) || !fs.existsSync(f)) return send(res, 404, 'not found', 'text/plain');
    send(res, 200, fs.readFileSync(f), MIME[path.extname(f)] || 'application/octet-stream');
  } catch (e) {
    console.error(e);
    if (!res.headersSent) send(res, 500, { error: e.message });
  }
}).listen(CFG.port, '127.0.0.1', () => console.log(`voice-call listening on 127.0.0.1:${CFG.port}`));
