# ============================================================
#  Zapret Control - GUI manager for zapret-discord-youtube
#  Дизайн: claude.ai/design "Zapret Control дизайн-система"
#  1.1: фоновые операции (окно не зависает), автоподбор стратегии,
#       проверка доступа, punycode, лог в файл, один экземпляр
#  1.2: автоподбор проверяет все стратегии, выбор за пользователем
#  1.3: кнопка «Вернуть всё как было»
#  1.4: самообновление приложения, тихая проверка версий при запуске,
#       подсказки, DNS в диагностике, Esc/Enter в диалогах, память окна
#  1.5: режим Lineage 2 — обход на портах Линейки для любых серверов
#  1.6: вкладка «Соединения» — журнал, к каким адресам не удаётся подключиться
#  1.7: Lineage 2 — режим «Не трогать» (порты Линейки мимо zapret) и поиск портов сервера
#  1.8: «Не трогать порты» — RustDesk/AnyDesk/TeamViewer и свои порты мимо FACEIT MODE
# ============================================================
param(
    [switch]$TestParse,
    [switch]$TestUI,
    [string]$RootOverride
)

$ErrorActionPreference = 'Stop'
$script:AppVersion = '1.8.0'
$script:SelfPath   = $PSCommandPath
$script:AppRepoApi = 'https://api.github.com/repos/MassimoUniverse/zapret-control/releases/latest'
$script:AppRepoUrl = 'https://github.com/MassimoUniverse/zapret-control'
$script:RestartPath = $null

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
        # параметры пробрасываем в повышенный экземпляр, иначе -RootOverride терялся
        $extra = if ($RootOverride) { " -RootOverride `"$RootOverride`"" } else { '' }
        Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`"$extra"
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

# ---------- Настройки приложения (положение окна) ----------
# лежат в профиле пользователя, а не в папке zapret — переживают обновление и переезд папки
$script:SettingsFile = Join-Path $env:LOCALAPPDATA 'ZapretControl\settings.json'
function Get-AppSettings {
    try {
        if (Test-Path -LiteralPath $script:SettingsFile) {
            return (Get-Content -LiteralPath $script:SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json)
        }
    } catch {}
    return $null
}
function Save-AppSettings([hashtable]$s) {
    try {
        $dir = Split-Path $script:SettingsFile -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        [IO.File]::WriteAllText($script:SettingsFile, ($s | ConvertTo-Json -Compress), [Text.Encoding]::UTF8)
    } catch {}
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

# ---------- Lineage 2 ----------
# Сервер Линейки — это голый TCP на своих портах (2106 вход, 7777 игра), без домена в трафике.
# Списки сайтов его не ловят, а FACEIT MODE берёт все порты 1024+ — слишком широко ради одной игры.
# Поэтому отдельное правило: только порты Линейки, любые IP, параметры обмана — те же, что у игрового
# правила выбранной стратегии (они под неё подобраны). Сайты и прочие игры правило не задевает.
$script:L2DefaultPorts = '2106,7777'

# Два режима, файл utils\lineage.enabled хранит какой:
#   exclude — «Не трогать»: порты Линейки вычитаются из игрового диапазона, WinDivert их даже не перехватывает.
#             Нужен, когда сервер НЕ заблокирован, а zapret (FACEIT MODE) своими ложными пакетами ломает
#             соединение: по документации zapret, если сервер принимает фейк, «получается слом tcp соединения».
#   bypass  — «Обход»: отдельное правило обмана DPI на портах Линейки (когда провайдер блокирует сервер).
# Старое содержимое «enabled» (версия 1.5) = bypass.
function Get-LineageMode {
    $f = Join-Path $script:Utils 'lineage.enabled'
    if (-not (Test-Path -LiteralPath $f)) { return 'off' }
    $v = ''
    try { $v = [string](Get-Content -LiteralPath $f -TotalCount 1 -ErrorAction Stop) } catch {}
    if ($v.Trim() -eq 'exclude') { return 'exclude' }
    return 'bypass'
}
function Test-Lineage { (Get-LineageMode) -ne 'off' }
function Get-LineageModeText {
    switch (Get-LineageMode) { 'exclude' { "не трогать ($(Get-LineagePorts))" } 'bypass' { "обход ($(Get-LineagePorts))" } default { 'выкл' } }
}

# Вычитает порты из списка диапазонов: ('1024-65535', '2106,7777') -> '1024-2105,2107-7776,7778-65535'.
# Если вычитать нечего или игровой фильтр выключен (заглушка '12'), список не меняется.
function Remove-PortsFromRange([string]$base, [string]$ports) {
    if (-not $base -or -not $ports) { return $base }
    $cut = @(foreach ($p in $ports -split ',') { if ($p -match '^(\d+)(?:-(\d+))?$') { ,@([int]$Matches[1], [int]$(if ($Matches[2]) { $Matches[2] } else { $Matches[1] })) } })
    $res = New-Object System.Collections.ArrayList
    foreach ($seg in $base -split ',') {
        if ($seg -notmatch '^(\d+)(?:-(\d+))?$') { return $base }
        $parts = New-Object System.Collections.ArrayList
        [void]$parts.Add(@([int]$Matches[1], [int]$(if ($Matches[2]) { $Matches[2] } else { $Matches[1] })))
        foreach ($c in $cut) {
            $next = New-Object System.Collections.ArrayList
            foreach ($p in $parts) {
                if ($c[1] -lt $p[0] -or $c[0] -gt $p[1]) { [void]$next.Add($p); continue }
                if ($c[0] -gt $p[0]) { [void]$next.Add(@($p[0], ($c[0] - 1))) }
                if ($c[1] -lt $p[1]) { [void]$next.Add(@(($c[1] + 1), $p[1])) }
            }
            $parts = $next
        }
        foreach ($p in $parts) { [void]$res.Add($(if ($p[0] -eq $p[1]) { "$($p[0])" } else { "$($p[0])-$($p[1])" })) }
    }
    if (-not $res.Count) { return '12' }   # всё вычли — та же заглушка, что у выключенного фильтра
    return ($res -join ',')
}

function Get-LineagePorts {
    $f = Join-Path $script:Utils 'lineage.ports'
    try {
        if (Test-Path -LiteralPath $f) {
            $p = (Get-Content -LiteralPath $f -TotalCount 1 -ErrorAction Stop)
            if ($p -and (Test-LineagePorts $p.Trim()).ok) { return $p.Trim() }
        }
    } catch {}
    return $script:L2DefaultPorts
}

# Порты через запятую, диапазоны через дефис. 80/443 нельзя: на «любых IP» это весь веб — сломаются сайты
function Test-LineagePorts([string]$text) {
    $t = ($text -replace '\s', '').Trim(',')
    if (-not $t) { return @{ ok = $false; err = 'Укажи хотя бы один порт, например 2106,7777' } }
    if ($t -notmatch '^\d+(-\d+)?(,\d+(-\d+)?)*$') { return @{ ok = $false; err = 'Порты пишутся через запятую, диапазон через дефис: 2106,7777 или 7777-7779' } }
    $norm = @()
    foreach ($part in $t -split ',') {
        $ab = @($part -split '-' | ForEach-Object { [int]$_ })
        $a = $ab[0]; $b = $ab[-1]
        if ($a -lt 1 -or $b -gt 65535 -or $a -gt $b) { return @{ ok = $false; err = "Неверный порт или диапазон: $part" } }
        if ((80 -ge $a -and 80 -le $b) -or (443 -ge $a -and 443 -le $b)) {
            return @{ ok = $false; err = 'Порты 80 и 443 добавлять нельзя — это весь веб, на любых IP сломаются сайты' }
        }
        if (($b - $a) -gt 1000) { return @{ ok = $false; err = "Слишком широкий диапазон: $part. Для всех игровых портов есть FACEIT MODE" } }
        $norm += $part
    }
    if ($norm.Count -gt 20) { return @{ ok = $false; err = 'Не больше 20 портов или диапазонов' } }
    return @{ ok = $true; ports = ($norm -join ',') }
}

# Добавляет к сырой строке аргументов (ещё с %GameFilterTCP%, %BIN%, %LISTS%) правило для портов Линейки
function Add-LineageRule([string]$argStr, [string]$ports) {
    if (-not $ports) { return $argStr }
    # порты должен видеть сам перехват WinDivert, иначе правило не получит ни одного пакета
    if ($argStr -match '--wf-tcp=(\S+)') {
        $argStr = [regex]::Replace($argStr, '--wf-tcp=(\S+)', { param($m) '--wf-tcp=' + $m.Groups[1].Value + ',' + $ports }, 1)
    } else {
        $argStr = "--wf-tcp=$ports " + $argStr
    }
    # параметры берём у игрового TCP-правила стратегии
    $params = $null
    foreach ($seg in ($argStr -split '\s--new(\s|$)')) {
        if ($seg -match '--filter-tcp=%GameFilterTCP%') { $params = $seg; break }
    }
    if ($params) {
        $params = $params -replace '--filter-tcp=%GameFilterTCP%\s*', ''
        $params = $params -replace '--ipset="[^"]*"\s*', ''          # любые IP (ipset-exclude остаётся)
        $params = $params.Trim()
    } else {
        # у стратегии нет игрового правила — проверенный набор из FAKE TLS AUTO ALT3
        $params = '--ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" ' +
                  '--dpi-desync=fake,multisplit --dpi-desync-any-protocol=1 --dpi-desync-cutoff=n4 --dpi-desync-split-seqovl=681 ' +
                  '--dpi-desync-split-pos=1 --dpi-desync-fooling=ts --dpi-desync-repeats=8 ' +
                  '--dpi-desync-split-seqovl-pattern="%BIN%tls_clienthello_www_google_com.bin" ' +
                  '--dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com --dpi-desync-fake-unknown="%BIN%tls_clienthello_max_ru.bin"'
    }
    return ($argStr.TrimEnd() + " --new --filter-tcp=$ports " + $params)
}

# ---------- Не трогать порты ----------
# FACEIT MODE подмешивает ложные пакеты во ВСЁ на портах 1024+ (TCP и UDP, любые IP). Программам со своим
# протоколом это ломает связь: RustDesk пишет «Не подключено» — его UDP-регистрация на 21116 не доходит
# (проверено: с исключённым IP сервер отвечает, без — молчит). Порты из utils\exclude.ports вычитаются
# из игрового диапазона TCP и UDP, WinDivert их не перехватывает. Сайты и обычный обход это не задевает.
$script:ExcludePresets = [ordered]@{
    'RustDesk'   = '21115-21119'
    'AnyDesk'    = '6568'
    'TeamViewer' = '5938'
}
function Test-ExcludePorts([string]$text) {
    $t = ($text -replace '\s', '').Trim(',')
    if (-not $t) { return @{ ok = $true; ports = '' } }
    if ($t -notmatch '^\d+(-\d+)?(,\d+(-\d+)?)*$') { return @{ ok = $false; err = 'Порты пишутся через запятую, диапазон через дефис: 21115-21119,5938' } }
    $norm = New-Object System.Collections.ArrayList
    foreach ($part in $t -split ',') {
        $ab = @($part -split '-' | ForEach-Object { [int]$_ })
        if ($ab[0] -lt 1 -or $ab[-1] -gt 65535 -or $ab[0] -gt $ab[-1]) { return @{ ok = $false; err = "Неверный порт или диапазон: $part" } }
        if (-not $norm.Contains($part)) { [void]$norm.Add($part) }
    }
    if ($norm.Count -gt 30) { return @{ ok = $false; err = 'Не больше 30 портов или диапазонов' } }
    return @{ ok = $true; ports = ($norm -join ',') }
}
function Get-ExcludePorts {
    $f = Join-Path $script:Utils 'exclude.ports'
    try {
        if (Test-Path -LiteralPath $f) {
            $p = [string](Get-Content -LiteralPath $f -TotalCount 1 -ErrorAction Stop)
            $chk = Test-ExcludePorts $p
            if ($chk.ok) { return $chk.ports }
        }
    } catch {}
    return ''
}
function Get-ExcludeText {
    $p = Get-ExcludePorts
    if (-not $p) { return 'нет' }
    $apps = @(foreach ($k in $script:ExcludePresets.Keys) { if ((",$p,") -like "*,$($script:ExcludePresets[$k]),*") { $k } })
    if ($apps.Count) { return "$p ($($apps -join ', '))" }
    return $p
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
    $l2mode = Get-LineageMode
    if ($l2mode -eq 'bypass') { $argStr = Add-LineageRule $argStr (Get-LineagePorts) }
    $gf = Get-GameFilter
    $gTcp = $gf.TCP
    if ($l2mode -eq 'exclude') { $gTcp = Remove-PortsFromRange $gTcp (Get-LineagePorts) }
    $gUdp = $gf.UDP; $gBoth = $gf.Both
    $exP = Get-ExcludePorts
    if ($exP) {
        $gTcp  = Remove-PortsFromRange $gTcp  $exP
        $gUdp  = Remove-PortsFromRange $gUdp  $exP
        $gBoth = Remove-PortsFromRange $gBoth $exP
    }
    $argStr = $argStr.Replace('%GameFilterTCP%', $gTcp)
    $argStr = $argStr.Replace('%GameFilterUDP%', $gUdp)
    $argStr = $argStr.Replace('%GameFilter%',    $gBoth)
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
    Write-Host ("Lineage 2: {0}" -f (Get-LineageMode) + $(if (Test-Lineage) { ', ports ' + (Get-LineagePorts) } else { '' }))
    Write-Host ("Exclude ports: {0}" -f (Get-ExcludeText))
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

# Проверяет сразу несколько доменов параллельно, с общим дедлайном.
# Возвращает, сколько из них прошли TLS-рукопожатие.
function Test-TlsMany([string[]]$domains, [int]$timeoutMs = 7000) {
    $deadline = [DateTime]::UtcNow.AddMilliseconds($timeoutMs)
    $items = @()
    foreach ($d in $domains) {
        $it = @{ domain = $d; tcp = (New-Object System.Net.Sockets.TcpClient); conn = $null; ssl = $null; auth = $null }
        try { $it.conn = $it.tcp.ConnectAsync($d, 443) } catch {}
        $items += $it
    }
    foreach ($it in $items) {
        if (-not $it.conn) { continue }
        $rem = [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds
        if ($rem -gt 0) { try { [void]$it.conn.Wait($rem) } catch {} }
    }
    foreach ($it in $items) {
        if (-not $it.conn -or $it.conn.Status -ne 'RanToCompletion') { continue }
        try {
            $it.ssl = New-Object System.Net.Security.SslStream($it.tcp.GetStream(), $false)
            $it.auth = $it.ssl.AuthenticateAsClientAsync($it.domain, $null, [System.Security.Authentication.SslProtocols]::Tls12, $false)
        } catch {}
    }
    $ok = 0
    foreach ($it in $items) {
        if ($it.auth) {
            $rem = [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds
            if ($rem -gt 0) { try { [void]$it.auth.Wait($rem) } catch {} }
            if ($it.auth.Status -eq 'RanToCompletion') { $ok++ }
        }
        if ($it.ssl) { try { $it.ssl.Dispose() } catch {} }
        try { $it.tcp.Close() } catch {}
    }
    return $ok
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

# Строка netsh локализована («RFC 1323 Timestamps» / «Метки времени RFC 1323») — ищем по номеру RFC
function Get-TcpTimestamps {
    foreach ($l in @(& netsh interface tcp show global 2>$null)) {
        if ("$l" -match '1323|timestamps' -and "$l" -match ':\s*(\w+)\s*$') { return $Matches[1].ToLower() }
    }
    return ''
}

# Стандарт Windows — allowed. В справке netsh значение называется default, но allowed тоже описан — пробуем оба
function Reset-TcpTimestamps {
    foreach ($v in 'default', 'allowed') {
        & netsh interface tcp set global timestamps=$v 2>&1 | Out-Null
        $cur = Get-TcpTimestamps
        if ($cur -and $cur -ne 'enabled') { return $cur }
    }
    return (Get-TcpTimestamps)
}

function Get-ZapretLeftovers {
    $left = @()
    if (Get-Service -Name zapret -ErrorAction SilentlyContinue) { $left += 'служба zapret' }
    foreach ($wd in 'WinDivert','WinDivert14') { if (Get-Service -Name $wd -ErrorAction SilentlyContinue) { $left += "драйвер $wd" } }
    if (Get-Process -Name winws -ErrorAction SilentlyContinue) { $left += 'процесс winws.exe' }
    return ,$left
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

# Фоновые задачи (обновление zapret) собирают строку запуска сами — им нужна та же функция для Линейки
$script:BgPrelude += "`nfunction Add-LineageRule {`n" + ${function:Add-LineageRule}.ToString() + "`n}`n"
$script:BgPrelude += "`nfunction Remove-PortsFromRange {`n" + ${function:Remove-PortsFromRange}.ToString() + "`n}`n"

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

# Тихая фоновая задача: без оверлея и без блокировки кнопок — для проверки версий.
# Отдельный слот, чтобы не мешать Start-Bg и не ловить «Дождись окончания операции».
$script:QPs = $null; $script:QHandle = $null; $script:QOnDone = $null
function Start-Quiet {
    param([string]$Body, [hashtable]$Params = @{}, [scriptblock]$OnDone = $null)
    if ($script:QPs) { return $false }
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('CTX', $Params)
    $rs.SessionStateProxy.SetVariable('BGQ', $script:BgQueue)
    $rs.SessionStateProxy.SetVariable('CANCEL', [hashtable]::Synchronized(@{ stop = $false }))
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($script:BgPrelude + "`n" + $Body)
    $script:QPs = $ps
    $script:QHandle = $ps.BeginInvoke()
    $script:QOnDone = $OnDone
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

    <!-- Подсказки в цвет темы: стандартная белая выглядела чужой -->
    <Style TargetType="ToolTip">
      <Setter Property="Background" Value="#131B15"/>
      <Setter Property="Foreground" Value="{StaticResource TextBody}"/>
      <Setter Property="BorderBrush" Value="{StaticResource LineHover}"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Padding" Value="12,8"/>
      <Setter Property="HasDropShadow" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToolTip">
            <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="1" CornerRadius="8" Padding="{TemplateBinding Padding}" MaxWidth="340">
              <TextBlock Text="{Binding Content, RelativeSource={RelativeSource TemplatedParent}}" TextWrapping="Wrap" Foreground="{TemplateBinding Foreground}"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="Button">
      <Setter Property="ToolTipService.ShowDuration" Value="20000"/>
      <Setter Property="ToolTipService.InitialShowDelay" Value="600"/>
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
                <Hyperlink x:Name="LnkTg" Foreground="#5FD6A0" TextDecorations="None" ToolTip="Канал автора в Telegram">by Massimo</Hyperlink>
              </TextBlock>
              <TextBlock x:Name="TxtVer" Text="v—" FontFamily="Consolas" FontSize="11" Margin="12,1,0,0" VerticalAlignment="Center" Foreground="{StaticResource TextLow}"/>
              <TextBlock FontSize="11" FontFamily="Consolas" Margin="10,1,0,0" VerticalAlignment="Center" Foreground="{StaticResource TextLow}">
                <Hyperlink x:Name="LnkGh" Foreground="#5A6E60" TextDecorations="None" ToolTip="Исходный код приложения на GitHub">github</Hyperlink>
              </TextBlock>
            </StackPanel>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,14,0">
              <TextBlock x:Name="TxtRoot" FontFamily="Consolas" FontSize="11" Foreground="{StaticResource TextLow}" VerticalAlignment="Center" Margin="0,0,18,0"
                         MaxWidth="380" TextTrimming="CharacterEllipsis" ToolTip="Папка zapret, которой управляет приложение"/>
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
                      <ToggleButton x:Name="TglService" Style="{StaticResource SwitchLg}" HorizontalAlignment="Right" VerticalAlignment="Center"
                                    ToolTip="Запустить или остановить обход прямо сейчас. Автозапуск при включении ПК при этом не меняется."/>
                    </Grid>
                    <TextBlock x:Name="TxtStrategy" Style="{StaticResource Muted}" FontSize="13" Margin="0,10,0,0"/>
                    <Rectangle Style="{StaticResource Hair}" Margin="0,18,0,18"/>
                    <Grid>
                      <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="Auto"/>
                      </Grid.ColumnDefinitions>
                      <ComboBox x:Name="CmbStrategy" Grid.Column="0" HorizontalAlignment="Stretch"
                                ToolTip="Стратегия — набор приёмов, которыми zapret обманывает DPI провайдера. У разных провайдеров работают разные. Не угадал — вкладка Проверка → «Подобрать»."/>
                      <Button x:Name="BtnInstall" Grid.Column="1" Content="Установить службу" Style="{StaticResource Accent}" Margin="10,0,0,0"
                              ToolTip="Создаст службу Windows с выбранной стратегией и включит автозапуск. Если служба уже есть — пересоздаст её с новой стратегией."/>
                      <Button x:Name="BtnRemove" Grid.Column="2" Content="Удалить" Style="{StaticResource Danger}" Margin="4,0,0,0"
                              ToolTip="Удалит службу и драйвер WinDivert. Списки и настройки останутся — поставить обратно можно в один клик."/>
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
                    <ToggleButton x:Name="TglFaceit" Style="{StaticResource SwitchLg}" HorizontalAlignment="Right" VerticalAlignment="Top"
                                  ToolTip="Включает обход на любые IP по портам 1024–65535 — так ловится игровой трафик, у которого нет домена. Game Filter при этом переключается в «TCP и UDP»."/>
                  </Grid>
                </Border>

                <Border Style="{StaticResource Card}">
                  <StackPanel>
                    <Grid>
                      <StackPanel MaxWidth="560" HorizontalAlignment="Left">
                        <TextBlock Text="И&#x2009;Г&#x2009;Р&#x2009;О&#x2009;В&#x2009;О&#x2009;Й&#x2009;&#x2009;Р&#x2009;Е&#x2009;Ж&#x2009;И&#x2009;М" Style="{StaticResource Kicker}"/>
                        <TextBlock Text="Lineage 2" FontSize="18" FontWeight="SemiBold" Margin="0,10,0,0"/>
                        <TextBlock x:Name="TxtL2Desc" Style="{StaticResource Muted}" FontSize="13" Margin="0,6,0,0"
                                   Text="Пишет «Связь с сервером прервалась»? Поставь «Не трогать»: zapret перестанет вмешиваться в соединение с сервером Линейки. «Обход» — только если провайдер блокирует сам сервер."/>
                      </StackPanel>
                      <ComboBox x:Name="CmbL2Mode" Width="200" Height="38" HorizontalAlignment="Right" VerticalAlignment="Top"
                                ToolTip="Не трогать — порты Линейки вообще не проходят через zapret (лечит обрывы при включённом FACEIT MODE). Обход — отдельное правило обмана DPI на портах Линейки, если провайдер блокирует сервер.">
                        <ComboBoxItem Content="Выключен"/>
                        <ComboBoxItem Content="Не трогать"/>
                        <ComboBoxItem Content="Обход блокировки"/>
                      </ComboBox>
                    </Grid>
                    <Grid Margin="0,14,0,0">
                      <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="170"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                      </Grid.ColumnDefinitions>
                      <TextBlock Grid.Column="0" Text="Порты" Foreground="{StaticResource TextMid}" FontSize="12.5" VerticalAlignment="Center" Margin="0,0,12,0"/>
                      <TextBox x:Name="TxtL2Ports" Grid.Column="1" FontFamily="Consolas" FontSize="12.5" Padding="10,7"
                               ToolTip="Через запятую, диапазон через дефис. У большинства серверов 2106 и 7777. Не знаешь свои — нажми «Найти порты» и зайди в игру."/>
                      <Button x:Name="BtnL2Find" Grid.Column="2" Content="Найти порты" Padding="14,8" Margin="10,0,0,0"
                              ToolTip="Минуту следит за соединениями клиента Линейки: запусти игру и попробуй войти — приложение само увидит адрес и порты сервера."/>
                      <TextBlock x:Name="TxtL2Hint" Grid.Column="3" Text="Свои порты? Впиши и нажми Enter" Foreground="{StaticResource TextLow}" FontSize="12" VerticalAlignment="Center" Margin="12,0,0,0" TextWrapping="Wrap"/>
                    </Grid>
                  </StackPanel>
                </Border>

                <Border Style="{StaticResource Card}">
                  <StackPanel>
                    <StackPanel MaxWidth="600" HorizontalAlignment="Left">
                      <TextBlock Text="И&#x2009;С&#x2009;К&#x2009;Л&#x2009;Ю&#x2009;Ч&#x2009;Е&#x2009;Н&#x2009;И&#x2009;Я" Style="{StaticResource Kicker}"/>
                      <TextBlock Text="Не трогать порты" FontSize="18" FontWeight="SemiBold" Margin="0,10,0,0"/>
                      <TextBlock Style="{StaticResource Muted}" FontSize="13" Margin="0,6,0,0"
                                 Text="FACEIT MODE вмешивается во всё на портах 1024+. Некоторым программам это ломает связь — например, RustDesk пишет «Не подключено». Порты отсюда zapret пропускает как есть, сайты и обход это не задевает."/>
                    </StackPanel>
                    <Grid Margin="0,14,0,0">
                      <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*" MaxWidth="260"/>
                        <ColumnDefinition Width="Auto"/>
                      </Grid.ColumnDefinitions>
                      <TextBlock Grid.Column="0" Text="Порты" Foreground="{StaticResource TextMid}" FontSize="12.5" VerticalAlignment="Center" Margin="0,0,12,0"/>
                      <TextBox x:Name="TxtExPorts" Grid.Column="1" FontFamily="Consolas" FontSize="12.5" Padding="10,7"
                               ToolTip="Через запятую, диапазон через дефис. Действует на TCP и UDP. Пусто — ничего не исключено."/>
                      <StackPanel Grid.Column="2" Orientation="Horizontal" Margin="10,0,0,0">
                        <Button x:Name="BtnExRustDesk" Content="+ RustDesk" Padding="12,8" ToolTip="Порты сервера RustDesk: 21115–21119"/>
                        <Button x:Name="BtnExAnyDesk" Content="+ AnyDesk" Padding="12,8" Margin="6,0,0,0" ToolTip="Порт AnyDesk: 6568"/>
                        <Button x:Name="BtnExTeamViewer" Content="+ TeamViewer" Padding="12,8" Margin="6,0,0,0" ToolTip="Порт TeamViewer: 5938"/>
                      </StackPanel>
                    </Grid>
                    <TextBlock x:Name="TxtExHint" Text="Свои порты? Впиши и нажми Enter. Работает, когда включён FACEIT MODE или игровой фильтр" Foreground="{StaticResource TextLow}" FontSize="12" Margin="0,8,0,0" TextWrapping="Wrap"/>
                  </StackPanel>
                </Border>

                <Border Style="{StaticResource Card}">
                  <StackPanel>
                    <TextBlock Text="П&#x2009;А&#x2009;Р&#x2009;А&#x2009;М&#x2009;Е&#x2009;Т&#x2009;Р&#x2009;Ы" Style="{StaticResource Kicker}" Margin="0,0,0,6"/>
                    <Grid Margin="0,14,0,14">
                      <StackPanel VerticalAlignment="Center">
                        <TextBlock Text="Game Filter" FontSize="14.5" FontWeight="Medium"/>
                        <TextBlock x:Name="TxtGameSub" Text="Диапазоны портов для игрового трафика" Foreground="{StaticResource TextMid}" FontSize="12.5" Margin="0,3,0,0"/>
                      </StackPanel>
                      <ComboBox x:Name="CmbGame" Width="190" Height="38" HorizontalAlignment="Right"
                                ToolTip="На каких портах применять игровые правила обхода. Пока включён FACEIT MODE, управляется им.">
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
                      <Button x:Name="BtnIpsetUpdate" Content="Обновить список" HorizontalAlignment="Right" Padding="15,9"
                              ToolTip="Скачает свежий список IP-адресов Discord и YouTube с GitHub. Нужен редко — когда голос в Discord перестал работать."/>
                    </Grid>
                    <Rectangle Style="{StaticResource Hair}"/>
                    <Grid Margin="0,14,0,0">
                      <StackPanel VerticalAlignment="Center">
                        <TextBlock Text="Автопроверка обновлений" FontSize="14.5" FontWeight="Medium"/>
                        <TextBlock Text="При запуске тихо проверять новые версии zapret и самого приложения" Foreground="{StaticResource TextMid}" FontSize="12.5" Margin="0,3,0,0"/>
                      </StackPanel>
                      <ToggleButton x:Name="TglUpd" Style="{StaticResource Switch}" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                    </Grid>
                  </StackPanel>
                </Border>

                <!-- Обновление: zapret и само приложение -->
                <Border Style="{StaticResource Card}">
                  <StackPanel>
                    <TextBlock Text="О&#x2009;Б&#x2009;Н&#x2009;О&#x2009;В&#x2009;Л&#x2009;Е&#x2009;Н&#x2009;И&#x2009;Е" Style="{StaticResource Kicker}"/>
                    <Grid Margin="0,10,0,0">
                      <StackPanel MaxWidth="560" HorizontalAlignment="Left">
                        <TextBlock x:Name="TxtVerLocal" Text="zapret: —" FontSize="14.5" FontWeight="Medium"/>
                        <TextBlock x:Name="TxtVerLatest" Text="Нажми «Проверить», чтобы узнать о новой версии"
                                   Foreground="{StaticResource TextMid}" FontSize="12.5" Margin="0,4,0,0" TextWrapping="Wrap"/>
                      </StackPanel>
                      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                        <Button x:Name="BtnCheckUpd" Content="Проверить" Padding="15,9"
                                ToolTip="Спросит у GitHub, есть ли новые версии zapret и Zapret Control. Ничего не скачивает и не меняет."/>
                        <Button x:Name="BtnDoUpd" Content="Обновить zapret" Style="{StaticResource Accent}" Margin="8,0,0,0" Visibility="Collapsed"
                                ToolTip="Скачает новую версию zapret, перенесёт твои списки и настройки и переустановит службу. Старая версия сохранится рядом."/>
                      </StackPanel>
                    </Grid>
                    <Rectangle Style="{StaticResource Hair}" Margin="0,14,0,14"/>
                    <Grid>
                      <StackPanel MaxWidth="560" HorizontalAlignment="Left">
                        <TextBlock x:Name="TxtAppVer" Text="Zapret Control: —" FontSize="14.5" FontWeight="Medium"/>
                        <TextBlock x:Name="TxtAppLatest" Text="Само приложение тоже умеет обновляться"
                                   Foreground="{StaticResource TextMid}" FontSize="12.5" Margin="0,4,0,0" TextWrapping="Wrap"/>
                      </StackPanel>
                      <Button x:Name="BtnAppUpd" Content="Обновить приложение" Style="{StaticResource Accent}" HorizontalAlignment="Right" VerticalAlignment="Center" Visibility="Collapsed"
                              ToolTip="Скачает новую версию Zapret Control с GitHub и заменит файл приложения. Папку zapret и службу не трогает."/>
                    </Grid>
                  </StackPanel>
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
                  <Button x:Name="BtnRunTests" Content="Проверить сейчас" Style="{StaticResource Accent}" HorizontalAlignment="Right" VerticalAlignment="Top"
                          ToolTip="Попробует установить защищённое соединение с YouTube и Discord. Занимает несколько секунд, ничего не меняет."/>
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
                               Text="Проверяет все стратегии по очереди и показывает, какие пробивают блокировки. Какую поставить — выбираешь сам. Текущая стратегия после проверки возвращается. Занимает несколько минут, интернет в это время будет прерываться."/>
                  </StackPanel>
                  <Button x:Name="BtnAutoPick" Content="Подобрать" Style="{StaticResource Accent}" HorizontalAlignment="Right" VerticalAlignment="Center"
                          ToolTip="По очереди поставит каждую стратегию и проверит доступ. В конце — таблица, выбираешь сам. Текущая стратегия вернётся."/>
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
                <Button x:Name="BtnDiag" Content="Запустить диагностику" Style="{StaticResource Accent}" Margin="0,0,10,10" Padding="20,11"
                        ToolTip="Проверит службы, драйвер, DNS, прокси и известные конфликты. Ничего не меняет, кроме TCP timestamps, если они оказались выключены."/>
                <Button x:Name="BtnReport" Content="Скопировать отчёт" Margin="0,0,10,10" Padding="18,11"
                        ToolTip="Скопирует состояние, результат диагностики и журнал в буфер обмена — чтобы вставить в сообщение, когда просишь помощи."/>
                <Button x:Name="BtnRestartSvc" Content="Перезапустить службу" Margin="0,0,10,10" Padding="18,11"
                        ToolTip="Остановит и заново запустит службу zapret. Помогает, если обход перестал работать после сна ПК или смены сети."/>
                <Button x:Name="BtnOpenFolder" Content="Открыть папку" Margin="0,0,10,10" Padding="18,11"
                        ToolTip="Откроет папку zapret в Проводнике."/>
                <Button x:Name="BtnKillWinws" Content="Остановить winws.exe" Margin="0,0,10,10" Padding="18,11"
                        ToolTip="Принудительно завершит процесс обхода. Служба поднимет его заново при следующем запуске."/>
                <Button x:Name="BtnFixDivert" Content="Удалить WinDivert" Margin="0,0,10,10" Padding="18,11"
                        ToolTip="Удалит драйвер WinDivert из системы. Нужно, если он завис после сбоя zapret. Служба поставит его заново сама."/>
                <Button x:Name="BtnDiscordCache" Content="Очистить кэш Discord" Margin="0,0,10,10" Padding="18,11"
                        ToolTip="Закроет Discord и удалит его кэш. Помогает, когда после смены стратегии не грузятся картинки или не подключается голос."/>
                <Button x:Name="BtnOpenLog" Content="Папка с логом" Margin="0,0,10,10" Padding="18,11"
                        ToolTip="Откроет папку с журналом приложения."/>
                <Button x:Name="BtnResetAll" Content="Вернуть всё как было" Style="{StaticResource Danger}" BorderBrush="#40E5534B" Margin="0,0,10,10" Padding="18,11"
                        ToolTip="Полный откат: удалит службу и драйвер, выключит FACEIT MODE, вернёт сетевую настройку Windows. Папка zapret останется."/>
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

          <TabItem Header="Соединения" Tag="&#x21C4;">
            <Grid>
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
              </Grid.RowDefinitions>
              <Border Grid.Row="0" Style="{StaticResource Card}">
                <StackPanel>
                  <Grid>
                    <StackPanel MaxWidth="520" HorizontalAlignment="Left">
                      <TextBlock Text="Ж&#x2009;У&#x2009;Р&#x2009;Н&#x2009;А&#x2009;Л&#x2009;&#x2009;С&#x2009;О&#x2009;Е&#x2009;Д&#x2009;И&#x2009;Н&#x2009;Е&#x2009;Н&#x2009;И&#x2009;Й" Style="{StaticResource Kicker}"/>
                      <TextBlock Text="Куда не получается подключиться" FontSize="18" FontWeight="SemiBold" Margin="0,10,0,0"/>
                      <TextBlock Style="{StaticResource Muted}" FontSize="13" Margin="0,6,0,0"
                                 Text="Нажми «Начать запись», повтори проблему — открой игру, сайт или программу — и останови. Будет видно, какая программа к каким адресам стучалась и что с каждым соединением случилось."/>
                    </StackPanel>
                    <Button x:Name="BtnConnStart" Content="Начать запись" Style="{StaticResource Accent}" HorizontalAlignment="Right" VerticalAlignment="Top"
                            ToolTip="Следит за всеми TCP-соединениями компьютера, пока не остановишь (максимум 15 минут). Ничего не меняет и никуда не отправляет."/>
                  </Grid>
                  <Grid Margin="0,16,0,0">
                    <Grid.RowDefinitions>
                      <RowDefinition Height="Auto"/>
                      <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>
                    <TextBlock x:Name="TxtConnStatus" Grid.Row="1" Text="Запись не идёт" Foreground="{StaticResource TextMid}" FontSize="12.5"
                               TextWrapping="Wrap" Margin="0,12,0,0"/>
                    <StackPanel Grid.Row="0" Orientation="Horizontal" HorizontalAlignment="Right">
                      <TextBlock Text="Только проблемные" Foreground="{StaticResource TextMid}" FontSize="12.5" VerticalAlignment="Center"/>
                      <ToggleButton x:Name="TglConnBad" Style="{StaticResource Switch}" Margin="10,0,16,0" VerticalAlignment="Center"
                                    ToolTip="Скрыть адреса, к которым всё подключалось нормально"/>
                      <Button x:Name="BtnConnCopy" Content="Скопировать" Padding="14,8" IsEnabled="False"
                              ToolTip="Скопирует сводку по адресам в буфер обмена — вставь её в сообщение, когда просишь помощи."/>
                      <Button x:Name="BtnConnSave" Content="Сохранить в файл" Padding="14,8" Margin="8,0,0,0" IsEnabled="False"
                              ToolTip="Сохранит полный журнал — сводку и каждое соединение по времени — в текстовый файл и покажет его в Проводнике."/>
                    </StackPanel>
                  </Grid>
                </StackPanel>
              </Border>
              <Border Grid.Row="1" Background="{StaticResource WellBg}" BorderBrush="{StaticResource Line}" BorderThickness="1"
                      CornerRadius="14" Padding="8,10" Margin="0,0,0,16">
                <ScrollViewer VerticalScrollBarVisibility="Auto">
                  <StackPanel x:Name="ConnList"/>
                </ScrollViewer>
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
                 'CmbL2Mode','TxtL2Ports','TxtL2Hint','BtnL2Find','TxtL2Desc',
                 'TxtExPorts','BtnExRustDesk','BtnExAnyDesk','BtnExTeamViewer','TxtExHint',
                 'BtnRunTests','TestList','BtnAutoPick',
                 'TxtExclude','BtnSaveExclude','TxtGeneral','BtnSaveGeneral',
                 'TxtVerLocal','TxtVerLatest','BtnCheckUpd','BtnDoUpd','LnkTg','LnkGh','TxtVer','TxtGameSub',
                 'TxtAppVer','TxtAppLatest','BtnAppUpd',
                 'BtnDiag','BtnReport','BtnRestartSvc','BtnOpenFolder','BtnKillWinws','BtnFixDivert','BtnDiscordCache','BtnOpenLog','BtnResetAll','TxtDiag','TxtLog',
                 'BtnConnStart','TxtConnStatus','TglConnBad','BtnConnCopy','BtnConnSave','ConnList',
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

# ---------- Результаты автоподбора: таблица с выбором ----------
$script:PickRows = @{}

function Show-PickResults($results, [int]$total) {
    $ui.TestList.Children.Clear()
    $script:TestRows = @{}
    $script:PickRows = @{}

    $sorted = @($results | Sort-Object @{ Expression = { [int]$_.pass }; Descending = $true },
                                       @{ Expression = { [int]$_.idx };  Descending = $false })

    $hdr = New-Object System.Windows.Controls.TextBlock
    $hdr.Text = 'Лучшие сверху. Нажми «Поставить» напротив той, что нужна.'
    $hdr.FontSize = 12.5; $hdr.Foreground = $BrGrayTx
    $hdr.Margin = New-Object System.Windows.Thickness 12,4,6,8
    $ui.TestList.Children.Add($hdr) | Out-Null

    $first = $true
    foreach ($r in $sorted) {
        $name = [string]$r.name
        $pass = [int]$r.pass
        $started = [bool]$r.started

        $row = New-Object System.Windows.Controls.Grid
        $row.Margin = New-Object System.Windows.Thickness 6,4,6,4
        $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = 'Auto'
        $c2 = New-Object System.Windows.Controls.ColumnDefinition
        $c3 = New-Object System.Windows.Controls.ColumnDefinition; $c3.Width = 'Auto'
        $c4 = New-Object System.Windows.Controls.ColumnDefinition; $c4.Width = 'Auto'
        $row.ColumnDefinitions.Add($c1); $row.ColumnDefinitions.Add($c2)
        $row.ColumnDefinitions.Add($c3); $row.ColumnDefinitions.Add($c4)

        $dot = New-Object System.Windows.Shapes.Ellipse
        $dot.Width = 7; $dot.Height = 7; $dot.VerticalAlignment = 'Center'
        $dot.Margin = New-Object System.Windows.Thickness 6,0,0,0
        [System.Windows.Controls.Grid]::SetColumn($dot, 0)

        $txt = New-Object System.Windows.Controls.TextBlock
        $txt.Text = $name
        $txt.FontFamily = New-Object System.Windows.Media.FontFamily 'Consolas'
        $txt.FontSize = 12.5; $txt.Foreground = $BrBody
        $txt.VerticalAlignment = 'Center'; $txt.Margin = New-Object System.Windows.Thickness 12,0,10,0
        $txt.TextTrimming = 'CharacterEllipsis'
        [System.Windows.Controls.Grid]::SetColumn($txt, 1)

        $st = New-Object System.Windows.Controls.TextBlock
        $st.FontSize = 12.5; $st.FontWeight = 'Medium'; $st.VerticalAlignment = 'Center'
        $st.Margin = New-Object System.Windows.Thickness 0,0,6,0
        [System.Windows.Controls.Grid]::SetColumn($st, 2)

        if (-not $started) {
            $dot.Fill = $BrRed; $st.Text = 'не запускается'; $st.Foreground = $BrRedTx
        } elseif ($pass -ge $total -and $total -gt 0) {
            $dot.Fill = $BrGreen; $dot.Effect = $DotGlow
            $st.Text = "работает · $pass из $total"; $st.Foreground = $BrGreenTx
        } elseif ($pass -gt 0) {
            $dot.Fill = $BrAmber; $st.Text = "частично · $pass из $total"; $st.Foreground = $BrAmber
        } else {
            $dot.Fill = $BrRed; $st.Text = "не пробивает · 0 из $total"; $st.Foreground = $BrRedTx
        }

        $btn = New-Object System.Windows.Controls.Button
        $btn.Content = 'Поставить'
        $btn.FontSize = 12
        $btn.Padding = New-Object System.Windows.Thickness 14,5,14,5
        $btn.Margin = New-Object System.Windows.Thickness 8,0,4,0
        $btn.VerticalAlignment = 'Center'
        $btn.Tag = $name
        if ($first -and $started -and $pass -ge $total -and $total -gt 0) { $btn.Style = $win.FindResource('Accent') }
        if (-not $started) { $btn.IsEnabled = $false }
        $btn.Add_Click({
            param($sender, $e)
            $n = [string]$sender.Tag
            $ui.CmbStrategy.SelectedItem = $n
            Invoke-Install '(выбрана после автоподбора)'
        })
        [System.Windows.Controls.Grid]::SetColumn($btn, 3)

        $row.Children.Add($dot) | Out-Null
        $row.Children.Add($txt) | Out-Null
        $row.Children.Add($st)  | Out-Null
        $row.Children.Add($btn) | Out-Null
        $ui.TestList.Children.Add($row) | Out-Null
        $script:PickRows[$name] = @{ btn = $btn; started = $started }
        $first = $false
    }
    Update-PickMarks
}

# Помечает в таблице подбора стратегию, которая стоит сейчас
function Update-PickMarks {
    if (-not $script:PickRows -or $script:PickRows.Count -eq 0) { return }
    $cur = Get-CurrentStrategy
    foreach ($k in @($script:PickRows.Keys)) {
        $pr = $script:PickRows[$k]
        if (-not $pr.started) { continue }
        if ($cur -and $k -eq $cur) { $pr.btn.Content = 'Стоит сейчас'; $pr.btn.IsEnabled = $false }
        else { $pr.btn.Content = 'Поставить'; $pr.btn.IsEnabled = $true }
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
            $ui.TxtStrategy.Inlines.Add($r1); $ui.TxtStrategy.Inlines.Add($r2)
            if (Test-Path -LiteralPath (Join-Path $script:Root ($strat + '.bat'))) {
                $ui.TxtStrategy.Inlines.Add((New-Object System.Windows.Documents.Run ' · автозапуск при включении ПК'))
            } else {
                # после обновления zapret стратегию могли переименовать — служба работает, но пересобрать её уже нельзя
                $r3 = New-Object System.Windows.Documents.Run ' · файла этой стратегии больше нет — выбери другую и переустанови'
                $r3.Foreground = $BrAmber
                $ui.TxtStrategy.Inlines.Add($r3)
            }
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

        if (-not $ui.CmbL2Mode.IsDropDownOpen) {
            $l2idx = switch (Get-LineageMode) { 'exclude' { 1 } 'bypass' { 2 } default { 0 } }
            if ($ui.CmbL2Mode.SelectedIndex -ne $l2idx) { $ui.CmbL2Mode.SelectedIndex = $l2idx }
        }
        if (-not $ui.TxtL2Ports.IsKeyboardFocused -and -not $script:L2Dirty) { $ui.TxtL2Ports.Text = Get-LineagePorts }
        if (-not $ui.TxtExPorts.IsKeyboardFocused -and -not $script:ExDirty) { $ui.TxtExPorts.Text = Get-ExcludePorts }

        $faceit = Test-Faceit
        $ui.TglFaceit.IsChecked = $faceit
        # FACEIT MODE сам выставляет game filter = all; ручная смена в этот момент только ломала режим
        $ui.CmbGame.IsEnabled = -not $faceit
        $ui.TxtGameSub.Text = if ($faceit) { 'Управляется FACEIT MODE — выключи его, чтобы менять вручную' } else { 'Диапазоны портов для игрового трафика' }

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

# Перечитывает список стратегий из папки (после обновления zapret они могут измениться)
function Refresh-Strategies {
    $sel = Get-SelectedStrategy
    $ui.CmbStrategy.Items.Clear()
    $script:Strategies = @(Get-StrategyFiles | ForEach-Object { $_.BaseName })
    foreach ($s in $script:Strategies) { [void]$ui.CmbStrategy.Items.Add($s) }
    $cur = Get-CurrentStrategy
    if ($sel -and $script:Strategies -contains $sel)     { $ui.CmbStrategy.SelectedItem = $sel }
    elseif ($cur -and $script:Strategies -contains $cur) { $ui.CmbStrategy.SelectedItem = $cur }
    elseif ($script:Strategies.Count)                    { $ui.CmbStrategy.SelectedIndex = 0 }
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
        Update-PickMarks
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
$ui.TxtVer.Text = "v$script:AppVersion"
$ui.TxtAppVer.Text = "Zapret Control: $script:AppVersion"

$ui.TitleBar.Add_MouseLeftButtonDown({ try { $win.DragMove() } catch {} })
$ui.BtnMin.Add_Click({ $win.WindowState = 'Minimized' })
$ui.BtnClose.Add_Click({ $win.Close() })

# Ошибка внутри обработчика кнопки раньше молча убивала всё окно — теперь пишем в журнал и живём дальше
$win.Dispatcher.Add_UnhandledException({
    param($sender, $e)
    $e.Handled = $true
    $m = try { $e.Exception.GetBaseException().Message } catch { 'неизвестная ошибка' }
    try { Log "ОШИБКА: $m" } catch {}
    try { Hide-Busy } catch {}
    try { Show-Info 'Что-то пошло не так' "$m`n`nПриложение продолжает работать. Если повторится — «Скопировать отчёт» на вкладке Диагностика и напиши в комментарии к посту." } catch {}
})

# Esc закрывает диалог / останавливает долгую операцию, Enter подтверждает безопасные вопросы
$win.Add_PreviewKeyDown({
    param($sender, $e)
    if ($ui.DialogOverlay.Visibility -eq 'Visible') {
        if ($e.Key -eq 'Escape') {
            $ui.DlgNo.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))); $e.Handled = $true
        } elseif ($e.Key -eq 'Return') {
            # для опасных подтверждений (красная кнопка) Enter ничего не делает — только осознанный клик
            if ($ui.DlgYes.Visibility -ne 'Visible') { $ui.DlgNo.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))); $e.Handled = $true }
            elseif ($ui.DlgYes.Style -ne $win.FindResource('DangerSolid')) { $ui.DlgYes.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))); $e.Handled = $true }
        }
    } elseif ($ui.BusyOverlay.Visibility -eq 'Visible' -and $e.Key -eq 'Escape' -and $ui.BtnBusyCancel.Visibility -eq 'Visible') {
        $ui.BtnBusyCancel.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))); $e.Handled = $true
    }
})

