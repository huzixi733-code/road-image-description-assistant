const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const frontend = path.resolve(__dirname, '../web/index.html');

function harness({ nativeCamera = false, blocked = false } = {}) {
  const html = fs.readFileSync(frontend, 'utf8');
  const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];
  // Exercise the production speech queue and photo/result handlers with a fake
  // engine: mobile playback requires an audible utterance during a user click.
  const speech = script.slice(script.indexOf('    const TTS_MAX_CHUNK'), script.indexOf('    async function initCamera'));
  const photo = script.slice(script.indexOf('    async function sendImageToOllama'), script.indexOf("    reReadBtn.addEventListener"));
  let clock = 0;
  let nextId = 1;
  const timers = new Map();
  const spoken = [];
  let clicks = 0;
  let activated = false;
  let inGesture = false;
  let cancels = 0;
  let resolveResponse;
  const elements = {};
  for (const name of ['captureBtn', 'captureBtnText', 'fallbackCaptureBtn', 'nativeFileInput', 'timingBadge', 'resultContent', 'debugBox', 'snapshotElem', 'videoElem', 'srAnnouncer']) {
    elements[name] = { textContent: '', style: {}, listeners: {}, addEventListener(type, fn) { this.listeners[type] = fn; } };
  }
  elements.nativeFileInput.click = () => { clicks++; };
  elements.videoElem.videoWidth = nativeCamera ? 0 : 640;
  const synth = {
    speaking: false, pending: false, paused: false,
    getVoices: () => [],
    cancel() { cancels++; this.speaking = false; this.pending = false; },
    resume() { this.paused = false; },
    speak(utterance) {
      spoken.push(utterance);
      if (inGesture && utterance.text.trim() && utterance.volume > 0) activated = true;
      if (blocked || !activated) {
        context.setTimeout(() => utterance.onerror?.({ error: 'not-allowed' }), 0);
      } else {
        this.speaking = true;
        utterance.onstart?.();
      }
    }
  };
  const context = vm.createContext({
    ...elements, console,
    CONFIG: { ttsRate: 1, ttsPitch: 1, ttsVoiceURI: '', apiEndpoint: '/api/chat', modelName: 'existing-model', systemPrompt: 'existing-prompt' },
    window: { speechSynthesis: synth }, navigator: { userAgent: 'iPhone' },
    SpeechSynthesisUtterance: function(text) { this.text = text; },
    setTimeout(fn, delay) { const id = nextId++; timers.set(id, { fn, at: clock + delay }); return id; },
    clearTimeout(id) { timers.delete(id); },
    setInterval() { return nextId++; }, clearInterval() {},
    triggerHaptic() {}, performance: { now: () => clock },
    currentStream: nativeCamera ? null : {}, isProcessing: false, lastDescription: '',
    captureVideoFrame: () => 'photo-base64',
    handleFileCapture: () => vm.runInContext("sendImageToOllama('photo-base64')", context),
    fetch: () => new Promise(resolve => { resolveResponse = resolve; })
  });
  vm.runInContext(speech + photo, context);
  return {
    spoken, elements, get cancels() { return cancels; }, get clicks() { return clicks; },
    call(code) { return vm.runInContext(code, context); },
    click(name) { inGesture = true; try { elements[name].listeners.click(); } finally { inGesture = false; } },
    end() { synth.speaking = false; spoken.at(-1).onend?.(); },
    advance(ms) {
      const target = clock + ms;
      for (let guard = 0; guard < 500; guard++) {
        const next = [...timers].filter(([, t]) => t.at <= target).sort((a, b) => a[1].at - b[1].at)[0];
        if (!next) { clock = target; return; }
        clock = next[1].at; timers.delete(next[0]); next[1].fn();
      }
      throw new Error('Unbounded retry loop');
    },
    async respond(description) {
      resolveResponse({ ok: true, json: async () => ({ message: { content: JSON.stringify({ description }) } }) });
      await new Promise(resolve => setImmediate(resolve));
    }
  };
}

test('first live photo and subsequent photo start and read the returned road description', async () => {
  const h = harness();
  for (const description of ['前方有行人，请注意避让。', '右侧有车辆，请沿左侧通行。']) {
    h.click('captureBtn');
    assert.equal(h.spoken.at(-1).text, '已拍照，正在识别路况，请稍候。');
    h.end(); h.advance(40);
    await h.respond(description);
    assert.equal(h.spoken.at(-1).text, description);
    assert.equal(h.elements.resultContent.textContent, description);
    h.end(); h.advance(40);
  }
  assert.equal(h.cancels, 0, 'idle engines are never canceled before first speech');
});

test('native camera starts audible speech in the click before asynchronous image/result loading', async () => {
  const h = harness({ nativeCamera: true });
  h.click('captureBtn');
  assert.equal(h.clicks, 1);
  assert.equal(h.spoken[0].text, '请拍照，返回后将自动播报路况。');
  assert.equal(h.spoken[0].volume, 1);
  h.end(); h.advance(40);
  h.elements.nativeFileInput.listeners.change({ target: { files: [{}] } });
  h.end(); h.advance(40);
  await h.respond('前方路面平整。');
  assert.equal(h.spoken.at(-1).text, '前方路面平整。');
  h.end(); h.advance(40);
  h.click('fallbackCaptureBtn');
  assert.equal(h.clicks, 2);
  assert.equal(h.elements.nativeFileInput.value, '', 'same photo may be selected again');
});

test('late errors from interrupted notices cannot invalidate the road description', async () => {
  const h = harness();
  h.click('captureBtn');
  const oldNotice = h.spoken[0];
  await h.respond('前方有台阶。');
  const roadSpeech = h.spoken.at(-1);
  oldNotice.onerror({ error: 'interrupted' });
  assert.equal(h.call('activeUtterance'), roadSpeech);
  assert.equal(h.call('ttsActive'), true);
});

test('a failed first chunk is retried instead of skipped, with a bounded retry', () => {
  const h = harness();
  h.click('captureBtn');
  const first = h.spoken[0];
  first.onerror({ error: 'synthesis-failed' });
  h.advance(120);
  assert.equal(h.spoken[1].text, first.text);
  first.onend();
  assert.equal(h.call('activeUtterance'), h.spoken[1]);
  h.spoken[1].onerror({ error: 'synthesis-failed' });
  h.advance(10000);
  assert.equal(h.spoken.length, 2);
  assert.match(h.elements.timingBadge.textContent, /点击顶部重读/);
});

test('browser rejection reports a replay action rather than silently discarding speech', () => {
  const h = harness({ blocked: true });
  h.click('captureBtn'); h.advance(10000);
  assert.equal(h.spoken.length, 1);
  assert.equal(h.call('ttsActive'), false);
  assert.match(h.elements.timingBadge.textContent, /点击顶部重读/);
});

test('missing startup event retries the original utterance once and stops after failure', () => {
  const h = harness();
  h.click('captureBtn'); h.end(); h.advance(40);
  // A stalled mobile engine may enqueue without emitting start/end/error.
  h.call('window.speechSynthesis.speak = function() { this.pending = true; }');
  h.call("speakText('前方有台阶。')");
  h.advance(12000);
  assert.equal(h.call('ttsActive'), false);
  assert.match(h.elements.timingBadge.textContent, /点击顶部重读/);
});
