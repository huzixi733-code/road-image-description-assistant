import http.client
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch
import wave

SERVER_DIR = Path(__file__).resolve().parents[1] / 'docker-web'
sys.path.insert(0, str(SERVER_DIR))
import server
from tts_backend import PiperSpeech, SpeechUnavailable, silence_wav, validate_request


class FakeSpeech:
    def available(self):
        return True

    def synthesize(self, text, rate):
        return silence_wav()


class SpeechHTTPTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        Path(cls.directory.name, 'index.html').write_text('<html>reviewed page</html>', encoding='utf-8')
        cls.old_root = server.WEB_ROOT
        cls.old_speech = server.SPEECH
        server.WEB_ROOT = cls.directory.name
        server.SPEECH = FakeSpeech()
        cls.http = server.ThreadingHTTPServer(('127.0.0.1', 0), server.RoadAssistantHandler)
        cls.thread = threading.Thread(target=cls.http.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.http.shutdown()
        cls.http.server_close()
        cls.thread.join()
        server.WEB_ROOT = cls.old_root
        server.SPEECH = cls.old_speech
        cls.directory.cleanup()

    def request(self, method, path, payload=None):
        connection = http.client.HTTPConnection(*self.http.server_address, timeout=5)
        body = json.dumps(payload).encode('utf-8') if payload is not None else None
        connection.request(method, path, body=body, headers={'Content-Type': 'application/json'})
        response = connection.getresponse()
        result = response.status, dict(response.getheaders()), response.read()
        connection.close()
        return result

    def test_same_origin_audio_and_status(self):
        status, _, body = self.request('GET', '/api/tts/status')
        self.assertEqual(status, 200)
        self.assertTrue(json.loads(body)['available'])
        status, headers, body = self.request('POST', '/api/tts', {'text': '前方有护栏。', 'rate': 1.15})
        self.assertEqual(status, 200)
        self.assertEqual(headers['Content-Type'], 'audio/wav')
        self.assertEqual(headers['Cache-Control'], 'no-store')
        with wave.open(io.BytesIO(body)) as wav:
            self.assertGreater(wav.getnframes(), 0)

    def test_silent_unlock_audio_does_not_need_model(self):
        status, headers, body = self.request('GET', '/api/tts/silence.wav')
        self.assertEqual(status, 200)
        self.assertEqual(headers['Content-Type'], 'audio/wav')
        self.assertEqual(body[:4], b'RIFF')

    def test_invalid_requests_are_rejected(self):
        for payload in [[], {}, {'text': ''}, {'text': 'x' * 1001}, {'text': '道路', 'rate': True}, {'text': '道路', 'rate': float('nan')}, {'text': '道路', 'rate': 8}]:
            with self.subTest(payload=payload):
                self.assertEqual(self.request('POST', '/api/tts', payload)[0], 400)
        self.assertEqual(self.request('POST', '/api/tts', {'text': 'x' * 13000})[0], 413)

    def test_missing_engine_does_not_break_existing_page_or_health(self):
        with patch.object(server.SPEECH, 'synthesize', side_effect=SpeechUnavailable('not ready')):
            self.assertEqual(self.request('POST', '/api/tts', {'text': '道路'})[0], 503)
        self.assertEqual(self.request('GET', '/healthz')[0], 200)
        status, headers, body = self.request('GET', '/')
        self.assertEqual(status, 200)
        self.assertIn('no-store', headers['Cache-Control'])
        self.assertIn(b'reviewed page', body)

    def test_model_management_still_not_exposed(self):
        self.assertEqual(self.request('POST', '/api/pull', {'model': 'anything'})[0], 404)


class SpeechBackendTests(unittest.TestCase):
    def test_rate_and_phoneme_input_validation(self):
        self.assertEqual(validate_request({'text': '前方[[道路]]', 'rate': 1.151}), ('前方  道路', 1.15))

    def test_model_is_reused_and_wav_cached_without_external_network(self):
        class Voice:
            def synthesize_wav(self, text, wav, syn_config):
                wav.setnchannels(1)
                wav.setsampwidth(2)
                wav.setframerate(22050)
                wav.writeframes(b'\0' * 200)
        class PiperVoice:
            loads = 0
            @classmethod
            def load(cls, *args, **kwargs):
                cls.loads += 1
                return Voice()
        class SynthesisConfig:
            def __init__(self, **kwargs):
                self.kwargs = kwargs
        import types
        fake_piper = types.SimpleNamespace(PiperVoice=PiperVoice, SynthesisConfig=SynthesisConfig)
        engine = PiperSpeech('unused-model')
        with patch.object(engine, 'available', return_value=True), patch.dict(sys.modules, {'piper': fake_piper}):
            first = engine.synthesize('前方有护栏。', 1.0)
            self.assertEqual(engine.synthesize('前方有护栏。', 1.0), first)
            engine.synthesize('右侧有车辆。', 1.15)
            self.assertEqual(PiperVoice.loads, 1)


if __name__ == '__main__':
    unittest.main()
