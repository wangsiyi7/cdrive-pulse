#requires -Version 5.1
<#
.SYNOPSIS
    cdrive-pulse（C盘脉搏）— Windows C 盘空间监测与安全清理工具
.DESCRIPTION
    纯 PowerShell 5.1+，零第三方依赖，开箱即用。
    四个命令：
      scan    测量 C 盘容量 + 按 rules.json 逐条测量目录大小，生成 out\scan-latest.json 与 out\report-latest.md
      clean   清理 action=delete 的规则目录（默认干跑 -WhatIf，加 -Execute 才真正删除）
      report  对比两次扫描结果：.\cpulse.ps1 report <旧scan.json> <新scan.json>
      rules   列出当前规则库
.NOTES
    清理安全铁律：
      1. 干跑是默认行为，必须显式 -Execute 才删除
      2. 删除前验证路径存在且不是符号链接 / Junction（链接一律跳过并警告）
      3. 占用 / 拒绝访问的文件跳过并计数，绝不强杀进程
      4. 删除前后各测一次大小，输出释放统计，全程写日志
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command = "help",
    [Parameter(Position = 1)][string]$Arg1,
    [Parameter(Position = 2)][string]$Arg2,
    [switch]$WhatIf,    # 显式干跑（clean 的默认行为，写出来仅为了语义清晰）
    [switch]$Execute    # 真正执行删除
)

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RulesFile  = Join-Path $ScriptRoot "rules.json"
$OutDir     = Join-Path $ScriptRoot "out"

# 四象限分类展示名
$CategoryNames = @{
    safeCache = "安全缓存（可放心清理）"
    caution   = "谨慎区域（需人工确认）"
    system    = "系统区域（勿手动删除）"
    migrate   = "建议迁移（挪到其他盘）"
}
$CategoryOrder = @("safeCache", "caution", "system", "migrate")

function Ensure-OutDir {
    if (-not (Test-Path -LiteralPath $OutDir)) {
        New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    }
}

# 读取规则库（UTF-8）
function Get-Rules {
    if (-not (Test-Path -LiteralPath $RulesFile)) {
        Write-Error "未找到规则库文件: $RulesFile"
        exit 1
    }
    $raw = Get-Content -LiteralPath $RulesFile -Raw -Encoding UTF8
    # 注意：PS 5.1 的 ConvertFrom-Json 把整个 JSON 数组作为“单个对象”输出，
    # 必须先接进变量再用 @() 展开，否则下游 Where-Object / foreach 会把全部规则当成一条
    $parsed = $raw | ConvertFrom-Json
    return @($parsed)
}

# 展开 %USERPROFILE% / %LOCALAPPDATA% 等环境变量
function Expand-RulePath([string]$Path) {
    return [Environment]::ExpandEnvironmentVariables($Path)
}

# 用 robocopy /L（仅列举不落盘）测量目录字节数；/XJ 排除联接点，防 junction 循环；速度快
function Measure-DirectorySize([string]$LiteralPath) {
    if (-not (Test-Path -LiteralPath $LiteralPath)) { return [int64]0 }
    $output = & robocopy.exe "$LiteralPath" "NULL" /L /S /BYTES /XJ /NJH /NFL /NDL /NP /R:0 /W:0 2>$null
    # 汇总行形如：  Bytes :   12345678        0  ...，取 Total 列（第一个数字）
    foreach ($line in $output) {
        if ($line -match '^\s*Bytes\s*:\s*(\d+)') {
            return [int64]::Parse($Matches[1])
        }
    }
    return [int64]0
}

function ConvertTo-GB([int64]$Bytes) {
    return [math]::Round($Bytes / 1GB, 2)
}

# 读取规则的可选扩展字段（maxAgeDays / keepFiles / keepLatestSubdir）
function Get-RuleProp($Rule, [string]$Name) {
    $p = $Rule.PSObject.Properties[$Name]
    if ($null -ne $p) { return $p.Value }
    return $null
}

