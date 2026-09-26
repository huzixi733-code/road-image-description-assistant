# Road Image Description Assistant

面向视障用户的本地道路图片描述工具。项目使用 Ollama 运行 `qwen3-vl:8b-instruct-q4_K_M`，提供 Windows 本地/局域网 API 和手机浏览器前端。

## 功能

- 手机或电脑拍照后调用本地 Qwen3-VL 生成中文道路描述
- 优先描述近处障碍、台阶、坑洞、围挡、行人和车辆方位
- 避免无用开场、动态臆测和“道路安全”等不可靠结论
- 浏览器中文语音播报、重读、停止播报和振动反馈
- 显示完整结构化 JSON，便于复盘提示词与模型输出
- Ollama 地址、模型名称和播报速度可以在网页中修改

## 目录

```text
web/          单页网页前端及纯 PowerShell 静态服务器
windows-api/  Ollama 启动、图片描述、局域网接口和防火墙脚本
```

## 环境

- Windows 10/11
- NVIDIA GPU，项目实验设备为 RTX 5060
- Ollama Windows 独立运行文件
- 模型：`qwen3-vl:8b-instruct-q4_K_M`

模型和 Ollama 二进制文件体积约 7.5 GB，没有提交到 GitHub。将 Ollama 独立版放入：

```text
windows-api/runtime/
```

然后在 `windows-api` 中运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\01-安装并配置.ps1"
```

## 本机图片描述

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\windows-api\02-描述道路图片.ps1" -ImagePath "C:\path\road.jpg"
```

## 手机网页使用

1. 电脑和手机连接同一个可信 Wi-Fi。
2. 在 `windows-api` 中启动支持浏览器跨域访问的 API：

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File ".\03-启动局域网API.ps1" -AllowBrowserOrigins
   ```

3. 首次使用时，以管理员身份运行 `04-添加Windows防火墙规则.ps1`。
4. 双击 `web/启动前端.cmd`。
5. 手机打开启动窗口显示的 `http://电脑IP:8080/` 地址。

网页会根据访问地址自动填写 Ollama 地址。部分手机浏览器不允许普通 HTTP 页面持续访问摄像头，此时会使用系统相机拍摄入口。

## API

```text
GET  http://电脑IP:11434/api/version
GET  http://电脑IP:11434/api/tags
POST http://电脑IP:11434/api/chat
```

Ollama API 没有账号和密码。仅应在可信的专用局域网中开放，不要配置公网端口映射。

## 输出原则

模型返回包含 `image_quality`、`important_objects`、`layout`、`uncertainties` 和 `description` 的 JSON。网页向用户朗读 `description`，通常为 2 至 4 个中文短句。

项目只描述单张图片支持的静态事实，不能验证真实道路是否安全，也不能替代盲杖、导盲犬或人工判断。
