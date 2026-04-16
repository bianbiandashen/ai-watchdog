#!/usr/bin/env node
// ai-watchdog web server — no npm dependencies, pure Node.js built-ins
'use strict';
const http = require('http');
const { exec, execSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const os = require('os');

const PORT = process.env.WATCHDOG_PORT || 7474;
const ROOT = path.dirname(__dirname); // ai-watchdog/
const STATE_FILE = path.join(ROOT, 'logs', 'state.json');
const LOG_FILE = path.join(ROOT, 'logs', 'watchdog.log');
const CLAUDE_PROJECTS = path.join(os.homedir(), '.claude', 'projects');
const CODEX_HISTORY = path.join(os.homedir(), '.codex', 'history.jsonl');
const ORBA_DIR = path.join(os.homedir(), '.orba');

// ── Helpers ──────────────────────────────────────────────────────────────────
function sh(cmd) {
  try { return execSync(cmd, { encoding: 'utf8', timeout: 5000 }); }
  catch { return ''; }
}

function readJSON(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); }
  catch { return null; }
}

function getMemInfo() {
  const pageSize = parseInt(sh('sysctl -n hw.pagesize').trim());
  const vmStat = sh('vm_stat');
  const getPages = (label) => {
    const m = vmStat.match(new RegExp(label + '\\s+(\\d+)'));
    return m ? parseInt(m[1]) : 0;
  };
  const freePages = getPages('Pages free:') + getPages('Pages inactive:') + getPages('Pages purgeable:');
  const totalMB = parseInt(sh('sysctl -n hw.memsize').trim()) / 1024 / 1024;
  const freeMB = Math.round(freePages * pageSize / 1024 / 1024);
  const usedMB = Math.round(totalMB - freeMB);
  return { freeMB, usedMB, totalMB: Math.round(totalMB), pct: Math.round(usedMB * 100 / totalMB) };
}

function getDaemonStatus() {
  const pidFile = path.join(ROOT, 'logs', 'watchdog.pid');
  try {
    const pid = parseInt(fs.readFileSync(pidFile, 'utf8').trim());
    try { process.kill(pid, 0); return { running: true, pid }; }
    catch { return { running: false, pid: null }; }
  } catch { return { running: false, pid: null }; }
}

// ── Process APIs ──────────────────────────────────────────────────────────────
const MCP_PATTERNS = [
  'server-qdrant\\.js', 'orba-context-mcp', 'orba-context@',
  'orba-context/dist/mcp', 'figma.*mcp', 'mitmproxy.*mcp',
  'playwright.*mcp', 'ChromeDevTools.*mcp', 'proxyman.*mcp',
  'plugin_miniprogram', 'mp-cli.*mcp'
];
const TOOL_PATTERNS = ['claude', 'codex', 'Cursor', 'Warp', 'OrbaDesktop', 'orba-cli', 'orba-desktop'];

// Human-friendly names from command strings
const MCP_NAME_RULES = [
  { re: /server-qdrant/,            name: 'Qdrant Vector DB' },
  { re: /orba-context-mcp/,         name: 'Orba Context Graph' },
  { re: /orba-context@|orba-context\/dist\/mcp/, name: 'Orba Context MCP' },
  { re: /figma.*mcp|OrbaFigmaToCode/,            name: 'Figma MCP' },
  { re: /mitmproxy/,                name: 'mitmproxy MCP' },
  { re: /playwright/,               name: 'Playwright MCP' },
  { re: /ChromeDevTools/,           name: 'Chrome DevTools MCP' },
  { re: /proxyman/,                 name: 'Proxyman MCP' },
  { re: /plugin_miniprogram/,       name: 'MiniProgram IDE-CLI' },
  { re: /mp-cli/,                   name: 'MP CLI MCP' },
];

function getMCPToolName(cmd) {
  for (const { re, name } of MCP_NAME_RULES) {
    if (re.test(cmd)) return name;
  }
  const m = cmd.match(/\/([^/]+\.(?:js|py|ts))(?:\s|$)/);
  return m ? m[1] : 'MCP Server';
}