# 解析规则路径（支持 * 通配），返回当前存在的目标目录列表
function Resolve-RuleTargets($Rule) {
    $expanded = Expand-RulePath $Rule.path
    if ($expanded.Contains('*')) {
        $parent = Split-Path $expanded -Parent
        $leaf   = Split-Path $expanded -Leaf
        if (Test-Path -LiteralPath $parent) {
            return @(Get-ChildItem -LiteralPath $parent -Directory -Filter $leaf -Force -ErrorAction SilentlyContinue |
                     ForEach-Object { $_.FullName })
        }
        return @()
    }
    if (Test-Path -LiteralPath $expanded) { return @($expanded) }
    return @()
}

# 安全校验：路径必须存在，且不是符号链接 / Junction（铁律 2）
function Test-TargetSafe([string]$LiteralPath, [ref]$Reason) {
    if (-not (Test-Path -LiteralPath $LiteralPath)) {
        $Reason.Value = "路径不存在"
        return $false
    }
    $item = Get-Item -LiteralPath $LiteralPath -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        $Reason.Value = "无法读取路径信息"
        return $false
    }
    if ($item.LinkType) {
        $Reason.Value = "是 $($item.LinkType) 链接，按安全铁律跳过"
        return $false
    }
    return $true
}

# 获取 C 盘容量信息（优先 WMI/CIM，回退 Get-PSDrive）
function Get-DriveInfo {
    $total = [int64]0; $free = [int64]0
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction SilentlyContinue
    if ($disk) {
        $total = [int64]$disk.Size
        $free  = [int64]$disk.FreeSpace
    } else {
        $d = Get-PSDrive C -ErrorAction SilentlyContinue
        if ($d) {
            $free  = [int64]$d.Free
            $total = $free + [int64]$d.Used
        }
    }
    $used = $total - $free
    $pct = 0
    if ($total -gt 0) { $pct = [math]::Round($used * 100.0 / $total, 1) }
    return [ordered]@{
        totalGB = ConvertTo-GB $total
        usedGB  = ConvertTo-GB $used
        freeGB  = ConvertTo-GB $free
        percent = $pct
    }
}

# ============================ scan ============================
function Build-ScanMarkdown($Scan) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("# C盘脉搏 扫描报告")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("- 生成时间: $($Scan.generatedAt)")
    [void]$sb.AppendLine("- C 盘总量: $($Scan.drive.totalGB) GB")
    [void]$sb.AppendLine("- 已用: $($Scan.drive.usedGB) GB（$($Scan.drive.percent)%）")
    [void]$sb.AppendLine("- 可用: $($Scan.drive.freeGB) GB")
    [void]$sb.AppendLine("")
    foreach ($cat in $CategoryOrder) {
        $items = @($Scan.groups | Where-Object { $_.category -eq $cat } | Sort-Object sizeGB -Descending)
        if ($items.Count -eq 0) { continue }
        $sum = ($items | Measure-Object -Property sizeGB -Sum).Sum
        [void]$sb.AppendLine("## $($CategoryNames[$cat])（合计 $([math]::Round($sum, 2)) GB）")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("| 名称 | 路径模板 | 大小 (GB) | 存在 | 说明 |")
        [void]$sb.AppendLine("| --- | --- | ---: | :---: | --- |")
        foreach ($g in $items) {
            $mark = "—"; if ($g.exists) { $mark = "✓" }
            [void]$sb.AppendLine("| $($g.name) | ``$($g.path)`` | $($g.sizeGB) | $mark | $($g.note) |")
        }
        [void]$sb.AppendLine("")
    }
    [void]$sb.AppendLine("> 由 cdrive-pulse 生成；路径使用环境变量模板，不含个人信息。")
    return $sb.ToString()
}

