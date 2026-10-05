<#
 =============================================================================
  gui.ps1 - Antarmuka graphical untuk PC Toolkit (WinForms)
  Dipanggil dari install.ps1, atau langsung:
      powershell -ExecutionPolicy Bypass -File gui.ps1
  Semua operasi lewat engine PC-Toolkit.ps1 -Task <nama> -Json.
 =============================================================================
#>
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$Engine    = Join-Path $PSScriptRoot 'PC-Toolkit.ps1'
$AgentPs1  = Join-Path $PSScriptRoot 'agent.ps1'
$script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
                      [Security.Principal.WindowsBuiltInRole]::Administrator)

# group, task, judul, ada-tombol-jalankan, butuh-input, jenis-input, berisiko
$script:alat = @(
    @{ g = 'Perawatan';    t = 'junk-size';       j = 'Hitung ukuran sampah';           a = $false; i = '';            r = $false }
    @{ g = 'Perawatan';    t = 'junk';             j = 'Bersihkan cache & sampah';       a = $true;  i = '';            r = $true  }
    @{ g = 'Perawatan';    t = 'browser';          j = 'Bersihkan cache browser';        a = $true;  i = '';            r = $true  }

    @{ g = 'Hardware';     t = 'battery';          j = 'Kesehatan baterai';              a = $false; i = '';            r = $false }
    @{ g = 'Hardware';     t = 'disk';             j = 'Kesehatan SSD / HDD';           a = $false; i = '';            r = $false }
    @{ g = 'Hardware';     t = 'cpu';              j = 'Suhu & beban CPU';              a = $false; i = '';            r = $false }

    @{ g = 'Startup';      t = 'startup-list';     j = 'Daftar aplikasi startup';       a = $false; i = '';            r = $false }
    @{ g = 'Startup';      t = 'disable-startup';  j = 'Nonaktifkan startup terpilih';  a = $true;  i = 'banyak';      r = $true  }

    @{ g = 'Sisa aplikasi'; t = 'leftover-scan';   j = 'Pindai sisa aplikasi';          a = $false; i = '';            r = $false }
    @{ g = 'Sisa aplikasi'; t = 'delete-leftover'; j = 'Hapus sisa terpilih';           a = $true;  i = 'banyak';      r = $true  }

    @{ g = 'Daya';         t = 'power-list';       j = 'Daftar skema daya';             a = $false; i = '';            r = $false }
    @{ g = 'Daya';         t = 'set-power';        j = 'Ganti skema daya';              a = $true;  i = 'satu';        r = $true  }

    @{ g = 'Sistem';       t = 'summary';          j = 'Ringkasan sistem';              a = $false; i = '';            r = $false }
)

