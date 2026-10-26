@echo off
rem Pre-treino da LLM (BPE 4096, TT 256, TD 128, 8 cabecas, TF 512, 4 blocos; ~1,35 mi parametros)
rem sobre dados\corpus.tok, SEM FIM: ao chegar ao fim do corpus volta ao comeco (-DMULTIEPOCA).
rem Checkpoint a cada 4 Mi tokens (~6 min) para perder pouco se o PC desligar.
rem A taxa cai ate 0,1 x LR ao longo da primeira passada e fica assim depois.
rem Se o processo cair, recomeca do ultimo checkpoint em 30 s. Para parar de vez: crie o arquivo
rem PARAR_TREINO nesta pasta e encerre build\treino_llm.exe. Log: treino_llm_log.txt
cd /d %~dp0
if not exist dados\corpus.tok (
  echo [erro] dados\corpus.tok nao encontrado: sem corpus nao ha treino. Veja o README.
  exit /b 1
)
set CFG=-DTOK16 -DTV=4096 -DTT=256 -DTD=128 -DTH=8 -DTF=512 -DTL=4
build\asm.exe tf_corpus_main.asm build\treino_llm.obj %CFG% -DMULTIEPOCA -DCORPUS="dados/corpus.tok" -DPASSOS_TOTAL=4515186 -DCKPT=4194304 -DMODELO="dados/modelo_llm.bin" -DMODELO_TMP="dados/modelo_llm.tmp" -DOTIM="dados/modelo_llm.otim" -DOTIM_TMP="dados/modelo_llm.otim.tmp" -DPOSICAO="dados/modelo_llm.pos" -DPOSICAO_TMP="dados/modelo_llm.pos.tmp" || exit /b 1
build\pelink.exe build\treino_llm.obj build\treino_llm.exe || exit /b 1
rem Ao iniciar manualmente, a parada anterior (PARAR_TREINO) e removida.
if exist PARAR_TREINO del PARAR_TREINO
:laco
if exist PARAR_TREINO goto fim
start "" /b /wait /belownormal build\treino_llm.exe >> treino_llm_log.txt 2>&1
if exist PARAR_TREINO goto fim
echo [treino encerrou; recomecando em 30 s] >> treino_llm_log.txt
timeout /t 30 /nobreak >nul
goto laco
:fim
echo [treino parado pelo arquivo PARAR_TREINO] >> treino_llm_log.txt

