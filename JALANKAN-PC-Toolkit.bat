@echo off
title PC Toolkit - Optimasi Windows
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"%~dp0PC-Toolkit.ps1\"'"
