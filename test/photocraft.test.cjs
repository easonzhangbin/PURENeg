'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const net = require('node:net');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const { PhotoCraftClient, fingerprint, confinedPath, ensureSession } = require('../src/photocraft.cjs');

const token = 'a'.repeat(64);
async function serverFor(t, handler) {
  const sockets = new Set();
  const server = net.createServer(socket => {
    sockets.add(socket); socket.on('close', () => sockets.delete(socket));
    let buffer = '';
    socket.setEncoding('utf8');
    socket.on('data', chunk => {
      buffer += chunk;
      for (let end; (end = buffer.indexOf('\n')) >= 0;) {
        const frame = JSON.parse(buffer.slice(0, end)); buffer = buffer.slice(end + 1);
        handler(socket, frame);
      }
    });
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => {
    for (const socket of sockets) socket.destroy();
    await new Promise(resolve => server.close(resolve));
  });
  return new PhotoCraftClient({ port: server.address().port, token, timeoutMs: 2000 });
}
const reply = (socket, frame, result) => socket.write(JSON.stringify({ id: frame.id, ok: true, result }) + '\n');

test('authenticates, handles fragmented replies and ignores unrelated reply ids', async t => {
  const seen = [];
  const client = await serverFor(t, (socket, frame) => {
    seen.push(frame.method);
    if (frame.method === 'auth') { assert.equal(frame.params.token, token); return reply(socket, frame, null); }
    socket.write(JSON.stringify({ id: 'unrelated', ok: true, result: 'ignored' }) + '\n');
    const line = JSON.stringify({ id: frame.id, ok: true, result: { document: '胶片' } }) + '\n';
    socket.write(line.slice(0, 18));
    setImmediate(() => socket.write(line.slice(18)));
  });
  assert.deepEqual(await client.request('ui.inspect'), { document: '胶片' });
  assert.deepEqual(seen, ['auth', 'ui.inspect']);
  assert.ok(!JSON.stringify(client).includes(token));
});

test('can reconnect to a live legacy PhotoCraft session using its original authorized workspace', async t => {
  const root = await fs.realpath(await fs.mkdtemp(path.join(os.tmpdir(), 'pureneg-session-')));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const workDir = path.join(root, 'PURENeg');
  const fallbackWorkDir = path.join(root, 'PhotoCraft Film Dust');
  await fs.mkdir(fallbackWorkDir);
  const tokenFile = path.join(fallbackWorkDir, 'control.token');
  await fs.writeFile(tokenFile, token);
  const server = await serverFor(t, (socket, frame) => {
    if (frame.method === 'auth') assert.equal(frame.params.token, token);
    reply(socket, frame, {});
  });
  const manifest = { pid: process.pid, port: server.port, tokenFile, workDir: fallbackWorkDir };
  await fs.writeFile(path.join(fallbackWorkDir, 'session.json'), JSON.stringify(manifest));
  const connected = await ensureSession({ workDir, fallbackWorkDir });
  assert.equal(connected.client.workDir, fallbackWorkDir);
  assert.equal(connected.reused, true);
  await assert.rejects(ensureSession({ workDir }), { code: 'NO_SESSION' });
});

test('does not send an edit after failed authentication', async t => {
  const seen = [];
  const client = await serverFor(t, (socket, frame) => {
    seen.push(frame.method);
    socket.write(JSON.stringify({ id: frame.id, ok: false, error: 'bad token' }) + '\n');
  });
  await assert.rejects(client.execute('layer.delete'), error => error.code === 'AUTH_FAILED' && !error.message.includes(token));
  assert.deepEqual(seen, ['auth']);
});

test('a disconnected mutation is reported as uncertain and is never resent', async t => {
  let calls = 0;
  const client = await serverFor(t, (socket, frame) => {
    if (frame.method === 'auth') return reply(socket, frame, null);
    calls++;
    socket.end();
  });
  await assert.rejects(client.execute('layer.new.layer'), error => error.mayHaveApplied === true);
  assert.equal(calls, 1);
});

test('timeouts distinguish an unsent request from a sent mutation', async t => {
  const authWait = await serverFor(t, () => {});
  authWait.timeoutMs = 30;
  await assert.rejects(authWait.request('ui.inspect'), error => error.code === 'TIMEOUT' && !error.mayHaveApplied);
  const sentWait = await serverFor(t, (socket, frame) => { if (frame.method === 'auth') reply(socket, frame, null); });
  sentWait.timeoutMs = 30;
  await assert.rejects(sentWait.execute('layer.new.layer'), error => error.code === 'TIMEOUT' && error.mayHaveApplied);
});

test('malformed and oversized responses fail closed', async t => {
  const malformed = await serverFor(t, (socket, frame) => {
    if (frame.method === 'auth') return reply(socket, frame, null);
    socket.write('not-json\n');
  });
  await assert.rejects(malformed.request('ui.inspect'), error => error.code === 'INVALID_REPLY');
  const large = await serverFor(t, (socket, frame) => reply(socket, frame, 'x'.repeat(500)));
  large.maxReplyBytes = 50;
  await assert.rejects(large.request('ui.inspect'), error => error.code === 'REPLY_TOO_LARGE');
});

test('remote hosts and invalid credentials are refused', () => {
  assert.throws(() => new PhotoCraftClient({ host: '192.168.1.2', port: 1234, token }), /回环/);
  assert.throws(() => new PhotoCraftClient({ port: 0, token }), /端口/);
  assert.throws(() => new PhotoCraftClient({ port: 1234, token: 'secret' }), /凭证/);
});

const original = () => ({ index: 0, revision: 7, name: 'scan.tiff', path: '/scan.tiff',
  width: 64, height: 32, depth: 16, mode: 'Rgb', activeLayer: 10,
  layers: [{ id: 10, name: 'Background', visible: true, hasMask: false }],
  hasSelection: false, quickMask: false, selectedLayers: [10] });

test('snapshot guard rejects edits, reordered documents and changed layer identity', async () => {
  const client = new PhotoCraftClient({ port: 1234, token });
  const expected = original();
  client.getActiveDocument = async () => ({ ...expected, revision: 8 });
  await assert.rejects(client.assertUnchanged(expected), error => error.code === 'STALE_DOCUMENT');
  assert.notEqual(fingerprint(expected), fingerprint({ ...expected, index: 1 }));
  assert.notEqual(fingerprint(expected), fingerprint({ ...expected, layers: [{ id: 11 }] }));
});

test('workspace checks reject path traversal and symlinks outside the authorized root', async t => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'photocraft-bridge-path-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const inside = path.join(root, 'ok.tif'); await fs.writeFile(inside, 'fixture');
  assert.equal(await confinedPath(root, inside), await fs.realpath(inside));
  await assert.rejects(confinedPath(root, path.join(root, '..', 'outside.tif'), false), error => error.code === 'OUTSIDE_WORKSPACE');
  const link = path.join(root, 'outside'); await fs.symlink(os.tmpdir(), link);
  await assert.rejects(confinedPath(root, path.join(link, 'x.tif'), false), error => error.code === 'OUTSIDE_WORKSPACE');
});