$script:Strategies = @()
Refresh-Strategies

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
    Show-Confirm 'Удалить службу Zapret?' 'Служба и драйвер WinDivert будут удалены из системы, обход перестанет запускаться при старте ПК. Списки и настройки сохранятся — поставить обратно можно в один клик. Полный откат со всеми настройками — вкладка Диагностика → «Вернуть всё как было».' 'Да, удалить' $true {
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

# ---------- Lineage 2 ----------
$script:L2Dirty = $false

function Set-LineageMode([string]$mode) {
    $flag = Join-Path $script:Utils 'lineage.enabled'
    if ($mode -eq 'exclude' -or $mode -eq 'bypass') { Set-Content -LiteralPath $flag -Value $mode -Encoding ASCII }
    elseif ([IO.File]::Exists($flag)) { [IO.File]::Delete($flag) }
}
function Set-Lineage([bool]$on) { if (-not $on) { Set-LineageMode 'off' } else { Set-LineageMode 'bypass' } }

# Сохраняет порты из поля; $true — если сохранились (или не менялись), $false — если ввод неверный
function Save-LineagePorts {
    $chk = Test-LineagePorts $ui.TxtL2Ports.Text
    if (-not $chk.ok) {
        $ui.TxtL2Hint.Text = $chk.err; $ui.TxtL2Hint.Foreground = $BrRedTx
        return $false
    }
    $old = Get-LineagePorts
    $ui.TxtL2Ports.Text = $chk.ports
    $script:L2Dirty = $false
    $ui.TxtL2Hint.Text = 'Свои порты? Впиши и нажми Enter'; $ui.TxtL2Hint.Foreground = $BrGray
    if ($chk.ports -ne $old) {
        Set-Content -LiteralPath (Join-Path $script:Utils 'lineage.ports') -Value $chk.ports -Encoding ASCII
        Log "Lineage 2: порты $($chk.ports)"
        if (Test-Lineage) { Offer-Reinstall 'Порты Lineage 2 изменены.' }
    }
    return $true
}

$ui.CmbL2Mode.Add_SelectionChanged({
    if ($script:updating) { return }
    $mode = switch ($ui.CmbL2Mode.SelectedIndex) { 1 { 'exclude' } 2 { 'bypass' } default { 'off' } }
    if ($mode -eq (Get-LineageMode)) { return }
    if ($mode -ne 'off' -and -not (Save-LineagePorts)) {
        $script:updating = $true
        try { $ui.CmbL2Mode.SelectedIndex = switch (Get-LineageMode) { 'exclude' { 1 } 'bypass' { 2 } default { 0 } } } finally { $script:updating = $false }
        return
    }
    Set-LineageMode $mode
    $what = switch ($mode) {
        'exclude' { "Lineage 2: «Не трогать» — порты $(Get-LineagePorts) не проходят через zapret" }
        'bypass'  { "Lineage 2: обход блокировки на портах $(Get-LineagePorts), любые IP" }
        default   { 'Lineage 2: режим выключен' }
    }
    Log $what
    if ($mode -eq 'exclude' -and -not (Test-Faceit) -and (Get-GameFilter).Mode -notin 'all', 'tcp') {
        Log 'Lineage 2: FACEIT MODE и игровой TCP-фильтр выключены — zapret и так не трогал порты Линейки, режим заработает, когда они включатся'
    }
    Update-Status
    if ($mode -ne 'off' -and -not (Get-Service -Name zapret -ErrorAction SilentlyContinue)) {
        Show-Info 'Режим Lineage 2 сохранён' 'Осталось выбрать стратегию и нажать «Установить службу» — режим встроится в неё.'
        return
    }
    Offer-Reinstall $(switch ($mode) { 'exclude' { 'Lineage 2: «Не трогать» включён.' } 'bypass' { 'Lineage 2: обход включён.' } default { 'Режим Lineage 2 выключен.' } })
})

# ---------- Lineage 2: поиск портов сервера ----------
# Смотрим, куда подключается клиент Линейки, пока человек входит в игру. Порт 80/443 — это лаунчер и сайт, не игра.
$script:L2ProcRegex = '^(?i)(l2|l2\.bin|lineage.*|la2.*|l2[a-z0-9_]*)$'
$ui.BtnL2Find.Add_Click({
    $ui.BtnL2Find.IsEnabled = $false
    $ui.TxtL2Hint.Text = 'Жду минуту: запусти игру и попробуй войти...'; $ui.TxtL2Hint.Foreground = $BrAmber
    Log 'Lineage 2: ищу порты сервера — запусти игру и попробуй войти (до 60 секунд)'
    $ok = Start-Quiet -Params @{ typeSrc = $script:ConnTypeSrc; rx = $script:L2ProcRegex; seconds = 60 } -Body @'
if (-not ('ZcTcpTable' -as [type])) { Add-Type -TypeDefinition $CTX.typeSrc -Language CSharp }
$found = @{}; $names = @{}
$end = (Get-Date).AddSeconds($CTX.seconds)
$firstHit = $null
while ((Get-Date) -lt $end) {
    foreach ($r in [ZcTcpTable]::Read()) {
        if ($r.Pid -le 4 -or $r.State -eq 2 -or $r.RemotePort -in 80, 443) { continue }
        if ($r.Remote -like '127.*' -or $r.Remote -eq '::1' -or $r.Remote -eq '0.0.0.0' -or $r.Remote -eq '::') { continue }
        if (-not $names.ContainsKey($r.Pid)) {
            $n = ''
            try { $n = [System.Diagnostics.Process]::GetProcessById($r.Pid).ProcessName } catch {}
            $names[$r.Pid] = $n
        }
        $pn = $names[$r.Pid]
        if (-not $pn -or $pn -notmatch $CTX.rx -or $pn -match '(?i)updat|launch|patch') { continue }
        $k = "$($r.Remote):$($r.RemotePort)"
        if (-not $found.ContainsKey($k)) {
            $found[$k] = @{ proc = "$pn.exe"; remote = $r.Remote; port = $r.RemotePort; est = $false }
            if (-not $firstHit) { $firstHit = Get-Date }
        }
        if ($r.State -eq 5) { $found[$k].est = $true }
    }
    # вход в игру — это два соединения (вход и игра); после первого ждём ещё 20 секунд и хватит
    if ($firstHit -and ((Get-Date) - $firstHit).TotalSeconds -ge 20) { break }
    Start-Sleep -Milliseconds 300
}
@{ found = @($found.Values) }
'@ -OnDone {
        param($res)
        $ui.BtnL2Find.IsEnabled = $true
        $r = @($res)[-1]
        $list = @($r.found)
        if (-not $list.Count) {
            $ui.TxtL2Hint.Text = 'Клиент Линейки не подключался. Нажми ещё раз и сразу входи в игру'; $ui.TxtL2Hint.Foreground = $BrRedTx
            Log 'Lineage 2: за минуту клиент игры ни к чему не подключился'
            return
        }
        $ports = @($list | ForEach-Object { [int]$_.port } | Sort-Object -Unique)
        $desc = ($list | ForEach-Object { "$($_.proc) → $($_.remote):$($_.port)$(if ($_.est) { '' } else { ' (не ответил)' })" }) -join ', '
        Log "Lineage 2: найдено — $desc"
        $ui.TxtL2Ports.Text = ($ports -join ',')
        $script:L2Dirty = $true
        if (Save-LineagePorts) {
            $ui.TxtL2Hint.Text = "Найдено: $desc"; $ui.TxtL2Hint.Foreground = $BrGreenTx
        }
    }
    if (-not $ok) {
        $ui.BtnL2Find.IsEnabled = $true
        $ui.TxtL2Hint.Text = 'Подожди пару секунд — идёт другая проверка'; $ui.TxtL2Hint.Foreground = $BrAmber
    }
})

