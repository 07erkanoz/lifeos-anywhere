@echo off
set "PROGRAMFILES(X86)=C:\Program Files (x86)"
cd /d C:\Projeler\LifeOs-Anywhere
flutter build windows --release
echo BUILD_EXIT_CODE=%ERRORLEVEL%
