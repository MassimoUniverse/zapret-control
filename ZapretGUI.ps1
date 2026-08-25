# ============================================================
#  Zapret Control 1.1 - GUI manager for zapret-discord-youtube
#  Дизайн: claude.ai/design "Zapret Control дизайн-система"
#  1.1: фоновые операции (окно не зависает), автоподбор стратегии,
#       проверка доступа, punycode, лог в файл, один экземпляр
# ============================================================
param(
    [switch]$TestParse,
    [switch]$TestUI,
    [string]$RootOverride
)

$ErrorActionPreference = 'Stop'
$script:AppVersion = '1.1.1'

# ---------- Где мы лежим ----------
# В собранном .exe $PSScriptRoot / $PSCommandPath / $MyInvocation ПУСТЫЕ (проверено),
# поэтому путь берём из процесса. Без этого exe не найдёт папку запрета рядом с собой.
function Get-AppDir {
    if ($PSScriptRoot) { return $PSScriptRoot }
    try {
        $exe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if ($exe -and ($exe -notmatch '(?i)\\powershell(_ise)?\.exe$')) { return (Split-Path -Parent $exe) }
    } catch {}
    return ([System.AppDomain]::CurrentDomain.BaseDirectory.TrimEnd('\'))
}
$script:AppDir = Get-AppDir

# ---------- Elevation ----------
# В exe права запрашивает манифест (requireAdmin), сюда попадаем только в режиме .ps1
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $TestParse -and -not $TestUI) {
    if ($PSCommandPath) {
        Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
    } else {
        try { Start-Process ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -Verb RunAs } catch {}
    }
    exit
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# ---------- Single instance ----------
$script:MutexCreated = $false
if (-not $TestParse -and -not $TestUI) {
    $script:AppMutex = New-Object System.Threading.Mutex($true, 'Global\ZapretControlGUI', [ref]$script:MutexCreated)
    if (-not $script:MutexCreated) {
        [System.Windows.MessageBox]::Show('Zapret Control уже запущен — окно должно быть на панели задач.', 'Zapret Control', 'OK', 'Information') | Out-Null
        exit
    }
}

# ---------- Root detection ----------
# имя папки, которую заводим сами, если ставим zapret с нуля
$script:HomeFolderName = 'Zapret Control'

function Find-ZapretRoot {
    if ($RootOverride) { return $RootOverride }
    $candidates = @()
    try {
        $img = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\zapret' -ErrorAction Stop).ImagePath
        if ($img -match '"?([^"]*?winws\.exe)') {
            $candidates += (Split-Path (Split-Path $Matches[1] -Parent) -Parent)
        }
    } catch {}
    $bases = @()
    if ($script:AppDir) {
        $candidates += $script:AppDir
        $bases += $script:AppDir
        $bases += (Join-Path $script:AppDir $script:HomeFolderName)
        $bases += (Split-Path -Parent $script:AppDir)
    }
    $bases += (Join-Path 'C:\' $script:HomeFolderName)
    $bases += 'C:\'
    # любая папка zapret-discord-youtube* рядом с приложением, в нашей папке или в корне C:
    foreach ($base in $bases) {
        try {
            Get-ChildItem -LiteralPath $base -Directory -Filter 'zapret-discord-youtube*' -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending | ForEach-Object { $candidates += $_.FullName }
        } catch {}
    }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path (Join-Path $c 'bin\winws.exe'))) { return $c }
    }
    return $null
}

# ---------- Загрузка zapret (первая установка и обновление) ----------
$script:VersionUrl = 'https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/main/.service/version.txt'
$script:ReleaseApi = 'https://api.github.com/repos/Flowseal/zapret-discord-youtube/releases/latest'
$script:MirrorPage = 'https://sourceforge.net/projects/flowseal.mirror/files/'

function Get-LatestZip {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    try {
        $r = Invoke-RestMethod -Uri $script:ReleaseApi -TimeoutSec 20 -Headers @{ 'User-Agent' = 'zapret-gui' }
        $asset = $r.assets | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1
        if ($asset) { return @{ Version = $r.tag_name; Url = $asset.browser_download_url; Src = 'GitHub' } }
    } catch {}
    # запасной путь — зеркало SourceForge (когда GitHub недоступен)
    $sf = Invoke-RestMethod -Uri 'https://sourceforge.net/projects/flowseal.mirror/best_release.json' -TimeoutSec 20
    $ver = ($sf.release.filename -split '/' | Where-Object { $_ }) | Select-Object -First 1
    if (-not $sf.release.url) { throw 'Не удалось получить ссылку на скачивание' }
    return @{ Version = $ver; Url = $sf.release.url; Src = 'SourceForge' }
}

# Наши доработки: игровые правила -> отдельный ipset-game.txt
function Apply-Customizations([string]$targetRoot) {
    $enc = New-Object System.Text.UTF8Encoding($false)
    $changed = 0
    Get-ChildItem -LiteralPath $targetRoot -Filter 'general*.bat' -ErrorAction SilentlyContinue | ForEach-Object {
        $raw = Get-Content -LiteralPath $_.FullName -Raw
        $orig = $raw
        $raw = $raw -replace '(--filter-tcp=%GameFilterTCP%) --ipset="%LISTS%ipset-all\.txt"', '$1 --ipset="%LISTS%ipset-game.txt"'
        $raw = $raw -replace '(--filter-udp=%GameFilterUDP%) --ipset="%LISTS%ipset-all\.txt"', '$1 --ipset="%LISTS%ipset-game.txt"'
        if ($raw -ne $orig) { [System.IO.File]::WriteAllText($_.FullName, $raw, $enc); $changed++ }
    }
    return $changed
}

# Пользовательские списки + наши обязательные исключения (Twitch/OBS)
function Ensure-DefaultLists([string]$targetRoot) {
    $l = Join-Path $targetRoot 'lists'
    $u = Join-Path $targetRoot 'utils'
    foreach ($d in @($l, $u)) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null } }
    $ipsetExcl = Join-Path $l 'ipset-exclude-user.txt'
    $genUser   = Join-Path $l 'list-general-user.txt'
    $exclUser  = Join-Path $l 'list-exclude-user.txt'
    $gameIpset = Join-Path $l 'ipset-game.txt'
    if (-not (Test-Path $ipsetExcl)) { Set-Content -LiteralPath $ipsetExcl -Value '203.0.113.113/32' -Encoding ASCII }
    if (-not (Test-Path $genUser))   { Set-Content -LiteralPath $genUser -Value "# Never leave this file empty`r`ndomain.example.abc" -Encoding ASCII }
    if (-not (Test-Path $exclUser))  { Set-Content -LiteralPath $exclUser -Value 'domain.example.abc' -Encoding ASCII }
    if (-not (Test-Path $gameIpset)) { Set-Content -LiteralPath $gameIpset -Value '203.0.113.113/32' -Encoding ASCII }
    $cur = Get-Content -LiteralPath $exclUser -ErrorAction SilentlyContinue
    $need = @('twitch.tv', 'ttvnw.net', 'jtvnw.net', 'live-video.net') | Where-Object { $cur -notcontains $_ }
    if ($need) { Add-Content -LiteralPath $exclUser -Value $need -Encoding ASCII }
}