test('zero-change result performs no document mutations', async () => {
  const client = new PhotoCraftClient({ port: 1234, token });
  const snapshot = original();
  client.getActiveDocument = async () => snapshot;
  client.execute = () => { throw new Error('must not edit'); };
  assert.deepEqual(await client.importResult({ snapshot, changed: false }), { document: 0, layer: null, unchanged: true, warnings: [] });
});

test('export preserves original snapshot and refuses unsupported documents before saving', async t => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'photocraft-bridge-export-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const client = new PhotoCraftClient({ port: 1234, token, workDir: root });
  let snapshot = original(), saves = 0;
  client.getActiveDocument = async () => snapshot;
  client.request = async (method, params) => { assert.equal(method, 'app.save'); saves++; await fs.writeFile(params.path, 'fixture'); return { warnings: [] }; };
  const filename = path.join(root, 'source.tiff');
  assert.deepEqual((await client.prepareExport(filename)).snapshot, snapshot);
  await assert.rejects(client.prepareExport(filename), error => error.code === 'FILE_EXISTS');
  snapshot = { ...snapshot, depth: 32 };
  await assert.rejects(client.prepareExport(path.join(root, 'unsupported.tiff')), error => error.code === 'UNSUPPORTED_DOCUMENT');
  snapshot = { ...snapshot, depth: 16, hasSelection: true };
  await assert.rejects(client.prepareExport(path.join(root, 'selected.tiff')), error => error.code === 'ACTIVE_SELECTION');
  assert.equal(saves, 1);
});

