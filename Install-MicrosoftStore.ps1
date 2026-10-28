<#
.SYNOPSIS
    Установка (восстановление) Microsoft Store в Windows 10 / 11: LTSC, а также Home / Pro / Education / Enterprise.

.DESCRIPTION
    Способы установки, по порядку (останавливается, когда Store появился):
      1. Регистрация уже имеющихся файлов Store (AppXManifest.xml).
      2. wsreset.exe -i (Windows 11, сборка 22000+).
      3. Локальная папка с пакетами (-PackagePath).
      4. Кэш ранее скачанных пакетов (%ProgramData%\MicrosoftStore-LTSC-Installer\packages).
      5. Загрузка из сети. Источники (параметр -Source):
           StoreCdn  - ссылки на CDN Microsoft, которые выдаёт store.rg-adguard.net;
           Mirror    - JSON-манифест с наборами пакетов под версию Windows (-ManifestUrl);
           Auto      - StoreCdn, затем Mirror (на Windows 10 сборки ниже 19041 порядок обратный).

    Каждый пакет перед установкой проверяется: подпись должна принадлежать Microsoft.
    Саму подпись окончательно проверяет система развёртывания Windows.
    По умолчанию Store добавляется и в образ системы (для новых учётных записей).

    Формат манифеста Mirror (только HTTPS). Ключ - набор под версию Windows:
    Win11_24H2 (сборка 26100+), LTSC2021 (19044+), LTSC2019 (14393+):
      { "LTSC2021": { "deps": ["https://.../Microsoft.VCLibs.x64....appx", ...],
                      "store": "https://....msixbundle", "store_license": "https://....xml",
                      "StorePurchaseApp": "https://....msixbundle",
                      "StorePurchaseApp_license": "https://....xml" }, ... }
    Наборы Mirror подобраны под конкретную версию Windows, а CDN отдаёт самый свежий Store,
    который может не встать на старые сборки (LTSC 2019 / LTSB 2016).

.PARAMETER PackagePath      Папка с .appx/.msix/.appxbundle/.msixbundle.
.PARAMETER Source           Источник загрузки: Auto, StoreCdn, Mirror.
.PARAMETER ManifestUrl      HTTPS-адрес JSON-манифеста для источника Mirror.
.PARAMETER NoDownload       Не скачивать ничего из сети.
.PARAMETER ForceDownload    Игнорировать кэш и скачать пакеты заново.
.PARAMETER SkipWsreset      Пропустить wsreset -i.
.PARAMETER WsresetTimeout   Сколько секунд ждать wsreset (30-900).
.PARAMETER CurrentUserOnly  Не добавлять Store в образ системы, только текущему пользователю.

.NOTES
    Проще всего запускать двойным кликом по Install-MicrosoftStore.cmd:
    скрипт сам запросит права администратора.
    Журнал: %ProgramData%\MicrosoftStore-LTSC-Installer\install.log
#>
[CmdletBinding()]
param(
    [string]$PackagePath,
    [ValidateSet('Auto', 'StoreCdn', 'Mirror')]
    [string]$Source = 'Auto',
    [string]$ManifestUrl = 'https://files.w3k.dev/msstore/manifest.json',
    [switch]$NoDownload,
    [switch]$ForceDownload,
    [switch]$SkipWsreset,
    [ValidateRange(30, 900)]
    [int]$WsresetTimeout = 180,
    [switch]$CurrentUserOnly
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

function Wait-Key {
    if ([Environment]::UserInteractive) {
        Write-Host "`nНажмите Enter, чтобы закрыть окно..." -ForegroundColor Gray
        [void](Read-Host)
    }
}

trap {
    Write-Host "`nОШИБКА: $($_.Exception.Message)" -ForegroundColor Red
    Wait-Key
    exit 1
}

# ---------- Автоматический запрос прав администратора ----------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin -or $PSVersionTable.PSEdition -eq 'Core') {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    foreach ($k in $PSBoundParameters.Keys) {
        $v = $PSBoundParameters[$k]
        if ($v -is [switch]) { if ($v.IsPresent) { $argList += "-$k" } }
        else { $argList += "-$k"; $argList += "`"$($v.ToString().TrimEnd('\'))`"" }
    }
    Write-Host 'Запрашиваю права администратора (нажмите "Да" в окне UAC)...'
    try {
        Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
                      -ArgumentList $argList -Verb RunAs
    } catch {
        Write-Host 'Права администратора не предоставлены. Установка отменена.' -ForegroundColor Red
        Wait-Key
    }
    exit
}

# ---------- Пути и журнал ----------
$WorkRoot = Join-Path $env:ProgramData 'MicrosoftStore-LTSC-Installer'
$CdnDir    = Join-Path $WorkRoot 'packages\StoreCdn'
$MirrorRoot = Join-Path $WorkRoot 'packages\Mirror'
$LogFile   = Join-Path $WorkRoot 'install.log'
New-Item -Path $CdnDir -ItemType Directory -Force | Out-Null

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    $line  = '[{0}][{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    $color = switch ($Level) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'ERROR' { 'Red' } default { 'Cyan' } }
    Write-Host $line -ForegroundColor $color
    try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 } catch {}
}