# Куда ставить: рядом с приложением, но НИКОГДА не россыпью в корень диска
function Get-InstallBase {
    $b = if ($script:AppDir) { $script:AppDir } else { 'C:\' }
    if ($b -match '^[A-Za-z]:\\?$') { $b = Join-Path $b $script:HomeFolderName }
    try {
        if (-not (Test-Path -LiteralPath $b)) { New-Item -ItemType Directory -Force -Path $b | Out-Null }
        $probe = Join-Path $b ('.w_' + [Guid]::NewGuid().ToString('N'))
        [System.IO.File]::WriteAllText($probe, 'x'); [System.IO.File]::Delete($probe)
        return $b
    } catch {
        $fb = Join-Path 'C:\' $script:HomeFolderName
        if (-not (Test-Path -LiteralPath $fb)) { New-Item -ItemType Directory -Force -Path $fb | Out-Null }
        return $fb
    }
}

# Первая установка: качает свежий zapret и кладёт одной папкой
function Install-ZapretFresh {
    $rel = Get-LatestZip
    $folderName = 'zapret-discord-youtube-' + ($rel.Version -replace '[^\w\.\-]', '')
    $dest = Join-Path (Get-InstallBase) $folderName

    $tmp = Join-Path $env:TEMP ('zapret_new_' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $zip = Join-Path $tmp 'z.zip'
        Invoke-WebRequest -Uri $rel.Url -OutFile $zip -TimeoutSec 300 -UseBasicParsing
        $ex = Join-Path $tmp 'ex'
        Expand-Archive -LiteralPath $zip -DestinationPath $ex -Force
        $newRoot = Get-ChildItem -LiteralPath $ex -Directory -ErrorAction SilentlyContinue |
                   Where-Object { Test-Path (Join-Path $_.FullName 'bin\winws.exe') } |
                   Select-Object -First 1 -ExpandProperty FullName
        if (-not $newRoot) {
            if (Test-Path (Join-Path $ex 'bin\winws.exe')) { $newRoot = $ex } else { throw 'В архиве не найден bin\winws.exe' }
        }
        Apply-Customizations $newRoot | Out-Null
        Ensure-DefaultLists $newRoot
        if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Force -Path $dest | Out-Null }
        robocopy $newRoot $dest /E /NFL /NDL /NJH /NJS /NP /R:2 /W:1 2>$null | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "Ошибка распаковки (robocopy $LASTEXITCODE)" }
        return $dest
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$script:Root = Find-ZapretRoot
if (-not $script:Root) {
    if ($TestParse -or $TestUI) { Write-Host 'Zapret folder not found'; exit 1 }
    # запрета на компьютере нет — предлагаем скачать и поставить сами
    $ans = [System.Windows.MessageBox]::Show(
        "Zapret не найден на этом компьютере." + [Environment]::NewLine + [Environment]::NewLine +
        "Скачать последнюю версию и установить автоматически?" + [Environment]::NewLine +
        "Папка будет создана рядом с приложением, наши настройки применятся сразу.",
        'Zapret Control', 'YesNo', 'Question')
    if ($ans -ne 'Yes') { exit 1 }
    try {
        $script:Root = Install-ZapretFresh
        [System.Windows.MessageBox]::Show(
            "Zapret установлен:" + [Environment]::NewLine + $script:Root + [Environment]::NewLine + [Environment]::NewLine +
            "Дальше выбери стратегию и нажми «Установить службу», либо открой вкладку «Проверка» и нажми «Подобрать».",
            'Готово', 'OK', 'Information') | Out-Null
    } catch {
        [System.Windows.MessageBox]::Show(
            "Не удалось скачать zapret:" + [Environment]::NewLine + $_.Exception.Message + [Environment]::NewLine + [Environment]::NewLine +
            "Скачай вручную и положи папку рядом с приложением:" + [Environment]::NewLine + $script:MirrorPage,
            'Ошибка', 'OK', 'Error') | Out-Null
        exit 1
    }
}
$script:Root  = (Resolve-Path $script:Root).Path
$script:Bin   = Join-Path $script:Root 'bin\'
$script:Lists = Join-Path $script:Root 'lists\'
$script:Utils = Join-Path $script:Root 'utils\'

# ---------- File log ----------
# основной лог лежит рядом с запретом (utils\zapret-gui.log); если туда нельзя писать
# (папка только на чтение) — уходим в %LOCALAPPDATA%\ZapretControl
$script:LogDir  = $script:Utils
$script:LogFile = Join-Path $script:Utils 'zapret-gui.log'
function Init-FileLog {
    try {
        if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Force $script:LogDir | Out-Null }
        $probe = Join-Path $script:LogDir ('.w_' + [Guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($probe, 'x'); [IO.File]::Delete($probe)
    } catch {
        $script:LogDir  = Join-Path $env:LOCALAPPDATA 'ZapretControl'
        $script:LogFile = Join-Path $script:LogDir 'zapret-gui.log'
    }
    try {
        if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Force $script:LogDir | Out-Null }
        if ((Test-Path $script:LogFile) -and (Get-Item $script:LogFile).Length -gt 1MB) {
            $old = "$script:LogFile.old"
            if ([IO.File]::Exists($old)) { [IO.File]::Delete($old) }
            [IO.File]::Move($script:LogFile, $old)
        }
    } catch {}
}
function Write-FileLog([string]$msg) {
    try { [IO.File]::AppendAllText($script:LogFile, ('{0}  {1}{2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg, [Environment]::NewLine), [Text.Encoding]::UTF8) } catch {}
}

# ---------- Core logic ----------

function Get-GameFilter {
    $f = Join-Path $script:Utils 'game_filter.enabled'
    if (-not (Test-Path $f)) {
        return @{ TCP='12'; UDP='12'; Both='12'; Mode='off' }
    }
    $mode = ''
    $raw = Get-Content -LiteralPath $f -TotalCount 1 -ErrorAction SilentlyContinue
    if ($raw) { $mode = $raw.Trim() }
    switch -Regex ($mode) {
        '^(?i)all$' { return @{ TCP='1024-65535'; UDP='1024-65535'; Both='1024-65535'; Mode='all' } }
        '^(?i)tcp$' { return @{ TCP='1024-65535'; UDP='12';         Both='1024-65535'; Mode='tcp' } }
        default     { return @{ TCP='12';         UDP='1024-65535'; Both='1024-65535'; Mode='udp' } }
    }
}

# Стратегией считается только .bat, внутри которого реально запускается winws.exe.
# Иначе в список попадает наш собственный лаунчер "Zapret GUI.bat", лежащий в той же папке.
function Get-StrategyFiles {
    Get-ChildItem -LiteralPath $script:Root -Filter '*.bat' |
        Where-Object { $_.Name -notlike 'service*' } |
        Where-Object {
            try { [bool](Select-String -LiteralPath $_.FullName -SimpleMatch 'winws.exe' -Quiet -ErrorAction Stop) }
            catch { $false }
        } |
        Sort-Object { [regex]::Replace($_.Name, '\d+', { $args[0].Value.PadLeft(8, '0') }) }
}

function Get-StrategyArgs([string]$batFile) {
    $lines = Get-Content -LiteralPath $batFile
    $cmd = $null
    $capture = $false
    foreach ($line in $lines) {
        if (-not $capture -and $line -match 'winws\.exe') { $capture = $true }
        if ($capture) {
            $t = $line.Trim()
            $cont = $t.EndsWith('^')
            if ($cont) { $t = $t.Substring(0, $t.Length - 1).Trim() }
            if ($cmd) { $cmd = "$cmd $t" } else { $cmd = $t }
            if (-not $cont) { break }
        }
    }
    if (-not $cmd) { throw "В файле не найден запуск winws.exe: $batFile" }
    $marker = 'winws.exe"'
    $idx = $cmd.IndexOf($marker)
    if ($idx -lt 0) { throw "Не удалось выделить аргументы winws в: $batFile" }
    $argStr = $cmd.Substring($idx + $marker.Length).Trim()
    $gf = Get-GameFilter
    $argStr = $argStr.Replace('%GameFilterTCP%', $gf.TCP)
    $argStr = $argStr.Replace('%GameFilterUDP%', $gf.UDP)
    $argStr = $argStr.Replace('%GameFilter%',    $gf.Both)
    $argStr = $argStr.Replace('%BIN%',   $script:Bin)
    $argStr = $argStr.Replace('%LISTS%', $script:Lists)
    return $argStr
}

function Get-StrategyBinPath([string]$strategyName) {
    $bat = Join-Path $script:Root ($strategyName + '.bat')
    if (-not (Test-Path -LiteralPath $bat)) { throw "Файл стратегии не найден: $bat" }
    return ('"{0}winws.exe" {1}' -f $script:Bin, (Get-StrategyArgs $bat))
}

function Ensure-UserLists {
    $ipsetExcl = Join-Path $script:Lists 'ipset-exclude-user.txt'
    $genUser   = Join-Path $script:Lists 'list-general-user.txt'
    $exclUser  = Join-Path $script:Lists 'list-exclude-user.txt'
    if (-not (Test-Path $ipsetExcl)) { Set-Content -LiteralPath $ipsetExcl -Value '203.0.113.113/32' -Encoding ASCII }
    if (-not (Test-Path $genUser))   { Set-Content -LiteralPath $genUser -Value "# Never leave this file empty`r`ndomain.example.abc" -Encoding ASCII }
    if (-not (Test-Path $exclUser))  { Set-Content -LiteralPath $exclUser -Value 'domain.example.abc' -Encoding ASCII }
}

function Get-CurrentStrategy {
    try {
        return (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\zapret' -ErrorAction Stop).'zapret-discord-youtube'
    } catch { return $null }
}

function Get-LocalVersion {
    try {
        $m = Select-String -LiteralPath (Join-Path $script:Root 'service.bat') -Pattern 'LOCAL_VERSION=([^"]+)' -ErrorAction Stop
        if ($m) { return $m.Matches[0].Groups[1].Value.Trim() }
    } catch {}
    return '?'
}

function Test-Faceit { Test-Path (Join-Path $script:Utils 'faceit.enabled') }

function Set-Faceit([bool]$on) {
    $faceitFlag = Join-Path $script:Utils 'faceit.enabled'
    $gameFlag   = Join-Path $script:Utils 'game_filter.enabled'
    $gameIpset  = Join-Path $script:Lists 'ipset-game.txt'
    if ($on) {
        Set-Content -LiteralPath $faceitFlag -Value 'enabled' -Encoding ASCII
        Set-Content -LiteralPath $gameFlag   -Value 'all'     -Encoding ASCII
        Set-Content -LiteralPath $gameIpset  -Value '0.0.0.0/0' -Encoding ASCII
    } else {
        if ([IO.File]::Exists($faceitFlag)) { [IO.File]::Delete($faceitFlag) }
        if ([IO.File]::Exists($gameFlag))   { [IO.File]::Delete($gameFlag) }
        Set-Content -LiteralPath $gameIpset  -Value '203.0.113.113/32' -Encoding ASCII
    }
}

function Set-GameFilterMode([string]$mode) {
    $gameFlag = Join-Path $script:Utils 'game_filter.enabled'
    if ($mode -eq 'off') {
        if ([IO.File]::Exists($gameFlag)) { [IO.File]::Delete($gameFlag) }
    } else {
        Set-Content -LiteralPath $gameFlag -Value $mode -Encoding ASCII
    }
}

# IPSet-статус с кэшем: раньше читали весь файл (543 КБ / 32k строк) каждые 3 сек
$script:IpsetCache = @{ stamp = $null; value = 'any' }
function Get-IpsetStatus {
    $listFile = Join-Path $script:Lists 'ipset-all.txt'
    if (-not (Test-Path $listFile)) { return 'any' }
    $fi = Get-Item -LiteralPath $listFile
    $stamp = '{0}|{1}' -f $fi.LastWriteTimeUtc.Ticks, $fi.Length
    if ($script:IpsetCache.stamp -eq $stamp) { return $script:IpsetCache.value }

    $value = 'loaded'
    if ($fi.Length -eq 0) {
        $value = 'any'
    } else {
        $first = Get-Content -LiteralPath $listFile -TotalCount 1 -ErrorAction SilentlyContinue
        if ($first -and $first.Trim() -eq '203.0.113.113/32') { $value = 'none' }
    }
    $script:IpsetCache = @{ stamp = $stamp; value = $value }
    return $value
}

# Кириллические/IDN домены -> punycode (иначе ASCII-запись превращала их в ?????)
function ConvertTo-Punycode([string]$line) {
    $t = $line.Trim()
    if ($t -eq '' -or $t.StartsWith('#')) { return $line }
    if ($t -match '^[\x00-\x7F]+$') { return $line }
    try { return (New-Object System.Globalization.IdnMapping).GetAscii($t) } catch { return $line }
}

# ---------- Test modes ----------
if ($TestParse) {
    Write-Host "AppDir: $script:AppDir"
    Write-Host "Root: $script:Root"
    $gf = Get-GameFilter
    Write-Host ("GameFilter: mode={0} TCP={1} UDP={2}" -f $gf.Mode, $gf.TCP, $gf.UDP)
    Write-Host ("IPSet: {0}" -f (Get-IpsetStatus))
    Write-Host ("Punycode: {0}" -f (ConvertTo-Punycode 'президент.рф'))
    foreach ($f in Get-StrategyFiles) {
        $a = Get-StrategyArgs $f.FullName
        Write-Host ('--- {0}  ({1} символов, {2} правил)' -f $f.Name, $a.Length, ([regex]::Matches($a, '--new').Count + 1))
    }
    # сверка: то, что построит приложение, против того, что реально стоит в службе
    $curStrat = Get-CurrentStrategy
    if ($curStrat) {
        try {
            $expected = Get-StrategyBinPath $curStrat
            $actual = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\zapret' -ErrorAction Stop).ImagePath
            Write-Host ''
            Write-Host ("Установленная стратегия: {0}" -f $curStrat)
            if ($expected -eq $actual) {
                Write-Host 'СВЕРКА: строка запуска совпадает с установленной службой'
            } else {
                Write-Host 'СВЕРКА: РАСХОЖДЕНИЕ со службой'
                Write-Host ("  служба:     {0}" -f $actual)
                Write-Host ("  приложение: {0}" -f $expected)
            }
        } catch { Write-Host ("Сверка не удалась: {0}" -f $_.Exception.Message) }
    }
    exit 0
}

# ---------- Проверяемые домены ----------
$script:TestTargets = @(
    @{ host='www.youtube.com';            label='YouTube' }
    @{ host='redirector.googlevideo.com'; label='YouTube видео (CDN)' }
    @{ host='discord.com';                label='Discord' }
    @{ host='gateway.discord.gg';         label='Discord голос/шлюз' }
    @{ host='cdn.discordapp.com';         label='Discord картинки' }
    @{ host='i.ytimg.com';                label='YouTube превью' }
)
# для автоподбора берём короткий набор, чтобы перебор шёл быстро
$script:PickTargets = @('www.youtube.com', 'redirector.googlevideo.com', 'discord.com', 'gateway.discord.gg')

# ---------- Фоновая инфраструктура ----------
$script:BgQueue  = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
$script:BgPs     = $null
$script:BgHandle = $null
$script:BgOnDone = $null
$script:BgCancel = $null

$script:BgPrelude = @'
function BgLog([string]$m)  { $BGQ.Enqueue(@{ t='log';  msg=$m }) }
function BgBusy([string]$m) { $BGQ.Enqueue(@{ t='busy'; msg=$m }) }
function BgDiag([string]$tag, [string]$text) { $BGQ.Enqueue(@{ t='diag'; tag=$tag; text=$text }) }
function BgTest([string]$key, [string]$label, [string]$state, [string]$note) {
    $BGQ.Enqueue(@{ t='test'; key=$key; label=$label; state=$state; note=$note })
}
function BgStopped { return [bool]$CANCEL.stop }

# ВАЖНО: не передавать сюда PowerShell-callback проверки сертификата —
# в фоновом потоке у скриптблока нет runspace и ЛЮБОЙ домен помечается недоступным.
function Test-TlsDomain([string]$domain, [int]$timeoutMs = 6000) {
    $tcp = $null; $ssl = $null
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.ReceiveTimeout = $timeoutMs; $tcp.SendTimeout = $timeoutMs
        $iar = $tcp.BeginConnect($domain, 443, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($timeoutMs, $false)) { return @{ ok=$false; why='нет ответа (таймаут)' } }
        $tcp.EndConnect($iar)
        $ssl = New-Object System.Net.Security.SslStream($tcp.GetStream(), $false)
        $ssl.ReadTimeout = $timeoutMs; $ssl.WriteTimeout = $timeoutMs
        $task = $ssl.AuthenticateAsClientAsync($domain, $null, [System.Security.Authentication.SslProtocols]::Tls12, $false)
        $done = $false
        try { $done = $task.Wait($timeoutMs) } catch { return @{ ok=$false; why='соединение сброшено (похоже на DPI)' } }
        if (-not $done) { return @{ ok=$false; why='TLS таймаут (похоже на блокировку)' } }
        return @{ ok=$true; why='' }
    } catch {
        $m = $_.Exception.GetBaseException().Message
        if ($m -match 'неизвест|not known|not be resolved') { return @{ ok=$false; why='домен не найден (DNS)' } }
        return @{ ok=$false; why=(($m -split "`r?`n")[0]) }
    } finally {
        if ($ssl) { try { $ssl.Dispose() } catch {} }
        if ($tcp) { try { $tcp.Close() } catch {} }
    }
}

function Remove-ZapretSvc {
    & sc.exe stop zapret   2>&1 | Out-Null
    & sc.exe delete zapret 2>&1 | Out-Null
    Get-Process -Name winws -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    foreach ($wd in 'WinDivert','WinDivert14') {
        if (Get-Service -Name $wd -ErrorAction SilentlyContinue) {
            & sc.exe stop $wd   2>&1 | Out-Null
            & sc.exe delete $wd 2>&1 | Out-Null
        }
    }
}

function Get-SvcFailReason {
    try {
        $ev = Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='Service Control Manager'; StartTime=(Get-Date).AddMinutes(-3) } -MaxEvents 25 -ErrorAction SilentlyContinue |
              Where-Object { $_.Message -match 'zapret' } | Select-Object -First 1
        if ($ev) { return (($ev.Message -replace '\s+', ' ').Trim()) }
    } catch {}
    return ''
}

function Get-LatestZipBg {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    try {
        $r = Invoke-RestMethod -Uri 'https://api.github.com/repos/Flowseal/zapret-discord-youtube/releases/latest' -TimeoutSec 20 -Headers @{ 'User-Agent' = 'zapret-gui' }
        $asset = $r.assets | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1
        if ($asset) { return @{ Version = $r.tag_name; Url = $asset.browser_download_url; Src = 'GitHub' } }
    } catch {}
    $sf = Invoke-RestMethod -Uri 'https://sourceforge.net/projects/flowseal.mirror/best_release.json' -TimeoutSec 20
    $ver = ($sf.release.filename -split '/' | Where-Object { $_ }) | Select-Object -First 1
    if (-not $sf.release.url) { throw 'Не удалось получить ссылку на скачивание' }
    return @{ Version = $ver; Url = $sf.release.url; Src = 'SourceForge' }
}

function Apply-CustomizationsBg([string]$targetRoot) {
    $enc = New-Object System.Text.UTF8Encoding($false)
    $changed = 0
    Get-ChildItem -LiteralPath $targetRoot -Filter 'general*.bat' -ErrorAction SilentlyContinue | ForEach-Object {
        $raw = Get-Content -LiteralPath $_.FullName -Raw
        $orig = $raw
        $raw = $raw -replace '(--filter-tcp=%GameFilterTCP%) --ipset="%LISTS%ipset-all\.txt"', '$1 --ipset="%LISTS%ipset-game.txt"'
        $raw = $raw -replace '(--filter-udp=%GameFilterUDP%) --ipset="%LISTS%ipset-all\.txt"', '$1 --ipset="%LISTS%ipset-game.txt"'
        if ($raw -ne $orig) { [System.IO.File]::WriteAllText($_.FullName, $raw, $enc); $changed++ }
    }
    return $changed
}

function Install-ZapretSvc([string]$binPath, [string]$name) {
    Remove-ZapretSvc
    & netsh interface tcp set global timestamps=enabled 2>&1 | Out-Null
    $created = $false
    for ($i = 0; $i -lt 6 -and -not $created; $i++) {
        try {
            New-Service -Name zapret -BinaryPathName $binPath -DisplayName 'zapret' -Description 'Zapret DPI bypass software' -StartupType Automatic -ErrorAction Stop | Out-Null
            $created = $true
        } catch { Start-Sleep -Milliseconds 600 }
    }
    if (-not $created) { return @{ ok=$false; err='не удалось создать службу (старая помечена на удаление)' } }
    try { Start-Service -Name zapret -ErrorAction Stop }
    catch {
        $reason = Get-SvcFailReason
        $msg = $_.Exception.Message
        if ($reason) { $msg = "$msg | журнал Windows: $reason" }
        return @{ ok=$false; err=$msg }
    }
    try { Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\zapret' -Name 'zapret-discord-youtube' -Value $name } catch {}
    return @{ ok=$true; err='' }
}
'@

function Start-Bg {
    param(
        [string]$Body,
        [hashtable]$Params = @{},
        [scriptblock]$OnDone = $null,
        [string]$BusyText = 'Работаю...',
        [bool]$Cancellable = $false
    )
    if ($script:BgPs) { Log 'Дождись окончания текущей операции'; return $false }
    $script:BgCancel = [hashtable]::Synchronized(@{ stop = $false })
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('CTX', $Params)
    $rs.SessionStateProxy.SetVariable('BGQ', $script:BgQueue)
    $rs.SessionStateProxy.SetVariable('CANCEL', $script:BgCancel)
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($script:BgPrelude + "`n" + $Body)
    $script:BgPs     = $ps
    $script:BgHandle = $ps.BeginInvoke()
    $script:BgOnDone = $OnDone
    Show-Busy $BusyText $Cancellable
    return $true
}

# ---------- XAML ----------
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Zapret Control" Width="1000" Height="780" MinWidth="880" MinHeight="640"
        Background="#0A0F0C" FontFamily="Segoe UI" WindowStartupLocation="CenterScreen"
        WindowStyle="None" ResizeMode="CanResize">

  <WindowChrome.WindowChrome>
    <WindowChrome CaptionHeight="0" ResizeBorderThickness="6" GlassFrameThickness="0,0,0,1" CornerRadius="0" UseAeroCaptionButtons="False"/>
  </WindowChrome.WindowChrome>

  <Window.Resources>

    <SolidColorBrush x:Key="TextHi"    Color="#EAF2EC"/>
    <SolidColorBrush x:Key="TextMid"   Color="#8CA396"/>
    <SolidColorBrush x:Key="TextLow"   Color="#5A6E60"/>
    <SolidColorBrush x:Key="TextBody"  Color="#B9CBBF"/>
    <SolidColorBrush x:Key="Green"     Color="#2FBF71"/>
    <SolidColorBrush x:Key="GreenHi"   Color="#34D399"/>
    <SolidColorBrush x:Key="GreenText" Color="#5FD6A0"/>
    <SolidColorBrush x:Key="OnGreen"   Color="#06120B"/>
    <SolidColorBrush x:Key="Red"       Color="#E5534B"/>
    <SolidColorBrush x:Key="RedText"   Color="#E97B74"/>
    <SolidColorBrush x:Key="Amber"     Color="#D6A243"/>
    <SolidColorBrush x:Key="CardBg"    Color="#101712"/>
    <SolidColorBrush x:Key="WellBg"    Color="#07100A"/>
    <SolidColorBrush x:Key="SideBg"    Color="#080C09"/>
    <SolidColorBrush x:Key="Line"      Color="#1E2B22"/>
    <SolidColorBrush x:Key="LineHover" Color="#2A3B30"/>

    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource CardBg}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="14"/>
      <Setter Property="Padding" Value="22,20"/>
      <Setter Property="Margin" Value="0,0,0,16"/>
    </Style>

    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource TextHi}"/>
    </Style>

    <Style x:Key="Muted" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource TextMid}"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>

    <Style x:Key="Kicker" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource TextLow}"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>

    <Style x:Key="Hair" TargetType="Rectangle">
      <Setter Property="Height" Value="1"/>
      <Setter Property="Fill" Value="{StaticResource Line}"/>
    </Style>

    <Style TargetType="Button">
      <Setter Property="Background" Value="#131B15"/>
      <Setter Property="Foreground" Value="{StaticResource TextHi}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="Padding" Value="16,10"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="13.5"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="1" CornerRadius="9" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#182018"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource LineHover}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Accent" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="{StaticResource Green}"/>
      <Setter Property="Foreground" Value="{StaticResource OnGreen}"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="18,10"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderThickness="0" CornerRadius="9" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource GreenHi}"/>
                <Setter TargetName="Bd" Property="Effect">
                  <Setter.Value>
                    <DropShadowEffect Color="#34D399" BlurRadius="18" ShadowDepth="0" Opacity="0.4"/>
                  </Setter.Value>
                </Setter>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Opacity" Value="0.35"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Danger" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="{StaticResource Red}"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="1" CornerRadius="9" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#14E5534B"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="#30E5534B"/>
                <Setter Property="Foreground" Value="{StaticResource RedText}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="DangerSolid" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="{StaticResource Red}"/>
      <Setter Property="Foreground" Value="#160707"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="20,9"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderThickness="0" CornerRadius="9" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#EC6259"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="WinBtn" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="Foreground" Value="{StaticResource TextMid}"/>
      <Setter Property="Padding" Value="0"/>
      <Setter Property="Width" Value="28"/>
      <Setter Property="Height" Value="28"/>
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="9"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="6">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#131B15"/>
                <Setter Property="Foreground" Value="{StaticResource TextHi}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="WinBtnClose" TargetType="Button" BasedOn="{StaticResource WinBtn}">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="6">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#22E5534B"/>
                <Setter Property="Foreground" Value="{StaticResource TextHi}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="SwitchLg" TargetType="ToggleButton">
      <Setter Property="Width" Value="56"/>
      <Setter Property="Height" Value="32"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToggleButton">
            <Border x:Name="Track" CornerRadius="16" Background="#1E2B22">
              <Ellipse x:Name="Thumb" Width="24" Height="24" Fill="#5A6E60" HorizontalAlignment="Left" Margin="4,0,4,0"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Track" Property="Background" Value="{StaticResource Green}"/>
                <Setter TargetName="Thumb" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="Thumb" Property="Fill" Value="{StaticResource OnGreen}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Track" Property="Opacity" Value="0.4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Switch" TargetType="ToggleButton">
      <Setter Property="Width" Value="46"/>
      <Setter Property="Height" Value="26"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToggleButton">
            <Border x:Name="Track" CornerRadius="13" Background="#1E2B22">
              <Ellipse x:Name="Thumb" Width="20" Height="20" Fill="#5A6E60" HorizontalAlignment="Left" Margin="3,0,3,0"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Track" Property="Background" Value="{StaticResource Green}"/>
                <Setter TargetName="Thumb" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="Thumb" Property="Fill" Value="{StaticResource OnGreen}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Track" Property="Opacity" Value="0.4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="{StaticResource TextBody}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="Bd" Background="Transparent" CornerRadius="6" Padding="11,8" Margin="5,1">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#131B15"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#152FBF71"/>
                <Setter Property="Foreground" Value="{StaticResource GreenText}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ComboBox">
      <Setter Property="Foreground" Value="{StaticResource TextHi}"/>
      <Setter Property="Height" Value="40"/>
      <Setter Property="FontSize" Value="13.5"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <ToggleButton Focusable="False" ClickMode="Press"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border x:Name="Bd" Background="#0A0F0C" BorderBrush="#1E2B22" BorderThickness="1" CornerRadius="9">
                      <Path x:Name="Caret" HorizontalAlignment="Right" Margin="0,0,14,0" VerticalAlignment="Center"
                            Data="M 0 0 L 4.5 4.5 L 9 0 Z" Fill="#5A6E60"/>
                    </Border>
                    <ControlTemplate.Triggers>
                      <Trigger Property="IsMouseOver" Value="True">
                        <Setter TargetName="Bd" Property="BorderBrush" Value="#2A3B30"/>
                      </Trigger>
                      <Trigger Property="IsChecked" Value="True">
                        <Setter TargetName="Bd" Property="BorderBrush" Value="#2A3B30"/>
                        <Setter TargetName="Caret" Property="Fill" Value="#34D399"/>
                      </Trigger>
                    </ControlTemplate.Triggers>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <ContentPresenter Margin="14,0,32,0" VerticalAlignment="Center" IsHitTestVisible="False"
                                Content="{TemplateBinding SelectionBoxItem}"
                                ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"/>
              <Popup IsOpen="{TemplateBinding IsDropDownOpen}" Placement="Bottom" AllowsTransparency="True" StaysOpen="False">
                <Border Background="#101712" BorderBrush="#2A3B30" BorderThickness="1" CornerRadius="10"
                        MinWidth="{TemplateBinding ActualWidth}" MaxHeight="330" Margin="0,6,0,0">
                  <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <ItemsPresenter Margin="0,4"/>
                  </ScrollViewer>
                </Border>
              </Popup>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="TextBox">
      <Setter Property="Background" Value="{StaticResource WellBg}"/>
      <Setter Property="Foreground" Value="{StaticResource TextBody}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CaretBrush" Value="#34D399"/>
      <Setter Property="Padding" Value="12,10"/>
      <Setter Property="SelectionBrush" Value="#2FBF71"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="10">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ScrollBar">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Width" Value="9"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.Thumb>
                  <Thumb>
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Border Background="#1E2B22" CornerRadius="4" Margin="2,0"/>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/>
          <Setter Property="Height" Value="9"/>
          <Setter Property="Template">
            <Setter.Value>
              <ControlTemplate TargetType="ScrollBar">
                <Grid Background="Transparent">
                  <Track x:Name="PART_Track" IsDirectionReversed="False">
                    <Track.Thumb>
                      <Thumb>
                        <Thumb.Template>
                          <ControlTemplate TargetType="Thumb">
                            <Border Background="#1E2B22" CornerRadius="4" Margin="0,2"/>
                          </ControlTemplate>
                        </Thumb.Template>
                      </Thumb>
                    </Track.Thumb>
                  </Track>
                </Grid>
              </ControlTemplate>
            </Setter.Value>
          </Setter>
        </Trigger>
      </Style.Triggers>
    </Style>

    <Style TargetType="TabControl">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="TabStripPlacement" Value="Left"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabControl">
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="216"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <Border Grid.Column="0" Background="{StaticResource SideBg}" BorderBrush="{StaticResource Line}" BorderThickness="0,0,1,0">
                <DockPanel>
                  <TextBlock DockPanel.Dock="Bottom" Text="zapret · dpi bypass" Margin="22,0,0,16"
                             FontFamily="Consolas" FontSize="11" Foreground="#3F4E45"/>
                  <StackPanel IsItemsHost="True" Margin="12,16,12,0"/>
                </DockPanel>
              </Border>
              <Border Grid.Column="1" Padding="26,22,26,0" Margin="0,0,0,100">
                <ContentPresenter ContentSource="SelectedContent"/>
              </Border>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="TabItem">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="Bd" CornerRadius="8" Margin="0,2" Background="Transparent" Cursor="Hand" Padding="12,10,14,10">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Border x:Name="Bar" Grid.Column="0" Width="3" Height="16" CornerRadius="2" Background="Transparent" Margin="0,0,9,0"/>
                <TextBlock x:Name="Ico" Grid.Column="1" FontFamily="Segoe UI Symbol" FontSize="14"
                           Text="{TemplateBinding Tag}" Foreground="{StaticResource TextLow}" VerticalAlignment="Center"/>
                <ContentPresenter x:Name="Hdr" Grid.Column="2" ContentSource="Header" Margin="12,0,0,0"
                                  VerticalAlignment="Center" TextElement.Foreground="{StaticResource TextMid}" TextElement.FontSize="14"/>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#131B15"/>
                <Setter TargetName="Bar" Property="Background" Value="{StaticResource Green}"/>
                <Setter TargetName="Ico" Property="Foreground" Value="{StaticResource GreenHi}"/>
                <Setter TargetName="Hdr" Property="TextElement.Foreground" Value="{StaticResource TextHi}"/>
                <Setter TargetName="Hdr" Property="TextElement.FontWeight" Value="Medium"/>
              </Trigger>
              <MultiTrigger>
                <MultiTrigger.Conditions>
                  <Condition Property="IsMouseOver" Value="True"/>
                  <Condition Property="IsSelected" Value="False"/>
                </MultiTrigger.Conditions>
                <Setter TargetName="Bd" Property="Background" Value="#0F1712"/>
                <Setter TargetName="Hdr" Property="TextElement.Foreground" Value="{StaticResource TextBody}"/>
                <Setter TargetName="Ico" Property="Foreground" Value="{StaticResource TextMid}"/>
              </MultiTrigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

  </Window.Resources>

  <Border BorderBrush="{StaticResource Line}" BorderThickness="1">
    <Grid>
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="58"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="100"/>
        </Grid.RowDefinitions>

        <Border x:Name="TitleBar" Grid.Row="0" Background="Transparent" BorderBrush="{StaticResource Line}" BorderThickness="0,0,0,1">
          <Grid>
            <StackPanel Orientation="Horizontal" Margin="20,0,0,0" VerticalAlignment="Center">
              <Border Width="15" Height="15" CornerRadius="3" RenderTransformOrigin="0.5,0.5" VerticalAlignment="Center">
                <Border.Background>
                  <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                    <GradientStop Color="#34D399" Offset="0"/>
                    <GradientStop Color="#2FBF71" Offset="1"/>
                  </LinearGradientBrush>
                </Border.Background>
                <Border.RenderTransform><RotateTransform Angle="45"/></Border.RenderTransform>
                <Border.Effect><DropShadowEffect Color="#2FBF71" BlurRadius="14" ShadowDepth="0" Opacity="0.4"/></Border.Effect>
              </Border>
              <TextBlock Text="Z&#x2009;A&#x2009;P&#x2009;R&#x2009;E&#x2009;T&#x2009;&#x2009;&#x2009;C&#x2009;O&#x2009;N&#x2009;T&#x2009;R&#x2009;O&#x2009;L"
                         FontSize="13" FontWeight="SemiBold" Margin="13,0,0,0" VerticalAlignment="Center"/>
              <TextBlock FontSize="11.5" Margin="12,1,0,0" VerticalAlignment="Center" Foreground="{StaticResource TextLow}">
                <Hyperlink x:Name="LnkTg" Foreground="#5FD6A0" TextDecorations="None">by Massimo</Hyperlink>
              </TextBlock>
            </StackPanel>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,14,0">
              <TextBlock x:Name="TxtRoot" FontFamily="Consolas" FontSize="11" Foreground="{StaticResource TextLow}" VerticalAlignment="Center" Margin="0,0,18,0"/>
              <Button x:Name="BtnMin" Style="{StaticResource WinBtn}" Content="&#xE921;"/>
              <Button x:Name="BtnClose" Style="{StaticResource WinBtnClose}" Content="&#xE8BB;" Margin="6,0,0,0"/>
            </StackPanel>
          </Grid>
        </Border>

        <TabControl x:Name="MainTabs" Grid.Row="1" Grid.RowSpan="2">

          <TabItem Header="Управление" Tag="&#x25C8;">
            <ScrollViewer VerticalScrollBarVisibility="Auto" Margin="0,0,-10,0" Padding="0,0,10,0">
              <StackPanel>

                <Border Style="{StaticResource Card}">
                  <StackPanel>
                    <TextBlock Text="С&#x2009;Л&#x2009;У&#x2009;Ж&#x2009;Б&#x2009;А" Style="{StaticResource Kicker}"/>
                    <Grid Margin="0,12,0,0">
                      <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                        <TextBlock Text="Zapret" FontSize="26" FontWeight="SemiBold" VerticalAlignment="Center"/>
                        <Border x:Name="PillService" CornerRadius="6" Padding="12,5" Background="#148CA396"
                                BorderBrush="#288CA396" BorderThickness="1" VerticalAlignment="Center" Margin="14,3,0,0">
                          <StackPanel Orientation="Horizontal">
                            <Ellipse x:Name="DotService" Width="7" Height="7" Fill="#5A6E60" VerticalAlignment="Center"/>
                            <TextBlock x:Name="TxtService" Text="—" FontSize="12.5" FontWeight="Medium" Foreground="{StaticResource TextMid}" Margin="7,0,0,0"/>
                          </StackPanel>
                        </Border>
                      </StackPanel>
                      <ToggleButton x:Name="TglService" Style="{StaticResource SwitchLg}" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                    </Grid>
                    <TextBlock x:Name="TxtStrategy" Style="{StaticResource Muted}" FontSize="13" Margin="0,10,0,0"/>
                    <Rectangle Style="{StaticResource Hair}" Margin="0,18,0,18"/>
                    <Grid>
                      <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="Auto"/>
                      </Grid.ColumnDefinitions>
                      <ComboBox x:Name="CmbStrategy" Grid.Column="0" HorizontalAlignment="Stretch"/>
                      <Button x:Name="BtnInstall" Grid.Column="1" Content="Установить службу" Style="{StaticResource Accent}" Margin="10,0,0,0"/>
                      <Button x:Name="BtnRemove" Grid.Column="2" Content="Удалить" Style="{StaticResource Danger}" Margin="4,0,0,0"/>
                    </Grid>
                    <TextBlock x:Name="TxtWarn" Text="Настройки изменены — переустанови службу, чтобы применить"
                               Foreground="{StaticResource Amber}" FontSize="12.5" Margin="0,12,0,0" Visibility="Collapsed"/>
                    <StackPanel Orientation="Horizontal" Margin="0,16,0,0">
                      <Ellipse x:Name="DotWinws" Width="6" Height="6" Fill="#5A6E60" VerticalAlignment="Center"/>
                      <TextBlock x:Name="TxtWinws" Text="winws.exe" FontFamily="Consolas" FontSize="11.5" Foreground="{StaticResource TextMid}" Margin="7,0,22,0"/>
                      <Ellipse x:Name="DotDivert" Width="6" Height="6" Fill="#5A6E60" VerticalAlignment="Center"/>
                      <TextBlock x:Name="TxtDivert" Text="WinDivert" FontFamily="Consolas" FontSize="11.5" Foreground="{StaticResource TextMid}" Margin="7,0,0,0"/>
                    </StackPanel>
                  </StackPanel>
                </Border>

                <Border Style="{StaticResource Card}">
                  <Grid>
                    <StackPanel MaxWidth="560" HorizontalAlignment="Left">
                      <TextBlock Text="И&#x2009;Г&#x2009;Р&#x2009;О&#x2009;В&#x2009;О&#x2009;Й&#x2009;&#x2009;Р&#x2009;Е&#x2009;Ж&#x2009;И&#x2009;М" Style="{StaticResource Kicker}"/>
                      <TextBlock Text="FACEIT" FontSize="18" FontWeight="SemiBold" Margin="0,10,0,0"/>
                      <TextBlock Style="{StaticResource Muted}" FontSize="13" Margin="0,6,0,0"
                                 Text="Игровой обход на все IP (порты 1024–65535) — нужен для FACEIT и CS2. Не задевает браузер и OBS. Выключай, когда не играешь."/>
                    </StackPanel>
                    <ToggleButton x:Name="TglFaceit" Style="{StaticResource SwitchLg}" HorizontalAlignment="Right" VerticalAlignment="Top"/>
                  </Grid>
                </Border>

                <Border Style="{StaticResource Card}">
                  <StackPanel>
                    <TextBlock Text="П&#x2009;А&#x2009;Р&#x2009;А&#x2009;М&#x2009;Е&#x2009;Т&#x2009;Р&#x2009;Ы" Style="{StaticResource Kicker}" Margin="0,0,0,6"/>
                    <Grid Margin="0,14,0,14">
                      <StackPanel VerticalAlignment="Center">
                        <TextBlock Text="Game Filter" FontSize="14.5" FontWeight="Medium"/>
                        <TextBlock Text="Диапазоны портов для игрового трафика" Foreground="{StaticResource TextMid}" FontSize="12.5" Margin="0,3,0,0"/>
                      </StackPanel>
                      <ComboBox x:Name="CmbGame" Width="190" Height="38" HorizontalAlignment="Right">
                        <ComboBoxItem Content="Выключен"/>
                        <ComboBoxItem Content="TCP и UDP"/>
                        <ComboBoxItem Content="Только TCP"/>
                        <ComboBoxItem Content="Только UDP"/>
                      </ComboBox>
                    </Grid>
                    <Rectangle Style="{StaticResource Hair}"/>
                    <Grid Margin="0,14,0,14">
                      <StackPanel VerticalAlignment="Center">
                        <TextBlock Text="IPSet список" FontSize="14.5" FontWeight="Medium"/>
                        <TextBlock x:Name="TxtIpset" Text="" Foreground="{StaticResource TextMid}" FontSize="12.5" Margin="0,3,0,0"/>
                      </StackPanel>
                      <Button x:Name="BtnIpsetUpdate" Content="Обновить список" HorizontalAlignment="Right" Padding="15,9"/>
                    </Grid>
                    <Rectangle Style="{StaticResource Hair}"/>
                    <Grid Margin="0,14,0,0">
                      <StackPanel VerticalAlignment="Center">
                        <TextBlock Text="Автопроверка обновлений" FontSize="14.5" FontWeight="Medium"/>
                        <TextBlock Text="Проверять новые версии zapret при запуске" Foreground="{StaticResource TextMid}" FontSize="12.5" Margin="0,3,0,0"/>
                      </StackPanel>
                      <ToggleButton x:Name="TglUpd" Style="{StaticResource Switch}" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                    </Grid>
                  </StackPanel>
                </Border>

                <!-- Обновление самого zapret -->
                <Border Style="{StaticResource Card}">
                  <Grid>
                    <StackPanel MaxWidth="560" HorizontalAlignment="Left">
                      <TextBlock Text="О&#x2009;Б&#x2009;Н&#x2009;О&#x2009;В&#x2009;Л&#x2009;Е&#x2009;Н&#x2009;И&#x2009;Е" Style="{StaticResource Kicker}"/>
                      <TextBlock x:Name="TxtVerLocal" Text="Установлено: —" FontSize="14.5" FontWeight="Medium" Margin="0,10,0,0"/>
                      <TextBlock x:Name="TxtVerLatest" Text="Нажми «Проверить», чтобы узнать о новой версии"
                                 Foreground="{StaticResource TextMid}" FontSize="12.5" Margin="0,4,0,0" TextWrapping="Wrap"/>
                    </StackPanel>
                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                      <Button x:Name="BtnCheckUpd" Content="Проверить" Padding="15,9"/>
                      <Button x:Name="BtnDoUpd" Content="Обновить" Style="{StaticResource Accent}" Margin="8,0,0,0" Visibility="Collapsed"/>
                    </StackPanel>
                  </Grid>
                </Border>

              </StackPanel>
            </ScrollViewer>
          </TabItem>

          <TabItem Header="Проверка" Tag="&#x25CE;">
            <Grid>
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
              </Grid.RowDefinitions>

              <Border Grid.Row="0" Style="{StaticResource Card}">
                <Grid>
                  <StackPanel MaxWidth="560" HorizontalAlignment="Left">
                    <TextBlock Text="П&#x2009;Р&#x2009;О&#x2009;В&#x2009;Е&#x2009;Р&#x2009;К&#x2009;А&#x2009;&#x2009;Д&#x2009;О&#x2009;С&#x2009;Т&#x2009;У&#x2009;П&#x2009;А" Style="{StaticResource Kicker}"/>
                    <TextBlock Text="Работает ли обход" FontSize="18" FontWeight="SemiBold" Margin="0,10,0,0"/>
                    <TextBlock Style="{StaticResource Muted}" FontSize="13" Margin="0,6,0,0"
                               Text="Приложение само стучится к каждому сайту по TLS и смотрит, отвечает ли он. Зелёный — обход работает, красный — сайт не открывается."/>
                  </StackPanel>
                  <Button x:Name="BtnRunTests" Content="Проверить сейчас" Style="{StaticResource Accent}" HorizontalAlignment="Right" VerticalAlignment="Top"/>
                </Grid>
              </Border>

              <Border Grid.Row="1" Background="{StaticResource WellBg}" BorderBrush="{StaticResource Line}" BorderThickness="1"
                      CornerRadius="14" Padding="8,10" Margin="0,0,0,16">
                <ScrollViewer VerticalScrollBarVisibility="Auto">
                  <StackPanel x:Name="TestList"/>
                </ScrollViewer>
              </Border>

              <Border Grid.Row="2" Style="{StaticResource Card}">
                <Grid>
                  <StackPanel MaxWidth="560" HorizontalAlignment="Left">
                    <TextBlock Text="А&#x2009;В&#x2009;Т&#x2009;О&#x2009;П&#x2009;О&#x2009;Д&#x2009;Б&#x2009;О&#x2009;Р" Style="{StaticResource Kicker}"/>
                    <TextBlock Text="Найти рабочую стратегию" FontSize="16" FontWeight="SemiBold" Margin="0,8,0,0"/>
                    <TextBlock Style="{StaticResource Muted}" FontSize="12.5" Margin="0,5,0,0"
                               Text="Перебирает стратегии: ставит каждую и проверяет доступ. Останавливается на первой, где всё работает, и оставляет её. Занимает до нескольких минут, интернет в это время будет прерываться."/>
                  </StackPanel>
                  <Button x:Name="BtnAutoPick" Content="Подобрать" Style="{StaticResource Accent}" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                </Grid>
              </Border>
            </Grid>
          </TabItem>

          <TabItem Header="Списки" Tag="&#x25A4;">
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="16"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <Border Style="{StaticResource Card}" Grid.Column="0" Margin="0,0,0,16">
                <Grid>
                  <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="Auto"/>
                  </Grid.RowDefinitions>
                  <TextBlock Grid.Row="0" Text="И&#x2009;С&#x2009;К&#x2009;Л&#x2009;Ю&#x2009;Ч&#x2009;Е&#x2009;Н&#x2009;И&#x2009;Я" Style="{StaticResource Kicker}"/>
                  <WrapPanel Grid.Row="1" Margin="0,10,0,8">
                    <TextBlock Text="Не обходить" FontSize="17" FontWeight="SemiBold" VerticalAlignment="Center"/>
                    <Border Background="#0A0F0C" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="6" Padding="9,3" Margin="10,2,0,2" VerticalAlignment="Center">
                      <TextBlock Text="list-exclude-user.txt" FontFamily="Consolas" FontSize="11.5" Foreground="{StaticResource TextMid}"/>
                    </Border>
                  </WrapPanel>
                  <TextBlock Grid.Row="2" Style="{StaticResource Muted}" FontSize="12.5" Margin="0,0,0,14"
                             Text="Домены, которые провайдер НЕ блокирует. Twitch и live-video.net не убирать: без них ломается видео и стрим из OBS."/>
                  <TextBox x:Name="TxtExclude" Grid.Row="3" AcceptsReturn="True" VerticalScrollBarVisibility="Auto"
                           FontFamily="Consolas" FontSize="12.5"/>
                  <Button x:Name="BtnSaveExclude" Grid.Row="4" Content="Сохранить" Style="{StaticResource Accent}"
                          HorizontalAlignment="Right" Margin="0,14,0,0" Padding="22,10"/>
                </Grid>
              </Border>
              <Border Style="{StaticResource Card}" Grid.Column="2" Margin="0,0,0,16">
                <Grid>
                  <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="Auto"/>
                  </Grid.RowDefinitions>
                  <TextBlock Grid.Row="0" Text="О&#x2009;Б&#x2009;Х&#x2009;О&#x2009;Д" Style="{StaticResource Kicker}"/>
                  <WrapPanel Grid.Row="1" Margin="0,10,0,8">
                    <TextBlock Text="Дополнительно в обход" FontSize="17" FontWeight="SemiBold" VerticalAlignment="Center"/>
                    <Border Background="#0A0F0C" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="6" Padding="9,3" Margin="10,2,0,2" VerticalAlignment="Center">
                      <TextBlock Text="list-general-user.txt" FontFamily="Consolas" FontSize="11.5" Foreground="{StaticResource TextMid}"/>
                    </Border>
                  </WrapPanel>
                  <TextBlock Grid.Row="2" Style="{StaticResource Muted}" FontSize="12.5" Margin="0,0,0,14"
                             Text="Домены, которые провайдер блокирует, а стокового списка не хватило. Файл не должен быть пустым."/>
                  <TextBox x:Name="TxtGeneral" Grid.Row="3" AcceptsReturn="True" VerticalScrollBarVisibility="Auto"
                           FontFamily="Consolas" FontSize="12.5"/>
                  <Button x:Name="BtnSaveGeneral" Grid.Row="4" Content="Сохранить" Style="{StaticResource Accent}"
                          HorizontalAlignment="Right" Margin="0,14,0,0" Padding="22,10"/>
                </Grid>
              </Border>
            </Grid>
          </TabItem>

          <TabItem Header="Диагностика" Tag="&#x25C7;">
            <Grid>
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
              </Grid.RowDefinitions>
              <WrapPanel Grid.Row="0" Margin="0,0,0,6">
                <Button x:Name="BtnDiag" Content="Запустить диагностику" Style="{StaticResource Accent}" Margin="0,0,10,10" Padding="20,11"/>
                <Button x:Name="BtnReport" Content="Скопировать отчёт" Margin="0,0,10,10" Padding="18,11"/>
                <Button x:Name="BtnRestartSvc" Content="Перезапустить службу" Margin="0,0,10,10" Padding="18,11"/>
                <Button x:Name="BtnOpenFolder" Content="Открыть папку" Margin="0,0,10,10" Padding="18,11"/>
                <Button x:Name="BtnKillWinws" Content="Остановить winws.exe" Margin="0,0,10,10" Padding="18,11"/>
                <Button x:Name="BtnFixDivert" Content="Удалить WinDivert" Margin="0,0,10,10" Padding="18,11"/>
                <Button x:Name="BtnDiscordCache" Content="Очистить кэш Discord" Margin="0,0,10,10" Padding="18,11"/>
                <Button x:Name="BtnOpenLog" Content="Папка с логом" Margin="0,0,10,10" Padding="18,11"/>
              </WrapPanel>
              <Border Grid.Row="1" Background="{StaticResource WellBg}" BorderBrush="{StaticResource Line}" BorderThickness="1"
                      CornerRadius="14" Padding="14,12" Margin="0,0,0,16">
                <RichTextBox x:Name="TxtDiag" IsReadOnly="True" Background="Transparent" BorderThickness="0"
                             FontFamily="Consolas" FontSize="12.5" Foreground="{StaticResource TextBody}"
                             VerticalScrollBarVisibility="Auto">
                  <FlowDocument PagePadding="0"/>
                </RichTextBox>
              </Border>
            </Grid>
          </TabItem>

        </TabControl>

        <Border Grid.Row="2" Background="{StaticResource SideBg}" BorderBrush="{StaticResource Line}" BorderThickness="0,1,0,0"
                Margin="217,0,0,0" Padding="26,12,26,10">
          <Grid>
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <TextBlock Grid.Row="0" Text="Ж&#x2009;У&#x2009;Р&#x2009;Н&#x2009;А&#x2009;Л" FontSize="10.5" FontWeight="SemiBold" Foreground="{StaticResource TextLow}"/>
            <TextBox x:Name="TxtLog" Grid.Row="1" IsReadOnly="True" BorderThickness="0" Background="Transparent"
                     FontFamily="Consolas" FontSize="11.5" Foreground="{StaticResource TextMid}"
                     VerticalScrollBarVisibility="Auto" Padding="0" Margin="0,6,0,0"/>
          </Grid>
        </Border>
      </Grid>

      <!-- Confirm dialog -->
      <Grid x:Name="DialogOverlay" Background="#99040705" Visibility="Collapsed">
        <Border Width="400" Background="{StaticResource CardBg}" BorderBrush="{StaticResource LineHover}" BorderThickness="1"
                CornerRadius="14" Padding="24" VerticalAlignment="Center" HorizontalAlignment="Center">
          <Border.Effect><DropShadowEffect Color="#000000" BlurRadius="60" ShadowDepth="10" Opacity="0.6"/></Border.Effect>
          <StackPanel>
            <TextBlock x:Name="DlgTitle" FontSize="16" FontWeight="SemiBold" TextWrapping="Wrap"/>
            <TextBlock x:Name="DlgMsg" Style="{StaticResource Muted}" FontSize="13" Margin="0,10,0,0"/>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,22,0,0">
              <Button x:Name="DlgNo" Content="Нет" Padding="20,9"/>
              <Button x:Name="DlgYes" Content="Да" Style="{StaticResource DangerSolid}" Margin="10,0,0,0"/>
            </StackPanel>
          </StackPanel>
        </Border>
      </Grid>

      <!-- Busy overlay: не закрывает шапку, чтобы во время долгих операций
           окно можно было двигать и сворачивать -->
      <Grid x:Name="BusyOverlay" Background="#B3040705" Visibility="Collapsed" Margin="0,58,0,0">
        <Border Background="{StaticResource CardBg}" BorderBrush="{StaticResource LineHover}" BorderThickness="1"
                CornerRadius="14" Padding="28,24" VerticalAlignment="Center" HorizontalAlignment="Center" MinWidth="340">
          <Border.Effect><DropShadowEffect Color="#000000" BlurRadius="60" ShadowDepth="10" Opacity="0.6"/></Border.Effect>
          <StackPanel>
            <Grid Width="34" Height="34" HorizontalAlignment="Center">
              <Ellipse Stroke="#1E2B22" StrokeThickness="3"/>
              <Path Stroke="#34D399" StrokeThickness="3" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                    Data="M 17,1.5 A 15.5,15.5 0 0 1 32.5,17">
                <Path.RenderTransform><RotateTransform CenterX="17" CenterY="17"/></Path.RenderTransform>
                <Path.Triggers>
                  <EventTrigger RoutedEvent="FrameworkElement.Loaded">
                    <BeginStoryboard>
                      <Storyboard>
                        <DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(RotateTransform.Angle)"
                                         From="0" To="360" Duration="0:0:1.1" RepeatBehavior="Forever"/>
                      </Storyboard>
                    </BeginStoryboard>
                  </EventTrigger>
                </Path.Triggers>
              </Path>
            </Grid>
            <TextBlock x:Name="BusyText" Text="Работаю..." FontSize="14.5" FontWeight="Medium"
                       HorizontalAlignment="Center" Margin="0,16,0,0" TextWrapping="Wrap" TextAlignment="Center" MaxWidth="420"/>
            <TextBlock x:Name="BusySub" Text="Идёт в фоне — окно можно свернуть" Foreground="{StaticResource TextLow}"
                       FontSize="12" HorizontalAlignment="Center" Margin="0,7,0,0"/>
            <Button x:Name="BtnBusyCancel" Content="Отменить" HorizontalAlignment="Center" Margin="0,18,0,0" Visibility="Collapsed"/>
          </StackPanel>
        </Border>
      </Grid>
    </Grid>
  </Border>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$win = [Windows.Markup.XamlReader]::Load($reader)

