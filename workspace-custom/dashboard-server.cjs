const http = require('http');
const fs = require('fs');
const path = require('path');
const HOME = require('os').homedir();

const PORT = 8899;
// Profile mapping: reads from agent-profiles.json
function _getProfile(agentId) {
  try {
    const map = JSON.parse(fs.readFileSync(path.join(HOME, '.openclaw', 'agent-profiles.json'), 'utf-8'));
    return map[agentId] || (agentId.endsWith('-agent') ? agentId.replace(/-agent$/, '') : agentId);
  } catch {
    return agentId.endsWith('-agent') ? agentId.replace(/-agent$/, '') : agentId;
  }
}

const OPENCLAW_CONFIG = path.join(HOME, '.openclaw', 'openclaw.json');

// 读取 Agent 配置
function getAgentConfig() {
  try {
    const config = JSON.parse(fs.readFileSync(OPENCLAW_CONFIG, 'utf-8'));
    const agents = config.agents?.list || [];
    
    // agentMap: ? openclaw.json + IDENTITY.md ?????????
    const defaultColors = ['#ef4444', '#f59e0b', '#3b82f6', '#06b6d4', '#ec4899', '#8b5cf6', '#10b981'];
    const agentMap = {};
    try {
      agents.forEach((agent, idx) => {
        const id = agent.id;
        let name = agent.name || id;
        let icon = agent.identity?.emoji || '🤖';
        // ??? IDENTITY.md ???????
        const workspace = agent.workspace || path.join(HOME, '.openclaw', 'workspaces', id);
        try {
          const identity = fs.readFileSync(path.join(workspace, 'IDENTITY.md'), 'utf-8');
          const nameMatch = identity.match(/\*\*Name:\*\*\s*(.+)/);
          if (nameMatch) { const parsed = nameMatch[1].split(/\s*[\(\/]/)[0].trim(); if (parsed) name = parsed; }
          const emojiMatch = identity.match(/\*\*Emoji:\*\*\s*(\S+)/);
          if (emojiMatch) icon = emojiMatch[1].trim();
        } catch {}
        if (agent.identity?.emoji) icon = agent.identity.emoji;
        agentMap[id] = { name, icon, color: defaultColors[idx % defaultColors.length] };
      });
    } catch (e) {
      console.warn('Failed to build agentMap:', e.message);
    }
    
    return agents.map(agent => {
      const meta = agentMap[agent.id] || { name: agent.id, icon: '📦', color: '#6b7280' };
      return {
        id: agent.id,
        name: meta.name,
        icon: meta.icon,
        color: meta.color,
        model: agent.model || 'unknown',
        workspace: agent.workspace
      };
    });
  } catch (error) {
    console.error('Failed to read agent config:', error);
    return [];
  }
}

// 检查端口是否在线
function checkPort(port) {
  return new Promise((resolve) => {
    const net = require('net');
    const socket = new net.Socket();
    socket.setTimeout(1000);
    socket.on('connect', () => {
      socket.destroy();
      resolve(true);
    });
    socket.on('timeout', () => {
      socket.destroy();
      resolve(false);
    });
    socket.on('error', () => {
      resolve(false);
    });
    socket.connect(port, '127.0.0.1');
  });
}

// ===== Agent 启动/停止/重启 控制（多实例，路径与端口均从配置动态解析，不硬编码）=====
const { spawn: _spawn, exec: _exec } = require('child_process');

function _resolveLaunch() {
  // 运行本服务的 node 即 openclaw 自带 node；据此推导 openclaw.mjs 与工作目录
  const NODE = process.env.OPENCLAW_NODE || process.execPath;
  const baseDir = path.dirname(NODE);
  const MJS = process.env.OPENCLAW_MJS || path.join(baseDir, 'node_modules', 'openclaw', 'openclaw.mjs');
  const WORKDIR = path.dirname(baseDir);
  return { NODE, MJS, WORKDIR };
}

function _resolveAgent(agentId) {
  let config;
  try { config = JSON.parse(fs.readFileSync(OPENCLAW_CONFIG, 'utf-8')); } catch { return { ok: false }; }
  const list = (config.agents && config.agents.list) || [];
  const found = list.find(a => a && a.id === agentId);
  if (!found) return { ok: false };
  if (agentId === 'main') return { ok: true, isMain: true, profile: 'main', port: (config.gateway && config.gateway.port) || 18789 };
  const profile = _getProfile(agentId);
  let port = null;
  try {
    const subCfg = JSON.parse(fs.readFileSync(path.join(HOME, '.openclaw-' + profile, 'openclaw.json'), 'utf-8'));
    if (subCfg.gateway && subCfg.gateway.port) port = subCfg.gateway.port;
  } catch {}
  return { ok: true, isMain: false, profile, port };
}

function _startAgentProcess(agentId, isMain, profile) {
  const { NODE, MJS, WORKDIR } = _resolveLaunch();
  if (!fs.existsSync(MJS)) throw new Error('openclaw.mjs not found: ' + MJS);
  // 打开独立 cmd 窗口（/k 保留窗口）。安装路径无空格，故不加引号以规避 cmd 嵌套引号问题。
  const profileArg = isMain ? '' : ('--profile ' + profile + ' ');
  const cmd = 'title ' + agentId + ' & ' + NODE + ' ' + MJS + ' ' + profileArg + 'gateway --force';
  const child = _spawn('cmd.exe', ['/k', cmd], {
    cwd: fs.existsSync(WORKDIR) ? WORKDIR : undefined,
    detached: true,
    stdio: 'ignore',
    windowsHide: false,
    env: Object.assign({}, process.env, { OPENCLAW_DISABLE_BONJOUR: '1' })
  });
  child.unref();
}

function _findPidsByPort(port) {
  return new Promise((resolve) => {
    _exec('netstat -ano -p tcp', { windowsHide: true, maxBuffer: 8 * 1024 * 1024 }, (err, stdout) => {
      if (err || !stdout) return resolve([]);
      const pids = new Set();
      const re = new RegExp(':' + port + '\\b');
      for (const line of stdout.split(/\r?\n/)) {
        if (!/LISTENING/i.test(line)) continue;
        if (!re.test(line)) continue;
        const m = line.match(/(\d+)\s*$/);
        if (m) pids.add(m[1]);
      }
      resolve([...pids]);
    });
  });
}

function _killPids(pids) {
  return Promise.all(pids.map(pid => new Promise((resolve) => {
    _exec('taskkill /PID ' + pid + ' /F /T', { windowsHide: true }, () => resolve());
  })));
}

// ===== External web server projects (rental 8901, spider-monitor 8902, ...) =====
// Config single-source: <HOME>/.openclaw/workspace/webservers.json (shared with OpenClaw.ps1)
const WEBSERVERS_JSON = path.join(HOME, '.openclaw', 'workspace', 'webservers.json');
function _loadWebServers() {
  try {
    const cfg = JSON.parse(fs.readFileSync(WEBSERVERS_JSON, 'utf-8'));
    return Array.isArray(cfg.webservers) ? cfg.webservers : [];
  } catch { return []; }
}
function _resolveWebServer(id) {
  return _loadWebServers().find(w => w && w.id === id) || null;
}
function _expandWebEnvPlaceholders(value, NODE) {
  // Keep runtime-dependent paths out of webservers.json: OPENCLAW_PACKAGE_DIR moves
  // on every runtime upgrade. OpenClaw.ps1 expands the same placeholder set.
  const map = {
    OPENCLAW_HOME: process.env.OPENCLAW_HOME || path.join(HOME, '.openclaw'),
    OPENCLAW_PACKAGE_DIR: process.env.OPENCLAW_PACKAGE_DIR
      || path.dirname(_resolveLaunch().MJS),
    USERPROFILE: process.env.USERPROFILE || HOME,
    NODE_EXE: NODE
  };
  return String(value).replace(/\$\{(\w+)\}/g, (m, key) =>
    (map[key] !== undefined && map[key] !== null) ? String(map[key]) : m);
}
function _startWebProcess(ws) {
  const { NODE } = _resolveLaunch();
  if (!ws.cwd || !fs.existsSync(ws.cwd)) throw new Error('cwd not found: ' + ws.cwd);
  // An entry may declare `env`; without it a restart from this panel would drop
  // vars like OPENCLAW_HOME / OPENCLAW_PACKAGE_DIR and half-break the service.
  const extraEnv = {};
  if (ws.env && typeof ws.env === 'object') {
    for (const [k, v] of Object.entries(ws.env)) {
      extraEnv[k] = _expandWebEnvPlaceholders(v, NODE);
    }
  }
  const child = _spawn(NODE, [ws.script], {
    cwd: ws.cwd,
    detached: true,
    stdio: 'ignore',
    windowsHide: true,
    env: Object.assign({}, process.env, { PORT: String(ws.port) }, extraEnv)
  });
  child.unref();
}


// ===== Cron jobs (read-only from state/openclaw.sqlite via built-in node:sqlite) =====
const CRON_DB = path.join(HOME, '.openclaw', 'state', 'openclaw.sqlite');
function _readCronJobs() {
  let DatabaseSync;
  try { ({ DatabaseSync } = require('node:sqlite')); }
  catch (e) { return { error: 'node:sqlite unavailable (need Node 22+): ' + e.message, jobs: [] }; }
  if (!fs.existsSync(CRON_DB)) return { error: 'cron db not found: ' + CRON_DB, jobs: [] };
  const db = new DatabaseSync(CRON_DB, { readOnly: true });
  try {
    const rows = db.prepare(
      `SELECT job_id, name, enabled, schedule_kind, schedule_expr, schedule_tz, every_ms,
              next_run_at_ms, last_run_at_ms, last_run_status, last_error, last_duration_ms,
              consecutive_errors, last_delivery_status, running_at_ms, payload_model
       FROM cron_jobs ORDER BY enabled DESC, next_run_at_ms ASC`
    ).all();
    const now = Date.now();
    const jobs = rows.map(r => {
      let scheduleText = r.schedule_kind || '';
      if (r.schedule_kind === 'cron') scheduleText = r.schedule_expr + (r.schedule_tz ? ' (' + r.schedule_tz + ')' : '');
      else if (r.schedule_kind === 'every') scheduleText = 'every ' + Math.round((r.every_ms || 0) / 60000) + 'min';
      else if (r.schedule_kind === 'at') scheduleText = 'once';
      let health = 'unknown';
      if (!r.enabled) health = 'disabled';
      else if (r.last_run_status === 'ok') health = 'ok';
      else if (r.last_run_status === 'error') health = 'error';
      else if (r.last_run_status === 'skipped') health = 'skipped';
      return {
        id: r.job_id,
        name: r.name,
        enabled: !!r.enabled,
        running: !!(r.running_at_ms && (now - r.running_at_ms) < 30 * 60 * 1000),
        schedule: scheduleText,
        scheduleKind: r.schedule_kind,
        model: r.payload_model ? String(r.payload_model).replace('kiro-gw/', '') : '',
        nextRunAtMs: r.next_run_at_ms || null,
        lastRunAtMs: r.last_run_at_ms || null,
        lastRunStatus: r.last_run_status || null,
        lastError: r.last_error || null,
        lastDurationMs: r.last_duration_ms || null,
        consecutiveErrors: r.consecutive_errors || 0,
        lastDeliveryStatus: r.last_delivery_status || null,
        health,
      };
    });
    const summary = {
      total: jobs.length,
      ok: jobs.filter(j => j.health === 'ok').length,
      error: jobs.filter(j => j.health === 'error').length,
      disabled: jobs.filter(j => j.health === 'disabled').length,
      running: jobs.filter(j => j.running).length,
    };
    return { updatedAt: new Date().toISOString(), summary, jobs };
  } finally {
    try { db.close(); } catch {}
  }
}

// ===== Background resident tasks (long-running detached node procs + progress files) =====
const { execSync: _execSync } = require('child_process');
function _listNodeProcs() {
  // returns array of {pid, cmd} for all node.exe processes (via WMIC-free CIM through PowerShell)
  try {
    const out = _execSync(
      'powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \\\"Name=\'node.exe\'\\\" | Select-Object ProcessId,CommandLine | ConvertTo-Json -Compress"',
      { windowsHide: true, maxBuffer: 8 * 1024 * 1024, timeout: 8000 }
    ).toString();
    let arr = JSON.parse(out);
    if (!Array.isArray(arr)) arr = [arr];
    return arr.map(p => ({ pid: p.ProcessId, cmd: p.CommandLine || '' }));
  } catch { return []; }
}
function _safeReadJson(p) { try { return JSON.parse(fs.readFileSync(p, 'utf-8')); } catch { return null; } }
function _readBgTasks() {
  const procs = _listNodeProcs();
  const countCmd = (re) => procs.filter(p => re.test(p.cmd)).length;
  const tasks = [];

  // --- Task 1: overseas 4-band reap (dead-station deletion) ---
  const reapDir = path.join('D:', 'Kiro', 'testspider', 'platform', 'data', 'bulk', 'cn', 'reach-overseas');
  const bands = [];
  let processedSum = 0, deletedSum = 0, reachableSum = 0, deadSum = 0, maxIdMax = 0, lastUpdate = 0;
  for (let w = 1; w <= 4; w++) {
    const j = _safeReadJson(path.join(reapDir, `reap-progress-w${w}.json`));
    if (!j) continue;
    processedSum += j.processed || 0;
    deletedSum += j.deleted || 0;
    reachableSum += j.reachable || 0;
    deadSum += j.dead || 0;
    if (j.maxId > maxIdMax) maxIdMax = j.maxId;
    const ts = j.updatedAt ? Date.parse(j.updatedAt) : 0;
    if (ts > lastUpdate) lastUpdate = ts;
    bands.push({ band: 'w' + w, processed: j.processed || 0, deleted: j.deleted || 0, completed: !!j.completed, updatedAt: j.updatedAt || null });
  }
  const reapWorkers = countCmd(/overseas-reap-supervised/);
  if (bands.length) {
    // universe ~= sum of per-band id spans; use maxId of last band as rough total scanned universe
    const universe = 250234330; // last band maxId (full overseas id space)
    const pct = universe > 0 ? +(processedSum / universe * 100).toFixed(2) : 0;
    const deadRate = processedSum > 0 ? +(deadSum / processedSum * 100).toFixed(1) : 0;
    const allDone = bands.length === 4 && bands.every(b => b.completed);
    tasks.push({
      id: 'overseas-reap',
      name: '境外死站删除（4带并行）',
      guardCron: 'f12dfe23 · 每小时巡检',
      workers: reapWorkers,
      expectedWorkers: 4,
      alive: reapWorkers > 0,
      allDone,
      progressPct: pct,
      metrics: {
        '已扫描': processedSum,
        '已删死站': deletedSum,
        '可达': reachableSum,
        '死站率%': deadRate,
      },
      bands,
      lastUpdateMs: lastUpdate || null,
    });
  }

  // --- Task 2: domestic queue-runner (source census/expansion orchestrator) ---
  const qLog = path.join('D:', 'Kiro', 'testspider', 'platform', 'data', 'bulk', 'cn', 'queue-runner.log');
  const qAlive = countCmd(/sweep-queue-runner/);
  let qDone = false, qLastPhase = '', qLastMs = null;
  try {
    const st = fs.statSync(qLog);
    qLastMs = st.mtimeMs;
    const buf = fs.readFileSync(qLog, 'utf-8');
    const lines = buf.trimEnd().split(/\r?\n/).slice(-8);
    for (let i = lines.length - 1; i >= 0; i--) {
      let ev = null; try { ev = JSON.parse(lines[i]); } catch {}
      if (ev && ev.event) {
        if (ev.event === 'queue_all_done') { qDone = true; qLastPhase = 'queue_all_done'; break; }
        if (!qLastPhase) qLastPhase = ev.event + (ev.phase ? (':' + ev.phase) : '');
      }
    }
  } catch {}
  tasks.push({
    id: 'cn-queue-runner',
    name: '境内信源普查编排器 (queue-runner)',
    guardCron: '9305c313 · 每小时保活',
    workers: qAlive,
    expectedWorkers: 1,
    alive: qAlive > 0,
    allDone: qDone,
    progressPct: qDone ? 100 : null,
    metrics: { '最后事件': qLastPhase || '-' },
    bands: [],
    lastUpdateMs: qLastMs,
  });

  return { updatedAt: new Date().toISOString(), tasks };
}

const server = http.createServer(async (req, res) => {
  // CORS
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  
  if (req.method === 'OPTIONS') {
    res.writeHead(200);
    res.end();
    return;
  }
  
  // 路由：获取状态
  if (req.url === '/api/status') {
    const agentConfigs = getAgentConfig();
    // ???? portMap??? sub-agent ? openclaw.json ????
    const portMap = {};
    try {
      const mainCfg = JSON.parse(fs.readFileSync(path.join(HOME, '.openclaw', 'openclaw.json'), 'utf-8'));
      portMap['main'] = (mainCfg.gateway && mainCfg.gateway.port) || 18789;
      const agentList = mainCfg.agents?.list || [];
      for (const agent of agentList) {
        if (agent.id === 'main') continue;
        const profile = _getProfile(agent.id);
        try {
          const subCfg = JSON.parse(fs.readFileSync(path.join(HOME, `.openclaw-${profile}`, 'openclaw.json'), 'utf-8'));
          if (subCfg.gateway?.port) portMap[agent.id] = subCfg.gateway.port;
        } catch {}
      }
    } catch (e) {
      console.warn('Failed to build portMap from config:', e.message);
      if (!portMap['main']) portMap['main'] = 18789;
    }
    
    const statusPromises = agentConfigs.map(async (agent) => {
      const port = portMap[agent.id];
      const online = port ? await checkPort(port) : false;
      return {
        ...agent,
        port,
        profile: _getProfile(agent.id),
        online,
        status: online ? 'online' : 'offline'
      };
    });
    
    const statuses = await Promise.all(statusPromises);
    
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify(statuses));
    return;
  }
  
  // 路由：调度器统计 (proxy to Kiro Gateway)
  if (req.url === '/api/scheduler') {
    const http2 = require('http');
    const opts = {
      hostname: '127.0.0.1',
      port: 9000,
      path: '/scheduler/stats',
      method: 'GET',
      headers: { 'Authorization': 'Bearer my-super-secret-password-123' },
      timeout: 3000
    };
    const proxyReq = http2.request(opts, (proxyRes) => {
      let body = '';
      proxyRes.on('data', (chunk) => { body += chunk; });
      proxyRes.on('end', () => {
        res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
        res.end(body);
      });
    });
    proxyReq.on('error', () => {
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      res.end(JSON.stringify({ error: 'Kiro Gateway unavailable', active: 0, queued: 0, max_concurrent: 0, total_requests: 0, total_queued: 0, total_timeouts: 0, total_completed: 0 }));
    });
    proxyReq.on('timeout', () => { proxyReq.destroy(); });
    proxyReq.end();
    return;
  }
  
    // 路由：Cron 任务调度（只读，读 state/openclaw.sqlite 的 cron_jobs 表）
  if (req.url === '/api/cron') {
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    try { res.end(JSON.stringify(_readCronJobs())); }
    catch (e) { res.end(JSON.stringify({ error: e.message, jobs: [] })); }
    return;
  }

  // 路由：后台常驻任务（只读，进程存活 + 进度文件聚合）
  if (req.url === '/api/bgtasks') {
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    try { res.end(JSON.stringify(_readBgTasks())); }
    catch (e) { res.end(JSON.stringify({ error: e.message, tasks: [] })); }
    return;
  }

  // 路由：停止 Agent
  // 路由：启动 Agent（先检查端口，再打开独立窗口启动）
  if (req.url.startsWith('/api/start/')) {
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    const agentId = decodeURIComponent(req.url.slice('/api/start/'.length).split('?')[0].split('/')[0]);
    const info = _resolveAgent(agentId);
    if (!info.ok) { res.end(JSON.stringify({ ok: false, error: 'unknown agent: ' + agentId })); return; }
    if (info.port && await checkPort(info.port)) { res.end(JSON.stringify({ ok: false, already: true, message: 'already running', port: info.port })); return; }
    try { _startAgentProcess(agentId, info.isMain, info.profile); res.end(JSON.stringify({ ok: true, starting: true, port: info.port })); }
    catch (e) { res.end(JSON.stringify({ ok: false, error: e.message })); }
    return;
  }

  // 路由：停止 Agent（按端口结束监听进程）
  if (req.url.startsWith('/api/stop/')) {
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    const parts = req.url.slice('/api/stop/'.length).split('?')[0].split('/').filter(Boolean);
    const agentId = decodeURIComponent(parts[0] || '');
    const info = _resolveAgent(agentId);
    if (info.isMain) { res.end(JSON.stringify({ ok: false, error: '主 Agent 由启动脚本守护，不在此停止' })); return; }
    const port = parts[1] ? parseInt(parts[1], 10) : info.port;
    if (!port) { res.end(JSON.stringify({ ok: false, error: 'no port' })); return; }
    try { const pids = await _findPidsByPort(port); await _killPids(pids); res.end(JSON.stringify({ ok: true, stopped: true, pids })); }
    catch (e) { res.end(JSON.stringify({ ok: false, error: e.message })); }
    return;
  }
  
  // 路由：重启 Agent
  // 路由：重启 Agent（先按端口结束，再启动）
  if (req.url.startsWith('/api/restart/')) {
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    const parts = req.url.slice('/api/restart/'.length).split('?')[0].split('/').filter(Boolean);
    const agentId = decodeURIComponent(parts[0] || '');
    const info = _resolveAgent(agentId);
    if (!info.ok) { res.end(JSON.stringify({ ok: false, error: 'unknown agent: ' + agentId })); return; }
    const port = parts[1] ? parseInt(parts[1], 10) : info.port;
    try {
      if (port) { const pids = await _findPidsByPort(port); await _killPids(pids); await new Promise(r => setTimeout(r, 800)); }
      _startAgentProcess(agentId, info.isMain, info.profile);
      res.end(JSON.stringify({ ok: true, restarting: true, port }));
    } catch (e) { res.end(JSON.stringify({ ok: false, error: e.message })); }
    return;
  }
  
  // 路由：查看日志
  // Web server projects: list + running status
  if (req.url === '/api/webservers') {
    const list = _loadWebServers();
    const statuses = await Promise.all(list.map(async (ws) => {
      const online = ws.port ? await checkPort(ws.port) : false;
      return { id: ws.id, name: ws.name, emoji: ws.emoji || '', desc: ws.desc || '', port: ws.port, url: ws.url || ('http://127.0.0.1:' + ws.port), online, status: online ? 'online' : 'offline' };
    }));
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify(statuses));
    return;
  }

  // Web server project: start
  if (req.url.startsWith('/api/webserver/start/')) {
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    const id = decodeURIComponent(req.url.slice('/api/webserver/start/'.length).split('?')[0].split('/')[0]);
    const ws = _resolveWebServer(id);
    if (!ws) { res.end(JSON.stringify({ ok: false, error: 'unknown webserver: ' + id })); return; }
    if (ws.port && await checkPort(ws.port)) { res.end(JSON.stringify({ ok: false, already: true, message: 'already running', port: ws.port })); return; }
    try { _startWebProcess(ws); res.end(JSON.stringify({ ok: true, starting: true, port: ws.port })); }
    catch (e) { res.end(JSON.stringify({ ok: false, error: e.message })); }
    return;
  }

  // Web server project: stop (kill by port)
  if (req.url.startsWith('/api/webserver/stop/')) {
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    const id = decodeURIComponent(req.url.slice('/api/webserver/stop/'.length).split('?')[0].split('/')[0]);
    const ws = _resolveWebServer(id);
    if (!ws || !ws.port) { res.end(JSON.stringify({ ok: false, error: 'unknown webserver: ' + id })); return; }
    try { const pids = await _findPidsByPort(ws.port); await _killPids(pids); res.end(JSON.stringify({ ok: true, stopped: true, pids })); }
    catch (e) { res.end(JSON.stringify({ ok: false, error: e.message })); }
    return;
  }

  // Web server project: restart
  if (req.url.startsWith('/api/webserver/restart/')) {
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    const id = decodeURIComponent(req.url.slice('/api/webserver/restart/'.length).split('?')[0].split('/')[0]);
    const ws = _resolveWebServer(id);
    if (!ws) { res.end(JSON.stringify({ ok: false, error: 'unknown webserver: ' + id })); return; }
    try {
      if (ws.port) { const pids = await _findPidsByPort(ws.port); await _killPids(pids); await new Promise(r => setTimeout(r, 800)); }
      _startWebProcess(ws);
      res.end(JSON.stringify({ ok: true, restarting: true, port: ws.port }));
    } catch (e) { res.end(JSON.stringify({ ok: false, error: e.message })); }
    return;
  }

  if (req.url.startsWith('/api/logs/')) {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ exists: false, error: 'Not implemented' }));
    return;
  }
  
  // 路由：Canvas 静态文件（供 embed iframe 无认证访问）
  const canvasPrefix = '/__openclaw__/canvas/';
  const canvasPrefix2 = '/canvas/';
  const urlPath = req.url.split('?')[0];
  if (urlPath.startsWith(canvasPrefix) || urlPath.startsWith(canvasPrefix2)) {
    const relativePath = urlPath.startsWith(canvasPrefix)
      ? urlPath.slice(canvasPrefix.length)
      : urlPath.slice(canvasPrefix2.length);
    const canvasRoot = path.join(HOME, '.openclaw', 'canvas');
    const filePath = path.join(canvasRoot, relativePath);
    // 安全检查：确保不能跳出 canvas 目录
    const resolved = path.resolve(filePath);
    if (!resolved.startsWith(path.resolve(canvasRoot))) {
      res.writeHead(403);
      res.end('Forbidden');
      return;
    }
    // 如果是目录，尝试 index.html
    let targetFile = resolved;
    try {
      if (fs.statSync(targetFile).isDirectory()) {
        targetFile = path.join(targetFile, 'index.html');
      }
    } catch {}
    if (fs.existsSync(targetFile)) {
      const ext = path.extname(targetFile).toLowerCase();
      const mimeMap = { '.html': 'text/html', '.css': 'text/css', '.js': 'application/javascript', '.json': 'application/json', '.png': 'image/png', '.jpg': 'image/jpeg', '.svg': 'image/svg+xml', '.gif': 'image/gif' };
      const contentType = mimeMap[ext] || 'application/octet-stream';
      res.writeHead(200, { 'Content-Type': contentType + '; charset=utf-8' });
      res.end(fs.readFileSync(targetFile));
    } else {
      res.writeHead(404);
      res.end('Canvas file not found');
    }
    return;
  }

  // 默认：返回 HTML
  const htmlPath = path.join(__dirname, 'dashboard.html');
  if (fs.existsSync(htmlPath)) {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(fs.readFileSync(htmlPath));
  } else {
    res.writeHead(404);
    res.end('dashboard.html not found');
  }
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`Dashboard server running at http://127.0.0.1:${PORT}/`);
});