$ui.TxtL2Ports.Add_TextChanged({ if ($ui.TxtL2Ports.IsKeyboardFocused) { $script:L2Dirty = $true } })
$ui.TxtL2Ports.Add_KeyDown({
    param($sender, $e)
    if ($e.Key -eq 'Return') { [void](Save-LineagePorts); $e.Handled = $true }
})
$ui.TxtL2Ports.Add_LostKeyboardFocus({ if ($script:L2Dirty) { [void](Save-LineagePorts) } })

# ---------- Не трогать порты ----------
$script:ExDirty = $false
$script:ExHintDefault = 'Свои порты? Впиши и нажми Enter. Работает, когда включён FACEIT MODE или игровой фильтр'

function Save-ExcludePorts {
    $chk = Test-ExcludePorts $ui.TxtExPorts.Text
    if (-not $chk.ok) {
        $ui.TxtExHint.Text = $chk.err; $ui.TxtExHint.Foreground = $BrRedTx
        return $false
    }
    $old = Get-ExcludePorts
    $ui.TxtExPorts.Text = $chk.ports
    $script:ExDirty = $false
    if ($chk.ports -eq $old) {
        $ui.TxtExHint.Text = $script:ExHintDefault; $ui.TxtExHint.Foreground = $BrGray
        return $true
    }
    $f = Join-Path $script:Utils 'exclude.ports'
    if ($chk.ports) { Set-Content -LiteralPath $f -Value $chk.ports -Encoding ASCII }
    elseif ([IO.File]::Exists($f)) { [IO.File]::Delete($f) }
    $txt = Get-ExcludeText
    Log $(if ($chk.ports) { "Не трогать порты: $txt" } else { 'Не трогать порты: список очищен' })
    $gm = (Get-GameFilter).Mode
    if ($gm -eq 'off') {
        $ui.TxtExHint.Text = 'Сохранено. Сейчас FACEIT MODE и игровой фильтр выключены — zapret эти порты и так не трогает'
        $ui.TxtExHint.Foreground = $BrGray
        return $true
    }
    $ui.TxtExHint.Text = $(if ($chk.ports) { "Сохранено: $txt" } else { 'Список очищен' }); $ui.TxtExHint.Foreground = $BrGreenTx
    if (Get-Service -Name zapret -ErrorAction SilentlyContinue) { Offer-Reinstall 'Список «Не трогать порты» изменён.' }
    return $true
}