$ui = @{}
foreach ($n in @('TitleBar','BtnMin','BtnClose','TxtRoot','PillService','DotService','TxtService','TglService','TxtStrategy',
                 'CmbStrategy','BtnInstall','BtnRemove','TxtWarn',
                 'DotWinws','TxtWinws','DotDivert','TxtDivert','TglFaceit','CmbGame','TxtIpset','BtnIpsetUpdate','TglUpd',
                 'BtnRunTests','TestList','BtnAutoPick',
                 'TxtExclude','BtnSaveExclude','TxtGeneral','BtnSaveGeneral',
                 'TxtVerLocal','TxtVerLatest','BtnCheckUpd','BtnDoUpd','LnkTg',
                 'BtnDiag','BtnReport','BtnRestartSvc','BtnOpenFolder','BtnKillWinws','BtnFixDivert','BtnDiscordCache','BtnOpenLog','TxtDiag','TxtLog',
                 'DialogOverlay','DlgTitle','DlgMsg','DlgYes','DlgNo',
                 'BusyOverlay','BusyText','BusySub','BtnBusyCancel','MainTabs')) {
    $ui[$n] = $win.FindName($n)
}

if ($TestUI) {
    $missing = @($ui.GetEnumerator() | Where-Object { -not $_.Value } | ForEach-Object { $_.Key })
    if ($missing.Count) { Write-Host "MISSING: $($missing -join ', ')"; exit 1 }
    Write-Host 'UI OK'
    exit 0
}

