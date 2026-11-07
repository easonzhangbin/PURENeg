'use strict';

const os = require('node:os');
const path = require('node:path');

function supportPath(name) {
  const support = process.platform === 'darwin' ? ['Library', 'Application Support'] : ['.local', 'share'];
  return path.join(os.homedir(), ...support, name);
}

function workRootOverride() {
  return process.env.PURENEG_HOME || process.env.PHOTOCRAFT_FILMDUST_HOME;
}

function defaultWorkRoot() { return supportPath('PURENeg'); }
function legacyWorkRoot() { return supportPath('PhotoCraft Film Dust'); }

module.exports = { workRootOverride, defaultWorkRoot, legacyWorkRoot };