function Add-ExcludePreset([string]$name) {
    $ports = $script:ExcludePresets[$name]
    $cur = Test-ExcludePorts $ui.TxtExPorts.Text
    $list = @(if ($cur.ok -and $cur.ports) { $cur.ports -split ',' })
    if ($list -contains $ports) {
        $ui.TxtExHint.Text = "$name уже в списке ($ports)"; $ui.TxtExHint.Foreground = $BrGray
        return
    }
    $ui.TxtExPorts.Text = (@($list) + $ports) -join ','
    $script:ExDirty = $true
    [void](Save-ExcludePorts)
}
$ui.BtnExRustDesk.Add_Click({ Add-ExcludePreset 'RustDesk' })
$ui.BtnExAnyDesk.Add_Click({ Add-ExcludePreset 'AnyDesk' })
$ui.BtnExTeamViewer.Add_Click({ Add-ExcludePreset 'TeamViewer' })
$ui.TxtExPorts.Add_TextChanged({ if ($ui.TxtExPorts.IsKeyboardFocused) { $script:ExDirty = $true } })
$ui.TxtExPorts.Add_KeyDown({
    param($sender, $e)
    if ($e.Key -eq 'Return') { [void](Save-ExcludePorts); $e.Handled = $true }
})
$ui.TxtExPorts.Add_LostKeyboardFocus({ if ($script:ExDirty) { [void](Save-ExcludePorts) } })

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