# ---------- Проверка параметров ----------
if (([Uri]$ManifestUrl).Scheme -ne 'https') { throw 'Манифест должен загружаться по HTTPS.' }

# ---------- Система ----------
$rawArch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
$Arch = switch ($rawArch.ToUpperInvariant()) {
    'AMD64' { 'x64' } 'ARM64' { 'arm64' } 'X86' { 'x86' }
    default { throw "Не удалось определить архитектуру Windows: '$rawArch'." }
}
$build = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber
$VersionKey = if     ($build -ge 26100) { 'Win11_24H2' }
              elseif ($build -ge 19044) { 'LTSC2021' }
              elseif ($build -ge 14393) { 'LTSC2019' }
              else                      { $null }
Write-Log "Windows build $build, архитектура $Arch, набор Mirror: $VersionKey, PowerShell $($PSVersionTable.PSVersion)"

$MainIds = 'Microsoft.WindowsStore', 'Microsoft.StorePurchaseApp',
           'Microsoft.XboxIdentityProvider', 'Microsoft.DesktopAppInstaller'

function Test-StoreInstalled {
    $null -ne (Get-AppxPackage -Name 'Microsoft.WindowsStore' -ErrorAction SilentlyContinue | Select-Object -First 1)
}

function Wait-Store([int]$TimeoutSec) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        if (Test-StoreInstalled) { return $true }
        Start-Sleep -Seconds 5
    }
    return $false
}

function Finish {
    Write-Log 'Microsoft Store установлен.' 'OK'
    Write-Host 'Откройте его через меню Пуск или Win+R -> ms-windows-store:'
    Write-Host 'Если не запускается сразу, перезагрузите ПК и войдите заново.'
    Wait-Key
    exit 0
}

# ---------- Работа с пакетами ----------
function Get-PkgInfo([string]$FileName) {
    if ($FileName -match '^(?<id>.+?)_(?<ver>\d+(?:\.\d+)+)_(?<arch>[^_]+)_[^_]*_(?<pub>[^.]+)\.(?<ext>\w+)$') {
        [pscustomobject]@{ Id = $Matches.id; Ver = [version]$Matches.ver; Arch = $Matches.arch.ToLower(); File = $FileName }
    }
}

function Select-Latest($infos) {
    @($infos) | Where-Object { $_ -and ($_.Arch -eq $Arch -or $_.Arch -eq 'neutral') } |
        Group-Object Id, Arch |
        ForEach-Object { $_.Group | Sort-Object Ver -Descending | Select-Object -First 1 }
}

function Test-PackageSignature([string]$Path) {
    $name = Split-Path $Path -Leaf
    try { $sig = Get-AuthenticodeSignature -LiteralPath $Path }
    catch { Write-Log "Подпись $name не проверена: $($_.Exception.Message)" 'WARN'; return $true }

    switch ($sig.Status.ToString()) {
        'Valid' {
            if ($sig.SignerCertificate.Subject -match 'O=Microsoft Corporation') { return $true }
            Write-Log "$name подписан не Microsoft: $($sig.SignerCertificate.Subject)" 'ERROR'
            return $false
        }
        { $_ -in 'NotSigned', 'HashMismatch' } {
            Write-Log "${name}: подпись отсутствует или повреждена ($_)." 'ERROR'
            return $false
        }
        default {
            Write-Log "${name}: статус подписи $_, окончательную проверку выполнит Windows при установке." 'WARN'
            return $true
        }
    }
}

