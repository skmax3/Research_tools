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
rem  Mac 作業 : Dell = Mac、BenQ = PC（メイン・ゲーム）
rem  先に切替器のボタンで、Mac の映像を Dell 側にしておく
rem ============================================================
if not exist "%~dp0macwork.cfg" (
  echo [エラー] macwork.cfg がありません。先に save-config.bat で保存してください。
  pause
  exit /b 1
)

echo Mac 作業のモードに切り替えます...

rem 1) Dell を Mac（HDMI）の入力にする（今は PC が映っているので命令が届く）
if "%USE_DDC%"=="1" "%CMM%" /SetValue "%DELL_ID%" 60 %DELL_MAC%

rem 2) Windows の画面設定：BenQ をメインにして、Dell への出力を止める
"%MMT%" /LoadConfig "%~dp0macwork.cfg"

rem 3) BenQ を PC（DP）の入力にする
if "%USE_DDC%"=="1" (
  timeout /t 3 /nobreak >nul
  "%CMM%" /SetValue "%BENQ_ID%" 60 %BENQ_PC%
)

echo 完了しました。
timeout /t 2 >nul
