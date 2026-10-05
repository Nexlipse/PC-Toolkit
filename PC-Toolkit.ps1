<#
================================================================================
 PC-Toolkit.ps1 - Toolkit Optimasi & Perawatan Windows (CLI + JSON engine)
--------------------------------------------------------------------------------
 Fitur:
   1. Bersihkan cache: %TEMP%, C:\Windows\Temp, Prefetch, WER, thumbnail,
      cache Windows Update, Recycle Bin, flush DNS
   2. Cek kesehatan baterai (battery health) + laporan powercfg
   3. Cek kesehatan SSD/HDD (SMART: health, wear, suhu, jam nyala)
   4. Cek & hapus sisa file aplikasi (leftover) + entri uninstall mati
   5. Monitoring suhu CPU real-time
   6. Bersihkan cache browser (Chrome / Edge / Firefox)
   7. Kelola aplikasi startup (dengan backup .reg otomatis)
   8. Ringkasan kesehatan sistem
   9. Jalankan DASHBOARD (Web UI via Node.js, di latar belakang)
  10. Skema daya (Power Plan)

 CLI  : powershell -ExecutionPolicy Bypass -File .\PC-Toolkit.ps1
 JSON : powershell -ExecutionPolicy Bypass -File .\PC-Toolkit.ps1 -Task <task> -Json
================================================================================
#>

param(
    [ValidateSet('menu','junk','junk-size','battery','disk','leftover-scan','delete-leftover','cpu','browser','startup-list','disable-startup','summary','power-list','set-power')]
    [string]$Task = 'menu',
    [switch]$Json,
    [switch]$IncludeRecycleBin,
    [string]$Guid = ''
)

$ErrorActionPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# ============================= VARIABEL GLOBAL =============================
$script:Quiet    = [bool]$Json
$script:IsAdmin  = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$script:LogDir   = Join-Path $PSScriptRoot 'logs'
$script:BackupDir = Join-Path $script:LogDir 'backup'
if (-not (Test-Path -LiteralPath $script:LogDir))    { New-Item -ItemType Directory -Path $script:LogDir    -Force | Out-Null }
if (-not (Test-Path -LiteralPath $script:BackupDir)) { New-Item -ItemType Directory -Path $script:BackupDir -Force | Out-Null }
$script:LogFile = Join-Path $script:LogDir ("log-{0}.txt" -f (Get-Date -Format 'yyyy-MM-dd'))
try { Add-Type -AssemblyName Microsoft.VisualBasic } catch { }

$script:LeftoverExclude = @(
    'microsoft','windows','windowsapps','common files','windows defender',
    'internet explorer','windows media player','windows photo viewer','windows nt',
    'windows defender advanced threat protection','windows security health',
    'packages','temp','d3dscache','connecteddevicesplatform','comms','squirreltemp',
    'modifiablewindowsapps','programs','package cache','downloaded installations',
    'reference assemblies','usoprivate','usoshared','start menu','templates'
)

# ================================ FUNGSI BANTU ==============================
function Write-Log { param([string]$Pesan)
    $baris = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Pesan
    Add-Content -Path $script:LogFile -Value $baris -Encoding UTF8
}

function Format-Size { param([double]$Byte)
    if ($Byte -ge 1GB) { return ("{0:N2} GB" -f ($Byte / 1GB)) }
    elseif ($Byte -ge 1MB) { return ("{0:N1} MB" -f ($Byte / 1MB)) }
    elseif ($Byte -ge 1KB) { return ("{0:N1} KB" -f ($Byte / 1KB)) }
    return ("{0} B" -f [int64]$Byte)
}

function Get-FolderSize { param([string]$Path)
    if ([string]::IsNullOrEmpty($Path) -or -not (Test-Path -LiteralPath $Path)) { return 0 }
    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { return 0 }
    return [int64]$sum
}

function Write-Ui { param([string]$Teks, [string]$Warna = '')
    if ($script:Quiet) { return }
    if ($Warna) { Write-Host $Teks -ForegroundColor $Warna } else { Write-Host $Teks }
}

function Clear-Screen { if (-not $script:Quiet) { try { Clear-Host } catch { } } }

function Write-Field { param([string]$Label, [string]$Nilai = '', [string]$Warna = '')
    Write-Ui ('  {0,-17} {1}' -f $Label, $Nilai) $Warna
}

# Nilai panjang dipotong supaya kolom tabel tidak geser. Nama/label dibiarkan utuh.
function Potong { param([string]$Teks, [int]$Maks)
    if ($null -eq $Teks) { return '' }
    if ($Teks.Length -le $Maks) { return $Teks }
    return $Teks.Substring(0, $Maks - 3) + '...'
}

# Satu langkah lanjutan yang bisa dilakukan, bukan sekadar angka merah.
function Write-Saran { param([string]$Teks) Write-Ui ('  Saran: ' + $Teks) 'Cyan' }

# Jendela console hanya selebar konten, bukan memenuhi layar.
function Set-Layar { param([int]$Kolom = 76, [int]$Baris = 38)
    if ($script:Quiet) { return }
    try {
        $raw = $Host.UI.RawUI
        if ($raw.BufferSize.Width -lt $Kolom) {
            $raw.BufferSize = New-Object System.Management.Automation.Host.Size($Kolom, $raw.BufferSize.Height)
        }
        $raw.WindowSize = New-Object System.Management.Automation.Host.Size($Kolom, $Baris)
    } catch { }
}



function Write-Section { param([string]$Judul)
    Write-Ui ''
    Write-Ui ("  $Judul") 'Cyan'
    Write-Ui ('  ' + ('-' * [Math]::Min(60, $Judul.Length))) 'DarkGray'
    Write-Ui ''
}

function Show-Banner {
    Clear-Screen
    Write-Ui '  PC TOOLKIT' 'White'
    Write-Ui '  Optimasi & perawatan Windows' 'DarkGray'
    Write-Ui ''
    if ($script:IsAdmin) { Write-Ui '  Mode       : Administrator' 'Green' }
    else { Write-Ui '  Mode       : User biasa - beberapa fitur butuh admin' 'Yellow' }
    Write-Ui ('  Komputer   : {0}\{1}' -f $env:COMPUTERNAME, $env:USERNAME)
    Write-Ui ('  Log        : logs\log-{0}.txt' -f (Get-Date -Format 'yyyy-MM-dd')) 'DarkGray'
}

function Pause-Menu { param([string]$Pesan = '  Enter untuk kembali ke menu')
    if ($script:Quiet) { return }
    [void](Read-Host $Pesan)
}

function Ask-Confirm { param([string]$Pesan)
    if ($script:Quiet) { return $false }
    $j = Read-Host ('  {0}  [y/N] ' -f $Pesan)
    if ($null -eq $j) { return $false }
    return ($j -match '^(y|ya|yes|1)$')
}

function ConvertTo-Norm { param([string]$Teks)
    if ([string]::IsNullOrWhiteSpace($Teks)) { return '' }
    return ($Teks.ToLower() -replace '[^a-z0-9]', '')
}

function Get-SelectedIndexes {
    param([string]$Pilihan, [int]$Max)
    $list = New-Object 'System.Collections.Generic.List[int]'
    if ([string]::IsNullOrWhiteSpace($Pilihan)) { return @() }
    foreach ($part in ($Pilihan -split '[,\s]+')) {
        if ([string]::IsNullOrWhiteSpace($part)) { continue }
        if ($part -match '^(\d+)-(\d+)$') {
            $a = [int]$Matches[1]; $b = [int]$Matches[2]
            if ($a -gt $b) { $t = $a; $a = $b; $b = $t }
            for ($i = $a; $i -le $b; $i++) { if ($i -ge 1 -and $i -le $Max) { $list.Add($i) } }
        } elseif ($part -match '^\d+$') {
            $i2 = [int]$part
            if ($i2 -ge 1 -and $i2 -le $Max) { $list.Add($i2) }
        }
    }
    return @($list | Sort-Object -Unique)
}

function Get-PathFromUninstallString { param([string]$String)
    if ([string]::IsNullOrWhiteSpace($String)) { return $null }
    $s = $String.Trim()
    if ($s.StartsWith('"')) {
        $end = $s.IndexOf('"', 1)
        if ($end -gt 1) { $s = $s.Substring(1, $end - 1) } else { return $null }
    } else {
        $s = ($s -split ' -')[0]
        $s = ($s -split ' /')[0]
        $s = $s.Trim()
    }
    if ($s -notmatch '[\\/]') { return $null }
    if ($s -match '(?i)msiexec') { return $null }
    return $s
}

function Remove-ChildrenSafe {
    param([string]$Path, [string[]]$Pola = $null)
    $gagal = 0; $bebas = [int64]0
    if ([string]::IsNullOrEmpty($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Gagal = 0; Byte = [int64]0 }
    }
    $items = Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    foreach ($i in $items) {
        if ($Pola) {
            $cocok = $false
            foreach ($p in $Pola) { if ($i.Name -like $p) { $cocok = $true; break } }
            if (-not $cocok) { continue }
        }
        try {
            $sz = [int64]0
            if ($i.PSIsContainer) { $sz = Get-FolderSize -Path $i.FullName } else { $sz = [int64]$i.Length }
            Remove-Item -LiteralPath $i.FullName -Recurse -Force -ErrorAction Stop
            $bebas += $sz
        } catch { $gagal++ }
    }
    return [pscustomobject]@{ Gagal = $gagal; Byte = $bebas }
}

