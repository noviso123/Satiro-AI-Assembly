# Componentes de terceiros e origem dos dados

Este arquivo lista o que não é de autoria do Satiro-IA e as condições que se aplicam.

## 1. Corpus Pira (perguntas e respostas sobre oceano, costa brasileira e clima)

- **O que é usado:** os pares de pergunta e resposta derivados do Pira, em `dados\sft_pr.txt`,
  `dados\sft_pr.tok` e `dados\pira_valid.tok`. Esses arquivos são gerados a partir dos arquivos
  originais do Pira (`pira_train.tsv`, `pira_valid.tsv`, `pira_test.tsv`), que não estão mais no
  projeto.
- **Licença:** o código-fonte original indica licença **MIT** para o Pira (comentário em
  `chat_core.asm`, que não é mais usado pelo chat).
- **Atribuição necessária:** a licença MIT exige que o aviso de copyright e o texto da licença
  acompanhem as cópias do software. **Falta incluir o aviso de copyright exato do projeto Pira**,
  que deve ser copiado da fonte original antes de publicar. Não o inventei.

Texto da licença MIT (aplica-se ao Pira):

> Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
> associated documentation files (the "Software"), to deal in the Software without restriction,
> including without limitation the rights to use, copy, modify, merge, publish, distribute,
> sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all copies or
> substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT
> NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
> NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
> DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## 2. Corpus de treino original (`corpus-ptbr-v1.tsv`, removido)

- **Origem:** não documentada no projeto. **Não é possível afirmar a licença.**
- **Situação:** o arquivo foi removido. O modelo treinado a partir dele (`dados\modelo_llm.bin`,
  `dados\modelo_chat*.bin`) pode herdar restrições de uso desses textos. Antes de uso comercial dos
  modelos, verifique a origem dos textos com um advogado.

## 3. Ferramentas de terceiros

- **Windows (kernel32):** o programa usa as chamadas do sistema Windows, sob as condições da Microsoft.
- **Nenhum outro componente externo** é incluído no código-fonte. O montador e o linker são do próprio projeto.
