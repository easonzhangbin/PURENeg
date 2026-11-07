#!/usr/bin/env node
'use strict';
// Refresh from a locally reviewed checkout, never from an unpinned remote branch.
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const expected = 'fcf68d6c6a77e4373db28f878c7f80f7b8934f3f';
const source = path.resolve(process.argv[2] || path.join(__dirname, '../../research/film-dust'));
const dest = path.resolve(__dirname, '../vendor/film-dust');
const revision = execFileSync('git', ['-C', source, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();
if (revision !== expected) throw new Error('The film-dust checkout is not the reviewed revision');
fs.mkdirSync(dest, { recursive: true });
for (const rel of ['engine', 'LICENSE.txt', 'NOTICES.txt', 'native/src', 'native/node-api', 'native/build.sh']) {
  fs.cpSync(path.join(source, rel), path.join(dest, rel), { recursive: true });
}
const binary = path.join(source, 'native/build/filmdust.node');
if (fs.existsSync(binary)) {
  fs.mkdirSync(path.join(dest, 'native/build'), { recursive: true });
  fs.copyFileSync(binary, path.join(dest, 'native/build/filmdust.node'));
}
fs.writeFileSync(path.join(dest, 'UPSTREAM.json'), JSON.stringify({
  repository: 'https://github.com/magholmes/film-dust', revision, license: 'MIT', patches: [],
}, null, 2) + '\n');
console.log('Vendored film-dust ' + revision.slice(0, 7));