# Люди вставляют адреса как есть («https://site.com/page») — zapret такие строки не матчит, нужен голый домен
function ConvertTo-BareDomain([string]$line) {
    $t = $line.Trim()
    if ($t -eq '' -or $t.StartsWith('#')) { return $line }
    $t = $t -replace '^(?i)[a-z][a-z0-9+.\-]*://', ''   # схема
    $t = $t -replace '^[^/]*@', ''                        # user:pass@
    $t = ($t -split '[/?#\s]', 2)[0]                     # путь, запрос, хвост
    $t = $t -replace ':\d+$', ''                          # порт
    $t = $t -replace '^www\.', ''
    return $t.ToLower()
}

function Save-ListFile([string]$path, [string]$text, [string]$title) {
    $lines = ($text -replace "`r`n", "`n").Trim("`n") -split "`n"
    $converted = 0; $cleaned = 0
    $out = foreach ($l in $lines) {
        $d = ConvertTo-BareDomain $l
        if ($d -ne $l.Trim()) { $cleaned++ }
        $p = ConvertTo-Punycode $d
        if ($p -ne $d) { $converted++ }
        $p
    }
    $body = ($out | Where-Object { $_ -ne '' } | Select-Object -Unique) -join "`r`n"
    if ([string]::IsNullOrWhiteSpace($body)) { $body = 'domain.example.abc' }
    Set-Content -LiteralPath $path -Value $body -Encoding ASCII
    $notes = @()
    if ($cleaned -gt 0)   { $notes += "адресов приведено к домену: $cleaned" }
    if ($converted -gt 0) { $notes += "переведено в punycode: $converted" }
    if ($notes.Count) { Log "$title сохранён ($($notes -join ', '))" } else { Log "$title сохранён" }
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
function Start-AccessTests {
    $ui.TestList.Children.Clear()
    $script:TestRows = @{}
    $script:PickRows = @{}
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
}

$ui.BtnRunTests.Add_Click({
    # без запущенного обхода проверка покажет голую блокировку — предупреждаем, чтобы не пугать
    if (-not (Get-Process -Name winws -ErrorAction SilentlyContinue)) {
        Show-Confirm 'Обход сейчас не запущен' 'Проверка покажет, что открывается без обхода — скорее всего, ничего. Запусти службу на вкладке «Управление» или проверь как есть.' 'Проверить как есть' $false { Start-AccessTests } $null
        return
    }
    Start-AccessTests
})

# ---------- Автоподбор стратегии ----------
$ui.BtnAutoPick.Add_Click({
    Show-Confirm 'Начать автоподбор?' 'Приложение проверит все стратегии по очереди и покажет, какие пробивают блокировки. Какую поставить — выберешь сам. Текущая стратегия после проверки вернётся. Займёт несколько минут, интернет в это время будет прерываться. Остановить можно в любой момент.' 'Начать' $false {
        $list = @()
        foreach ($n in @(Get-StrategyFiles | ForEach-Object { $_.BaseName })) {
            try { $list += @{ name = $n; binPath = (Get-StrategyBinPath $n) } } catch {}
        }
        if (-not $list.Count) { Show-Info 'Нет стратегий' 'В папке не найдено ни одного general-файла.'; return }

        # запоминаем, что стояло до проверки — вернём это в конце
        $orig = Get-CurrentStrategy
        $origBin = $null
        if ($orig) { try { $origBin = Get-StrategyBinPath $orig } catch {} }
        $hadSvc = [bool](Get-Service -Name zapret -ErrorAction SilentlyContinue)

        $ui.TestList.Children.Clear()
        $script:TestRows = @{}
        $script:PickRows = @{}
        foreach ($s in $list) { Set-TestRow $s.name '' 'wait' 'в очереди' }
        Log "Автоподбор: проверяю все стратегии ($($list.Count))"
        Start-Bg -BusyText 'Автоподбор стратегии...' -Cancellable $true -Params @{
            strategies = $list; targets = $script:PickTargets
            orig = $orig; origBin = $origBin; hadSvc = $hadSvc
        } -Body @'
$results = @()
$i = 0
$total = @($CTX.targets).Count
foreach ($s in $CTX.strategies) {
    if (BgStopped) { break }
    $i++
    BgBusy ("[{0}/{1}] {2}" -f $i, $CTX.strategies.Count, $s.name)
    BgTest $s.name '' 'run' ''
    $r = Install-ZapretSvc $s.binPath $s.name
    if (-not $r.ok) {
        BgTest $s.name '' 'fail' 'не запускается'
        BgLog ("  {0}: служба не стартовала — {1}" -f $s.name, $r.err)
        $results += @{ name = $s.name; pass = -1; started = $false; idx = $i }
        continue
    }
    Start-Sleep -Seconds 2
    if (BgStopped) { break }
    $pass = Test-TlsMany $CTX.targets 7000
    $results += @{ name = $s.name; pass = $pass; started = $true; idx = $i }
    BgLog ("  {0}: {1} из {2}" -f $s.name, $pass, $total)
    if ($pass -ge $total) { BgTest $s.name '' 'ok' '' }
    elseif ($pass -gt 0) { BgTest $s.name '' 'fail' ("частично: $pass из $total") }
    else { BgTest $s.name '' 'fail' ("0 из $total") }
}
$stopped = BgStopped

# возвращаем систему в состояние до проверки
if ($CTX.origBin) {
    BgBusy ("Возвращаю исходную стратегию: " + $CTX.orig)
    $rr = Install-ZapretSvc $CTX.origBin $CTX.orig
    if ($rr.ok) { BgLog ("Вернул исходную стратегию: " + $CTX.orig) }
    else { BgLog ("Не удалось вернуть исходную стратегию: " + $rr.err) }
} elseif (-not $CTX.hadSvc) {
    BgBusy 'Снимаю тестовую службу...'
    Remove-ZapretSvc
    BgLog 'До проверки служба не стояла — тестовую снял'
} else {
    BgLog 'Не удалось определить исходную стратегию — оставлена последняя проверенная'
}
@{ results = $results; total = $total; stopped = $stopped; orig = $CTX.orig }
'@ -OnDone {
            param($res)
            $r = @($res)[-1]
            if (-not $r) { return }
            $rows = @($r.results)
            if (-not $rows.Count) {
                $ui.TestList.Children.Clear(); $script:TestRows = @{}; $script:PickRows = @{}
                $back0 = if ($r.orig) { " Текущая стратегия возвращена: «$($r.orig)»." } else { '' }
                Show-Info 'Проверка остановлена' ("Ни одна стратегия не успела провериться." + $back0)
                return
            }
            Show-PickResults $rows ([int]$r.total)
            $full = @($rows | Where-Object { $_.started -and $_.pass -ge $r.total }).Count
            $part = @($rows | Where-Object { $_.started -and $_.pass -gt 0 -and $_.pass -lt $r.total }).Count
            $head = if ($r.stopped) { "Проверка остановлена, проверено стратегий: $($rows.Count)." } else { "Проверено стратегий: $($rows.Count)." }
            $back = if ($r.orig) { " Текущая стратегия возвращена: «$($r.orig)»." } else { '' }
            Log "Автоподбор завершён: полностью работают $full, частично $part, всего $($rows.Count)"
            if ($full -gt 0) {
                Show-Info 'Готово — выбирай' ("$head Полностью работают: $full, частично: $part.$back" + [Environment]::NewLine + [Environment]::NewLine + 'В списке нажми «Поставить» напротив нужной — лучшие сверху.')
            } elseif ($part -gt 0) {
                Show-Info 'Полностью рабочих нет' ("$head Частично работают: $part.$back" + [Environment]::NewLine + [Environment]::NewLine + 'Можно поставить лучшую из частичных — они сверху списка.')
            } else {
                Show-Info 'Рабочей стратегии не нашлось' ("$head Ни одна не дала доступа.$back" + [Environment]::NewLine + [Environment]::NewLine + 'Проверь вкладку «Диагностика»: мешать может VPN, другой обход или Adguard.')
            }
        }
    } $null
})

