<#
 =============================================================================
  agent.ps1 - Agent sisi CLIENT untuk PC Toolkit Panel
 -----------------------------------------------------------------------
  Dijalankan di PC milik client. Tidak butuh Node.js / install apa pun,
  hanya Windows PowerShell 5.1 yang sudah ada.

  Pakai:
      .\agent.ps1 -Server "https://pc.example.com:5700" -Code "KODE-ENROLL"

  Setelah enroll berhasil, token disimpan di agent.token dan parameter
  -Code tidak perlu dipakai lagi. Untuk berjalan otomatis:
      .\agent.ps1 -Server "https://pc.example.com:5700"

  Loop: heartbeat ->(if ada task) jalankan -> kirim hasil -> tidur -> ulang.
  Arah koneksi HANYA keluar (outbound). Client tidak perlu port forwarding.
 =============================================================================
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Server,
    [string]$Code = '',
    [int]$IntervalSec = 20,
    [switch]$Sekali            # satu putaran lalu keluar (untuk tes)
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$Root        = $PSScriptRoot
$Engine      = Join-Path $Root 'PC-Toolkit.ps1'
$TokenFile   = Join-Path $Root 'agent.token'

# Task yang boleh dijalankan jarak jauh. Cermin dari ValidateSet di
# PC-Toolkit.ps1 ditambah 'menu' yang dikecualikan karena interaktif.
$TaskBoleh = @(
    'junk-size','junk','battery','disk','cpu','summary',
    'startup-list','disable-startup','leftover-scan','delete-leftover',
    'browser','power-list','set-power'
)

# Task yang menghapus / mengubah -> panel wajib konfirmasi eksplisit.
$TaskBerbahaya = @('junk','delete-leftover','disable-startup','set-power','browser')

$Server = $Server.TrimEnd('/')

function Tulis {
    param([string]$Pesan, [string]$Warna = 'Gray')
    $st = [datetime]::Now.ToString('HH:mm:ss')
    Write-Host ("[{0}] {1}" -f $st, $Pesan) -ForegroundColor $Warna
}

function AmbilToken {
    if (Test-Path -LiteralPath $TokenFile) {
        return (Get-Content -LiteralPath $TokenFile -Raw).Trim()
    }
    return ''
}

function SimpanToken { param([string]$Token)
    Set-Content -LiteralPath $TokenFile -Value $Token -Encoding ASCII
}

# Panggil server. $Body di-hash jadi JSON. Return object @{ ok; status; data }
function Panggil {
    param([string]$Path, $Body = $null, [string]$Token = '')
    $uri = $Server + $Path
    $headers = @{ 'User-Agent' = 'pctoolkit-agent/1.0' }
    if ($Token) { $headers['X-Agent-Token'] = $Token }

    $params = @{
        Uri             = $uri
        Method          = 'Post'
        Headers         = $headers
        TimeoutSec      = 30
        UseBasicParsing = $true
        ErrorAction     = 'Stop'
    }
    if ($null -ne $Body) {
        $params['ContentType'] = 'application/json; charset=utf-8'
        $params['Body'] = [System.Text.Encoding]::UTF8.GetBytes(
            ($Body | ConvertTo-Json -Depth 8 -Compress))
    }

    try {
        $resp = Invoke-RestMethod @params
        return [pscustomobject]@{ ok = $true; status = 200; data = $resp }
    } catch [System.Net.WebException] {
        $st = 0
        $isi = ''
        if ($_.Exception.Response) {
            try { $st = [int]$_.Exception.Response.StatusCode } catch { $st = 0 }
            try {
                $sr = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                $isi = $sr.ReadToEnd(); $sr.Close()
            } catch { $isi = '' }
        }
        return [pscustomobject]@{ ok = $false; status = $st; data = $isi }
    } catch {
        return [pscustomobject]@{ ok = $false; status = 0; data = $_.Exception.Message }
    }
}

function Info-Diri {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
    $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
                [Security.Principal.WindowsBuiltInRole]::Administrator)
    $baterai = $null
    try {
        $bat = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($bat) { $baterai = [int]$bat.EstimatedChargeRemaining }
    } catch { }

    return [ordered]@{
        computer   = $env:COMPUTERNAME
        user       = $env:USERNAME
        os         = if ($os) { $os.Caption } else { 'Windows' }
        build      = if ($os) { $os.BuildNumber } else { $null }
        cpu        = if ($cpu) { $cpu.Name.Trim() } else { $null }
        isAdmin    = [bool]$admin
        batteryPct = $baterai
        agentVer   = '1.0'
        engineMtime = if (Test-Path -LiteralPath $Engine) {
            (Get-Item -LiteralPath $Engine).LastWriteTime.ToString('o')
        } else { $null }
    }
}

function Daftarkan {
    param([string]$Kode)
    Tulis "Mendaftarkan ke $Server ..." 'Yellow'
    $r = Panggil '/agent/enroll' @{ code = $Kode; meta = (Info-Diri) }
    if (-not $r.ok -or -not $r.data.token) {
        Tulis ("Gagal daftar: " + ($r.data | Out-String).Trim()) 'Red'
        return $null
    }
    SimpanToken $r.data.token
    Tulis ("Terdaftar. ID = " + $r.data.id) 'Green'
    return $r.data
}

