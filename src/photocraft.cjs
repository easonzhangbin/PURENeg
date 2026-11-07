'use strict';

// PhotoCraft's authenticated loopback JSON-lines control protocol. No edit is
// automatically retried: a lost reply does not prove that an edit was not applied.
const net = require('node:net');
const fs = require('node:fs/promises');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawn } = require('node:child_process');

class BridgeError extends Error {
  constructor(message, code = 'PHOTOCRAFT_ERROR', mayHaveApplied = false) {
    super(message);
    this.name = 'BridgeError';
    this.code = code;
    this.mayHaveApplied = mayHaveApplied;
  }
}

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const canonical = value => JSON.stringify(value);
const layerIds = layers => layers.flatMap(layer => [layer.id, ...layerIds(layer.children || [])]);

function snapshotOf(state) {
  const index = state.session?.active;
  const doc = state.document;
  if (!Number.isInteger(index) || index < 0 || !doc) {
    throw new BridgeError('请先在本工具启动的 PhotoCraft 中打开照片。', 'NO_DOCUMENT');
  }
  return {
    index, revision: doc.revision, name: doc.name, path: doc.path || null,
    width: doc.width, height: doc.height, depth: doc.depth, mode: doc.mode,
    layers: structuredClone(doc.layers || []), activeLayer: doc.activeLayer,
    hasSelection: !!doc.hasSelection, quickMask: !!doc.quickMask,
    selectedLayers: [...(doc.selectedLayers || [])],
  };
}

function fingerprint(snapshot) {
  return canonical({
    index: snapshot.index, revision: snapshot.revision,
    name: snapshot.name, path: snapshot.path, width: snapshot.width,
    height: snapshot.height, depth: snapshot.depth, mode: snapshot.mode,
    layers: layerIds(snapshot.layers), hasSelection: snapshot.hasSelection,
    quickMask: snapshot.quickMask,
  });
}

async function confinedPath(root, filename, mustExist = true) {
  const canonicalRoot = await fs.realpath(root);
  const resolved = path.resolve(filename);
  const checked = mustExist ? await fs.realpath(resolved)
    : path.join(await fs.realpath(path.dirname(resolved)), path.basename(resolved));
  const relative = path.relative(canonicalRoot, checked);
  if (!relative || relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    throw new BridgeError('交换文件必须位于本工具的工作目录中。', 'OUTSIDE_WORKSPACE');
  }
  return checked;
}

class PhotoCraftClient {
  #token;
  constructor({ host = '127.0.0.1', port, token, tokenFile, workDir,
    timeoutMs = 55000, maxReplyBytes = 6 * 1024 * 1024 } = {}) {
    if (host !== '127.0.0.1' && host !== '::1' && host !== 'localhost') {
      throw new BridgeError('PhotoCraft 控制连接仅允许本机回环地址。', 'INVALID_HOST');
    }
    if (!Number.isInteger(port) || port < 1 || port > 65535) throw new BridgeError('无效的控制端口。', 'INVALID_PORT');
    if (token !== undefined && !/^[0-9a-f]{64}$/i.test(token)) throw new BridgeError('无效的控制凭证。', 'INVALID_TOKEN');
    if (!token && !tokenFile) throw new BridgeError('缺少控制凭证文件。', 'INVALID_TOKEN');
    this.host = host === 'localhost' ? '127.0.0.1' : host;
    this.port = port;
    this.tokenFile = tokenFile;
    this.workDir = workDir;
    this.timeoutMs = timeoutMs;
    this.maxReplyBytes = maxReplyBytes;
    this.#token = token;
  }

  static async connect(options) {
    const client = new PhotoCraftClient(options);
    await client.status();
    return client;
  }

