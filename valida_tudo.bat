@echo off
rem Validacao completa do Satiro-IA: monta tudo, roda os testes e sai 0 se tudo passou.
rem Uso: valida_tudo.bat   (a partir de qualquer pasta; o script se posiciona na raiz)
cd /d "%~dp0"
set ERR=0
taskkill /F /IM chat_llm.exe >nul 2>&1

echo ===BUILD-PRODUCAO===
call ajuste_fino_llm.bat so_montar
if errorlevel 1 (echo FALHA build-producao & set ERR=1) else echo OK build-producao

echo ===BUILD-LM===
build\asm.exe lm_train_main.asm build\lm_train.obj -DTEXTO_LM="dados/sft_pr.txt" -DNTRAIN=5000
if errorlevel 1 (echo FALHA asm-lm_train & set ERR=1) else echo OK asm-lm_train
build\pelink.exe build\lm_train.obj build\lm_train.exe
if errorlevel 1 (echo FALHA pelink-lm_train & set ERR=1) else echo OK pelink-lm_train
build\asm.exe lm_grad_main.asm build\lm_grad.obj -DTEXTO_LM="dados/sft_pr.txt"
if errorlevel 1 (echo FALHA asm-lm_grad & set ERR=1) else echo OK asm-lm_grad
build\pelink.exe build\lm_grad.obj build\lm_grad.exe
if errorlevel 1 (echo FALHA pelink-lm_grad & set ERR=1) else echo OK pelink-lm_grad

echo ===BUILD-TESTES===
build\asm.exe tests\tf_mm_check.asm build\tf_mm_check.obj
if errorlevel 1 (echo FALHA asm-mm_check & set ERR=1) else echo OK asm-mm_check
build\pelink.exe build\tf_mm_check.obj build\tf_mm_check.exe
if errorlevel 1 (echo FALHA pelink-mm_check & set ERR=1) else echo OK pelink-mm_check
build\asm.exe tests\batch_check.asm build\batch_check.obj
if errorlevel 1 (echo FALHA asm-batch_check & set ERR=1) else echo OK asm-batch_check
build\pelink.exe build\batch_check.obj build\batch_check.exe
if errorlevel 1 (echo FALHA pelink-batch_check & set ERR=1) else echo OK pelink-batch_check
build\asm.exe tests\tf_dir_check.asm build\tf_dir_check.obj
if errorlevel 1 (echo FALHA asm-dir_check & set ERR=1) else echo OK asm-dir_check
build\pelink.exe build\tf_dir_check.obj build\tf_dir_check.exe
if errorlevel 1 (echo FALHA pelink-dir_check & set ERR=1) else echo OK pelink-dir_check
build\asm.exe tests\tf_grad_check.asm build\tf_grad_check.obj
if errorlevel 1 (echo FALHA asm-grad_check & set ERR=1) else echo OK asm-grad_check
build\pelink.exe build\tf_grad_check.obj build\tf_grad_check.exe
if errorlevel 1 (echo FALHA pelink-grad_check & set ERR=1) else echo OK pelink-grad_check

echo ===BUILD-DADOS===
build\asm.exe tf_bpe_main.asm build\chk_bpe.obj
if errorlevel 1 (echo FALHA asm-bpe & set ERR=1) else echo OK asm-bpe
build\asm.exe tf_bpe_cod_main.asm build\chk_bpecod.obj -DTOK16 -DTV=4096 -DVOCAB="dados/vocab_bpe.bin"
if errorlevel 1 (echo FALHA asm-bpe_cod & set ERR=1) else echo OK asm-bpe_cod
build\asm.exe tf_bpe_cod_main.asm build\chk_bpecod2.obj
if errorlevel 1 (echo FALHA asm-bpe_cod-bytes & set ERR=1) else echo OK asm-bpe_cod-bytes
build\asm.exe tf_sft_fmt_main.asm build\chk_sft.obj
if errorlevel 1 (echo FALHA asm-sft_fmt & set ERR=1) else echo OK asm-sft_fmt
del build\chk_bpe.obj build\chk_bpecod.obj build\chk_bpecod2.obj build\chk_sft.obj >nul 2>&1

echo ===EXECUCAO===
echo ---mm_check--- & build\tf_mm_check.exe
echo ---batch_check--- & build\batch_check.exe
echo ---dir_check--- & build\tf_dir_check.exe
echo ---grad_check--- & build\tf_grad_check.exe
echo ---lm_grad--- & build\lm_grad.exe
echo ---lm_train--- & build\lm_train.exe
echo ---eval--- & build\eval_llm.exe
echo ---gen--- & (echo O Brasil| build\gen_llm.exe -n 10 >nul 2>&1)
if errorlevel 1 (echo FALHA gen & set ERR=1) else echo OK gen
echo ---chat--- & (echo /sair| build\chat_llm.exe >nul 2>&1)
if errorlevel 1 (echo FALHA chat & set ERR=1) else echo OK chat

echo ===FIM ERR=%ERR%===
exit /b %ERR%
