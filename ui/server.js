/**
 * Verdaccio 工具箱 — 本地 Web 控制台
 *
 * 启动:  node server.js        (或双击根目录 run-ui.bat)
 * 访问:  http://localhost:4874
 *
 * 仅监听 127.0.0.1,只在本机使用,无任何外部依赖。
 */
'use strict';

const http = require('http');
const fs = require('fs');
const os = require('os');
const net = require('net');
const path = require('path');
const { spawn } = require('child_process');

const PORT = Number(process.env.PORT || 4874);
const ROOT = path.resolve(__dirname, '..');
const INDEX = path.join(__dirname, 'public', 'index.html');
const REGISTRY = process.env.REGISTRY || 'http://localhost:4873';
// 工具箱启动 Verdaccio 时记录所用 config,所有脚本 / API 跟随该记录
const ACTIVE_CONFIG_FILE = path.join(ROOT, 'active-config.txt');

// 允许执行的脚本白名单(相对仓库根目录),防止任意命令执行
const SCRIPTS = {
  'start':               { file: 'start.ps1' },
  'start-background':    { file: 'start-background.ps1' },
  'stop':                { file: 'stop.ps1' },
  'status':              { file: 'status.ps1' },
  'test':                { file: 'test.ps1' },
  'backup-db':           { file: 'backup-db.ps1' },
  'check-db':            { file: 'check-db.ps1' },
  'clean-db':            { file: 'clean-db.ps1' },
  'clean-cache':         { file: 'clean-cache.ps1' },
  'remove-package':      { file: 'remove-package.ps1' },
  'remove-scope':        { file: 'remove-scope.ps1' },
  'remove-all-packages': { file: 'remove-all-packages.ps1' },
  'rotate-secret':       { file: 'rotate-secret.ps1' },
  'login':               { file: 'login.ps1' },
  'register':            { file: 'register.ps1' },
};

let current = null; // 正在运行的子进程

// ---------------------------------------------------------------------------
// 工具函数
// ---------------------------------------------------------------------------