  async request(method, params = {}) {
    if (typeof method !== 'string' || !method || !params || typeof params !== 'object' || Array.isArray(params)) {
      throw new BridgeError('无效的控制请求。', 'INVALID_REQUEST');
    }
    const token = this.#token || (await fs.readFile(this.tokenFile, 'utf8')).trim();
    if (!/^[0-9a-f]{64}$/i.test(token)) throw new BridgeError('控制凭证文件无效。', 'INVALID_TOKEN');
    const requestId = crypto.randomUUID();
    const authId = `auth-${requestId}`;
    return new Promise((resolve, reject) => {
      const socket = net.createConnection({ host: this.host, port: this.port });
      let buffer = '', bytes = 0, authenticated = false, sent = false, settled = false;
      const finish = (error, result) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        socket.destroy();
        if (error) reject(error); else resolve(result);
      };
      const timer = setTimeout(() => finish(new BridgeError(
        sent ? 'PhotoCraft 响应超时；操作可能已执行，请检查文档后再试。' : '无法连接 PhotoCraft 控制会话。',
        'TIMEOUT', sent)), this.timeoutMs);
      socket.setEncoding('utf8');
      socket.on('connect', () => socket.write(JSON.stringify({ id: authId, method: 'auth', params: { token } }) + '\n'));
      socket.on('data', chunk => {
        bytes += Buffer.byteLength(chunk);
        if (bytes > this.maxReplyBytes) return finish(new BridgeError('PhotoCraft 响应超过大小限制。', 'REPLY_TOO_LARGE', sent));
        buffer += chunk;
        for (let end; (end = buffer.indexOf('\n')) >= 0;) {
          const line = buffer.slice(0, end); buffer = buffer.slice(end + 1);
          if (!line.trim()) continue;
          let reply;
          try { reply = JSON.parse(line); }
          catch { return finish(new BridgeError('PhotoCraft 返回了无效的 JSON。', 'INVALID_REPLY', sent)); }
          if (!authenticated && reply.id === authId) {
            if (!reply.ok) return finish(new BridgeError('PhotoCraft 控制认证失败。', 'AUTH_FAILED'));
            authenticated = true;
            sent = true;
            socket.write(JSON.stringify({ id: requestId, method, params }) + '\n');
          } else if (authenticated && reply.id === requestId) {
            if (!reply.ok) return finish(new BridgeError(String(reply.error || 'PhotoCraft 拒绝了操作。'), 'COMMAND_FAILED', /^timeout/.test(String(reply.error))));
            return finish(null, reply.result);
          }
        }
      });
      socket.on('error', () => finish(new BridgeError(sent ? 'PhotoCraft 连接中断；操作可能已执行。' : 'PhotoCraft 未连接，请先启动控制会话。', 'CONNECTION_FAILED', sent)));
      socket.on('close', () => { if (!settled) finish(new BridgeError('PhotoCraft 提前关闭了连接。', 'CONNECTION_CLOSED', sent)); });
    });
  }

  execute(command, params = {}) { return this.request('engine.execute', { command, params }); }
  async status() {
    const state = await this.request('ui.inspect');
    return { connected: true, session: state.session, document: state.document, jobs: state.jobs, dialogs: state.dialogs };
  }
  async getActiveDocument() { return snapshotOf(await this.status()); }
  async assertUnchanged(snapshot) {
    const current = await this.getActiveDocument();
    if (fingerprint(current) !== fingerprint(snapshot)) {
      throw new BridgeError('照片在处理期间已切换或修改。修复文件已保留，请重新读取当前照片。', 'STALE_DOCUMENT');
    }
    return current;
  }

  async prepareExport(filename) {
    if (!this.workDir) throw new BridgeError('未配置交换工作目录。', 'NO_WORKSPACE');
    const target = await confinedPath(this.workDir, filename, false);
    if (!/\.tiff?$/i.test(target)) throw new BridgeError('交换图像必须使用 TIFF。', 'INVALID_FORMAT');
    try { await fs.access(target); throw new BridgeError('导出路径已存在，请使用新的任务目录。', 'FILE_EXISTS'); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
    const snapshot = await this.getActiveDocument();
    if (![8, 16].includes(snapshot.depth) || !/^(rgb|gray|grayscale)$/i.test(snapshot.mode)) {
      throw new BridgeError('此版本支持 RGB 或灰度的 8／16 位照片，请先转换照片模式。', 'UNSUPPORTED_DOCUMENT');
    }
    if (snapshot.hasSelection || snapshot.quickMask) throw new BridgeError('请先取消选区并退出快速蒙版，再处理整张照片。', 'ACTIVE_SELECTION');
    const result = await this.request('app.save', { path: target, tiffLayers: false });
    await this.assertUnchanged(snapshot);
    return { snapshot, path: target, warnings: result?.warnings || [] };
  }
  exportComposite(filename) { return this.prepareExport(filename); }

  async importResult({ snapshot, cleanedPath, maskPath, name = 'PURE Neg · 修复', changed = true, manualEditable = false } = {}) {
    if (!snapshot) throw new BridgeError('缺少原始照片快照。', 'NO_SNAPSHOT');
    await this.assertUnchanged(snapshot);
    if (!changed) return { document: snapshot.index, layer: null, unchanged: true, warnings: [] };
    const clean = await confinedPath(this.workDir, cleanedPath);
    const mask = await confinedPath(this.workDir, maskPath);
    const warnings = [], temporary = [];
    let newLayer = null, succeeded = false;
    try {
      // Open both external images before editing the original. A failed decode
      // therefore leaves its layers untouched.
      for (const [filename, kind] of [[clean, 'clean'], [mask, 'mask']]) {
        const opened = await this.request('app.open', { path: filename });
        warnings.push(...(opened?.warnings || []));
        const doc = await this.getActiveDocument();
        // Register immediately: validation failures still need to close this tab.
        temporary.push({ kind, snapshot: doc });
        if (doc.width !== snapshot.width || doc.height !== snapshot.height) throw new BridgeError('修复图或蒙版尺寸与原照片不一致。', 'SIZE_MISMATCH');
        if (kind === 'clean' && (doc.depth !== snapshot.depth || doc.mode.toLowerCase() !== snapshot.mode.toLowerCase())) {
          throw new BridgeError('修复图的位深或颜色模式与原照片不一致。', 'FORMAT_MISMATCH');
        }
        if (kind === 'mask' && !/^(gray|grayscale)$/i.test(doc.mode)) {
          throw new BridgeError('灰尘蒙版必须是灰度图。', 'FORMAT_MISMATCH');
        }
      }
      const repaired = temporary.find(t => t.kind === 'clean').snapshot;
      const maskDoc = temporary.find(t => t.kind === 'mask').snapshot;
      // Assemble and verify the editable mask in the scratch document first.
      // The original receives only an already-masked layer through the explicit
      // source/destination copy command, never active-document Apply Image.
      await this.execute('document.activate', { document: repaired.index });
      const guardScratch = async () => {
        const current = await this.getActiveDocument();
        if (current.index !== repaired.index || current.activeLayer !== repaired.activeLayer
          || current.path !== repaired.path || current.name !== repaired.name || current.hasSelection || current.quickMask
          || canonical(layerIds(current.layers)) !== canonical(layerIds(repaired.layers))) {
          throw new BridgeError('临时修复文档已切换，已停止导回；原照片保持原样。', 'STALE_DOCUMENT');
        }
      };
      await guardScratch();
      await this.execute('layer.hideLayers', { layer: repaired.activeLayer });
      await guardScratch();
      // A full, already-composited repaired image can use a white recovery mask:
      // black paint restores the original beneath, while the image thumbnail
      // remains available for Spot Healing anywhere, including missed dust.
      // Legacy callers still use the actual detection mask for sparse repairs.
      await this.execute(manualEditable ? 'layer.layerMask.revealAll' : 'layer.layerMask.hideAll', { layer: repaired.activeLayer });
      await guardScratch();
      if (!manualEditable) await this.execute('image.applyImage', {
        source: { document: maskDoc.index, layer: 'merged', channel: 'composite' },
        target: 'mask', blending: 'normal', opacity: 100,
      });
      await guardScratch();
      const prepared = await this.getActiveDocument();
      if (!prepared.layers.find(layer => layer.id === repaired.activeLayer)?.hasMask) {
        throw new BridgeError('PhotoCraft 未能建立临时修复蒙版，原照片保持原样。', 'IMPORT_VERIFICATION_FAILED');
      }
      const sourceCheck = await this.execute('document.inspect', { document: snapshot.index });
      if (fingerprint(snapshotOf({ session: { active: snapshot.index }, document: sourceCheck })) !== fingerprint(snapshot)) {
        throw new BridgeError('原照片在导回前已修改，修复文件已保留。', 'STALE_DOCUMENT');
      }
      const copied = await this.execute('layer.copyToDocument', {
        source: repaired.index, document: snapshot.index, layers: [repaired.activeLayer], offset: [0, 0], name,
      });
      newLayer = copied.layers?.[0];
      if (!Number.isInteger(newLayer)) throw new BridgeError('PhotoCraft 没有返回新图层。', 'INVALID_REPLY', true);
      const guardTarget = async () => {
        const current = await this.getActiveDocument();
        if (current.index !== snapshot.index || current.activeLayer !== newLayer || current.name !== snapshot.name
          || current.path !== snapshot.path || current.width !== snapshot.width || current.height !== snapshot.height
          || current.hasSelection || current.quickMask
          || canonical(layerIds(current.layers).filter(id => id !== newLayer)) !== canonical(layerIds(snapshot.layers))) {
          throw new BridgeError('导回期间目标图层已切换，已停止导回；修复文件已保留。', 'STALE_DOCUMENT');
        }
      };
      const top = snapshot.layers[0]?.id;
      await guardTarget();
      if (top !== undefined) await this.execute('layer.moveTo', { layer: newLayer, target: top, position: 'above' });
      await guardTarget();
      await this.execute('layer.showLayers', { layer: newLayer });
      const verified = await this.getActiveDocument();
      const layer = verified.layers.find(l => l.id === newLayer);
      if (!layer?.hasMask || !layer.visible) throw new BridgeError('PhotoCraft 未保留可编辑修复蒙版。', 'IMPORT_VERIFICATION_FAILED', true);
      succeeded = true;
      return { document: snapshot.index, layer: newLayer, warnings };
    } finally {
      if (!succeeded && newLayer !== null) {
        // Delete only the layer this operation created, never rewind unrelated
        // user history. If identity is uncertain, leave the hidden layer alone.
        try {
          await this.execute('document.activate', { document: snapshot.index });
          const doc = await this.getActiveDocument();
          const ids = layerIds(doc.layers).filter(id => id !== newLayer);
          if (canonical(ids) === canonical(layerIds(snapshot.layers)) && doc.name === snapshot.name && doc.width === snapshot.width && doc.height === snapshot.height) {
            await this.execute('layer.delete', { layer: newLayer });
          }
        } catch { /* original work remains authoritative; keep external files */ }
      }
      // Close only scratch documents we opened, in descending index order so
      // closing one does not shift the remaining indices.
      for (const temp of [...temporary].sort((a, b) => b.snapshot.index - a.snapshot.index)) {
        try {
          const doc = await this.execute('document.inspect', { document: temp.snapshot.index });
          if (doc.path === temp.snapshot.path && doc.name === temp.snapshot.name && canonical(layerIds(doc.layers || [])) === canonical(layerIds(temp.snapshot.layers))) {
            await this.execute('file.close', { document: temp.snapshot.index, save: 'discard' });
          }
        } catch { /* an already-closed scratch tab needs no cleanup */ }
      }
      try { await this.execute('document.activate', { document: snapshot.index }); } catch { /* source may have been closed by the user */ }
    }
  }
}

