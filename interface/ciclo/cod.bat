@echo off
rem Codifica um texto P/R em tokens BPE. Uso: cod.bat <texto> <saida.tok>  (saida e recriada)
if "%~1"=="" (echo uso: cod.bat ^<texto^> ^<saida.tok^> & exit /b 1)
if "%~2"=="" (echo uso: cod.bat ^<texto^> ^<saida.tok^> & exit /b 1)
cd /d "%~dp0..\.."
if exist "%~2" del "%~2"
set CFG=-DTOK16 -DTV=4096 -DTT=256 -DTD=128 -DTH=8 -DTF=512 -DTL=4 -DVOCAB="dados/vocab_bpe.bin"
build\asm.exe tf_bpe_cod_main.asm build\ciclo_cod.obj %CFG% -DTEXTO="%~1" -DSAIDA="%~2" || exit /b 1
build\pelink.exe build\ciclo_cod.obj build\ciclo_cod.exe || exit /b 1
build\ciclo_cod.exe || exit /b 1