// Bulk process tree — ONE ps call instead of N×6
let _procTree = null;
let _procTreeTs = 0;
function buildProcTree() {
  const now = Date.now();
  if (_procTree && now - _procTreeTs < 5000) return _procTree;
  _procTree = {};
  const lines = sh('ps -axo pid=,ppid=,command= 2>/dev/null').split('\n');
  for (const line of lines) {
    const m = line.trim().match(/^(\d+)\s+(\d+)\s+(.*)$/);
    if (!m) continue;
    _procTree[m[1]] = { ppid: m[2], cmd: m[3] };
  }
  _procTreeTs = now;
  return _procTree;
}

function getOwner(pid) {
  const tree = buildProcTree();
  const ownerRe = /\b(claude|codex|orba-cli|Cursor|OrbaDesktop|Warp)\b/;
  let cur = String(pid);
  for (let i = 0; i < 6; i++) {
    const node = tree[cur];
    if (!node) return { tool: 'orphan', hint: 'parent dead' };
    const ppid = node.ppid;
    if (!ppid || ppid === '1' || ppid === '0') {
      if (node.cmd.includes('spanner') || node.cmd.includes('benchmark')) return { tool: 'benchmark', hint: 'spanner-harness' };
      return { tool: 'orphan', hint: 'launchd' };
    }
    const parent = tree[ppid];
    if (!parent) return { tool: 'orphan', hint: 'parent gone' };
    const m = parent.cmd.match(ownerRe);
    if (m) return { tool: m[1], hint: '' };
    cur = ppid;
  }
  return { tool: '?', hint: '' };
}

function isOrphanFast(pid) {
  const tree = buildProcTree();
  const node = tree[String(pid)];
  if (!node) return true;
  return node.ppid === '1';
}

// Port cache (lsof is slow)
let _portCache = null;
let _portCacheTs = 0;
function buildPortCache() {
  const now = Date.now();
  if (_portCache && now - _portCacheTs < 10000) return _portCache;
  _portCache = {};
  for (const line of sh('lsof -iTCP -sTCP:LISTEN -P -n 2>/dev/null').split('\n')) {
    const parts = line.trim().split(/\s+/);
    if (parts.length < 9) continue;
    const pid = parseInt(parts[1]);
    const m = (parts[8] || '').match(/:(\d+)$/);
    if (!m || isNaN(pid)) continue;
    if (!_portCache[pid]) _portCache[pid] = [];
    const port = parseInt(m[1]);
    if (!_portCache[pid].includes(port)) _portCache[pid].push(port);
  }
  _portCacheTs = now;
  return _portCache;
}
function getListenPorts(pid) { return (buildPortCache())[pid] || []; }

function parseProcessLine(line) {
  const parts = line.trim().split(/\s+/);
  if (parts.length < 11) return null;
  return {
    user: parts[0], pid: parseInt(parts[1]), cpu: parseFloat(parts[2]),
    mem: parseFloat(parts[3]), rss: Math.round(parseInt(parts[5]) / 1024),
    stat: parts[7], started: parts[8], time: parts[9],
    cmd: parts.slice(10).join(' ')
  };
}

function isOrphan(pid) {
  const ppid = sh(`ps -o ppid= -p ${pid} 2>/dev/null`).trim();
  if (!ppid || ppid === '1') return true;
  try { process.kill(parseInt(ppid), 0); return false; }
  catch { return true; }
}

function getMCPProcesses() {
  const seen = new Set();
  const procs = [];
  for (const pat of MCP_PATTERNS) {
    const lines = sh(`ps aux | grep -E '${pat}' | grep -v 'grep\\|watchdog'`).split('\n').filter(Boolean);
    for (const line of lines) {
      const p = parseProcessLine(line);
      if (!p || seen.has(p.pid)) continue;
      // Skip the web server itself
      if (p.pid === process.pid) continue;
      seen.add(p.pid);
      p.toolName = getMCPToolName(p.cmd);
      p.ports = getListenPorts(p.pid);
      p.owner = getOwner(p.pid);
      p.orphan = (p.owner.tool === 'orphan' || isOrphanFast(p.pid));
      p.cmdShort = p.cmd.substring(0, 120);
      procs.push(p);
    }
  }
  return procs.sort((a, b) => b.rss - a.rss);
}