function Invoke-Scan {
    Ensure-OutDir
    $rules = Get-Rules
    Write-Host "正在测量 C 盘容量与 $($rules.Count) 条规则目录（robocopy 快速测量）..."
    $drive = Get-DriveInfo
    $groups = @()
    $i = 0
    foreach ($rule in $rules) {
        $i++
        Write-Host ("  [{0}/{1}] {2}" -f $i, $rules.Count, $rule.name)
        $targets = Resolve-RuleTargets $rule
        $size = [int64]0
        foreach ($t in $targets) { $size += Measure-DirectorySize $t }
        # 用 pscustomobject（而非哈希表）便于后续 Sort-Object / Measure-Object 按 sizeGB 统计
        $groups += [pscustomobject]([ordered]@{
            id       = $rule.id
            name     = $rule.name
            path     = $rule.path   # JSON 中保留环境变量模板路径，不输出真实用户名
            sizeGB   = ConvertTo-GB $size
            category = $rule.category
            note     = $rule.note
            exists   = ($targets.Count -gt 0)
        })
    }
    $scan = [ordered]@{
        generatedAt = (Get-Date -Format "yyyy-MM-ddTHH:mm:sszzz")
        drive       = $drive
        groups      = $groups
    }
    $jsonPath = Join-Path $OutDir "scan-latest.json"
    ($scan | ConvertTo-Json -Depth 5) | Out-File -LiteralPath $jsonPath -Encoding UTF8
    $mdPath = Join-Path $OutDir "report-latest.md"
    (Build-ScanMarkdown $scan) | Out-File -LiteralPath $mdPath -Encoding UTF8

    Write-Host ""
    Write-Host "扫描完成："
    Write-Host ("  C 盘: 总 {0} GB / 已用 {1} GB ({2}%) / 可用 {3} GB" -f $drive.totalGB, $drive.usedGB, $drive.percent, $drive.freeGB)
    Write-Host "  占用最高的 5 个目录："
    $top5 = @($groups | Sort-Object sizeGB -Descending | Select-Object -First 5)
    foreach ($g in $top5) {
        Write-Host ("    {0,8} GB  {1}  ({2})" -f $g.sizeGB, $g.name, $g.path)
    }
    Write-Host ""
    Write-Host "  机器可读结果: $jsonPath"
    Write-Host "  人读报告:     $mdPath"
}

# ============================ clean ============================
# 按规则语义删除一个目标目录，返回删除过程中出错（占用/拒绝访问等）的项目数
function Remove-RuleTarget($Rule, [string]$Target) {
    $delErrs = @()
    $maxAgeDays     = Get-RuleProp $Rule 'maxAgeDays'
    $keepFiles      = Get-RuleProp $Rule 'keepFiles'
    $keepLatestSub  = Get-RuleProp $Rule 'keepLatestSubdir'
    if ($maxAgeDays) {
        # 仅删 N 天前的文件（如 Local\Temp）
        $cutoff = (Get-Date).AddDays(-[int]$maxAgeDays)
        Get-ChildItem -LiteralPath $Target -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff } |
            ForEach-Object {
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue -ErrorVariable +delErrs
            }
    } elseif ($keepLatestSub) {
        # 保留名称版本号最大的子目录，其余删除（如 WPS 旧版本）
        $dirs = @(Get-ChildItem -LiteralPath $Target -Directory -Force -ErrorAction SilentlyContinue |
                  Sort-Object -Descending -Property {
                      $v = $null
                      try { $v = [version]($_.Name -replace '[^\d\.]', '') } catch { $v = [version]'0.0' }
                      $v
                  })
        for ($k = 1; $k -lt $dirs.Count; $k++) {
            Remove-Item -LiteralPath $dirs[$k].FullName -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable +delErrs
        }
    } elseif ($keepFiles) {
        # 删除目录内容但保留指定文件（如 Squirrel packages 保留 Update.exe）
        Get-ChildItem -LiteralPath $Target -Force -ErrorAction SilentlyContinue |
            Where-Object { $keepFiles -notcontains $_.Name } |
            ForEach-Object {
                Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable +delErrs
            }
    } else {
        # 整目录删除（缓存类，系统/应用会自动重建）
        Remove-Item -LiteralPath $Target -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable +delErrs
    }
    return @($delErrs).Count
}

