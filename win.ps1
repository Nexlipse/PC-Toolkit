<#
 =============================================================================
  irm christitus.com/win  |  iex   ->   WinForms GUI
 =============================================================================
  Client cukup tempel SATU BARIS di PowerShell (Administrator):

      irm http://ALAMAT-PROVIDER:5700/p/KUNCI/win | iex

  Skrip ini diunduh ke memori lalu dijalankan langsung (tidak ada file .ps1
  di disk sampai folder toolkit benar-benar dibuat).
 =============================================================================
#>

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$ScriptDir = Join-Path $env:LOCALAPPDATA 'PC-Toolkit'
$Kunci     = 'KUNCI'
$Berkas    = @('PC-Toolkit.ps1', 'agent.ps1', 'gui.ps1')

function Tulis { param([string]$m, [string]$w = 'Gray') Write-Host $m -ForegroundColor $w }

# Alamat server tempat skrip ini diunduh. Dipakai untuk ambil file lain.
$Server = 'http://ALAMAT-PROVIDER:5700'

if (-not (Test-Path -LiteralPath $ScriptDir)) {
    New-Item -ItemType Directory -Path $ScriptDir -Force | Out-Null
}
Tulis "Folder: $ScriptDir" 'DarkGray'

$Unauthorized = $false
$wc = New-Object System.Net.WebClient
foreach ($nama in $Berkas) {
    $tujuan = Join-Path $ScriptDir $nama
    try {
        Tulis "Mengambil $nama ..."
        $bytes = $wc.DownloadData("${Server}/files/${nama}?k=${Kunci}")
        [System.IO.File]::WriteAllBytes($tujuan, $bytes)
        Tulis '  ok' 'DarkGray'
    } catch [System.Net.WebException] {
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 401) { $Unauthorized = $true }
        Tulis "  GAGAL: $($_.Exception.Message)" 'Red'
    }
}

if ($Unauthorized) {
    Write-Host ''
    Tulis 'Server menolak permintaan. Kunci panel salah, atau endpoint /files tidak aktif di versi ini.' 'Yellow'
    Tulis 'Per-format yang benar:  irm http://ALAMAT:5700/p/KUNCI/win | iex' 'Yellow'
    exit 1
}

$gui = Join-Path $ScriptDir 'gui.ps1'
if (-not (Test-Path -LiteralPath $gui)) {
    Tulis 'gui.ps1 gagal diunduh, GUI tidak bisa dibuka.' 'Red'
    exit 1
}

$adaToken = Test-Path -LiteralPath (Join-Path $ScriptDir 'agent.token')
if ($adaToken) { Tulis 'Token agent ditemukan, PC ini sudah terdaftar.' 'DarkGray' }

Tulis ''
Tulis 'Menjalankan GUI...' 'Green'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $gui