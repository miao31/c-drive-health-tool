#requires -Version 5.1
<#
  C 盘健康工具（合并版：只读扫描 + 交互式清理）
  ------------------------------------------------------------------
  合并自 c_drive_readonly_scan.ps1（分层只读扫描）与 clean-interactive.ps1（交互式清理）。
  一次运行 = 先只读体检，再由你决定是否进入逐项确认的清理。

  用法（建议以管理员身份运行 PowerShell）：
      .\c_drive_tool.ps1                        # 只读扫描（默认，绝不删除任何文件）
      .\c_drive_tool.ps1 -Clean                 # 扫描后进入交互式清理，每一步都要你确认
      .\c_drive_tool.ps1 -Clean -DryRun         # 演练清理，只打印不删除
      .\c_drive_tool.ps1 -ListPersonalFiles     # 额外汇总下载/桌面的安装包（只列出，不删除）
      .\c_drive_tool.ps1 -OutDir D:\some\dir    # 指定报告输出目录
      .\c_drive_tool.ps1 -DirTimeoutSec 30 -TopFiles 10 -TopSubdirs 5

  单目录超时即降级：只记录总大小，报告里标注"明细不足"，且该目录不允许被清理。
  高危路径由 Guard-Path 运行时拦截；受保护项（密钥等）连枚举都不做。
#>
param(
    [switch]$Clean,
    [switch]$DryRun,
    [switch]$ListPersonalFiles,
    [switch]$Archive,
    [switch]$AssessSystemChannels,
    [string]$OutDir = "",
    [string]$Config = "",
    [int]$DirTimeoutSec = 20,
    [int]$TopFiles = 20,
    [int]$TopSubdirs = 10
)

# ============================================================
# 0. 尺寸测量内核（C#，带超时降级）
# ============================================================
$csSrc = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Diagnostics;
public class CDriveSz {
    public static long[] Size(string path, long maxMs) {
        long size = 0, count = 0; int to = 0;
        var sw = Stopwatch.StartNew();
        var st = new Stack<string>();
        st.Push(path);
        while (st.Count > 0) {
            if (maxMs > 0 && sw.ElapsedMilliseconds > maxMs) { to = 1; break; }
            var d = st.Pop();
            try { foreach (var f in Directory.EnumerateFiles(d)) { try { size += new FileInfo(f).Length; count++; } catch { } } } catch { }
            try {
                foreach (var s in Directory.EnumerateDirectories(d)) {
                    try { var di = new DirectoryInfo(s); if ((di.Attributes & FileAttributes.ReparsePoint) != 0) continue; } catch { }
                    st.Push(s);
                }
            } catch { }
        }
        return new long[] { size, count, to };
    }
    public static List<string[]> TopFiles(string path, int n, long maxMs) {
        var all = new List<string[]>();
        var sw = Stopwatch.StartNew();
        var st = new Stack<string>();
        st.Push(path);
        while (st.Count > 0) {
            if (maxMs > 0 && sw.ElapsedMilliseconds > maxMs) break;
            var d = st.Pop();
            try {
                foreach (var f in Directory.EnumerateFiles(d)) {
                    long sz = 0; string mt = "";
                    try { var fi = new FileInfo(f); sz = fi.Length; mt = fi.LastWriteTime.ToString("yyyy-MM-dd"); } catch { continue; }
                    if (all.Count < 60000) all.Add(new string[] { f, sz.ToString(), mt });
                }
            } catch { }
            try {
                foreach (var s in Directory.EnumerateDirectories(d)) {
                    try { var di = new DirectoryInfo(s); if ((di.Attributes & FileAttributes.ReparsePoint) != 0) continue; } catch { }
                    st.Push(s);
                }
            } catch { }
        }
        all.Sort((a, b) => long.Parse(b[1]).CompareTo(long.Parse(a[1])));
        var res = new List<string[]>();
        for (int i = 0; i < Math.Min(n, all.Count); i++) res.Add(all[i]);
        return res;
    }
    public static List<string[]> Subdirs(string path, int n, long maxMs) {
        var res = new List<string[]>();
        try {
            foreach (var s in Directory.EnumerateDirectories(path)) {
                try { var di = new DirectoryInfo(s); if ((di.Attributes & FileAttributes.ReparsePoint) != 0) continue; } catch { continue; }
                var r = Size(s, maxMs);
                res.Add(new string[] { s, r[0].ToString(), r[1].ToString(), r[2].ToString() });
            }
        } catch { }
        res.Sort((a, b) => long.Parse(b[1]).CompareTo(long.Parse(a[1])));
        if (res.Count > n) res = res.GetRange(0, n);
        return res;
    }
}
'@

# 已存在同名类型时不再重复加载——避免同一 PowerShell 会话里二次运行报错
if (-not ('CDriveSz' -as [type])) { Add-Type -TypeDefinition $csSrc -Language CSharp }

# ============================================================
# 1. 通用设置
# ============================================================
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'
$scriptPath   = $MyInvocation.MyCommand.Path
$stamp        = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:abort = $false
$script:logLines = New-Object System.Collections.ArrayList

$W  = $env:windir
$UL = "$env:USERPROFILE\AppData\Local"
$UR = "$env:USERPROFILE\AppData\Roaming"
$UP = $env:USERPROFILE

# ---------- 版本与运行标识（为升级 / 规范化预留） ----------
$ScriptVersion = '1.1.0'
$SchemaVersion = 1
$RunId         = $stamp
$ConfigSource   = 'builtin'
$ArchiveReport  = [bool]$Archive
$AssessChannels = [bool]$AssessSystemChannels

# ---------- 可选配置：只覆盖非安全关键参数 ----------
# 配置缺失、解析失败或越界，一律回退内置默认值。
# $catalog、Guard-Path 与删除逻辑永不从配置读取。
if (-not [string]::IsNullOrWhiteSpace($Config)) {
    if (-not (Test-Path -LiteralPath $Config)) {
        $ConfigSource = 'builtin (config missing)'
    } else {
        try {
            $cfg = Import-PowerShellDataFile -LiteralPath $Config -ErrorAction Stop
            if ($cfg.ContainsKey('DirTimeoutSec')) {
                $v = [int]$cfg['DirTimeoutSec']; if ($v -ge 1 -and $v -le 3600) { $DirTimeoutSec = $v }
            }
            if ($cfg.ContainsKey('TopFiles')) {
                $v = [int]$cfg['TopFiles']; if ($v -ge 1 -and $v -le 200) { $TopFiles = $v }
            }
            if ($cfg.ContainsKey('TopSubdirs')) {
                $v = [int]$cfg['TopSubdirs']; if ($v -ge 1 -and $v -le 200) { $TopSubdirs = $v }
            }
            if ($cfg.ContainsKey('ArchiveOnScan')) { $ArchiveReport = [bool]$cfg['ArchiveOnScan'] }
            if ($cfg.ContainsKey('AssessSystemChannelsOnScan')) { $AssessChannels = [bool]$cfg['AssessSystemChannelsOnScan'] }
            $ConfigSource = $Config
        } catch {
            $ConfigSource = 'builtin (config error)'
        }
    }
}

