@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Set-NativeActiveSetup.ps1" -StubExePath "%~dp0HelloWorld.ps1" -Key "NActiveSetup-Test" -Description "NActiveSetup Hello World Test"
