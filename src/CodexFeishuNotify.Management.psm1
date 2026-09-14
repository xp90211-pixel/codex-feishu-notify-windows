Set-StrictMode -Version 2.0

function Read-CfnUtf8File {
    param([Parameter(Mandatory = $true)] [string] $Path)
    # Throw on invalid UTF-8 instead of permanently writing replacement characters.
    $encoding = New-Object System.Text.UTF8Encoding($false, $true)
    return [IO.File]::ReadAllText($Path, $encoding)
}

function Assert-CfnTomlComplete {
    param([string] $Text)
    # Tommy accepts EOF inside an unfinished array; require lexical closure
    # before parsing. Syntax/type validation still belongs to the TOML parser.
    $stack = New-Object System.Collections.Generic.Stack[char]
    $quote = [char]0
    $multiline = $false
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        if ($quote -ne [char]0) {
            if ($quote -eq [char]34 -and $ch -eq [char]92) { $i++; continue }
            if ($ch -eq $quote) {
                if (-not $multiline) { $quote = [char]0 }
                elseif ($i + 2 -lt $Text.Length -and $Text[$i + 1] -eq $quote -and $Text[$i + 2] -eq $quote) {
                    $i += 2
                    # TOML permits one or two literal quotes adjacent to closure.
                    for ($extra = 0; $extra -lt 2 -and $i + 1 -lt $Text.Length -and $Text[$i + 1] -eq $quote; $extra++) { $i++ }
                    $quote = [char]0
                }
            } elseif (-not $multiline -and $ch -in @([char]10, [char]13)) { throw 'Unterminated TOML string.' }
            continue
        }
        if ($ch -eq '#') {
            while ($i -lt $Text.Length -and $Text[$i] -ne [char]10) { $i++ }
            continue
        }
        if ($ch -in @([char]34, [char]39)) {
            $quote = $ch
            $multiline = $i + 2 -lt $Text.Length -and $Text[$i + 1] -eq $ch -and $Text[$i + 2] -eq $ch
            if ($multiline) { $i += 2 }
        } elseif ($ch -in @('[', '{')) { $stack.Push($ch) }
        elseif ($ch -in @(']', '}')) {
            if ($stack.Count -eq 0) { throw 'Unbalanced TOML container.' }
            $opening = $stack.Pop()
            if (($ch -eq ']' -and $opening -ne '[') -or ($ch -eq '}' -and $opening -ne '{')) { throw 'Mismatched TOML container.' }
        }
    }
    if ($quote -ne [char]0 -or $stack.Count -ne 0) { throw 'Incomplete TOML string or container; nothing was changed.' }
}

function ConvertFrom-CfnToml {
    param([AllowEmptyString()] [string] $Text)
    if (-not ('Tommy.TOML' -as [type])) {
        $library = Join-Path $PSScriptRoot 'vendor\Tommy.dll'
        if ((Get-FileHash -LiteralPath $library -Algorithm SHA256).Hash -ne '2684B7EAACA463DDB08E8BF55F12B0D8BF0B02EE868CF6A7B0D3C42B4B53003D') {
            throw 'TOML parser checksum mismatch.'
        }
        Add-Type -Path $library
    }
    Assert-CfnTomlComplete $Text
    $reader = New-Object IO.StringReader(,[string]$Text)
    try { return ,([Tommy.TOML]::Parse($reader)) }
    catch { throw 'Invalid or unsupported TOML. Configuration was not changed; repair it before installing.' }
    finally { $reader.Dispose() }
}

function ConvertFrom-CfnNotifyLine {
    param([Parameter(Mandatory = $true)] [string] $Line)
    $document = ConvertFrom-CfnToml $Line
    if (-not $document.HasKey('notify') -or -not $document['notify'].IsArray) { throw 'Root notify must be a TOML string array.' }
    $values = New-Object System.Collections.Generic.List[string]
    foreach ($child in $document['notify'].AsArray.Children) {
        if (-not $child.IsString) { throw 'Every notify command argument must be a string.' }
        $values.Add($child.AsString.Value)
    }
    return $values.ToArray()
}