# ---------- Диагностика ----------
$ui.BtnDiag.Add_Click({
    $ui.TxtDiag.Document.Blocks.Clear()
    Start-Bg -BusyText 'Проверяю систему...' -Params @{ root = $script:Root; strategy = (Get-CurrentStrategy); ver = (Get-LocalVersion); app = $script:AppVersion } -Body @'
$allSvc = Get-Service -ErrorAction SilentlyContinue
$svc = Get-Service -Name zapret -ErrorAction SilentlyContinue

BgDiag '--' ("Zapret Control {0} · zapret {1} · служба: {2} · стратегия: {3}" -f $CTX.app, $CTX.ver,
    $(if ($svc) { [string]$svc.Status } else { 'не установлена' }), $(if ($CTX.strategy) { $CTX.strategy } else { '—' }))

$bfe = Get-Service -Name BFE -ErrorAction SilentlyContinue
if ($bfe -and $bfe.Status -eq 'Running') { BgDiag 'OK' 'Base Filtering Engine работает' }
else { BgDiag 'X' 'Base Filtering Engine НЕ работает — без него zapret не работает!' }

if (Get-Process -Name winws -ErrorAction SilentlyContinue) { BgDiag 'OK' 'winws.exe запущен' }
else { BgDiag '!' 'winws.exe не запущен (обход не активен)' }

if ($svc -and $svc.Status -ne 'Running') {
    $reason = Get-SvcFailReason
    if ($reason) { BgDiag 'X' ("Служба не работает. Журнал Windows: " + $reason) }
}

# DNS: провайдер может отдавать заглушку вместо реального адреса — обход тут бессилен, нужен DoH
try {
    $ips = @([System.Net.Dns]::GetHostAddresses('www.youtube.com') | ForEach-Object { $_.IPAddressToString })
    $bad = @($ips | Where-Object { $_ -match '^(127\.|0\.0\.0\.0$|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|::1$)' })
    if (-not $ips.Count) { BgDiag 'X' 'DNS не отвечает — youtube.com не находится. Проверь интернет или смени DNS на 1.1.1.1 / 8.8.8.8' }
    elseif ($bad.Count) { BgDiag 'X' ('DNS подменяет адреса (youtube.com -> ' + ($bad -join ', ') + ') — включи DNS-over-HTTPS в браузере или в настройках Windows') }
    else { BgDiag 'OK' ('DNS отвечает: youtube.com -> ' + (@($ips | Select-Object -First 2) -join ', ')) }
} catch { BgDiag 'X' ('DNS не отвечает: ' + $_.Exception.GetBaseException().Message + ' — смени DNS на 1.1.1.1 / 8.8.8.8') }

if ($CTX.root -match '[^\x00-\x7F]') { BgDiag '!' 'В пути к папке zapret есть кириллица или другие не-латинские символы — у части пользователей из-за этого не стартует служба. Если будут проблемы, перенеси папку в путь из латиницы' }
else { BgDiag 'OK' 'Путь к папке zapret без кириллицы' }

$proxyOn = $false
try {
    $proxyKey = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
    if ($proxyKey.ProxyEnable -eq 1) { $proxyOn = $true; BgDiag '!' ("Включён системный прокси: " + $proxyKey.ProxyServer) }
} catch {}
if (-not $proxyOn) { BgDiag 'OK' 'Системный прокси выключен' }

$tsv = Get-TcpTimestamps
if ($tsv -eq 'enabled') { BgDiag 'OK' 'TCP timestamps включены' }
elseif (-not $svc) { BgDiag 'OK' ("TCP timestamps: " + $(if ($tsv) { $tsv } else { '?' }) + " (стандарт Windows, включатся при установке службы)") }
else { & netsh interface tcp set global timestamps=enabled 2>&1 | Out-Null; BgDiag '!' 'TCP timestamps были выключены — включил' }

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
    [void]$sb.AppendLine("FACEIT: $(if (Test-Faceit) { 'вкл' } else { 'выкл' })   Lineage 2: $(Get-LineageModeText)   Не трогать порты: $(Get-ExcludeText)   GameFilter: $((Get-GameFilter).Mode)   IPSet: $(Get-IpsetStatus)")
    [void]$sb.AppendLine("winws.exe: $(if (Get-Process -Name winws -ErrorAction SilentlyContinue) { 'запущен' } else { 'не запущен' })")
    [void]$sb.AppendLine("Проверка доступа: $script:LastTestSummary")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('--- Диагностика ---')
    $range = New-Object System.Windows.Documents.TextRange($ui.TxtDiag.Document.ContentStart, $ui.TxtDiag.Document.ContentEnd)
    $dt = $range.Text.Trim()
    [void]$sb.AppendLine($(if ($dt) { $dt } else { '(не запускалась)' }))
    [void]$sb.AppendLine('')
    if ($script:MonState -and @($script:MonState.snap).Count) {
        $bad = @(Get-ConnSorted | Where-Object { (Get-ConnLevel $_) -gt 0 } | Select-Object -First 15)
        [void]$sb.AppendLine("--- Журнал соединений: проблемные адреса ($($bad.Count)) ---")
        foreach ($a in $bad) { [void]$sb.AppendLine(("{0} -> {1} · {2}" -f $a.proc, (Get-ConnTarget $a), (Get-ConnBreakdown $a))) }
        if (-not $bad.Count) { [void]$sb.AppendLine('(нет — всё подключалось)') }
        [void]$sb.AppendLine('')
    }
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

$ui.BtnResetAll.Add_Click({
    $msg = "Уберу из системы всё, что добавлял zapret:`n" +
           "•  службу zapret и автозапуск`n" +
           "•  драйвер WinDivert и процесс winws.exe`n" +
           "•  FACEIT MODE, Lineage 2 и игровой фильтр — выключу`n" +
           "•  сетевую настройку TCP timestamps — верну стандартную Windows`n`n" +
           "Обход перестанет работать. Папка zapret и твои списки сайтов останутся — если zapret больше не нужен, после этого просто удали папку."
    Show-Confirm 'Вернуть всё как было?' $msg 'Да, вернуть' $true {
        Log 'Откат: удаляю службу и WinDivert, возвращаю настройки Windows...'
        Start-Bg -BusyText 'Возвращаю всё как было...' -Body @'
Remove-ZapretSvc
$left = Get-ZapretLeftovers
for ($i = 0; $i -lt 10 -and $left.Count; $i++) { Start-Sleep -Milliseconds 500; $left = Get-ZapretLeftovers }
if ($left.Count) { BgLog ('Не удалось убрать: ' + ($left -join ', ')) } else { BgLog 'Служба zapret и WinDivert удалены, winws.exe остановлен' }
$ts = Reset-TcpTimestamps
if ($ts -eq 'enabled') { BgLog 'TCP timestamps остались включены — Windows не дала поменять (это безвредно)' }
else { BgLog ('TCP timestamps: стандарт Windows (' + $ts + ')') }
@{ ok = ($left.Count -eq 0); left = ($left -join ', '); ts = $ts }
'@ -OnDone {
            param($res)
            $r = @($res)[-1]
            try { Set-Faceit $false } catch { Log "ОШИБКА: не удалось выключить FACEIT MODE: $($_.Exception.Message)" }
            try { Set-Lineage $false } catch { Log "ОШИБКА: не удалось выключить Lineage 2: $($_.Exception.Message)" }
            Hide-Warn
            Update-Status
            Update-PickMarks
            if ($r -and $r.ok) {
                Log 'Откат завершён'
                $net = if ($r.ts -eq 'enabled') { '. Настройку TCP timestamps Windows поменять не дала — она безвредна, можно не обращать внимания.' } else { ', настройки сети стандартные.' }
                Show-Info 'Готово — всё как было' ("Службы и драйвера zapret в системе больше нет, FACEIT MODE и Lineage 2 выключены" + $net + "`n`nЕсли zapret больше не нужен — удали папку с ним. Вернуть обход — вкладка Управление → «Установить службу».")
            } elseif ($r -and $r.left) {
                Log "Откат не до конца: осталось $($r.left)"
                Show-Info 'Почти готово' "Не получилось убрать: $($r.left).`n`nОбычно Windows дочищает это после перезагрузки. Перезагрузи ПК и нажми кнопку ещё раз."
            } else {
                Show-Info 'Что-то пошло не так' 'Откат прервался с ошибкой — подробности в журнале внизу окна. Нажми кнопку ещё раз, а если не поможет — перезагрузи ПК и повтори.'
            }
        }
    } $null
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
$ui.LnkGh.Add_Click({ try { Start-Process $script:AppRepoUrl } catch {} })

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

# ---------- Обновление: zapret и само приложение ----------
$script:AppUpdate = $null   # @{ ver; url; page } когда на GitHub есть версия новее нашей

function ConvertTo-AppVersion([string]$tag) {
    try { return [version](($tag -replace '^[vV]', '').Trim()) } catch { return $null }
}

# Один тихий запрос за обеими версиями; $quiet = запуск по таймеру при старте (без шума в журнале)
function Start-UpdateCheck([bool]$quiet) {
    $ui.TxtVerLocal.Text = "zapret: $(Get-LocalVersion)"
    if (-not $quiet) {
        $ui.TxtVerLatest.Text = 'Проверяю...';  $ui.TxtVerLatest.Foreground = $BrGrayTx
        $ui.TxtAppLatest.Text = 'Проверяю...';  $ui.TxtAppLatest.Foreground = $BrGrayTx
    }
    $ui.BtnCheckUpd.IsEnabled = $false
    $started = Start-Quiet -Params @{ verUrl = $script:VersionUrl; appApi = $script:AppRepoApi; quiet = $quiet } -Body @'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$out = @{ quiet = $CTX.quiet }
try { $out.zapret = (Invoke-WebRequest -Uri $CTX.verUrl -TimeoutSec 15 -UseBasicParsing).Content.Trim() }
catch { $out.zapretErr = $_.Exception.Message }
try {
    $r = Invoke-RestMethod -Uri $CTX.appApi -TimeoutSec 15 -Headers @{ 'User-Agent' = 'zapret-control' }
    $asset = $r.assets | Where-Object { $_.name -eq 'Zapret-Control.zip' } | Select-Object -First 1
    $out.appTag  = [string]$r.tag_name
    $out.appUrl  = if ($asset) { [string]$asset.browser_download_url } else { '' }
    $out.appPage = [string]$r.html_url
} catch { $out.appErr = $_.Exception.Message }
$out
'@ -OnDone {
        param($res)
        $r = @($res)[-1]
        $ui.BtnCheckUpd.IsEnabled = $true
        if (-not $r) { return }
        $quiet = [bool]$r.quiet
        $local = Get-LocalVersion
        $ui.TxtVerLocal.Text = "zapret: $local"
        if ($r.zapret) {
            if ($r.zapret -ne $local) {
                $ui.TxtVerLatest.Text = "Доступна новая версия zapret: $($r.zapret)"
                $ui.TxtVerLatest.Foreground = $BrAmber
                $ui.BtnDoUpd.Visibility = 'Visible'
                Log "Доступно обновление zapret: $local -> $($r.zapret)"
            } else {
                $ui.TxtVerLatest.Text = "Последняя версия ($local)"
                $ui.TxtVerLatest.Foreground = $BrGreenTx
                $ui.BtnDoUpd.Visibility = 'Collapsed'
            }
        } elseif (-not $quiet) {
            $ui.TxtVerLatest.Text = 'Не удалось проверить (нет связи с GitHub?)'
            $ui.TxtVerLatest.Foreground = $BrRedTx
        }
        $nv = ConvertTo-AppVersion $r.appTag
        $cv = ConvertTo-AppVersion $script:AppVersion
        if ($nv -and $cv) {
            if ($nv -gt $cv -and $r.appUrl) {
                $script:AppUpdate = @{ ver = $nv.ToString(); url = $r.appUrl; page = $r.appPage }
                $ui.TxtAppLatest.Text = "Доступна новая версия Zapret Control: $nv"
                $ui.TxtAppLatest.Foreground = $BrAmber
                $ui.BtnAppUpd.Visibility = 'Visible'
                Log "Доступно обновление Zapret Control: $script:AppVersion -> $nv (вкладка Управление → Обновление)"
            } else {
                $script:AppUpdate = $null
                $ui.TxtAppLatest.Text = 'Последняя версия'
                $ui.TxtAppLatest.Foreground = $BrGreenTx
                $ui.BtnAppUpd.Visibility = 'Collapsed'
            }
        } elseif (-not $quiet) {
            $ui.TxtAppLatest.Text = 'Не удалось проверить (нет связи с GitHub?)'
            $ui.TxtAppLatest.Foreground = $BrRedTx
        }
    }
    if (-not $started) { $ui.BtnCheckUpd.IsEnabled = $true }
}

$ui.BtnCheckUpd.Add_Click({ Start-UpdateCheck $false })

$ui.BtnAppUpd.Add_Click({
    $u = $script:AppUpdate
    if (-not $u) { Show-Info 'Обновлений нет' 'Сначала нажми «Проверить».'; return }
    if (-not $script:SelfPath -or -not (Test-Path -LiteralPath $script:SelfPath)) {
        Show-Info 'Обнови вручную' "Не могу найти свой файл, чтобы заменить его. Скачай новую версию со страницы релизов:`n$($u.page)"
        return
    }
    Show-Confirm "Обновить Zapret Control до $($u.ver)?" "Скачаю новую версию с GitHub и заменю файл приложения (старый сохранится рядом как ZapretGUI.ps1.bak). Папку zapret, службу и настройки не трогаю. После обновления приложение перезапустится." 'Обновить' $false {
        # внутри отложенного блока локальной $u уже нет — берём из script-переменной
        $u = $script:AppUpdate
        Log "Обновление Zapret Control: $script:AppVersion -> $($u.ver)"
        Start-Bg -BusyText "Скачиваю Zapret Control $($u.ver)..." -Params @{ url = $u.url; selfPath = $script:SelfPath; ver = $u.ver; cur = $script:AppVersion } -Body @'
$tmp = Join-Path $env:TEMP ('zc_upd_' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $zip = Join-Path $tmp 'zc.zip'
    Invoke-WebRequest -Uri $CTX.url -OutFile $zip -TimeoutSec 120 -UseBasicParsing
    BgBusy 'Проверяю скачанный файл...'
    $ex = Join-Path $tmp 'ex'
    Expand-Archive -LiteralPath $zip -DestinationPath $ex -Force
    $ps1 = Get-ChildItem -LiteralPath $ex -Recurse -Filter 'ZapretGUI.ps1' | Select-Object -First 1
    if (-not $ps1) { throw 'в архиве нет ZapretGUI.ps1' }
    $txt = [IO.File]::ReadAllText($ps1.FullName, [Text.Encoding]::UTF8)
    if ($txt -notmatch "\`$script:AppVersion = '([^']+)'") { throw 'файл в архиве не похож на Zapret Control' }
    $got = $Matches[1]
    if (-not ([version]$got -gt [version]$CTX.cur)) { throw "в архиве версия $got, а установлена $($CTX.cur) — обновлять нечего" }
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($txt, [ref]$null, [ref]$errs)
    if ($errs -and $errs.Count) { throw ('файл не проходит проверку синтаксиса: ' + $errs[0].Message) }

    BgBusy 'Заменяю файл приложения...'
    Copy-Item -LiteralPath $CTX.selfPath -Destination ($CTX.selfPath + '.bak') -Force
    # пишем строго с BOM — без него PowerShell 5.1 читает кириллицу как мусор
    [IO.File]::WriteAllText($CTX.selfPath, $txt, (New-Object System.Text.UTF8Encoding($true)))
    $bat = Get-ChildItem -LiteralPath $ex -Recurse -Filter 'Zapret GUI.bat' | Select-Object -First 1
    if ($bat) { Copy-Item -LiteralPath $bat.FullName -Destination (Join-Path (Split-Path $CTX.selfPath -Parent) 'Zapret GUI.bat') -Force }
    BgLog ("Zapret Control обновлён до " + $got + " (резервная копия: ZapretGUI.ps1.bak)")
    @{ ok = $true; ver = $got }
} catch {
    BgLog ('ОШИБКА обновления приложения: ' + $_.Exception.Message)
    @{ ok = $false; err = $_.Exception.Message }
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
'@ -OnDone {
            param($res)
            $r = @($res)[-1]
            if ($r -and $r.ok) {
                $ui.BtnAppUpd.Visibility = 'Collapsed'
                $ui.TxtAppLatest.Text = "Установлена версия $($r.ver) — нужен перезапуск"
                $ui.TxtAppLatest.Foreground = $BrGreenTx
                Show-Confirm 'Приложение обновлено' "Zapret Control $($r.ver) установлен. Перезапустить сейчас?" 'Перезапустить' $false {
                    $script:RestartPath = $script:SelfPath
                    $win.Close()
                } { Log 'Новая версия заработает после перезапуска приложения' }
            } elseif ($r) {
                Show-Info 'Не удалось обновить' "$($r.err)`n`nМожно скачать вручную: $($script:AppUpdate.page)"
            }
        }
    } $null
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
        'lists\ipset-exclude-user.txt', 'utils\faceit.enabled', 'utils\game_filter.enabled', 'utils\check_updates.enabled',
        'utils\lineage.enabled', 'utils\lineage.ports', 'utils\exclude.ports'
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
            $l2mode = 'off'; $l2p = '2106,7777'
            $l2flag = Join-Path $CTX.root 'utils\lineage.enabled'
            if (Test-Path $l2flag) {
                $l2v = [string](Get-Content -LiteralPath $l2flag -TotalCount 1)
                $l2mode = if ($l2v.Trim() -eq 'exclude') { 'exclude' } else { 'bypass' }
                $l2f = Join-Path $CTX.root 'utils\lineage.ports'
                if (Test-Path $l2f) { $v = (Get-Content -LiteralPath $l2f -TotalCount 1); if ($v -and $v.Trim() -match '^\d+(-\d+)?(,\d+(-\d+)?)*$') { $l2p = $v.Trim() } }
                if ($l2mode -eq 'bypass') { $argStr = Add-LineageRule $argStr $l2p }
            }
            $gfFile = Join-Path $CTX.root 'utils\game_filter.enabled'
            $gTcp = '12'; $gUdp = '12'; $gBoth = '12'
            if (Test-Path $gfFile) {
                $mode = (Get-Content -LiteralPath $gfFile -TotalCount 1)
                if ($mode) { $mode = $mode.Trim().ToLower() }
                if ($mode -eq 'all') { $gTcp = '1024-65535'; $gUdp = '1024-65535' }
                elseif ($mode -eq 'tcp') { $gTcp = '1024-65535' }
                else { $gUdp = '1024-65535' }
                $gBoth = '1024-65535'
            }
            if ($l2mode -eq 'exclude') { $gTcp = Remove-PortsFromRange $gTcp $l2p }
            $exF = Join-Path $CTX.root 'utils\exclude.ports'
            if (Test-Path $exF) {
                $exP = ([string](Get-Content -LiteralPath $exF -TotalCount 1)).Trim()
                if ($exP -match '^\d+(-\d+)?(,\d+(-\d+)?)*$') {
                    $gTcp = Remove-PortsFromRange $gTcp $exP; $gUdp = Remove-PortsFromRange $gUdp $exP; $gBoth = Remove-PortsFromRange $gBoth $exP
                }
            }
            $argStr = $argStr.Replace('%GameFilterTCP%', $gTcp).Replace('%GameFilterUDP%', $gUdp).Replace('%GameFilter%', $gBoth)
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
                $ui.TxtVerLocal.Text = "zapret: $(Get-LocalVersion)"
                $ui.TxtVerLatest.Text = "Обновлено до $($r.version)"
                $ui.TxtVerLatest.Foreground = $BrGreenTx
                $ui.BtnDoUpd.Visibility = 'Collapsed'
                Refresh-Strategies
                Show-Info 'Обновление завершено' "zapret обновлён до $($r.version). Твои списки и настройки перенесены, служба переустановлена.`n`nСтарая версия сохранена рядом в папке с суффиксом _backup."
            } elseif ($r) {
                Show-Info 'Не удалось обновить' "$($r.err)`n`nСкачать вручную: $script:MirrorPage"
            }
        }
    } $null
})

