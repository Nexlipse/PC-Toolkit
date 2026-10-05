# PC Toolkit — Optimasi & Perawatan Windows (CLI + Dashboard)

Toolkit sederhana untuk membersihkan dan memeriksa kesehatan PC Windows 10/11 tanpa perlu install software pihak ketiga.
Ada dua mode: **CLI (PowerShell)** untuk yang suka terminal, dan **Dashboard (Web UI via Node.js)** untuk yang suka tampilan visual.

## Fitur

| # | Fitur | Keterangan |
|---|-------|------------|
| 1 | Bersihkan cache & file sampah | `%TEMP%`, `C:\Windows\Temp`, `Prefetch`, crash dumps, Windows Error Reporting, cache Windows Update, thumbnail/icon cache, Recycle Bin, flush DNS |
| 2 | Cek kesehatan baterai | Kapasitas desain vs kapasitas penuh (health %), cycle count, laporan `powercfg /batteryreport` |
| 3 | Cek kesehatan SSD/HDD | Health status SMART, wear %, suhu, jam nyala, jumlah error baca + ringkasan partisi |
| 4 | Cek sisa aplikasi (leftover) | Scan folder program yang tidak terhubung ke aplikasi terinstal/shortcut/proses berjalan, hapus ke **Recycle Bin**; juga bersihkan entri uninstall registry yang mati (dengan backup `.reg`) |
| 5 | Monitoring suhu CPU | Real-time tiap 3 detik di CLI, auto-refresh tiap 5 detik di dashboard |
| 6 | Bersihkan cache browser | Chrome, Edge, Firefox (dilewati otomatis kalau browser sedang berjalan) |
| 7 | Kelola aplikasi startup | Lihat & nonaktifkan item startup dengan backup otomatis ke `logs\backup` |
| 8 | Ringkasan sistem | OS, CPU, RAM, uptime, partisi, 5 proses RAM terbesar |
| 9 | **Jalankan DASHBOARD** | Menu CLI no. 9 menjalankan `node server.js` di latar belakang lalu membuka browser |
| 10 | Skema daya | Lihat & ganti power plan |

## Cara Menjalankan

### Via CLI
Double-click `JALANKAN-PC-Toolkit.bat` (otomatis minta akses Administrator),
atau manual dari terminal:

```powershell
powershell -ExecutionPolicy Bypass -File .\PC-Toolkit.ps1
```

### Via Dashboard (Web UI)
Double-click `JALANKAN-DASHBOARD.bat`, atau:

```bash
cd dashboard
node server.js
```

Dashboard terbuka otomatis di `http://127.0.0.1:5599` (hanya bisa diakses dari komputer sendiri).
Server bisa dihentikan lewat tombol **"Hentikan Server Dashboard"** di bagian bawah halaman.

Atau dari menu CLI, pilih menu **[9] Jalankan DASHBOARD** — script otomatis menjalankan
`node server.js` di latar belakang lalu membuka browser.

### Menjalankan satu fitur saja (tanpa menu)

```powershell
powershell -ExecutionPolicy Bypass -File .\PC-Toolkit.ps1 -Task junk      # bersihkan cache (interaktif)
powershell -ExecutionPolicy Bypass -File .\PC-Toolkit.ps1 -Task summary   # ringkasan sistem
powershell -ExecutionPolicy Bypass -File .\PC-Toolkit.ps1 -Task battery   # cek baterai
powershell -ExecutionPolicy Bypass -File .\PC-Toolkit.ps1 -Task disk      # cek SSD/HDD
powershell -ExecutionPolicy Bypass -File .\PC-Toolkit.ps1 -Task cpu       # suhu CPU (sekali baca)
```

Task tersedia: `junk`, `junk-size`, `battery`, `disk`, `leftover-scan`, `delete-leftover`,
`cpu`, `browser`, `startup-list`, `disable-startup`, `summary`, `power-list`, `set-power`.
Tambahkan `-Json` untuk output JSON (dipakai dashboard).

## Keamanan

- File cache dihapus permanen, tapi hanya di folder sampah yang aman (file yang sedang dipakai sistem otomatis dilewati).
- Folder **leftover** dan file startup dihapus ke **Recycle Bin** (bisa dikembalikan).
- Entri registry yang dihapus selalu di-export dulu ke `logs\backup\*.reg` (bisa dikembalikan double-click).
- Semua aksi dicatat di `logs\log-YYYY-MM-DD.txt`.
- Penghapusan leftover dibatasi hanya di dalam: Program Files, Program Files (x86), ProgramData, AppData (Roaming/Local) — folder sistem seperti `Microsoft`, `Windows`, `Packages` tidak akan bisa dihapus.

## Keterbatasan

- Beberapa fitur butuh **Administrator**: Prefetch, cache Windows Update, WER, suhu CPU via ACPI, ganti power plan, startup HKLM.
- **Suhu CPU** bergantung hardware/driver: sebagian PC tidak mengekspos sensor via WMI. Kalau kosong, gunakan HWiNFO64/Core Temp, atau jalankan sebagai Administrator.
- **Baterai** tidak tersedia di PC desktop/VM; di beberapa laptop kapasitas desain tidak dilaporkan.
- Dashboard tidak butuh dependensi npm apa pun (pure Node.js).

## Struktur

```
PC-Toolkit/
├── PC-Toolkit.ps1          # engine CLI + mode JSON
├── JALANKAN-PC-Toolkit.bat # launcher CLI (auto-elevate admin)
├── JALANKAN-DASHBOARD.bat  # launcher dashboard
├── dashboard/
│   ├── server.js           # server Node tanpa dependensi
│   └── index.html          # UI dashboard
└── logs/                   # log aksi + backup registry/startup (dibuat otomatis)
```
