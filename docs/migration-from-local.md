# 从现有本机版本迁移

本指南适用于已经存在 `Codex.LarkNotify.codex`、`lark-channel-notify/notify.ps1` 和 `drain.ps1` 的电脑。迁移期间不要让新旧两个任务同时正式发送。

## 1. 备份现状

```powershell
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = Join-Path $PWD "migration-backup-$stamp"
New-Item -ItemType Directory -Path $backup | Out-Null

Export-ScheduledTask -TaskName 'Codex.LarkNotify.codex' |
  Set-Content -LiteralPath (Join-Path $backup 'Codex.LarkNotify.codex.xml') -Encoding Unicode

Copy-Item "$env:USERPROFILE\.codex\config.toml" $backup
Copy-Item "$env:USERPROFILE\.codex\integrations\lark-channel-notify\notify.ps1" $backup
Copy-Item "$env:USERPROFILE\.codex\integrations\lark-channel-notify\drain.ps1" $backup
```

不要把这个备份目录提交 Git；它可能包含真实路径和会话标识。

## 2. 记录私有配置

从旧 `drain.ps1` 本地读取目标 `chat_id`、Lark channel home 和 profile。只在安装命令或 `settings.local.json` 中使用，不要粘贴到 Issue、PR 或 README。

## 3. 安装新版本

```powershell
pwsh -File .\scripts\Install.ps1 `
  -ChatId 'oc_YOUR_REAL_ID' `
  -LarkChannelProfile 'codex' `
  -ScheduleStart '18:40' `
  -ScheduleEnd '02:00' `
  -HolidayRegion SG
```

如果顶层 Codex 通知由其他包装器管理，而旧飞书脚本位于 `--previous-notify` 中，安装器会替换下游脚本并保留包装器。安装器不会主动启动新计划任务。

## 4. 只读检查和 dry run

```powershell
pwsh -File .\scripts\Test-Configuration.ps1
pwsh -File "$env:USERPROFILE\.codex\integrations\codex-feishu-notify\drain.ps1" -DryRun
```

确认以下项目：

- 恰好有一个 `MSFT_TaskDailyTrigger`；
- `DaysInterval=1`；
- 重复为 `PT1M / PT7H20M`；
- 启用新加坡日历时，每个未来节假日有一个 `MSFT_TaskTimeTrigger`，默认重复为 `PT1M / PT16H40M`；
- `StartWhenAvailable=False`；
- `AllowDemandStart=False`；
- `config.toml` 仍保留 PC 端需要的通知包装器；
- dry run 能找到正确的专用 Lark profile。

另请核对 `holidays.local.json` 的地区、年份和官方来源。普通周末不会因为启用节假日功能而全天运行。

## 5. 停用旧任务

完成上一步后，先进行可恢复的停用：

```powershell
Disable-ScheduledTask -TaskName 'Codex.LarkNotify.codex'
```

观察一个完整运行窗口，确认没有重复消息和漏发。需要回滚时：

```powershell
Enable-ScheduledTask -TaskName 'Codex.LarkNotify.codex'
pwsh -File .\scripts\Uninstall.ps1
```

稳定后再人工决定是否注销旧任务和归档旧目录。不要迁移旧日志；未发送队列项也应逐项检查，避免在新旧系统中重复发送。
