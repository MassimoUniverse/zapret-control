# ============================================================
#  L2 Helper — Lineage 2 для Zapret Control
#  Отдельная программа: службу и настройки Zapret Control не трогает.
#  Смотрит, куда подключается клиент Линейки (любой проект), и вписывает
#  IP серверов в lists\ipset-exclude-user.txt — zapret перечитывает список
#  на лету и перестаёт вмешиваться в эти соединения (в т.ч. FACEIT MODE).
#  Исключения остаются в файле — после перезагрузки ничего искать не нужно.
# ============================================================
param(
    [switch]$TestUI,
    [string]$RootOverride
)

$ErrorActionPreference = 'Stop'
$script:Version = '1.0.0'
$script:AppDir = if ($PSScriptRoot) { $PSScriptRoot } else { [AppDomain]::CurrentDomain.BaseDirectory.TrimEnd('\') }

# ---------- Права администратора ----------
# Нужны, чтобы видеть путь к клиенту игры (античит запускает его с повышенными правами)
# и писать в папку zapret.
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $TestUI) {
    $extra = if ($RootOverride) { " -RootOverride `"$RootOverride`"" } else { '' }
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`"$extra"
    exit
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

if (-not $TestUI) {
    $created = $false
    $script:Mutex = New-Object System.Threading.Mutex($true, 'Global\ZapretL2Helper', [ref]$created)
    if (-not $created) {
        [System.Windows.MessageBox]::Show('L2 Helper уже запущен — окно должно быть на панели задач.', 'L2 Helper', 'OK', 'Information') | Out-Null
        exit
    }
}

# ---------- Где zapret ----------
# Так же, как ищет Zapret Control: сначала папка, из которой запущена служба
function Find-ZapretRoot {
    if ($RootOverride) { return $RootOverride }
    $candidates = @()
    try {
        $img = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\zapret' -ErrorAction Stop).ImagePath
        if ($img -match '"?([^"]*?winws\.exe)') { $candidates += (Split-Path (Split-Path $Matches[1] -Parent) -Parent) }
    } catch {}
    $bases = @($script:AppDir, (Join-Path $script:AppDir 'Zapret Control'), (Split-Path -Parent $script:AppDir), 'C:\Zapret Control', 'C:\')
    $candidates += $script:AppDir
    foreach ($b in $bases) {
        try {
            Get-ChildItem -LiteralPath $b -Directory -Filter 'zapret-discord-youtube*' -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending | ForEach-Object { $candidates += $_.FullName }
        } catch {}
    }
    foreach ($c in $candidates) { if ($c -and (Test-Path (Join-Path $c 'bin\winws.exe'))) { return $c } }
    return $null
}

$script:Root = Find-ZapretRoot
if (-not $script:Root) {
    if ($TestUI) { Write-Host 'Zapret folder not found'; exit 1 }
    [System.Windows.MessageBox]::Show(
        "Не нашёл zapret на этом компьютере.`n`nСначала поставь Zapret Control, выбери стратегию и нажми «Установить службу» — потом запусти L2 Helper.",
        'L2 Helper', 'OK', 'Warning') | Out-Null
    exit 1
}
$script:Root = (Resolve-Path $script:Root).Path
$script:ExclFile = Join-Path $script:Root 'lists\ipset-exclude-user.txt'

# ---------- Своё хранилище ----------
# Не в папке zapret и не рядом с программой: переживёт обновление zapret и переезд папки helper'а.
$script:DataDir = Join-Path $env:LOCALAPPDATA 'L2Helper'
if (-not (Test-Path $script:DataDir)) { New-Item -ItemType Directory -Force -Path $script:DataDir | Out-Null }
$script:StateFile = Join-Path $script:DataDir 'servers.json'
$script:LogFile   = Join-Path $script:DataDir 'l2helper.log'

function Write-FileLog([string]$m) {
    try { [IO.File]::AppendAllText($script:LogFile, ('{0}  {1}{2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m, [Environment]::NewLine), [Text.Encoding]::UTF8) } catch {}
}

# servers: ip -> @{ ip; ports (string, через запятую); project; added }
function Load-State {
    $s = [ordered]@{}
    try {
        if (Test-Path $script:StateFile) {
            $j = [IO.File]::ReadAllText($script:StateFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
            foreach ($x in @($j.servers)) {
                if ($x -and $x.ip) { $s[[string]$x.ip] = @{ ip = [string]$x.ip; ports = [string]$x.ports; project = [string]$x.project; added = [string]$x.added } }
            }
        }
    } catch { Write-FileLog "не прочитал servers.json: $($_.Exception.Message)" }
    return $s
}
function Save-State {
    $list = @(foreach ($k in $script:Servers.Keys) { $v = $script:Servers[$k]; [ordered]@{ ip = $v.ip; ports = $v.ports; project = $v.project; added = $v.added } })
    $json = ConvertTo-Json -Depth 4 -InputObject ([ordered]@{ servers = $list })
    [IO.File]::WriteAllText($script:StateFile, $json, (New-Object Text.UTF8Encoding $false))
}

# ---------- Список исключений zapret ----------
function Read-ExclLines {
    if (-not (Test-Path -LiteralPath $script:ExclFile)) { return @() }
    return @([IO.File]::ReadAllLines($script:ExclFile) | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
function Test-InExcl([string[]]$lines, [string]$ip) { return ($lines -contains $ip -or $lines -contains "$ip/32") }

# Дописываем недостающие IP в конец файла, остальное содержимое не трогаем
function Add-ToExcl([string[]]$ips) {
    $lines = Read-ExclLines
    $need = @($ips | Where-Object { -not (Test-InExcl $lines $_) })
    if (-not $need.Count) { return 0 }
    $prefix = ''
    if (Test-Path -LiteralPath $script:ExclFile) {
        $raw = [IO.File]::ReadAllText($script:ExclFile)
        if ($raw.Length -and -not $raw.EndsWith("`n")) { $prefix = "`r`n" }
    }
    [IO.File]::AppendAllText($script:ExclFile, $prefix + (($need | ForEach-Object { "$_`r`n" }) -join ''), [Text.Encoding]::ASCII)
    return $need.Count
}
function Remove-FromExcl([string[]]$ips) {
    if (-not (Test-Path -LiteralPath $script:ExclFile)) { return }
    $drop = @{}; foreach ($ip in $ips) { $drop[$ip] = 1; $drop["$ip/32"] = 1 }
    $keep = @([IO.File]::ReadAllLines($script:ExclFile) | Where-Object { -not $drop.ContainsKey($_.Trim()) })
    # пустым файл оставлять нельзя — zapret ждёт хотя бы одну строку; заглушка та же, что у Zapret Control
    if (-not @($keep | Where-Object { $_.Trim() }).Count) { $keep = @('203.0.113.113/32') }
    [IO.File]::WriteAllText($script:ExclFile, (($keep -join "`r`n") + "`r`n"), [Text.Encoding]::ASCII)
}

# ---------- Кто клиент Линейки ----------
# Проекты называют клиент как угодно, но папка system у всех от одного движка:
# NWindow.dll (интерфейс L2), l2.ini, либо Engine.dll + Core.dll. Плюс запасной вариант по имени.
$script:NameRx = '^(?i)(l2|l2\.bin|l2\.exe\.bin|lineage.*|la2.*)$'
$script:PidCache = @{}
function Get-L2Info([int]$procId) {
    if ($script:PidCache.ContainsKey($procId)) { return $script:PidCache[$procId] }
    $info = $null
    try {
        $p = [System.Diagnostics.Process]::GetProcessById($procId)
        $name = $p.ProcessName
        $path = $null
        try { $path = $p.MainModule.FileName } catch {}
        $isL2 = $false; $project = ''
        if ($path) {
            $dir = Split-Path $path -Parent
            if ((Test-Path (Join-Path $dir 'NWindow.dll')) -or (Test-Path (Join-Path $dir 'l2.ini')) -or
                ((Test-Path (Join-Path $dir 'Engine.dll')) -and (Test-Path (Join-Path $dir 'Core.dll')))) { $isL2 = $true }
            $proj = Split-Path $dir -Leaf
            if ($proj -match '^(?i)system') { $proj = Split-Path (Split-Path $dir -Parent) -Leaf }
            $project = $proj
        }
        if (-not $isL2 -and $name -match $script:NameRx) { $isL2 = $true }
        if ($isL2) { $info = @{ name = "$name.exe"; project = $project; path = $path } }
    } catch {}
    $script:PidCache[$procId] = $info
    return $info
}

function Test-PublicIp([string]$ip) {
    if (-not $ip -or $ip -eq '0.0.0.0' -or $ip -eq '::' -or $ip -eq '::1') { return $false }
    if ($ip -match '^(127|10|0)\.' -or $ip -match '^192\.168\.' -or $ip -match '^169\.254\.' -or $ip -match '^172\.(1[6-9]|2\d|3[01])\.' -or $ip -match '^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.') { return $false }
    if ($ip -match '^(?i)(fe80|fc|fd)') { return $false }
    return $true
}

# ---------- Таблица TCP-соединений ----------
$script:TcpSrc = @'
using System; using System.Collections.Generic; using System.Net; using System.Runtime.InteropServices;
public static class L2hTcpTable {
    [DllImport("iphlpapi.dll")]
    static extern uint GetExtendedTcpTable(IntPtr table, ref int size, bool order, int af, int tableClass, uint reserved);
    public class Row { public int State; public string Remote; public int RemotePort; public int Pid; }
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
                        row.Remote = new IPAddress((long)(uint)Marshal.ReadInt32(p, 12)).ToString();
                        row.RemotePort = Port(Marshal.ReadInt32(p, 16));
                        row.Pid = Marshal.ReadInt32(p, 20);
                    } else {
                        IntPtr p = IntPtr.Add(buf, 4 + i * 56);
                        byte[] a = new byte[16]; Marshal.Copy(IntPtr.Add(p, 24), a, 0, 16);
                        var ip = new IPAddress(a);
                        row.Remote = ip.IsIPv4MappedToIPv6 ? ip.MapToIPv4().ToString() : ip.ToString();
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
if (-not ('L2hTcpTable' -as [type])) { Add-Type -TypeDefinition $script:TcpSrc -Language CSharp }

# ---------- Окно ----------
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="L2 Helper" Width="760" Height="700" MinWidth="640" MinHeight="560"
        Background="#0A0F0C" FontFamily="Segoe UI" WindowStartupLocation="CenterScreen">
  <Window.Resources>
    <SolidColorBrush x:Key="TextHi"    Color="#EAF2EC"/>
    <SolidColorBrush x:Key="TextMid"   Color="#8CA396"/>
    <SolidColorBrush x:Key="TextLow"   Color="#5A6E60"/>
    <SolidColorBrush x:Key="TextBody"  Color="#B9CBBF"/>
    <SolidColorBrush x:Key="Green"     Color="#2FBF71"/>
    <SolidColorBrush x:Key="GreenHi"   Color="#34D399"/>
    <SolidColorBrush x:Key="OnGreen"   Color="#06120B"/>
    <SolidColorBrush x:Key="CardBg"    Color="#101712"/>
    <SolidColorBrush x:Key="WellBg"    Color="#07100A"/>
    <SolidColorBrush x:Key="Line"      Color="#1E2B22"/>
    <SolidColorBrush x:Key="LineHover" Color="#2A3B30"/>

    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource CardBg}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="14"/>
      <Setter Property="Padding" Value="20,18"/>
      <Setter Property="Margin" Value="0,0,0,14"/>
    </Style>
    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource TextHi}"/>
    </Style>
    <Style x:Key="Muted" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource TextMid}"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="FontSize" Value="13"/>
    </Style>
    <Style x:Key="Kicker" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource TextLow}"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style TargetType="ToolTip">
      <Setter Property="Background" Value="#131B15"/>
      <Setter Property="Foreground" Value="{StaticResource TextBody}"/>
      <Setter Property="BorderBrush" Value="{StaticResource LineHover}"/>
    </Style>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#131B15"/>
      <Setter Property="Foreground" Value="{StaticResource TextHi}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="Padding" Value="14,8"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="13"/>
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
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="{StaticResource WellBg}"/>
      <Setter Property="Foreground" Value="{StaticResource TextHi}"/>
      <Setter Property="CaretBrush" Value="{StaticResource TextHi}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="Padding" Value="10,7"/>
      <Setter Property="FontFamily" Value="Consolas"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="9">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid Margin="22,18,22,18">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="120"/>
    </Grid.RowDefinitions>

    <StackPanel Grid.Row="0" Margin="0,0,0,16">
      <StackPanel Orientation="Horizontal">
        <Ellipse Width="12" Height="12" Fill="{StaticResource GreenHi}" VerticalAlignment="Center" Margin="0,2,10,0"/>
        <TextBlock Text="L2 Helper" FontSize="22" FontWeight="SemiBold"/>
        <TextBlock x:Name="TxtVer" Foreground="{StaticResource TextLow}" FontSize="12" VerticalAlignment="Bottom" Margin="10,0,0,4"/>
      </StackPanel>
      <TextBlock Style="{StaticResource Muted}" Margin="0,6,0,0"
                 Text="Lineage 2 вместе с zapret. Пока окно открыто, программа смотрит, к каким серверам подключается клиент Линейки — любого проекта — и убирает их из-под zapret. Связь с сервером перестаёт рваться, а YouTube, Discord и FACEIT работают как раньше."/>
    </StackPanel>

    <Border Grid.Row="1" Style="{StaticResource Card}">
      <StackPanel>
        <TextBlock Text="С О С Т О Я Н И Е" Style="{StaticResource Kicker}"/>
        <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
          <Ellipse x:Name="DotWatch" Width="10" Height="10" Fill="{StaticResource GreenHi}" VerticalAlignment="Center" Margin="0,0,10,0"/>
          <TextBlock x:Name="TxtWatch" FontSize="15" FontWeight="Medium" Text="Слежу за игрой"/>
        </StackPanel>
        <TextBlock x:Name="TxtGame" Style="{StaticResource Muted}" Margin="20,4,0,0"/>
        <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
          <Ellipse x:Name="DotZapret" Width="10" Height="10" Fill="{StaticResource GreenHi}" VerticalAlignment="Center" Margin="0,0,10,0"/>
          <TextBlock x:Name="TxtZapret" FontSize="13.5"/>
        </StackPanel>
        <TextBlock x:Name="TxtRoot" Foreground="{StaticResource TextLow}" FontFamily="Consolas" FontSize="11.5" Margin="20,4,0,0" TextTrimming="CharacterEllipsis"/>
      </StackPanel>
    </Border>

    <Border Grid.Row="2" Style="{StaticResource Card}">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <StackPanel Grid.Row="0">
          <TextBlock Text="С Е Р В Е Р Ы    В    И С К Л Ю Ч Е Н И Я Х" Style="{StaticResource Kicker}"/>
          <TextBlock Style="{StaticResource Muted}" FontSize="12.5" Margin="0,8,0,10"
                     Text="Сохраняются насовсем — после перезагрузки искать заново не нужно, программу можно даже не запускать. Если самый первый вход оборвался — просто зайди ещё раз: сервер к этому моменту уже в списке."/>
        </StackPanel>
        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
          <StackPanel x:Name="ServerList"/>
        </ScrollViewer>
        <Grid Grid.Row="2" Margin="0,12,0,0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*" MaxWidth="220"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <TextBox x:Name="TxtAddIp" Grid.Column="0" ToolTip="IP сервера, если знаешь его заранее (например, из сообщения поддержки проекта)"/>
          <Button x:Name="BtnAdd" Grid.Column="1" Content="Добавить IP" Margin="8,0,0,0"/>
          <Button x:Name="BtnClear" Grid.Column="3" Content="Убрать все"
                  ToolTip="Вернуть zapret обычное поведение для всех серверов из списка"/>
        </Grid>
      </Grid>
    </Border>

    <Border Grid.Row="3" Background="{StaticResource WellBg}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="10" Padding="12,8">
      <TextBox x:Name="TxtLog" IsReadOnly="True" BorderThickness="0" Background="Transparent" Padding="0"
               Foreground="{StaticResource TextMid}" FontSize="12" VerticalScrollBarVisibility="Auto" TextWrapping="Wrap"/>
    </Border>
  </Grid>
</Window>
'@

$win = [Windows.Markup.XamlReader]::Parse($xaml)
$ui = @{}
foreach ($n in 'TxtVer','DotWatch','TxtWatch','TxtGame','DotZapret','TxtZapret','TxtRoot','ServerList','TxtAddIp','BtnAdd','BtnClear','TxtLog') {
    $ui[$n] = $win.FindName($n)
}
if ($TestUI) {
    $missing = @($ui.GetEnumerator() | Where-Object { -not $_.Value } | ForEach-Object { $_.Key })
    if ($missing.Count) { Write-Host "MISSING: $($missing -join ', ')"; exit 1 }
    if (-not $env:L2H_TEST_KEEP) { Write-Host 'UI OK'; exit 0 }
}

function BrushOf([string]$hex) { New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($hex)) }
$BrGreen = BrushOf '#34D399'; $BrAmber = BrushOf '#D6A243'; $BrRed = BrushOf '#E5534B'; $BrGray = BrushOf '#5A6E60'
$BrMid = BrushOf '#8CA396'; $BrLow = BrushOf '#5A6E60'; $BrLine = BrushOf '#1E2B22'

function Log([string]$m) {
    $line = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $m
    if ($ui.TxtLog.Text) { $ui.TxtLog.AppendText("`r`n" + $line) } else { $ui.TxtLog.Text = $line }
    $ui.TxtLog.ScrollToEnd()
    Write-FileLog $m
}

# ---------- Список серверов в окне ----------
function Render-Servers {
    $ui.ServerList.Children.Clear()
    if (-not $script:Servers.Count) {
        $t = New-Object System.Windows.Controls.TextBlock
        $t.Text = 'Пока пусто. Запусти игру и войди на сервер — адреса появятся здесь сами.'
        $t.Foreground = $BrLow; $t.FontSize = 13; $t.Margin = '0,6,0,6'; $t.TextWrapping = 'Wrap'
        [void]$ui.ServerList.Children.Add($t)
        $ui.BtnClear.IsEnabled = $false
        return
    }
    $ui.BtnClear.IsEnabled = $true
    $lines = Read-ExclLines
    foreach ($k in @($script:Servers.Keys)) {
        $s = $script:Servers[$k]
        $row = New-Object System.Windows.Controls.Grid
        $row.Margin = '0,0,0,6'
        foreach ($w in 'Auto', '*', 'Auto') {
            $cd = New-Object System.Windows.Controls.ColumnDefinition
            $cd.Width = $(if ($w -eq '*') { New-Object System.Windows.GridLength(1, 'Star') } else { [System.Windows.GridLength]::Auto })
            $row.ColumnDefinitions.Add($cd)
        }
        $ip = New-Object System.Windows.Controls.TextBlock
        $ip.Text = $s.ip; $ip.FontFamily = 'Consolas'; $ip.FontSize = 13.5; $ip.MinWidth = 150; $ip.VerticalAlignment = 'Center'
        [System.Windows.Controls.Grid]::SetColumn($ip, 0)
        $d = New-Object System.Windows.Controls.TextBlock
        $parts = @()
        if ($s.project) { $parts += $s.project }
        if ($s.ports)   { $parts += "порт $($s.ports)" }
        if ($s.added)   { $parts += "с $($s.added)" }
        if (-not (Test-InExcl $lines $s.ip)) { $parts += 'НЕТ в списке zapret — верну при следующей проверке' }
        $d.Text = ($parts -join '  ·  '); $d.Foreground = $BrMid; $d.FontSize = 12.5; $d.VerticalAlignment = 'Center'; $d.Margin = '12,0,12,0'; $d.TextTrimming = 'CharacterEllipsis'
        [System.Windows.Controls.Grid]::SetColumn($d, 1)
        $b = New-Object System.Windows.Controls.Button
        $b.Content = 'Убрать'; $b.Padding = '12,5'; $b.Tag = $s.ip
        $b.ToolTip = 'zapret снова будет обрабатывать этот адрес как обычно'
        $b.Add_Click({ param($sender, $e) Remove-Server ([string]$sender.Tag) })
        [System.Windows.Controls.Grid]::SetColumn($b, 2)
        [void]$row.Children.Add($ip); [void]$row.Children.Add($d); [void]$row.Children.Add($b)
        [void]$ui.ServerList.Children.Add($row)
    }
}

function Add-Server([string]$ip, [int]$port, [string]$project, [string]$proc) {
    $new = -not $script:Servers.Contains($ip)
    if ($new) {
        $script:Servers[$ip] = @{ ip = $ip; ports = $(if ($port) { "$port" } else { '' }); project = $project; added = (Get-Date -Format 'dd.MM.yyyy') }
    } else {
        $s = $script:Servers[$ip]
        if ($port -and (",$($s.ports),") -notlike "*,$port,*") { $s.ports = (@(@($s.ports -split ',' | Where-Object { $_ }) + "$port") -join ',') } else { return }
        if (-not $s.project -and $project) { $s.project = $project }
    }
    try {
        $n = Add-ToExcl @($ip)
        Save-State
    } catch {
        Log "ОШИБКА: не смог записать $ip в список zapret: $($_.Exception.Message)"
        return
    }
    if ($new) {
        $who = @(); if ($proc) { $who += $proc }; if ($project) { $who += $project }
        Log ("Новый сервер: $ip" + $(if ($port) { ":$port" } else { '' }) + $(if ($who.Count) { " ($($who -join ', '))" } else { '' }) + ' — zapret больше его не трогает' + $(if ($proc) { '. Если вход сейчас оборвался — зайди ещё раз' } else { '' }))
    } else {
        Log "Сервер $ip — ещё порт $port"
    }
    Render-Servers
}

function Remove-Server([string]$ip) {
    if (-not $script:Servers.Contains($ip)) { return }
    try { Remove-FromExcl @($ip) } catch { Log "ОШИБКА: не смог убрать $ip из списка: $($_.Exception.Message)"; return }
    $script:Servers.Remove($ip)
    Save-State
    Log "Убрал $ip — zapret снова обрабатывает его как обычно"
    Render-Servers
}

# ---------- Состояние zapret и игры ----------
function Update-Status {
    $svc = Get-Service -Name zapret -ErrorAction SilentlyContinue
    $gf = Test-Path (Join-Path $script:Root 'utils\game_filter.enabled')
    if (-not $svc) {
        $ui.DotZapret.Fill = $BrAmber; $ui.TxtZapret.Text = 'Служба zapret не установлена — исключения заработают, когда поставишь её в Zapret Control'
    } elseif ($svc.Status -ne 'Running') {
        $ui.DotZapret.Fill = $BrAmber; $ui.TxtZapret.Text = "Служба zapret: $($svc.Status)"
    } elseif (-not $gf) {
        $ui.DotZapret.Fill = $BrGreen; $ui.TxtZapret.Text = 'Zapret работает, FACEIT MODE выключен — он и так почти не трогает Линейку, исключения на всякий случай'
    } else {
        $ui.DotZapret.Fill = $BrGreen; $ui.TxtZapret.Text = 'Zapret работает, FACEIT MODE включён — серверы из списка он пропускает как есть'
    }

    $alive = @()
    foreach ($k in @($script:PidCache.Keys)) {
        $v = $script:PidCache[$k]
        if (-not $v) { continue }
        try { [void][System.Diagnostics.Process]::GetProcessById([int]$k); $alive += $v } catch { $script:PidCache.Remove($k) }
    }
    if (-not $alive.Count) {
        foreach ($p in @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match $script:NameRx })) {
            $i = Get-L2Info $p.Id; if ($i) { $alive += $i }
        }
    }
    if ($alive.Count) {
        $g = $alive[0]
        $ui.TxtGame.Text = "Клиент запущен: $($g.name)" + $(if ($g.project) { " — $($g.project)" } else { '' }) + ". Новые серверы попадут в исключения сами."
        $ui.TxtGame.Foreground = $BrGreen
    } else {
        $ui.TxtGame.Text = 'Клиент Линейки пока не запущен — запускай игру, окно можно не закрывать.'
        $ui.TxtGame.Foreground = $BrMid
    }
}

# ---------- Слежение ----------
$script:SeenKeys = @{}
function Poll-Connections {
    try { $rows = [L2hTcpTable]::Read() } catch { return }
    foreach ($r in $rows) {
        if ($r.Pid -le 4 -or $r.State -lt 3 -or $r.State -gt 5) { continue }    # SYN_SENT, SYN_RCVD, ESTABLISHED
        if ($r.RemotePort -in 80, 443) { continue }                             # сайт, лаунчер, обновления
        if (-not (Test-PublicIp $r.Remote)) { continue }
        $key = "$($r.Pid)|$($r.Remote)|$($r.RemotePort)"
        if ($script:SeenKeys.ContainsKey($key)) { continue }
        $script:SeenKeys[$key] = 1
        $info = Get-L2Info $r.Pid
        if (-not $info) { continue }
        Add-Server $r.Remote $r.RemotePort $info.project $info.name
    }
    if ($script:SeenKeys.Count -gt 5000) { $script:SeenKeys.Clear() }
}

# ---------- Ручное добавление и очистка ----------
$ui.BtnAdd.Add_Click({
    $t = $ui.TxtAddIp.Text.Trim()
    $ipObj = $null
    if (-not [System.Net.IPAddress]::TryParse($t, [ref]$ipObj) -or $t -notmatch '^[0-9a-fA-F:.]+$') { Log "«$t» — не похоже на IP-адрес. Пример: 54.37.192.112"; return }
    $ip = $ipObj.ToString()
    if (-not (Test-PublicIp $ip)) { Log "$ip — локальный адрес, zapret его и так не трогает"; return }
    $ui.TxtAddIp.Text = ''
    if ($script:Servers.Contains($ip)) { Log "$ip уже в списке"; return }
    Add-Server $ip 0 'добавлен вручную' ''
})
$ui.TxtAddIp.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { $ui.BtnAdd.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) } })
$ui.BtnClear.Add_Click({
    $r = [System.Windows.MessageBox]::Show('Убрать все серверы Линейки из исключений? zapret снова будет обрабатывать их как обычно.', 'L2 Helper', 'YesNo', 'Question')
    if ($r -ne 'Yes') { return }
    $ips = @($script:Servers.Keys)
    try { Remove-FromExcl $ips } catch { Log "ОШИБКА: $($_.Exception.Message)"; return }
    $script:Servers.Clear(); Save-State
    Log "Убрал все серверы ($($ips.Count))"
    Render-Servers
})

# ---------- Старт ----------
$ui.TxtVer.Text = "v$script:Version"
$ui.TxtRoot.Text = $script:Root
$script:Servers = Load-State
try {
    $n = Add-ToExcl @($script:Servers.Keys)
    if ($n) { Log "Вернул в список zapret серверы, которых там не было: $n (например, после обновления zapret)" }
} catch { Log "ОШИБКА: нет доступа к $script:ExclFile — $($_.Exception.Message)" }
Log ("L2 Helper $script:Version — zapret: $script:Root" + $(if ($script:Servers.Count) { "; серверов в исключениях: $($script:Servers.Count)" } else { '' }))
Render-Servers
Update-Status

$pollTimer = New-Object System.Windows.Threading.DispatcherTimer
$pollTimer.Interval = [TimeSpan]::FromMilliseconds(400)
$pollTimer.Add_Tick({ Poll-Connections })
$statusTimer = New-Object System.Windows.Threading.DispatcherTimer
$statusTimer.Interval = [TimeSpan]::FromSeconds(3)
$statusTimer.Add_Tick({
    Update-Status
    # кто-то (обновление zapret, ручная правка) мог убрать наши строки — возвращаем
    try { $n = Add-ToExcl @($script:Servers.Keys); if ($n) { Log "Вернул в список zapret серверов: $n"; Render-Servers } } catch {}
})

if ($TestUI) { return }   # тестовый режим с L2H_TEST_KEEP: функции и окно загружены, таймеры не запущены

$pollTimer.Start()
$statusTimer.Start()
[void]$win.ShowDialog()
$pollTimer.Stop(); $statusTimer.Stop()
if ($script:Mutex) { try { $script:Mutex.ReleaseMutex() } catch {} }
