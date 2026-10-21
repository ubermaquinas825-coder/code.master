param(
    [Parameter(Mandatory = $true)][string]$ApplicationDirectory,
    [Parameter(Mandatory = $true)][string]$DiagnosticsDirectory
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$application = [IO.Path]::GetFullPath($ApplicationDirectory)
$diagnostics = [IO.Path]::GetFullPath($DiagnosticsDirectory)
New-Item -ItemType Directory -Path $diagnostics -Force | Out-Null
$node = Join-Path $application 'resources/runtime/node.exe'
$server = Join-Path $application 'resources/server'
if (!(Test-Path $node) -or !(Test-Path (Join-Path $server 'build/server/index.js'))) { throw 'Bundled Windows backend is missing.' }
# This helper runs with the actual shipped Windows Node and native Sharp, on
# private throwaway data. It cannot read the desktop user's provider settings.
$helper = @'
'use strict';
const assert = require('node:assert/strict');
const { fork } = require('node:child_process');
const { randomUUID, createHash } = require('node:crypto');
const { mkdir, writeFile } = require('node:fs/promises');
const { createWriteStream } = require('node:fs');
const { join } = require('node:path');
const [server, diagnostics] = process.argv.slice(2);
const sharp = require(join(server, 'node_modules/sharp'));
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const report = { status: 'failed', startedAt: new Date().toISOString(), platform: process.platform, nodeVersion: process.version, checks: [] };
const data = join(diagnostics, 'private-test-data');
let child, base, cookie = '';
async function start() {
  const env = { ...process.env, NODE_ENV: 'production', HOST: '127.0.0.1', PORT: '0', DATA_DIR: data,
    APP_ORIGIN: '', COOKIE_SECURE: 'false', OPENAI_API_KEY: '', APP_OPENAI_API_KEY: '',
    AI_IMAGE_MODEL: '', AI_VISION_MODEL: '', DOTENV_CONFIG_PATH: join(data, 'never-load-env'), DOTENV_CONFIG_QUIET: 'true' };
  delete env.NODE_OPTIONS;
  delete env.ELECTRON_RUN_AS_NODE;
  child = fork(join(server, 'build/server/index.js'), [], { cwd: server, env, execPath: process.execPath,
    windowsHide: true, stdio: ['ignore', 'pipe', 'pipe', 'ipc'] });
  const log = createWriteStream(join(diagnostics, `backend-${Date.now()}.log`));
  child.stdout.pipe(log, { end: false });
  child.stderr.pipe(log, { end: false });
  child.once('exit', () => log.end());
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('Packaged backend readiness timed out.')), 45000);
    const finish = (error, message) => { clearTimeout(timer); error ? reject(error) : resolve(message); };
    child.once('error', error => finish(error));
    child.once('exit', code => finish(new Error(`Backend exited before readiness (${code}).`)));
    child.on('message', message => {
      if (message?.type === 'startup-error') finish(new Error(`Backend startup: ${message.code}`));
      if (message?.type === 'ready') {
        assert.ok(Number.isInteger(message.port) && message.port > 0 && message.port < 65536);
        base = `http://127.0.0.1:${message.port}`;
        finish(null);
      }
    });
  });
}
async function stop() {
  const proc = child;
  if (!proc || proc.exitCode !== null || proc.signalCode !== null) return;
  await new Promise(resolve => {
    const timer = setTimeout(() => { proc.kill(); resolve(); }, 35000);
    proc.once('exit', () => { clearTimeout(timer); resolve(); });
    if (proc.connected) proc.send({ type: 'shutdown' }, error => { if (error) proc.kill(); });
    else proc.kill();
  });
}
async function request(path, { method = 'GET', body, status = 200, form } = {}) {
  const headers = {};
  if (cookie) headers.Cookie = cookie;
  if (!['GET', 'HEAD'].includes(method)) headers.Origin = base;
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  const response = await fetch(base + '/api' + path, { method, headers,
    body: form || (body === undefined ? undefined : JSON.stringify(body)), signal: AbortSignal.timeout(15000) });
  assert.equal(response.status, status, `${method} ${path} expected HTTP ${status}, got ${response.status}`);
  return response;
}
async function json(path, options) { return (await request(path, options)).json(); }
async function bytes(asset) { return Buffer.from(await (await request(`/assets/${asset.id}/file`)).arrayBuffer()); }
async function poll(job) {
  const deadline = Date.now() + 60000;
  while (Date.now() < deadline) {
    const current = (await json(`/jobs/${job.id}`)).job;
    assert.notEqual(current.status, 'failed', `Worker failed: ${current.error?.message || current.error || current.id}`);
    if (current.status === 'succeeded') return current;
    await sleep(350);
  }
  throw new Error(`Queued job timed out: ${job.id}`);
}
async function alphaChecks(image) {
  const decoded = await sharp(image).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  assert.equal(decoded.info.width, 72);
  assert.equal(decoded.info.height, 96);
  const alpha = (x, y) => decoded.data[(y * decoded.info.width + x) * 4 + 3];
  assert.equal(alpha(36, 48), 0, 'Erase stroke must remove center alpha.');
  assert.equal(alpha(0, 0), 0, 'Polygon must remove outside alpha.');
  assert.equal(alpha(18, 24), 255, 'Interior pixels must remain opaque.');
}
(async () => {
  try {
    assert.equal(process.platform, 'win32', 'This verification must run natively on Windows.');
    assert.equal(process.version, 'v24.18.0', 'Unexpected bundled Node version.');
    await mkdir(data, { recursive: true });
    await start();
    const config = await json('/config');
    assert.equal(config.aiConfigured, false);
    assert.equal(config.visionConfigured, false);
    assert.equal(config.capabilities.generate, false);
    assert.equal(config.capabilities.vectorize, true);
    report.checks.push('Packaged Windows Node, SQLite and Sharp start without provider keys');
    const register = await request('/auth/register', { method: 'POST', status: 201,
      body: { name: 'Smoke Windows', email: `smoke-${randomUUID()}@example.test`, password: `Aa!${randomUUID()}` } });
    const user = (await register.json()).user;
    cookie = register.headers.get('set-cookie').split(';', 1)[0];
    const project = (await json('/projects')).projects[0];
    assert.ok(project?.id);
    const polygon = Buffer.from('<svg xmlns="http://www.w3.org/2000/svg" width="96" height="72"><polygon points="20,16 70,14 76,54 24,56" fill="rgb(210,30,65)"/></svg>');
    const fixture = await sharp({ create: { width: 96, height: 72, channels: 4, background: '#ffffff' } })
      .composite([{ input: polygon }]).withMetadata({ density: 144 }).png().toBuffer();
    const form = new FormData();
    form.set('projectId', project.id);
    form.set('file', new Blob([fixture], { type: 'image/png' }), 'poligono-smoke.png');
    const upload = (await json('/uploads', { method: 'POST', form, status: 201 })).upload;
    assert.match(upload.originalUrl, /^\/api\/uploads\/[^/]+\/original$/);
    assert.equal(upload.originalSha256, hash(fixture));
    const originalUploadBytes = async () => Buffer.from(await (await request(upload.originalUrl.slice(4))).arrayBuffer());
    assert.deepEqual(await originalUploadBytes(), fixture, 'Raw upload download must preserve every input byte, including metadata.');
    const initial = await json(`/uploads/${upload.id}/extraction`);
    assert.equal(initial.revision, 0);
    const creditsBefore = await json('/credits');
    const analysis = await json(`/uploads/${upload.id}/analyze`, { method: 'POST', body: { mode: 'local', view: 'front', revision: 0 } });
    assert.equal(analysis.method, 'local');
    assert.ok(analysis.regions.length > 0 && analysis.regions.length <= 16);
    assert.ok(analysis.regions.some(r => r.x > 0.1 && r.y > 0.1 && r.width < 0.9 && r.height < 0.9 &&
      r.x <= 0.5 && r.x + r.width >= 0.5 && r.y <= 0.5 && r.y + r.height >= 0.5));
    for (const r of analysis.regions) {
      assert.equal(r.confidenceSource, 'contrast-heuristic');
      assert.equal(r.estimated, true);
      assert.ok(r.x >= 0 && r.y >= 0 && r.width > 0 && r.height > 0 && r.x + r.width <= 1 && r.y + r.height <= 1);
    }
    const document = analysis.document;
    assert.equal(document.revision, 1);
    assert.equal(document.view, 'front');
    assert.deepEqual(document.regions, analysis.regions);
    assert.deepEqual(await json(`/uploads/${upload.id}/extraction`), document);
    assert.deepEqual(await json('/credits'), creditsBefore);
    report.checks.push('Local analysis measures the uploaded polygon and persists normalized regions without paid calls');
    const crop = await poll((await json('/jobs', { method: 'POST', status: 202, body: {
      idempotencyKey: randomUUID(), projectId: project.id, uploadId: upload.id, operation: 'crop',
      regions: [{ id: 'imagem', label: 'Original smoke', x: 0, y: 0, width: 1, height: 1 }] } })).job);
    assert.equal(crop.assets.length, 1);
    const original = crop.assets[0];
    const originalBytes = await bytes(original);
    const originalPixels = await sharp(originalBytes).ensureAlpha().raw().toBuffer();
    assert.deepEqual([...originalPixels.subarray((36 * 96 + 48) * 4, (36 * 96 + 48) * 4 + 4)], [210, 30, 65, 255]);
    const recipe = { rotation: 90, polygon: [{ x: 0.1, y: 0.1 }, { x: 0.9, y: 0.1 }, { x: 0.9, y: 0.9 }, { x: 0.1, y: 0.9 }],
      strokes: [{ mode: 'erase', radius: 0.1, points: [{ x: 0.5, y: 0.5 }] }] };
    const before = (await json(`/assets?projectId=${project.id}`)).assets.length;
    const versionsBefore = await json(`/assets/${original.id}/versions`);
    const preview = await request(`/assets/${original.id}/edits/preview`, { method: 'POST', body: { recipe } });
    assert.match(preview.headers.get('content-type'), /^image\/png/);
    await alphaChecks(Buffer.from(await preview.arrayBuffer()));
    assert.equal((await json(`/assets?projectId=${project.id}`)).assets.length, before);
    assert.deepEqual(await json(`/assets/${original.id}/versions`), versionsBefore);
    const saved = await json(`/assets/${original.id}/edits`, { method: 'POST', status: 201,
      body: { recipe, label: 'Smoke PNG editado' } });
    const edited = saved.asset;
    assert.notEqual(edited.id, original.id);
    assert.equal(saved.version.parentAssetId, original.id);
    assert.deepEqual(saved.version.recipe, recipe);
    const editedBytes = await bytes(edited);
    await alphaChecks(editedBytes);
    assert.equal((await json(`/assets?projectId=${project.id}`)).assets.length, before + 1);
    assert.equal(hash(await bytes(original)), hash(originalBytes));
    assert.equal(hash(await originalUploadBytes()), hash(fixture));
    const history = await json(`/assets/${original.id}/versions`);
    assert.ok(history.versions.some(v => v.asset.id === edited.id));
    assert.deepEqual(await json(`/assets/${edited.id}/versions`), history);
    report.checks.push('Queue crop, polygon mask, erase alpha, rotated preview and saved PNG version preserve original pixels');
    const vectorBody = { idempotencyKey: randomUUID(), projectId: project.id, assetId: edited.id,
      operation: 'vectorize', options: { colors: 4, detail: 'low' } };
    const vectorJob = await poll((await json('/jobs', { method: 'POST', status: 202, body: vectorBody })).job);
    assert.equal(vectorJob.assetId, edited.id);
    assert.equal(vectorJob.assets.length, 1);
    const vector = vectorJob.assets[0];
    assert.equal(vector.kind, 'vector');
    assert.equal(vector.mimeType, 'image/svg+xml');
    assert.equal(vector.width, 72);
    assert.equal(vector.height, 96);
    const vectorBytes = await bytes(vector);
    const svg = vectorBytes.toString('utf8');
    assert.match(svg, /<svg\b/);
    assert.match(svg, /<path\b[^>]*\bd="[^"]+"/);
    assert.doesNotMatch(svg, /<image\b|data:image|<script\b/i);
    const repeated = await json('/jobs', { method: 'POST', body: vectorBody });
    assert.equal(repeated.job.id, vectorJob.id);
    const credits = await json('/credits');
    assert.equal(credits.balance, creditsBefore.balance - 2);
    assert.equal(credits.reserved, 0);
    assert.equal(credits.entries.filter(e => e.jobId === vectorJob.id && e.type === 'reserve').length, 1);
    report.checks.push('Edited assetId is traced to actual SVG paths with rotated dimensions and one credit reservation');
    await stop();
    await start();
    assert.equal((await json('/me')).user.id, user.id);
    assert.deepEqual(await originalUploadBytes(), fixture);
    assert.equal((await json(`/uploads?projectId=${project.id}`)).uploads.find(item => item.id === upload.id).originalSha256, hash(fixture));
    assert.deepEqual(await json(`/uploads/${upload.id}/extraction`), document);
    assert.deepEqual(await json(`/assets/${original.id}/versions`), history);
    assert.equal(hash(await bytes(original)), hash(originalBytes));
    assert.equal(hash(await bytes(edited)), hash(editedBytes));
    assert.equal(hash(await bytes(vector)), hash(vectorBytes));
    const persistedJob = (await json(`/jobs/${vectorJob.id}`)).job;
    assert.equal(persistedJob.status, 'succeeded');
    assert.equal(persistedJob.assetId, edited.id);
    assert.deepEqual(await json('/credits'), credits);
    report.checks.push('Raw upload download and SHA-256 preserve every original byte, including PNG metadata, after edits and backend restart');
    report.checks.push('Backend restart recovers session, extraction, edit recipe, original files, SVG, queue and credits from disk');
    report.status = 'passed';
  } catch (error) { report.error = String(error.stack || error); process.exitCode = 1; }
  finally {
    await stop();
    report.finishedAt = new Date().toISOString();
    await writeFile(join(diagnostics, 'feature-report.json'), JSON.stringify(report, null, 2));
    console.log(JSON.stringify(report, null, 2));
  }
})();
'@
$helperPath = Join-Path $diagnostics 'feature-smoke.cjs'
$helper | Set-Content -LiteralPath $helperPath -Encoding utf8
$process = Start-Process -FilePath $node -ArgumentList ('"{0}" "{1}" "{2}"' -f $helperPath, $server, $diagnostics) -PassThru -NoNewWindow
if (!$process.WaitForExit(360000)) {
    & taskkill /PID $process.Id /T /F 2>$null
    throw 'Native feature verification exceeded six minutes.'
}
if ($process.ExitCode -ne 0) { throw ('Native feature verification failed with exit code ' + $process.ExitCode) }
$report = Get-Content (Join-Path $diagnostics 'feature-report.json') -Raw | ConvertFrom-Json
if ($report.status -ne 'passed') { throw 'Native feature verification did not pass.' }