# ------------------------------ engine call -------------------------------
function Invoke-Engine {
    param([string]$Task, [string]$Stdin = '', [string]$Guid = '')

    if (-not (Test-Path -LiteralPath $Engine)) {
        return @{ ok = $false; json = $null; teks = "Engine tidak ditemukan: $Engine" }
    }

    $arg = @('-NoProfile','-ExecutionPolicy','Bypass','-File', $Engine, '-Task', $Task, '-Json')
    if ($Task -eq 'junk') { $arg += '-IncludeRecycleBin' }
    if ($Task -eq 'set-power') { $arg += @('-Guid', $Guid) }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName        = 'powershell.exe'
    $psi.Arguments       = (($arg | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' ')
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow   = $true
    $psi.WorkingDirectory = $PSScriptRoot

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    try { [void]$p.Start() } catch {
        return @{ ok = $false; json = $null; teks = "Gagal menjalankan engine: $($_.Exception.Message)" }
    }
    if ($Stdin) { $p.StandardInput.Write($Stdin); $p.StandardInput.Close() }
    $out = $p.StandardOutput.ReadToEnd()
    $err = $p.StandardError.ReadToEnd()
    if (-not $p.WaitForExit(300000)) {
        try { $p.Kill() } catch { }
        return @{ ok = $false; json = $null; teks = 'Waktu habis (5 menit), operasi dihentikan.' }
    }

    $teks = $out.Trim()
    if ($teks.Contains('{')) { $teks = $teks.Substring($teks.IndexOf('{')) }
    if (-not $teks) {
        return @{ ok = $false; json = $null; teks = ("Engine tidak mengeluarkan JSON. stderr: " + $err.Trim()) }
    }
    try {
        return @{ ok = $true; json = ($teks | ConvertFrom-Json); teks = $null }
    } catch {
        return @{ ok = $false; json = $null; teks = "Output engine tidak bisa dibaca: " + $teks.Substring(0,[Math]::Min(400,$teks.Length)) }
    }
}

function Format-Size { param($b)
    if ($null -eq $b) { return '-' }
    $b = [double]$b
    if ($b -ge 1GB) { return ("{0:N2} GB" -f ($b/1GB)) }
    if ($b -ge 1MB) { return ("{0:N1} MB" -f ($b/1MB)) }
    if ($b -ge 1KB) { return ("{0:N1} KB" -f ($b/1KB)) }
    return ("{0} B" -f [int64]$b)
}

# Pretty-printer supaya hasil JSON enak dibaca, bukan satu baris panjang.
function Tampil-Json {
    param($o, [string]$judul = '')
    if ($null -eq $o) { return "(kosong)" }
    $sb = New-Object System.Text.StringBuilder
    function Tmb($x, $prefix, $d) {
        if ($d -gt 6) { return }
        if ($x -is [System.Collections.IEnumerable] -and $x -isnot [string] -and $x -isnot [pscustomobject]) {
            $arr = @($x)
            if ($arr.Count -eq 0) { [void]$sb.AppendLine("$prefix(none)"); return }
            $i = 0
            foreach ($it in $arr) {
                if ($it -is [string] -or $it -is [ValueType]) { [void]$sb.AppendLine(("{0}- {1}" -f $prefix, $it)) }
                else {
                    [void]$sb.AppendLine(("{0}- [{1}]" -f $prefix, $i))
                    Tmb $it ($prefix + '    ') ($d+1)
                }
                $i++
            }
            return
        }
        if ($x -is [pscustomobject]) {
            foreach ($p in $x.PSObject.Properties) {
                $v = $p.Value
                if ($null -eq $v) { [void]$sb.AppendLine(("{0}{1}: -" -f $prefix, $p.Name)) }
                elseif ($v -is [string] -or $v -is [ValueType]) { [void]$sb.AppendLine(("{0}{1}: {2}" -f $prefix, $p.Name, $v)) }
                else {
                    [void]$sb.AppendLine(("{0}{1}:" -f $prefix, $p.Name))
                    Tmb $v ($prefix + '  ') ($d+1)
                }
            }
            return
        }
        [void]$sb.AppendLine(("{0}{1}" -f $prefix, $x))
    }
    if ($judul) { [void]$sb.AppendLine("== $judul ==") }
    Tmb $o '' 0
    return $sb.ToString().TrimEnd()
}

# ------------------------------ input dialog -----------------------------
function Ask-Input {
    param([string]$Judul, [string]$Petunjuk, [string]$Contoh, [bool]$Banyak)
    $f = New-Object System.Windows.Forms.Form
    $f.Text = $Judul; $f.StartPosition = 'CenterParent'; $f.Size = New-Object System.Drawing.Size(620,340)
    $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false
    $f.BackColor = [System.Drawing.Color]::FromArgb(30,34,40)

    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Petunjuk; $l.ForeColor = [System.Drawing.Color]::FromArgb(180,188,198)
    $l.AutoSize = $true; $l.Location = New-Object System.Drawing.Point(14,14)
    $l.MaximumSize = New-Object System.Drawing.Size(575,0)

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Multiline = $true
    $tb.ScrollBars = 'Vertical'
    $tb.BackColor = [System.Drawing.Color]::FromArgb(20,23,27)
    $tb.ForeColor = [System.Drawing.Color]::FromArgb(220,225,232)
    $tb.BorderStyle = 'FixedSingle'
    $tb.Font = New-Object System.Drawing.Font('Consolas', 9.5)
    $tb.Location = New-Object System.Drawing.Point(14,64)
    $tb.Size = New-Object System.Drawing.Size(575,180)
    if ($Contoh) { $tb.Text = $Contoh }

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Lanjut'; $ok.DialogResult = 'OK'; $ok.Size = New-Object System.Drawing.Size(90,28)
    $ok.Location = New-Object System.Drawing.Point(410,258)

    $batal = New-Object System.Windows.Forms.Button
    $batal.Text = 'Batal'; $batal.DialogResult = 'Cancel'; $batal.Size = New-Object System.Drawing.Size(90,28)
    $batal.Location = New-Object System.Drawing.Point(500,258)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = 'Kosongkan berarti batal.'
    $lbl.ForeColor = [System.Drawing.Color]::FromArgb(130,138,148)
    $lbl.AutoSize = $true; $lbl.Location = New-Object System.Drawing.Point(14,266)

    $null = $f.Controls.AddRange(@($l,$tb,$lbl,$ok,$batal))
    $f.AcceptButton = $ok; $f.CancelButton = $batal
    if ($f.ShowDialog() -eq 'OK') { return $tb.Text }
    return $null
}

# ------------------------------ form utama -------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'PC Toolkit'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(1040,700)
$form.MinimumSize = New-Object System.Drawing.Size(860,560)
$form.BackColor = [System.Drawing.Color]::FromArgb(24,27,32)
$form.ForeColor = [System.Drawing.Color]::FromArgb(224,229,235)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

# --- header ---
$hdr = New-Object System.Windows.Forms.Panel
$hdr.Dock = 'Top'; $hdr.Height = 54
$hdr.BackColor = [System.Drawing.Color]::FromArgb(19,22,26)

$lblJudul = New-Object System.Windows.Forms.Label
$lblJudul.Text = 'PC Toolkit'; $lblJudul.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 14)
$lblJudul.ForeColor = [System.Drawing.Color]::FromArgb(236,240,245)
$lblJudul.AutoSize = $true; $lblJudul.Location = New-Object System.Drawing.Point(18,10)
$hdr.Controls.Add($lblJudul)