function processExists(pid) {
  try { process.kill(pid, 0); return true; } catch { return false; }
}
async function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const port = server.address().port;
      server.close(error => error ? reject(error) : resolve(port));
    });
  });
}

async function launchPhotoCraft({ workDir, appPath = '/Applications/PhotoCraft.app/Contents/MacOS/PhotoCraft', startupTimeoutMs = 20000, safeGpu = false } = {}) {
  if (!workDir) throw new BridgeError('缺少工作目录。', 'NO_WORKSPACE');
  await fs.mkdir(workDir, { recursive: true, mode: 0o700 });
  const root = await fs.realpath(workDir);
  const executable = appPath.endsWith('.app') ? path.join(appPath, 'Contents', 'MacOS', 'PhotoCraft') : appPath;
  await fs.access(executable);
  const port = await freePort();
  const tokenFile = path.join(root, `control-${crypto.randomUUID()}.token`);
  await fs.writeFile(tokenFile, crypto.randomBytes(32).toString('hex'), { flag: 'wx', mode: 0o600 });
  const configDir = path.join(root, 'photocraft-settings');
  await fs.mkdir(configDir, { recursive: true, mode: 0o700 });
  const log = await fs.open(path.join(root, 'photocraft.log'), 'a', 0o600);
  let child;
  try {
    const args = ['--new-instance', '--control', String(port), '--control-token-file', tokenFile,
      '--automation-read-root', root, '--automation-write-root', root];
    if (safeGpu) args.push('--safe-gpu');
    child = spawn(executable, args, { detached: true, stdio: ['ignore', log.fd, log.fd],
      env: { ...process.env, PHOTOCRAFT_CONFIG_DIR: configDir, PHOTOCRAFT_CONTROL_TOKEN: '', PHOTOCRAFT_CONTROL_TOKEN_FILE: '' } });
    child.unref();
  } finally { await log.close(); }
  let launchError = null;
  child.on('error', error => { launchError = error; });
  const session = { version: 1, pid: child.pid, port, tokenFile, workDir: root, startedAt: new Date().toISOString() };
  const client = new PhotoCraftClient({ ...session, timeoutMs: 1500 });
  const deadline = Date.now() + startupTimeoutMs;
  while (Date.now() < deadline) {
    if (launchError || !processExists(child.pid)) throw new BridgeError('PhotoCraft 启动失败，请查看工作目录中的 photocraft.log。', 'LAUNCH_FAILED');
    try {
      await client.status();
      client.timeoutMs = 55000;
      const sessionPath = path.join(root, 'session.json');
      const temporary = sessionPath + '.' + crypto.randomUUID();
      await fs.writeFile(temporary, JSON.stringify(session, null, 2), { flag: 'wx', mode: 0o600 });
      await fs.rename(temporary, sessionPath);
      return { client, session, reused: false };
    } catch { await sleep(250); }
  }
  throw new BridgeError('PhotoCraft 已启动但未及时响应，请稍后连接。', 'LAUNCH_TIMEOUT');
}

