#!/usr/bin/env node
'use strict';

const fs = require('node:fs/promises');
const path = require('node:path');
const { execFile } = require('node:child_process');
const { promisify } = require('node:util');
const { processFile, optionsChecked, cancelled } = require('./processor.cjs');
const { workRootOverride, defaultWorkRoot, legacyWorkRoot } = require('./workspace.cjs');
const version = require('./version.cjs');
const runFile = promisify(execFile);
const thresholdFlags = ['dust-sensitivity', 'fiber-sensitivity', 'scratch-sensitivity'];

const englishMessages = process.env.PURENEG_LANGUAGE === 'en' ? require('./engine-messages-en.json') : null;
const emit = (event) => {
  if (englishMessages && typeof event.message === 'string') {
    const secondPass = ' · 第二遍';
    const repeated = event.message.endsWith(secondPass);
    const base = repeated ? event.message.slice(0, -secondPass.length) : event.message;
    if (Object.hasOwn(englishMessages, base)) {
      event = { ...event, message: englishMessages[base] + (repeated ? ' · Pass 2' : '') };
    }
  }
  process.stdout.write(JSON.stringify(event) + '\n');
};
const controller = new AbortController();
process.once('SIGTERM', () => controller.abort());
process.once('SIGINT', () => controller.abort());

function parseArgs(args) {
  const command = args.shift() || 'help';
  const flags = {};
  const switches = new Set(['launch', 'revise-export']);
  const allowed = new Set(['input', 'source-name', 'output', 'polarity', 'sensitivity', 'detect', 'work-dir', 'app', 'launch', 'review', 'edits', 'format', 'mask', 'revise-export', ...thresholdFlags]);
  while (args.length) {
    const key = args.shift();
    if (!key.startsWith('--') || !allowed.has(key.slice(2))) throw new Error('未知参数：' + key);
    const name = key.slice(2);
    if (Object.hasOwn(flags, name)) throw new Error('重复参数：' + key);
    if (switches.has(name)) flags[name] = true;
    else {
      if (!args.length || args[0].startsWith('--')) throw new Error('参数缺少值：' + key);
      flags[name] = args.shift();
    }
  }
  return { command, flags };
}

function workRoot(flags) {
  return path.resolve(flags['work-dir'] || workRootOverride() || defaultWorkRoot());
}

function appPath(flags) {
  return flags.app || process.env.PHOTOCRAFT_APP || '/Applications/PhotoCraft.app';
}

async function installedInfo(app) {
  try {
    const executable = app.endsWith('.app') ? path.join(app, 'Contents/MacOS/PhotoCraft') : app;
    await fs.access(executable);
    const result = await runFile(executable, ['--version'], { timeout: 15000, maxBuffer: 4096 });
    const match = (result.stdout || result.stderr).match(/\d+\.\d+\.\d+/);
    return { installed: true, version: match?.[0] || 'unknown', app };
  } catch { return { installed: false, app }; }
}

async function publishResult(result, destination) {
  await fs.mkdir(destination, { recursive: true });
  const outputDir = await fs.mkdtemp(path.join(path.resolve(destination), 'PURENeg-'));
  const paths = {};
  try {
    for (const [key, file] of Object.entries(result.paths)) {
      paths[key] = path.join(outputDir, path.basename(file));
      await fs.copyFile(file, paths[key], fs.constants.COPYFILE_EXCL);
    }
  } catch (error) {
    await fs.rm(outputDir, { recursive: true, force: true });
    throw error;
  }
  return { ...result, outputDir, paths };
}

