$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
$taskDialog = New-Object System.Windows.Forms.OpenFileDialog
$taskDialog.Title = '选择需要描述的道路图片'
$taskDialog.Filter = '图片|*.jpg;*.jpeg;*.png;*.webp;*.bmp|所有文件|*.*'
if ($taskDialog.ShowDialog() -eq 'OK') {
    & (Join-Path $PSScriptRoot '02-描述道路图片.ps1') -ImagePath $taskDialog.FileName
}
