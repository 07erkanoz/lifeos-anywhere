@echo off
set "ProgramFiles(x86)=C:\Program Files (x86)"
cd /d C:\Projeler\LifeOs-Anywhere
flutter build windows --release --dart-define-from-file=.env
echo EXIT_CODE=%ERRORLEVEL%
