@echo off
rem Monta o chat com um modelo. Uso: chat.bat <modelo.bin> <saida.exe>
cd /d "%~dp0..\.."
set CFG=-DTOK16 -DTV=4096 -DTT=256 -DTD=128 -DTH=8 -DTF=512 -DTL=4 -DVOCAB="dados/vocab_bpe.bin"
build\asm.exe tf_chat_main.asm build\ciclo_chat.obj %CFG% -DMODELO="%~1" || exit /b 1
build\pelink.exe build\ciclo_chat.obj "%~2" || exit /b 1