@echo off
rem Avalia um modelo em um texto tokenizado. Uso: avalia.bat <modelo.bin> <texto.tok>  (imprime a linha de resultado)
if "%~1"=="" (echo uso: avalia.bat ^<modelo.bin^> ^<texto.tok^> & exit /b 1)
if "%~2"=="" (echo uso: avalia.bat ^<modelo.bin^> ^<texto.tok^> & exit /b 1)
cd /d "%~dp0..\.."
set CFG=-DTOK16 -DTV=4096 -DTT=256 -DTD=128 -DTH=8 -DTF=512 -DTL=4 -DVOCAB="dados/vocab_bpe.bin"
build\asm.exe tf_eval_main.asm build\ciclo_ev.obj %CFG% -DMODELO="%~1" -DTEXTO="%~2" || exit /b 1
build\pelink.exe build\ciclo_ev.obj build\ciclo_ev.exe || exit /b 1
build\ciclo_ev.exe || exit /b 1