function Test-AllowedUrl([string]$Url, [string]$Src) {
    try { $u = [Uri]$Url } catch { return $false }
    if ($Src -eq 'StoreCdn') {
        # CDN Microsoft отдаёт ссылки в том числе по HTTP; целостность закрывает проверка подписи.
        return ($u.Host -match '(^|\.)microsoft\.com$' -and $u.Scheme -in 'http', 'https')
    }
    $mirrorHost = ([Uri]$ManifestUrl).Host
    return ($u.Scheme -eq 'https' -and
            ($u.Host -eq $mirrorHost -or $u.Host -eq 'aka.ms' -or $u.Host -match '(^|\.)microsoft\.com$'))
}

function Invoke-Download([string]$Url, [string]$Dest) {
    $part = "$Dest.part"
    for ($i = 1; $i -le 3; $i++) {
        try {
            if (Test-Path $part) { Remove-Item $part -Force }
            Invoke-WebRequest -Uri $Url -OutFile $part -UseBasicParsing -TimeoutSec 600
            if ((Get-Item $part).Length -eq 0) { throw 'Получен пустой файл.' }
            Move-Item -LiteralPath $part -Destination $Dest -Force
            return
        } catch {
            Write-Log "Загрузка, попытка ${i}/3: $($_.Exception.Message)" 'WARN'
            if ($i -eq 3) { throw }
            Start-Sleep -Seconds (3 * $i)
        }
    }
}

# --- Источник 1: ссылки на CDN Microsoft через store.rg-adguard.net ---
function Get-StoreCdnLinks {
    $families = 'Microsoft.WindowsStore_8wekyb3d8bbwe', 'Microsoft.StorePurchaseApp_8wekyb3d8bbwe',
                'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe', 'Microsoft.XboxIdentityProvider_8wekyb3d8bbwe'
    $rx = [regex]'<a href="(?<u>[^"]+)"[^>]*>(?<n>[^<]+?\.(?:appx|msix|appxbundle|msixbundle))</a>'
    $links = @{}
    foreach ($fam in $families) {
        for ($try = 1; $try -le 2; $try++) {
            try {
                $resp = Invoke-WebRequest -Uri 'https://store.rg-adguard.net/api/GetFiles' -Method Post -UseBasicParsing `
                    -ContentType 'application/x-www-form-urlencoded' `
                    -Body @{ type = 'PackageFamilyName'; url = $fam; ring = 'RP'; lang = 'en-US' }
                foreach ($m in $rx.Matches($resp.Content)) {
                    $links[$m.Groups['n'].Value] = [System.Net.WebUtility]::HtmlDecode($m.Groups['u'].Value)
                }
                Write-Log "Список ссылок получен: $fam" 'OK'
                break
            } catch { Write-Log "${fam}, попытка ${try}: $($_.Exception.Message)" 'WARN' }
        }
    }
    return $links
}

# --- Источник 2: Mirror (JSON-манифест с наборами под версию Windows) ---
function Test-DepArch([string]$Name) {
    if ($Name -match '(?i)(^|[._-])arm64([._-]|$)') { return ($Arch -eq 'arm64') }
    if ($Name -match '(?i)(^|[._-])x64([._-]|$)')   { return ($Arch -eq 'x64') }
    if ($Name -match '(?i)(^|[._-])x86([._-]|$)')   { return $true }   # x86-зависимости нужны на любой архитектуре
    return $false
}

function Get-MirrorLinks([string]$Url) {
    if (-not $VersionKey) { throw "Сборка $build не поддерживается наборами Mirror (нужна 14393+)." }
    if ($Arch -eq 'x86'   -and $build -ge 26100) { throw '32-разрядная Windows 11 не поддерживается.' }
    if ($Arch -eq 'arm64' -and $build -lt 26100) { throw 'Для Windows 10 LTSC в манифесте нет пакетов ARM64.' }

    $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 30
    $m    = $resp.Content | ConvertFrom-Json
    $prop = $m.PSObject.Properties[$VersionKey]
    if (-not $prop) { throw "В манифесте нет набора $VersionKey." }
    $set = $prop.Value

    $urls = New-Object 'System.Collections.Generic.List[string]'
    foreach ($u in @($set.deps)) {
        if ($u -and (Test-DepArch ([IO.Path]::GetFileName(([Uri][string]$u).AbsolutePath)))) { $urls.Add([string]$u) }
    }
    foreach ($f in 'store', 'store_license', 'StorePurchaseApp', 'StorePurchaseApp_license') {
        $p = $set.PSObject.Properties[$f]
        if ($p -and -not [string]::IsNullOrWhiteSpace([string]$p.Value)) { $urls.Add([string]$p.Value) }
    }
    $links = @{}
    foreach ($u in ($urls | Sort-Object -Unique)) {
        $n = [Uri]::UnescapeDataString([IO.Path]::GetFileName(([Uri]$u).AbsolutePath))
        if ($n) { $links[$n] = $u }
    }
    return $links
}