function Get-CfnNotifyRecord {
    param([AllowEmptyString()] [string] $Text)
    $document = ConvertFrom-CfnToml $Text
    if (-not $document.HasKey('notify')) { return [pscustomobject]@{ Found = $false; Line = ''; Match = $null } }

    # Locate a whole assignment without serializing unrelated TOML. A parsed
    # probe proves it is the root node, not a table key or text inside a string.
    $probe = 'CFN-' + [guid]::NewGuid().ToString('N')
    $pattern = '(?m)^[ \t]*(?:notify|"notify"|''notify'')[ \t]*='
    foreach ($candidate in [regex]::Matches($Text, $pattern)) {
        $end = $candidate.Index
        while ($end -lt $Text.Length) {
            $newline = $Text.IndexOf("`n", $end)
            $end = if ($newline -lt 0) { $Text.Length } else { $newline + 1 }
            $segment = $Text.Substring($candidate.Index, $end - $candidate.Index)
            try { $part = ConvertFrom-CfnToml $segment } catch { if ($end -eq $Text.Length) { break }; continue }
            if (-not $part.HasKey('notify')) { break }
            $ending = if ($segment.EndsWith("`r`n")) { "`r`n" } elseif ($segment.EndsWith("`n")) { "`n" } else { '' }
            $line = $segment.Substring(0, $segment.Length - $ending.Length)
            $test = $Text.Substring(0, $candidate.Index) + 'notify = ["' + $probe + '"]' + $ending + $Text.Substring($end)
            try {
                $parsed = ConvertFrom-CfnToml $test
                if ($parsed['notify'].IsArray -and $parsed['notify'].ChildrenCount -eq 1 -and
                    $parsed['notify'][0].IsString -and $parsed['notify'][0].AsString.Value -ceq $probe) {
                    return [pscustomobject]@{
                        Found = $true; Line = $line
                        Match = [pscustomobject]@{ Index = $candidate.Index; Length = $segment.Length; Groups = @{ ending = @{ Value = $ending } } }
                    }
                }
            } catch {}
            break
        }
    }
    throw 'The root notify node uses an unsupported form; no automatic replacement is safe.'
}

function Set-CfnNotifyLine {
    param([AllowEmptyString()] [string] $Text, [AllowEmptyString()] [string] $NewLine)
    $record = Get-CfnNotifyRecord $Text
    if ($record.Found) {
        $replacement = if ($NewLine) { $NewLine + $record.Match.Groups['ending'].Value } else { '' }
        $result = $Text.Substring(0, $record.Match.Index) + $replacement + $Text.Substring($record.Match.Index + $record.Match.Length)
    } elseif ($NewLine) {
        # Before every table, including when the file ends in [features].
        $result = $NewLine + [Environment]::NewLine + $Text
    } else { $result = $Text }
    $parsed = ConvertFrom-CfnToml $result
    if ($NewLine) {
        $expected = @(ConvertFrom-CfnNotifyLine $NewLine)
        $actual = @($parsed['notify'].Children | ForEach-Object { $_.AsString.Value })
        if (($expected | ConvertTo-Json -Compress) -cne ($actual | ConvertTo-Json -Compress)) { throw 'Root notify verification failed.' }
    } elseif ($parsed.HasKey('notify')) { throw 'Root notify removal failed.' }
    return $result
}

function Merge-CfnObject {
    param([Parameter(Mandatory = $true)] $Defaults, [AllowNull()] $Existing)
    if ($null -eq $Existing) { return }
    foreach ($property in @($Existing.PSObject.Properties)) {
        if ($null -eq $property) { continue }
        $target = $Defaults.PSObject.Properties[$property.Name]
        if ($null -ne $target -and $target.Value -is [pscustomobject] -and $property.Value -is [pscustomobject]) {
            Merge-CfnObject $target.Value $property.Value
        } else { $Defaults | Add-Member NoteProperty $property.Name $property.Value -Force }
    }
}

function Test-CfnTaskOwnership {
    param([AllowNull()] $Task, [Parameter(Mandatory = $true)] [string] $InstallRoot)
    if ($null -eq $Task) { return $false }
    $actions = @($Task.Actions)
    if ($actions.Count -ne 1) { return $false }
    $match = [regex]::Match([string]$actions[0].Arguments, '(?i)(?:^|\s)-File\s+(?:"(?<path>[^"]+)"|(?<path>\S+))(?:\s|$)')
    if (-not $match.Success) { return $false }
    return [IO.Path]::GetFullPath($match.Groups['path'].Value) -ieq [IO.Path]::GetFullPath((Join-Path $InstallRoot 'drain.ps1'))
}

