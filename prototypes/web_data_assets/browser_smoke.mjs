// Node >=22; no npm packages. Uses Chrome's DevTools Protocol with a fresh profile.
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdtemp, readFile, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import {once} from 'node:events';

const root = path.resolve(process.argv[2] ?? '.work/app/build/web');
const chrome = process.env.CHROME_EXECUTABLE ??
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const requests = [];
const server = createServer(async (request, response) => {
  const url = new URL(request.url, 'http://localhost');
  const file = path.resolve(root, '.' + url.pathname.replace(/^\/probe/, ''));
  if (!url.pathname.startsWith('/probe/') ||
      !(file === root || file.startsWith(root + path.sep))) {
    response.writeHead(404).end(); return;
  }
  const types = {'.mjs': 'text/javascript', '.js': 'text/javascript',
    '.wasm': 'application/wasm', '.html': 'text/html'};
  try {
    const actual = url.pathname.endsWith('/') ? path.join(file, 'index.html') : file;
    const bytes = await readFile(actual);
    requests.push(url.pathname + url.search);
    response.writeHead(200, {'Content-Type': types[path.extname(actual)] ??
      'application/octet-stream', 'Cache-Control': 'no-store'}).end(bytes);
  } catch { response.writeHead(404).end(); }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const origin = `http://127.0.0.1:${server.address().port}`;
const profile = await mkdtemp(path.join(tmpdir(), 'web-data-assets-chrome-'));
const child = spawn(chrome, ['--headless=new', '--remote-debugging-port=0',
  `--user-data-dir=${profile}`, '--no-first-run', '--no-default-browser-check',
  'about:blank'], {stdio: 'ignore'});
let socket;
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const deadline = Date.now() + 90000;
const watchdog = setTimeout(() => child.kill('SIGKILL'), 100000);
try {
  let port;
  while (!port) {
    if (Date.now() > deadline) throw Error('Chrome startup timeout');
    try { port = (await readFile(path.join(profile, 'DevToolsActivePort'), 'utf8')).split('\n')[0]; }
    catch { await delay(100); }
  }
  const pages = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
  socket = new WebSocket(pages.find(p => p.type === 'page').webSocketDebuggerUrl);
  await once(socket, 'open');
  let id = 0;
  const pending = new Map();
  socket.addEventListener('message', event => {
    const message = JSON.parse(event.data);
    if (pending.has(message.id)) {
      const {resolve, reject} = pending.get(message.id);
      pending.delete(message.id);
      message.error ? reject(Error(JSON.stringify(message.error))) : resolve(message.result);
    }
  });
  function send(method, params = {}) {
    return new Promise((resolve, reject) => {
      const next = ++id;
      pending.set(next, {resolve, reject});
      socket.send(JSON.stringify({id: next, method, params}));
    });
  }
  async function evaluate(expression) {
    const result = await send('Runtime.evaluate', {expression, awaitPromise: true,
      returnByValue: true, timeout: 60000});
    if (result.exceptionDetails) throw Error(JSON.stringify(result.exceptionDetails));
    return result.result.value;
  }
  await send('Page.enable');
  await send('Page.navigate', {url: origin + '/probe/'});
  let flutterResult;
  while (!flutterResult) {
    if (Date.now() > deadline) throw Error('Flutter rootBundle probe timeout');
    await delay(100);
    flutterResult = await evaluate('globalThis.flutterAssetProbe');
  }
  assert.equal(flutterResult, 'PASS');
  const result = await evaluate(`(${async function () {
    const workers = [];
    let id = 0;
    function worker(packageName) {
      const url = new URL('assets/packages/web_payload_probe/web/' +
        packageName + '_worker.mjs?probe=1', document.baseURI);
      const result = new Worker(url, {type: 'module'});
      workers.push(result);
      return result;
    }
    function call(worker, operation, args = {}) {
      return new Promise((resolve, reject) => {
        const request = ++id;
        const timer = setTimeout(() => reject(Error(operation + ' timeout')), 20000);
        worker.onerror = event => { clearTimeout(timer); reject(Error(event.message)); };
        worker.onmessage = ({data}) => {
          if (data.id !== request) return;
          clearTimeout(timer);
          data.error ? reject(Error(JSON.stringify(data.error))) : resolve(data.result);
        };
        worker.postMessage({id: request, operation, ...args});
      });
    }
    function check(condition, message) { if (!condition) throw Error(message); }
    try {
      const zxing = worker('zxing_dart');
      const image = worker('image_ffmpeg');
      const z = await call(zxing, 'capabilities');
      const i = await call(image, 'capabilities');
      check(z.abiVersion === 3 && i.abiVersion === 5, 'Unexpected ABI');
      const matrix = await call(zxing, 'encodeDataMatrix', {
        payload: new TextEncoder().encode('Hook-supplied Wasm works'),
      });
      check(matrix.width > 0 && matrix.height > 0 && matrix.bits.length > 0,
        'Empty barcode');
      const pixels = new Uint8Array([255, 0, 0, 255]);
      const png = await call(image, 'encodePng', {
        bytes: pixels, width: 1, height: 1, stride: 4, compressionLevel: 6,
      });
      check(png.bytes[0] === 137 && png.bytes[1] === 80, 'Missing PNG signature');
      const decoded = await call(image, 'decodeImage', {encoded: png.bytes});
      check(decoded.width === 1 && decoded.height === 1 &&
        pixels.every((v, n) => decoded.bytes[n] === v), 'PNG round trip failed');
      return {baseURI: document.baseURI, zxingAbi: z.abiVersion,
        imageAbi: i.abiVersion, barcode: [matrix.width, matrix.height],
        pngBytes: png.bytes.length, pngRoundTrip: 'PASS'};
    } finally { for (const worker of workers) worker.terminate(); }
  }} )()`);
  for (const packageName of ['image_ffmpeg', 'zxing_dart']) {
    for (const suffix of ['worker.mjs', 'loader.mjs', 'module.mjs', 'module.wasm']) {
      assert(requests.some(url => url.split('?')[0] ===
        `/probe/assets/packages/web_payload_probe/web/${packageName}_${suffix}`));
    }
  }
  assert(requests.includes('/probe/assets/packages/web_payload_probe/web/image_ffmpeg_module.wasm?probe=1'));
  const appCodeRequests = requests.filter(url => url.includes('/main.dart.'));
  if (process.argv.includes('--expect-dart-wasm')) {
    assert(appCodeRequests.includes('/probe/main.dart.wasm'));
    assert(!appCodeRequests.includes('/probe/main.dart.js'), 'Unexpected Dart-to-JS fallback');
  }
  console.log(JSON.stringify({flutterRootBundle: flutterResult, ...result, appCodeRequests,
    requests: requests.filter(url => url.includes('web_payload_probe'))}, null, 2));
} finally {
  clearTimeout(watchdog);
  socket?.close();
  child.kill();
  if (child.exitCode === null && child.signalCode === null) await once(child, 'exit');
  server.closeAllConnections();
  await new Promise(resolve => server.close(resolve));
  await rm(profile, {recursive: true, force: true});
}
