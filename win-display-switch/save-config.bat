@echo off
setlocal
cd /d "%~dp0"
call "%~dp0settings.bat"
if not exist "%MMT%" (
  echo [エラー] MultiMonitorTool.exe がこのフォルダにありません。
  echo NirSoft のページからダウンロードして、このフォルダに入れてください。
  pause
  exit /b 1
)

rem ============================================================
rem  今の Windows の画面設定を、モードとして保存する（最初に 1 回だけ）
rem ============================================================
echo 今の Windows の画面設定を保存します。
echo.
echo   1 = 4K でゲーム（Dell がメイン、BenQ は「表示しない」）
echo   2 = Mac 作業   （BenQ がメイン、Dell は「表示しない」）
echo.
echo 先に Windows の「設定 - システム - ディスプレイ」で、その状態にしておいてください。
echo.
choice /c 12 /m "どちらとして保存しますか"
if errorlevel 2 (
  "%MMT%" /SaveConfig "%~dp0macwork.cfg"
  echo macwork.cfg に保存しました。
) else (
  "%MMT%" /SaveConfig "%~dp0game4k.cfg"
  echo game4k.cfg に保存しました。
)
pause
