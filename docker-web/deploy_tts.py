"""Install the offline voice and deploy a verified bundle to the existing service.

Run over the existing SSH connection; JSON bundle is read on standard input.
Existing service environment and port are preserved. No credentials are saved.
"""
from __future__ import annotations

import base64
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time
import urllib.request

ROOT = Path('/opt/road-assistant')
MODEL_NAME = 'zh_CN-huayan-medium.onnx'
MODEL_SHA = '9929917bf8cabb26fd528ea44d3a6699c11e87317a14765312420be230be0f3d'
CONFIG_SHA = 'd521dc45504a8ccc99e325822b35946dd701840bfb07e3dbb31a40929ed6a82b'
FILES = {'server.py', 'tts_backend.py', 'requirements-tts.txt', 'web/index.html',
         'tts-models/' + MODEL_NAME, 'tts-models/' + MODEL_NAME + '.json', 'tts-models/MODEL_CARD'}


def step(message):
    print(message, flush=True)


def find_service():
    matches = []
    for proc in Path('/proc').iterdir():
        if not proc.name.isdigit():
            continue
        try:
            args = (proc / 'cmdline').read_bytes().split(b'\0')
            if str(ROOT / 'server.py').encode() in args:
                env = {}
                for item in (proc / 'environ').read_bytes().split(b'\0'):
                    if b'=' in item:
                        key, value = item.split(b'=', 1)
                        env[os.fsdecode(key)] = os.fsdecode(value)
                matches.append((int(proc.name), env, os.readlink(proc / 'exe'), os.readlink(proc / 'cwd')))
        except (FileNotFoundError, PermissionError):
            continue
    if len(matches) != 1:
        raise RuntimeError('Expected exactly one existing road assistant server process')
    return matches[0]


def request(url, payload=None, timeout=10):
    data = json.dumps(payload).encode('utf-8') if payload is not None else None
    req = urllib.request.Request(url, data=data, headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=timeout) as response:
        return response.read()


def wait_health(url, process):
    for _ in range(50):
        if process.poll() is not None:
            raise RuntimeError('Web service exited after restart')
        try:
            if json.loads(request(url + '/healthz', timeout=1)).get('status') == 'ok':
                return
        except Exception:
            time.sleep(0.2)
    raise RuntimeError('Web service did not become healthy')