# ---------- UI helpers ----------
function BrushOf([string]$hex) {
    New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($hex))
}
$BrGreen   = BrushOf '#34D399'
$BrGreenTx = BrushOf '#5FD6A0'
$BrRed     = BrushOf '#E5534B'
$BrRedTx   = BrushOf '#E97B74'
$BrGray    = BrushOf '#5A6E60'
$BrGrayTx  = BrushOf '#8CA396'
$BrAmber   = BrushOf '#D6A243'
$BrBody    = BrushOf '#B9CBBF'
$BrPillOnBg   = BrushOf '#182FBF71'
$BrPillOnBd   = BrushOf '#302FBF71'
$BrPillOffBg  = BrushOf '#18E5534B'
$BrPillOffBd  = BrushOf '#30E5534B'
$BrPillNoneBg = BrushOf '#148CA396'
$BrPillNoneBd = BrushOf '#288CA396'

$DotGlow = New-Object System.Windows.Media.Effects.DropShadowEffect
$DotGlow.Color = [System.Windows.Media.ColorConverter]::ConvertFromString('#34D399')
$DotGlow.BlurRadius = 8; $DotGlow.ShadowDepth = 0; $DotGlow.Opacity = 0.6

function Log([string]$msg) {
    $ts = Get-Date -Format 'HH:mm:ss'
    $ui.TxtLog.AppendText("$ts  $msg`r`n")
    if ($ui.TxtLog.Text.Length -gt 60000) { $ui.TxtLog.Text = $ui.TxtLog.Text.Substring(30000) }
    $ui.TxtLog.ScrollToEnd()
    Write-FileLog $msg
}

