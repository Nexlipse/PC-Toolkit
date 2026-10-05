@echo off
title PC Toolkit Dashboard
cd /d "%~dp0dashboard"
where node >nul 2>nul
if errorlevel 1 (
  echo Node.js belum terpasang. Silakan install dulu dari https://nodejs.org
  pause
  exit /b 1
)
echo Dashboard berjalan di http://127.0.0.1:5599
echo Browser akan terbuka otomatis. Tekan Ctrl+C untuk menghentikan.
node server.js
pause