$lblPc = New-Object System.Windows.Forms.Label
$lblPc.Text = "$env:COMPUTERNAME  ·  $(if ($script:IsAdmin) {'Administrator'} else {'User biasa'})"
$lblPc.ForeColor = [System.Drawing.Color]::FromArgb(140,150,162)
$lblPc.AutoSize = $true; $lblPc.Location = New-Object System.Drawing.Point(18,32)
$hdr.Controls.Add($lblPc)

$btnHub = New-Object System.Windows.Forms.Button
$btnHub.Text = 'Hubungkan ke provider'
$btnHub.Size = New-Object System.Drawing.Size(170,30)
$btnHub.Anchor = 'Top,Right'
$btnHub.Location = New-Object System.Drawing.Point(852,12)
$btnHub.FlatStyle = 'Flat'; $btnHub.ForeColor = [System.Drawing.Color]::FromArgb(190,198,208)
$btnHub.BackColor = [System.Drawing.Color]::FromArgb(34,38,45)
$btnHub.Location = New-Object System.Drawing.Point(852,12)
$hdr.Controls.Add($btnHub)

$form.Controls.Add($hdr)

# --- tree kiri ---
$tree = New-Object System.Windows.Forms.TreeView
$tree.Dock = 'Left'; $tree.Width = 232
$tree.BackColor = [System.Drawing.Color]::FromArgb(27,31,37)
$tree.ForeColor = [System.Drawing.Color]::FromArgb(210,216,224)
$tree.BorderStyle = 'None'; $tree.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
$form.Controls.Add($tree)

# --- panel kanan ---
$kanan = New-Object System.Windows.Forms.Panel
$kanan.Dock = 'Fill'; $kanan.BackColor = [System.Drawing.Color]::FromArgb(24,27,32)
$form.Controls.Add($kanan)

$lblAksi = New-Object System.Windows.Forms.Label
$lblAksi.Text = 'Pilih satu alat di daftar kiri'
$lblAksi.Dock = 'Top'; $lblAksi.Height = 46
$lblAksi.Padding = New-Object System.Windows.Forms.Padding(18,14,0,0)
$lblAksi.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 12)
$lblAksi.ForeColor = [System.Drawing.Color]::FromArgb(236,240,245)
$lblAksi.BackColor = [System.Drawing.Color]::FromArgb(24,27,32)
$kanan.Controls.Add($lblAksi)