function Remove-ToRecycleBin { param([string]$Path)
    try {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($Path, [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs, [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
        return $true
    } catch { return $false }
}

function Read-StdinLines {
    $lines = @()
    try {
        if ([Console]::IsInputRedirected) {
            while ($true) {
                $line = [Console]::In.ReadLine()
                if ($null -eq $line) { break }
                $t = $line.Trim()
                if ($t) { $lines += $t }
            }
        }
    } catch { }
    return @($lines)
}

function Out-Json { param($Obj) $Obj | ConvertTo-Json -Depth 8 }

# ============================ 1. BERSIHKAN CACHE ============================
function Get-JunkTargets {
    $targets = @()
    $targets += [pscustomobject]@{ Nama = 'Temp user (%TEMP%)';     Path = $env:TEMP;                                                       ButuhAdmin = $false; Pola = $null; Layanan = $null }
    $targets += [pscustomobject]@{ Nama = 'Temp Windows';           Path = (Join-Path $env:windir 'Temp');                                  ButuhAdmin = $true;  Pola = $null; Layanan = $null }
    $targets += [pscustomobject]@{ Nama = 'Prefetch';               Path = (Join-Path $env:windir 'Prefetch');                              ButuhAdmin = $true;  Pola = $null; Layanan = $null }
    $targets += [pscustomobject]@{ Nama = 'Crash Dumps';            Path = (Join-Path $env:LOCALAPPDATA 'CrashDumps');                      ButuhAdmin = $false; Pola = $null; Layanan = $null }
    $targets += [pscustomobject]@{ Nama = 'Error Report (Queue)';   Path = 'C:\ProgramData\Microsoft\Windows\WER\ReportQueue';              ButuhAdmin = $true;  Pola = $null; Layanan = $null }
    $targets += [pscustomobject]@{ Nama = 'Error Report (Archive)'; Path = 'C:\ProgramData\Microsoft\Windows\WER\ReportArchive';            ButuhAdmin = $true;  Pola = $null; Layanan = $null }
    $targets += [pscustomobject]@{ Nama = 'Cache Windows Update';   Path = (Join-Path $env:windir 'SoftwareDistribution\Download');         ButuhAdmin = $true;  Pola = $null; Layanan = @('wuauserv','bits') }
    $targets += [pscustomobject]@{ Nama = 'Thumbnail & Icon Cache'; Path = (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer');      ButuhAdmin = $false; Pola = @('thumbcache_*.db','iconcache_*.db'); Layanan = $null }
    return @($targets)
}

function Invoke-JunkClean {
    param([switch]$IncludeRecycleBin)
    $details = @(); $totalFreed = [int64]0; $totalFailed = 0
    foreach ($t in (Get-JunkTargets)) {
        $status = 'ok'; $freed = [int64]0
        if (-not (Test-Path -LiteralPath $t.Path)) { $status = 'tidak ada' }
        elseif ($t.ButuhAdmin -and -not $script:IsAdmin) { $status = 'butuh admin' }
        else {
            if ($t.Layanan) { foreach ($s in $t.Layanan) { Stop-Service -Name $s -Force -ErrorAction SilentlyContinue } }
            $h = Remove-ChildrenSafe -Path $t.Path -Pola $t.Pola
            if ($t.Layanan) { foreach ($s in $t.Layanan) { Start-Service -Name $s -ErrorAction SilentlyContinue } }
            $freed = [int64]$h.Byte
            if ($h.Gagal -gt 0) { $status = ('sebagian gagal ({0} file terkunci)' -f $h.Gagal); $totalFailed += $h.Gagal }
            elseif ($freed -eq 0) { $status = 'sudah bersih' }
            $totalFreed += $freed
            Write-Log ('BERSIHKAN {0} -> {1}' -f $t.Path, (Format-Size $freed))
        }
        $details += [pscustomobject]@{ name = $t.Nama; path = $t.Path; freedBytes = $freed; status = $status }
    }
    $rb = $false
    if ($IncludeRecycleBin) {
        try { Clear-RecycleBin -Force -ErrorAction Stop; $rb = $true; Write-Log 'RECYCLE BIN dikosongkan' } catch { $rb = $false }
    }
    $dns = $false
    try { Clear-DnsClientCache -ErrorAction Stop; $dns = $true; Write-Log 'Cache DNS dibersihkan' } catch { }
    return [pscustomobject]@{
        freedBytes = $totalFreed; failedCount = $totalFailed
        details = @($details); recycleBinCleaned = $rb; dnsFlushed = $dns
    }
}

function Show-JunkInteractive {
    Show-Banner
    Write-Section 'BERSIHKAN CACHE & FILE SAMPAH'
    $targets = Get-JunkTargets
    $total = [int64]0
    Write-Ui '  Hitungan ukuran per lokasi. File yang sedang dipakai sistem dilewati otomatis.' 'DarkGray'
    Write-Ui ''
    Write-Ui ('  {0,-24}{1,12}  {2}' -f 'Lokasi', 'Ukuran', 'Status') 'White'
    Write-Ui ('  {0,-24}{1,-12}  {2}' -f ('-' * 24), ('-' * 12), ('-' * 18)) 'DarkGray'
    foreach ($t in $targets) {
        $size = [int64]0
        $status = 'siap'
        $warna = ''
        if (-not (Test-Path -LiteralPath $t.Path)) { $status = 'tidak ada'; $warna = 'DarkGray' }
        elseif ($t.ButuhAdmin -and -not $script:IsAdmin) { $status = 'butuh admin'; $warna = 'Yellow' }
        else {
            if ($t.Pola) {
                foreach ($p in $t.Pola) {
                    $sum = (Get-ChildItem -LiteralPath $t.Path -Filter $p -Force -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
                    if ($sum) { $size += $sum }
                }
            } else { $size = Get-FolderSize -Path $t.Path }
            if ($size -eq 0) { $status = 'sudah bersih' }
        }
        $total += $size
        Write-Ui ('  {0,-24}{1,12}  {2}' -f $t.Nama, (Format-Size $size), $status) $warna
    }
    Write-Ui ('  {0,-24}{1,12}' -f ('-' * 24), ('-' * 12)) 'DarkGray'
    Write-Ui ('  {0,-24}{1,12}' -f 'Total', (Format-Size $total)) 'White'
    Write-Ui ''

    if ($total -eq 0) {
        Write-Ui '  Tidak ada sampah yang bisa dibebaskan. Tidak perlu membersihkan.' 'Green'
        Write-Ui ''
        Pause-Menu
        return
    }

    if (-not (Ask-Confirm ("Bersihkan {0} ini?" -f (Format-Size $total)))) { Write-Ui '  Dibatalkan.' 'DarkGray'; Pause-Menu; return }
    $rb = Ask-Confirm 'Kosongkan juga Recycle Bin?'
    Write-Ui ''
    Write-Ui '  Membersihkan...' 'Gray'
    $hsl = Invoke-JunkClean -IncludeRecycleBin:$rb
    Write-Ui ''
    Write-Ui ('  {0,-24}{1,12}  {2}' -f 'Lokasi', 'Diberaskan', 'Hasil') 'White'
    Write-Ui ('  {0,-24}{1,-12}  {2}' -f ('-' * 24), ('-' * 12), ('-' * 22)) 'DarkGray'
    foreach ($it in $hsl.details) {
        $w = 'Green'
        if ($it.status -like '*gagal*') { $w = 'Yellow' }
        elseif ($it.status -eq 'butuh admin') { $w = 'Yellow' }
        elseif ($it.status -eq 'tidak ada') { $w = 'DarkGray' }
        Write-Ui ('  {0,-24}{1,12}  {2}' -f $it.name, (Format-Size $it.freedBytes), $it.status) $w
    }
    Write-Ui ''
    Write-Ui ('  Total dibebaskan: {0}' -f (Format-Size $hsl.freedBytes)) 'Green'
    if ($hsl.failedCount -gt 0) { Write-Ui ('  {0} file terkunci dilewati.' -f $hsl.failedCount) 'Yellow' }
    if ($hsl.recycleBinCleaned) { Write-Ui '  Recycle Bin dikosongkan.' 'Green' }
    if ($hsl.dnsFlushed) { Write-Ui '  Cache DNS dibersihkan.' 'Green' }
    Write-Ui ''
    Pause-Menu
}

function Get-JunkSizeData {
    $items = @()
    foreach ($t in (Get-JunkTargets)) {
        $size = [int64]0
        $status = 'ok'
        if (-not (Test-Path -LiteralPath $t.Path)) { $status = 'tidak ada' }
        elseif ($t.ButuhAdmin -and -not $script:IsAdmin) { $status = 'butuh admin' }
        else {
            if ($t.Pola) {
                foreach ($p in $t.Pola) {
                    $sum = (Get-ChildItem -LiteralPath $t.Path -Filter $p -Force -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
                    if ($sum) { $size += $sum }
                }
            } else { $size = Get-FolderSize -Path $t.Path }
        }
        $items += [pscustomobject]@{ name = $t.Nama; path = $t.Path; sizeBytes = $size; status = $status }
    }
    return [pscustomobject]@{ isAdmin = $script:IsAdmin; items = @($items) }
}

# ============================ 2. BATERAI ====================================
function Get-BatteryData {
    $d = [pscustomobject]@{
        present = $false; percent = $null; statusCode = $null; statusText = 'Tidak ada baterai'
        designCapacity = $null; fullChargeCapacity = $null; healthPercent = $null
        cycleCount = $null; voltage = $null; reportPath = $null
    }
    $bat = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $bat) { return $d }
    $d = [pscustomobject]@{
        present = $true; percent = $bat.EstimatedChargeRemaining; statusCode = $bat.BatteryStatus
        statusText = ('Kode {0}' -f $bat.BatteryStatus)
        designCapacity = $null; fullChargeCapacity = $null; healthPercent = $null
        cycleCount = $null; voltage = $null; reportPath = $null
    }
    if ($null -ne $bat.BatteryStatus) {
        switch ([int]$bat.BatteryStatus) {
            1  { $d.statusText = 'Menggunakan baterai (discharge)' }
            2  { $d.statusText = 'Terhubung AC' }
            3  { $d.statusText = 'Terisi penuh' }
            6  { $d.statusText = 'Sedang mengisi daya' }
            7  { $d.statusText = 'Mengisi daya (tinggi)' }
            8  { $d.statusText = 'Mengisi daya (rendah)' }
            9  { $d.statusText = 'Mengisi daya (kritis)' }
            11 { $d.statusText = 'Terisi sebagian' }
        }
    }
    $static = Get-CimInstance -Namespace 'root\wmi' -ClassName BatteryStaticData -ErrorAction SilentlyContinue
    if ($static) {
        $d.designCapacity = ($static | Measure-Object -Property DesignedCapacity -Maximum).Maximum
        $volt = ($static | Measure-Object -Property DesignVoltage -Maximum).Maximum
        if ($volt) { $d.voltage = $volt }
    }
    $fc = Get-CimInstance -Namespace 'root\wmi' -ClassName BatteryFullChargedCapacity -ErrorAction SilentlyContinue
    if ($fc) { $d.fullChargeCapacity = ($fc | Measure-Object -Property FullChargedCapacity -Maximum).Maximum }
    if ($d.designCapacity -and $d.fullChargeCapacity) {
        $d.healthPercent = [math]::Round(($d.fullChargeCapacity / $d.designCapacity) * 100, 1)
    }
    $cc = Get-CimInstance -Namespace 'root\wmi' -ClassName BatteryCycleCount -ErrorAction SilentlyContinue
    if ($cc) { $d.cycleCount = ($cc | Measure-Object -Property CycleCount -Maximum).Maximum }
    try {
        $rep = Join-Path $script:LogDir 'battery-report.html'
        & powercfg /batteryreport /output $rep 2>$null | Out-Null
        if (Test-Path -LiteralPath $rep) { $d.reportPath = $rep }
    } catch { }
    # Fallback: parse kapasitas dari laporan HTML bila WMI tidak melaporkannya
    if ($d.reportPath) {
        try {
            $html = Get-Content -LiteralPath $d.reportPath -Raw -ErrorAction Stop
            if ($null -eq $d.designCapacity) {
                $m = [regex]::Match($html, 'DESIGN\s+CAPACITY\s*</span>\s*</td>\s*<td[^>]*>\s*([\d\.,]+)', 'IgnoreCase')
                if ($m.Success) { $d.designCapacity = [int64]($m.Groups[1].Value -replace '\D', '') }
            }
            if ($null -eq $d.fullChargeCapacity) {
                $m = [regex]::Match($html, 'FULL\s+CHARGE\s+CAPACITY\s*</span>\s*</td>\s*<td[^>]*>\s*([\d\.,]+)', 'IgnoreCase')
                if ($m.Success) { $d.fullChargeCapacity = [int64]($m.Groups[1].Value -replace '\D', '') }
            }
            if ($null -ne $d.designCapacity -and $null -ne $d.fullChargeCapacity -and $null -eq $d.healthPercent) {
                $d.healthPercent = [math]::Round(($d.fullChargeCapacity / $d.designCapacity) * 100, 1)
            }
        } catch { }
    }
    return $d
}

function Show-BatteryInteractive {
    Show-Banner
    Write-Section 'CEK KESEHATAN BATERAI'
    $d = Get-BatteryData
    if (-not $d.present) {
        Write-Ui '  Tidak ada baterai terdeteksi.' 'Yellow'
        Write-Ui '  Kemungkinan PC desktop, atau sedang berjalan di dalam VM.' 'DarkGray'
        Write-Ui ''
        Pause-Menu
        return
    }

    $pct = if ($null -ne $d.percent) { "$($d.percent) %" } else { 'tidak dilaporkan' }
    Write-Field 'Daya saat ini' $pct
    Write-Field 'Status' $d.statusText
    if ($null -ne $d.designCapacity)     { Write-Field 'Kapasitas desain' ("{0} mWh" -f $d.designCapacity) }
    if ($null -ne $d.fullChargeCapacity) { Write-Field 'Kapasitas penuh'  ("{0} mWh" -f $d.fullChargeCapacity) }
    if ($null -ne $d.cycleCount)         { Write-Field 'Siklus charge'   $d.cycleCount }

    Write-Ui ''
    if ($null -ne $d.healthPercent) {
$warna = 'Green'; $ket = 'Masih bagus, tidak perlu diganti.'
        if ($d.healthPercent -lt 50) { $warna = 'Red'; $ket = 'Buruk. Pertimbangkan ganti baterai.' }
        elseif ($d.healthPercent -lt 80) { $warna = 'Yellow'; $ket = 'Mulai menurun. Pantau pemakaian dan durasi pakai.' }
        Write-Field 'Kesehatan' ("{0} %" -f $d.healthPercent) $warna
        Write-Ui ('    ' + ($ket)) $warna
        if ($d.healthPercent -lt 80) { Write-Saran 'kalau sering turun ke bawah 30% saat tidak dipakai, shut down penuh (Start > Shut down) lebih baik daripada Sleep.' }
    } else {
        Write-Ui '  Kesehatan baterai tidak bisa dihitung: firmware tidak melaporkan' 'DarkGray'
        Write-Ui '  kapasitas desain maupun kapasitas penuh. Buka laporan powercfg di bawah.' 'DarkGray'
    }

    if ($d.reportPath) {
        Write-Ui ''
        Write-Ui ('  Laporan lengkap: logs\battery-report.html') 'DarkGray'
    }
    Write-Ui ''
    Pause-Menu
}

# ============================ 3. SSD / HDD ==================================
function Convert-DiskTemp { param($Nilai)
    if ($null -eq $Nilai -or $Nilai -le 0) { return $null }
    if ($Nilai -gt 200) { $c = ($Nilai / 10.0) - 273.15 } else { $c = $Nilai }
    if ($c -ge -20 -and $c -le 150) { return [math]::Round($c, 1) }
    return $null
}

function Get-DiskData {
    $disks = @()
    foreach ($p in (Get-PhysicalDisk -ErrorAction SilentlyContinue)) {
        $rel = $null
        try { $rel = $p | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue } catch { }
        $temp = $null
        if ($rel -and $rel.Temperature) { $temp = Convert-DiskTemp $rel.Temperature }
        $disks += [pscustomobject]@{
            model = "$($p.FriendlyName)"; mediaType = "$($p.MediaType)"; busType = "$($p.BusType)"
            sizeBytes = [int64]$p.Size; health = "$($p.HealthStatus)"
            temperatureC = $temp; wear = $rel.Wear; powerOnHours = $rel.PowerOnHours; readErrors = $rel.ReadErrorsTotal
        }
    }
    if ($disks.Count -eq 0) {
        foreach ($x in (Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction SilentlyContinue)) {
            $disks += [pscustomobject]@{
                model = "$($x.Model)"; mediaType = '?'; busType = '?'
                sizeBytes = [int64]$x.Size; health = "$($x.Status)"
                temperatureC = $null; wear = $null; powerOnHours = $null; readErrors = $null
            }
        }
    }
    $vols = @()
    foreach ($v in (Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter })) {
        if (-not $v.Size) { continue }
        $vols += [pscustomobject]@{
            letter = "$($v.DriveLetter)"; label = "$($v.FileSystemLabel)"
            sizeBytes = [int64]$v.Size; freeBytes = [int64]$v.SizeRemaining
        }
    }
    return [pscustomobject]@{ disks = @($disks); volumes = @($vols) }
}

function Show-DiskInteractive {
    Show-Banner
    Write-Section 'CEK KESEHATAN SSD / HDD'
    $d = Get-DiskData

    if ($d.disks.Count -eq 0) {
        Write-Ui '  Tidak ada disk yang terbaca.' 'Yellow'
    }
    $no = 0
    foreach ($dk in $d.disks) {
        $no++
        Write-Ui ('  Disk {0}: {1}' -f $no, $dk.model) 'White'
        Write-Field 'Tipe' ("{0} via {1}" -f $dk.mediaType, $dk.busType)
        Write-Field 'Kapasitas' (Format-Size $dk.sizeBytes)
        $warna = 'Green'
        if ($dk.health -ne 'Healthy' -and $dk.health -ne 'OK') { $warna = 'Red' }
        Write-Field 'Health' $dk.health $warna
        if ($null -ne $dk.temperatureC) {
            $w = 'Green'; if ($dk.temperatureC -ge 55) { $w = 'Yellow' } elseif ($dk.temperatureC -ge 70) { $w = 'Red' }
            Write-Field 'Suhu' ("{0} C" -f $dk.temperatureC) $w
        }
        if ($null -ne $dk.wear) {
            $w = 'Green'; if ($dk.wear -gt 50) { $w = 'Yellow' } elseif ($dk.wear -gt 80) { $w = 'Red' }
            Write-Field 'Keausan' ("{0} % terpakai" -f $dk.wear) $w
        }
        if ($null -ne $dk.powerOnHours) { Write-Field 'Jam nyala' ("{0} jam" -f $dk.powerOnHours) }
        if ($null -ne $dk.readErrors -and $dk.readErrors -gt 0) {
            Write-Field 'Error baca' $dk.readErrors 'Yellow'
        }
        Write-Ui ''
    }

    if ($d.volumes.Count -gt 0) {
        Write-Ui '  Partisi' 'White'
        Write-Ui ('  {0,-5}{1,-16}{2,13}{3,13}{4,9}' -f '', 'Nama', 'Total', 'Bebas', 'Sisa') 'DarkGray'
        $peringatan = @()
        foreach ($v in $d.volumes) {
            $pct = 0
            if ($v.sizeBytes -gt 0) { $pct = [math]::Round($v.freeBytes / $v.sizeBytes * 100, 1) }
            $warna = 'Gray'
            if ($pct -lt 10) { $warna = 'Red'; $peringatan += ('{0} tinggal {1}%' -f $v.letter, [int]$pct) }
            elseif ($pct -lt 20) { $warna = 'Yellow'; $peringatan += ('{0} tinggal {1}%' -f $v.letter, [int]$pct) }
            else { $warna = 'Green' }
            $label = if ($v.label) { $v.label } else { '-' }
            Write-Ui ('  {0,-5}{1,-16}{2,13}{3,13}{4,9}' -f ($v.letter + ':'), (Potong $label 16), (Format-Size $v.sizeBytes), (Format-Size $v.freeBytes), ("$pct%")) $warna
        }
        Write-Ui ''
        if ($peringatan.Count -gt 0) {
            Write-Ui ('  Partisi kritis: ' + ($peringatan -join ', ') + '.') 'Yellow'
            Write-Saran 'klik kanan drive di>This PC > Properties > Clean Up untuk melepas file sistem, atau bersihkan cache lewat menu [1].'
        }
    }
    Write-Ui '  Suhu dan keausan hanya dilaporkan sebagian firmware. Kolom kosong = tidak tersedia.' 'DarkGray'
    Write-Ui ''
    Pause-Menu
}

# ============================ 4. LEFTOVER ===================================
function Get-LeftoverRoots {
    $roots = @(
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        $env:ProgramData,
        (Join-Path $env:USERPROFILE 'AppData\Roaming'),
        (Join-Path $env:USERPROFILE 'AppData\Local'),
        (Join-Path $env:USERPROFILE 'AppData\Local\Programs')
    )
    return @($roots | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
}

function Get-InstalledApps {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $hasil = @()
    foreach ($p in $paths) {
        $props = Get-ItemProperty -Path $p -ErrorAction SilentlyContinue
        foreach ($e in $props) {
            if (-not $e) { continue }
            if (-not $e.DisplayName) { continue }
            $loc = $e.InstallLocation
            $exe = Get-PathFromUninstallString -String $e.UninstallString
            if (-not $loc -and $exe) {
                $dir = Split-Path $exe -Parent
                if ($dir -and $dir -notmatch '(?i)^c:\\windows') { $loc = $dir }
            }
            $hasil += [pscustomobject]@{
                Name = $e.DisplayName
                NormName = ConvertTo-Norm $e.DisplayName
                Location = $loc
                UninstallExe = $exe
                RegPSPath = $e.PSPath
            }
        }
    }
    return @($hasil)
}

function Get-StartMenuShortcutTargets {
    $targets = @()
    try {
        $sh = New-Object -ComObject WScript.Shell
        $roots = @(
            (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu'),
            (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu')
        )
        foreach ($r in $roots) {
            if (-not (Test-Path -LiteralPath $r)) { continue }
            foreach ($l in (Get-ChildItem -LiteralPath $r -Recurse -Filter *.lnk -ErrorAction SilentlyContinue)) {
                try {
                    $t = $sh.CreateShortcut($l.FullName).TargetPath
                    if ($t) { $targets += $t.ToLower() }
                } catch { }
            }
        }
    } catch { }
    return @($targets)
}

function Test-FolderInUse {
    param([string]$Folder, $Apps, [string[]]$ProcPaths, [string[]]$LnkTargets)
    $lf = $Folder.TrimEnd('\').ToLower()
    foreach ($pp in $ProcPaths) { if ($pp -and $pp.StartsWith($lf)) { return $true } }
    foreach ($t in $LnkTargets) { if ($t -and ($t -eq $lf -or $t.StartsWith($lf + '\'))) { return $true } }
    $nFold = ConvertTo-Norm (Split-Path $Folder -Leaf)
    foreach ($a in $Apps) {
        if ($a.Location) {
            $loc = $a.Location.TrimEnd('\').ToLower()
            if ($loc -and $loc.Length -gt 3) {
                if ($loc -eq $lf -or $loc.StartsWith($lf + '\') -or $lf.StartsWith($loc + '\')) { return $true }
            }
        }
        $nApp = $a.NormName
        if (-not $nApp) { continue }
        if ($nFold -eq $nApp) { return $true }
        if ($nApp.Length -ge 5 -and $nFold.Length -ge 4) {
            if ($nApp.Contains($nFold) -or $nFold.Contains($nApp)) { return $true }
        }
    }
    return $false
}

function Get-LeftoverScanData {
    $apps = Get-InstalledApps
    $procPaths = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path } | ForEach-Object { $_.Path.ToLower() })
    $lnkTargets = Get-StartMenuShortcutTargets
    $cands = @()
    foreach ($root in (Get-LeftoverRoots)) {
        foreach ($d in (Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue)) {
            $lname = $d.Name.ToLower()
            if ($script:LeftoverExclude -contains $lname) { continue }
            if ($lname -like 'regid.*') { continue }
            if (Test-FolderInUse -Folder $d.FullName -Apps $apps -ProcPaths $procPaths -LnkTargets $lnkTargets) { continue }
            $sz = Get-FolderSize -Path $d.FullName
            $cands += [pscustomobject]@{ path = $d.FullName; name = $d.Name; sizeBytes = [int64]$sz }
        }
    }
    $cands = @($cands | Sort-Object -Property sizeBytes -Descending)
    $broken = @()
    foreach ($a in ($apps | Where-Object { $_.UninstallExe -and -not (Test-Path -LiteralPath $_.UninstallExe) } | Sort-Object -Property UninstallExe -Unique)) {
        $broken += [pscustomobject]@{ name = $a.Name; uninstallExe = $a.UninstallExe; regPsPath = $a.RegPSPath }
    }
    return [pscustomobject]@{ candidates = @($cands); broken = @($broken) }
}

function Test-AllowedLeftoverPath { param([string]$Path)
    $p = $Path.TrimEnd('\').ToLower()
    if ($p.Length -lt 4) { return $false }
    $roots = Get-LeftoverRoots
    $dalamRoot = $false
    foreach ($r in $roots) {
        $rl = $r.TrimEnd('\').ToLower()
        if ($p -eq $rl) { return $false }
        if ($p.StartsWith($rl + '\')) { $dalamRoot = $true }
    }
    if (-not $dalamRoot) { return $false }
    $nama = (Split-Path $p -Leaf)
    if ($script:LeftoverExclude -contains $nama) { return $false }
    if ($nama -like 'regid.*') { return $false }
    return $true
}

function Invoke-DeleteLeftover {
    param([string[]]$Paths = @(), [string[]]$RegKeys = @())
    $del = @()
    foreach ($p in $Paths) {
        $ok = $false; $err = ''
        $norm = $p.Trim()
        if ($norm.Length -lt 4) { $err = 'Path tidak valid' }
        elseif (-not (Test-Path -LiteralPath $norm)) { $err = 'Folder tidak ditemukan' }
        elseif (-not (Test-AllowedLeftoverPath -Path $norm)) { $err = 'Ditolak: di luar lokasi yang diizinkan / folder sistem' }
        else {
            $sz = Get-FolderSize -Path $norm
            if (Remove-ToRecycleBin -Path $norm) {
                $ok = $true
                Write-Log ('HAPUS LEFTOVER {0} ({1})' -f $norm, (Format-Size $sz))
            } else { $err = 'Gagal menghapus (folder terkunci?)' }
        }
        $del += [pscustomobject]@{ path = $norm; ok = $ok; error = $err }
    }
    $reg = @()
    $regRe = '^Microsoft\.PowerShell\.Core\\Registry::HKEY_(LOCAL_MACHINE|CURRENT_USER)\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\[^\\]+$'
    foreach ($k in $RegKeys) {
        $ok = $false; $err = ''
        $norm = $k.Trim()
        if ($norm -match $regRe) {
            try {
                $hkm = ($norm -split '::', 2)[1]
                $hkForm = $hkm -replace '^HKEY_LOCAL_MACHINE', 'HKLM'
                $hkForm = $hkForm -replace '^HKEY_CURRENT_USER', 'HKCU'
                $bf = Join-Path $script:BackupDir ('uninstall-' + (Get-Date -Format 'yyyyMMddHHmmssfff') + '.reg')
                & reg.exe export $hkForm $bf /y 2>$null | Out-Null
                Remove-Item -LiteralPath $norm -Recurse -Force -ErrorAction Stop
                $ok = $true
                Write-Log ('HAPUS ENTRY UNINSTALL {0} (backup: {1})' -f $hkm, $bf)
            } catch { $err = $_.Exception.Message }
        } else { $err = 'Key registry tidak valid / di luar area Uninstall' }
        $reg += [pscustomobject]@{ key = $norm; ok = $ok; error = $err }
    }
    return [pscustomobject]@{ deleted = @($del); regRemoved = @($reg) }
}

function Show-LeftoverInteractive {
    Show-Banner
    Write-Section 'CEK SISA FILE APLIKASI (LEFTOVER)'
    Write-Ui '  Memindai aplikasi terinstal, folder program, shortcut, dan proses berjalan...' 'Gray'
    Write-Ui '  Deteksi sisa folder-leftover berbasis heuristik. Periksa ulang sebelum menghapus.' 'DarkGray'
    $data = Get-LeftoverScanData
    Write-Ui ''
    if ($data.candidates.Count -eq 0) {
        Write-Ui '  Tidak ditemukan sisa folder aplikasi. Sistem bersih.' 'Green'
    } else {
        $total = [int64]0
        foreach ($c in $data.candidates) { $total += $c.sizeBytes }
        Write-Ui ('  {0} folder diduga sisa aplikasi, total {1}' -f $data.candidates.Count, (Format-Size $total)) 'Yellow'
        Write-Ui ''
        $no = 0
        foreach ($c in $data.candidates) {
            $no++
            $short = $c.path.Replace($env:USERPROFILE, '~')
            Write-Ui ('  {0,3}. {1}' -f $no, $c.name) 'White'
            Write-Ui ('       {0,10}   {1}' -f (Format-Size $c.sizeBytes), $short) 'DarkGray'
        }
        Write-Ui ''
        $sel = Read-Host '  Nomor folder yang mau dihapus (contoh: 1,3-5, Enter = batal)'
        $idx = Get-SelectedIndexes -Pilihan $sel -Max $data.candidates.Count
        if ($idx.Count -gt 0) {
            $paths = @()
            foreach ($i in $idx) { $paths += $data.candidates[$i - 1].path }
            if (Ask-Confirm ("Pindahkan {0} folder ke Recycle Bin?" -f $paths.Count)) {
                $hsl = Invoke-DeleteLeftover -Paths $paths -RegKeys @()
                $okN = 0; $failN = 0
                foreach ($r in $hsl.deleted) {
                    if ($r.ok) { $okN++; Write-Ui ('    Terhapus : {0}' -f $r.path) 'Green' }
                    else { $failN++; Write-Ui ('    Gagal    : {0} ({1})' -f $r.path, $r.error) 'Red' }
                }
                $w = if ($failN -gt 0) { 'Yellow' } else { 'Green' }
                Write-Ui ("  Selesai: {0} terhapus, {1} gagal." -f $okN, $failN) $w
            } else { Write-Ui '  Dibatalkan.' 'DarkGray' }
        }
    }
    if ($data.broken.Count -gt 0) {
        Write-Ui ''
        Write-Ui '  Entri uninstall tidak valid (uninstaller sudah hilang):' 'Yellow'
        $no = 0
        foreach ($b in $data.broken) {
            $no++
            Write-Ui ('  {0,3}. {1}' -f $no, $b.name) 'White'
            Write-Ui ('       {0}' -f $b.uninstallExe) 'DarkGray'
        }
        Write-Ui ''
        $sel = Read-Host '  Nomor entri registry yang mau dibersihkan (Enter = batal)'
        $idx = Get-SelectedIndexes -Pilihan $sel -Max $data.broken.Count
        if ($idx.Count -gt 0) {
            if (Ask-Confirm ("Bersihkan {0} entri registry? Backup ke logs\backup dulu." -f $idx.Count)) {
                $regKeys = @()
                foreach ($i in $idx) { $regKeys += $data.broken[$i - 1].regPsPath }
                $hsl = Invoke-DeleteLeftover -Paths @() -RegKeys $regKeys
                $okN = 0; $failN = 0
                foreach ($r in $hsl.regRemoved) {
                    if ($r.ok) { $okN++ } else { $failN++; Write-Ui ('    Gagal: {0}' -f $r.error) 'Red' }
                }
                $w = if ($failN -gt 0) { 'Yellow' } else { 'Green' }
                Write-Ui ("  Selesai: {0} dibersihkan, {1} gagal." -f $okN, $failN) $w
            } else { Write-Ui '  Dibatalkan.' 'DarkGray' }
        }
    }
    Write-Ui ''
    Pause-Menu
}

# ============================ 5. SUHU CPU ===================================
function Convert-Tentakelvin { param($Nilai)
    if ($null -eq $Nilai -or $Nilai -le 0) { return $null }
    $c = ($Nilai / 10.0) - 273.15
    if ($c -lt -20 -or $c -gt 150) {
        $c2 = $Nilai - 273.15
        if ($c2 -ge -20 -and $c2 -le 150) { return [math]::Round($c2, 1) }
        return $null
    }
    return [math]::Round($c, 1)
}

function Get-TempReadings {
    $hasil = @()
    try {
        $tz = Get-CimInstance -Namespace 'root\wmi' -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop
        foreach ($z in $tz) {
            $c = Convert-Tentakelvin $z.CurrentTemperature
            if ($null -ne $c) {
                $nm = 'Thermal Zone'
                if ($z.InstanceName) { $nm = ('Thermal Zone ({0})' -f $z.InstanceName) }
                $hasil += [pscustomobject]@{ Source = $nm; Celsius = $c }
            }
        }
    } catch { }
    if ($hasil.Count -eq 0) {
        try {
            $perf = Get-CimInstance -Namespace 'root\cimv2' -ClassName Win32_PerfFormattedData_Counters_ThermalZoneInformation -ErrorAction Stop
            foreach ($z in $perf) {
                $c = Convert-Tentakelvin $z.Temperature
                if ($null -ne $c) {
                    $nm = 'Thermal Zone'
                    if ($z.Name) { $nm = ('Thermal Zone ({0})' -f $z.Name) }
                    $hasil += [pscustomobject]@{ Source = $nm; Celsius = $c }
                }
            }
        } catch { }
    }
    try {
        foreach ($p in (Get-PhysicalDisk -ErrorAction SilentlyContinue)) {
            $rel = $null
            try { $rel = $p | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue } catch { }
            if ($rel -and $rel.Temperature) {
                $c = Convert-DiskTemp $rel.Temperature
                if ($null -ne $c) { $hasil += [pscustomobject]@{ Source = ('Disk: {0}' -f $p.FriendlyName); Celsius = $c } }
            }
        }
    } catch { }
    return @($hasil)
}

function Get-CpuData {
    $load = $null
    $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue
    if ($cpu) { $load = ($cpu | Measure-Object -Property LoadPercentage -Average).Average }
    return [pscustomobject]@{ cpuLoad = $load; readings = @(Get-TempReadings) }
}

function Show-CpuTemperature {
    param([switch]$NonStop)
    Show-Banner
    Write-Section 'MONITORING SUHU CPU'
    do {
        $baca = Get-TempReadings
        $load = $null
        $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue
        if ($cpu) { $load = ($cpu | Measure-Object -Property LoadPercentage -Average).Average }
        if (-not $baca -or $baca.Count -eq 0) {
            Write-Ui '  Komputer ini tidak melaporkan data suhu lewat WMI/ACPI.' 'Yellow'
            Write-Ui '  Yang bisa dicoba:' 'White'
            Write-Ui '    - Jalankan sebagai Administrator, sensor thermal butuh akses lebih'
            Write-Ui '    - Pasang driver OEM laptop/desktop, sering sensor disembunyikan'
            Write-Ui '    - Alternatif gratis yang selalu bisa baca: HWiNFO64 / Core Temp'
            if (-not $NonStop) { Pause-Menu }
            return
        }
        Clear-Screen
        Show-Banner
        Write-Section 'MONITORING SUHU'
        Write-Ui ('  Beban CPU: {0} %' -f $(if ($null -ne $load) { $load } else { 'tidak terbaca' }))
        Write-Ui ''
        $panas = $false
        foreach ($b in $baca) {
            $warna = 'Green'
            if ($b.Celsius -ge 80) { $warna = 'Red'; $panas = $true } elseif ($b.Celsius -ge 60) { $warna = 'Yellow' }
            Write-Ui ('  {0,-40}{1,8} C' -f $b.Source, $b.Celsius) $warna
        }
        Write-Ui ''
        Write-Ui '  Acuan: di bawah 60 C aman | 60-80 C hangat | di atas 80 C panas' 'DarkGray'
        if ($panas) { Write-Saran 'suhu di atas 80 C: bersihkan debu kipas, pastikan jalur udara tidak tertutup, cek thermal paste kalau sudah 2 tahun.' }
        if (-not $NonStop) { break }
        Write-Ui '  Refresh tiap 3 detik - tekan Q untuk keluar...' 'DarkGray'
        $selesai = $false
        for ($w = 0; $w -lt 15; $w++) {
            Start-Sleep -Milliseconds 200
            try {
                if ([Console]::KeyAvailable) {
                    $k = [Console]::ReadKey($true)
                    if ($k.Key -eq 'Q') { $selesai = $true; break }
                }
            } catch { }
        }
        if ($selesai) { break }
        Clear-Screen
        Show-Banner
        Write-Section 'MONITORING SUHU CPU'
    } while ($true)
    if (-not $NonStop) { Pause-Menu }
}

# ============================ 6. CACHE BROWSER ==============================
function Get-BrowserCacheItems {
    $items = @()
    $browsers = @(
        @{ Browser = 'Google Chrome'; Base = (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data'); Proc = 'chrome' },
        @{ Browser = 'Microsoft Edge'; Base = (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data'); Proc = 'msedge' }
    )
    foreach ($b in $browsers) {
        if (-not (Test-Path -LiteralPath $b.Base)) { continue }
        $subs = @('Cache', 'Code Cache', 'GPUCache', 'Service Worker\CacheStorage', 'Service Worker\ScriptCache')
        foreach ($prof in (Get-ChildItem -LiteralPath $b.Base -Directory -ErrorAction SilentlyContinue)) {
            if (-not ($prof.Name -eq 'Default' -or $prof.Name -like 'Profile *')) { continue }
            foreach ($s in $subs) {
                $p = Join-Path $prof.FullName $s
                if (Test-Path -LiteralPath $p) { $items += [pscustomobject]@{ Browser = $b.Browser; Path = $p; Proc = $b.Proc } }
            }
        }
    }
    $ff = Join-Path $env:LOCALAPPDATA 'Mozilla\Firefox\Profiles'
    if (Test-Path -LiteralPath $ff) {
        foreach ($prof in (Get-ChildItem -LiteralPath $ff -Directory -ErrorAction SilentlyContinue)) {
            foreach ($s in @('cache2', 'startupCache', 'shader-cache')) {
                $p = Join-Path $prof.FullName $s
                if (Test-Path -LiteralPath $p) { $items += [pscustomobject]@{ Browser = 'Mozilla Firefox'; Path = $p; Proc = 'firefox' } }
            }
        }
    }
    return @($items)
}

function Invoke-BrowserClean {
    $results = @(); $total = [int64]0; $failed = 0
    foreach ($i in (Get-BrowserCacheItems)) {
        $status = 'ok'; $freed = [int64]0
        if (Get-Process -Name $i.Proc -ErrorAction SilentlyContinue) {
            $results += [pscustomobject]@{ browser = $i.Browser; path = $i.Path; freedBytes = 0; status = 'dilewati - browser sedang berjalan' }
            continue
        }
        $h = Remove-ChildrenSafe -Path $i.Path
        $freed = [int64]$h.Byte
        if ($h.Gagal -gt 0) { $status = ('sebagian gagal ({0} file terkunci)' -f $h.Gagal); $failed += $h.Gagal }
        elseif ($freed -eq 0) { $status = 'sudah bersih' }
        $total += $freed
        Write-Log ('BROWSER CACHE {0} -> {1}' -f $i.Path, (Format-Size $freed))
        $results += [pscustomobject]@{ browser = $i.Browser; path = $i.Path; freedBytes = $freed; status = $status }
    }
    return [pscustomobject]@{ freedBytes = $total; failedCount = $failed; items = @($results) }
}

function Show-BrowserInteractive {
    Show-Banner
    Write-Section 'BERSIHKAN CACHE BROWSER'
    Write-Ui '  Cache browser yang sedang dipakai tidak bisa dihapus.' 'Yellow'
    Write-Ui '  Tutup Chrome, Edge, dan Firefox dulu, lalu lanjut.' 'DarkGray'
    Write-Ui ''
    if (-not (Ask-Confirm 'Lanjutkan membersihkan cache browser?')) { Write-Ui '  Dibatalkan.' 'DarkGray'; Pause-Menu; return }
    Write-Ui '  Membersihkan...' 'Gray'
    $hsl = Invoke-BrowserClean

    if (-not $hsl.items -or $hsl.items.Count -eq 0) {
        Write-Ui ''
        Write-Ui '  Tidak ada cache browser yang ditemukan.' 'Yellow'
        Write-Ui '  Kalau browser sudah dipakai, coba tutup dulu lalu ulangi.' 'DarkGray'
        Write-Ui ''
        Pause-Menu
        return
    }

    Write-Ui ''
    foreach ($it in $hsl.items) {
        $w = 'Green'
        if ($it.status -like '*gagal*' -or $it.status -like '*terkunci*') { $w = 'Yellow' }
        Write-Ui ('  {0}' -f $it.browser) 'White'
        Write-Field 'Status' $it.status $w
        Write-Field 'Dibebaskan' (Format-Size $it.freedBytes)
        Write-Ui ('    ' + $it.path) 'DarkGray'
        Write-Ui ''
    }
    Write-Ui ('  Total dibebaskan: {0}' -f (Format-Size $hsl.freedBytes)) 'Green'
    if ($hsl.failedCount -gt 0) { Write-Ui ('  {0} file terkunci dilewati.' -f $hsl.failedCount) 'Yellow' }
    Write-Ui ''
    Pause-Menu
}

# ============================ 7. STARTUP ====================================
function Get-StartupData {
    $items = @()
    $regSources = @(
        @{ Lokasi = 'Registry HKLM (64-bit)'; Key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' },
        @{ Lokasi = 'Registry HKLM (32-bit)'; Key = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run' },
        @{ Lokasi = 'Registry HKCU';          Key = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' }
    )
    foreach ($s in $regSources) {
        $k = Get-Item -LiteralPath $s.Key -ErrorAction SilentlyContinue
        if (-not $k) { continue }
        foreach ($vn in $k.GetValueNames()) {
            $nm = $vn
            if ([string]::IsNullOrEmpty($nm)) { $nm = '(Default)' }
            $items += [pscustomobject]@{
                type = 'Reg'; location = $s.Lokasi; name = $nm
                command = "$($k.GetValue($vn))"; keyPath = $s.Key; valueName = "$vn"; filePath = ''
            }
        }
    }
    $folders = @(
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\StartUp')
    )
    foreach ($fd in $folders) {
        if (-not (Test-Path -LiteralPath $fd)) { continue }
        foreach ($f in (Get-ChildItem -LiteralPath $fd -File -ErrorAction SilentlyContinue)) {
            $items += [pscustomobject]@{
                type = 'File'; location = 'Folder Startup'; name = $f.BaseName
                command = $f.FullName; keyPath = ''; valueName = ''; filePath = $f.FullName
            }
        }
    }
    return [pscustomobject]@{ items = @($items) }
}

function Invoke-DisableStartup {
    param([string[]]$Targets = @())
    $res = @()
    $validKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    )
    foreach ($t in $Targets) {
        $parts = $t.Split('|')
        $ok = $false; $err = ''; $backup = $null
        if ($parts.Count -ge 3 -and $parts[0] -ieq 'Reg') {
            $key = $parts[1].Trim(); $vn = $parts[2].Trim()
            if ($validKeys -notcontains $key) { $err = 'Key tidak diizinkan' }
            elseif (-not (Get-ItemProperty -LiteralPath $key -Name $vn -ErrorAction SilentlyContinue)) { $err = 'Value tidak ditemukan' }
            elseif ($key -like 'HKLM:*' -and -not $script:IsAdmin) { $err = 'Butuh akses Administrator' }
            else {
                try {
                    $bf = Join-Path $script:BackupDir ('startup-' + (Get-Date -Format 'yyyyMMddHHmmssfff') + '.reg')
                    & reg.exe export ($key -replace ':', '') $bf /y 2>$null | Out-Null
                    Remove-ItemProperty -LiteralPath $key -Name $vn -Force -ErrorAction Stop
                    $ok = $true; $backup = $bf
                    Write-Log ('STARTUP NONAKTIF {0}\{1} (backup: {2})' -f $key, $vn, $bf)
                } catch { $err = $_.Exception.Message }
            }
            $res += [pscustomobject]@{ target = $t; ok = $ok; error = $err; backup = $backup }
        } elseif ($parts.Count -ge 2 -and $parts[0] -ieq 'File') {
            $f = $parts[1].Trim()
            $validDirs = @(
                (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup').ToLower(),
                (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\StartUp').ToLower()
            )
            $fd = ''
            if ($f) { $fd = (Split-Path $f -Parent).ToLower() }
            if (-not (Test-Path -LiteralPath $f)) { $err = 'File tidak ditemukan' }
            elseif ($validDirs -notcontains $fd) { $err = 'Lokasi tidak diizinkan' }
            else {
                try {
                    $dest = Join-Path $script:BackupDir ((Get-Date -Format 'yyyyMMddHHmmssfff') + '-' + (Split-Path $f -Leaf))
                    Move-Item -LiteralPath $f -Destination $dest -Force -ErrorAction Stop
                    $ok = $true; $backup = $dest
                    Write-Log ('STARTUP NONAKTIF (file) {0} -> {1}' -f $f, $dest)
                } catch { $err = $_.Exception.Message }
            }
            $res += [pscustomobject]@{ target = $t; ok = $ok; error = $err; backup = $backup }
        } else {
            $res += [pscustomobject]@{ target = $t; ok = $false; error = 'Format target tidak valid'; backup = $null }
        }
    }
    return [pscustomobject]@{ results = @($res) }
}

function Show-StartupInteractive {
    Show-Banner
    Write-Section 'KELOLA APLIKASI STARTUP'
    $data = Get-StartupData
    if ($data.items.Count -eq 0) {
        Write-Ui '  Tidak ada aplikasi startup terdaftar.'
        Pause-Menu
        return
    }
    Write-Ui '  Kolom sumber: Reg = registry, File = folder Startup. Yang paling lambat buka adalah' 'DarkGray'
    Write-Ui '  kandidat utama untuk dimatikan. Item inti Windows sebaiknya dibiarkan.' 'DarkGray'
    Write-Ui ''
    $no = 0
    foreach ($it in $data.items) {
        $no++
        $cmd = $it.command
        if ($cmd -and $cmd.Length -gt 58) { $cmd = $cmd.Substring(0, 55) + '...' }
        Write-Ui ('  {0,3}. [{1}] {2}' -f $no, $it.type, $it.name) 'White'
        Write-Ui ('       cmd  : {0}' -f $cmd) 'DarkGray'
        Write-Ui ('       dari : {0}' -f $it.location) 'DarkGray'
    }
    Write-Ui ''
    $sel = Read-Host '  Nomor yang mau dinonaktifkan (pisah koma/spasi, Enter = batal)'
    $idx = Get-SelectedIndexes -Pilihan $sel -Max $data.items.Count
    if ($idx.Count -eq 0) { Write-Ui '  Tidak ada yang diubah.' 'DarkGray'; Pause-Menu; return }
    if (-not (Ask-Confirm ("Nonaktifkan {0} item? Backup ke logs\backup dulu." -f $idx.Count))) {
        Write-Ui '  Dibatalkan.' 'DarkGray'; Pause-Menu; return
    }
    $targets = @()
    foreach ($i in $idx) {
        $it = $data.items[$i - 1]
        if ($it.type -eq 'Reg') { $targets += ('Reg|{0}|{1}' -f $it.keyPath, $it.valueName) }
        else { $targets += ('File|{0}' -f $it.filePath) }
    }
    $hsl = Invoke-DisableStartup -Targets $targets
    $okN = 0; $failN = 0
    foreach ($r in $hsl.results) {
        if ($r.ok) { $okN++ } else { $failN++; Write-Ui ('    Gagal: {0} ({1})' -f $r.target, $r.error) 'Red' }
    }
    $warna = if ($failN -gt 0) { 'Yellow' } else { 'Green' }
    Write-Ui ('  Selesai: {0} dinonaktifkan, {1} gagal.' -f $okN, $failN) $warna
    Write-Ui '  Dikembalikan manual dari file .reg di logs\backup.' 'DarkGray'
    Write-Ui ''
    Pause-Menu
}

# ============================ 8. RINGKASAN SISTEM ===========================
function Get-SummaryData {
    $os  = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
    $cs  = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    $ramTotal = [int64]0; $ramUsed = [int64]0; $upText = ''
    if ($os) {
        $ramTotal = [int64]$os.TotalVisibleMemorySize * 1KB
        $ramUsed  = ([int64]$os.TotalVisibleMemorySize - [int64]$os.FreePhysicalMemory) * 1KB
        $up = (Get-Date) - $os.LastBootUpTime
        $upText = ('{0} hari {1} jam {2} menit' -f $up.Days, $up.Hours, $up.Minutes)
    }
    $vols = @()
    foreach ($v in (Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter })) {
        if (-not $v.Size) { continue }
        $vols += [pscustomobject]@{
            letter = "$($v.DriveLetter)"; label = "$($v.FileSystemLabel)"
            sizeBytes = [int64]$v.Size; freeBytes = [int64]$v.SizeRemaining
        }
    }
    $bat = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
    $tops = @()
    foreach ($pr in (Get-Process -ErrorAction SilentlyContinue | Sort-Object -Property WS -Descending | Select-Object -First 5)) {
        $tops += [pscustomobject]@{ name = $pr.ProcessName; wsBytes = [int64]$pr.WS }
    }
    return [pscustomobject]@{
        os = "$($os.Caption)"; arch = "$($os.OSArchitecture)"; computer = $env:COMPUTERNAME
        manufacturer = "$($cs.Manufacturer)"; model = "$($cs.Model)"
        cpuName = "$($cpu.Name)"; cores = $cpu.NumberOfCores; threads = $cpu.NumberOfLogicalProcessors
        cpuLoad = $cpu.LoadPercentage
        ramTotalBytes = $ramTotal; ramUsedBytes = $ramUsed; uptimeText = $upText
        volumes = @($vols); batteryPresent = [bool]$bat; batteryPercent = $bat.EstimatedChargeRemaining
        topProcesses = @($tops); isAdmin = $script:IsAdmin
    }
}

function Show-SummaryInteractive {
    Show-Banner
    Write-Section 'RINGKASAN KESEHATAN SISTEM'
    $d = Get-SummaryData
    Write-Field 'Sistem' ("{0} ({1})" -f $d.os, $d.arch)
    Write-Field 'Komputer' ("{0} {1}" -f $d.manufacturer, $d.model).Trim()
    Write-Field 'CPU' $d.cpuName
    Write-Field 'Core / thread' ("{0} / {1}" -f $d.cores, $d.threads)
    if ($null -ne $d.cpuLoad) { Write-Field 'Beban CPU' ("{0} %" -f $d.cpuLoad) }
$ramTinggi = $false
    if ($d.ramTotalBytes -gt 0) {
        $pct = [math]::Round($d.ramUsedBytes / $d.ramTotalBytes * 100, 0)
        Write-Field 'RAM terpakai' ("{0} dari {1} ({2}%)" -f (Format-Size $d.ramUsedBytes), (Format-Size $d.ramTotalBytes), $pct)
        if ($pct -ge 85) { $ramTinggi = $true; Write-Ui ("  RAM sudah {0}% penuh." -f $pct) 'Yellow' }
    }
    Write-Field 'Uptime' $d.uptimeText
    if ($d.batteryPresent) { Write-Field 'Baterai' ("{0} %" -f $d.batteryPercent) }

    Write-Ui ''
    Write-Ui '  Partisi' 'White'
    Write-Ui ('  {0,-5}{1,-16}{2,13}{3,13}{4,9}' -f '', 'Nama', 'Total', 'Bebas', 'Sisa') 'DarkGray'
    $tipis = @()
    foreach ($v in $d.volumes) {
        $pct = 0
        if ($v.sizeBytes -gt 0) { $pct = [math]::Round($v.freeBytes / $v.sizeBytes * 100, 1) }
        $warna = 'Gray'
        if ($pct -lt 10) { $warna = 'Red'; $tipis += ('{0} tinggal {1}%' -f $v.letter, [int]$pct) }
        elseif ($pct -lt 20) { $warna = 'Yellow'; $tipis += ('{0} tinggal {1}%' -f $v.letter, [int]$pct) }
        else { $warna = 'Green' }
        $label = if ($v.label) { $v.label } else { '-' }
        Write-Ui ('  {0,-5}{1,-16}{2,13}{3,13}{4,9}' -f ($v.letter + ':'), (Potong $label 16), (Format-Size $v.sizeBytes), (Format-Size $v.freeBytes), ("$pct%")) $warna
    }

    if ($d.topProcesses.Count -gt 0) {
        Write-Ui ''
        Write-Ui '  Proses dengan RAM terbesar' 'White'
        Write-Ui ('  {0,-32}{1,12}' -f 'Proses', 'RAM') 'DarkGray'
        foreach ($p in $d.topProcesses) {
            Write-Ui ('  {0,-32}{1,12}' -f (Potong $p.name 32), (Format-Size $p.wsBytes))
        }
    }
    Write-Ui ''
    if ($tipis.Count -gt 0) {
        Write-Ui ('  Perlu perhatian: ' + ($tipis -join ', ') + '.') 'Yellow'
        Write-Saran 'partisi itu paling aman dibersihkan lewat menu [1], atau Settings > System > Storage > Temporary files.'
    }
    if ($ramTinggi) {
        $pemboros = ($d.topProcesses | Select-Object -First 3 | ForEach-Object { $_.name }) -join ', '
        Write-Saran ("tutup yang tidak dipakai. Yang paling besar sekarang: {0}." -f $pemboros)
    }
    Write-Ui ''
    Pause-Menu
}

# ============================ 9. POWER PLAN =================================
function Get-PowerPlanData {
    $guidRe = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
    $aktif = ''
    $cur = (& powercfg /getactivescheme 2>$null)
    if ($cur) {
        $m = [regex]::Match(($cur -join ' '), $guidRe)
        if ($m.Success) { $aktif = $m.Value.ToLower() }
    }
    $plans = @(); $i = 0
    $lines = (& powercfg /list 2>$null)
    foreach ($ln in $lines) {
        $m2 = [regex]::Match($ln, $guidRe)
        if (-not $m2.Success) { continue }
        $g = $m2.Value.ToLower()
        $tail = $ln.Substring($m2.Index + $m2.Length)
        $nama = ''
        if ($tail -match '\(([^)]*)\)') { $nama = $Matches[1] }
        else { $parts = $tail -split ':'; $nama = $parts[-1].Trim() }
        if ([string]::IsNullOrWhiteSpace($nama)) { $nama = '(tanpa nama)' }
        $i++
        $plans += [pscustomobject]@{ no = $i; guid = $g; name = $nama; active = ($g -eq $aktif) }
    }
    return [pscustomobject]@{ activeGuid = $aktif; plans = @($plans) }
}

function Invoke-SetPowerPlan {
    param([string]$Guid)
    $guidRe = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    if ($Guid -notmatch $guidRe) {
        return [pscustomobject]@{ ok = $false; error = 'GUID tidak valid'; activeGuid = '' }
    }
    if (-not $script:IsAdmin) {
        return [pscustomobject]@{ ok = $false; error = 'Butuh akses Administrator'; activeGuid = '' }
    }
    & powercfg /setactive $Guid 2>$null | Out-Null
    $cur = (& powercfg /getactivescheme 2>$null)
    $m = [regex]::Match(($cur -join ' '), '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
    $ok = ($m.Success -and ($m.Value.ToLower() -eq $Guid.ToLower()))
    if ($ok) { Write-Log ('POWER PLAN -> {0}' -f $Guid) }
    return [pscustomobject]@{ ok = $ok; error = ''; activeGuid = $m.Value.ToLower() }
}

function Show-PowerInteractive {
    Show-Banner
    Write-Section 'SKEMA DAYA (POWER PLAN)'
    $data = Get-PowerPlanData
    if ($data.plans.Count -eq 0) {
        Write-Ui '  Tidak bisa membaca daftar power plan.' 'Yellow'
        Pause-Menu
        return
    }
    foreach ($p in $data.plans) {
        $baris = ('  {0,3}. {1}' -f $p.no, $p.name)
        if ($p.active) { Write-Ui ($baris + '  <- aktif') 'Green' } else { Write-Ui $baris }
    }
    if (-not $script:IsAdmin) { Write-Ui '  Butuh Administrator untuk mengganti skema daya.' 'Yellow' }
    Write-Ui ''
    $sel = Read-Host '  Nomor skema yang mau diaktifkan (Enter untuk batal)'
    $idx = Get-SelectedIndexes -Pilihan $sel -Max $data.plans.Count
    if ($idx.Count -eq 0) { Write-Ui '  Dibatalkan.' 'DarkGray'; Pause-Menu; return }
    if ($idx.Count -ne 1) { Write-Ui '  Pilih satu nomor saja.' 'Red'; Pause-Menu; return }
    $p = $data.plans[$idx[0] - 1]
    if ($p.active) { Write-Ui '  Skema itu sudah aktif.' 'DarkGray'; Pause-Menu; return }
    $hsl = Invoke-SetPowerPlan -Guid $p.guid
    if ($hsl.ok) { Write-Ui ('  Skema daya diganti ke: {0}' -f $p.name) 'Green' }
    else { Write-Ui ('  Gagal: {0}' -f $hsl.error) 'Red' }
    Write-Ui ''
    Pause-Menu
}

# ============================ DASHBOARD (NODE) ==============================
function Start-Dashboard {
    Show-Banner
    Write-Section 'DASHBOARD (WEB UI via Node.js)'
    $node = Get-Command node.exe -ErrorAction SilentlyContinue
    if (-not $node) {
        Write-Ui '  Node.js belum terpasang di komputer ini.' 'Yellow'
        Write-Ui '  Install dulu dari https://nodejs.org lalu coba lagi.'
        Pause-Menu
        return
    }
    $jalan = $false
    try {
        $r = Invoke-WebRequest -Uri 'http://127.0.0.1:5599/api/ping' -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
        if ($r.Content -match 'pc-toolkit') { $jalan = $true }
    } catch { }
    if (-not $jalan) {
        Write-Ui '  Menjalankan server dashboard di latar belakang...' 'Gray'
        $srv = Join-Path $PSScriptRoot 'dashboard\server.js'
        Start-Process -FilePath 'node.exe' -ArgumentList ('"' + $srv + '"') -WorkingDirectory (Join-Path $PSScriptRoot 'dashboard') -WindowStyle Hidden | Out-Null
        Start-Sleep -Seconds 2
    }
    Write-Ui '  Membuka browser: http://127.0.0.1:5599' 'Green'
    Write-Ui '  (Dashboard bisa dihentikan lewat tombol "Stop Server" di halaman web)' 'DarkGray'
    try { Start-Process 'http://127.0.0.1:5599' } catch { }
    Pause-Menu
}

# ================================ MENU UTAMA ================================
function Show-Menu {
    Set-Layar
    while ($true) {
        Show-Banner
        Write-Ui '  PERAWATAN' 'White'
        Write-Ui '    [1] Bersihkan cache & file sampah'
        Write-Ui '    [2] Bersihkan cache browser'
        Write-Ui '    [3] Cek & hapus sisa aplikasi'
        Write-Ui ''
        Write-Ui '  KESEHATAN' 'White'
        Write-Ui '    [4] Ringkasan sistem'
        Write-Ui '    [5] Cek baterai'
        Write-Ui '    [6] Cek SSD / HDD'
        Write-Ui '    [7] Monitor suhu CPU'
        Write-Ui ''
        Write-Ui '  PENGATURAN' 'White'
        Write-Ui '    [8] Kelola aplikasi startup'
        Write-Ui '    [9] Skema daya'
        Write-Ui ''
        Write-Ui '  LAIN-LAIN' 'White'
        Write-Ui '    [D] Dashboard web' 'Cyan'
        Write-Ui '    [L] Buka folder log & backup' 'DarkGray'
        Write-Ui '    [0] Keluar'
        Write-Ui ''
        $p = Read-Host '  Pilih'
        if ($null -eq $p) { break }
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $p = $p.Trim()
        switch ($p.ToLower()) {
            '1' { Show-JunkInteractive }
            '2' { Show-BrowserInteractive }
            '3' { Show-LeftoverInteractive }
            '4' { Show-SummaryInteractive }
            '5' { Show-BatteryInteractive }
            '6' { Show-DiskInteractive }
            '7' { Show-CpuTemperature -NonStop }
            '8' { Show-StartupInteractive }
            '9' { Show-PowerInteractive }
            'd' { Start-Dashboard }
            'l' { Start-Process explorer.exe $script:LogDir; Pause-Menu }
            '0' { return }
            default { Write-Ui "  '$p' tidak dikenal." 'Yellow'; Start-Sleep -Milliseconds 700 }
        }
    }
}

# ================================ EKSEKUSI ==================================
switch ($Task) {
    'menu'             { Show-Menu; if (-not $script:Quiet) { Write-Ui '  Sampai jumpa!' 'Cyan' } }
    'junk'             { if ($script:Quiet) { Out-Json (Invoke-JunkClean -IncludeRecycleBin) } else { Show-JunkInteractive } }
    'junk-size'        { Out-Json (Get-JunkSizeData) }
    'battery'          { if ($script:Quiet) { Out-Json (Get-BatteryData) } else { Show-BatteryInteractive } }
    'disk'             { if ($script:Quiet) { Out-Json (Get-DiskData) } else { Show-DiskInteractive } }
    'leftover-scan'    { if ($script:Quiet) { Out-Json (Get-LeftoverScanData) } else { Show-LeftoverInteractive } }
    'delete-leftover'  {
        $lines = Read-StdinLines
        $paths = @(); $regKeys = @()
        foreach ($l in $lines) {
            if ($l.StartsWith('REG::')) { $regKeys += $l.Substring(5) } else { $paths += $l }
        }
        Out-Json (Invoke-DeleteLeftover -Paths $paths -RegKeys $regKeys)
    }
    'cpu'              { if ($script:Quiet) { Out-Json (Get-CpuData) } else { Show-CpuTemperature } }
    'browser'          { if ($script:Quiet) { Out-Json (Invoke-BrowserClean) } else { Show-BrowserInteractive } }
    'startup-list'     { if ($script:Quiet) { Out-Json (Get-StartupData) } else { Show-StartupInteractive } }
    'disable-startup'  { Out-Json (Invoke-DisableStartup -Targets (Read-StdinLines)) }
    'summary'          { if ($script:Quiet) { Out-Json (Get-SummaryData) } else { Show-SummaryInteractive } }
    'power-list'       { if ($script:Quiet) { Out-Json (Get-PowerPlanData) } else { Show-PowerInteractive } }
    'set-power'        { Out-Json (Invoke-SetPowerPlan -Guid $Guid) }
}
