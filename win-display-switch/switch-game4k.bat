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
rem  4K でゲーム : Dell = PC（メイン）、BenQ = Mac
rem  先に切替器のボタンで、Mac の映像を BenQ 側にしておく
rem ============================================================
if not exist "%~dp0game4k.cfg" (
  echo [エラー] game4k.cfg がありません。先に save-config.bat で保存してください。
  pause
  exit /b 1
)

echo 4K でゲームのモードに切り替えます...

rem 1) BenQ を Mac（HDMI）の入力にする（今は PC が映っているので命令が届く）
if "%USE_DDC%"=="1" "%CMM%" /SetValue "%BENQ_ID%" 60 %BENQ_MAC%

rem 2) Windows の画面設定：Dell をメインにして、BenQ への出力を止める
"%MMT%" /LoadConfig "%~dp0game4k.cfg"

rem 3) Dell を PC（DP）の入力にする
rem    （Dell が Mac の入力を映している間は届かないことがある。届かなければ Dell のボタンで切り替える）
if "%USE_DDC%"=="1" (
  timeout /t 3 /nobreak >nul
  "%CMM%" /SetValue "%DELL_ID%" 60 %DELL_PC%
)

echo 完了しました。
timeout /t 2 >nul