$txt = New-Object System.Windows.Forms.TextBox
$txt.Multiline = $true; $txt.ReadOnly = $true; $txt.ScrollBars = 'Both'
$txt.Dock = 'Fill'
$txt.BackColor = [System.Drawing.Color]::FromArgb(18,20,24)
$txt.ForeColor = [System.Drawing.Color]::FromArgb(198,206,216)
$txt.BorderStyle = 'None'
$txt.Font = New-Object System.Drawing.Font('Consolas', 9.5)
$txt.WordWrap = $false
$kanan.Controls.Add($txt)

$bar = New-Object System.Windows.Forms.Panel
$bar.Dock = 'Bottom'; $bar.Height = 58
$bar.BackColor = [System.Drawing.Color]::FromArgb(27,31,37)
$kanan.Controls.Add($bar)

$btnJalankan = New-Object System.Windows.Forms.Button
$btnJalankan.Text = 'Jalankan'
$btnJalankan.Size = New-Object System.Drawing.Size(130,32)
$btnJalankan.Location = New-Object System.Drawing.Point(18,13)
$btnJalankan.FlatStyle = 'Flat'
$btnJalankan.BackColor = [System.Drawing.Color]::FromArgb(106,168,79)
$btnJalankan.ForeColor = [System.Drawing.Color]::FromArgb(14,18,12)
$btnJalankan.Enabled = $false
$bar.Controls.Add($btnJalankan)

$btnMuatUlang = New-Object System.Windows.Forms.Button
$btnMuatUlang.Text = 'Muat ulang'
$btnMuatUlang.Size = New-Object System.Drawing.Size(110,32)
$btnMuatUlang.Location = New-Object System.Drawing.Point(158,13)
$btnMuatUlang.FlatStyle = 'Flat'
$btnMuatUlang.BackColor = [System.Drawing.Color]::FromArgb(38,43,50)
$btnMuatUlang.ForeColor = [System.Drawing.Color]::FromArgb(200,208,218)
$bar.Controls.Add($btnMuatUlang)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Dock = 'Bottom'; $lblStatus.Height = 26
$lblStatus.TextAlign = 'MiddleLeft'
$lblStatus.Padding = New-Object System.Windows.Forms.Padding(18,0,0,0)
$lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(130,138,148)
$lblStatus.Text = 'Siap.'
$bar.Controls.Add($lblStatus)

# --- isi tree ---
$grupNodes = @{}
foreach ($a in $script:alat) {
    if (-not $grupNodes.ContainsKey($a.g)) {
        $n = New-Object System.Windows.Forms.TreeNode($a.g)
        $n.ForeColor = [System.Drawing.Color]::FromArgb(140,150,162)
        $tree.Nodes.Add($n) | Out-Null
        $grupNodes[$a.g] = $n
    }
    $leaf = New-Object System.Windows.Forms.TreeNode($a.j)
    $leaf.Tag = $a
    $grupNodes[$a.g].Nodes.Add($leaf) | Out-Null
}
$tree.ExpandAll()

# --- aksi ---
$script:terpilih = $null

function Tampil-Status { param([string]$t, [string]$warna = 'normal')
    $lblStatus.Text = $t
    $lblStatus.ForeColor = switch ($warna) {
        'ok'    { [System.Drawing.Color]::FromArgb(120,186,94) }
        'err'   { [System.Drawing.Color]::FromArgb(214,110,88) }
        default { [System.Drawing.Color]::FromArgb(130,138,148) }
    }
}