function Save-MirrorFiles([hashtable]$Links, [string]$Dir) {
    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    Write-Log "К загрузке файлов: $($Links.Count) (источник Mirror)"
    foreach ($n in @($Links.Keys)) {
        $dest = Join-Path $Dir $n
        $url  = $Links[$n]
        if ((Test-Path $dest) -and -not $ForceDownload) { Write-Log "В кэше: $n"; continue }
        if (-not (Test-AllowedUrl $url 'Mirror')) { Write-Log "Адрес не допущен, пропуск: $url" 'WARN'; continue }
        try {
            Write-Log "Загрузка $n"
            Invoke-Download $url $dest
            if ($n -match '(?i)\.(appx|msix|appxbundle|msixbundle)$' -and -not (Test-PackageSignature $dest)) {
                Remove-Item $dest -Force -ErrorAction SilentlyContinue
            }
        } catch { Write-Log "Не скачан ${n}: $($_.Exception.Message)" 'WARN' }
    }
}

function Save-Packages([hashtable]$Links, [string]$Src) {
    $infos  = foreach ($n in $Links.Keys) { Get-PkgInfo $n }
    $wanted = @(Select-Latest $infos)
    Write-Log "К загрузке пакетов: $($wanted.Count) (источник $Src)"
    foreach ($p in $wanted) {
        $dest = Join-Path $CdnDir $p.File
        $url  = $Links[$p.File]
        if ((Test-Path $dest) -and -not $ForceDownload) { Write-Log "В кэше: $($p.File)"; continue }
        if (-not (Test-AllowedUrl $url $Src)) { Write-Log "Адрес не допущен, пропуск: $url" 'WARN'; continue }
        try {
            Write-Log "Загрузка $($p.File)"
            Invoke-Download $url $dest
            if (-not (Test-PackageSignature $dest)) { Remove-Item $dest -Force -ErrorAction SilentlyContinue }
        } catch { Write-Log "Не скачан $($p.File): $($_.Exception.Message)" 'WARN' }
    }
}

