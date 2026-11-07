'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const { spawn } = require('node:child_process');
const { encodeTiff } = require('../src/tiff.cjs');

test('cancelling the CLI leaves the source intact and publishes no incomplete output', { timeout: 30000 }, async () => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'pureneg-cancel-'));
  try {
    const input = path.join(dir, 'input.tiff'), output = path.join(dir, 'results');
    const image = { width: 1200, height: 900, depth: 16, channels: 3, colorChannels: 3, data: new Uint16Array(1200 * 900 * 3).fill(24000) };
    const original = encodeTiff(image);
    await fs.writeFile(input, original);
    const child = spawn(process.execPath, [path.resolve(__dirname, '../src/cli.cjs'), 'prepare', '--input', input, '--output', output, '--work-dir', path.join(dir, 'work'), '--polarity', 'bright'], { stdio: ['ignore', 'pipe', 'pipe'] });
    let received = '', sent = false;
    child.stdout.on('data', data => {
      received += data.toString();
      if (!sent && received.includes('读取完成')) { sent = true; child.kill('SIGTERM'); }
    });
    let stderr = '';
    child.stderr.on('data', data => { stderr += data; });
    const code = await new Promise((resolve, reject) => { child.once('error', reject); child.once('close', resolve); });
    assert.ok(sent, 'cancellation must occur after input decoding');
    assert.equal(code, 130, stderr);
    const events = received.trim().split('\n').map(line => JSON.parse(line));
    assert.equal(events.at(-1).type, 'error');
    assert.equal(events.at(-1).cancelled, true);
    assert.deepEqual(await fs.readFile(input), original);
    const published = await fs.readdir(output).catch(error => error.code === 'ENOENT' ? [] : Promise.reject(error));
    assert.deepEqual(published, []);
  } finally { await fs.rm(dir, { recursive: true, force: true }); }
});
