@echo off
set "PROGRAMFILES(X86)=C:\Program Files (x86)"
cd /d D:\Projeler\LifeOs-Anyware
echo === WINDOWS BUILD ===
C:\flutter\bin\flutter.bat build windows --release
echo WIN_EXIT=%ERRORLEVEL%
echo === APK BUILD ===
C:\flutter\bin\flutter.bat build apk --release
echo APK_EXIT=%ERRORLEVEL%
echo === DONE ===