function Show-Warn { $ui.TxtWarn.Visibility = 'Visible' }
function Hide-Warn { $ui.TxtWarn.Visibility = 'Collapsed' }

function Show-Busy([string]$text, [bool]$cancellable) {
    $ui.BusyText.Text = $text
    $ui.BtnBusyCancel.Visibility = $(if ($cancellable) { 'Visible' } else { 'Collapsed' })
    $ui.BusyOverlay.Visibility = 'Visible'
}
function Hide-Busy { $ui.BusyOverlay.Visibility = 'Collapsed' }

$ui.BtnBusyCancel.Add_Click({
    if ($script:BgCancel) { $script:BgCancel.stop = $true; $ui.BusyText.Text = 'Останавливаю...'; $ui.BtnBusyCancel.Visibility = 'Collapsed' }
})

# ---------- Dialogs ----------
$script:DialogAction = $null
$script:DialogCancel = $null

function Show-Info([string]$title, [string]$message) {
    $ui.DlgTitle.Text = $title
    $ui.DlgMsg.Text = $message
    $ui.DlgYes.Visibility = 'Collapsed'
    $ui.DlgNo.Content = 'ОК'
    $script:DialogAction = $null; $script:DialogCancel = $null
    $ui.DialogOverlay.Visibility = 'Visible'
}

function Show-Confirm([string]$title, [string]$message, [string]$yesText, [bool]$danger, [scriptblock]$onYes, [scriptblock]$onNo) {
    $ui.DlgTitle.Text = $title
    $ui.DlgMsg.Text = $message
    $ui.DlgYes.Visibility = 'Visible'
    $ui.DlgYes.Content = $yesText
    if ($danger) { $ui.DlgYes.Style = $win.FindResource('DangerSolid') } else { $ui.DlgYes.Style = $win.FindResource('Accent') }
    $ui.DlgNo.Content = 'Нет'
    $script:DialogAction = $onYes
    $script:DialogCancel = $onNo
    $ui.DialogOverlay.Visibility = 'Visible'
}

$ui.DlgYes.Add_Click({
    $ui.DialogOverlay.Visibility = 'Collapsed'
    $a = $script:DialogAction; $script:DialogAction = $null; $script:DialogCancel = $null
    if ($a) { & $a }
})
$ui.DlgNo.Add_Click({
    $ui.DialogOverlay.Visibility = 'Collapsed'
    $c = $script:DialogCancel; $script:DialogAction = $null; $script:DialogCancel = $null
    if ($c) { & $c }
})

# ---------- Diagnostics / tests output ----------
function Add-Diag([string]$tag, [string]$text) {
    $color = switch ($tag) { 'OK' { '#34D399' } '!' { '#D6A243' } 'X' { '#E5534B' } default { '#5A6E60' } }
    $p = New-Object System.Windows.Documents.Paragraph
    $p.Margin = New-Object System.Windows.Thickness 0
    $p.LineHeight = 22
    $r1 = New-Object System.Windows.Documents.Run ("[$tag] ")
    $r1.Foreground = BrushOf $color
    $r1.FontWeight = 'SemiBold'
    $r2 = New-Object System.Windows.Documents.Run $text
    $r2.Foreground = $BrBody
    $p.Inlines.Add($r1); $p.Inlines.Add($r2)
    $ui.TxtDiag.Document.Blocks.Add($p)
    $ui.TxtDiag.ScrollToEnd()
}