function getToolProcesses() {
  const result = [];
  const globalSeen = new Set();
  for (const pat of TOOL_PATTERNS) {
    const lines = sh(`ps aux | grep -E '${pat}' | grep -v 'grep\\|watchdog'`).split('\n').filter(Boolean);
    if (lines.length === 0) continue;
    const procs = [];
    for (const line of lines) {
      const p = parseProcessLine(line);
      if (!p || globalSeen.has(p.pid)) continue;
      globalSeen.add(p.pid);
      p.ports = getListenPorts(p.pid);
      p.cmdShort = p.cmd.substring(0, 120);
      procs.push(p);
    }
    if (procs.length === 0) continue;
    const totalRSS = procs.reduce((s, p) => s + p.rss, 0);
    result.push({ name: pat, count: procs.length, totalRSS, children: procs.sort((a, b) => b.rss - a.rss) });
  }
  return result;
}

// ── Session APIs ──────────────────────────────────────────────────────────────
function getClaudeSessions(n = 5) {
  try {
    const allFiles = [];
    const projectDirs = fs.readdirSync(CLAUDE_PROJECTS, { withFileTypes: true })
      .filter(d => d.isDirectory()).map(d => path.join(CLAUDE_PROJECTS, d.name));

    for (const dir of projectDirs) {
      const files = fs.readdirSync(dir).filter(f => f.endsWith('.jsonl'));
      for (const f of files) {
        const fp = path.join(dir, f);
        const stat = fs.statSync(fp);
        const sessionId = f.replace('.jsonl', '');
        const projectDir = path.basename(dir);
        const cwd = '/' + projectDir.replace(/^-/, '').replace(/-/g, '/');
        // Extract summary
        let summary = '(no summary)';
        try {
          const lines = fs.readFileSync(fp, 'utf8').split('\n').filter(Boolean);
          for (const line of lines) {
            try {
              const d = JSON.parse(line);
              if (d.type === 'user' && d.message) {
                const msg = d.message;
                let content = typeof msg === 'object' ? (msg.content || '') : msg;
                if (Array.isArray(content)) {
                  const t = content.find(c => c && c.type === 'text');
                  content = t ? t.text : '';
                }
                if (content && typeof content === 'string') {
                  summary = content.trim().split('\n')[0].substring(0, 60);
                  break;
                }
              }
            } catch {}
          }
        } catch {}
        allFiles.push({ sessionId, cwd, ts: stat.mtimeMs / 1000, summary, size: stat.size, tool: 'claude' });
      }
    }
    return allFiles.sort((a, b) => b.ts - a.ts).slice(0, n);
  } catch { return []; }
}

function getCodexSessions(n = 5) {
  try {
    const sessions = {};
    const lines = fs.readFileSync(CODEX_HISTORY, 'utf8').split('\n').filter(Boolean);
    for (const line of lines) {
      try {
        const d = JSON.parse(line);
        const sid = d.session_id;
        if (!sid) continue;
        const ts = d.ts || 0;
        if (!sessions[sid] || ts > sessions[sid].ts) {
          sessions[sid] = { sessionId: sid, ts, cwd: d.cwd || '~', summary: sessions[sid]?.summary || '(no summary)', tool: 'codex' };
        }
        if (sessions[sid].summary === '(no summary)' && d.role === 'user') {
          const content = d.content;
          let text = '';
          if (Array.isArray(content)) {
            const t = content.find(c => c && c.type === 'input_text');
            text = t ? t.text : '';
          } else if (typeof content === 'string') {
            text = content;
          }
          if (text) sessions[sid].summary = text.split('\n')[0].substring(0, 60);
        }
      } catch {}
    }
    return Object.values(sessions).sort((a, b) => b.ts - a.ts).slice(0, n);
  } catch { return []; }
}

// Export session context to ~/Downloads/
function exportSession(tool, sessionId) {
  const dst = path.join(os.homedir(), 'Downloads', `ai-session-${tool}-${sessionId.substring(0, 8)}-${Date.now()}`);
  fs.mkdirSync(dst, { recursive: true });
  try {
    if (tool === 'claude') {
      // Find the session file
      const projectDirs = fs.readdirSync(CLAUDE_PROJECTS, { withFileTypes: true })
        .filter(d => d.isDirectory()).map(d => path.join(CLAUDE_PROJECTS, d.name));
      for (const dir of projectDirs) {
        const fp = path.join(dir, `${sessionId}.jsonl`);
        if (fs.existsSync(fp)) {
          fs.copyFileSync(fp, path.join(dst, `session.jsonl`));
          // Also copy memory if exists
          const memDir = path.join(dir, 'memory');
          if (fs.existsSync(memDir)) sh(`cp -r '${memDir}' '${dst}/memory'`);
          return { ok: true, path: dst, resumeCmd: `claude --resume ${sessionId}` };
        }
      }
    } else if (tool === 'codex') {
      // Export relevant lines from history.jsonl
      const lines = fs.readFileSync(CODEX_HISTORY, 'utf8').split('\n')
        .filter(l => l.includes(sessionId));
      fs.writeFileSync(path.join(dst, 'history.jsonl'), lines.join('\n'));
      // Copy sessions dir if exists
      const sessDir = path.join(ORBA_DIR.replace('.orba', '.codex'), 'sessions');
      if (fs.existsSync(sessDir)) sh(`cp -r '${sessDir}' '${dst}/sessions'`);
      return { ok: true, path: dst, resumeCmd: `codex --session ${sessionId}` };
    }
    return { ok: false, error: 'Session file not found' };
  } catch (e) {
    return { ok: false, error: e.message };
  }
}

