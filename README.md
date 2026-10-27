# Satiro-IA

Um modelo de linguagem (transformer) escrito **inteiro em assembly x86-64** para Windows, com
montador e linker próprios. Não usa Python, PyTorch, NASM nem compilador C.

> **Estado atual:** o modelo é pequeno (≈1,35 milhão de parâmetros) e treinado com pouco texto.
> Ele responde cumprimentos, agradecimentos e algumas perguntas do treino, mas **erra com frequência**
> em perguntas gerais. Veja a seção [Limitações](#limitações).

---

## Requisitos

- **Windows 10 ou 11, 64 bits.**
- **Processador com AVX2 e FMA** (Intel desde ~2013, AMD desde ~2015). Sem isso, os programas
  mostram uma mensagem e encerram.
- Memória: o chat usa pouco; o treino usa ~300 MB de RAM, mais o disco para o corpus.
- Para a interface visual: **PowerShell 5.1** (já vem no Windows) e um navegador.
- **Não é preciso instalar nada**: o montador `build\asm.exe` e o linker `build\pelink.exe` estão no projeto.

---

## Estrutura do projeto

| Caminho | Conteúdo |
|---|---|
| `build\` | montador, linker e programas compilados (gerados; ignorados pelo Git) |
| `dados\vocab_bpe.bin` | vocabulário do tokenizador (4096 tokens) |
| `dados\pira_*.tok` | textos de validação já tokenizados |
| `dados\modelo_*` | pesos dos modelos (**não incluídos no repositório**; ver [Modelos](#modelos)) |
| `dados\conversas_basicas.txt` | conversas básicas (cumprimentos, identidade, educação) |
| `interface\` | interface visual (servidor PowerShell + página HTML) |
| `tf_*.asm` | código-fonte do transformer, treino, chat e avaliação |
| `lm_*.asm` | implementação antiga (MLP por bytes), mantida como referência e usada pelo valida_tudo |
| `tools\asm\`, `tools\pelink*` | código-fonte do montador e do linker |
| `LEIAME_LLM.md` | referência técnica com todas as opções de compilação |
| `LICENSE` | GNU AGPL-3.0 (uso livre) |
| `LICENSE-COMERCIAL.md` | termos da licença comercial paga |
| `CONTRIBUTING.md` | como contribuir e o acordo de contribuição |

---

## Instalação

1. Baixe ou clone o repositório numa pasta, por exemplo `C:\Satiro-IA`. O montador
   (`build\asm.exe`) e o linker (`build\pelink.exe`) acompanham o repositório; os demais
   executáveis e **os modelos treinados não** (ver [Modelos](#modelos)).
2. Abra um terminal (PowerShell) **na pasta do projeto**.
3. Se você tiver os modelos em `dados\` (veja [Modelos](#modelos)), confira que o chat abre
   (ele é o primeiro teste completo):

```powershell
"/sair" | .\build\chat_llm.exe
```

Deve aparecer: `Satiro-IA (transformer em assembly). Digite /sair para encerrar.`

Sem os modelos, monte e valide o que dá com `.\valida_tudo.bat` (os testes numéricos não
dependem de modelos; o chat e o avaliador sim).

Os programas procuram os dados a partir da **pasta do projeto**. Eles mudam de pasta sozinhos
ao iniciar, então também funcionam se chamados de outro lugar.

---

## Como usar

### 1. Conversar pelo terminal

```powershell
.\build\chat_llm.exe -r 1.2
```

- Digite a mensagem e aperte Enter. `/sair` encerra.
- `-r 1.2` reduz a repetição de palavras (recomendado).

Opções de amostragem (valem para o chat e para o gerador):

| Opção | Efeito | Padrão |
|---|---|---|
| `-t 0.8` | temperatura (0 = sempre a resposta mais provável) | 0.8 |
| `-k 40` | considera só as 40 opções mais prováveis | 40 |
| `-p 0.95` | nucleus: soma de probabilidade considerada | 0.95 |
| `-r 1.2` | penalidade de repetição | 1 (desligada) |
| `-s 7` | semente (mesma semente = mesma resposta) | relógio |
| `-n 60` | tamanho máximo da resposta, em tokens | 400 |
| `-g` | guloso (mesmo que `-t 0`) | desligado |

### Configurações de geração (linha de comando e interface)

| Opção | Efeito | Padrão | Faixa |
|---|---|---|---|
| `-t` / `temperatura` | aleatoriedade (0 = sempre a mais provável) | 0.8 | 0 a 2 |
| `-k` / `top_k` | só as K opções mais prováveis | 40 | 1 a 200 |
| `-p` / `top_p` | nucleus: massa de probabilidade considerada | 0.95 | 0.05 a 1 |
| `-r` / `repeticao` | penalidade de repetição (1 = desligada) | 1.2 | 1 a 3 |
| `-c` / `contexto` | quantos tokens anteriores o modelo olha | 256 | 8 a 256 |
| `-n` / `max_tokens` | tamanho máximo da resposta | 120 | 10 a 400 |
| `-s` / `semente` | semente (0 = aleatória; mesma semente = mesma resposta) | 0 | |
| `mostrar_modelo` | mostra a resposta do modelo quando ele "não sabe" | 0 | 0 ou 1 |

Os padrões desta tabela são os de `dados\config_chat.json` (usados pela interface). Pela linha de
comando, os padrões são os da tabela anterior (`-r` 1 desligado, `-n` 400).

Na interface, o painel **Configurações da IA** aplica os valores e reinicia o chat. Os valores ficam em
`dados\config_chat.json`. Valores fora da faixa são recusados.

O contexto só limita quando a conversa ocupa mais tokens do que ele. Para perguntas curtas, o efeito é nulo.

### Documentos anexados (PDF, Word, TXT, MD, CSV)

Na interface, o botão **Anexar** envia um arquivo (até 300 MB, enviado em partes). O servidor extrai o texto, divide em
trechos e passa a responder com base nele, citando o nome do arquivo.

- **Suportados:** `.pdf` (com texto embutido), `.docx`, `.txt`, `.md`, `.csv`.
- **Não suportados:** `.doc` (Word antigo) e `.xls`. Salve como `.docx`.
- **PDF escaneado** (imagem) não tem texto e não é lido: não há OCR no projeto. PDFs com fontes de
  codificação própria podem sair com caracteres trocados.
- Os documentos ficam em `dados\documentos\`. **Remover** tira o documento das respostas e move o texto
  para `dados\documentos\removidos\`; nada é apagado de vez.
- A resposta com base em documento é uma **busca por frases**, não geração: o modelo não escreve o texto.

### Pensamento profundo e limpeza de conversa

- **Pensamento profundo** (opção na configuração): mostra os passos da resposta, como os termos da
  pergunta, as fontes usadas, a semelhança com perguntas conhecidas e o nível de confiança. É uma busca
  verificável nas fontes; não é raciocínio do modelo.
- **Limpar conversa:** apaga a conversa da tela e reinicia o chat, esquecendo o histórico. Documentos e
  correções continuam salvos.
- **Restaurar padrão de fábrica** (painel de configurações): volta tudo ao estado original — modelo de
  fábrica, configurações padrão, sem correções, sem documentos e sem aprendizado contínuo. **Nada é
  apagado:** o que existia é movido para `dados\backups\antes-do-reset-<data-hora>\`. Para voltar a um
  backup, copie os arquivos de volta manualmente. O modelo de fábrica fica em `dados\fabrica\`.

Todas as ações destrutivas pedem confirmação dentro da própria página (botões Confirmar e Cancelar).
O reset exige digitar a palavra RESTAURAR.

### 2. Conversar pela interface visual

```powershell
powershell -ExecutionPolicy Bypass -File interface\server.ps1
```

Depois abra **http://localhost:8765** no navegador. Para encerrar, aperte **Ctrl+C** na janela do
PowerShell.

A interface responde nesta ordem:
1. **Correção sua** para a mesma pergunta (sempre a mais recente).
2. **Regras básicas:** cumprimentos, identidade, agradecimento e despedida (respostas fixas).
3. **Documentos anexados:** trechos com termos em comum com a pergunta.
4. **Perguntas conhecidas:** as do treino (`dados\sft_pr.txt`) e as que você ensinou
   (`dados\ensino_usuario.txt`). Pergunta igual, ou parecida (pelo menos 2 palavras em comum e 50%
   de semelhança), recebe a resposta cadastrada.
5. **Não sabe:** para o resto, a interface diz que não sabe responder e convida a ensinar. A
   resposta gerada pelo modelo não é mostrada, porque não é confiável.

**Corrigir:** cada resposta da IA tem o botão **Corrigir**. Escreva a resposta certa e clique em
"Salvar correção". A correção é gravada em `dados\ensino_usuario.txt` e vale na hora: a mesma
pergunta, mesmo com outras palavras parecidas, passa a receber a sua resposta. Para apagar tudo que
você ensinou, apague esse arquivo e reinicie o servidor.

**O modelo não muda com a correção.** Ela vale pela busca, não pelos pesos do modelo. A
incorporação aos pesos acontece pelo ciclo automático descrito abaixo, quando você acumula
correções suficientes.

### 3. Gerar texto a partir de um início

```powershell
echo O Brasil | .\build\gen_llm.exe -n 100 -r 1.2
```

### 4. Avaliar o modelo em texto que ele não viu

```powershell
.\build\eval_llm.exe
```

Mostra três números: **acerto do próximo token** (quanto maior, melhor), **probabilidade média** e
**bits por byte** (quanto menor, melhor).

---

## Ciclo automático de correções

Quando você corrige respostas suficientes (`N`, em `dados\ciclo_config.json`, padrão 10), o servidor
roda sozinho, em segundo plano, o ciclo `interface\ciclo_correcoes.ps1`:

1. Monta o treino: o texto de oceano (`dados\sft_pr.tok`, repetido para o modelo não esquecer),
   as conversas básicas e as suas correções.
2. Faz um ajuste fino a partir do modelo de produção, com a taxa `lr` do config. O resultado vai
   para um **candidato**; o modelo de produção não é alterado.
3. Testa o modelo atual e o candidato em dois conjuntos: o texto de validação de oceano
   (`dados\pira_valid.tok`) e o teste básico (`dados\teste_basico.txt`, 36 pares que não estão no treino).
4. **Só troca se o candidato não piorar no teste básico e piorar no máximo `tolerancia` (50) na
   validação.** Antes de trocar, guarda o modelo atual em `dados\versoes\<data-hora>\`.
5. Se trocou, o servidor reinicia o chat na mensagem seguinte.

Tudo é registrado em `dados\ciclo_log.txt`.

**Voltar para uma versão anterior:**

```powershell
powershell -ExecutionPolicy Bypass -File interface\reverter.ps1                      # lista as versões
powershell -ExecutionPolicy Bypass -File interface\reverter.ps1 -Versao <pasta>       # volta para ela
```

**Limites reais do ciclo:**
- Com os dados atuais, a maioria dos ajustes **não passa** no teste: o ajuste tende a piorar o conhecimento
  de oceano. O ciclo foi feito para recusar essas trocas. Um ajuste passou com taxa 1e-5 e custou 50 pontos
  na validação, dentro da tolerância.
- A tolerância é uma escolha sua: quanto menor, mais conservador o ciclo.
- Cada ciclo leva de 5 a 10 minutos e usa a CPU enquanto roda.
- Ao trocar o modelo, a memória de aprendizado contínuo (`modelo_vivo`) é guardada em `dados\versoes`, porque
  foi aprendida sobre o modelo antigo.
- As correções ficam salvas em `dados\ensino_usuario.txt` e valem na hora pela busca, mesmo que o ciclo
  recuse a troca do modelo.

## Como o chat aprende

Cada resposta do chat dá **um passo de aprendizado** sobre a conversa recente. Os pesos evoluídos
ficam em `dados\modelo_vivo.bin` e `dados\modelo_vivo.otim`. O modelo base (`dados\modelo_chat*.bin`)
**não muda**.

- Para **voltar ao modelo original**, apague `dados\modelo_vivo.*` (ou mova para outra pasta).
- Ao **refazer o ajuste fino**, o aprendizado antigo deve ser retirado: o `ajuste_fino_llm.bat`
  já move `modelo_vivo.*` para um backup antes de treinar.

---

## Treinar

### Preparar os dados

> **Atenção:** o corpus de treino (`dados\corpus.tok`, 17,6 GB) **não está mais neste projeto**.
> Sem ele, o pré-treino não roda: `treino_llm.bat` agora avisa e encerra. O chat e o ajuste fino
> funcionam normalmente, porque usam só o vocabulário e os modelos já treinados.
> Para treinar de novo, é preciso um corpus de texto em português (UTF-8) e codificá-lo com os passos abaixo.

1. **Treinar o vocabulário BPE** (já existe `dados\vocab_bpe.bin`; só refaça se mudar o corpus).
   O programa `build\bpe.exe` não está mais na pasta. Para recompilar:

```bat
build\asm.exe tf_bpe_main.asm build\bpe.obj -DTEXTO="dados/seu_texto.txt" -DSAIDA="dados/vocab_novo.bin"
build\pelink.exe build\bpe.obj build\bpe.exe
build\bpe.exe
```

2. **Codificar o corpus** em tokens (`dados\corpus.tok`), com `tf_bpe_cod_main.asm`.
   O LEIAME_LLM.md traz a linha de compilação exata.

### Pré-treino (sem fim)

```powershell
.\treino_llm.bat
```

- Treina sobre `dados\corpus.tok`. Ao chegar ao fim do corpus, **volta ao começo** e continua.
- Salva um checkpoint a cada 4 milhões de tokens (`dados\modelo_llm.*`).
- Se o processo cair, o script **reinicia sozinho** a partir do último checkpoint.
- Se o computador desligar, o treino para: rode `treino_llm.bat` de novo para retomar.
- Para **parar de vez**, crie o arquivo `PARAR_TREINO` na pasta do projeto e encerre o processo
  `build\treino_llm.exe`. Ao iniciar `treino_llm.bat` de novo, o arquivo é removido automaticamente.
- O progresso fica em `treino_llm_log.txt`.

### Ajuste fino com conversas e perguntas

```powershell
powershell -ExecutionPolicy Bypass -File interface\gera_conversas.ps1   # gera dados\conversas_basicas.txt
.\ajuste_fino_llm.bat                                                    # ajusta e monta build\chat_llm.exe
```

O `ajuste_fino_llm.bat` parte de `dados\modelo_chat3.bin` (modelo de conversa), treina com as
perguntas cadastradas (`dados\sft_pr.tok`) e grava `dados\modelo_chat4.*`. O `build\chat_llm.exe`
é montado a partir desse `modelo_chat4`. O aprendizado contínuo antigo (`modelo_vivo`) é movido
para `dados\modelo_vivo_antigo.*` antes do ajuste, porque não vale para o modelo novo.

---

## Compilar tudo do zero

Os programas são montados por `build\asm.exe` e ligados por `build\pelink.exe`. Exemplo para o chat:

```bat
build\asm.exe tf_chat_main.asm build\chat_llm.obj -DTOK16 -DTV=4096 -DTT=256 -DTD=128 -DTH=8 -DTF=512 -DTL=4 -DVOCAB="dados/vocab_bpe.bin" -DMODELO="dados/modelo_chat4.bin"
build\pelink.exe build\chat_llm.obj build\chat_llm.exe
```

Use um arquivo `.bat` para os caminhos com aspas (o PowerShell perde as aspas dos `-D`).
Todas as opções de compilação estão em `LEIAME_LLM.md`.

---

## Modelos

Os pesos treinados **não estão no repositório** (ficam em `dados\modelo_*`, ignorados pelo Git),
e o mesmo vale para os dados de ajuste fino derivados do Pira (`dados\sft_pr.*`,
`dados\pira_valid.tok`) e pelo corpus de pré-treino. Para usar o chat sem treinar, é preciso ter
`dados\modelo_chat*.bin` e `dados\vocab_bpe.bin` (o vocabulário este sim vem no repositório).
Se você recebeu o projeto sem os modelos, precisa treinar (ver acima).

---

## Testes e validação

- **Suíte completa:** `valida_tudo.bat` monta tudo (produção, pipeline lm, testes, ferramentas de
  dados), roda os testes numéricos e os smoke de chat/geração; sai com exit 0 só se tudo passar.
- **Gradiente (derivada direcional):** `tests\tf_dir_check.asm` confere o backward do transformer
  região por região de parâmetros.
- **Gradiente (parâmetro a parâmetro):** `tests\tf_grad_check.asm` compara com diferenças finitas
  (lento: um forward por parâmetro testado).
- **Multiplicação de matrizes:** `tests\tf_mm_check.asm`.
- **Lote com threads:** `tests\batch_check.asm` (o lote paralelo tem que bater com a soma sequencial).
- **Regressão do codificador:** `tests\enc_regressao.asm` (as formas de encoding usadas pelo projeto).
- **Codificador do montador:** `tests\as_enc_check.ps1` compara com o NASM (requer o NASM instalado
  em `C:\Program Files\NASM`).

Todos os testes em `tests\*.asm` são montados com `build\asm.exe` e ligados com `build\pelink.exe`,
como os programas principais.

---

## Limitações

- **Qualidade:** o modelo ainda gera respostas sem sentido para perguntas gerais (medido: 32% de
  acerto do próximo token em texto de oceano, 1,65 bits por byte). A interface sinaliza essas
  respostas, mas não as corrige.
- **Conversa direta com o modelo:** cumprimentos e agradecimentos só saem certos pela camada de
  regras da interface. Sem ela, o modelo responde fora de contexto.
- **Dados:** as conversas básicas são poucas (862 pares gerados por modelos de frase) e
  repetitivas. Não há um conjunto grande de conversas reais.
- **Hardware:** exige AVX2 e FMA. Não há versão para CPUs sem essas instruções.
- **Aprendizado contínuo:** aprende com tudo o que é digitado no chat, inclusive respostas do próprio
  modelo. Sem filtro, o modelo pode reforçar erros.
- **Testes:** a suíte automatizada é o `valida_tudo.bat` (monta tudo e roda os testes numéricos).

---

## Licença

O projeto tem **dupla licença**:

1. **GNU AGPL-3.0** (arquivo `LICENSE`), para uso livre. Você pode usar, estudar, modificar e
   redistribuir o código. Se você distribuir o projeto modificado, ou oferecer uma versão modificada
   como serviço pela rede, precisa disponibilizar o código-fonte completo sob a mesma AGPL-3.0.
2. **Licença comercial paga** (arquivo `LICENSE-COMERCIAL.md`), para quem quer usar o projeto
   comercialmente sem as obrigações da AGPL, por exemplo sem abrir o código.

Quem contribuir com código precisa aceitar o acordo de contribuição em `CONTRIBUTING.md`, que
permite ao titular oferecer a licença comercial.

Os **dados de treino** têm origem própria e não estão cobertos pela licença do código. Antes de usar
os modelos treinados comercialmente, confira as condições de uso dos textos de origem.

Componentes de terceiros, atribuições e a situação do corpus original estão em `THIRD_PARTY.md`.
Antes de publicar, é preciso acrescentar o aviso de copyright do projeto Pira, exigido pela licença MIT.
