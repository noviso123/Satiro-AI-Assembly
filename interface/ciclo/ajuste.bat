@echo off
rem Ajuste fino a partir de <base> sobre <corpus.tok>, gravando <saida.bin> (novo arquivo). Uso: ajuste.bat <corpus.tok> <base.bin> <saida.bin> [taxa]
if "%~1"=="" (echo uso: ajuste.bat ^<corpus.tok^> ^<base.bin^> ^<saida.bin^> [taxa] & exit /b 1)
if "%~2"=="" (echo uso: ajuste.bat ^<corpus.tok^> ^<base.bin^> ^<saida.bin^> [taxa] & exit /b 1)
if "%~3"=="" (echo uso: ajuste.bat ^<corpus.tok^> ^<base.bin^> ^<saida.bin^> [taxa] & exit /b 1)
cd /d "%~dp0..\.."
set "LRV=%~4"
if "%LRV%"=="" set LRV=2.0e-4
set CFG=-DTOK16 -DTV=4096 -DTT=256 -DTD=128 -DTH=8 -DTF=512 -DTL=4
build\asm.exe tf_corpus_main.asm build\ciclo_ft.obj %CFG% -DCORPUS="%~1" -DBASE="%~2" -DMODELO="%~3" -DMODELO_TMP="%~3.tmp" -DOTIM="%~3.otim" -DOTIM_TMP="%~3.otim.tmp" -DPOSICAO="%~3.pos" -DPOSICAO_TMP="%~3.pos.tmp" -DNOVO -DSOBRESCREVER -DLR=%LRV% -DAQUEC=50 || exit /b 1
build\pelink.exe build\ciclo_ft.obj build\ciclo_ft.exe || exit /b 1
build\ciclo_ft.exe || exit /b 1