# ---------- Журнал соединений ----------
# Таблицу TCP-соединений с PID читаем напрямую через iphlpapi: Get-NetTCPConnection тратит ~1 с на вызов,
# а здесь опрос раз в 0,4 с. Прав администратора не нужно.
$script:ConnTypeSrc = @'
using System; using System.Collections.Generic; using System.Net; using System.Runtime.InteropServices;
public static class ZcTcpTable {
    [DllImport("iphlpapi.dll")]
    static extern uint GetExtendedTcpTable(IntPtr table, ref int size, bool order, int af, int tableClass, uint reserved);
    public class Row { public int State; public string Remote; public int RemotePort; public int LocalPort; public int Pid; }
    static int Port(int v) { return ((v & 0xFF) << 8) | ((v >> 8) & 0xFF); }
    public static List<Row> Read() { var list = new List<Row>(); Fill(list, 2); Fill(list, 23); return list; }
    static void Fill(List<Row> list, int af) {
        int size = 0;
        GetExtendedTcpTable(IntPtr.Zero, ref size, false, af, 5, 0);
        for (int attempt = 0; attempt < 4; attempt++) {
            if (size <= 0) return;
            IntPtr buf = Marshal.AllocHGlobal(size);
            try {
                uint r = GetExtendedTcpTable(buf, ref size, false, af, 5, 0);
                if (r == 122) continue;
                if (r != 0) return;
                int n = Marshal.ReadInt32(buf);
                for (int i = 0; i < n; i++) {
                    var row = new Row();
                    if (af == 2) {
                        IntPtr p = IntPtr.Add(buf, 4 + i * 24);
                        row.State = Marshal.ReadInt32(p, 0);
                        row.LocalPort = Port(Marshal.ReadInt32(p, 8));
                        row.Remote = new IPAddress((long)(uint)Marshal.ReadInt32(p, 12)).ToString();
                        row.RemotePort = Port(Marshal.ReadInt32(p, 16));
                        row.Pid = Marshal.ReadInt32(p, 20);
                    } else {
                        IntPtr p = IntPtr.Add(buf, 4 + i * 56);
                        byte[] a = new byte[16]; Marshal.Copy(IntPtr.Add(p, 24), a, 0, 16);
                        var ip = new IPAddress(a);
                        row.Remote = ip.IsIPv4MappedToIPv6 ? ip.MapToIPv4().ToString() : ip.ToString();
                        row.LocalPort = Port(Marshal.ReadInt32(p, 20));
                        row.RemotePort = Port(Marshal.ReadInt32(p, 44));
                        row.State = Marshal.ReadInt32(p, 48);
                        row.Pid = Marshal.ReadInt32(p, 52);
                    }
                    list.Add(row);
                }
                return;
            } finally { Marshal.FreeHGlobal(buf); }
        }
    }
}
'@

# Фоновый опрос. Как понимаем, что случилось с соединением (состояния TCP из таблицы):
#   ждало ответа (SYN_SENT) и исчезло, не подключившись   -> «нет ответа» (>=1 с) или «сброшено сразу» (<1 с)
#   подключилось и исчезло за <2 с без нормального закрытия -> «оборвалось сразу» (так выглядит RST от DPI)
#   подключилось, но ждало ответа >=3 с                    -> «подключилось медленно»
# Нормальное закрытие с нашей стороны оставляет в таблице TIME_WAIT — по нему отличаем его от обрыва.
$script:ConnMonBody = @'
if (-not ('ZcTcpTable' -as [type])) { Add-Type -TypeDefinition $CTX.typeSrc -Language CSharp }
$conns = @{}; $agg = @{}; $names = @{}; $procs = @{}; $ignore = @{}
$events = $MON.events
$start = Get-Date
function IsLocalIp([string]$ip) { return ($ip -eq '0.0.0.0' -or $ip -eq '::' -or $ip -like '127.*' -or $ip -eq '::1') }
function ProcName([int]$id) {
    if ($procs.ContainsKey($id)) { return $procs[$id] }
    $n = "pid $id"
    try { $n = [System.Diagnostics.Process]::GetProcessById($id).ProcessName + '.exe' } catch {}
    $procs[$id] = $n
    return $n
}
function RefreshNames {
    try {
        foreach ($e in @(Get-DnsClientCache -ErrorAction Stop)) {
            if ($e.Data -and ($e.Type -eq 1 -or $e.Type -eq 28)) { $names[[string]$e.Data] = [string]$e.Entry }
        }
    } catch {}
}
function Finish($c, [string]$st, [datetime]$now) {
    $dom = $names[$c.remote]
    $dur = if ($c.est) { ($c.est - $c.first).TotalSeconds } else { ($now - $c.first).TotalSeconds }
    [void]$events.Add(@{ t = $c.first; proc = $c.proc; remote = $c.remote; rport = $c.rport; dom = $dom; st = $st; dur = [math]::Round($dur, 2) })
    if ($events.Count -gt 20000) { $events.RemoveRange(0, 2000) }
    $ak = "$($c.proc)|$($c.remote)|$($c.rport)"
    $a = $agg[$ak]
    if (-not $a) {
        $a = @{ proc = $c.proc; remote = $c.remote; rport = $c.rport; dom = $dom; n = 0; ok = 0; slow = 0; noanswer = 0; reset = 0; drop = 0; last = $now }
        $agg[$ak] = $a
    }
    $a.n++
    if ($st -eq 'slow') { $a.slow++; $a.ok++ } else { $a[$st]++ }
    $a.last = $now
    if (-not $a.dom -and $dom) { $a.dom = $dom }
    $MON.dirty = $true
}
function Publish {
    foreach ($a in $agg.Values) { if (-not $a.dom -and $names.ContainsKey($a.remote)) { $a.dom = $names[$a.remote] } }
    $MON.snap = @(foreach ($a in $agg.Values) { $a.Clone() })
    $MON.total = $events.Count
    $MON.ver++
    $MON.dirty = $false
}

RefreshNames
$lastNames = Get-Date
# то, что было открыто до начала записи, не оцениваем — мы не видели, как оно начиналось
foreach ($r in [ZcTcpTable]::Read()) { $ignore["$($r.Pid)|$($r.LocalPort)|$($r.Remote)|$($r.RemotePort)"] = 1 }
$MON.running = $true

while (-not $MON.stop) {
    try {
        $now = Get-Date
        if (($now - $lastNames).TotalSeconds -ge 3) { RefreshNames; $lastNames = $now }
        $seen = @{}; $tw = @{}
        $table = [ZcTcpTable]::Read()
        # входящие соединения (к нашему слушающему порту) не интересны — смотрим только, куда подключаемся мы
        $listen = @{}
        foreach ($r in $table) { if ($r.State -eq 2) { $listen[$r.LocalPort] = 1 } }
        foreach ($r in $table) {
            if ($r.State -eq 2 -or $listen.ContainsKey($r.LocalPort)) { continue }
            if ((IsLocalIp $r.Remote) -and -not $CTX.loopback) { continue }
            $tuple = "$($r.LocalPort)|$($r.Remote)|$($r.RemotePort)"
            if ($r.State -eq 11 -or $r.Pid -eq 0) { $tw[$tuple] = 1; continue }
            $key = "$($r.Pid)|$tuple"
            $seen[$key] = 1
            if ($ignore.ContainsKey($key)) { continue }
            $c = $conns[$key]
            if (-not $c) {
                $c = @{ proc = (ProcName $r.Pid); lport = $r.LocalPort; remote = $r.Remote; rport = $r.RemotePort; first = $now; syn = ($r.State -eq 3); est = $null; fin = $false }
                $conns[$key] = $c
            }
            if ($r.State -ge 5 -and $r.State -le 10 -and -not $c.est) { $c.est = $now }
            if ($r.State -ge 6 -and $r.State -le 10) { $c.fin = $true }
        }
        foreach ($key in @($conns.Keys)) {
            if ($seen.ContainsKey($key)) { continue }
            $c = $conns[$key]; $conns.Remove($key)
            $closedByUs = $tw.ContainsKey("$($c.lport)|$($c.remote)|$($c.rport)")
            if ($c.est -or $closedByUs) {
                if (-not $c.est) { $c.est = $now }
                $alive = ($now - $c.est).TotalSeconds
                if (-not $closedByUs -and -not $c.fin -and $alive -lt 2) { Finish $c 'drop' $now }
                elseif ($c.syn -and ($c.est - $c.first).TotalSeconds -ge 3) { Finish $c 'slow' $now }
                else { Finish $c 'ok' $now }
            } else {
                Finish $c $(if (($now - $c.first).TotalSeconds -ge 1) { 'noanswer' } else { 'reset' }) $now
            }
        }
        # то, что прямо сейчас висит в ожидании ответа дольше 2 с — показываем вживую
        $MON.pending = @($conns.Values | Where-Object { -not $_.est -and $_.syn -and ($now - $_.first).TotalSeconds -ge 2 } |
                         ForEach-Object { "$($_.proc) -> $($_.remote):$($_.rport)" })
        if ($MON.dirty -or $MON.ver -eq 0) { Publish }
        if (($now - $start).TotalMinutes -ge 15) { $MON.autostop = $true; break }
    } catch { $MON.err = $_.Exception.Message }
    Start-Sleep -Milliseconds 400
}

# остановка: открытые соединения считаем удачными, а висящие без ответа — неудачными
$now = Get-Date
foreach ($c in @($conns.Values)) {
    if ($c.est) { Finish $c $(if ($c.syn -and ($c.est - $c.first).TotalSeconds -ge 3) { 'slow' } else { 'ok' }) $now }
    elseif ($c.syn -and ($now - $c.first).TotalSeconds -ge 2) { Finish $c 'noanswer' $now }
}
$MON.pending = @()
Publish
$MON.ended = $now
$MON.running = $false
'@

$script:ConnStatusText = @{ ok = 'подключилось'; slow = 'подключилось медленно'; noanswer = 'нет ответа'; reset = 'сброшено сразу'; drop = 'оборвалось сразу' }
$script:MonState = $null
$script:MonPs = $null; $script:MonHandle = $null
$script:MonShownVer = -1

function Get-ConnLevel($a) {
    $bad = [int]$a.noanswer + [int]$a.reset + [int]$a.drop
    if ([int]$a.ok -eq 0 -and $bad -gt 0) { return 2 }
    if ($bad -gt 0 -or [int]$a.slow -gt 0) { return 1 }
    return 0
}

function Get-ConnTarget($a) {
    if ($a.dom) { return "$($a.dom):$($a.rport)  ($($a.remote))" }
    return "$($a.remote):$($a.rport)"
}

function Get-ConnBreakdown($a) {
    $parts = @("подключилось $($a.ok)")
    if ([int]$a.slow)     { $parts += "из них медленно $($a.slow)" }
    if ([int]$a.noanswer) { $parts += "нет ответа $($a.noanswer)" }
    if ([int]$a.reset)    { $parts += "сброшено сразу $($a.reset)" }
    if ([int]$a.drop)     { $parts += "оборвалось сразу $($a.drop)" }
    return "попыток $($a.n): " + ($parts -join ', ')
}

function Get-ConnSorted {
    if (-not $script:MonState) { return @() }
    return @(@($script:MonState.snap) | Sort-Object @{ Expression = { Get-ConnLevel $_ }; Descending = $true },
                                                   @{ Expression = { $_.last }; Descending = $true })
}

function Format-Duration([timespan]$d) {
    if ($d.TotalHours -ge 1) { return '{0}:{1:00}:{2:00}' -f [int][math]::Floor($d.TotalHours), $d.Minutes, $d.Seconds }
    return '{0:00}:{1:00}' -f [int][math]::Floor($d.TotalMinutes), $d.Seconds
}

function Update-ConnStatus {
    $m = $script:MonState
    if (-not $m) { $ui.TxtConnStatus.Text = 'Запись не идёт'; return }
    $end = if ($m.ended) { $m.ended } else { Get-Date }
    $snap = @($m.snap)
    $badN = @($snap | Where-Object { (Get-ConnLevel $_) -eq 2 }).Count
    $head = if ($m.running -or -not $m.ended) { 'Запись идёт' } else { 'Записано' }
    $txt = "$head · $(Format-Duration ($end - $m.started)) · соединений $($m.total) · адресов $($snap.Count) · не подключается $badN"
    $pend = @($m.pending)
    if ($pend.Count) { $txt += " · ждут ответа: " + ($pend[0..([math]::Min(1, $pend.Count - 1))] -join ', ') }
    if ($m.err) { $txt += " · ошибка: $($m.err)" }
    $ui.TxtConnStatus.Text = $txt
    $ui.TxtConnStatus.Foreground = $(if ($badN -gt 0) { $BrAmber } else { $BrGrayTx })
}

