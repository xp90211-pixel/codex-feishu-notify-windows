[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param([Parameter(Mandatory = $true)] [string] $InstallRoot)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\CodexFeishuNotify.psm1') -Force -DisableNameChecking
$settings = Get-CfnSettings $InstallRoot
$control = Get-CfnDeliveryControlState $InstallRoot $settings
if (-not $settings.FeishuEnabled -or -not $control.EffectiveActive) {
    throw '当前不允许飞书投递。请先开启两个总开关；如需在时段外测试，请明确点击“马上开始”。'
}
if ($settings.ChatId -notmatch '^oc_[A-Za-z0-9_-]{8,}$' -or $settings.ChatId -match 'REPLACE') { throw '请先配置有效的飞书会话 ID。' }
Initialize-CfnLarkProfile $settings
$cli = Find-CfnLarkCli $settings.LarkCliPath
if (-not $cli) { throw '未找到 lark-cli，请先配置程序路径。' }
if ($PSCmdlet.ShouldProcess('已配置的飞书会话', '发送一条不含任务内容的连接测试消息')) {
    $testId = Get-CfnEventId ([guid]::NewGuid().ToString('N'))
    $arguments = @('im', '+messages-send', '--as', 'bot', '--chat-id', $settings.ChatId,
        '--text', 'Codex 飞书通知连接测试：由用户手动发送，不含任务或结果内容。',
        '--idempotency-key', "cx-$testId", '--format', 'json')
    $transport = Invoke-CfnTransport $InstallRoot $cli $arguments $settings
    if ($transport.Skipped) { throw '发送前设置发生变化，测试已取消。' }
    $receipt = Test-CfnTransportOutput $transport.ExitCode $transport.Stdout
    if (-not $receipt.Success) {
        Update-CfnDeliveryResult $InstallRoot 'unconfirmed' ('test: ' + $receipt.Reason) $testId
        throw ('测试未确认成功：' + $receipt.Reason + '。没有自动重试，请先检查配置和飞书会话。')
    }
    Update-CfnDeliveryResult $InstallRoot 'sent' 'manual_test' $testId $receipt.MessageId
    Write-Output ('测试消息已确认发送，飞书回执：' + $receipt.MessageId)
}