function Log($m) { [void]$script:logLines.Add(("{0}  [{1}]  {2}" -f (Get-Date).ToString('HH:mm:ss'), $RunId, $m)) }
function Say($m, $c) { if (-not $c) { $c = 'White' }; Write-Host $m -ForegroundColor $c; Log $m }
function Fmt($b) {
    $b = [double]$b
    if ($b -ge 1TB) { return "{0:N2} TB" -f ($b / 1TB) }
    if ($b -ge 1GB) { return "{0:N2} GB" -f ($b / 1GB) }
    if ($b -ge 1MB) { return "{0:N1} MB" -f ($b / 1MB) }
    if ($b -ge 1KB) { return "{0:N0} KB" -f ($b / 1KB) }
    return "$b B"
}
function GetFree { return (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'").FreeSpace }

# ---------- 输出目录：默认脚本所在目录，逐级降级 ----------
if ([string]::IsNullOrWhiteSpace($OutDir) -or -not (Test-Path -LiteralPath $OutDir)) { $OutDir = Split-Path -Parent $scriptPath }
if ([string]::IsNullOrWhiteSpace($OutDir) -or -not (Test-Path -LiteralPath $OutDir)) { $OutDir = $env:TEMP }
if (-not (Test-Path -LiteralPath $OutDir)) { $OutDir = (Get-Location).Path }

# ---------- 环境识别 ----------
$os      = Get-CimInstance Win32_OperatingSystem
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$hostName = (Get-Process -Id $PID).ProcessName
switch ($hostName) {
    'powershell' { $shellType = '原生 PowerShell (Windows PowerShell)' }
    'pwsh'       { $shellType = 'PowerShell Core (pwsh)' }
    default      { $shellType = "非原生 PowerShell / 宿主进程：$hostName（按非原生处理）" }
}
$disk   = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
$dSize  = [double]$disk.Size
$dFree  = [double]$disk.FreeSpace
$freePct = if ($dSize -gt 0) { $dFree / $dSize * 100 } else { 0 }

# ============================================================
# 2. 安全护栏（运行时路径守卫）
# ============================================================
$forbiddenRoots = @(
    "$W\WinSxS", "$W\Installer", "$W\System32\config",
    'C:\Program Files', 'C:\Program Files (x86)', 'C:\ProgramData',
    "$W\Fonts", "$W\Microsoft.NET", "$W\SystemApps",
    "$W\SysWOW64", "$W\servicing", "$W\SystemResources",
    'C:\Boot', 'C:\Recovery', 'C:\EFI', 'C:\System Volume Information', 'C:\Windows\CSC'
)
$allowedInsideForbidden = @("$W\System32\LogFiles", "$W\System32\SleepStudy")

function Guard-Path($p) {
    $lp = $p.ToLower().TrimEnd('\')
    foreach ($f in $forbiddenRoots) {
        $lf = $f.ToLower()
        if ($lp -eq $lf -or $lp.StartsWith($lf + '\')) {
            foreach ($a in $allowedInsideForbidden) {
                $la = $a.ToLower()
                if ($lp -eq $la -or $lp.StartsWith($la + '\')) { return $true }
            }
            return $false
        }
    }
    return $true
}

# ============================================================
# 3. 目录清单（唯一事实来源）
#    risk      : low 可清理 / confirm 需人工确认 / protected 禁止操作
#    cleanable : 是否可由本脚本自动清理（仅 low 类可能为真）
#    noscan    : 连枚举都不做（受保护、无权限）
# ============================================================
$stopWU   = { Say "     停止 Windows Update 服务..." 'DarkGray'; Stop-Service wuauserv, bits -Force -EA SilentlyContinue }
$startWU  = { Say "     恢复 Windows Update 服务..." 'DarkGray'; Start-Service wuauserv, bits -EA SilentlyContinue }
$stopExp  = { Say "     重启资源管理器..." 'DarkGray'; Stop-Process -Name explorer -Force -EA SilentlyContinue; Start-Sleep 1 }
$startExp = { Start-Process explorer -EA SilentlyContinue }

$catalog = @(
# ---- 低风险：可清理 ----
@{ id='L01'; name='Windows 临时目录'; paths=@("$W\Temp"); risk='low'; recover='不可恢复'
   reason='系统级临时文件，程序重开即重建'
   cleanable=$true; admin=$true;  mode='contents'; filter=''; recurse=$false; pre=$null; post=$null
   note='系统级临时文件' }

@{ id='L02'; name='用户临时文件 %TEMP%'; paths=@("$env:TEMP"); risk='low'; recover='不可恢复'
   reason='应用临时文件，可重建'
   cleanable=$true; admin=$false; mode='contents'; filter=''; recurse=$false; pre=$null; post=$null
   note='正在使用的文件会跳过，不会中断程序' }

@{ id='L03'; name='预读取 Prefetch'; paths=@("$W\Prefetch"); risk='low'; recover='部分可恢复'
   reason='启动预读取缓存，会自动重建'
   cleanable=$true; admin=$true;  mode='contents'; filter=''; recurse=$false; pre=$null; post=$null
   note='清空后首次开机略慢，会自行重建' }

@{ id='L04'; name='缩略图缓存 thumbcache'; paths=@("$UL\Microsoft\Windows\Explorer"); risk='low'; recover='部分可恢复'
   reason='资源管理器缩略图缓存，自动重建'
   cleanable=$true; admin=$false; mode='files'; filter='thumbcache_*.db'; recurse=$false; pre=$stopExp; post=$startExp
   note='会重启资源管理器（桌面闪一下），缓存会自动重建' }

@{ id='L05'; name='Edge 浏览器缓存'; paths=@("$UL\Microsoft\Edge\User Data\Default\Cache","$UL\Microsoft\Edge\User Data\Default\Code Cache","$UL\Microsoft\Edge\User Data\Default\GPUCache"); risk='low'; recover='部分可恢复'
   reason='网页缓存，可重建'
   cleanable=$true; admin=$false; mode='contents'; filter=''; recurse=$false; pre=$null; post=$null
   note='请先关闭 Edge；只删缓存，不影响书签和密码' }

@{ id='L06'; name='Chrome 浏览器缓存'; paths=@("$UL\Google\Chrome\User Data\Default\Cache","$UL\Google\Chrome\User Data\Default\Code Cache","$UL\Google\Chrome\User Data\Default\GPUCache"); risk='low'; recover='部分可恢复'
   reason='网页缓存，可重建'
   cleanable=$false; howto='在 Chrome 里 设置 → 隐私和安全 → 清除浏览数据' }

@{ id='L07'; name='Firefox 缓存'; paths=@("$UL\Mozilla\Firefox\Profiles"); risk='low'; recover='部分可恢复'
   reason='网页缓存，可重建'
   cleanable=$true; admin=$false; mode='contents'; filter=''; recurse=$false; pre=$null; post=$null
   note='请先关闭 Firefox' }

@{ id='L08'; name='系统网络缓存 INetCache'; paths=@("$UL\Microsoft\Windows\INetCache"); risk='low'; recover='部分可恢复'
   reason='IE/系统组件的网页缓存'
   cleanable=$true; admin=$false; mode='contents'; filter=''; recurse=$false; pre=$null; post=$null
   note='IE/系统组件的网页缓存' }

@{ id='L09'; name='崩溃转储 Minidump/CrashDumps'; paths=@("$W\Minidump","$UL\CrashDumps"); risk='low'; recover='不可恢复'
   reason='蓝屏转储，排查完毕即可删'
   cleanable=$true; admin=$true;  mode='contents'; filter=''; recurse=$false; pre=$null; post=$null
   note='正在排查蓝屏问题的话请跳过' }

@{ id='L10'; name='Windows 升级日志 MoSetup'; paths=@("$W\Logs\MoSetup"); risk='low'; recover='不可恢复'
   reason='纯升级日志，删除不影响系统'
   cleanable=$true; admin=$true;  mode='contents'; filter=''; recurse=$false; pre=$null; post=$null
   note='纯日志，历史上是最大单项' }

@{ id='L11'; name='其余系统日志 CBS/DISM/WMI/NetSetup/Panther'; paths=@("$W\Logs\CBS","$W\Logs\DISM","$W\Logs\WinREAgent","$W\Logs\NetSetup","$W\System32\LogFiles\WMI","$W\Panther"); risk='low'; recover='不可恢复'
   reason='系统运行日志，删除不影响功能'
   cleanable=$true; admin=$true;  mode='contents'; filter=''; recurse=$false; pre=$null; post=$null
   note='组件服务、DISM、WMI 跟踪等日志' }

@{ id='L12'; name='Windows 更新下载缓存'; paths=@("$W\SoftwareDistribution\Download"); risk='low'; recover='部分可恢复'
   reason='已下载的更新包，不影响已安装更新'
   cleanable=$true; admin=$true;  mode='contents'; filter=''; recurse=$false; pre=$stopWU; post=$startWU
   note='脚本会自动停/启更新服务' }

@{ id='L13'; name='pip 缓存'; paths=@("$UL\pip\cache"); risk='low'; recover='部分可恢复'
   reason='Python 包缓存，可重新下载'
   cleanable=$true; admin=$false; mode='contents'; filter=''; recurse=$false; pre=$null; post=$null
   note='等价于 pip cache purge' }

@{ id='L14'; name='npm 缓存'; paths=@("$UR\npm-cache","$UL\npm-cache"); risk='low'; recover='部分可恢复'
   reason='npm 包缓存，可重新下载'
   cleanable=$true; admin=$false; mode='contents'; filter=''; recurse=$false; pre=$null; post=$null
   note='等价于 npm cache clean --force' }

@{ id='L15'; name='Windows 错误报告 WER'; paths=@("$UL\Microsoft\Windows\WER","C:\ProgramData\Microsoft\Windows\WER"); risk='low'; recover='不可恢复'
   reason='错误报告队列'
   cleanable=$false; howto='手动删除上述目录内的内容（错误报告队列）' }

@{ id='L16'; name='回收站'; paths=@('C:\$Recycle.Bin'); risk='low'; recover='不可恢复'
   reason='已删除文件占用，清空才真正释放'
   cleanable=$true; admin=$false; mode='bin'; filter=''; recurse=$false; pre=$null; post=$null
   note='清空回收站，这一步才会真正腾出空间' }

# ---- 需确认：禁止自动处理 ----
@{ id='C01'; name='下载目录 Downloads'; paths=@("$UP\Downloads"); risk='confirm'; recover='可恢复'; reason='可能含个人文件，必须逐项确认' }
@{ id='C02'; name='桌面大文件'; paths=@("$UP\Desktop"); risk='confirm'; recover='可恢复'; reason='可能含个人文件，必须逐项确认' }
@{ id='C03'; name='文档/图片/视频/音乐'; paths=@("$UP\Documents","$UP\Pictures","$UP\Videos","$UP\Music"); risk='confirm'; recover='可恢复'; reason='个人资料，禁止自动处理' }
@{ id='C04'; name='IDE 缓存与扩展'; paths=@("$UP\.vscode","$UR\Code","$UL\Programs\Microsoft VS Code","$UP\.cursor"); risk='confirm'; recover='部分可恢复'; reason='扩展与工作区配置不可整体删除' }
@{ id='C05'; name='包管理器本地仓库'; paths=@("$UP\.m2","$UP\.gradle","$UP\.cargo","$UP\.nuget","$UP\.pnpm-store","$UL\Yarn\Cache","$UL\go-build"); risk='confirm'; recover='部分可恢复'; reason='可重建但重下成本高' }
@{ id='C06'; name='旧系统残留 $WinREAgent'; paths=@('C:\$WinREAgent'); risk='confirm'; recover='不可恢复'; reason='删除后无法回退到更新前系统' }
@{ id='C07'; name='旧系统 Windows.old'; paths=@('C:\Windows.old'); risk='confirm'; recover='不可恢复'; reason='删除后无法回退旧系统' }
@{ id='C08'; name='AI 模型目录'; paths=@("$UP\.ollama","$UP\.lmstudio","$UP\.cache\huggingface"); risk='confirm'; recover='不可恢复'; reason='体积大不等于垃圾，只分析不自动删' }
@{ id='C09'; name='微信/QQ 文件目录'; paths=@("$UP\Documents\WeChat Files","$UP\Documents\Tencent Files"); risk='confirm'; recover='不可恢复'; reason='聊天记录与账号数据受保护，仅缓存子目录可考虑' }
@{ id='C10'; name='Docker / WSL / 虚拟机'; paths=@("$UL\Docker","$UL\WSL","$UP\.docker"); risk='confirm'; recover='不可恢复'; reason='vhdx 与 volume 非缓存，禁止删除' }

# ---- 已保护：禁止操作 ----
@{ id='P01'; name='Windows 系统核心目录'; paths=@("$W\System32","$W\SysWOW64","$W\WinSxS","$W\Installer","$W\DriverStore","$W\servicing","$W\Fonts","$W\Microsoft.NET","$W\SystemApps"); risk='protected'; recover='不可恢复'; reason='删除会导致系统无法启动或无法更新' }
@{ id='P02'; name='程序安装目录与公共数据'; paths=@('C:\Program Files','C:\Program Files (x86)','C:\ProgramData'); risk='protected'; recover='不可恢复'; reason='已安装程序本体与配置' }
@{ id='P03'; name='浏览器用户数据（密码/书签/Cookie）'; paths=@("$UL\Microsoft\Edge\User Data\Default","$UL\Google\Chrome\User Data\Default"); risk='protected'; recover='不可恢复'; reason='含登录数据、Cookie、书签，删除即丢失' }
@{ id='P04'; name='用户配置 AppData\Roaming'; paths=@("$UR"); risk='protected'; recover='不可恢复'; reason='软件配置与账号数据' }
@{ id='P05'; name='密钥与凭据目录'; paths=@("$UP\.ssh","$UP\.gnupg","$UP\.aws","$UP\.docker\config.json"); risk='protected'; recover='不可恢复'; reason='私钥与凭据，泄露或删除均造成严重后果；本项不枚举内容'; noscan=$true }
@{ id='P06'; name='休眠文件与页面文件'; paths=@('C:\hiberfil.sys','C:\pagefile.sys','C:\swapfile.sys'); risk='protected'; recover='不可恢复'; reason='系统占用文件，禁止直接删除' }
@{ id='P07'; name='OneDrive 同步目录'; paths=@("$UP\OneDrive"); risk='protected'; recover='不可恢复'; reason='删除会触发云端同步删除' }
)

# ============================================================
# 4. 阶段一：只读扫描
# ============================================================
try { Clear-Host } catch { }
Say "==============================================================" 'White'
Say " C 盘健康工具（只读扫描 + 交互式清理）" 'White'
Say "==============================================================" 'White'
Say (" 可用空间：{0}（{1}%）    管理员：{2}" -f (Fmt $dFree), [math]::Round($freePct,1), $(if ($isAdmin) { '是' } else { '否' })) 'Gray'
if ($Clean) {
    Say (" 模式：交互式清理{0}" -f $(if ($DryRun) { '（演练，不删除）' } else { '' })) 'Yellow'
    if (-not $isAdmin) { Say " 提示：未以管理员运行，L01/L03/L09/L10/L11/L12 会被跳过。" 'Yellow' }
} else {
    Say " 模式：只读扫描（不删除任何文件）" 'Gray'
    Say " 如需清理，请以管理员身份运行：.\c_drive_tool.ps1 -Clean" 'DarkGray'
}
Say ""

Say "[阶段 1/2] 只读扫描" 'Cyan'
Say (" 正在测量 {0} 个目录项（单目录超时 {1} 秒，超时即降级）..." -f $catalog.Count, $DirTimeoutSec) 'Gray'
$scanSw = [System.Diagnostics.Stopwatch]::StartNew()

$maxMs = [long]$DirTimeoutSec * 1000
$items = New-Object System.Collections.ArrayList
$lowSum = [double]0

foreach ($c in $catalog) {
    $noScan = [bool]$c.noscan
    $size = [double]0
    $cnt  = [long]0
    $to   = 0
    $lastWrite = ''
    $paths = @()

    if ($noScan) {
        $complete = '未扫描（受保护，禁止枚举）'
        $paths = @($c.paths)
    } else {
        $paths = @($c.paths) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
        $sizeMs = if ($c.risk -eq 'protected') { [long]60000 } else { $maxMs }
        foreach ($p in $paths) {
            $r = [CDriveSz]::Size($p, $sizeMs)
            $size += $r[0]
            $cnt  += $r[1]
            if ($r[2] -eq 1) { $to = 1 }
        }
        if ($size -le 0) { continue }
        if ($c.risk -eq 'low') { $lowSum += $size }
        $complete = if ($to -eq 1) { '明细不足（超时降级）' } else { '完整' }
        if ($paths.Count -gt 0) {
            try { $lastWrite = (Get-Item -LiteralPath $paths[0] -Force).LastWriteTime.ToString('yyyy-MM-dd HH:mm') } catch { }
        }
    }

    $tops = @()
    $topf = @()
    if ($c.risk -ne 'protected') {
        foreach ($p in $paths) {
            foreach ($s in [CDriveSz]::Subdirs($p, $TopSubdirs, [long]($maxMs / 2))) {
                $tops += [pscustomobject]@{ p = $s[0]; s = [long]$s[1] }
            }
        }
        $tops = @($tops | Sort-Object s -Descending | Select-Object -First $TopSubdirs)
        foreach ($p in $paths) {
            foreach ($f in [CDriveSz]::TopFiles($p, $TopFiles, $maxMs)) {
                $topf += [pscustomobject]@{ p = $f[0]; s = [long]$f[1]; m = $f[2] }
            }
        }
        $topf = @($topf | Sort-Object s -Descending | Select-Object -First $TopFiles)
    }

    $how = if ($c.risk -eq 'protected') { '禁止操作' }
           elseif ($c.cleanable) { '可脚本清理（-Clean 逐项确认）' }
           elseif ($c.howto) { "需手动：$($c.howto)" }
           else { '需人工确认，不自动处理' }

    [void]$items.Add([pscustomobject]@{
        id = $c.id; name = $c.name; paths = @($paths)
        size = $size; count = $cnt; risk = $c.risk
        reason = $c.reason; recover = $c.recover; how = $how
        cleanable = [bool]$c.cleanable; admin = [bool]$c.admin; mode = $c.mode
        filter = $c.filter; recurse = [bool]$c.recurse; pre = $c.pre; post = $c.post; note = $c.note
        complete = $complete; lastWrite = $lastWrite; topDirs = @($tops); topFiles = @($topf)
    })
}

$scanSw.Stop()
$itemList = @($items | Sort-Object size -Descending)
$lowItems = @($itemList | Where-Object { $_.risk -eq 'low' })
$cfmItems = @($itemList | Where-Object { $_.risk -eq 'confirm' })
$proItems = @($itemList | Where-Object { $_.risk -eq 'protected' })

# ---------- 系统官方通道：只读评估（-AssessSystemChannels） ----------
# 复用本次扫描结果：不重复枚举、不调用任何外部命令、不修改系统设置。
# 占用 ≠ 可回收量；合并统计项不拆分到单个通道，一律留 unknown。
$systemChannels = @()
if ($AssessChannels) {
    $channelMap = @(
        @{ id='WINSXS';        name='组件存储 WinSxS';  itemIds=@('P01');       sizeItem=$null;  cmd='Dism.exe /Online /Cleanup-Image /StartComponentCleanup'; reversible='否';       admin=$true;  stage='C 阶段候选'; note='P01 为 9 个路径合并统计，不可拆分' }
        @{ id='DRIVERSTORE';   name='旧版驱动包';      itemIds=@('P01');       sizeItem=$null;  cmd='cleanmgr → 设备驱动程序包';                            reversible='否';       admin=$true;  stage='C 阶段候选'; note='同上，合并项，占用不可单独给出' }
        @{ id='WU_CACHE';      name='更新下载缓存';    itemIds=@('L12');       sizeItem='L12'; cmd='本工具 L12（逐项确认）';                               reversible='部分';    admin=$true;  stage='现有能力';   note='' }
        @{ id='SYS_LOGS';      name='系统日志';        itemIds=@('L10','L11'); sizeItem=$null;  cmd='本工具 L10 / L11（逐项确认）';                         reversible='否';       admin=$true;  stage='现有能力';   note='两项合计见报告第 4 节，不重复计算' }
        @{ id='RECYCLEBIN';    name='回收站';          itemIds=@('L16');       sizeItem='L16'; cmd='本工具 L16 / Clear-RecycleBin';                        reversible='否';       admin=$false; stage='现有能力';   note='' }
        @{ id='OLD_SYSTEM';    name='旧系统与回退残留';itemIds=@('C06','C07'); sizeItem=$null;  cmd='设置 → 系统 → 存储 → 临时文件';                         reversible='否';       admin=$true;  stage='C 阶段候选'; note='confirm 类，仅统计不处理' }
        @{ id='HIBERNATE';     name='休眠 / 页面文件'; itemIds=@('P06');       sizeItem=$null;  cmd='powercfg /h off（明确不进白名单）';                    reversible='需手动重开'; admin=$true; stage='不执行';    note='P06 已保护，本工具不处理' }
        @{ id='STORAGE_SENSE'; name='存储感知';        itemIds=@();            sizeItem=$null;  cmd='设置 → 系统 → 存储 → 存储感知';                         reversible='视配置';  admin=$false; stage='C 阶段候选'; note='无对应清单项，仅给入口' }
    )
    foreach ($c in $channelMap) {
        $bytes = $null
        if ($c.sizeItem) {
            $hit = @($itemList | Where-Object { $_.id -eq $c.sizeItem } | Select-Object -First 1)
            if ($hit.Count -gt 0) { $bytes = [long]$hit[0].size }
        }
        $systemChannels += [pscustomobject]@{
            id         = $c.id
            name       = $c.name
            itemIds    = @($c.itemIds)
            bytes      = $bytes
            command    = $c.cmd
            reversible = $c.reversible
            admin      = [bool]$c.admin
            stage      = $c.stage
            note       = $c.note
        }
    }
}

# ---------- 健康判定（可用 <10 GB 紧急 / <15 GB 偏低 / 否则正常） ----------
if ($dFree -lt 10GB)     { $health = '紧急：可用空间低于 10 GB，建议立即清理' }
elseif ($dFree -lt 15GB) { $health = '偏低：建议近期安排一次清理' }
else                     { $health = '正常' }

if ($lowSum -ge 1GB -or $dFree -lt 10GB) {
    $verdict = "建议清理：低风险可释放约 $(Fmt $lowSum)，可用率 $([math]::Round($freePct,1))%"
} elseif ($lowSum -ge 500MB -or $dFree -lt 15GB) {
    $verdict = "可选清理：低风险可释放约 $(Fmt $lowSum)，空间偏低，建议近期安排一次"
} else {
    $verdict = "当前 C 盘空间充足，无紧急清理需求。清理收益较小（低风险项约 $(Fmt $lowSum)），可选择不执行。"
}

Say (" 扫描完成，用时 {0:N0} 秒" -f $scanSw.Elapsed.TotalSeconds) 'Green'
Say ""
$cfmSum = [double](($cfmItems | Measure-Object -Property size -Sum).Sum)
$proSum = [double](($proItems | Measure-Object -Property size -Sum).Sum)
Say (" 低风险可释放：{0}（{1} 项）" -f (Fmt $lowSum), $lowItems.Count) 'Green'
Say (" 需要确认：    {0}（{1} 项，不自动处理）" -f (Fmt $cfmSum), $cfmItems.Count) 'Yellow'
Say (" 已保护：      {0}（{1} 项，禁止操作）" -f (Fmt $proSum), $proItems.Count) 'Red'
Say (" 健康状态：{0}" -f $health) 'Gray'
Say ""
Say " 占用最大的低风险项：" 'Gray'
$i = 1
foreach ($r in ($lowItems | Select-Object -First 5)) {
    Say ("   {0}. {1,-34} {2,10}" -f $i, $r.name, (Fmt $r.size)) 'Gray'
    $i++
}
Say ""

# ---------- 报告输出 ----------
$jsonPath = Join-Path $OutDir "c_drive_scan_$stamp.json"
# 只导出数据字段：pre/post 是 ScriptBlock，序列化后会撑到数 MB
$jsonItems = @($itemList | Select-Object id, name, paths, size, count, risk, reason, recover, how,
                                              cleanable, admin, complete, lastWrite, topDirs, topFiles)
$runMode = if ($Clean) { if ($DryRun) { 'clean-dryrun' } else { 'clean' } } else { 'readonly' }
$payload = [pscustomobject]@{
    stamp         = $stamp
    scannedAt     = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    toolVersion   = $ScriptVersion
    schemaVersion = $SchemaVersion
    runId         = $RunId
    configSource  = $ConfigSource
    runMode       = $runMode
    scanSeconds   = [math]::Round($scanSw.Elapsed.TotalSeconds, 1)
    systemChannels= @($systemChannels)
    outDir        = $OutDir
    diskSize      = $dSize
    diskFree      = $dFree
    freePct       = [math]::Round($freePct, 1)
    lowSum        = $lowSum
    health        = $health
    scriptPath    = $scriptPath
    items         = $jsonItems
}
[System.IO.File]::WriteAllText($jsonPath, ($payload | ConvertTo-Json -Depth 8 -Compress), (New-Object System.Text.UTF8Encoding($false)))

$md = New-Object System.Collections.ArrayList
[void]$md.Add("# C 盘空间分析报告")
[void]$md.Add("")
[void]$md.Add("> 本报告由只读扫描生成，扫描过程未删除、未移动、未修改任何文件。所有释放空间均为估算值。")
[void]$md.Add("")
[void]$md.Add("## 1. 系统环境概览")
[void]$md.Add("")
[void]$md.Add("| 项目 | 值 |")
[void]$md.Add("|---|---|")
[void]$md.Add("| 操作系统 | $($os.Caption)（版本 $($os.Version)） |")
[void]$md.Add("| 执行环境 | $shellType |")
[void]$md.Add("| 管理员权限 | $(if ($isAdmin) { '是' } else { '否' }) |")
[void]$md.Add("| 扫描时间 | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') |")
[void]$md.Add("| 扫描耗时 | $([math]::Round($scanSw.Elapsed.TotalSeconds,1)) 秒 |")
[void]$md.Add("| 单目录超时 | $DirTimeoutSec 秒 |")
[void]$md.Add("")
[void]$md.Add("## 2. C 盘容量概览")
[void]$md.Add("")
[void]$md.Add("| 项目 | 值 |")
[void]$md.Add("|---|---|")
[void]$md.Add("| 总容量 | $(Fmt $dSize) |")
[void]$md.Add("| 已用 | $(Fmt ($dSize - $dFree)) |")
[void]$md.Add("| 可用 | $(Fmt $dFree) |")
[void]$md.Add("| 可用率 | $([math]::Round($freePct,1))% |")
[void]$md.Add("| 健康状态 | $health |")
[void]$md.Add("")
[void]$md.Add("## 3. 当前是否需要清理")
[void]$md.Add("")
[void]$md.Add($verdict)
[void]$md.Add("")
[void]$md.Add("低风险项可释放合计（估算）：**$(Fmt $lowSum)**")
[void]$md.Add("")

function AddTable($title, $list) {
    $script:md.Add("## $title")
    $script:md.Add("")
    $script:md.Add("| 项目 ID | 名称 | 路径 | 大小 | 明细完整性 | 可恢复性 | 处理方式 |")
    $script:md.Add("|---|---|---|---|---|---|---|")
    foreach ($i in $list) {
        $p = ($i.paths -join '; ')
        if ($p.Length -gt 70) { $p = $p.Substring(0, 70) + '…' }
        $script:md.Add("| $($i.id) | $($i.name) | ``$p`` | $(Fmt $i.size) | $($i.complete) | $($i.recover) | $($i.how) |")
    }
    $script:md.Add("")
}
AddTable "4. 低风险候选项（仍需逐项确认）" $lowItems
AddTable "5. 需要确认项（禁止自动处理）" $cfmItems
AddTable "6. 已保护 / 禁止操作" $proItems

[void]$md.Add("## 7. 可操作项目明细")
[void]$md.Add("")
foreach ($i in ($itemList | Where-Object { $_.risk -ne 'protected' } | Select-Object -First 12)) {
    [void]$md.Add("### [$($i.id)] $($i.name) — $(Fmt $i.size)")
    [void]$md.Add("")
    [void]$md.Add("- 路径：$($i.paths -join '; ')")
    [void]$md.Add("- 文件数：$($i.count)　最近修改：$($i.lastWrite)　明细：$($i.complete)　可恢复性：$($i.recover)")
    [void]$md.Add("- 处理方式：$($i.how)　清理原因：$($i.reason)")
    [void]$md.Add("")
    if ($i.topFiles.Count -gt 0) {
        [void]$md.Add("Top 文件：")
        [void]$md.Add("")
        [void]$md.Add("| 大小 | 最后修改 | 路径 |")
        [void]$md.Add("|---|---|---|")
        foreach ($f in ($i.topFiles | Select-Object -First 8)) {
            [void]$md.Add("| $(Fmt $f.s) | $($f.m) | ``$($f.p)`` |")
        }
        [void]$md.Add("")
    }
    if ($i.topDirs.Count -gt 0) {
        [void]$md.Add("Top 子目录：")
        [void]$md.Add("")
        [void]$md.Add("| 大小 | 路径 |")
        [void]$md.Add("|---|---|")
        foreach ($d in ($i.topDirs | Select-Object -First 5)) {
            [void]$md.Add("| $(Fmt $d.s) | ``$($d.p)`` |")
        }
        [void]$md.Add("")
    }
}

[void]$md.Add("## 8. 推荐方案")
[void]$md.Add("")
[void]$md.Add("1. 只处理低风险项，且必须以管理员身份运行本脚本的清理模式（``-Clean``），逐项确认。")
[void]$md.Add("2. 需要确认项一律不自动处理；确需处理时先按报告中路径打开目录手动查看。")
[void]$md.Add("3. 已保护项在任何情况下都不得手动删除。")
[void]$md.Add("4. 系统级清理优先使用 Windows 存储感知或磁盘清理（cleanmgr）。")
[void]$md.Add("5. 明细不足（超时降级）的项目不得删除或迁移，只允许人工查看。")
[void]$md.Add("")
[void]$md.Add("## 9. 输出文件说明")
[void]$md.Add("")
[void]$md.Add("- 本报告：``$(Join-Path $OutDir 'c_drive_analysis_report.md')``")
[void]$md.Add("- 结构化数据：``$jsonPath``")
[void]$md.Add("- 本脚本为只读扫描 + 显式确认式清理，不存在静默删除行为。")
[void]$md.Add("")
[void]$md.Add("## 10. 主要风险提醒")
[void]$md.Add("")
[void]$md.Add("- 已保护项删除会导致系统无法启动、软件无法卸载或账号数据永久丢失。")
[void]$md.Add("- 下载目录、桌面、文档属于个人文件区，默认只建议打开目录手动查看或移入回收站。")
[void]$md.Add("- 所有释放空间为估算值，实际以清理结束时的可用空间为准。")
[void]$md.Add("- 禁止使用第三方清理软件处理 WinSxS 与 Windows\Installer。")

if ($AssessChannels) {
    [void]$md.Add("## 11. 系统官方通道评估（只读）")
    [void]$md.Add("")
    [void]$md.Add("> 本节只复用本次扫描结果，**未执行任何系统清理命令，未修改系统设置**。占用 ≠ 可回收量；本工具不估算可回收量，合并统计项不拆分，一律标 unknown。")
    [void]$md.Add("")
    [void]$md.Add("| 通道 | 对应清单项 | 当前占用 | 官方命令 / 入口 | 可逆性 | 管理员 | 计划阶段 |")
    [void]$md.Add("|---|---|---|---|---|---|---|")
    foreach ($c in $systemChannels) {
        $occ = if ($null -eq $c.bytes) { 'unknown' } else { Fmt $c.bytes }
        $ids = if ($c.itemIds.Count -gt 0) { $c.itemIds -join ', ' } else { '-' }
        [void]$md.Add("| $($c.name) | $ids | $occ | $($c.command) | $($c.reversible) | $(if($c.admin){'是'}else{'否'}) | $($c.stage) |")
        if ($c.note) { [void]$md.Add(""); [void]$md.Add("> $($c.name)：$($c.note)") }
    }
    [void]$md.Add("")
    [void]$md.Add("下一步需由用户在管理员 PowerShell 中自行确认执行；本工具的 -SystemClean（阶段 C）尚未实现。")
}

$mdPath = Join-Path $OutDir 'c_drive_analysis_report.md'
[System.IO.File]::WriteAllLines($mdPath, $md, (New-Object System.Text.UTF8Encoding($true)))

# 报告归档：把原先散落在调度器里的 Copy-Item 收进工具自身，仅只读扫描生效
if ($ArchiveReport -and -not $Clean) {
    $archivePath = Join-Path $OutDir ("weekly-report-{0}.md" -f (Get-Date -Format 'yyyyMMdd'))
    try {
        Copy-Item -LiteralPath $mdPath -Destination $archivePath -Force -ErrorAction Stop
        Say " 报告已存档：$archivePath" 'DarkGray'
    } catch {
        Say " [注意] 报告存档失败：$($_.Exception.Message)" 'Yellow'
    }
}

$statusPath = Join-Path $OutDir "c_drive_scan_status_$stamp.txt"
$out = @()
$out += "SCAN_DONE"
$out += "REPORT_MD=$mdPath"
$out += "SCAN_JSON=$jsonPath"
$out += "OUT_DIR=$OutDir"
$out += "ITEMS=$($itemList.Count)  LOW=$($lowItems.Count)  CONFIRM=$($cfmItems.Count)  PROTECTED=$($proItems.Count)"
$out += "LOW_SUM_GB=$([math]::Round($lowSum/1GB,2))"
$out += "HEALTH=$health"
$out += "REPORT_OK=$((Test-Path -LiteralPath $mdPath) -and ((Get-Item -LiteralPath $mdPath).Length -gt 0))"
$out += "TOOL_VERSION=$ScriptVersion"
$out += "SCHEMA_VERSION=$SchemaVersion"
$out += "RUN_ID=$RunId"
$out += "CONFIG_SOURCE=$ConfigSource"
$out += "RUN_MODE=$runMode"
$out += "SCAN_SECONDS=$([math]::Round($scanSw.Elapsed.TotalSeconds, 1))"
if ($AssessChannels) {
    $out += "SYSTEM_CHANNEL_COUNT=$($systemChannels.Count)"
    $out += "SYSTEM_CHANNEL_ASSESSED=1"
}
[System.IO.File]::WriteAllLines($statusPath, $out, (New-Object System.Text.UTF8Encoding($false)))

Say " 报告已生成：" 'DarkGray'
Say "   $mdPath" 'DarkGray'
Say "   $jsonPath" 'DarkGray'
Say ""

# ============================================================
# 5. 阶段二：交互式清理（仅在 -Clean 时进入）
# ============================================================
function Show-List($paths, $limit) {
    $all = New-Object System.Collections.ArrayList
    foreach ($p in $paths) {
        $r = [CDriveSz]::Size($p, 0)
        [void]$all.Add([pscustomobject]@{ p = $p; s = $r[0]; n = $r[1] })
    }
    foreach ($x in ($all | Sort-Object s -Descending | Select-Object -First $limit)) {
        Write-Host ("     {0,-12} {1} 个   {2}" -f (Fmt $x.s), $x.n, $x.p) -ForegroundColor DarkGray
    }
    $files = New-Object System.Collections.ArrayList
    foreach ($p in $paths) {
        foreach ($f in [CDriveSz]::TopFiles($p, 6, 0)) {
            [void]$files.Add([pscustomobject]@{ p = $f[0]; s = [long]$f[1] })
        }
    }
    foreach ($f in ($files | Sort-Object s -Descending | Select-Object -First 6)) {
        Write-Host ("     {0,-12} {1}" -f (Fmt $f.s), $f.p) -ForegroundColor DarkGray
    }
}

function Ask($prompt) {
    while ($true) {
        $a = (Read-Host "     $prompt  [Y]执行 / [N]跳过(默认) / [L]列出内容 / [Q]退出").Trim().ToUpper()
        if ($a -eq '' -or $a -eq 'N') { return 'no' }
        if ($a -eq 'Y') { return 'yes' }
        if ($a -eq 'L') { return 'list' }
        if ($a -eq 'Q') { return 'quit' }
        Write-Host "     请输入 Y / N / L / Q" -ForegroundColor DarkYellow
    }
}

function Invoke-Clean($t) {
    Say ""
    Say ("[{0}] {1}" -f $t.id, $t.name) 'Cyan'
    if ($t.note) { Say ("     " + $t.note) 'DarkGray' }

    if ($t.admin -and -not $isAdmin) {
        Say "     [跳过] 需要管理员权限（请用管理员身份重新运行）" 'Yellow'; return 0
    }
    if ($t.complete -ne '完整') {
        Say "     [拒绝] 扫描超时，明细不足，不允许清理该目录" 'Red'; return 0
    }

    $paths = @($t.paths) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    if ($paths.Count -eq 0) { Say "     [跳过] 路径不存在或已为空" 'DarkGray'; return 0 }

    foreach ($p in $paths) {
        if (-not (Guard-Path $p)) { Say "     [拒绝] 高危路径，脚本已阻止: $p" 'Red'; return 0 }
    }

    $total = 0; $cnt = 0
    foreach ($p in $paths) { $r = [CDriveSz]::Size($p, $maxMs); $total += $r[0]; $cnt += $r[1] }
    if ($total -eq 0) { Say "     [跳过] 当前占用 0 字节" 'DarkGray'; return 0 }
    Say ("     当前占用 {0}，共 {1} 个文件" -f (Fmt $total), $cnt) 'Gray'

    $ans = Ask "确认清理这一项？"
    while ($ans -eq 'list') { Show-List $paths 10; $ans = Ask "确认清理这一项？" }
    if ($ans -eq 'quit') { $script:abort = $true; Say "     已请求退出" 'Yellow'; return 0 }
    if ($ans -eq 'no')   { Say "     [已跳过]" 'DarkGray'; Log ("SKIP  " + $t.id); return 0 }

    if ($DryRun) { Say "     [演练模式] 不实际删除" 'Magenta'; return $total }

    if ($t.pre) { & $t.pre }

    $freed = 0
    $fail = 0
    foreach ($p in $paths) {
        $before = ([CDriveSz]::Size($p, $maxMs))[0]
        if ($t.mode -eq 'contents') {
            foreach ($v in @(Get-ChildItem -LiteralPath $p -Force)) {
                try { Remove-Item -LiteralPath $v.FullName -Recurse -Force -ErrorAction Stop } catch { $fail++ }
            }
        } elseif ($t.mode -eq 'files') {
            $g = Get-ChildItem -LiteralPath $p -File -Force -Recurse:([bool]$t.recurse)
            if ($t.filter) { $g = $g | Where-Object { $_.Name -like $t.filter } }
            foreach ($v in @($g)) {
                try { Remove-Item -LiteralPath $v.FullName -Force -ErrorAction Stop } catch { $fail++ }
            }
        }
        $after = ([CDriveSz]::Size($p, $maxMs))[0]
        $freed += ($before - $after)
    }

    if ($t.post) { & $t.post }

    if ($fail -gt 0) { Say ("     [注意] {0} 个对象未能删除（被占用或权限不足）" -f $fail) 'Yellow' }
    Say ("     完成，释放 {0}" -f (Fmt $freed)) 'Green'
    Log ("DONE  {0}  freed={1}  fail={2}" -f $t.id, $freed, $fail)
    return $freed
}

$free0 = GetFree
$totalFreed = 0
$done = 0

if ($Clean -and -not $script:abort) {
    Say "[阶段 2/2] 交互式清理" 'Cyan'
    Say " 说明：回车默认 = 跳过；输入 L 可先看内容再决定；输入 Q 立即退出。" 'DarkGray'
    Say "       被占用的文件会自动跳过，不会强行终止程序。" 'DarkGray'

    $targets = @($items | Where-Object { $_.risk -eq 'low' -and $_.cleanable -eq $true -and $_.mode -ne 'bin' } | Sort-Object size -Descending)
    foreach ($t in $targets) {
        if ($script:abort) { break }
        $freed = Invoke-Clean $t
        $totalFreed += $freed
        if ($freed -gt 0) { $done++ }
    }

    $binItem = @($items | Where-Object { $_.mode -eq 'bin' -and $_.cleanable -eq $true } | Select-Object -First 1)
    if ($binItem.Count -gt 0 -and -not $script:abort) {
        $t = $binItem[0]
        Say ""
        Say ("[{0}] {1}" -f $t.id, $t.name) 'Cyan'
        if ($t.note) { Say ("     " + $t.note) 'DarkGray' }
        $ans = Ask "确认清空回收站？"
        if ($ans -eq 'quit') { $script:abort = $true }
        elseif ($ans -eq 'yes' -and -not $DryRun) {
            $b = [double](GetFree)
            Clear-RecycleBin -DriveLetter C -Force -EA SilentlyContinue
            Say ("     回收站已清空，释放约 {0}" -f (Fmt ([double](GetFree) - $b))) 'Green'
            Log ("DONE  {0}  bin" -f $t.id)
        } else { Say "     [已跳过]" 'DarkGray' }
    }
}

# ============================================================
# 6. 个人文件：只列出，不删除
# ============================================================
if ($ListPersonalFiles -and -not $script:abort) {
    Say ""
    Say "==============================================================" 'White'
    Say " 个人文件：下载 / 桌面的安装包（只列出，不删除）" 'Yellow'
    Say "==============================================================" 'White'
    $cands = @()
    foreach ($d in @("$UP\Downloads", "$UP\Desktop")) {
        if (Test-Path -LiteralPath $d) {
            $cands += @(Get-ChildItem -LiteralPath $d -File -EA SilentlyContinue |
                        Where-Object { $_.Extension -in '.msi','.exe','.zip','.rar','.7z','.iso','.msu','.cab' -and $_.Length -ge 5MB } |
                        Sort-Object Length -Descending)
        }
    }
    if ($cands.Count -eq 0) {
        Say " 没有找到符合条件的安装包（≥5 MB 的 msi/exe/zip/rar/7z/iso/msu/cab）。" 'DarkGray'
    } else {
        $sum = ($cands | Measure-Object -Property Length -Sum).Sum
        Say (" 共 {0} 个，合计 {1}，按大小排序：" -f $cands.Count, (Fmt $sum)) 'Gray'
        Say ""
        foreach ($f in $cands) {
            Say ("  {0,-11} {1}  {2}" -f (Fmt $f.Length), $f.LastWriteTime.ToString('yyyy-MM-dd'), $f.FullName) 'Gray'
        }
        Say ""
        Say " 处理方式：在文件管理器里打开对应目录，确认无用后右键 → 删除（进入回收站，可恢复）。" 'DarkGray'
        Say " 本脚本不代为删除个人文件，避免不可恢复的误删。" 'DarkGray'
    }
}

# ============================================================
# 7. 收尾
# ============================================================
if ($Clean) {
    Say ""
    Say "==============================================================" 'White'
    Say (" 清理结束：执行 {0} 项，累计释放 {1}" -f $done, (Fmt $totalFreed)) 'Green'
    Say (" 可用空间：{0}  ->  {1}" -f (Fmt $free0), (Fmt (GetFree))) 'Green'
    Say "==============================================================" 'White'
    Say ""
    Say " 后续建议（本脚本未执行，需你手动在系统中操作）：" 'Gray'

    $dsPath = "$W\System32\DriverStore\FileRepository"
    if (Test-Path -LiteralPath $dsPath) {
        $dsSize = ([CDriveSz]::Size($dsPath, 60000))[0]
        if ($dsSize -gt 0) { Say ("  - 驱动仓库 DriverStore 实际占用 {0}：磁盘清理 → 勾选 设备驱动程序包" -f (Fmt $dsSize)) 'Gray' }
    }

    Say "  - 组件存储 WinSxS：管理员运行 DISM /Online /Cleanup-Image /StartComponentCleanup" 'Gray'

    $wrPath = 'C:\$WinREAgent'
    if (Test-Path -LiteralPath $wrPath) {
        $wrSize = ([CDriveSz]::Size($wrPath, 60000))[0]
        if ($wrSize -gt 0) { Say ("  - 旧系统残留 `$WinREAgent 实际占用 {0}：设置 → 存储 → 临时文件" -f (Fmt $wrSize)) 'Gray' }
    } else {
        Say '  - 旧系统残留 $WinREAgent：已不存在，无需处理' 'DarkGray'
    }

    Say "  - 不要使用第三方清理软件清理 WinSxS 或 Windows\Installer" 'Gray'

    $logFile = Join-Path $OutDir ("cleanup-log-{0}.txt" -f $stamp)
    [System.IO.File]::WriteAllLines($logFile, $script:logLines, (New-Object System.Text.UTF8Encoding($true)))
    Say ""
    Say (" 日志已保存：{0}" -f $logFile) 'DarkGray'
} else {
    Say " 只读扫描完成，未做任何修改。" 'Green'
    Say " 如需清理，请以管理员身份运行：.\c_drive_tool.ps1 -Clean" 'Gray'
}