function Install-FromFolder([string]$Folder) {
    $files = @(Get-ChildItem -LiteralPath $Folder -File -ErrorAction SilentlyContinue |
               Where-Object { $_.Extension -match '^\.(appx|msix|appxbundle|msixbundle)$' })
    if ($files.Count -eq 0) { Write-Log "В папке $Folder нет пакетов." 'WARN'; return }

    $infos = foreach ($f in $files) {
        $i = Get-PkgInfo $f.Name
        if ($i) { $i | Add-Member -NotePropertyName Path -NotePropertyValue $f.FullName -PassThru }
    }
    $latest = @(Select-Latest $infos | Where-Object { Test-PackageSignature $_.Path })

    $mains    = @(foreach ($id in $MainIds) { $latest | Where-Object { $_.Id -eq $id } })
    $deps     = @($latest | Where-Object { $MainIds -notcontains $_.Id })
    $depPaths = @($deps | ForEach-Object { $_.Path })
    Write-Log "Зависимостей: $($deps.Count), основных пакетов: $($mains.Count)"

    foreach ($d in $deps) {
        try   { Add-AppxPackage -Path $d.Path -ErrorAction Stop; Write-Log $d.File 'OK' }
        catch { Write-Log "$($d.File): $($_.Exception.Message.Split("`n")[0]) (возможно, уже стоит более новая)" 'WARN' }
    }
    foreach ($m in $mains) {
        try {
            if ($depPaths.Count) { Add-AppxPackage -Path $m.Path -DependencyPath $depPaths -ErrorAction Stop }
            else                 { Add-AppxPackage -Path $m.Path -ErrorAction Stop }
            Write-Log $m.File 'OK'
        } catch { Write-Log "$($m.File): $($_.Exception.Message.Split("`n")[0])" 'WARN' }

        if (-not $CurrentUserOnly) {
            try {
                if ($depPaths.Count) {
                    Add-AppxProvisionedPackage -Online -PackagePath $m.Path -DependencyPackagePath $depPaths -SkipLicense | Out-Null
                } else {
                    Add-AppxProvisionedPackage -Online -PackagePath $m.Path -SkipLicense | Out-Null
                }
                Write-Log "В образ системы: $($m.File)" 'OK'
            } catch { Write-Log "Образ, $($m.File): $($_.Exception.Message.Split("`n")[0])" 'WARN' }
        }
    }
}

function Install-OnePackage([string]$Path, [string[]]$Deps, [string]$License) {
    $leaf = Split-Path $Path -Leaf
    if (-not $CurrentUserOnly) {
        $pr = @{ Online = $true; PackagePath = $Path; ErrorAction = 'Stop' }
        if ($Deps.Count) { $pr.DependencyPackagePath = $Deps }
        if ($License -and (Test-Path -LiteralPath $License)) { $pr.LicensePath = $License } else { $pr.SkipLicense = $true }
        try   { Add-AppxProvisionedPackage @pr | Out-Null; Write-Log "В образ системы: $leaf" 'OK' }
        catch { Write-Log "Образ, ${leaf}: $($_.Exception.Message.Split("`n")[0])" 'WARN' }
    }
    try   { Add-AppxPackage -Path $Path -ErrorAction Stop; Write-Log "Текущему пользователю: $leaf" 'OK' }
    catch { Write-Log "${leaf}: $($_.Exception.Message.Split("`n")[0])" 'WARN' }
}

function Install-FromMirrorFolder([string]$Dir) {
    $all   = @(Get-ChildItem -LiteralPath $Dir -File -ErrorAction SilentlyContinue)
    $store = $all | Where-Object { $_.Name -match '(?i)WindowsStore.*\.(msixbundle|appxbundle)$' } |
             Sort-Object Name -Descending | Select-Object -First 1
    if (-not $store) { Write-Log "В $Dir нет пакета Microsoft.WindowsStore." 'WARN'; return }
    if (-not (Test-PackageSignature $store.FullName)) { return }

    $deps = @($all | Where-Object { $_.Extension -match '(?i)^\.(appx|msix)$' -and (Test-DepArch $_.Name) } |
                     Where-Object { Test-PackageSignature $_.FullName } |
                     ForEach-Object { $_.FullName } | Sort-Object -Unique)
    if ($deps.Count -eq 0) { Write-Log "Нет зависимостей для архитектуры $Arch в $Dir." 'WARN'; return }
    Write-Log "Зависимостей для ${Arch}: $($deps.Count)"
    foreach ($d in $deps) {
        try   { Add-AppxPackage -Path $d -ErrorAction Stop; Write-Log (Split-Path $d -Leaf) 'OK' }
        catch { Write-Log "$(Split-Path $d -Leaf): $($_.Exception.Message.Split("`n")[0]) (возможно, уже стоит более новая)" 'WARN' }
    }

    $lic = $all | Where-Object { $_.Name -match '(?i)WindowsStore.*\.xml$' } | Select-Object -First 1
    Install-OnePackage $store.FullName $deps $(if ($lic) { $lic.FullName } else { '' })

    $pur = $all | Where-Object { $_.Name -match '(?i)StorePurchaseApp.*\.(msixbundle|appxbundle)$' } |
           Sort-Object Name -Descending | Select-Object -First 1
    if ($pur -and (Test-PackageSignature $pur.FullName)) {
        $pl = $all | Where-Object { $_.Name -match '(?i)StorePurchaseApp.*\.xml$' } | Select-Object -First 1
        Install-OnePackage $pur.FullName $deps $(if ($pl) { $pl.FullName } else { '' })
    }
}

function Register-Existing {
    try {
        Get-AppxPackage -AllUsers -Name $MainIds | ForEach-Object {
            $manifest = Join-Path $_.InstallLocation 'AppXManifest.xml'
            if (Test-Path $manifest) { Add-AppxPackage -DisableDevelopmentMode -Register $manifest -ErrorAction SilentlyContinue }
        }
    } catch { Write-Log $_.Exception.Message 'WARN' }
}

# =====================================================================
#                              ОСНОВНОЙ ХОД
# =====================================================================
if (Test-StoreInstalled) { Write-Log 'Store уже установлен для текущего пользователя.' 'OK'; Finish }

