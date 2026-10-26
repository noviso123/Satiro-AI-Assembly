@echo off
rem Ajuste fino P/R da LLM BPE a partir do checkpoint atual (dados\modelo_llm.bin, so leitura).
rem Parte de dados\modelo_chat3.bin e grava dados\modelo_chat4.* (refeito a cada vez) e monta:
rem   build\chat_llm.exe  (chat)   build\gen_llm.exe (gerador)   build\eval_llm.exe (avaliacao)
rem Leva alguns minutos e divide a CPU com o treino longo enquanto roda.
cd /d %~dp0
set CFG=-DTOK16 -DTV=4096 -DTT=256 -DTD=128 -DTH=8 -DTF=512 -DTL=4 -DVOCAB="dados/vocab_bpe.bin"
if not exist dados\sft_pr.tok (
  build\asm.exe tf_bpe_cod_main.asm build\cod_sft.obj %CFG% -DTEXTO="dados/sft_pr.txt" -DSAIDA="dados/sft_pr.tok" || exit /b 1
  build\pelink.exe build\cod_sft.obj build\cod_sft.exe || exit /b 1
  build\cod_sft.exe || exit /b 1
)
if not exist dados\pira_valid.tok (
  build\asm.exe tf_bpe_cod_main.asm build\cod_val.obj %CFG% -DTEXTO="dados/pira_valid.tsv" -DSAIDA="dados/pira_valid.tok" || exit /b 1
  build\pelink.exe build\cod_val.obj build\cod_val.exe || exit /b 1
  build\cod_val.exe || exit /b 1
)
rem O modelo vivo aprendido sobre o base antigo nao vale para o novo: guarda como backup (nao apaga).
if exist dados\modelo_vivo.bin move /y dados\modelo_vivo.bin dados\modelo_vivo_antigo.bin >nul
if exist dados\modelo_vivo.otim move /y dados\modelo_vivo.otim dados\modelo_vivo_antigo.otim >nul
rem Parte do modelo de conversa atual (modelo_chat3) e grava modelo_chat4: o chat usa o resultado.
build\asm.exe tf_corpus_main.asm build\ajuste_llm.obj %CFG% -DCORPUS="dados/sft_pr.tok" -DBASE="dados/modelo_chat3.bin" -DMODELO="dados/modelo_chat4.bin" -DMODELO_TMP="dados/modelo_chat4.tmp" -DOTIM="dados/modelo_chat4.otim" -DOTIM_TMP="dados/modelo_chat4.otim.tmp" -DPOSICAO="dados/modelo_chat4.pos" -DPOSICAO_TMP="dados/modelo_chat4.pos.tmp" -DNOVO -DSOBRESCREVER -DLR=2.0e-4 -DAQUEC=50 || exit /b 1
build\pelink.exe build\ajuste_llm.obj build\ajuste_llm.exe || exit /b 1
build\asm.exe tf_chat_main.asm build\chat_llm.obj %CFG% -DMODELO="dados/modelo_chat4.bin" || exit /b 1
build\pelink.exe build\chat_llm.obj build\chat_llm.exe || exit /b 1
build\asm.exe tf_gen_main.asm build\gen_llm.obj %CFG% -DMODELO="dados/modelo_llm.bin" || exit /b 1
build\pelink.exe build\gen_llm.obj build\gen_llm.exe || exit /b 1
build\asm.exe tf_eval_main.asm build\eval_llm.obj %CFG% -DMODELO="dados/modelo_llm.bin" -DTEXTO="dados/pira_valid.tok" || exit /b 1
build\pelink.exe build\eval_llm.obj build\eval_llm.exe || exit /b 1
if "%1"=="so_montar" exit /b 0
build\ajuste_llm.exe || exit /b 1
echo.
echo Pronto. Conversar: build\chat_llm.exe -r 1.2     Avaliar a base: build\eval_llm.exe