$script:TestRows = @{}
function Set-TestRow([string]$key, [string]$label, [string]$state, [string]$note) {
    if (-not $script:TestRows.ContainsKey($key)) {
        $row = New-Object System.Windows.Controls.Grid
        $row.Margin = New-Object System.Windows.Thickness 6,5,6,5
        $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = 'Auto'
        $c2 = New-Object System.Windows.Controls.ColumnDefinition
        $c3 = New-Object System.Windows.Controls.ColumnDefinition; $c3.Width = 'Auto'
        $row.ColumnDefinitions.Add($c1); $row.ColumnDefinitions.Add($c2); $row.ColumnDefinitions.Add($c3)

        $dot = New-Object System.Windows.Shapes.Ellipse
        $dot.Width = 7; $dot.Height = 7; $dot.Fill = $BrGray
        $dot.VerticalAlignment = 'Center'; $dot.Margin = New-Object System.Windows.Thickness 6,0,0,0
        [System.Windows.Controls.Grid]::SetColumn($dot, 0)

        $name = New-Object System.Windows.Controls.TextBlock
        $name.FontFamily = New-Object System.Windows.Media.FontFamily 'Consolas'
        $name.FontSize = 12.5; $name.Foreground = $BrBody
        $name.VerticalAlignment = 'Center'; $name.Margin = New-Object System.Windows.Thickness 12,0,10,0
        $name.TextTrimming = 'CharacterEllipsis'
        [System.Windows.Controls.Grid]::SetColumn($name, 1)

        $st = New-Object System.Windows.Controls.TextBlock
        $st.FontSize = 12.5; $st.FontWeight = 'Medium'; $st.VerticalAlignment = 'Center'
        $st.Margin = New-Object System.Windows.Thickness 0,0,8,0
        [System.Windows.Controls.Grid]::SetColumn($st, 2)

        $row.Children.Add($dot) | Out-Null
        $row.Children.Add($name) | Out-Null
        $row.Children.Add($st) | Out-Null
        $ui.TestList.Children.Add($row) | Out-Null
        $script:TestRows[$key] = @{ dot = $dot; name = $name; state = $st }
    }
    $r = $script:TestRows[$key]
    $r.name.Text = if ($label) { "$key   ($label)" } else { $key }
    switch ($state) {
        'run'  { $r.dot.Fill = $BrAmber; $r.dot.Effect = $null; $r.state.Text = 'проверяю...'; $r.state.Foreground = $BrGrayTx }
        'ok'   { $r.dot.Fill = $BrGreen; $r.dot.Effect = $DotGlow; $r.state.Text = 'работает';  $r.state.Foreground = $BrGreenTx }
        'fail' { $r.dot.Fill = $BrRed;   $r.dot.Effect = $null; $r.state.Text = $(if ($note) { $note } else { 'не открывается' }); $r.state.Foreground = $BrRedTx }
        default { $r.dot.Fill = $BrGray; $r.dot.Effect = $null; $r.state.Text = $note; $r.state.Foreground = $BrGrayTx }
    }
}

# ---------- Status ----------
$script:updating = $false
$script:LastTestSummary = 'не запускалась'

function Update-Status {
    $script:updating = $true
    try {
        $svc = Get-Service -Name zapret -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') {
            $ui.DotService.Fill = $BrGreen; $ui.DotService.Effect = $DotGlow
            $ui.TxtService.Text = 'Активна'; $ui.TxtService.Foreground = $BrGreenTx
            $ui.PillService.Background = $BrPillOnBg; $ui.PillService.BorderBrush = $BrPillOnBd
            $ui.TglService.IsChecked = $true
        } elseif ($svc) {
            $ui.DotService.Fill = $BrRed; $ui.DotService.Effect = $null
            $ui.TxtService.Text = 'Остановлена'; $ui.TxtService.Foreground = $BrRedTx
            $ui.PillService.Background = $BrPillOffBg; $ui.PillService.BorderBrush = $BrPillOffBd
            $ui.TglService.IsChecked = $false
        } else {
            $ui.DotService.Fill = $BrGray; $ui.DotService.Effect = $null
            $ui.TxtService.Text = 'Не установлена'; $ui.TxtService.Foreground = $BrGrayTx
            $ui.PillService.Background = $BrPillNoneBg; $ui.PillService.BorderBrush = $BrPillNoneBd
            $ui.TglService.IsChecked = $false
        }

        $strat = Get-CurrentStrategy
        $ui.TxtStrategy.Inlines.Clear()
        if ($strat) {
            $r1 = New-Object System.Windows.Documents.Run 'Стратегия: '
            $r2 = New-Object System.Windows.Documents.Run $strat
            $r2.Foreground = $BrBody
            $r3 = New-Object System.Windows.Documents.Run ' · автозапуск при включении ПК'
            $ui.TxtStrategy.Inlines.Add($r1); $ui.TxtStrategy.Inlines.Add($r2); $ui.TxtStrategy.Inlines.Add($r3)
        } else {
            $ui.TxtStrategy.Inlines.Add((New-Object System.Windows.Documents.Run 'Стратегия не выбрана — установи службу'))
        }

        if (Get-Process -Name winws -ErrorAction SilentlyContinue) {
            $ui.DotWinws.Fill = $BrGreen; $ui.TxtWinws.Text = 'winws.exe запущен'
        } else {
            $ui.DotWinws.Fill = $BrGray; $ui.TxtWinws.Text = 'winws.exe не запущен'
        }

        $wd = Get-Service -Name WinDivert -ErrorAction SilentlyContinue
        if ($wd -and $wd.Status -eq 'Running') { $ui.DotDivert.Fill = $BrGreen; $ui.TxtDivert.Text = 'WinDivert активен' }
        elseif ($wd)                           { $ui.DotDivert.Fill = $BrAmber; $ui.TxtDivert.Text = "WinDivert: $($wd.Status)" }
        else                                   { $ui.DotDivert.Fill = $BrGray;  $ui.TxtDivert.Text = 'WinDivert не активен' }

        $ui.TglFaceit.IsChecked = (Test-Faceit)

        if (-not $ui.CmbGame.IsDropDownOpen) {
            $mode = (Get-GameFilter).Mode
            $idx = switch ($mode) { 'all' {1} 'tcp' {2} 'udp' {3} default {0} }
            if ($ui.CmbGame.SelectedIndex -ne $idx) { $ui.CmbGame.SelectedIndex = $idx }
        }

        $ui.TxtIpset.Text = switch (Get-IpsetStatus) {
            'loaded' { 'loaded — обход по скачанному списку IP' }
            'none'   { 'none — ipset-правила выключены' }
            default  { 'any — обход на любые IP' }
        }

        $ui.TglUpd.IsChecked = (Test-Path (Join-Path $script:Utils 'check_updates.enabled'))
    } finally {
        $script:updating = $false
    }
}

function Get-SelectedStrategy {
    if ($ui.CmbStrategy.SelectedItem) { return [string]$ui.CmbStrategy.SelectedItem }
    return $null
}

# ---------- Actions (все долгие — в фоне) ----------
function Invoke-Install([string]$reason) {
    $strat = Get-SelectedStrategy
    if (-not $strat) { Show-Info 'Нет стратегии' 'Сначала выбери стратегию в списке.'; return }
    $binPath = $null
    try { $binPath = Get-StrategyBinPath $strat } catch { Show-Info 'Ошибка' $_.Exception.Message; return }
    Ensure-UserLists
    Log "Устанавливаю службу ($strat) $reason"
    Start-Bg -BusyText "Устанавливаю службу`n$strat" -Params @{ binPath = $binPath; name = $strat } -Body @'
$r = Install-ZapretSvc $CTX.binPath $CTX.name
@{ ok = $r.ok; err = $r.err; name = $CTX.name }
'@ -OnDone {
        param($res)
        $r = @($res)[-1]
        if ($r -and $r.ok) { Hide-Warn; Log 'Служба установлена и запущена (автозапуск включён)' }
        else {
            $err = if ($r) { $r.err } else { 'неизвестная ошибка' }
            Log "ОШИБКА установки: $err"
            Show-Info 'Не удалось запустить службу' $err
        }
    }
}

function Offer-Reinstall([string]$what) {
    if (Get-Service -Name zapret -ErrorAction SilentlyContinue) {
        Show-Confirm 'Применить изменения?' "$what Служба хранит настройки внутри — чтобы изменения заработали, её нужно переустановить." 'Да, переустановить' $false `
            { Invoke-Install '(применяю изменения)' } { Show-Warn }
    } else { Show-Warn }
}

# ---------- Wiring ----------
Init-FileLog
$ui.TxtRoot.Text = $script:Root

$ui.TitleBar.Add_MouseLeftButtonDown({ try { $win.DragMove() } catch {} })
$ui.BtnMin.Add_Click({ $win.WindowState = 'Minimized' })
$ui.BtnClose.Add_Click({ $win.Close() })

$strategies = @(Get-StrategyFiles | ForEach-Object { $_.BaseName })
foreach ($s in $strategies) { [void]$ui.CmbStrategy.Items.Add($s) }
$cur = Get-CurrentStrategy
if ($cur -and $strategies -contains $cur) { $ui.CmbStrategy.SelectedItem = $cur }
elseif ($strategies.Count) { $ui.CmbStrategy.SelectedIndex = 0 }

$ExcludePath = Join-Path $script:Lists 'list-exclude-user.txt'
$GeneralPath = Join-Path $script:Lists 'list-general-user.txt'
Ensure-UserLists
$ui.TxtExclude.Text = (Get-Content -LiteralPath $ExcludePath -Raw -ErrorAction SilentlyContinue)
$ui.TxtGeneral.Text = (Get-Content -LiteralPath $GeneralPath -Raw -ErrorAction SilentlyContinue)

$ui.TglService.Add_Click({
    $svc = Get-Service -Name zapret -ErrorAction SilentlyContinue
    if (-not $svc) {
        $ui.TglService.IsChecked = $false
        Show-Info 'Служба не установлена' 'Выбери стратегию и нажми "Установить службу".'
        return
    }
    $start = [bool]$ui.TglService.IsChecked
    Start-Bg -BusyText $(if ($start) { 'Запускаю службу...' } else { 'Останавливаю службу...' }) -Params @{ start = $start } -Body @'
try {
    if ($CTX.start) { Start-Service -Name zapret -ErrorAction Stop; BgLog 'Служба запущена' }
    else {
        Stop-Service -Name zapret -Force -ErrorAction Stop
        Get-Process -Name winws -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        BgLog 'Служба остановлена'
    }
    @{ ok = $true }
} catch {
    $reason = Get-SvcFailReason
    $m = $_.Exception.Message
    if ($reason) { $m = "$m | журнал Windows: $reason" }
    BgLog "ОШИБКА: $m"
    @{ ok = $false; err = $m }
}
'@ -OnDone {
        param($res)
        $r = @($res)[-1]
        if ($r -and -not $r.ok) { Show-Info 'Не получилось' $r.err }
    }
})

$ui.BtnInstall.Add_Click({ Invoke-Install '' })

$ui.BtnRemove.Add_Click({
    Show-Confirm 'Удалить службу Zapret?' 'Служба и правила WinDivert будут удалены из системы, обход перестанет запускаться при старте ПК. Списки доменов сохранятся.' 'Да, удалить' $true {
        Log 'Удаляю службу и WinDivert...'
        Start-Bg -BusyText 'Удаляю службу...' -Body @'
Remove-ZapretSvc
BgLog 'Служба удалена'
@{ ok = $true }
'@
    } $null
})

$ui.TglFaceit.Add_Click({
    $on = [bool]$ui.TglFaceit.IsChecked
    Set-Faceit $on
    if ($on) { Log 'FACEIT режим включён (game filter = all, ipset-game = 0.0.0.0/0)' }
    else     { Log 'FACEIT режим выключен (game filter снят, ipset-game = заглушка)' }
    Update-Status
    Offer-Reinstall $(if ($on) { 'FACEIT режим включён.' } else { 'FACEIT режим выключен.' })
})

$ui.CmbGame.Add_SelectionChanged({
    if ($script:updating) { return }
    $mode = switch ($ui.CmbGame.SelectedIndex) { 1 {'all'} 2 {'tcp'} 3 {'udp'} default {'off'} }
    Set-GameFilterMode $mode
    Log "Game Filter: $mode"
    Offer-Reinstall 'Game Filter изменён.'
})

$ui.TglUpd.Add_Click({
    $flag = Join-Path $script:Utils 'check_updates.enabled'
    if ($ui.TglUpd.IsChecked) { Set-Content -LiteralPath $flag -Value 'ENABLED' -Encoding ASCII; Log 'Автопроверка обновлений включена' }
    else { if ([IO.File]::Exists($flag)) { [IO.File]::Delete($flag) }; Log 'Автопроверка обновлений выключена' }
})

# Обновление ipset — в фоне (раньше окно висло на все 15 секунд таймаута)
$ui.BtnIpsetUpdate.Add_Click({
    Log 'Скачиваю свежий ipset список...'
    Start-Bg -BusyText 'Скачиваю список IP-адресов...' -Params @{
        listFile = (Join-Path $script:Lists 'ipset-all.txt')
        url = 'https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/refs/heads/main/.service/ipset-service.txt'
    } -Body @'
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $res = Invoke-WebRequest -Uri $CTX.url -TimeoutSec 25 -UseBasicParsing
    Set-Content -LiteralPath $CTX.listFile -Value $res.Content -Encoding UTF8
    $n = (Get-Content -LiteralPath $CTX.listFile | Measure-Object -Line).Lines
    BgLog "ipset-all.txt обновлён: $n строк"
    @{ ok = $true; count = $n }
} catch {
    BgLog ("ОШИБКА загрузки: " + $_.Exception.Message)
    @{ ok = $false; err = $_.Exception.Message }
}
'@ -OnDone {
        param($res)
        $r = @($res)[-1]
        if ($r -and $r.ok) {
            if ((Get-Service -Name zapret -ErrorAction SilentlyContinue).Status -eq 'Running') {
                Show-Confirm 'Перезапустить службу?' 'Список обновлён. Чтобы winws подхватил новые адреса, службу нужно перезапустить.' 'Перезапустить' $false {
                    Start-Bg -BusyText 'Перезапускаю службу...' -Body @'
Restart-Service -Name zapret -Force
BgLog 'Служба перезапущена'
@{ ok = $true }
'@
                } $null
            }
        } elseif ($r) { Show-Info 'Не удалось скачать список' $r.err }
    }
})

function Save-ListFile([string]$path, [string]$text, [string]$title) {
    $lines = ($text -replace "`r`n", "`n").Trim("`n") -split "`n"
    $converted = 0
    $out = foreach ($l in $lines) {
        $p = ConvertTo-Punycode $l
        if ($p -ne $l) { $converted++ }
        $p
    }
    $body = ($out -join "`r`n").Trim()
    if ([string]::IsNullOrWhiteSpace($body)) { $body = 'domain.example.abc' }
    Set-Content -LiteralPath $path -Value $body -Encoding ASCII
    if ($converted -gt 0) { Log "$title сохранён (доменов переведено в punycode: $converted)" }
    else { Log "$title сохранён" }
    if ((Get-Service -Name zapret -ErrorAction SilentlyContinue).Status -eq 'Running') {
        Show-Confirm 'Перезапустить службу?' 'Список сохранён. Чтобы winws подхватил изменения, службу нужно перезапустить.' 'Перезапустить' $false {
            Start-Bg -BusyText 'Перезапускаю службу...' -Body @'
Restart-Service -Name zapret -Force
BgLog 'Служба перезапущена'
@{ ok = $true }
'@
        } $null
    }
}

$ui.BtnSaveExclude.Add_Click({
    Save-ListFile $ExcludePath $ui.TxtExclude.Text 'list-exclude-user.txt'
    $ui.TxtExclude.Text = (Get-Content -LiteralPath $ExcludePath -Raw)
})
$ui.BtnSaveGeneral.Add_Click({
    Save-ListFile $GeneralPath $ui.TxtGeneral.Text 'list-general-user.txt'
    $ui.TxtGeneral.Text = (Get-Content -LiteralPath $GeneralPath -Raw)
})

# ---------- Проверка доступа ----------
$ui.BtnRunTests.Add_Click({
    $ui.TestList.Children.Clear()
    $script:TestRows = @{}
    foreach ($t in $script:TestTargets) { Set-TestRow $t.host $t.label 'wait' 'в очереди' }
    Log 'Проверяю доступ к сайтам...'
    Start-Bg -BusyText 'Проверяю доступ к сайтам...' -Cancellable $true -Params @{ targets = $script:TestTargets } -Body @'
$ok = 0; $total = 0
foreach ($t in $CTX.targets) {
    if (BgStopped) { break }
    $total++
    BgTest $t.host $t.label 'run' ''
    BgBusy ("Проверяю: " + $t.host)
    $r = Test-TlsDomain $t.host 6000
    if ($r.ok) { $ok++; BgTest $t.host $t.label 'ok' '' }
    else       { BgTest $t.host $t.label 'fail' $r.why }
}
BgLog ("Проверка: доступно {0} из {1}" -f $ok, $total)
@{ ok = $ok; total = $total }
'@ -OnDone {
        param($res)
        $r = @($res)[-1]
        if ($r) {
            $script:LastTestSummary = "$($r.ok) из $($r.total)"
            if ($r.ok -eq $r.total) {
                Show-Info 'Всё работает' "Все $($r.total) проверок пройдены — обход работает."
            } elseif ($r.ok -eq 0) {
                Show-Info 'Ничего не открывается' "Ни один сайт не ответил. Проверь, что служба запущена, и попробуй «Подобрать» стратегию на этой же вкладке."
            } else {
                Show-Info 'Работает частично' "Доступно $($r.ok) из $($r.total). Попробуй другую стратегию или автоподбор — красные строки видно в списке."
            }
        }
    }
})