async function importHarness(t, { badSize = false, failAt = '', staleAtApply = false } = {}) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'photocraft-bridge-import-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const cleanedPath = path.join(root, 'clean.tiff'), maskPath = path.join(root, 'mask.tiff');
  await fs.writeFile(cleanedPath, 'fixture'); await fs.writeFile(maskPath, 'fixture');
  const docs = [original()], calls = [];
  let active = 0;
  const client = new PhotoCraftClient({ port: 1234, token, workDir: root });
  client.status = async () => ({ session: { active, documents: docs.map((doc, index) => ({ index, name: doc.name })) }, document: docs[active] });
  client.request = async (method, params) => {
    if (method !== 'app.open') throw new Error('unexpected method ' + method);
    const gray = path.basename(params.path) === 'mask.tiff';
    const index = docs.length;
    docs.push({ ...original(), index, name: path.basename(params.path), path: await fs.realpath(params.path),
      width: !gray && badSize ? 63 : 64, mode: gray ? 'Grayscale' : 'Rgb', depth: gray ? 8 : 16,
      activeLayer: 20 + index, layers: [{ id: 20 + index, name: 'Background', visible: true, hasMask: false }] });
    active = index;
    return { warnings: [] };
  };
  client.execute = async (command, params = {}) => {
    calls.push({ command, active, params });
    if (command === failAt) throw new Error('injected ' + command + ' failure');
    const doc = docs[active];
    switch (command) {
      case 'document.inspect': return docs[params.document ?? active];
      case 'document.activate': active = params.document; return { document: active };
      case 'layer.hideLayers': doc.layers.find(l => l.id === params.layer).visible = false; return null;
      case 'layer.layerMask.hideAll':
      case 'layer.layerMask.revealAll': doc.layers.find(l => l.id === params.layer).hasMask = true; return null;
      case 'image.applyImage':
        assert.notEqual(active, 0, 'the original must never receive Apply Image');
        if (staleAtApply) docs[0].revision++;
        return null;
      case 'layer.copyToDocument': {
        const source = docs[params.source].layers.find(l => l.id === params.layers[0]);
        assert.equal(source.hasMask, true, 'mask must exist before the original is edited');
        assert.equal(source.visible, false);
        const target = docs[params.document];
        target.layers.unshift({ ...source, id: 99, name: params.name }); target.activeLayer = 99;
        target.revision++; active = params.document;
        return { document: active, layers: [99] };
      }
      case 'layer.moveTo': return null;
      case 'layer.showLayers': doc.layers.find(l => l.id === params.layer).visible = true; return null;
      case 'layer.delete': doc.layers = doc.layers.filter(l => l.id !== params.layer); doc.activeLayer = 10; doc.revision++; return null;
      case 'file.close': docs.splice(params.document, 1); active = Math.min(active, docs.length - 1); return null;
      default: throw new Error('unexpected command ' + command);
    }
  };
  const snapshot = await client.getActiveDocument();
  return { client, docs, calls, args: { snapshot, cleanedPath, maskPath } };
}

test('assembles the mask in scratch before copying one complete layer into the original', async t => {
  const h = await importHarness(t);
  const result = await h.client.importResult(h.args);
  assert.equal(result.layer, 99);
  assert.equal(h.docs.length, 1, 'scratch documents must close');
  assert.equal(h.docs[0].layers[0].id, 99);
  assert.equal(h.docs[0].layers[0].hasMask, true);
  assert.equal(h.docs[0].layers[0].visible, true);
  const apply = h.calls.findIndex(call => call.command === 'image.applyImage');
  const copy = h.calls.findIndex(call => call.command === 'layer.copyToDocument');
  assert.ok(apply >= 0 && apply < copy);
  assert.deepEqual(h.docs[0].layers.slice(1), original().layers);
});

test('a decoded scratch image of the wrong size is closed without editing the original', async t => {
  const h = await importHarness(t, { badSize: true });
  await assert.rejects(h.client.importResult(h.args), error => error.code === 'SIZE_MISMATCH');
  assert.equal(h.docs.length, 1);
  assert.deepEqual(h.docs[0], original());
  assert.ok(!h.calls.some(call => call.command === 'layer.copyToDocument'));
});

test('manual editing uses a white recovery mask so later healing is not hidden by the detection mask', async t => {
  const h = await importHarness(t);
  await h.client.importResult({ ...h.args, manualEditable: true });
  assert.equal(h.docs[0].layers[0].hasMask, true);
  assert.ok(h.calls.some(call => call.command === 'layer.layerMask.revealAll'));
  assert.ok(!h.calls.some(call => call.command === 'image.applyImage'));
  assert.deepEqual(h.docs[0].layers.slice(1), original().layers);
});

test('mask failure in scratch closes temporary documents and leaves original pixels and history alone', async t => {
  const h = await importHarness(t, { failAt: 'image.applyImage' });
  await assert.rejects(h.client.importResult(h.args), /injected/);
  assert.equal(h.docs.length, 1);
  assert.deepEqual(h.docs[0], original());
});

test('a source edit during scratch preparation prevents the final copy', async t => {
  const h = await importHarness(t, { staleAtApply: true });
  await assert.rejects(h.client.importResult(h.args), error => error.code === 'STALE_DOCUMENT');
  assert.equal(h.docs.length, 1);
  assert.equal(h.docs[0].revision, 8, 'the intervening user edit is preserved');
  assert.deepEqual(h.docs[0].layers, original().layers);
  assert.ok(!h.calls.some(call => call.command === 'layer.copyToDocument'));
});

test('post-copy failure removes only the hidden layer created by this operation', async t => {
  const h = await importHarness(t, { failAt: 'layer.moveTo' });
  await assert.rejects(h.client.importResult(h.args), /injected/);
  assert.equal(h.docs.length, 1);
  assert.deepEqual(h.docs[0].layers, original().layers);
  const deleted = h.calls.filter(call => call.command === 'layer.delete');
  assert.deepEqual(deleted.map(call => call.params.layer), [99]);
});