# Jalankan satu task lewat engine yang sudah ada. Output = JSON engine.
# $Stdin dipakai task yang butuh daftar target (delete-leftover, disable-startup).
function JalankanTask {
    param([string]$TaskName, [string]$Stdin = '', [string]$Guid = '')
    if (-not (Test-Path -LiteralPath $Engine)) {
        return [pscustomobject]@{ ok = $false; error = "Engine tidak ditemukan: $Engine" }
    }
    if ($TaskBoleh -notcontains $TaskName) {
        return [pscustomobject]@{ ok = $false; error = "Task tidak diizinkan: $TaskName" }
    }

    $argumen = @('-NoProfile','-ExecutionPolicy','Bypass','-File', $Engine, '-Task', $TaskName, '-Json')
    if ($TaskName -eq 'junk') { $argumen += '-IncludeRecycleBin' }
    if ($TaskName -eq 'set-power') {
        if (-not $Guid) { return [pscustomobject]@{ ok = $false; error = 'Task set-power butuh GUID skema daya.' } }
        $argumen += @('-Guid', $Guid)
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = ($argumen | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
    $psi.RedirectStandardInput     = $true
    $psi.RedirectStandardOutput    = $true
    $psi.RedirectStandardError     = $true
    $psi.UseShellExecute          = $false
    $psi.CreateNoWindow            = $true
    $psi.WorkingDirectory         = $Root

    $proses = New-Object System.Diagnostics.Process
    $proses.StartInfo = $psi
    [void]$proses.Start()
    if ($Stdin) { $proses.StandardInput.Write($Stdin); $proses.StandardInput.Close() }
    $out = $proses.StandardOutput.ReadToEnd()
    $err = $proses.StandardError.ReadToEnd()
    if (-not $proses.WaitForExit(300000)) {   # 5 menit, sama seperti server.js
        try { $proses.Kill() } catch { }
        return [pscustomobject]@{ ok = $false; error = 'Task melebihi batas 5 menit, dihentikan.' }
    }

    $teks = $out.Trim()
    if ($teks.Contains('{')) { $teks = $teks.Substring($teks.IndexOf('{')) }
    if (-not $teks) {
        return [pscustomobject]@{ ok = $false; error = ("Engine tidak mengeluarkan JSON. stderr: " + $err.Trim()) }
    }
    try {
        $data = $teks | ConvertFrom-Json
        return [pscustomobject]@{ ok = $true; data = $data }
    } catch {
        return [pscustomobject]@{ ok = $false; error = ("Output engine bukan JSON: " + $teks.Substring(0, [Math]::Min(300, $teks.Length))) }
    }
}

# =============================================================================
$token = AmbilToken
if (-not $token) {
    if (-not $Code) {
        Tulis 'Belum terdaftar. Jalankan sekali dengan -Code KODE-ENROLL dari panel provider.' 'Red'
        exit 2
    }
    $d = Daftarkan $Code
    if (-not $d) { exit 3 }
    $token = $d.token
}

$meta = Info-Diri
Tulis ("Agent aktif. Menyorak tiap {0} dtk ke {1} (Ctrl+C untuk berhenti)" -f $IntervalSec, $Server) 'Cyan'
Tulis ("PC ini: {0} | {1} | {2}" -f $meta.computer, $meta.os, $(if ($meta.isAdmin) { 'Administrator' } else { 'User biasa' })) 'DarkGray'
if ($Sekali) { Tulis 'Mode -Sekali: satu putaran lalu keluar.' 'DarkGray' }

while ($true) {
    $r = Panggil '/agent/heartbeat' @{ meta = $meta } $token

    if ($r.status -eq 401 -or $r.status -eq 403) {
        Tulis 'Token ditolak server. Hapus agent.token lalu daftar ulang dengan kode baru.' 'Red'
        exit 4
    }
    if (-not $r.ok) {
        Tulis ("Server tidak bisa dihubungi (" + $r.status + "): " + $r.data) 'Yellow'
    } else {
        $tasks = @($r.data.tasks)
        if ($tasks.Count -gt 0) {
            Tulis ("Menerima {0} task dari panel." -f $tasks.Count) 'Cyan'
            foreach ($t in $tasks) {
                $nama = if ($t.task) { [string]$t.task } else { '' }
                $stdin = if ($t.stdin) { [string]$t.stdin } else { '' }
                $guid  = if ($t.guid)  { [string]$t.guid }  else { '' }

                if (-not $nama) {
                    Panggil '/agent/result' @{ taskId = $t.id; ok = $false; error = 'Task tanpa nama.' } $token | Out-Null
                    continue
                }
                if ($TaskBoleh -notcontains $nama) {
                    Panggil '/agent/result' @{ taskId = $t.id; ok = $false; error = "Task tidak diizinkan: $nama" } $token | Out-Null
                    continue
                }

                if ($TaskBerbahaya -contains $nama) {
                    Tulis ("  -> {0}  [mengubah sistem]" -f $nama) 'Yellow'
                } else {
                    Tulis ("  -> {0}" -f $nama) 'Gray'
                }

                $hasil = JalankanTask -TaskName $nama -Stdin $stdin -Guid $guid
                $kirim = @{ taskId = $t.id; ok = [bool]$hasil.ok; data = $hasil.data; error = $hasil.error }
                $kr = Panggil '/agent/result' $kirim $token
                if ($kr.ok) {
                    if ($hasil.ok) { Tulis '     selesai' 'DarkGray' }
                    else { Tulis ("     GAGAL: {0}" -f $hasil.error) 'Red' }
                } else {
                    Tulis ("     hasil gagal terkirim (HTTP " + $kr.status + ")") 'Yellow'
                }
            }
        }
    }

    if ($Sekali) { break }
    Start-Sleep -Seconds $IntervalSec
}