function killProcess(pid) {
  const cmd = sh(`ps -o command= -p ${pid} 2>/dev/null`).trim();
  if (!cmd) return { ok: true, pid, note: 'already dead' };
  const PROTECTED = [/\bclaude\b(?!.*server)/, /\bcodex\b(?!.*server)/, /Cursor$/, /OrbaDesktop/, /Warp\.app/, /dangerously/];
  if (PROTECTED.some(re => re.test(cmd))) {
    return { ok: false, error: 'Protected: ' + cmd.substring(0, 40) };
  }
  try {
    process.kill(pid, 'SIGTERM');
    // Follow up with SIGKILL after 2s (fire and forget)
    setTimeout(() => { try { process.kill(pid, 'SIGKILL'); } catch {} }, 2000);
    return { ok: true, pid };
  } catch (e) {
    // ESRCH means process already dead = success
    if (e.code === 'ESRCH') return { ok: true, pid, note: 'already exited' };
    return { ok: false, error: e.message };
  }
}

function killAllOrphans() {
  const procs = getMCPProcesses().filter(p => p.orphan);
  let killed = 0;
  for (const p of procs) {
    const r = killProcess(p.pid);
    if (r.ok) killed++;
  }
  return { ok: true, killed };
}

// Clean down to target memory watermark (default: 60%)
function cleanToWatermark(targetPct = 60) {
  const procs = getMCPProcesses().sort((a, b) => b.rss - a.rss); // biggest first
  let killed = 0;
  let freedMB = 0;
  for (const p of procs) {
    const mem = getMemInfo();
    if (mem.pct <= targetPct) break; // reached target
    const r = killProcess(p.pid);
    if (r.ok) {
      killed++;
      freedMB += p.rss;
    }
  }
  const after = getMemInfo();
  return { ok: true, killed, freedMB, memBefore: after.pct + killed, memAfter: after.pct, targetPct };
}

// ── Knowledge APIs ───────────────────────────────────────────────────────────
const SMART_HOME = path.join(os.homedir(), 'billion-smart');

function getBestPractices() {
  const dir = path.join(SMART_HOME, 'best-practices');
  try {
    return fs.readdirSync(dir).filter(f => f.endsWith('.md')).map(f => {
      const content = fs.readFileSync(path.join(dir, f), 'utf8');
      return { name: f.replace('.md', ''), content };
    });
  } catch { return []; }
}