function psQuote(s) {
  return "'" + String(s).replace(/'/g, "''") + "'";
}

function json(res, status, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
  });
  res.end(body);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (c) => {
      size += c.length;
      if (size > 64 * 1024) {
        reject(new Error('body too large'));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

// ---------------------------------------------------------------------------
// 解析 Verdaccio 实际使用的 config / storage
//   优先级:环境变量 > 工具箱启动记录(active-config.txt)>
//          运行中 Verdaccio 进程的 -c 参数 > %APPDATA% 默认配置
// ---------------------------------------------------------------------------

function readActiveConfig() {
  try {
    const line = fs.readFileSync(ACTIVE_CONFIG_FILE, 'utf8').split(/\r?\n/)[0].trim();
    return line || null;
  } catch {
    return null;
  }
}

// 检测正在运行的 verdaccio 进程的 -c 配置(结果缓存 30s,避免每次请求都起 PowerShell)
let runningConfigCache = { value: null, at: 0 };

function detectRunningConfig() {
  return new Promise((resolve) => {
    let settled = false;
    const child = spawn(
      'powershell.exe',
      [
        '-NoProfile',
        '-Command',
        '(Get-CimInstance Win32_Process -Filter "Name=\'node.exe\'" -ErrorAction SilentlyContinue | ' +
          'Where-Object { $_.CommandLine -match \'verdaccio\' } | ' +
          'Select-Object -First 1).CommandLine',
      ],
      { stdio: ['ignore', 'pipe', 'ignore'] }
    );
    const finish = (v) => {
      if (settled) return;
      settled = true;
      try { child.kill(); } catch {}
      resolve(v);
    };
    let out = '';
    child.stdout.on('data', (d) => (out += d.toString('utf8')));
    child.on('error', () => finish(null));
    child.on('close', () => {
      const m = out.match(/(?:^|\s)-c\s+(?:"([^"]+)"|'([^']+)'|(\S+))/);
      finish(m ? m[1] || m[2] || m[3] : null);
    });
    setTimeout(() => finish(null), 5000);
  });
}

// 从 config.yaml 的 storage: 字段解析存储目录(相对路径基于 config 所在目录)
function parseStorageFromConfig(configPath) {
  try {
    const text = fs.readFileSync(configPath, 'utf8');
    const m = text.match(/^\s*storage\s*:\s*(.+?)\s*(?:#.*)?$/m);
    let rel = m ? m[1].trim().replace(/^["']|["']$/g, '') : 'storage';
    if (path.isAbsolute(rel)) return rel;
    return path.resolve(path.dirname(configPath), rel);
  } catch {
    return path.join(path.dirname(configPath), 'storage');
  }
}

async function resolveActivePaths() {
  let config = process.env.VERDACCIO_CONFIG || readActiveConfig();
  if (!config) {
    if (Date.now() - runningConfigCache.at > 30 * 1000) {
      runningConfigCache.at = Date.now();
      runningConfigCache.value = await detectRunningConfig();
    }
    config =
      runningConfigCache.value ||
      path.join(process.env.APPDATA || process.env.USERPROFILE || '', 'verdaccio', 'config.yaml');
  }
  const storage = process.env.VERDACCIO_STORAGE || parseStorageFromConfig(config);
  return { config, storage };
}

// ---------------------------------------------------------------------------
// API: 运行状态(Verdaccio 是否在线)
// ---------------------------------------------------------------------------

function handleStatus(res) {
  const ping = http
    .get(REGISTRY + '/-/ping', (r) => {
      r.resume();
      const online = r.statusCode === 200;
      r.on('end', () => json(res, 200, { online }));
    })
    .on('error', () => json(res, 200, { online: false }));
  ping.setTimeout(2500, () => {
    ping.destroy();
    json(res, 200, { online: false });
  });
}

// ---------------------------------------------------------------------------
// API: 读取 DB 包列表
//   /api/packages            → 仅名称列表
//   /api/packages?detail=1   → 附带版本 / 更新时间(读取 storage 中 package.json)
// ---------------------------------------------------------------------------

function readPackageDetail(name, storageDir) {
  const pkgJson = path.join(storageDir, ...name.split('/'), 'package.json');
  try {
    const m = JSON.parse(fs.readFileSync(pkgJson, 'utf8'));
    const st = fs.statSync(pkgJson);
    // verdaccio 存储的是 packument 格式,最新版本在 dist-tags.latest
    const version =
      (m['dist-tags'] && m['dist-tags'].latest) || m.version || '-';
    return {
      name,
      version,
      description: m.description || '',
      modified: st.mtime.toISOString(),
    };
  } catch {
    return { name, version: '-', description: '', modified: null, missing: true };
  }
}

async function handlePackages(res, detail) {
  const { config, storage } = await resolveActivePaths();
  const dbFile = path.join(storage, '.verdaccio-db.json');
  fs.readFile(dbFile, 'utf8', (err, data) => {
    if (err) {
      json(res, 200, { count: 0, packages: [], detail: [], config, storage, error: 'DB 文件未找到: ' + dbFile });
      return;
    }
    try {
      const db = JSON.parse(data);
      const list = Array.isArray(db.list) ? db.list : [];
      const out = { count: list.length, packages: list, config, storage };
      if (detail) out.detail = list.map((name) => readPackageDetail(name, storage));
      json(res, 200, out);
    } catch (e) {
      json(res, 200, { count: 0, packages: [], detail: [], config, storage, error: 'DB 解析失败: ' + e.message });
    }
  });
}

// ---------------------------------------------------------------------------
// API: 执行脚本(SSE 流式返回输出)
// ---------------------------------------------------------------------------

async function handleRun(req, res) {
  let body;
  try {
    body = JSON.parse(await readBody(req));
  } catch {
    return json(res, 400, { error: '请求体不是合法 JSON' });
  }

  const id = String(body.id || '');
  const def = SCRIPTS[id];
  if (!def) return json(res, 400, { error: '未知命令: ' + id });

  if (current) {
    return json(res, 409, { error: '有命令正在执行,请等待完成或先终止' });
  }

  // 参数:各命令按需校验
  const args = [];
  if (id === 'remove-package') {
    const name = String(body.package || '').trim();
    if (!/^[@a-zA-Z0-9][@a-zA-Z0-9\/._-]*$/.test(name)) {
      return json(res, 400, { error: '包名不合法: ' + name });
    }
    args.push(name);
  }
  if (id === 'remove-scope') {
    let scope = String(body.scope || '').trim();
    if (!/^@?[a-zA-Z0-9][a-zA-Z0-9._-]*$/.test(scope)) {
      return json(res, 400, { error: 'scope 不合法: ' + scope });
    }
    if (!scope.startsWith('@')) scope = '@' + scope;
    args.push(scope);
  }
  if (id === 'start' || id === 'start-background') {
    const cfg = String(body.config || '').trim();
    if (cfg) {
      if (!/^[a-zA-Z]:[\\/][^<>:"|?*\r\n]+$/i.test(cfg) || !/\.(yaml|yml)$/i.test(cfg)) {
        return json(res, 400, { error: 'config 路径不合法(应为 *.yaml 绝对路径): ' + cfg });
      }
      if (!fs.existsSync(cfg)) {
        return json(res, 400, { error: 'config 文件不存在: ' + cfg });
      }
      // 记录本次启动使用的 config,后续脚本 / API 跟随
      try { fs.writeFileSync(ACTIVE_CONFIG_FILE, cfg + '\n'); } catch {}
      args.push(cfg);
    }
  }

  // stdin:交互脚本通过它接收确认词 / 登录信息
  const stdinText = typeof body.stdin === 'string' ? body.stdin : '';

  const scriptPath = path.join(ROOT, def.file);
  const psCommand =
    "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; " +
    "try{[Console]::InputEncoding=[System.Text.Encoding]::UTF8}catch{}; " +
    '& ' + psQuote(scriptPath) +
    (args.length ? ' ' + args.map(psQuote).join(' ') : '');

  const child = spawn(
    'powershell.exe',
    ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', psCommand],
    { cwd: ROOT }
  );

  current = child;

  res.writeHead(200, {
    'Content-Type': 'text/event-stream; charset=utf-8',
    'Cache-Control': 'no-cache',
    Connection: 'keep-alive',
  });

  const sse = (obj) => {
    try { res.write('data: ' + JSON.stringify(obj) + '\n\n'); } catch {}
  };

  sse({ type: 'start', id, pid: child.pid });

  if (stdinText) {
    child.stdin.write(stdinText.replace(/\r?\n/g, '\n') + '\n');
  }
  child.stdin.end();

  child.stdout.on('data', (d) => sse({ type: 'out', text: d.toString('utf8') }));
  child.stderr.on('data', (d) => sse({ type: 'err', text: d.toString('utf8') }));

  child.on('error', (err) => {
    sse({ type: 'err', text: '启动失败: ' + err.message });
    if (current === child) current = null;
    try { res.end(); } catch {}
  });

  // 进程退出即释放 busy,不等 stdio 管道关闭——
  // 因为 start-background 启动的 verdaccio 会继承管道句柄,
  // 导致 close 事件可能永不触发,服务会永久卡在"执行中"。
  child.on('exit', (code) => {
    if (current === child) current = null;
    sse({ type: 'exit', code: code === null ? 'killed' : code });
    // 给输出缓冲留 800ms,之后强制收尾,防止响应悬挂
    setTimeout(() => {
      try { child.stdout.destroy(); } catch {}
      try { child.stderr.destroy(); } catch {}
      try { res.end(); } catch {}
    }, 800);
  });

  child.on('close', () => {
    try { res.end(); } catch {}
  });
}

// ---------------------------------------------------------------------------
// API: 网络信息 — 其他电脑如何连接本机 Verdaccio
// ---------------------------------------------------------------------------

function testTcp(ip, port, timeoutMs) {
  return new Promise((resolve) => {
    const s = net.connect({ host: ip, port });
    const finish = (ok) => {
      s.destroy();
      resolve(ok);
    };
    s.setTimeout(timeoutMs, () => finish(false));
    s.on('connect', () => finish(true));
    s.on('error', () => finish(false));
  });
}

// 从 config.yaml 读取 listen 设置(未设置时 verdaccio 默认仅监听 localhost)
function readListenSetting(configPath) {
  try {
    const text = fs.readFileSync(configPath, 'utf8');
    const m = text.match(/^\s*listen\s*:\s*(.+?)\s*(?:#.*)?$/m);
    return m ? m[1] : null;
  } catch {
    return null;
  }
}

async function handleNetwork(res) {
  const { config, storage } = await resolveActivePaths();
  const port = Number((REGISTRY.match(/:(\d+)/) || [])[1] || 4873);
  const ips = [];
  const seen = new Set();
  for (const [ifname, addrs] of Object.entries(os.networkInterfaces())) {
    for (const a of addrs || []) {
      if (a.family !== 'IPv4' || a.internal) continue;
      if (seen.has(a.address)) continue;
      seen.add(a.address);
      ips.push({ ip: a.address, ifname });
    }
  }
  await Promise.all(
    ips.map(async (x) => {
      x.reachable = await testTcp(x.ip, port, 1000);
    })
  );
  json(res, 200, {
    hostname: os.hostname(),
    port,
    listen: readListenSetting(config),
    config,
    storage,
    ips,
    lanAccessible: ips.some((x) => x.reachable),
  });
}

// ---------------------------------------------------------------------------
// API: 上游服务器(uplinks)管理 — 读写 config.yaml 的 uplinks 段
//   GET  /api/uplinks                      → 列表 + packages 中的 proxy 引用
//   POST /api/uplinks {action,name,url}    → add / update / delete
//   写入前自动备份到 config-backups\;删除 uplink 时同步清理 proxy 引用
// ---------------------------------------------------------------------------

const CONFIG_BACKUP_DIR = path.join(ROOT, 'config-backups');

// 定位顶层 section(如 uplinks:)的行范围 [start, end):end 指向下一个顶层键
function findTopSection(lines, name) {
  const headRe = new RegExp('^' + name + '\\s*:\\s*(?:#.*)?$');
  const keyRe = /^[A-Za-z_$][\w$-]*\s*:/;
  const start = lines.findIndex((l) => headRe.test(l));
  if (start < 0) return null;
  let end = lines.length;
  for (let i = start + 1; i < lines.length; i++) {
    if (keyRe.test(lines[i])) {
      end = i;
      break;
    }
  }
  return { start, end };
}

const indentOf = (s) => s.length - s.replace(/^ */, '').length;

// 解析 uplinks 段:每项 { name, url, lineStart, lineEnd }
function parseUplinkEntries(lines) {
  const sec = findTopSection(lines, 'uplinks');
  const out = [];
  if (!sec) return out;
  for (let i = sec.start + 1; i < sec.end; i++) {
    const m = lines[i].match(/^\s+([\w.$@-]+)\s*:\s*(?:#.*)?$/);
    if (!m) continue;
    let j = i + 1;
    let url = '';
    for (; j < sec.end; j++) {
      if (/^\s+[\w.$@-]+\s*:\s*(?:#.*)?$/.test(lines[j]) && indentOf(lines[j]) === indentOf(lines[i])) break;
      const um = lines[j].match(/^\s+url\s*:\s*(.+?)\s*(?:#.*)?$/);
      if (um) url = um[1].trim().replace(/^["']|["']$/g, '');
    }
    out.push({ name: m[1], url, lineStart: i, lineEnd: j });
  }
  return out;
}

// 解析 packages 段的 proxy 引用:Map<uplinkName, [pattern, ...]>
// 以及每个 pattern 当前的 proxy 值:[{pattern, proxy}]
function parsePackagesProxy(lines) {
  const refs = new Map();
  const pats = [];
  const sec = findTopSection(lines, 'packages');
  if (!sec) return { refs, pats };
  const baseIndent = indentOf(lines[sec.start + 1] || '');
  let curPat = null;
  for (let i = sec.start + 1; i < sec.end; i++) {
    const ind = indentOf(lines[i]);
    const pm = lines[i].match(/^(\s+)(['"]?)(.+?)\2\s*:\s*(?:#.*)?$/);
    if (pm && ind === baseIndent) {
      curPat = pm[3];
      pats.push({ pattern: curPat, proxy: '', lineStart: i, lineEnd: i + 1 });
      continue;
    }
    const px = lines[i].match(/^(\s+)proxy\s*:\s*(.+?)\s*(?:#.*)?$/);
    if (px && curPat) {
      const val = px[2].split(',').map((s) => s.trim().replace(/[[\]"']/g, '')).filter(Boolean);
      pats[pats.length - 1].proxy = val.join(', ');
      for (const ref of val) {
        if (!refs.has(ref)) refs.set(ref, []);
        refs.get(ref).push(curPat);
      }
    }
    if (curPat) pats[pats.length - 1].lineEnd = i + 1;
  }
  return { refs, pats };
}

function parseProxyRefs(lines) {
  return parsePackagesProxy(lines).refs;
}

async function handleUplinksGet(res) {
  const { config } = await resolveActivePaths();
  let lines;
  try {
    lines = fs.readFileSync(config, 'utf8').split(/\r?\n/);
  } catch (e) {
    return json(res, 200, { config, uplinks: [], packages: [], error: 'config 读取失败: ' + e.message });
  }
  const { refs, pats } = parsePackagesProxy(lines);
  json(res, 200, {
    config,
    uplinks: parseUplinkEntries(lines).map((u) => ({
      name: u.name,
      url: u.url,
      refs: refs.get(u.name) || [],
    })),
    packages: pats.map((p) => ({ pattern: p.pattern, proxy: p.proxy })),
  });
}

// 设置 packages 某个 pattern 的 proxy(name 为空 = 移除代理)
async function handleSetProxy(res, pattern, name) {
  if (!pattern) return json(res, 400, { error: '缺少 pattern' });

  const { config } = await resolveActivePaths();
  let text;
  try {
    text = fs.readFileSync(config, 'utf8');
  } catch (e) {
    return json(res, 500, { error: 'config 读取失败: ' + e.message });
  }

  const eol = text.includes('\r\n') ? '\r\n' : '\n';
  const hadTrailingNl = /\r?\n$/.test(text);
  const lines = text.replace(/\r?\n$/, '').split(/\r?\n/);

  const uplinkNames = parseUplinkEntries(lines).map((u) => u.name);
  if (name && !uplinkNames.includes(name)) {
    return json(res, 400, { error: `uplink "${name}" 不存在,请先添加` });
  }

  const { pats } = parsePackagesProxy(lines);
  const target = pats.find((p) => p.pattern === pattern);
  if (!target) {
    return json(res, 404, { error: `packages 中没有找到规则 "${pattern}"` });
  }

  // 备份(复用同一备份目录与命名)
  try {
    fs.mkdirSync(CONFIG_BACKUP_DIR, { recursive: true });
    const d = new Date();
    const pad = (n) => String(n).padStart(2, '0');
    const ts = `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}-${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`;
    fs.copyFileSync(config, path.join(CONFIG_BACKUP_DIR, `config-${ts}.yaml`));
  } catch (e) {
    return json(res, 500, { error: '备份失败,已放弃写入: ' + e.message });
  }

  // 定位 pattern 块内已有的 proxy 行;新行插入点跳过块尾空行 / 注释
  let proxyIdx = -1;
  for (let i = target.lineStart + 1; i < target.lineEnd; i++) {
    if (/^\s+proxy\s*:/.test(lines[i])) {
      proxyIdx = i;
      break;
    }
  }
  let insertAt = target.lineEnd;
  while (
    insertAt > target.lineStart + 1 &&
    (lines[insertAt - 1].trim() === '' || lines[insertAt - 1].trim().startsWith('#'))
  ) {
    insertAt--;
  }

  if (!name) {
    if (proxyIdx >= 0) lines.splice(proxyIdx, 1);
  } else if (proxyIdx >= 0) {
    const ind = lines[proxyIdx].match(/^\s*/)[0];
    lines[proxyIdx] = `${ind}proxy: ${name}`;
  } else {
    const sec = findTopSection(lines, 'packages');
    const baseIndent = sec ? indentOf(lines[sec.start + 1] || '  x') : 2;
    lines.splice(insertAt, 0, `${' '.repeat(baseIndent + 2)}proxy: ${name}`);
  }

  try {
    fs.writeFileSync(config, lines.join(eol) + (hadTrailingNl ? eol : ''), 'utf8');
  } catch (e) {
    return json(res, 500, { error: 'config 写入失败: ' + e.message });
  }

  const refreshed = parsePackagesProxy(lines);
  json(res, 200, {
    ok: true,
    note: `已将 "${pattern}" 的代理设为 ${name || '(无)'},重启 Verdaccio 后生效`,
    packages: refreshed.pats.map((p) => ({ pattern: p.pattern, proxy: p.proxy })),
    uplinks: parseUplinkEntries(lines).map((u) => ({
      name: u.name,
      url: u.url,
      refs: refreshed.refs.get(u.name) || [],
    })),
  });
}

async function handleUplinksPost(req, res) {
  let body;
  try {
    body = JSON.parse(await readBody(req));
  } catch {
    return json(res, 400, { error: '请求体不是合法 JSON' });
  }

  const action = String(body.action || '');
  const name = String(body.name || '').trim();
  const url = String(body.url || '').trim();
  const pattern = String(body.pattern || '');

  if (!['add', 'update', 'delete', 'set-proxy'].includes(action)) {
    return json(res, 400, { error: 'action 必须是 add / update / delete / set-proxy' });
  }
  if (action === 'set-proxy') {
    return handleSetProxy(res, pattern, name);
  }
  if (!/^[A-Za-z][\w.-]*$/.test(name)) {
    return json(res, 400, { error: 'uplink 名称不合法(字母开头,可含数字 . _ -): ' + name });
  }
  if (action !== 'delete' && !/^https?:\/\/[^\s'"]+$/.test(url)) {
    return json(res, 400, { error: 'URL 不合法(需 http(s):// 开头): ' + url });
  }

  const { config } = await resolveActivePaths();

  let text;
  try {
    text = fs.readFileSync(config, 'utf8');
  } catch (e) {
    return json(res, 500, { error: 'config 读取失败: ' + e.message });
  }

  const eol = text.includes('\r\n') ? '\r\n' : '\n';
  const hadTrailingNl = /\r?\n$/.test(text);
  const lines = text.replace(/\r?\n$/, '').split(/\r?\n/);
  const entries = parseUplinkEntries(lines);
  const existing = entries.find((u) => u.name === name);

  if (action === 'add' && existing) {
    return json(res, 409, { error: `uplink "${name}" 已存在,请直接修改` });
  }
  if (action !== 'add' && !existing) {
    return json(res, 404, { error: `uplink "${name}" 不存在` });
  }

  // 备份(本地时间戳,与 db-backups 命名风格一致)
  try {
    fs.mkdirSync(CONFIG_BACKUP_DIR, { recursive: true });
    const d = new Date();
    const pad = (n) => String(n).padStart(2, '0');
    const ts = `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}-${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`;
    fs.copyFileSync(config, path.join(CONFIG_BACKUP_DIR, `config-${ts}.yaml`));
  } catch (e) {
    return json(res, 500, { error: '备份失败,已放弃写入: ' + e.message });
  }

  if (action === 'add') {
    const sec = findTopSection(lines, 'uplinks');
    const block = [`  ${name}:`, `    url: ${url}`, ''];
    if (!sec) {
      // 配置里没有 uplinks 段:文件末尾新建
      if (lines[lines.length - 1] !== '') lines.push('');
      lines.push('uplinks:', ...block);
    } else {
      // 插到最后一个条目的实际内容之后(跳过段尾的空行与注释),
      // 避免新条目落到下一 section 的说明注释后面
      let insertAt = sec.start + 1;
      const last = entries[entries.length - 1];
      if (last) {
        insertAt = last.lineEnd;
        while (
          insertAt > last.lineStart + 1 &&
          (lines[insertAt - 1].trim() === '' || lines[insertAt - 1].trim().startsWith('#'))
        ) {
          insertAt--;
        }
      }
      lines.splice(insertAt, 0, ...block);
    }
  } else if (action === 'update') {
    // 只替换 url 行,保留 auth / headers 等其他字段
    let replaced = false;
    for (let i = existing.lineStart + 1; i < existing.lineEnd; i++) {
      if (/^\s+url\s*:/.test(lines[i])) {
        const ind = lines[i].match(/^\s*/)[0];
        lines[i] = `${ind}url: ${url}`;
        replaced = true;
        break;
      }
    }
    if (!replaced) {
      lines.splice(existing.lineStart + 1, 0, `    url: ${url}`);
    }
  } else {
    // delete:移除条目,并清理 packages 中的 proxy 引用
    lines.splice(existing.lineStart, existing.lineEnd - existing.lineStart);
    const sec = findTopSection(lines, 'packages');
    if (sec) {
      for (let i = sec.start + 1; i < sec.end; i++) {
        const px = lines[i].match(/^(\s+)proxy\s*:\s*(.+?)\s*(?:#.*)?$/);
        if (!px) continue;
        const rest = px[2].split(',').map((s) => s.trim().replace(/[[\]"']/g, '')).filter((s) => s && s !== name);
        if (rest.length === px[2].split(',').filter((s) => s.trim()).length) continue; // 未引用,不动
        if (rest.length === 0) lines.splice(i--, 1);
        else if (rest.length === 1) lines[i] = `${px[1]}proxy: ${rest[0]}`;
        else lines[i] = `${px[1]}proxy: [${rest.join(', ')}]`;
      }
    }
  }

  try {
    fs.writeFileSync(config, lines.join(eol) + (hadTrailingNl ? eol : ''), 'utf8');
  } catch (e) {
    return json(res, 500, { error: 'config 写入失败: ' + e.message });
  }

  const { refs, pats } = parsePackagesProxy(lines);
  json(res, 200, {
    ok: true,
    note: '已写入 config.yaml,重启 Verdaccio 后生效',
    uplinks: parseUplinkEntries(lines).map((u) => ({
      name: u.name,
      url: u.url,
      refs: refs.get(u.name) || [],
    })),
    packages: pats.map((p) => ({ pattern: p.pattern, proxy: p.proxy })),
  });
}

// ---------------------------------------------------------------------------
// API: 终止当前命令(kill 整个进程树)
// ---------------------------------------------------------------------------

function handleKill(res) {
  if (!current || !current.pid) {
    return json(res, 409, { ok: false, error: '当前没有正在执行的命令' });
  }
  const pid = current.pid;
  spawn('taskkill', ['/pid', String(pid), '/T', '/F'], {
    stdio: 'ignore',
    windowHide: true,
  }).on('close', () => json(res, 200, { ok: true }));
}

// ---------------------------------------------------------------------------
// 静态页面 + 路由
// ---------------------------------------------------------------------------

const server = http.createServer((req, res) => {
  const u = new URL(req.url, 'http://localhost');
  const url = u.pathname;

  if (req.method === 'GET' && (url === '/' || url === '/index.html')) {
    fs.readFile(INDEX, (err, data) => {
      if (err) {
        res.writeHead(500);
        res.end('index.html 读取失败: ' + err.message);
        return;
      }
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(data);
    });
    return;
  }

  if (url === '/favicon.ico') {
    res.writeHead(204);
    res.end();
    return;
  }

  if (req.method === 'GET' && url === '/api/status') return handleStatus(res);
  if (req.method === 'GET' && url === '/api/network') {
    handleNetwork(res).catch((e) => json(res, 500, { error: e.message }));
    return;
  }
  if (req.method === 'GET' && url === '/api/packages') {
    handlePackages(res, u.searchParams.get('detail') === '1').catch((e) =>
      json(res, 500, { error: e.message })
    );
    return;
  }
  if (req.method === 'POST' && url === '/api/run') {
    handleRun(req, res).catch((e) => json(res, 500, { error: e.message }));
    return;
  }
  if (req.method === 'GET' && url === '/api/uplinks') {
    handleUplinksGet(res).catch((e) => json(res, 500, { error: e.message }));
    return;
  }
  if (req.method === 'POST' && url === '/api/uplinks') {
    handleUplinksPost(req, res).catch((e) => json(res, 500, { error: e.message }));
    return;
  }
  if (req.method === 'POST' && url === '/api/kill') return handleKill(res);
  if (req.method === 'POST' && url === '/api/shutdown') {
    // 供新实例接管时让旧实例优雅退出;
    // 要求自定义 header,浏览器跨域表单无法伪造,防误触/CSRF
    if (req.headers['x-toolbox'] !== '1') return json(res, 403, { error: 'forbidden' });
    json(res, 200, { ok: true, bye: true });
    setTimeout(() => process.exit(0), 200);
    return;
  }

  json(res, 404, { error: 'not found' });
});

function startListen(attempt) {
  server.once('error', (err) => {
    if (err.code === 'EADDRINUSE' && attempt === 0) {
      console.log('端口 ' + PORT + ' 已被占用,尝试让旧实例退出并接管…');
      const req = http.request(
        {
          host: '127.0.0.1',
          port: PORT,
          method: 'POST',
          path: '/api/shutdown',
          headers: { 'x-toolbox': '1' },
        },
        (r) => r.resume()
      );
      req.on('error', () => {});
      req.end();
      setTimeout(() => startListen(1), 1500);
    } else {
      console.error('监听失败: ' + err.message);
      console.error('若有其他程序占用 ' + PORT + ',请关闭它或设置 PORT 环境变量。');
      process.exit(1);
    }
  });

  // 注意:这里不能 removeAllListeners('listening') ——
  // 会把全局的横幅/开浏览器处理器一起清掉,导致端口接管后什么都不发生
  server.listen(PORT, '127.0.0.1');
}

// Windows 下打开默认浏览器。
// 注意:不要用 `cmd /c start` + windowHide —— SW_HIDE 会被 start 命令
// 继承给浏览器,导致浏览器进程启动了但窗口不显示。
function openBrowser(url) {
  if (process.platform !== 'win32' || process.env.NO_OPEN) return;
  // explorer.exe 直接走 ShellExecute,最可靠且无黑框闪烁
  const child = spawn('explorer.exe', [url], { detached: true, stdio: 'ignore' });
  child.on('error', () => {
    spawn('cmd', ['/c', 'start', '', url], {
      detached: true,
      stdio: 'ignore',
    }).unref();
  });
  child.unref();
}

server.on('listening', () => {
  const url = `http://localhost:${PORT}`;
  console.log('========================================');
  console.log(' Verdaccio 工具箱已启动');
  console.log('========================================');
  console.log('地址  : ' + url);
  console.log('脚本目录: ' + ROOT);
  // 异步解析实际使用的 config / storage(顺带预热缓存)
  resolveActivePaths()
    .then((p) => {
      console.log('配置  : ' + p.config);
      console.log('存储  : ' + p.storage);
      console.log('');
    })
    .catch(() => {});

  openBrowser(url);
});

startListen(0);
