# Docker Web 服务

此目录只部署网页和同源 API 代理，不在容器中安装或运行 Ollama。浏览器请求 `/api/chat`、`/api/tags` 和 `/api/version` 时，`server.py` 会转发给 `OLLAMA_BASE`。

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