// Rebuild BRAIN.md for each project with user messages (high priority) + summaries
function rebuildBrains() {
  const projects = {};
  // 1. Scan recent Claude sessions, extract USER messages grouped by project
  try {
    const projectDirs = fs.readdirSync(CLAUDE_PROJECTS, { withFileTypes: true })
      .filter(d => d.isDirectory()).map(d => path.join(CLAUDE_PROJECTS, d.name));
    for (const dir of projectDirs) {
      const projectDir = path.basename(dir);
      const cwd = '/' + projectDir.replace(/^-/, '').replace(/-/g, '/');
      // Map cwd to billion-smart folder
      let smartFolder = '_global';
      if (cwd.includes('/devin')) smartFolder = 'devin';
      else if (cwd.includes('/orba-desktop')) smartFolder = 'orba-desktop';
      else if (cwd.includes('/orba-memorybank-cli')) smartFolder = 'orba-memorybank-cli';
      else if (cwd.includes('/ai-watchdog')) smartFolder = 'ai-watchdog';
      if (!projects[smartFolder]) projects[smartFolder] = { userMsgs: [], summaries: [] };

      // Read latest session file
      const files = fs.readdirSync(dir).filter(f => f.endsWith('.jsonl'));
      const sorted = files.map(f => ({ f, mtime: fs.statSync(path.join(dir, f)).mtimeMs }))
        .sort((a, b) => b.mtime - a.mtime).slice(0, 3);
      for (const { f } of sorted) {
        try {
          const lines = fs.readFileSync(path.join(dir, f), 'utf8').split('\n').filter(Boolean).slice(-40);
          for (const line of lines) {
            try {
              const d = JSON.parse(line);
              if (d.type !== 'user') continue;
              const msg = d.message || {};
              let content = typeof msg === 'object' ? (msg.content || '') : String(msg);
              if (Array.isArray(content)) {
                const t = content.find(c => c && c.type === 'text');
                content = t ? t.text : '';
              }
              if (content && typeof content === 'string') {
                const text = content.trim().split('\n')[0].substring(0, 150);
                if (text.length > 10) projects[smartFolder].userMsgs.push(text);
              }
            } catch {}
          }
        } catch {}
      }
    }
  } catch {}

  // 2. Collect existing summaries
  try {
    for (const proj of Object.keys(projects)) {
      const sumDir = path.join(SMART_HOME, proj, 'summaries');
      if (!fs.existsSync(sumDir)) continue;
      const files = fs.readdirSync(sumDir).filter(f => f.endsWith('.md'))
        .sort().reverse().slice(0, 3);
      for (const f of files) {
        try {
          const content = fs.readFileSync(path.join(sumDir, f), 'utf8');
          projects[proj].summaries.push(content.substring(0, 500));
        } catch {}
      }
    }
  } catch {}

  // 3. Write brain/ sub-files — user messages to user-focus.md, summaries to learnings.md
  let updated = 0;
  const ts = new Date().toISOString().replace('T', ' ').substring(0, 19);
  for (const [proj, data] of Object.entries(projects)) {
    const brainDir = path.join(SMART_HOME, proj, 'brain');
    if (!fs.existsSync(brainDir)) { try { fs.mkdirSync(brainDir, { recursive: true }); } catch {} }

    // user-focus.md — highest weight: user's own messages
    if (data.userMsgs.length > 0) {
      const userContent = '# 我最近在关注\n> 权重最高 — 这些是我本人发的消息，代表当前关注点\n> Updated: ' + ts + '\n\n' +
        [...new Set(data.userMsgs)].slice(0, 15).map(m => '- ' + m).join('\n') + '\n';
      fs.writeFileSync(path.join(brainDir, 'user-focus.md'), userContent);
    }

    // learnings.md — accumulated from summaries
    if (data.summaries.length > 0) {
      const learnContent = '# 近期会话总结\n> AI 生成的摘要，帮助延续上下文\n> Updated: ' + ts + '\n\n' +
        data.summaries.join('\n\n---\n\n').substring(0, 2000) + '\n';
      fs.writeFileSync(path.join(brainDir, 'learnings.md'), learnContent);
    }
    updated++;
  }
  return { ok: true, updated };
}

function getBrains() {
  try {
    const projects = fs.readdirSync(SMART_HOME, { withFileTypes: true })
      .filter(d => d.isDirectory() && d.name !== '.git' && d.name !== 'best-practices');
    return projects.map(d => {
      const brainDir = path.join(SMART_HOME, d.name, 'brain');
      if (!fs.existsSync(brainDir)) return null;
      // Read all .md files in brain/ and concatenate
      const files = fs.readdirSync(brainDir).filter(f => f.endsWith('.md')).sort();
      const parts = files.map(f => {
        const content = fs.readFileSync(path.join(brainDir, f), 'utf8').trim();
        return { file: f, content, size: content.length };
      }).filter(p => p.size > 0);
      const fullContent = parts.map(p => p.content).join('\n\n---\n\n');
      return { project: d.name, files: parts, content: fullContent, size: fullContent.length };
    }).filter(Boolean);
  } catch { return []; }
}

function getRecentSummaries(n = 10) {
  const results = [];
  try {
    const projects = fs.readdirSync(SMART_HOME, { withFileTypes: true })
      .filter(d => d.isDirectory()).map(d => d.name);
    for (const proj of projects) {
      const sumDir = path.join(SMART_HOME, proj, 'summaries');
      if (!fs.existsSync(sumDir)) continue;
      const files = fs.readdirSync(sumDir).filter(f => f.endsWith('.md'));
      for (const f of files) {
        const fp = path.join(sumDir, f);
        const stat = fs.statSync(fp);
        results.push({ project: proj, file: f, ts: stat.mtimeMs / 1000, content: fs.readFileSync(fp, 'utf8') });
      }
    }
  } catch {}
  return results.sort((a, b) => b.ts - a.ts).slice(0, n);
}

