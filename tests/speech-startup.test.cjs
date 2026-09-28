const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const frontend = path.resolve(__dirname, '../web/index.html');

function harness({ nativeCamera = false, blocked = false, platform = 'iPhone', nativeSpeech = true, voices = [], audioBlocked = false } = {}) {
  const html = fs.readFileSync(frontend, 'utf8');
  const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];
  // Exercise the production speech queue and photo/result handlers with a fake
  // engine: mobile playback requires an audible utterance during a user click.
  const speech = script.slice(script.indexOf('    const TTS_MAX_CHUNK'), script.indexOf('    async function initCamera'));
  const photo = script.slice(script.indexOf('    function inferenceError'), script.indexOf('    // 双击屏幕重听'));
  let clock = 0;
  let nextId = 1;
  const timers = new Map();
  const spoken = [];
  let clicks = 0;
  let activated = false;
  let inGesture = false;
  let cancels = 0;
  let resolveResponse;
  let rejectResponse;
  const requests = [];
  const speechRequests = [];
  const revokedAudio = [];
  const audioPlays = [];
  let resolveSpeech;
  let audio;
  const elements = {};
  for (const name of ['captureBtn', 'captureBtnText', 'fallbackCaptureBtn', 'nativeFileInput', 'timingBadge', 'resultContent', 'debugBox', 'snapshotElem', 'videoElem', 'srAnnouncer', 'serverPlayBtn', 'ttsStatusElem', 'ttsPitchSelect', 'ttsVoiceSelect', 'reReadBtn', 'stopSpeechBtn']) {
    elements[name] = { textContent: '', style: {}, listeners: {}, addEventListener(type, fn) { this.listeners[type] = fn; } };
  }
  elements.nativeFileInput.click = () => { clicks++; };
  elements.videoElem.videoWidth = nativeCamera ? 0 : 640;
  const synth = {
    speaking: false, pending: false, paused: false,
    getVoices: () => voices,
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
    window: { speechSynthesis: nativeSpeech ? synth : undefined }, navigator: { userAgent: platform },
    Audio: function() {
      audio = this; this.src = ''; this.currentTime = 0;
      this.setAttribute = () => {}; this.pause = () => {};
      this.play = () => {
        audioPlays.push({ src: this.src, inGesture });
        if (audioBlocked && this.src.startsWith('blob:') && !inGesture) {
          const error = new Error('User activation required'); error.name = 'NotAllowedError';
          return Promise.reject(error);
        }
        return Promise.resolve();
      };
    },
    AbortController,
    URL: { createObjectURL: () => 'blob:speech-' + nextId++, revokeObjectURL: url => revokedAudio.push(url) },
    SpeechSynthesisUtterance: function(text) { this.text = text; },
    setTimeout(fn, delay) { const id = nextId++; timers.set(id, { fn, at: clock + delay }); return id; },
    clearTimeout(id) { timers.delete(id); },
    setInterval() { return nextId++; }, clearInterval() {},
    triggerHaptic() {}, performance: { now: () => clock },
    currentStream: nativeCamera ? null : {}, isProcessing: false, lastDescription: '',
    captureVideoFrame: () => 'photo-base64',
    handleFileCapture: () => vm.runInContext("sendImageToOllama('photo-base64')", context),
    fetch: (url, options) => {
      if (url === '/api/tts/status') return Promise.resolve({ ok: true, json: async () => ({ available: true }) });
      if (url === '/api/tts') {
        speechRequests.push({ url, payload: JSON.parse(options.body), signal: options.signal });
        return new Promise(resolve => { resolveSpeech = resolve; });
      }
      requests.push({ url, payload: JSON.parse(options.body) });
      return new Promise((resolve, reject) => { resolveResponse = resolve; rejectResponse = reject; });
    }
  });
  vm.runInContext(speech + photo, context);
  return {
    spoken, elements, requests, speechRequests, revokedAudio, audioPlays,
    get audio() { return audio; }, get cancels() { return cancels; }, get clicks() { return clicks; },
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
    },
    async respondHttp(status, error) {
      resolveResponse({ ok: false, status, text: async () => JSON.stringify({ error }) });
      await new Promise(resolve => setImmediate(resolve));
    },
    async respondData(data) {
      resolveResponse({ ok: true, status: 200, json: async () => data });
      await new Promise(resolve => setImmediate(resolve));
    },
    async disconnect() {
      rejectResponse(new TypeError('Failed to fetch'));
      await new Promise(resolve => setImmediate(resolve));
    },
    async respondSpeech(ok = true) {
      resolveSpeech({ ok, headers: { get: () => 'audio/wav' }, blob: async () => ({ size: 2048 }) });
      await new Promise(resolve => setImmediate(resolve));
    },
    playAudioFromGesture() {
      inGesture = true;
      try { vm.runInContext('playPreparedServerAudio(ttsToken)', context); }
      finally { inGesture = false; }
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

test('generation is bounded and uses the existing endpoint, model and context', () => {
  const h = harness(); h.click('captureBtn');
  const { url, payload } = h.requests[0];
  assert.equal(url, '/api/chat');
  assert.equal(payload.model, 'existing-model');
  assert.equal(payload.messages[0].content, 'existing-prompt');
  assert.equal(payload.options.num_ctx, 6144);
  assert.equal(payload.options.num_predict, 1024);
  assert.equal(payload.options.repeat_last_n, 128);
  assert.equal(payload.options.repeat_penalty, 1.1);
});

test('repeat-limit failure retries the same photo once with different generation parameters and reads the result', async () => {
  const h = harness(); h.click('captureBtn');
  h.end(); h.advance(40);
  await h.respondHttp(500, 'prediction aborted, token repeat limit reached');
  assert.equal(h.requests.length, 2);
  assert.match(h.elements.timingBadge.textContent, /重试一次/);
  const a = h.requests[0], b = h.requests[1];
  assert.equal(b.url, a.url);
  assert.equal(b.payload.model, a.payload.model);
  assert.equal(b.payload.options.num_ctx, a.payload.options.num_ctx);
  assert.deepEqual(b.payload.messages[1].images, a.payload.messages[1].images);
  assert.equal(b.payload.options.repeat_penalty, 1.2);
  assert.equal(b.payload.options.temperature, 0.2);
  assert.notEqual(b.payload.options.seed, a.payload.options.seed);
  await h.respond('画面中央可见道路，两侧有护栏。');
  assert.equal(h.spoken.at(-1).text, '画面中央可见道路，两侧有护栏。');
  assert.equal(JSON.parse(h.elements.debugBox.textContent).retries, 1);
  assert.equal(h.elements.captureBtn.disabled, false);
});

test('two repeat-limit failures stop without a third request or misleading IP instruction', async () => {
  const h = harness(); h.click('captureBtn');
  await h.respondHttp(500, 'prediction aborted, token repeat limit reached');
  await h.respondHttp(500, 'prediction aborted, token repeat limit reached');
  assert.equal(h.requests.length, 2);
  assert.match(h.elements.resultContent.textContent, /模型输出重复/);
  assert.doesNotMatch(h.elements.resultContent.textContent, /IP|HTTP/);
  assert.equal(h.elements.captureBtn.disabled, false);
});

test('ordinary server and network failures are not automatically retried', async () => {
  for (const network of [false, true]) {
    const h = harness(); h.click('captureBtn');
    if (network) await h.disconnect(); else await h.respondHttp(500, 'model runner failed');
    assert.equal(h.requests.length, 1);
    assert.match(h.elements.resultContent.textContent, network ? /检查网络/ : /识别服务暂时出错/);
    assert.equal(h.elements.captureBtn.disabled, false);
  }
});

test('truncated or invalid model output is not read aloud as raw JSON', async () => {
  for (const data of [
    { done_reason: 'length', message: { content: '{"description":"路面' } },
    { done: false, message: { content: '{"description":"路面平整。"}' } },
    { message: { content: '{"description":"路面' } },
    { message: { content: '{"description":{}}' } },
    { message: { content: '{"description":" "}' } }
  ]) {
    const h = harness(); h.click('captureBtn'); await h.respondData(data);
    assert.equal(h.requests.length, 1);
    assert.equal(h.call('lastDescription'), '');
    assert.doesNotMatch(h.elements.resultContent.textContent, /description|IP/);
    assert.ok(h.spoken.every(utterance => !utterance.text.includes('description')));
  }
});

test('model error sent in an HTTP 200 response also takes the bounded repeat recovery', async () => {
  const h = harness(); h.click('captureBtn');
  await h.respondData({ error: 'prediction aborted, token repeat limit reached' });
  assert.equal(h.requests.length, 2);
  await h.respond('前方有护栏。');
  assert.equal(h.elements.resultContent.textContent, '前方有护栏。');
});

test('new recognition clears the previous photo description before a failure', async () => {
  const h = harness(); h.click('captureBtn'); await h.respond('前方有台阶。');
  h.end(); h.advance(40);
  h.click('captureBtn'); await h.respondHttp(500, 'model runner failed');
  assert.equal(h.call('lastDescription'), '');
});

test('Android with no native speech interface uses same-origin server WAV audio', async () => {
  const h = harness({ platform: 'Android MicroMessenger', nativeSpeech: false });
  h.click('captureBtn');
  assert.equal(h.spoken.length, 0);
  assert.equal(h.speechRequests[0].url, '/api/tts');
  assert.equal(h.speechRequests[0].payload.text, '已拍照，正在识别路况，请稍候。');
  assert.equal(h.audioPlays[0].inGesture, true, 'prime audio during the photo click');
  await h.respondSpeech();
  assert.ok(h.audio.src.startsWith('blob:'));
  await h.respond('前方有护栏。');
  await h.respondSpeech();
  assert.equal(h.speechRequests.at(-1).payload.text, '前方有护栏。');
  assert.ok(h.revokedAudio.length > 0);
});

test('Android without Chinese voices falls back, while Android with Chinese and iOS retain native speech', () => {
  const empty = harness({ platform: 'Android' }); empty.click('captureBtn');
  assert.equal(empty.speechRequests.length, 1);
  const chinese = harness({ platform: 'Android', voices: [{ voiceURI: 'mandarin', lang: 'zh-CN', name: 'Chinese' }] });
  chinese.click('captureBtn');
  assert.equal(chinese.spoken.length, 1);
  assert.equal(chinese.speechRequests.length, 0);
  const ios = harness(); ios.click('captureBtn');
  assert.equal(ios.spoken.length, 1);
  assert.equal(ios.speechRequests.length, 0);
});

test('blocked Android autoplay provides a direct user-gesture play action without regenerating audio', async () => {
  const h = harness({ platform: 'Android', nativeSpeech: false, audioBlocked: true });
  h.click('captureBtn'); await h.respondSpeech();
  assert.equal(h.elements.serverPlayBtn.style.display, '');
  const source = h.audio.src;
  h.click('serverPlayBtn');
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(h.elements.serverPlayBtn.style.display, 'none');
  assert.equal(h.audio.src, source);
  assert.equal(h.speechRequests.length, 1);
  assert.equal(h.audioPlays.at(-1).inGesture, true);
});

test('stop cancels server synthesis and a late WAV cannot resume stopped playback', async () => {
  const h = harness({ platform: 'Android', nativeSpeech: false });
  h.click('captureBtn');
  h.click('stopSpeechBtn');
  assert.equal(h.speechRequests[0].signal.aborted, true);
  await h.respondSpeech();
  assert.equal(h.call('serverAudioUrl'), null);
  assert.equal(h.elements.serverPlayBtn.style.display, 'none');
});

test('server speech failure keeps recognition text and reports a readable status', async () => {
  const h = harness({ platform: 'Android', nativeSpeech: false });
  h.click('captureBtn'); await h.respondSpeech(false);
  await h.respond('前方有台阶。'); await h.respondSpeech(false);
  assert.equal(h.elements.resultContent.textContent, '前方有台阶。');
  assert.match(h.elements.ttsStatusElem.textContent, /服务器语音暂时无法播放/);
});

test('Android native playback failure falls back to server audio without repeating engine errors', async () => {
  const h = harness({ platform: 'Android', blocked: true, voices: [{ voiceURI: 'mandarin', lang: 'zh-CN', name: 'Chinese' }] });
  h.click('captureBtn'); h.advance(0);
  assert.equal(h.spoken.length, 1);
  assert.equal(h.speechRequests.length, 1);
  assert.equal(h.speechRequests[0].payload.text, '已拍照，正在识别路况，请稍候。');
  await h.respondSpeech();
  assert.ok(h.audio.src.startsWith('blob:'));
});
