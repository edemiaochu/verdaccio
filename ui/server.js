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
const STORAGE_DIR =
  process.env.VERDACCIO_STORAGE ||
  'C:\\Users\\lenovo\\.config\\verdaccio\\storage';
const CONFIG_YAML =
  process.env.VERDACCIO_CONFIG ||
  'C:\\Users\\lenovo\\.config\\verdaccio\\config.yaml';

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
  'remove-package':      { file: 'remove-package.ps1' },
  'remove-scope':        { file: 'remove-scope.ps1' },
  'remove-all-packages': { file: 'remove-all-packages.ps1' },
  'rotate-secret':       { file: 'rotate-secret.ps1' },
  'login':               { file: 'login.ps1' },
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

function readPackageDetail(name) {
  const pkgJson = path.join(STORAGE_DIR, ...name.split('/'), 'package.json');
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

function handlePackages(res, detail) {
  const dbFile = path.join(STORAGE_DIR, '.verdaccio-db.json');
  fs.readFile(dbFile, 'utf8', (err, data) => {
    if (err) {
      json(res, 200, { count: 0, packages: [], detail: [], error: 'DB 文件未找到: ' + dbFile });
      return;
    }
    try {
      const db = JSON.parse(data);
      const list = Array.isArray(db.list) ? db.list : [];
      const out = { count: list.length, packages: list };
      if (detail) out.detail = list.map(readPackageDetail);
      json(res, 200, out);
    } catch (e) {
      json(res, 200, { count: 0, packages: [], detail: [], error: 'DB 解析失败: ' + e.message });
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
function readListenSetting() {
  try {
    const text = fs.readFileSync(CONFIG_YAML, 'utf8');
    const m = text.match(/^\s*listen\s*:\s*(.+?)\s*(?:#.*)?$/m);
    return m ? m[1] : null;
  } catch {
    return null;
  }
}

async function handleNetwork(res) {
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
    listen: readListenSetting(),
    config: CONFIG_YAML,
    ips,
    lanAccessible: ips.some((x) => x.reachable),
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
    return handlePackages(res, u.searchParams.get('detail') === '1');
  }
  if (req.method === 'POST' && url === '/api/run') {
    handleRun(req, res).catch((e) => json(res, 500, { error: e.message }));
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
  console.log('存储  : ' + STORAGE_DIR);
  console.log('');

  openBrowser(url);
});

startListen(0);