function Invoke-Clean {
    Ensure-OutDir
    $dryRun = -not $Execute   # 铁律 1：默认干跑，必须显式 -Execute
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $logFile = Join-Path $OutDir "clean-log-$timestamp.txt"

    function Log([string]$Msg) {
        $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Msg
        Write-Host $line
        Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
    }

    $rules = @(Get-Rules | Where-Object { $_.action -eq "delete" })
    if ($rules.Count -eq 0) { Log "规则库中没有 action=delete 的规则，无事可做。"; return }

    $modeText = "干跑（仅列出将删除项，不做任何删除）"
    if (-not $dryRun) { $modeText = "实删（-Execute）" }
    Log "cdrive-pulse clean 开始，模式：$modeText；日志：$logFile"

    # 构建清理清单：仅 action=delete 的规则进入清单
    $plan = @()
    foreach ($rule in $rules) {
        $targets = Resolve-RuleTargets $rule
        if ($targets.Count -eq 0) {
            Log ("跳过 [{0}] {1}：无匹配目录" -f $rule.id, $rule.name)
            continue
        }
        foreach ($t in $targets) {
            $reason = ""
            if (-not (Test-TargetSafe $t ([ref]$reason))) {
                Log ("警告 跳过 [{0}] {1} -> {2}：{3}" -f $rule.id, $rule.name, $t, $reason)
                continue
            }
            $size = Measure-DirectorySize $t
            $plan += [pscustomobject]@{
                RuleId = $rule.id; Name = $rule.name; Path = $t
                SizeBytes = $size; Rule = $rule
            }
        }
    }

    $totalBytes = [int64]0
    foreach ($p in $plan) { $totalBytes += $p.SizeBytes }
    Log ("清理清单共 {0} 项目标，预计可释放 {1} GB：" -f $plan.Count, (ConvertTo-GB $totalBytes))
    foreach ($p in $plan) {
        Log ("  {0,8} GB  [{1}] {2}  ->  {3}" -f (ConvertTo-GB $p.SizeBytes), $p.RuleId, $p.Name, $p.Path)
    }

    if ($dryRun) {
        Log "干跑结束：未删除任何文件。加 -Execute 参数才会真正执行清理。"
        return
    }

    # 实删：逐项目标，前后测大小，占用文件跳过计数（铁律 3、4）
    $freedTotal = [int64]0
    $skippedTotal = 0
    foreach ($p in $plan) {
        $before = Measure-DirectorySize $p.Path
        $errs = Remove-RuleTarget $p.Rule $p.Path
        $skippedTotal += $errs
        $after = Measure-DirectorySize $p.Path
        $freed = $before - $after
        if ($freed -lt 0) { $freed = 0 }
        $freedTotal += $freed
        $errText = ""
        if ($errs -gt 0) { $errText = "，跳过占用/拒绝访问项目 $errs 个" }
        Log ("已清理 [{0}] {1}：释放 {2} GB{3}" -f $p.RuleId, $p.Name, (ConvertTo-GB $freed), $errText)
    }
    Log ("清理完成：共释放 {0} GB；跳过占用/拒绝访问项目合计 {1} 个（未强杀任何进程）。" -f (ConvertTo-GB $freedTotal), $skippedTotal)
    if ($skippedTotal -gt 0) {
        Log "提示：部分文件被占用属正常现象，关闭对应应用后重跑 clean 即可进一步释放。"
    }
}

