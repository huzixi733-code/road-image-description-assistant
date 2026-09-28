"""Local Mandarin audio generation; no speech text is sent to other services."""
from __future__ import annotations

import hashlib
import importlib.util
import io
import math
import re
import threading
import wave
from collections import OrderedDict
from pathlib import Path

MAX_TEXT_LENGTH = 1000
MAX_CACHE_BYTES = 16 * 1024 * 1024


def validate_request(payload):
    if not isinstance(payload, dict):
        raise ValueError("请求必须是JSON对象。")
    text = payload.get("text")
    if not isinstance(text, str) or not text.strip() or len(text) > MAX_TEXT_LENGTH:
        raise ValueError("语音文字不能为空，且不能超过1000字。")
    rate = payload.get("rate", 1.0)
    if isinstance(rate, bool) or not isinstance(rate, (int, float)) or not math.isfinite(rate) or not 0.6 <= rate <= 1.6:
        raise ValueError("语速必须在0.6至1.6之间。")
    # Do not expose Piper's raw phoneme syntax through a public text endpoint.
    text = re.sub(r"[\x00-\x1f\x7f\[\]]", " ", text).strip()
    if not text:
        raise ValueError("语音文字无效。")
    return text, round(float(rate), 2)


def silence_wav():
    output = io.BytesIO()
    with wave.open(output, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(8000)
        wav.writeframes(b"\0" * 1600)
    return output.getvalue()


class SpeechUnavailable(Exception):
    pass


class SpeechBusy(Exception):
    pass


class PiperSpeech:
    def __init__(self, model_path):
        self.model_path = Path(model_path)
        self._voice = None
        self._lock = threading.Lock()
        self._cache = OrderedDict()
        self._cache_bytes = 0

    def available(self):
        return (self.model_path.is_file()
                and Path(str(self.model_path) + ".json").is_file()
                and importlib.util.find_spec("piper") is not None)

    def synthesize(self, text, rate):
        if not self.available():
            raise SpeechUnavailable("服务器中文语音尚未安装完成。")
        if not self._lock.acquire(timeout=2):
            raise SpeechBusy("语音服务正在处理其他请求，请稍后重试。")
        try:
            key = hashlib.sha256((str(rate) + "\0" + text).encode("utf-8")).digest()
            if key in self._cache:
                self._cache.move_to_end(key)
                return self._cache[key]
            from piper import PiperVoice, SynthesisConfig
            if self._voice is None:
                self._voice = PiperVoice.load(str(self.model_path), use_cuda=False)
            output = io.BytesIO()
            with wave.open(output, "wb") as wav:
                self._voice.synthesize_wav(text, wav, syn_config=SynthesisConfig(length_scale=1.0 / rate))
            data = output.getvalue()
            if len(data) <= 44 or data[:4] != b"RIFF" or data[8:12] != b"WAVE":
                raise SpeechUnavailable("语音生成未返回有效音频。")
            if len(data) <= MAX_CACHE_BYTES:
                self._cache[key] = data
                self._cache_bytes += len(data)
                while self._cache_bytes > MAX_CACHE_BYTES or len(self._cache) > 32:
                    _, discarded = self._cache.popitem(last=False)
                    self._cache_bytes -= len(discarded)
            return data
        finally:
            self._lock.release()