function Pilih {
    param($alat)
    $script:terpilih = $alat
    $lblAksi.Text = $alat.j
    $btnJalankan.Enabled = $true
    $btnJalankan.Text = if ($alat.a) { 'Jalankan' } else { 'Periksa' }
    $btnJalankan.BackColor = if ($alat.r) {
        [System.Drawing.Color]::FromArgb(204,92,74)
    } else {
        [System.Drawing.Color]::FromArgb(106,168,79)
    }
    $txt.Text = "Klik `"$($btnJalankan.Text.ToLower())`" untuk menjalankan.`n`n"
    Tampil-Status 'Siap.'
}

function Kerjakan {
    param($alat, [string]$Stdin = '', [string]$Guid = '')

    if (-not $script:IsAdmin -and $alat.r) {
        $tanya = $form.Owner
        $j = [System.Windows.Forms.MessageBox]::Show(
            "Operasi ini mengubah sistem. PC sekarang tidak jalan sebagai Administrator,`nsebagian langkah akan dilewati.`n`nLanjut?",
            'Butuh hak Administrator', 'YesNo', 'Warning')
        if ($j -ne 'Yes') { return }
    }
    if ($alat.r) {
        $j = [System.Windows.Forms.MessageBox]::Show(
            "'$($alat.j)' mengubah sistem PC ini secara permanen.`nLanjutkan?",
            'Konfirmasi', 'YesNo', 'Warning')
        if ($j -ne 'Yes') { return }
    }

    $btnJalankan.Enabled = $false
    $btnMuatUlang.Enabled = $false
    $txt.Text = "Menjalankan $($alat.j)...`n`n"
    Tampil-Status 'Sedang berjalan…'
    $form.Refresh()
    [System.Windows.Forms.Application]::DoEvents()

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-Engine -Task $alat.t -Stdin $Stdin -Guid $Guid
    $sw.Stop()

    if ($r.ok) {
        $txt.Text = Tampil-Json $r.json $alat.j
        Tampil-Status ("Selesai dalam {0:N1} detik." -f $sw.Elapsed.TotalSeconds) 'ok'
    } else {
        $txt.Text = "GAGAL`n`n$($r.teks)"
        Tampil-Status 'Gagal.' 'err'
    }

    $btnJalankan.Enabled = $true
    $btnMuatUlang.Enabled = $true
    $form.Refresh()
}

$tree.Add_AfterSelect({
    if ($_.Node.Tag) { Pilih $_.Node.Tag }
})

$btnJalankan.Add_Click({
    $a = $script:terpilih
    if (-not $a) { return }
    $stdin = ''; $guid = ''
    if ($a.i -eq 'banyak') {
        $pet = switch ($a.t) {
            'delete-leftover' { "Satu path per baris. Untuk entri registry, tulis Registry:: lalu key path." }
            'disable-startup' { "Satu target per baris, format  Reg|keyPath|valueName  atau  File|path`nAmbil dari 'Daftar aplikasi startup'." }
        }
        $contoh = switch ($a.t) {
            'delete-leftover' { "C:\Program Files\Apps\YangSudahDihapus" }
            'disable-startup' { "File|C:\Users\me\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\app.lnk" }
        }
        $v = Ask-Input $a.j $pet $contoh $true
        if ($null -eq $v) { return }
        $stdin = $v.Trim()
        if (-not $stdin) { return }
    }
    if ($a.i -eq 'satu') {
        $v = Ask-Input $a.j 'Tempel GUID skema daya dari hasil "Daftar skema daya".' '381b4222-f694-41f0-9685-ff5bb260df2e' $false
        if ($null -eq $v) { return }
        $guid = $v.Trim()
        if (-not $guid) { return }
    }
    Kerjakan $a $stdin $guid
})

$btnMuatUlang.Add_Click({
    $a = $script:terpilih
    if ($a) { Kerjakan $a }
})

