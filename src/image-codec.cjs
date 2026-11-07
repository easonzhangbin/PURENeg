'use strict';

const fs = require('node:fs/promises');
const { constants } = require('node:fs');
const path = require('node:path');
const { execFile } = require('node:child_process');
const { promisify } = require('node:util');
const { cancelled } = require('./processor.cjs');

const exec = promisify(execFile);

async function runImageCodec(args, signal) {
  cancelled(signal);
  const candidates = [
    path.join(__dirname, '..', 'runtime', 'image-codec'),
    path.join(__dirname, '..', '.build', 'macos', 'image-codec'),
  ];
  let codec;
  for (const filename of candidates) {
    try {
      await fs.access(filename, constants.X_OK);
      codec = filename;
      break;
    } catch { /* An unpackaged checkout can use the local macOS build. */ }
  }
  if (!codec) throw new Error('此格式需要 PURE Neg 的 macOS 图像组件。请打开应用或先构建 macOS 版本。');
  try {
    await exec(codec, args, { signal, maxBuffer: 16 * 1024 });
  } catch (error) {
    cancelled(signal);
    throw new Error(error.stderr?.trim() || '无法读取或写入所选的图像格式。');
  }
  cancelled(signal);
}

module.exports = { runImageCodec };
