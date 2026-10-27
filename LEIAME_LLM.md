# Satiro-IA: LLM transformer em assembly

> **Nota:** o corpus de treino (`dados\corpus.tok`) foi removido deste projeto, então o pré-treino
> (`treino_llm.bat`) não roda mais. Os trechos sobre corpus, Pira e treino abaixo descrevem o
> processo original. O chat e o ajuste fino seguem funcionando. Veja o README.md.

Tudo é montado com `build\asm.exe <fonte> <saida.obj> [-DNOME=valor]` e ligado com
`build\pelink.exe <obj> <exe>`. Opções com aspas (`-DMODELO="..."`) devem ir num `.bat`.

## Peças

| Fonte | O que faz |
|---|---|
| `tf_bpe_main.asm` | treina o tokenizador BPE (`-DTEXTO`, `-DSAIDA`, `-DNV=4096`, `-DBPEMAX` bytes) |
| `tf_bpe_cod_main.asm` | texto → tokens uint16 (`-DTOK16 -DTV=n -DVOCAB -DTEXTO -DSAIDA`) |
| `tf_corpus_main.asm` | pré-treino e ajuste fino (retoma sozinho do `.pos`) |
| `tf_eval_main.asm` | avaliação em texto não visto: P(alvo), acerto e bits por byte |
| `tf_sft_fmt_main.asm` | pares do Pira → texto `P: pergunta` / `R: resposta` |
| `tf_gen_main.asm` | gera texto a partir da entrada padrão |
| `tf_chat_main.asm` | chat (`/sair` encerra) |

## Opções do modelo (iguais em todos os programas de um mesmo modelo)

`-DTT` contexto (256), `-DTD` largura (64), `-DTH` cabeças (4), `-DTF` camada interna (256),
`-DTL` blocos (2), `-DTV` vocabulário (256 = bytes). Com BPE: `-DTOK16 -DTV=<tokens>`.
Todas as dimensões precisam ser múltiplas de 8 (e `TD/TH` também).

## Opções do treino

`-DLR` (1e-3), `-DSEQLOTE` (8 sequências por passo), `-DNTH` (8 threads), `-DAQUEC` (500 passos de
aquecimento), `-DPASSOS_TOTAL=n` (decaimento linear até `-DLRMIN` × LR), `-DCORTE` (25, norma máxima
do gradiente), `-DCKPT` (checkpoint a cada 64 Mi tokens), `-DNTRAIN` (limite de tokens),
`-DNOVO` (começa do zero; recusa sobrescrever sem `-DSOBRESCREVER`), `-DBASE="arquivo"` (com `-DNOVO`:
ajuste fino a partir de outro modelo).

## Opções do gerador e do chat (linha de comando)

`-t` temperatura (0.8; 0 = guloso), `-k` top-k (40), `-p` top-p (0.95), `-r` penalidade de repetição
(1 = desligada; use ~1.2 só com BPE), `-s` semente, `-n` tokens a gerar, `-g` guloso.

## Receita com BPE

1. `tf_bpe_main` num trecho do corpus (8 MB bastam) → `vocab_bpe.bin`.
2. `tf_bpe_cod_main` no corpus inteiro → `corpus.tok`; idem para o texto de validação.
3. `tf_corpus_main -DTOK16 -DTV=4096 -DCORPUS="corpus.tok" ...` (pré-treino).
4. `tf_sft_fmt_main` + `tf_bpe_cod_main` → `sft_pr.tok`; `tf_corpus_main ... -DBASE=... -DNOVO` (ajuste fino).
5. `tf_chat_main -DTOK16 -DTV=4096 -DVOCAB=... -DMODELO=...`.

## Chat com aprendizado contínuo

`build\chat_llm.exe` aprende com cada conversa: depois de cada resposta, dá um passo de Adam
(taxa `LRVIVO` = 1e-4) sobre os últimos 257 tokens do histórico e grava os pesos em
`dados\modelo_vivo.bin` e `dados\modelo_vivo.otim`. O modelo base `dados\modelo_chat4.bin`
nunca é alterado. Para voltar ao modelo original, apague `dados\modelo_vivo.*`.
Ao refazer o ajuste fino (`ajuste_fino_llm.bat`), o `modelo_vivo.*` antigo é movido
automaticamente para `dados\modelo_vivo_antigo.*`.

## Modelo de produção

`treino_llm.bat` treina a LLM BPE (TD 128, 8 cabeças, TF 512, 4 blocos, ~1,35 mi parâmetros) sobre
`dados\corpus.tok` (o corpus inteiro já codificado: 9,25 bi tokens) e retoma sozinho se rodado de novo.
`ajuste_fino_llm.bat` parte de `dados\modelo_chat3.bin`, grava `dados\modelo_chat4.*` (com os pares
do `sft_pr.tok`) e monta `build\chat_llm.exe`; o checkpoint `modelo_llm.bin` só é usado para montar
`build\gen_llm.exe` e `build\eval_llm.exe`.

Medido com 16 MB de texto (TT 256, TD 64): por bytes, 2,64 bits/byte; com BPE de 4096 tokens,
2,26 bits/byte, no mesmo tempo de treino.