# ============================ report ============================
function Invoke-Report([string]$OldPath, [string]$NewPath) {
    if (-not $OldPath -or -not $NewPath) {
        Write-Error "用法: .\cpulse.ps1 report <旧scan.json> <新scan.json>"
        return
    }
    foreach ($f in @($OldPath, $NewPath)) {
        if (-not (Test-Path -LiteralPath $f)) {
            Write-Error "文件不存在: $f"
            return
        }
    }
    Ensure-OutDir
    $old = Get-Content -LiteralPath $OldPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $new = Get-Content -LiteralPath $NewPath -Raw -Encoding UTF8 | ConvertFrom-Json

    $oldMap = @{}
    foreach ($g in $old.groups) { $oldMap[$g.id] = $g }

    $rows = @()
    $totalFreed = 0.0
    foreach ($g in $new.groups) {
        if ($oldMap.ContainsKey($g.id)) {
            $o = $oldMap[$g.id]
            $delta = [math]::Round($o.sizeGB - $g.sizeGB, 2)  # 正数 = 释放
            $totalFreed += $delta
            $rows += [pscustomobject]@{
                Name = $g.name; Category = $g.category
                Before = $o.sizeGB; After = $g.sizeGB; Freed = $delta
            }
        }
    }
    $driveFreed = [math]::Round($old.drive.usedGB - $new.drive.usedGB, 2)
    $totalFreed = [math]::Round($totalFreed, 2)

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("# C盘脉搏 清理前后对比")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("- 旧扫描: $($old.generatedAt)")
    [void]$sb.AppendLine("- 新扫描: $($new.generatedAt)")
    [void]$sb.AppendLine("- C 盘已用: $($old.drive.usedGB) GB -> $($new.drive.usedGB) GB（释放 $driveFreed GB）")
    [void]$sb.AppendLine("- 规则目录合计释放: $totalFreed GB")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("| 名称 | 类别 | 清理前 (GB) | 清理后 (GB) | 释放 (GB) |")
    [void]$sb.AppendLine("| --- | --- | ---: | ---: | ---: |")
    foreach ($r in ($rows | Sort-Object Freed -Descending)) {
        [void]$sb.AppendLine("| $($r.Name) | $($r.Category) | $($r.Before) | $($r.After) | $($r.Freed) |")
    }
    $text = $sb.ToString()
    Write-Host $text
    $cmpPath = Join-Path $OutDir ("report-compare-{0}.md" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
    $text | Out-File -LiteralPath $cmpPath -Encoding UTF8
    Write-Host "对比报告已保存: $cmpPath"
}

# ============================ rules ============================
function Invoke-Rules {
    $rules = Get-Rules
    Write-Host ("当前规则库共 {0} 条（{1}）：" -f $rules.Count, $RulesFile)
    Write-Host ""
    foreach ($cat in $CategoryOrder) {
        $items = @($rules | Where-Object { $_.category -eq $cat })
        if ($items.Count -eq 0) { continue }
        Write-Host "【$($CategoryNames[$cat])】"
        foreach ($r in $items) {
            Write-Host ("  [{0}] {1}" -f $r.id, $r.name)
            Write-Host ("      路径: {0}   动作: {1}" -f $r.path, $r.action)
            if ($r.note) { Write-Host ("      说明: {0}" -f $r.note) }
        }
        Write-Host ""
    }
}

function Show-Help {
    Write-Host @"
cdrive-pulse（C盘脉搏）— Windows C 盘空间监测与安全清理工具

用法：
  .\cpulse.ps1 scan                        扫描 C 盘与规则目录，生成 out\scan-latest.json 和 out\report-latest.md
  .\cpulse.ps1 clean -WhatIf               干跑（默认）：列出将删除项与预计释放量
  .\cpulse.ps1 clean -Execute              真正执行清理（遵守安全铁律，全程写日志）
  .\cpulse.ps1 report <旧json> <新json>    对比两次扫描，统计释放量
  .\cpulse.ps1 rules                       列出当前规则库

规则库：rules.json（路径支持 %USERPROFILE% 等环境变量与 * 通配）
"@
}

switch ($Command.ToLower()) {
    "scan"   { Invoke-Scan }
    "clean"  { Invoke-Clean }
    "report" { Invoke-Report $Arg1 $Arg2 }
    "rules"  { Invoke-Rules }
    default  { Show-Help }
}
