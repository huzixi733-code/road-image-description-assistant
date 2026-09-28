# Docker Web 服务

此目录部署网页、同源 API 代理和可选的离线中文语音，不在容器中安装或运行 Ollama。浏览器请求 `/api/chat`、`/api/tags` 和 `/api/version` 时，`server.py` 会转发给 `OLLAMA_BASE`。

代理只允许 `GET /api/tags`、`GET /api/version` 和 `POST /api/chat`，不会公开 Ollama 的模型管理接口。

## 启动

容器需要 Python 3。假设 Docker 将宿主机 `8880` 映射到容器 `80`，并且模型电脑在 WireGuard 中的地址为 `10.0.0.102`：

```bash
cd /opt/road-assistant
OLLAMA_BASE=http://10.0.0.102:11434 PORT=80 \
  nohup ./docker-web/start.sh >web.log 2>&1 </dev/null &
```

浏览器访问：

```text
http://服务器地址:8880/
```

## 验证

```bash
curl http://127.0.0.1/healthz
curl http://127.0.0.1/api/version
curl http://127.0.0.1/api/tags
```

`/healthz` 只检查 Web 服务；另外两个接口能返回数据才表示容器已连通外部 Ollama。

可用环境变量：

- `WEB_ROOT`：静态网页目录，默认使用仓库中的 `web/`
- `OLLAMA_BASE`：外部 Ollama 根地址
- `PORT`：容器内 Web 监听端口，默认 `80`

服务会拒绝超过 25 MB 的请求。生产环境应由 Docker、Supervisor 或其他进程管理器负责自动重启。

## 安卓中文语音兜底

当浏览器没有网页语音接口或未提供中文音色时，前端使用同源 `POST /api/tts` 获取 WAV 音频；iOS 默认沿用系统语音。设置中也可以手动选择“中文普通话（服务器音频）”。服务器音频支持语速，音高固定。如果浏览器阻止自动播放，点击页面上的“点击播放语音”即可直接播放已生成音频，不会再次识别照片。

语音使用 `piper-tts==1.8.0`，依赖安装在项目 `.tts-venv` 中；中文音色位于 `tts-models/zh_CN-huayan-medium.onnx` 及其 `.json` 配置。语音文字在本机处理，不会提交到云端语音平台。首次加载模型较慢，后续复用同一模型，并在内存中缓存有限数量的音频。

首次在新的仓库检出中安装，可在项目根目录运行：

```bash
python3 -m venv .tts-venv
.tts-venv/bin/python -m pip install -r docker-web/requirements-tts.txt
mkdir -p tts-models
.tts-venv/bin/python -m piper.download_voices zh_CN-huayan-medium --data-dir tts-models
```

然后使用原有 `docker-web/start.sh` 启动。它会优先使用隔离的语音 Python 环境；没有安装语音依赖时，仍可启动原有网页和模型代理。维护者的部署工具使用固定版本并验证模型校验值，模型安装位置不在公开的 `web/` 目录内。

新增接口：`GET /api/tts/status` 检查可用性，`GET /api/tts/silence.wav` 提供点击时的静音音频准备，`POST /api/tts` 接受 `{"text":"前方有护栏。","rate":1.0}`，返回 `audio/wav`。文字上限1000字，语速范围0.6至1.6；音频不使用浏览器缓存。接口不会暴露模型管理功能，也不会接受外部URL或命令。

`deploy_tts.py` 验证部署包和固定语音模型的校验值，在替换当前服务之前安装隔离依赖并实际生成测试音频。随后备份当前文件，保留运行进程的 `WEB_ROOT`、`PORT`、`OLLAMA_BASE` 等环境并重启服务；验证失败时恢复原文件。声学模型来源及许可说明保存在模型目录的 `MODEL_CARD`，模型权重不纳入 Git 仓库。

可选 `TTS_MODEL` 环境变量仅用于指定本地语音模型路径。现有安装将文件放在 `server.py` 同目录的 `tts-models/` 下即可，不需要增加监听端口或改动原有 IP。
