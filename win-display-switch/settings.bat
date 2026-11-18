@echo off
rem ============================================================
rem  画面切り替えの設定（ここだけ自分の環境に合わせて書き換える）
rem ============================================================

rem --- 使うツール（このフォルダに置く） ---
set "MMT=%~dp0MultiMonitorTool.exe"
set "CMM=%~dp0ControlMyMonitor.exe"

rem --- モニターの入力を PC から切り替えるか ---
rem   0 = 使わない（モニターが自動で入力を探してくれる場合）
rem   1 = 使う（ControlMyMonitor.exe が必要。下の ID と番号も設定する）
set "USE_DDC=0"

rem --- モニターの名前（ControlMyMonitor の画面上の一覧に出る
rem     「Monitor ID」か「Short Monitor ID」をコピーして貼る） ---
set "DELL_ID=ここにDellのIDを貼る"
set "BENQ_ID=ここにBenQのIDを貼る"

rem --- 入力の番号（VCP 60 の値。多くのモニターで共通） ---
rem   15 = DisplayPort 1、17 = HDMI 1、18 = HDMI 2
rem   Dell : PC は DP、Mac（切替器から）は HDMI
set "DELL_PC=15"
set "DELL_MAC=17"
rem   BenQ : PC は DP、Mac（切替器から）は HDMI
set "BENQ_PC=15"
set "BENQ_MAC=17"