function Render-ConnList {
    $ui.ConnList.Children.Clear()
    $all = Get-ConnSorted
    $items = if ($ui.TglConnBad.IsChecked) { @($all | Where-Object { (Get-ConnLevel $_) -gt 0 }) } else { $all }
    $hasData = $all.Count -gt 0
    $ui.BtnConnCopy.IsEnabled = $hasData
    $ui.BtnConnSave.IsEnabled = $hasData
    if (-not $items.Count) {
        $hint = New-Object System.Windows.Controls.TextBlock
        $hint.Text = if (-not $script:MonState) { 'Здесь появятся адреса, к которым подключались программы во время записи.' }
                     elseif ($hasData) { 'Проблемных адресов нет — всё, к чему подключались, ответило.' }
                     else { 'Пока ни одного нового соединения. Открой то, что не работает, — строки появятся здесь.' }
        $hint.FontSize = 12.5; $hint.Foreground = $BrGrayTx; $hint.TextWrapping = 'Wrap'
        $hint.Margin = New-Object System.Windows.Thickness 12,6,12,6
        $ui.ConnList.Children.Add($hint) | Out-Null
        return
    }
    $max = 200
    foreach ($a in @($items | Select-Object -First $max)) {
        $lvl = Get-ConnLevel $a
        $row = New-Object System.Windows.Controls.Grid
        $row.Margin = New-Object System.Windows.Thickness 6,4,6,4
        foreach ($w in 'Auto', '*', 'Auto', 'Auto') { $cd = New-Object System.Windows.Controls.ColumnDefinition; $cd.Width = $w; $row.ColumnDefinitions.Add($cd) }

        $dot = New-Object System.Windows.Shapes.Ellipse
        $dot.Width = 7; $dot.Height = 7; $dot.VerticalAlignment = 'Center'
        $dot.Margin = New-Object System.Windows.Thickness 6,0,0,0
        $dot.Fill = switch ($lvl) { 2 { $BrRed } 1 { $BrAmber } default { $BrGreen } }
        [System.Windows.Controls.Grid]::SetColumn($dot, 0)

        $txt = New-Object System.Windows.Controls.TextBlock
        $txt.FontFamily = New-Object System.Windows.Media.FontFamily 'Consolas'
        $txt.FontSize = 12.5; $txt.VerticalAlignment = 'Center'; $txt.TextTrimming = 'CharacterEllipsis'
        $txt.Margin = New-Object System.Windows.Thickness 12,0,10,0
        $r1 = New-Object System.Windows.Documents.Run ([string]$a.proc); $r1.Foreground = $BrGrayTx
        $r2 = New-Object System.Windows.Documents.Run ('  →  ' + (Get-ConnTarget $a)); $r2.Foreground = $BrBody
        $txt.Inlines.Add($r1); $txt.Inlines.Add($r2)
        $txt.ToolTip = "$($a.proc) → $(Get-ConnTarget $a)`n$(Get-ConnBreakdown $a)"
        [System.Windows.Controls.Grid]::SetColumn($txt, 1)

        $bad = [int]$a.noanswer + [int]$a.reset + [int]$a.drop
        $st = New-Object System.Windows.Controls.TextBlock
        $st.FontSize = 12.5; $st.FontWeight = 'Medium'; $st.VerticalAlignment = 'Center'
        $st.Margin = New-Object System.Windows.Thickness 0,0,12,0
        switch ($lvl) {
            2 {
                $why = if ([int]$a.noanswer -ge [int]$a.reset -and [int]$a.noanswer -ge [int]$a.drop) { 'нет ответа' }
                       elseif ([int]$a.drop -ge [int]$a.reset) { 'обрывается' } else { 'сброс' }
                $st.Text = "не подключается · $why · $bad из $($a.n)"; $st.Foreground = $BrRedTx
            }
            1 {
                $st.Text = if ($bad) { "с ошибками · $bad из $($a.n)" } else { "медленно · $($a.slow) из $($a.n)" }
                $st.Foreground = $BrAmber
            }
            default { $st.Text = "ок · $($a.n)"; $st.Foreground = $BrGreenTx }
        }
        $st.ToolTip = Get-ConnBreakdown $a
        [System.Windows.Controls.Grid]::SetColumn($st, 2)

        $tm = New-Object System.Windows.Controls.TextBlock
        $tm.Text = ([datetime]$a.last).ToString('HH:mm:ss')
        $tm.FontFamily = New-Object System.Windows.Media.FontFamily 'Consolas'
        $tm.FontSize = 11.5; $tm.Foreground = $BrGray; $tm.VerticalAlignment = 'Center'
        $tm.Margin = New-Object System.Windows.Thickness 0,0,6,0
        [System.Windows.Controls.Grid]::SetColumn($tm, 3)

        foreach ($el in $dot, $txt, $st, $tm) { $row.Children.Add($el) | Out-Null }
        $ui.ConnList.Children.Add($row) | Out-Null
    }
    if ($items.Count -gt $max) {
        $more = New-Object System.Windows.Controls.TextBlock
        $more.Text = "…и ещё $($items.Count - $max). Полный список — в файле («Сохранить в файл»)."
        $more.FontSize = 12; $more.Foreground = $BrGrayTx
        $more.Margin = New-Object System.Windows.Thickness 12,8,12,4
        $ui.ConnList.Children.Add($more) | Out-Null
    }
}

# Текст для файла / буфера обмена. $timeline — добавить хронологию всех соединений
function Get-ConnReportText([bool]$timeline) {
    $m = $script:MonState
    $sb = New-Object System.Text.StringBuilder
    $end = if ($m.ended) { $m.ended } else { Get-Date }
    [void]$sb.AppendLine("=== Zapret Control $script:AppVersion — журнал соединений ===")
    [void]$sb.AppendLine("Запись: $($m.started.ToString('yyyy-MM-dd HH:mm:ss')) – $($end.ToString('HH:mm:ss')) ($(Format-Duration ($end - $m.started)))$(if ($m.autostop) { ', остановлена автоматически через 15 минут' })")
    [void]$sb.AppendLine("Во время записи: zapret $($m.ctx.zapret) · стратегия: $($m.ctx.strategy) · FACEIT: $($m.ctx.faceit) · Lineage 2: $($m.ctx.lineage) · не трогать порты: $($m.ctx.exclude)")
    [void]$sb.AppendLine("Соединений: $($m.total) · адресов: $(@($m.snap).Count)")
    [void]$sb.AppendLine('Видны только TCP-соединения: голос Discord и игры на UDP так не отследить.')
    $all = Get-ConnSorted
    foreach ($sec in @(@{ t = 'Не подключается'; l = 2 }, @{ t = 'С ошибками'; l = 1 }, @{ t = 'Без проблем'; l = 0 })) {
        $list = @($all | Where-Object { (Get-ConnLevel $_) -eq $sec.l })
        if (-not $list.Count) { continue }
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine("--- $($sec.t) ($($list.Count)) ---")
        foreach ($a in $list) {
            [void]$sb.AppendLine(("{0,-22} -> {1}" -f $a.proc, (Get-ConnTarget $a)))
            [void]$sb.AppendLine("    $(Get-ConnBreakdown $a) · последняя попытка $(([datetime]$a.last).ToString('HH:mm:ss'))")
        }
    }
    if ($timeline) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('--- Все соединения по времени ---')
        foreach ($e in @($m.events.ToArray() | Sort-Object { $_.t })) {
            $tgt = if ($e.dom) { "$($e.dom):$($e.rport) ($($e.remote))" } else { "$($e.remote):$($e.rport)" }
            [void]$sb.AppendLine(("{0}  {1,-22} {2,-26} {3}  ({4} с)" -f ([datetime]$e.t).ToString('HH:mm:ss.fff'), $e.proc, $script:ConnStatusText[$e.st], $tgt, $e.dur))
        }
    }
    return $sb.ToString()
}

function Start-ConnMonitor {
    if ($script:MonPs) { return }
    $svc = Get-Service -Name zapret -ErrorAction SilentlyContinue
    $state = [hashtable]::Synchronized(@{
        stop = $false; running = $false; snap = @(); ver = 0; total = 0; dirty = $false; pending = @()
        events = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
        started = (Get-Date); ended = $null; autostop = $false; err = ''
        ctx = @{
            zapret   = $(if (Get-Process -Name winws -ErrorAction SilentlyContinue) { 'работал' } elseif ($svc) { "НЕ работал (служба: $($svc.Status))" } else { 'НЕ работал (служба не установлена)' })
            strategy = $(if (Get-CurrentStrategy) { Get-CurrentStrategy } else { '—' })
            faceit   = $(if (Test-Faceit) { 'вкл' } else { 'выкл' })
            lineage  = (Get-LineageModeText)
            exclude  = (Get-ExcludeText)
        }
    })
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('MON', $state)
    $rs.SessionStateProxy.SetVariable('CTX', @{ typeSrc = $script:ConnTypeSrc; loopback = [bool]$script:ConnLoopback })
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($script:ConnMonBody)
    $script:MonState = $state
    $script:MonPs = $ps
    $script:MonHandle = $ps.BeginInvoke()
    $script:MonShownVer = -1
    $ui.BtnConnStart.Content = 'Остановить'
    $ui.BtnConnStart.Style = $win.FindResource('DangerSolid')
    Log 'Журнал соединений: запись началась'
    Update-ConnStatus
    Render-ConnList
}

function Stop-ConnMonitor { if ($script:MonState) { $script:MonState.stop = $true } }

# Вызывается таймером: обновляет экран и замечает, что фоновая запись закончилась
function Poll-ConnMonitor {
    if (-not $script:MonState) { return }
    if ($script:MonPs -or $script:MonState.running) { Update-ConnStatus }
    if ($script:MonState.ver -ne $script:MonShownVer) {
        $script:MonShownVer = $script:MonState.ver
        Render-ConnList
    }
    if ($script:MonHandle -and $script:MonHandle.IsCompleted) {
        try { [void]$script:MonPs.EndInvoke($script:MonHandle) } catch { Log "ОШИБКА журнала соединений: $($_.Exception.Message)" }
        $ps = $script:MonPs
        $script:MonPs = $null; $script:MonHandle = $null
        try { $ps.Runspace.Close(); $ps.Dispose() } catch {}
        if (-not $script:MonState.ended) { $script:MonState.ended = Get-Date }
        $ui.BtnConnStart.Content = 'Начать запись'
        $ui.BtnConnStart.Style = $win.FindResource('Accent')
        $ui.BtnConnStart.IsEnabled = $true
        Update-ConnStatus
        Render-ConnList
        $snap = @($script:MonState.snap)
        $badN = @($snap | Where-Object { (Get-ConnLevel $_) -eq 2 }).Count
        Log "Журнал соединений: запись остановлена$(if ($script:MonState.autostop) { ' (прошло 15 минут)' }) — соединений $($script:MonState.total), адресов $($snap.Count), не подключается $badN"
    }
}

$ui.BtnConnStart.Add_Click({
    if ($script:MonPs) { Stop-ConnMonitor; $ui.BtnConnStart.Content = 'Останавливаю...'; $ui.BtnConnStart.IsEnabled = $false; return }
    Start-ConnMonitor
})
$ui.TglConnBad.Add_Click({ Render-ConnList })

$ui.BtnConnCopy.Add_Click({
    if (-not $script:MonState) { return }
    try {
        Set-Clipboard -Value (Get-ConnReportText $false)
        Log 'Журнал соединений скопирован в буфер обмена'
        Show-Info 'Скопировано' 'Сводка по адресам в буфере обмена — вставь её в сообщение (Ctrl+V). Полный журнал по времени — кнопка «Сохранить в файл».'
    } catch { Log "Не удалось скопировать: $($_.Exception.Message)" }
})

$ui.BtnConnSave.Add_Click({
    if (-not $script:MonState) { return }
    $name = 'connections-' + $script:MonState.started.ToString('yyyyMMdd-HHmmss') + '.txt'
    $path = Join-Path $script:LogDir $name
    try {
        [IO.File]::WriteAllText($path, (Get-ConnReportText $true), (New-Object System.Text.UTF8Encoding($true)))
        Log "Журнал соединений сохранён: $path"
        Start-Process explorer.exe "/select,`"$path`""
    } catch {
        Log "Не удалось сохранить журнал: $($_.Exception.Message)"
        Show-Info 'Не удалось сохранить' $_.Exception.Message
    }
})

# ---------- Таймеры ----------
$statusTimer = New-Object System.Windows.Threading.DispatcherTimer
$statusTimer.Interval = [TimeSpan]::FromSeconds(3)
$statusTimer.Add_Tick({ Update-Status })

$monTimer = New-Object System.Windows.Threading.DispatcherTimer
$monTimer.Interval = [TimeSpan]::FromMilliseconds(700)
$monTimer.Add_Tick({ Poll-ConnMonitor })

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
    if ($script:QHandle -and $script:QHandle.IsCompleted) {
        $result = $null
        try { $result = $script:QPs.EndInvoke($script:QHandle) }
        catch { Log "ОШИБКА фоновой проверки: $($_.Exception.Message)" }
        $ps = $script:QPs; $done = $script:QOnDone
        $script:QPs = $null; $script:QHandle = $null; $script:QOnDone = $null
        try { $ps.Runspace.Close(); $ps.Dispose() } catch {}
        if ($done) {
            try { & $done $result } catch { Log "ОШИБКА обработки результата: $($_.Exception.Message)" }
        }
    }
})

# Положение окна: восстанавливаем, только если оно целиком видно на текущих мониторах
function Restore-WindowPlacement {
    $s = Get-AppSettings
    if (-not $s -or -not $s.w -or -not $s.h) { return }
    try {
        $vx = [System.Windows.SystemParameters]::VirtualScreenLeft;  $vy = [System.Windows.SystemParameters]::VirtualScreenTop
        $vw = [System.Windows.SystemParameters]::VirtualScreenWidth; $vh = [System.Windows.SystemParameters]::VirtualScreenHeight
        $w = [double]$s.w; $h = [double]$s.h; $x = [double]$s.x; $y = [double]$s.y
        if ($w -lt $win.MinWidth -or $h -lt $win.MinHeight) { return }
        if ($x -lt $vx -or $y -lt $vy -or ($x + $w) -gt ($vx + $vw) -or ($y + $h) -gt ($vy + $vh)) { return }
        $win.WindowStartupLocation = 'Manual'
        $win.Left = $x; $win.Top = $y; $win.Width = $w; $win.Height = $h
    } catch {}
}

# Не даём закрыть окно посреди установки службы — иначе она останется недоделанной
$win.Add_Closing({
    param($sender, $e)
    if ($script:BgPs) {
        $e.Cancel = $true
        Show-Info 'Идёт операция' 'Дождись окончания текущей операции — прерывать установку службы на середине нельзя. Долгие операции можно остановить кнопкой «Отменить».'
        return
    }
    if ($script:BgCancel) { $script:BgCancel.stop = $true }
    Stop-ConnMonitor
    if ($win.WindowState -eq 'Normal') {
        Save-AppSettings @{ x = [int]$win.Left; y = [int]$win.Top; w = [int]$win.ActualWidth; h = [int]$win.ActualHeight }
    }
})

# ---------- Start ----------
Update-Status
$ui.TxtVerLocal.Text = "zapret: $(Get-LocalVersion)"
Log "Zapret Control $script:AppVersion — управляю папкой: $script:Root"
Restore-WindowPlacement
$statusTimer.Start()
$pollTimer.Start()
$monTimer.Start()
Render-ConnList

# Тихая проверка версий через пару секунд после старта — если включена в параметрах
if (Test-Path (Join-Path $script:Utils 'check_updates.enabled')) {
    $startupTimer = New-Object System.Windows.Threading.DispatcherTimer
    $startupTimer.Interval = [TimeSpan]::FromSeconds(2)
    $startupTimer.Add_Tick({ $startupTimer.Stop(); Start-UpdateCheck $true })
    $startupTimer.Start()
}

[void]$win.ShowDialog()

$statusTimer.Stop()
$pollTimer.Stop()
$monTimer.Stop()
# фоновая запись соединений выходит из цикла за ~0,4 с после флага stop
if ($script:MonPs) {
    try { [void]$script:MonHandle.AsyncWaitHandle.WaitOne(2000); $script:MonPs.Runspace.Close(); $script:MonPs.Dispose() } catch {}
}
if ($script:AppMutex) { try { $script:AppMutex.ReleaseMutex() } catch {} }

# Перезапуск после самообновления — уже после того, как отпустили мьютекс
if ($script:RestartPath) {
    try { Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script:RestartPath`"" } catch {}
}
