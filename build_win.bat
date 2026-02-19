@echo off
set "PROGRAMFILES(X86)=C:\Program Files (x86)"
cd /d D:\Projeler\LifeOs-Anyware
C:\flutter\bin\flutter.bat build windows --release
echo BUILD_EXIT_CODE=%ERRORLEVEL%