# ---------- Автоподбор стратегии ----------
$ui.BtnAutoPick.Add_Click({
    Show-Confirm 'Начать автоподбор?' 'Приложение будет по очереди ставить стратегии и проверять доступ. Это займёт до нескольких минут, интернет в это время будет прерываться. Остановить можно в любой момент.' 'Начать' $false {
        $list = @()
        $sel = Get-SelectedStrategy
        $names = @(Get-StrategyFiles | ForEach-Object { $_.BaseName })
        if ($sel) { $names = @($sel) + @($names | Where-Object { $_ -ne $sel }) }
        foreach ($n in $names) {
            try { $list += @{ name = $n; binPath = (Get-StrategyBinPath $n) } } catch {}
        }
        if (-not $list.Count) { Show-Info 'Нет стратегий' 'В папке не найдено ни одного general-файла.'; return }

        $ui.TestList.Children.Clear()
        $script:TestRows = @{}
        Log "Автоподбор: перебираю $($list.Count) стратегий"
        Start-Bg -BusyText 'Автоподбор стратегии...' -Cancellable $true -Params @{ strategies = $list; targets = $script:PickTargets } -Body @'
$results = @()
$best = $null
$i = 0
foreach ($s in $CTX.strategies) {
    if (BgStopped) { break }
    $i++
    BgBusy ("[{0}/{1}] {2}" -f $i, $CTX.strategies.Count, $s.name)
    BgTest $s.name '' 'run' ''
    $r = Install-ZapretSvc $s.binPath $s.name
    if (-not $r.ok) {
        BgTest $s.name '' 'fail' 'не запускается'
        BgLog ("  {0}: служба не стартовала — {1}" -f $s.name, $r.err)
        continue
    }
    Start-Sleep -Seconds 2
    $pass = 0
    foreach ($t in $CTX.targets) {
        if (BgStopped) { break }
        BgBusy ("[{0}/{1}] {2} — проверяю {3}" -f $i, $CTX.strategies.Count, $s.name, $t)
        if ((Test-TlsDomain $t 6000).ok) { $pass++ }
    }
    if (BgStopped) { break }
    $results += @{ name = $s.name; pass = $pass }
    BgLog ("  {0}: {1} из {2}" -f $s.name, $pass, $CTX.targets.Count)
    if ($pass -eq $CTX.targets.Count) {
        BgTest $s.name '' 'ok' ''
        $best = $s
        break
    } else {
        BgTest $s.name '' 'fail' ("$pass из " + $CTX.targets.Count)
    }
}
if (-not $best -and $results.Count) {
    $top = $results | Sort-Object { $_.pass } -Descending | Select-Object -First 1
    if ($top.pass -gt 0) { $best = $CTX.strategies | Where-Object { $_.name -eq $top.name } | Select-Object -First 1 }
}
if ($best) {
    BgBusy ("Ставлю выбранную стратегию: " + $best.name)
    $r = Install-ZapretSvc $best.binPath $best.name
    BgLog ("Автоподбор завершён, оставляю: " + $best.name)
    @{ best = $best.name; results = $results; installed = $r.ok }
} else {
    BgLog 'Автоподбор: рабочей стратегии не нашлось'
    @{ best = $null; results = $results; installed = $false }
}
'@ -OnDone {
            param($res)
            $r = @($res)[-1]
            if ($r -and $r.best) {
                $ui.CmbStrategy.SelectedItem = $r.best
                Show-Info 'Стратегия подобрана' "Лучший результат у «$($r.best)» — она установлена и запущена с автозапуском."
            } elseif ($r) {
                Show-Info 'Не нашлось рабочей стратегии' 'Ни одна стратегия не дала доступа. Проверь вкладку «Диагностика» на конфликты (VPN, другой обход, Adguard) и что интернет вообще работает.'
            }
        }
    } $null
})

# ---------- Диагностика ----------
$ui.BtnDiag.Add_Click({
    $ui.TxtDiag.Document.Blocks.Clear()
    Start-Bg -BusyText 'Проверяю систему...' -Params @{ root = $script:Root } -Body @'
$allSvc = Get-Service -ErrorAction SilentlyContinue

$bfe = Get-Service -Name BFE -ErrorAction SilentlyContinue
if ($bfe -and $bfe.Status -eq 'Running') { BgDiag 'OK' 'Base Filtering Engine работает' }
else { BgDiag 'X' 'Base Filtering Engine НЕ работает — без него zapret не работает!' }

if (Get-Process -Name winws -ErrorAction SilentlyContinue) { BgDiag 'OK' 'winws.exe запущен' }
else { BgDiag '!' 'winws.exe не запущен (обход не активен)' }

$svc = Get-Service -Name zapret -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -ne 'Running') {
    $reason = Get-SvcFailReason
    if ($reason) { BgDiag 'X' ("Служба не работает. Журнал Windows: " + $reason) }
}

$proxyOn = $false
try {
    $proxyKey = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
    if ($proxyKey.ProxyEnable -eq 1) { $proxyOn = $true; BgDiag '!' ("Включён системный прокси: " + $proxyKey.ProxyServer) }
} catch {}
if (-not $proxyOn) { BgDiag 'OK' 'Системный прокси выключен' }

$ts = & netsh interface tcp show global | Select-String -Pattern 'timestamps' -SimpleMatch
if ($ts -and $ts.ToString() -match '(?i)enabled') { BgDiag 'OK' 'TCP timestamps включены' }
else { & netsh interface tcp set global timestamps=enabled | Out-Null; BgDiag '!' 'TCP timestamps были выключены — включил' }

if (Get-Process -Name AdguardSvc -ErrorAction SilentlyContinue) { BgDiag 'X' 'Найден Adguard — может ломать Discord' }
else { BgDiag 'OK' 'Adguard не найден' }

foreach ($pat in @(@('Killer','Killer'), @('SmartByte','SmartByte'), @('TracSrvWrapper|EPWD','Check Point'))) {
    $hit = $allSvc | Where-Object { $_.Name -match $pat[0] -or $_.DisplayName -match $pat[0] }
    if ($hit) { BgDiag 'X' ($pat[1] + ' найден — конфликтует с zapret') } else { BgDiag 'OK' ($pat[1] + ' не найден') }
}

$intel = $allSvc | Where-Object { $_.DisplayName -match 'Intel' -and $_.DisplayName -match 'Connectivity' }
if ($intel) { BgDiag 'X' 'Intel Connectivity Network Service найден (конфликтует с zapret)' }
else { BgDiag 'OK' 'Intel Connectivity не найден' }

$conf = @()
foreach ($s in 'GoodbyeDPI','discordfix_zapret','winws1','winws2') {
    if (Get-Service -Name $s -ErrorAction SilentlyContinue) { $conf += $s }
}
if ($conf.Count) { BgDiag 'X' ("Конфликтующие обходы: " + ($conf -join ', ') + " — удали их службы") }
else { BgDiag 'OK' 'Других DPI-обходов не найдено' }

$wd = Get-Service -Name WinDivert -ErrorAction SilentlyContinue
if ($wd -and $wd.Status -eq 'Running' -and -not (Get-Process -Name winws -ErrorAction SilentlyContinue)) {
    BgDiag '!' 'WinDivert работает без winws.exe — нажми "Удалить WinDivert"'
}

$vpn = $allSvc | Where-Object { $_.DisplayName -match 'VPN' -or $_.Name -match 'VPN' }
if ($vpn) { BgDiag '!' ("Найдены VPN-службы: " + (@($vpn | Select-Object -First 4 | ForEach-Object Name) -join ', ') + " — некоторые VPN конфликтуют с zapret") }
else { BgDiag 'OK' 'VPN-службы не найдены' }

$hostsFile = "$env:SystemRoot\System32\drivers\etc\hosts"
if (Test-Path $hostsFile) {
    $h = Get-Content $hostsFile -Raw -ErrorAction SilentlyContinue
    if ($h -match '(?im)^[^#]*(youtube\.com|youtu\.be)') { BgDiag '!' 'В hosts есть записи youtube — может ломать доступ к YouTube' }
    else { BgDiag 'OK' 'Файл hosts чистый (нет записей youtube)' }
}

if (-not (Test-Path (Join-Path $CTX.root 'bin\WinDivert64.sys'))) { BgDiag 'X' 'Файл bin\WinDivert64.sys не найден — распакуй архив заново' }
else { BgDiag 'OK' 'Файлы движка на месте' }

BgDiag '--' 'Диагностика завершена'
@{ ok = $true }
'@
})

