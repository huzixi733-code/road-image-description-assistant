param(
    [Parameter(Mandatory=$true)]
    [string]$Server,
    [Parameter(Mandatory=$true)]
    [string]$ImagePath,
    [string]$Model = 'qwen3-vl:8b-instruct-q4_K_M'
)

$ErrorActionPreference = 'Stop'
$taskResolved = (Resolve-Path -LiteralPath $ImagePath).Path
$taskImage = [Convert]::ToBase64String([IO.File]::ReadAllBytes($taskResolved))
$taskPrompt = @'
你是面向视障用户的道路图片描述助手。直接从关键目标的位置开始，不说“这是一张图片”“这是一个街景”或“图片中有很多”。近处障碍、台阶、坑洞、围挡或被占用通道优先；随后说明人、车辆、道路、门、通道、信号灯、标志和护栏的位置与空间关系。

方位以完整原图为准，区分画面左侧/中央/右侧与道路左侧车道/右侧车道。只描述图片直接支持的静态事实。车辆和行人使用“有”“可见”“位于”等静态表达；禁止使用“行驶”“驶向”“正在”“准备”“移动”“走向”“加速”“减速”等动态词。不输出精确距离、行动意图、安全或可通行结论。

只输出中文描述文本，2至4个短句，通常60至120字；先说最有用的信息，不写标题、列表、JSON、分析过程或自报置信度。输出前静默检查动态词、无依据安全结论和方位矛盾。
'@

$taskBody = @{
    model = $Model
    stream = $false
    think = $false
    messages = @(@{
        role = 'user'
        content = $taskPrompt
        images = @($taskImage)
    })
    options = @{
        num_ctx = 6144
        num_predict = 220
        temperature = 0
        seed = 42
    }
} | ConvertTo-Json -Depth 10 -Compress

$taskBase = $Server.TrimEnd('/')
$taskResponse = Invoke-RestMethod -Method Post -Uri "$taskBase/api/chat" `
    -ContentType 'application/json; charset=utf-8' `
    -Body ([Text.Encoding]::UTF8.GetBytes($taskBody)) -TimeoutSec 900
$taskResponse.message.content.Trim()