// ── HTTP Server ───────────────────────────────────────────────────────────────
const PUBLIC = path.join(__dirname, 'public');

const ROUTES = {
  'GET /api/status': () => {
    const mem = getMemInfo();
    const daemon = getDaemonStatus();
    const state = readJSON(STATE_FILE) || {};
    return { mem, daemon, state, ts: Date.now() };
  },
  'GET /api/processes': () => ({
    mcp: getMCPProcesses(),
    tools: getToolProcesses()
  }),
  'GET /api/sessions': () => ({
    claude: getClaudeSessions(5),
    codex: getCodexSessions(5)
  }),
  'GET /api/logs': () => {
    try {
      const lines = fs.readFileSync(LOG_FILE, 'utf8').split('\n').filter(Boolean).slice(-30);
      return { lines };
    } catch { return { lines: [] }; }
  },
  'GET /api/knowledge': () => ({
    bestPractices: getBestPractices(),
    summaries: getRecentSummaries(10),
    brains: getBrains()
  }),
};

const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://localhost`);
  const method = req.method;
  const pathname = url.pathname;

  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

  if (method === 'OPTIONS') { res.writeHead(204); res.end(); return; }

  // Static files
  if (!pathname.startsWith('/api/')) {
    const file = pathname === '/' ? '/index.html' : pathname;
    const fp = path.join(PUBLIC, file);
    if (fs.existsSync(fp) && fs.statSync(fp).isFile()) {
      const ext = path.extname(fp);
      const mime = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json' }[ext] || 'text/plain';
      res.setHeader('Content-Type', mime);
      res.writeHead(200);
      res.end(fs.readFileSync(fp));
    } else {
      res.writeHead(302, { Location: '/' }); res.end();
    }
    return;
  }

  // API routes
  const routeKey = `${method} ${pathname}`;
  if (ROUTES[routeKey]) {
    try {
      const data = ROUTES[routeKey]();
      res.setHeader('Content-Type', 'application/json');
      res.writeHead(200);
      res.end(JSON.stringify(data));
    } catch (e) {
      res.writeHead(500);
      res.end(JSON.stringify({ error: e.message }));
    }
    return;
  }

  // POST /api/kill/:pid
  if (method === 'POST' && pathname.startsWith('/api/kill/')) {
    const pid = parseInt(pathname.split('/').pop());
    if (isNaN(pid)) { res.writeHead(400); res.end(JSON.stringify({ error: 'Invalid PID' })); return; }
    const r = pid === 0 ? killAllOrphans() : killProcess(pid);
    res.setHeader('Content-Type', 'application/json');
    res.writeHead(r.ok ? 200 : 403);
    res.end(JSON.stringify(r));
    return;
  }

  // POST /api/clean-to-watermark
  if (method === 'POST' && pathname === '/api/clean-to-watermark') {
    const r = cleanToWatermark(60);
    res.setHeader('Content-Type', 'application/json');
    res.writeHead(200);
    res.end(JSON.stringify(r));
    return;
  }

  // POST /api/refresh-brains
  if (method === 'POST' && pathname === '/api/refresh-brains') {
    const r = rebuildBrains();
    res.setHeader('Content-Type', 'application/json');
    res.writeHead(200);
    res.end(JSON.stringify(r));
    return;
  }

  // GET /api/export/:tool/:sid
  if (method === 'GET' && pathname.startsWith('/api/export/')) {
    const parts = pathname.split('/');
    const tool = parts[3];
    const sid = parts[4];
    const r = exportSession(tool, sid);
    res.setHeader('Content-Type', 'application/json');
    res.writeHead(r.ok ? 200 : 404);
    res.end(JSON.stringify(r));
    return;
  }

  res.writeHead(404); res.end(JSON.stringify({ error: 'Not found' }));
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`AI Watchdog Web UI: http://localhost:${PORT}`);
});

process.on('SIGTERM', () => { server.close(); process.exit(0); });
process.on('SIGINT',  () => { server.close(); process.exit(0); });