$ui.BtnReport.Add_Click({
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("=== Zapret Control $script:AppVersion — отчёт ===")
    [void]$sb.AppendLine("Дата: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    [void]$sb.AppendLine("Windows: $([Environment]::OSVersion.VersionString)  PowerShell: $($PSVersionTable.PSVersion)")
    [void]$sb.AppendLine("Папка zapret: $script:Root")
    $svc = Get-Service -Name zapret -ErrorAction SilentlyContinue
    [void]$sb.AppendLine("Служба: $(if ($svc) { $svc.Status } else { 'не установлена' })")
    [void]$sb.AppendLine("Стратегия: $(Get-CurrentStrategy)")
    [void]$sb.AppendLine("FACEIT: $(if (Test-Faceit) { 'вкл' } else { 'выкл' })   GameFilter: $((Get-GameFilter).Mode)   IPSet: $(Get-IpsetStatus)")
    [void]$sb.AppendLine("winws.exe: $(if (Get-Process -Name winws -ErrorAction SilentlyContinue) { 'запущен' } else { 'не запущен' })")
    [void]$sb.AppendLine("Проверка доступа: $script:LastTestSummary")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('--- Диагностика ---')
    $range = New-Object System.Windows.Documents.TextRange($ui.TxtDiag.Document.ContentStart, $ui.TxtDiag.Document.ContentEnd)
    $dt = $range.Text.Trim()
    [void]$sb.AppendLine($(if ($dt) { $dt } else { '(не запускалась)' }))
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('--- Журнал ---')
    [void]$sb.AppendLine($ui.TxtLog.Text.Trim())
    try {
        Set-Clipboard -Value $sb.ToString()
        Log 'Отчёт скопирован в буфер обмена'
        Show-Info 'Отчёт скопирован' 'Вставь его в переписку (Ctrl+V) — там вся информация о состоянии и найденных проблемах.'
    } catch {
        Log "Не удалось скопировать: $($_.Exception.Message)"
    }
})

$ui.BtnKillWinws.Add_Click({
    Get-Process -Name winws -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Log 'winws.exe остановлен (служба может перезапустить его — останови службу, если нужно)'
    Update-Status
})

$ui.BtnFixDivert.Add_Click({
    Start-Bg -BusyText 'Удаляю WinDivert...' -Body @'
foreach ($wd in 'WinDivert','WinDivert14') {
    if (Get-Service -Name $wd -ErrorAction SilentlyContinue) {
        & sc.exe stop $wd   2>&1 | Out-Null
        & sc.exe delete $wd 2>&1 | Out-Null
    }
}
BgLog 'WinDivert остановлен и удалён'
@{ ok = $true }
'@
})

$ui.BtnDiscordCache.Add_Click({
    Show-Confirm 'Очистить кэш Discord?' 'Discord будет закрыт, папки Cache / Code Cache / GPUCache будут удалены. Настройки и аккаунт не пострадают.' 'Да, очистить' $false {
        Start-Bg -BusyText 'Чищу кэш Discord...' -Params @{ appdata = $env:APPDATA } -Body @'
Get-Process -Name Discord -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 600
$base = Join-Path $CTX.appdata 'discord'
foreach ($d in 'Cache','Code Cache','GPUCache') {
    $dir = Join-Path $base $d
    if (Test-Path $dir) {
        try { [IO.Directory]::Delete($dir, $true); BgLog "Удалён: $dir" } catch { BgLog "Не удалось удалить: $dir" }
    }
}
BgLog 'Кэш Discord очищен'
@{ ok = $true }
'@
    } $null
})

$ui.BtnOpenLog.Add_Click({
    if (Test-Path $script:LogFile) { Start-Process explorer.exe "/select,`"$script:LogFile`"" }
    else { Start-Process explorer.exe $script:LogDir }
})

$ui.BtnOpenFolder.Add_Click({ try { Start-Process explorer.exe $script:Root } catch {} })
$ui.LnkTg.Add_Click({ try { Start-Process 'https://t.me/masiuniv' } catch {} })

$ui.BtnRestartSvc.Add_Click({
    if (-not (Get-Service -Name zapret -ErrorAction SilentlyContinue)) {
        Show-Info 'Служба не установлена' 'Сначала установи службу на вкладке «Управление».'
        return
    }
    Start-Bg -BusyText 'Перезапускаю службу...' -Body @'
Restart-Service -Name zapret -Force
BgLog 'Служба перезапущена'
@{ ok = $true }
'@
})

# ---------- Обновление самого zapret ----------
$ui.BtnCheckUpd.Add_Click({
    $ui.TxtVerLocal.Text = "Установлено: $(Get-LocalVersion)"
    $ui.TxtVerLatest.Text = 'Проверяю...'
    $ui.TxtVerLatest.Foreground = $BrGrayTx
    Start-Bg -BusyText 'Проверяю новую версию zapret...' -Params @{ url = $script:VersionUrl } -Body @'
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $v = (Invoke-WebRequest -Uri $CTX.url -TimeoutSec 20 -UseBasicParsing).Content.Trim()
    @{ ok = $true; latest = $v }
} catch {
    @{ ok = $false; err = $_.Exception.Message }
}
'@ -OnDone {
        param($res)
        $r = @($res)[-1]
        $local = Get-LocalVersion
        if ($r -and $r.ok) {
            if ($r.latest -and $r.latest -ne $local) {
                $ui.TxtVerLatest.Text = "Доступна новая версия: $($r.latest)"
                $ui.TxtVerLatest.Foreground = $BrAmber
                $ui.BtnDoUpd.Visibility = 'Visible'
                Log "Доступно обновление zapret: $local -> $($r.latest)"
            } else {
                $ui.TxtVerLatest.Text = "Установлена последняя версия ($local)"
                $ui.TxtVerLatest.Foreground = $BrGreenTx
                $ui.BtnDoUpd.Visibility = 'Collapsed'
            }
        } else {
            $ui.TxtVerLatest.Text = 'Не удалось проверить (нет связи с GitHub?)'
            $ui.TxtVerLatest.Foreground = $BrRedTx
        }
    }
})

$ui.BtnDoUpd.Add_Click({
    Show-Confirm 'Обновить zapret?' 'Будет скачана новая версия, применены наши доработки (игровой ipset, исключения Twitch/OBS), перенесены твои списки и настройки, служба переустановлена. Старая версия сохранится в папку _backup рядом. Интернет на минуту прервётся.' 'Обновить' $false {
        Log 'Обновление zapret: начинаю'
        Start-Bg -BusyText 'Обновляю zapret...' -Cancellable $false -Params @{
            root = $script:Root
            strategy = (Get-CurrentStrategy)
        } -Body @'
$tmp = Join-Path $env:TEMP ('zapret_upd_' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
    BgBusy 'Узнаю адрес свежей версии...'
    $rel = Get-LatestZipBg
    BgLog ("Источник: " + $rel.Src + ", версия " + $rel.Version)

    BgBusy ("Скачиваю " + $rel.Version + "...")
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $zip = Join-Path $tmp 'z.zip'
    Invoke-WebRequest -Uri $rel.Url -OutFile $zip -TimeoutSec 300 -UseBasicParsing

    BgBusy 'Распаковываю...'
    $ex = Join-Path $tmp 'ex'
    Expand-Archive -LiteralPath $zip -DestinationPath $ex -Force
    $newRoot = Get-ChildItem -LiteralPath $ex -Directory -ErrorAction SilentlyContinue |
               Where-Object { Test-Path (Join-Path $_.FullName 'bin\winws.exe') } |
               Select-Object -First 1 -ExpandProperty FullName
    if (-not $newRoot) {
        if (Test-Path (Join-Path $ex 'bin\winws.exe')) { $newRoot = $ex } else { throw 'В архиве не найден bin\winws.exe' }
    }

    BgBusy 'Применяю наши доработки...'
    $n = Apply-CustomizationsBg $newRoot
    BgLog ("Доработки применены к стратегиям: " + $n)

    # переносим пользовательские файлы в новую версию
    $preserve = @(
        'lists\list-exclude-user.txt', 'lists\list-general-user.txt', 'lists\ipset-game.txt',
        'lists\ipset-exclude-user.txt', 'utils\faceit.enabled', 'utils\game_filter.enabled', 'utils\check_updates.enabled'
    )
    foreach ($relPath in $preserve) {
        $s = Join-Path $CTX.root $relPath
        if (Test-Path -LiteralPath $s) {
            $d = Join-Path $newRoot $relPath
            $dd = Split-Path $d -Parent
            if (-not (Test-Path $dd)) { New-Item -ItemType Directory -Force -Path $dd | Out-Null }
            Copy-Item -LiteralPath $s -Destination $d -Force
        }
    }
    $ig = Join-Path $newRoot 'lists\ipset-game.txt'
    if (-not (Test-Path $ig)) { Set-Content -LiteralPath $ig -Value '203.0.113.113/32' -Encoding ASCII }
    $exclFile = Join-Path $newRoot 'lists\list-exclude-user.txt'
    $exclCur = if (Test-Path $exclFile) { Get-Content -LiteralPath $exclFile } else { @() }
    $need = @('twitch.tv','ttvnw.net','jtvnw.net','live-video.net') | Where-Object { $exclCur -notcontains $_ }
    if ($need) { Add-Content -LiteralPath $exclFile -Value $need -Encoding ASCII }

    BgBusy 'Останавливаю службу...'
    Remove-ZapretSvc
    Start-Sleep -Milliseconds 900

    BgBusy 'Делаю резервную копию текущей версии...'
    $bak = ($CTX.root.TrimEnd('\')) + '_backup_' + (Get-Date -Format 'yyyyMMdd_HHmmss')
    robocopy $CTX.root $bak /E /NFL /NDL /NJH /NJS /NP /R:1 /W:1 2>$null | Out-Null

    BgBusy 'Копирую новую версию...'
    robocopy $newRoot $CTX.root /E /NFL /NDL /NJH /NJS /NP /R:2 /W:1 2>$null | Out-Null
    if ($LASTEXITCODE -ge 8) { throw ("Ошибка копирования файлов (robocopy " + $LASTEXITCODE + ")") }
    BgLog ("Резервная копия: " + $bak)

    if ($CTX.strategy) {
        BgBusy ('Переустанавливаю службу: ' + $CTX.strategy)
        $bat = Join-Path $CTX.root ($CTX.strategy + '.bat')
        if (Test-Path -LiteralPath $bat) {
            # строку запуска пересобираем уже из ОБНОВЛЁННОГО .bat
            $lines = Get-Content -LiteralPath $bat
            $cmd = $null; $cap = $false
            foreach ($line in $lines) {
                if (-not $cap -and $line -match 'winws\.exe') { $cap = $true }
                if ($cap) {
                    $t = $line.Trim()
                    $cont = $t.EndsWith('^')
                    if ($cont) { $t = $t.Substring(0, $t.Length - 1).Trim() }
                    if ($cmd) { $cmd = "$cmd $t" } else { $cmd = $t }
                    if (-not $cont) { break }
                }
            }
            $marker = 'winws.exe"'
            $argStr = $cmd.Substring($cmd.IndexOf($marker) + $marker.Length).Trim()
            $gfFile = Join-Path $CTX.root 'utils\game_filter.enabled'
            $gTcp = '12'; $gUdp = '12'
            if (Test-Path $gfFile) {
                $mode = (Get-Content -LiteralPath $gfFile -TotalCount 1)
                if ($mode) { $mode = $mode.Trim().ToLower() }
                if ($mode -eq 'all') { $gTcp = '1024-65535'; $gUdp = '1024-65535' }
                elseif ($mode -eq 'tcp') { $gTcp = '1024-65535' }
                else { $gUdp = '1024-65535' }
            }
            $argStr = $argStr.Replace('%GameFilterTCP%', $gTcp).Replace('%GameFilterUDP%', $gUdp).Replace('%GameFilter%', $gTcp)
            $argStr = $argStr.Replace('%BIN%', (Join-Path $CTX.root 'bin\')).Replace('%LISTS%', (Join-Path $CTX.root 'lists\'))
            $binPath = ('"{0}" {1}' -f (Join-Path $CTX.root 'bin\winws.exe'), $argStr)
            $r = Install-ZapretSvc $binPath $CTX.strategy
            if (-not $r.ok) { BgLog ('Служба не стартовала: ' + $r.err) }
        }
    }
    BgLog ("Обновление завершено, версия " + $rel.Version)
    @{ ok = $true; version = $rel.Version; backup = $bak }
} catch {
    BgLog ('ОШИБКА обновления: ' + $_.Exception.Message)
    @{ ok = $false; err = $_.Exception.Message }
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
'@ -OnDone {
            param($res)
            $r = @($res)[-1]
            if ($r -and $r.ok) {
                $ui.TxtVerLocal.Text = "Установлено: $(Get-LocalVersion)"
                $ui.TxtVerLatest.Text = "Обновлено до $($r.version)"
                $ui.TxtVerLatest.Foreground = $BrGreenTx
                $ui.BtnDoUpd.Visibility = 'Collapsed'
                Show-Info 'Обновление завершено' "zapret обновлён до $($r.version). Твои списки и настройки перенесены, служба переустановлена.`n`nСтарая версия сохранена рядом в папке с суффиксом _backup."
            } elseif ($r) {
                Show-Info 'Не удалось обновить' "$($r.err)`n`nСкачать вручную: $script:MirrorPage"
            }
        }
    } $null
})

# ---------- Таймеры ----------
$statusTimer = New-Object System.Windows.Threading.DispatcherTimer
$statusTimer.Interval = [TimeSpan]::FromSeconds(3)
$statusTimer.Add_Tick({ Update-Status })

$pollTimer = New-Object System.Windows.Threading.DispatcherTimer
$pollTimer.Interval = [TimeSpan]::FromMilliseconds(200)
$pollTimer.Add_Tick({
    while ($script:BgQueue.Count -gt 0) {
        $m = $script:BgQueue.Dequeue()
        switch ($m.t) {
            'log'  { Log $m.msg }
            'busy' { $ui.BusyText.Text = $m.msg }
            'diag' { Add-Diag $m.tag $m.text }
            'test' { Set-TestRow $m.key $m.label $m.state $m.note }
        }
    }
    if ($script:BgHandle -and $script:BgHandle.IsCompleted) {
        $result = $null
        try { $result = $script:BgPs.EndInvoke($script:BgHandle) }
        catch { Log "ОШИБКА в фоновой задаче: $($_.Exception.Message)" }
        $ps = $script:BgPs; $done = $script:BgOnDone
        $script:BgPs = $null; $script:BgHandle = $null; $script:BgOnDone = $null
        try { $ps.Runspace.Close(); $ps.Dispose() } catch {}
        Hide-Busy
        Update-Status
        if ($done) {
            try { & $done $result } catch { Log "ОШИБКА обработки результата: $($_.Exception.Message)" }
        }
    }
})

# Не даём закрыть окно посреди установки службы — иначе она останется недоделанной
$win.Add_Closing({
    param($sender, $e)
    if ($script:BgPs) {
        $e.Cancel = $true
        Show-Info 'Идёт операция' 'Дождись окончания текущей операции — прерывать установку службы на середине нельзя. Долгие операции можно остановить кнопкой «Отменить».'
        return
    }
    if ($script:BgCancel) { $script:BgCancel.stop = $true }
})

# ---------- Start ----------
Update-Status
$ui.TxtVerLocal.Text = "Установлено: $(Get-LocalVersion)"
Log "Zapret Control $script:AppVersion — управляю папкой: $script:Root"
$statusTimer.Start()
$pollTimer.Start()

[void]$win.ShowDialog()

$statusTimer.Stop()
$pollTimer.Stop()
if ($script:AppMutex) { try { $script:AppMutex.ReleaseMutex() } catch {} }