# --- hubungkan ke provider ---
$btnHub.Add_Click({
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'Hubungkan ke provider'; $f.StartPosition = 'CenterParent'
    $f.Size = New-Object System.Drawing.Size(560,270); $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox = $false; $f.MinimizeBox = $false
    $f.BackColor = [System.Drawing.Color]::FromArgb(30,34,40); $f.Font = New-Object System.Drawing.Font('Segoe UI',9)

    $l1 = New-Object System.Windows.Forms.Label
    $l1.Text = 'Alamat server provider'; $l1.AutoSize = $true; $l1.Location = New-Object System.Drawing.Point(14,16)
    $l1.ForeColor = [System.Drawing.Color]::FromArgb(180,188,198)
    $tb1 = New-Object System.Windows.Forms.TextBox
    $tb1.Location = New-Object System.Drawing.Point(14,38); $tb1.Size = New-Object System.Drawing.Size(515,26)
    $tb1.Text = 'https://alamat-provider:5700'
    $tb1.BackColor = [System.Drawing.Color]::FromArgb(20,23,27)
    $tb1.ForeColor = [System.Drawing.Color]::FromArgb(220,225,232)

    $l2 = New-Object System.Windows.Forms.Label
    $l2.Text = 'Kode enroll dari panel'; $l2.AutoSize = $true; $l2.Location = New-Object System.Drawing.Point(14,76)
    $l2.ForeColor = [System.Drawing.Color]::FromArgb(180,188,198)
    $tb2 = New-Object System.Windows.Forms.TextBox
    $tb2.Location = New-Object System.Drawing.Point(14,98); $tb2.Size = New-Object System.Drawing.Size(515,26)
    $tb2.BackColor = [System.Drawing.Color]::FromArgb(20,23,27)
    $tb2.ForeColor = [System.Drawing.Color]::FromArgb(220,225,232)

    $l3 = New-Object System.Windows.Forms.Label
    $l3.Text = 'Code ini hanya dipakai sekali, lalu hangus. Jangan isi ulang kalau PC ini sudah terdaftar.'
    $l3.AutoSize = $true; $l3.ForeColor = [System.Drawing.Color]::FromArgb(125,133,143)
    $l3.Location = New-Object System.Drawing.Point(14,132); $l3.MaximumSize = New-Object System.Drawing.Size(515,0)

    $b1 = New-Object System.Windows.Forms.Button
    $b1.Text = 'Daftar & mulai'; $b1.Size = New-Object System.Drawing.Size(120,30)
    $b1.Location = New-Object System.Drawing.Point(14,170)
    $b1.FlatStyle = 'Flat'; $b1.BackColor = [System.Drawing.Color]::FromArgb(106,168,79)
    $b1.ForeColor = [System.Drawing.Color]::FromArgb(14,18,12)

    $b2 = New-Object System.Windows.Forms.Button
    $b2.Text = 'Tutup'; $b2.Size = New-Object System.Drawing.Size(100,30)
    $b2.Location = New-Object System.Drawing.Point(430,170); $b2.DialogResult = 'Cancel'
    $b2.FlatStyle = 'Flat'; $b2.BackColor = [System.Drawing.Color]::FromArgb(38,43,50)
    $b2.ForeColor = [System.Drawing.Color]::FromArgb(200,208,218)

    $null = $f.Controls.AddRange(@($l1,$tb1,$l2,$tb2,$l3,$b1,$b2))
    $f.AcceptButton = $b1; $f.CancelButton = $b2
    if ($f.ShowDialog() -ne 'OK') { return }

    $server = $tb1.Text.Trim().TrimEnd('/')
    $code   = $tb2.Text.Trim()
    if (-not $server) { return }

    $adaToken = Test-Path -LiteralPath (Join-Path $PSScriptRoot 'agent.token')
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File', $AgentPs1, '-Server', $server)
    if (-not $adaToken) {
        if (-not $code) {
            [System.Windows.Forms.MessageBox]::Show('PC ini belum terdaftar. Isi kode enroll dulu.','Belum terdaftar','OK','Warning') | Out-Null
            return
        }
        $argList += @('-Code', $code)
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = (($argList | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' ')
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.WindowStyle = 'Minimized'
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        [System.Windows.Forms.MessageBox]::Show("Agent dijalankan di latar belakang (PID $($p.Id)).`n`nPanel provider sekarang bisa melihat PC ini dan mengirim task.","Terhubung",'OK','Information') | Out-Null
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Gagal menjalankan agent: $($_.Exception.Message)",'Gagal','OK','Error') | Out-Null
    }
})

$form.Add_Shown({
    $ringkasan = $script:alat | Where-Object { $_.t -eq 'summary' } | Select-Object -First 1
    Pilih $ringkasan
    $script:terpilih = $ringkasan
})

[void]$form.ShowDialog()