def run():
    pid, env, previous_python, cwd = find_service()
    if shutil.disk_usage(ROOT).free < 512 * 1024 * 1024:
        raise RuntimeError('At least 512 MB of free project disk space is required for offline speech')
    if Path(env.get('WEB_ROOT', str(ROOT / 'web'))).resolve() != (ROOT / 'web').resolve():
        raise RuntimeError('Existing WEB_ROOT differs from the reviewed deployment target')
    port = int(env.get('PORT', '80'))
    local_url = 'http://127.0.0.1:' + str(port)
    if json.loads(request(local_url + '/healthz')).get('status') != 'ok':
        raise RuntimeError('Existing service is not healthy; keeping files unchanged')
    bundle = json.loads(sys.stdin.buffer.read())
    if set(bundle) != FILES:
        raise RuntimeError('Unexpected deployment bundle files')
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%d-%H%M%S-%f')
    stage = ROOT / ('.tts-stage-' + stamp)
    stage.mkdir()
    for name, entry in bundle.items():
        target = stage / name
        data = base64.b64decode(entry['data'], validate=True)
        if hashlib.sha256(data).hexdigest() != entry['sha256']:
            raise RuntimeError('Bundle checksum mismatch: ' + name)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    if bundle['tts-models/' + MODEL_NAME]['sha256'] != MODEL_SHA or bundle['tts-models/' + MODEL_NAME + '.json']['sha256'] != CONFIG_SHA:
        raise RuntimeError('Voice model does not match the pinned upstream checksums')
    for name in ('server.py', 'tts_backend.py'):
        compile((stage / name).read_text(encoding='utf-8'), name, 'exec')
    step('UPLOAD_VERIFIED: Preparing isolated offline speech dependencies')
    venv = ROOT / '.tts-venv'
    if not (venv / 'bin/python').is_file() or not (venv / 'bin/pip').is_file():
        try:
            subprocess.run([previous_python, '-m', 'venv', str(venv)], check=True, timeout=120)
        except subprocess.CalledProcessError:
            subprocess.run(['apt-get', 'update'], check=True, timeout=300)
            subprocess.run(['apt-get', 'install', '-y', 'python3-venv'], check=True, timeout=300)
            subprocess.run([previous_python, '-m', 'venv', str(venv)], check=True, timeout=120)
    python = str(venv / 'bin/python')
    subprocess.run([python, '-m', 'pip', 'install', '--disable-pip-version-check',
                    '--index-url', 'https://pypi.org/simple', '-r', str(stage / 'requirements-tts.txt')],
                   check=True, timeout=600)
    model_dir = ROOT / 'tts-models'
    model_dir.mkdir(exist_ok=True)
    for name in (MODEL_NAME, MODEL_NAME + '.json', 'MODEL_CARD'):
        shutil.copy2(stage / 'tts-models' / name, model_dir / name)
    # Test real synthesis before replacing any live frontend/server files.
    smoke = ('import sys;sys.path.insert(0,sys.argv[1]);from tts_backend import PiperSpeech;'
             'data=PiperSpeech(sys.argv[2]).synthesize("中文语音服务已准备好。",1.0);'
             'assert data[:4]==b"RIFF" and len(data)>1000;print("OFFLINE_VOICE_VERIFIED",len(data),flush=True)')
    subprocess.run([python, '-c', smoke, str(stage), str(model_dir / MODEL_NAME)], check=True, timeout=120)
    backup = ROOT / ('tts-deploy-backup-' + stamp)
    backup.mkdir()
    live_files = ('server.py', 'tts_backend.py', 'requirements-tts.txt', 'web/index.html')
    old_files = []
    for name in live_files:
        target = ROOT / name
        if target.is_symlink():
            raise RuntimeError('Refusing to replace symlink: ' + name)
        if target.is_file():
            saved = backup / name
            saved.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(target, saved)
            old_files.append(name)
    step('BACKUP=' + str(backup))
    new_process = None
    terminated = False
    old_stopped = False
    try:
        for name in live_files:
            target = ROOT / name
            staged = stage / name
            os.chmod(staged, 0o644)
            os.replace(staged, target)
        os.kill(pid, signal.SIGTERM)
        terminated = True
        for _ in range(50):
            try:
                os.kill(pid, 0)
                if (Path('/proc') / str(pid) / 'stat').read_text().split()[2] == 'Z':
                    break
            except ProcessLookupError:
                break
            except FileNotFoundError:
                break
            time.sleep(0.1)
        else:
            raise RuntimeError('Old service did not stop; refusing a second server')
        old_stopped = True
        # Keep all existing environment values, including PORT, WEB_ROOT and OLLAMA_BASE.
        with (ROOT / 'tts-web.log').open('ab') as log:
            new_process = subprocess.Popen([python, str(ROOT / 'server.py')], cwd=cwd, env=env,
                                           stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
        wait_health(local_url, new_process)
        if not json.loads(request(local_url + '/api/tts/status')).get('available'):
            raise RuntimeError('New voice endpoint is not ready')
        audio = request(local_url + '/api/tts', {'text': '服务器中文语音测试成功。', 'rate': 1.0}, timeout=90)
        if audio[:4] != b'RIFF' or len(audio) <= 1000:
            raise RuntimeError('New voice endpoint returned invalid audio')
        expected = bundle['web/index.html']['sha256']
        for suffix in ('/', '/index.html'):
            if hashlib.sha256(request(local_url + suffix)).hexdigest() != expected:
                raise RuntimeError('Live frontend checksum mismatch')
        # Verify that the same Ollama connection still returns the configured model list.
        if not isinstance(json.loads(request(local_url + '/api/tags')).get('models'), list):
            raise RuntimeError('Existing model connection is not healthy')
        step('DEPLOYED_SHA256=' + expected)
        step('OFFLINE_TTS_BYTES=' + str(len(audio)))
        step('SUCCESS: Existing URL, port and model connection preserved; offline speech ready')
    except Exception:
        if new_process and new_process.poll() is None:
            new_process.terminate()
            try:
                new_process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                raise RuntimeError('Could not stop failed new server; backup retained at ' + str(backup))
        for name in old_files:
            shutil.copy2(backup / name, ROOT / name)
        if terminated and old_stopped:
            with (ROOT / 'tts-web.log').open('ab') as log:
                subprocess.Popen([previous_python, str(ROOT / 'server.py')], cwd=cwd, env=env,
                                 stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
        step('ROLLBACK: Previous files restored from ' + str(backup))
        raise


if __name__ == '__main__':
    run()