function Get-CfnSchedulePlan {
    param([string] $Start, [string] $End, [int] $IntervalMinutes, [string[]] $AllDayWeekdays = @(), $Calendar = $null, [datetime] $Today = [datetime]::Today)
    $window = Get-CfnScheduleWindow $Start $End
    if ($window.Duration.TotalMinutes -lt $IntervalMinutes) { throw 'Repetition interval exceeds the daily window.' }
    $plan = New-Object System.Collections.Generic.List[object]
    $plan.Add([pscustomobject]@{ Kind = 'Daily'; Start = $Today.Add($window.StartTime); Duration = $window.IsoDuration; Interval = "PT${IntervalMinutes}M"; Weekdays = @() })
    if (@($AllDayWeekdays).Count -gt 0) {
        foreach ($gap in @(Get-CfnHolidayGapWindows $Today $Start $End)) {
            if ($gap.Duration.TotalMinutes -ge $IntervalMinutes) {
                $plan.Add([pscustomobject]@{ Kind = 'Weekly'; Start = $gap.Start; Duration = $gap.IsoDuration; Interval = "PT${IntervalMinutes}M"; Weekdays = @($AllDayWeekdays) })
            }
        }
    }
    if ($null -ne $Calendar) {
        foreach ($day in @($Calendar.Holidays | Where-Object { $_.Date -ge $Today.Date -and $AllDayWeekdays -notcontains $_.Date.DayOfWeek.ToString() })) {
            foreach ($gap in @(Get-CfnHolidayGapWindows $day.Date $Start $End)) {
                if ($gap.Duration.TotalMinutes -ge $IntervalMinutes) {
                    $plan.Add([pscustomobject]@{ Kind = 'Once'; Start = $gap.Start; Duration = $gap.IsoDuration; Interval = "PT${IntervalMinutes}M"; Weekdays = @() })
                }
            }
        }
    }
    if ($plan.Count -gt 47) { throw "The schedule requires $($plan.Count) persistent triggers; at most 47 are supported. Shorten the calendar range." }
    return $plan.ToArray()
}

function New-CfnScheduledTriggers {
    param([object[]] $Plan)
    foreach ($entry in $Plan) {
        $trigger = switch ($entry.Kind) {
            'Daily' { New-ScheduledTaskTrigger -Daily -At $entry.Start }
            'Weekly' { New-ScheduledTaskTrigger -Weekly -WeeksInterval 1 -DaysOfWeek $entry.Weekdays -At $entry.Start }
            'Once' { New-ScheduledTaskTrigger -Once -At $entry.Start }
        }
        $trigger.Repetition = New-CimInstance -ClassName MSFT_TaskRepetitionPattern -Namespace 'Root/Microsoft/Windows/TaskScheduler' -ClientOnly -Property @{
            Interval = $entry.Interval; Duration = $entry.Duration; StopAtDurationEnd = $true
        }
        $trigger
    }
}

function Test-CfnScheduleTriggers {
    param($Task, [object[]] $Plan, [datetime] $Today = [datetime]::Today)
    $maskValues = @{ Sunday = 1; Monday = 2; Tuesday = 4; Wednesday = 8; Thursday = 16; Friday = 32; Saturday = 64 }
    $expected = @($Plan | ForEach-Object {
        $mask = 0; foreach ($day in $_.Weekdays) { $mask += $maskValues[$day] }
        $start = if ($_.Kind -eq 'Once') { $_.Start.ToString('yyyy-MM-dd HH:mm:ss') } else { $_.Start.ToString('HH:mm:ss') }
        '{0}|{1}|{2}|{3}|{4}' -f $_.Kind, $start, $_.Interval, $_.Duration, $mask
    } | Sort-Object)
    $actual = @($Task.Triggers | ForEach-Object {
        if ([string]$_.Id -eq 'CodexFeishuNotify.ManualOverride') { return }
        $startDate = [datetime]$_.StartBoundary
        $trigger = $_
        $kind = switch ($trigger.CimClass.CimClassName) {
            'MSFT_TaskDailyTrigger' { if ($trigger.DaysInterval -ne 1) { 'Invalid' } else { 'Daily' } }
            'MSFT_TaskWeeklyTrigger' { if ($trigger.WeeksInterval -ne 1) { 'Invalid' } else { 'Weekly' } }
            'MSFT_TaskTimeTrigger' { 'Once' }
            default { 'Invalid' }
        }
        if ($kind -eq 'Once' -and $startDate.Date -lt $Today.Date) { return }
        if (-not $_.Enabled -or -not $_.Repetition.StopAtDurationEnd) { $kind = 'Invalid' }
        $mask = if ($kind -eq 'Weekly') { [int]$_.DaysOfWeek } else { 0 }
        $start = if ($kind -eq 'Once') { $startDate.ToString('yyyy-MM-dd HH:mm:ss') } else { $startDate.ToString('HH:mm:ss') }
        '{0}|{1}|{2}|{3}|{4}' -f $kind, $start, $_.Repetition.Interval, $_.Repetition.Duration, $mask
    } | Sort-Object)
    return ($expected -join ';') -ceq ($actual -join ';')
}

Export-ModuleMember -Function Read-CfnUtf8File, ConvertFrom-CfnToml, ConvertFrom-CfnNotifyLine, Get-CfnNotifyRecord, Set-CfnNotifyLine, Merge-CfnObject, Test-CfnTaskOwnership, Get-CfnSchedulePlan, New-CfnScheduledTriggers, Test-CfnScheduleTriggers