async function main(argv) {
  const parsed = parseArgs([...argv]);
  const flags = parsed.flags;
  // v0.2 makes the previous commands safe aliases: analysis never commits to a
  // PhotoCraft document or publishes final files without a separate confirm.
  const command = ({ process: 'prepare', photocraft: 'prepare-photocraft' })[parsed.command] || parsed.command;
  if (command !== 'redetect' && thresholdFlags.some(key => Object.hasOwn(flags, key))) {
    throw new Error('分类灵敏度仅用于重新检测。');
  }
  if (flags.format !== undefined && command !== 'confirm') throw new Error('请在确认审核时选择导出格式。');
  if (flags['source-name'] !== undefined && command !== 'prepare') throw new Error('仅在准备审核时可指定来源名称。');
  const reviseExport = flags['revise-export'] === true;
  if (reviseExport && command !== 'preview' && command !== 'confirm') throw new Error('仅可在预览或确认时修订已导出的结果。');
  if (flags.mask !== undefined && (command !== 'confirm' || !['yes', 'no'].includes(flags.mask))) {
    throw new Error('请在确认审核时用 --mask yes 或 --mask no 选择是否保存蒙版。');
  }
  if (command === 'help' || command === '--help') {
    emit({ type: 'result', message: 'PURE Neg ' + version, usage: [
      'prepare --input scan.tiff|scan.jpg --output folder [--polarity auto|bright|dark] [--sensitivity 1] [--detect dust,scratches,fibers]',
      'doctor [--launch] [--app /Applications/PhotoCraft.app]',
      'prepare-photocraft --output folder [--polarity auto|bright|dark] [--sensitivity 1] [--detect dust,scratches,fibers]',
      'redetect --review review.json [--edits edits.json] --dust-sensitivity 1 --fiber-sensitivity 1 --scratch-sensitivity 1',
      'preview --review review.json --edits edits.json [--revise-export]',
      'inspect-review --review review.json',
      'confirm --review review.json --edits edits.json [--format tiff|jpeg|png] [--output folder] [--mask yes|no] [--revise-export]',
    ] });
    return;
  }
  if (!['prepare', 'doctor', 'prepare-photocraft', 'preview', 'confirm', 'inspect-review', 'redetect'].includes(command)) throw new Error('未知命令：' + command);
  const settings = optionsChecked({ polarity: flags.polarity ?? 'auto', sensitivity: flags.sensitivity === undefined ? 1 : Number(flags.sensitivity), detect: flags.detect });
  const options = { ...settings, conserveMemory: process.env.PURENEG_CONSERVE_MEMORY === '1',
    signal: controller.signal, onProgress: (event) => emit({ type: 'progress', ...event }) };
  const root = workRoot(flags), cacheRoot = path.join(root, 'reviews');
  const hasExplicitRoot = Boolean(flags['work-dir'] || workRootOverride());
  await fs.mkdir(root, { recursive: true, mode: 0o700 });
  if (command === 'preview' || command === 'confirm' || command === 'inspect-review' || command === 'redetect') {
    if (!flags.review) throw new Error('缺少审核记录；请先分析并预览扫描件。');
    const { renderReviewPreview, confirmReview, inspectReview, redetectReview } = require('./review.cjs');
    const reviewOptions = { ...options, reviseExport };
    if (hasExplicitRoot) reviewOptions.cacheRoot = cacheRoot;
    if (command === 'inspect-review') {
      emit({ type: 'review', ...await inspectReview(flags.review, reviewOptions) });
      return;
    }
    let edits = { excludedRegions: [] };
    if (flags.edits) {
      const editStat = await fs.stat(flags.edits);
      if (!editStat.isFile() || editStat.size > 8_000_000) throw new Error('审核选择文件无效或过大。');
      try { edits = JSON.parse(await fs.readFile(flags.edits, 'utf8')); }
      catch { throw new Error('无法读取审核选择，请重新打开预览。'); }
    }
    if (command === 'redetect') {
      const [dustSensitivity, fiberSensitivity, scratchSensitivity] = thresholdFlags.map(key => Number(flags[key]));
      const result = await redetectReview(flags.review, edits, { ...reviewOptions, dustSensitivity, fiberSensitivity, scratchSensitivity });
      emit({ type: 'redetected', ...result });
      return;
    }
    if (command === 'preview') {
      const preview = await renderReviewPreview(flags.review, edits, reviewOptions);
      emit({ type: 'preview', ...preview });
      return;
    }
    emit({ type: 'progress', fraction: 0.05, message: '按你确认的点位生成最终结果' });
    const includeMask = flags.mask === undefined ? undefined : flags.mask === 'yes';
    const result = await confirmReview(flags.review, edits, { ...reviewOptions, format: flags.format, outputRoot: flags.output, includeMask });
    const { context, host, stagedPaths, ...publicResult } = result;
    if (context !== 'photocraft' || !result.changed) {
      const saved = publicResult.paths.mask ? '图像和蒙版' : '图像';
      const message = result.changed ? `已保存你确认的修复${saved}。` :
        context === 'photocraft' ? '没有保留需要修复的区域，原图保持不变。' : `已保存${saved}，图像与原图一致。`;
      const resultEvent = { type: 'result', ...publicResult, imported: false, message };
      if (reviseExport) {
        resultEvent.reviewPreview = { cleanedPath: stagedPaths.cleaned, maskPath: stagedPaths.mask };
      }
      emit(resultEvent);
      return;
    }
    // Confirmation publishes the chosen pixels once. A failed host import does
    // not silently retry and add duplicate layers; the final TIFFs remain usable.
    emit({ type: 'progress', fraction: 0.96, message: '正在导回确认后的修复，请暂勿编辑 PhotoCraft' });
    try {
      const { ensureSession } = require('./photocraft.cjs');
      const session = await ensureSession({ workDir: host.workDir, launch: false });
      const imported = await session.client.importResult({ snapshot: host.snapshot, cleanedPath: stagedPaths.cleaned, maskPath: stagedPaths.mask,
        name: 'PURE Neg · 已审核修复', manualEditable: true });
      emit({ type: 'result', ...publicResult, imported: true, documentId: imported.document,
        warnings: imported.warnings || [], message: '已将你确认的修复图层和可编辑蒙版导回 PhotoCraft。' });
    } catch (error) {
      emit({ type: 'result', ...publicResult, imported: false, warnings: [error.message],
        message: '确认后的文件已保存，但未自动导回 PhotoCraft：' + error.message });
    }
    return;
  }
  if (command === 'prepare') {
    if (!flags.input || !flags.output) throw new Error('请选择 TIFF 或 JPEG 图像和结果保存目录。');
    const { prepareReview } = require('./review.cjs');
    const review = await prepareReview({ inputPath: flags.input, sourceName: flags['source-name'], outputRoot: flags.output, context: 'file', cacheRoot, options });
    emit({ type: 'review', ...review });
    return;
  }
  const { ensureSession } = require('./photocraft.cjs');
  const installed = await installedInfo(appPath(flags));
  if (!installed.installed) {
    if (command === 'doctor') { emit({ type: 'result', ...installed, connected: false, message: '未找到 PhotoCraft，请安装后重试。' }); return; }
    throw new Error('未找到 PhotoCraft。请安装到 /Applications/PhotoCraft.app，或使用 --app 指定位置。');
  }
  let session;
  try {
    session = await ensureSession({ workDir: root, fallbackWorkDir: hasExplicitRoot ? undefined : legacyWorkRoot(),
      launch: command === 'prepare-photocraft' || flags.launch === true, appPath: appPath(flags) });
  } catch (error) {
    if (command !== 'doctor' || flags.launch || error.code !== 'NO_SESSION') throw error;
    session = null;
  }
  if (command === 'doctor') {
    emit({ type: 'result', ...installed, connected: Boolean(session?.client), message: session?.client ? '已连接 PhotoCraft；请在它的窗口中打开扫描件，然后开始除尘。' : '尚未连接；点击启动 / 连接 PhotoCraft。' });
    return;
  }
  if (!flags.output) throw new Error('请选择结果保存目录。');
  if (!session?.client) throw new Error('无法连接 PhotoCraft，请先点击启动 / 连接。');
  const sessionRoot = session.client.workDir;
  const job = await fs.mkdtemp(path.join(sessionRoot, 'job-'));
  emit({ type: 'progress', fraction: 0, message: '从 PhotoCraft 读取当前照片' });
  const exported = await session.client.prepareExport(path.join(job, 'input.tiff'));
  cancelled(controller.signal);
  const { prepareReview } = require('./review.cjs');
  const review = await prepareReview({ inputPath: exported.path, outputRoot: flags.output, context: 'photocraft',
    sourceName: exported.snapshot.name, host: { workDir: sessionRoot, snapshot: exported.snapshot },
    cacheRoot: path.join(sessionRoot, 'reviews'), options });
  emit({ type: 'review', ...review, warnings: exported.warnings || [] });
}

if (require.main === module) main(process.argv.slice(2)).catch((error) => {
  emit({ type: 'error', message: error.message || String(error), cancelled: error.name === 'AbortError' });
  process.exitCode = error.name === 'AbortError' ? 130 : 1;
});

module.exports = { main, parseArgs, installedInfo, workRoot, publishResult };