Write-Log 'Проверка служб, нужных для Store'
foreach ($name in 'InstallService', 'ClipSVC', 'AppXSvc', 'wuauserv', 'LicenseManager') {
    $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
    if (-not $svc) { continue }
    try {
        if ($svc.StartType -eq 'Disabled') { Set-Service -Name $name -StartupType Manual }
        if ($svc.Status -ne 'Running')     { Start-Service -Name $name -ErrorAction SilentlyContinue }
    } catch { Write-Log "Служба ${name}: $($_.Exception.Message)" 'WARN' }
}

# --- 1. Регистрация имеющихся файлов ---
Write-Log 'Способ 1: регистрация существующих файлов Store'
Register-Existing
if (Test-StoreInstalled) { Finish }
Write-Log 'Файлов Store в системе нет.' 'WARN'

# --- 2. wsreset -i ---
$wsreset = Join-Path $env:SystemRoot 'System32\wsreset.exe'
if ($SkipWsreset -or $build -lt 22000 -or -not (Test-Path $wsreset)) {
    Write-Log 'Способ 2 (wsreset -i) пропущен: нужна Windows 11 (сборка 22000+) и wsreset.exe.'
} else {
    Write-Log "Способ 2: wsreset.exe -i (ожидание до $WsresetTimeout с)"
    try {
        Start-Process -FilePath $wsreset -ArgumentList '-i' -WindowStyle Hidden
        if (Wait-Store $WsresetTimeout) { Finish }
        Write-Log 'wsreset не установил Store, переходим дальше.' 'WARN'
    } catch { Write-Log $_.Exception.Message 'WARN' }
}

# --- 3. Локальная папка ---
if ($PackagePath) {
    Write-Log "Способ 3: установка из папки $PackagePath"
    Install-FromFolder $PackagePath
    if (Test-StoreInstalled) { Finish }
    Write-Log 'Из локальной папки установить не удалось.' 'WARN'
}

# --- 4. Кэш ---
if (-not $ForceDownload) {
    Write-Log 'Способ 4: пакеты из кэша'
    if (Test-Path $CdnDir) { Install-FromFolder $CdnDir }
    if (-not (Test-StoreInstalled) -and $VersionKey -and (Test-Path (Join-Path $MirrorRoot $VersionKey))) {
        Install-FromMirrorFolder (Join-Path $MirrorRoot $VersionKey)
    }
    if (-not (Test-StoreInstalled)) { Register-Existing }
    if (Test-StoreInstalled) { Finish }
}

# --- 5. Загрузка из сети ---
if (-not $NoDownload) {
    $sources = switch ($Source) {
        'StoreCdn' { @('StoreCdn') }
        'Mirror'   { @('Mirror') }
        default    { if ($build -lt 19041) { @('Mirror', 'StoreCdn') } else { @('StoreCdn', 'Mirror') } }
    }
    foreach ($src in $sources) {
        Write-Log "Способ 5: загрузка, источник $src"
        try {
            if ($src -eq 'StoreCdn') {
                $links = Get-StoreCdnLinks
                if (-not $links -or $links.Count -eq 0) { Write-Log 'StoreCdn не дал ссылок.' 'WARN'; continue }
                Save-Packages $links 'StoreCdn'
                Install-FromFolder $CdnDir
            } else {
                $links = Get-MirrorLinks $ManifestUrl
                if (-not $links -or $links.Count -eq 0) { Write-Log 'Mirror не дал ссылок.' 'WARN'; continue }
                $dir = Join-Path $MirrorRoot $VersionKey
                Save-MirrorFiles $links $dir
                Install-FromMirrorFolder $dir
            }
            if (-not (Test-StoreInstalled)) { Register-Existing }
            if (Test-StoreInstalled) { Finish }
        } catch { Write-Log "Источник ${src}: $($_.Exception.Message)" 'ERROR' }
    }
}

# --- Итог ---
Write-Log 'Установить Microsoft Store не удалось.' 'ERROR'
Write-Host @"

Что можно сделать:
  * Проверьте интернет и повторите запуск.
  * Скачайте пакеты вручную (Store, StorePurchaseApp, DesktopAppInstaller,
    XboxIdentityProvider, VCLibs, NET.Native.Framework/Runtime, UI.Xaml) в одну
    папку и запустите: Install-MicrosoftStore.cmd -PackagePath <папка> -NoDownload
  * Подробности смотрите в журнале: $LogFile
"@
Wait-Key
exit 1