async function ensureSession({ workDir, fallbackWorkDir, launch = false, ...launchOptions } = {}) {
  if (!workDir) throw new BridgeError('缺少工作目录。', 'NO_WORKSPACE');
  const root = path.resolve(workDir);
  const roots = fallbackWorkDir ? [root, path.resolve(fallbackWorkDir)] : [root];
  for (const candidate of roots) {
    let session;
    try { session = JSON.parse(await fs.readFile(path.join(candidate, 'session.json'), 'utf8')); }
    catch (error) { if (error.code !== 'ENOENT') throw new BridgeError('本地会话文件损坏，请重新启动控制会话。', 'INVALID_SESSION'); }
    if (!session || (candidate !== root && !processExists(session.pid))) continue;
    const tokenPath = await confinedPath(candidate, session.tokenFile);
    const client = new PhotoCraftClient({ port: session.port, tokenFile: tokenPath, workDir: candidate, timeoutMs: 2500 });
    try { await client.status(); client.timeoutMs = 55000; return { client, session, reused: true }; }
    catch (error) {
      if (!launch || processExists(session.pid)) throw new BridgeError('现有 PhotoCraft 会话暂时无法响应，请检查它的窗口后重试。', 'SESSION_UNAVAILABLE', error.mayHaveApplied);
    }
  }
  if (!launch) throw new BridgeError('请先点击“启动 / 连接 PhotoCraft”，再在打开的窗口中载入照片。', 'NO_SESSION');
  return launchPhotoCraft({ workDir: root, ...launchOptions });
}

module.exports = { PhotoCraftClient, BridgeError, ensureSession, launchPhotoCraft, fingerprint, confinedPath };
