# 手机 HTTPS 访问

此目录使用 Cloudflare Quick Tunnel 为本机网页生成临时 HTTPS 地址，可绕过校园网常见的客户端隔离和受管防火墙限制。手机和电脑不必连接同一个局域网，但都需要能访问互联网。

1. 先启动 Ollama API。
2. 双击 `手机访问_启动HTTPS.cmd`。
3. 首次运行会下载 `cloudflared.exe`，并验证 Cloudflare 数字签名。
4. 在手机浏览器打开窗口显示的 `https://随机名称.trycloudflare.com` 地址。
5. 保持电脑和窗口运行。关闭窗口后临时地址失效，下次启动通常会生成不同地址。

图片和模型请求会通过 Cloudflare 加密转发到本机。临时地址不要分享给其他人。Quick Tunnel 适合实验和演示，长期部署应使用固定隧道并增加访问认证。
