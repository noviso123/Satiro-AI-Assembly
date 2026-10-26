# Interface visual do Satiro-IA: servidor local que conversa com build\chat_llm.exe.
# Uso (a partir da raiz do projeto):  powershell -ExecutionPolicy Bypass -File interface\server.ps1
# Abra no navegador: http://localhost:8765
#
# Ordem de resposta:
#   1. correcao sua para a mesma pergunta (sempre a mais recente);
#   2. regras basicas (cumprimento, identidade, agradecimento, despedida);
#   3. documentos anexados (trechos com termos em comum com a pergunta);
#   4. perguntas conhecidas: as do treino (dados\sft_pr.txt) e as que voce ensinou;
#   5. se nada disso serve, diz que nao sabe. O modelo ainda recebe a mensagem (para aprender com a
#      conversa); a resposta gerada so aparece se "mostrar_modelo" estiver ligado na configuracao.
#
# Pensamento profundo (configuracao): mostra os passos que levaram a resposta (termos, fontes,
# semelhanca, confianca). Ele e uma busca verificavel nas fontes, nao raciocinio do modelo.

$ErrorActionPreference = 'Stop'
$root = (Get-Item $PSScriptRoot).Parent.FullName
$exe = Join-Path $root 'build\chat_llm.exe'
$pagina = Join-Path $PSScriptRoot 'index.html'
$arquivoPares = Join-Path $root 'dados\sft_pr.txt'
$arquivoEnsino = Join-Path $root 'dados\ensino_usuario.txt'
$arquivoHistorico = Join-Path $root 'dados\ensino_historico.txt'
$prefixo = 'http://localhost:8765/'
$UTF8SemBom = New-Object Text.UTF8Encoding($false)

$PARES_LIMIAR = 0.50        # semelhanca minima (0..1) para usar um par conhecido
$PARES_MIN_PALAVRAS = 2     # e pelo menos duas palavras em comum
$MAX_TEXTO = 500            # tamanho maximo de pergunta e resposta ensinadas
$STOPWORDS = @('de','da','do','das','dos','a','o','as','os','e','em','um','uma','uns','umas','no','na','nos','nas','para','por','com','que','qual','quais','como','quando','quem','se','ao','aos','mais','ser','sao','foi','era','isso','esse','essa','ele','ela','the')

function Normaliza([string]$s) {
    $d = $s.ToLowerInvariant().Normalize([Text.NormalizationForm]::FormD)
    $sb = New-Object Text.StringBuilder
    foreach ($c in $d.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($c) -ne [Globalization.UnicodeCategory]::NonSpacingMark) { [void]$sb.Append($c) }
    }
    return ($sb.ToString() -replace '[^a-z0-9 ]', ' ' -replace '\s+', ' ').Trim()
}

function Palavras([string]$s) {
    $lista = @()
    foreach ($p in (Normaliza $s).Split(' ', [StringSplitOptions]::RemoveEmptyEntries)) {
        if ($p.Length -ge 3 -and -not ($STOPWORDS -contains $p)) { $lista += $p }
    }
    return @($lista | Select-Object -Unique)
}

# documentos anexados (depende de Palavras e Normaliza, por isso vem aqui)
. (Join-Path $PSScriptRoot 'documentos.ps1')

# lista de pares conhecidos: { P, R, Tok, Origem, Norm }  (Origem: 'treino' ou 'ensino')
$pares = New-Object System.Collections.ArrayList

function Adiciona-Par([string]$pergunta, [string]$resposta, [string]$origem) {
    [void]$pares.Add([pscustomobject]@{ P = $pergunta; R = $resposta; Tok = (Palavras $pergunta); Origem = $origem; Norm = (Normaliza $pergunta) })
}

function Le-Pares-Arquivo([string]$caminho, [string]$origem) {
    if (-not (Test-Path $caminho)) { return }
    $pergunta = $null
    foreach ($linha in [IO.File]::ReadAllLines($caminho, [Text.Encoding]::UTF8)) {
        if ($linha.StartsWith('P: ')) { $pergunta = $linha.Substring(3) }
        elseif ($linha.StartsWith('R: ') -and $pergunta) {
            Adiciona-Par $pergunta $linha.Substring(3) $origem
            $pergunta = $null
        }
    }
}

Le-Pares-Arquivo $arquivoPares 'treino'
# o arquivo de treino repete cada par varias vezes (epocas): fica um de cada par pergunta+resposta
$unicos = @($pares | Sort-Object P, R -Unique)
$pares.Clear()
foreach ($u in $unicos) { [void]$pares.Add($u) }
Le-Pares-Arquivo $arquivoEnsino 'ensino'
Carrega-Documentos

function Busca-Par([string]$texto) {
    $norm = Normaliza $texto
    foreach ($par in $pares) {
        if ($par.Norm -eq $norm) { return [pscustomobject]@{ R = $par.R; Origem = $par.Origem; Score = 1.0 } }
    }
    $tok = Palavras $texto
    if ($tok.Count -eq 0) { return $null }
    $melhor = $null; $melhorScore = 0.0
    foreach ($par in $pares) {
        $inter = @($tok | Where-Object { $par.Tok -contains $_ }).Count
        if ($inter -lt $PARES_MIN_PALAVRAS) { continue }
        $uniao = $tok.Count + $par.Tok.Count - $inter
        $score = $inter / $uniao
        if ($score -gt $melhorScore) { $melhorScore = $score; $melhor = $par }
    }
    if ($melhor -and $melhorScore -ge $PARES_LIMIAR) { return [pscustomobject]@{ R = $melhor.R; Origem = $melhor.Origem; Score = $melhorScore } }
    return $null
}

function Busca-Ensino([string]$texto) {
    # correcao do usuario para a mesma pergunta: vale a mais recente
    $norm = Normaliza $texto
    $ens = @($pares | Where-Object { $_.Origem -eq 'ensino' -and $_.Norm -eq $norm })
    if ($ens.Count -gt 0) { return $ens[-1] }
    return $null
}

function Grava-Ensino([string]$pergunta, [string]$resposta) {
    # historico de correcoes: so cresce (conta para o ciclo)
    $linha = "P: $pergunta`nR: $resposta`n`n"
    [IO.File]::AppendAllText($arquivoHistorico, $linha, $UTF8SemBom)
    # correcoes atuais: uma por pergunta, a mais recente (substitui a anterior)
    $norm = Normaliza $pergunta
    $manter = @($pares | Where-Object { -not ($_.Origem -eq 'ensino' -and $_.Norm -eq $norm) })
    $pares.Clear()
    foreach ($p in $manter) { [void]$pares.Add($p) }
    Adiciona-Par $pergunta $resposta 'ensino'
    $texto = New-Object Text.StringBuilder
    foreach ($p in @($pares | Where-Object { $_.Origem -eq 'ensino' })) { [void]$texto.Append("P: $($p.P)`nR: $($p.R)`n`n") }
    [IO.File]::WriteAllText($arquivoEnsino, $texto.ToString(), $UTF8SemBom)
}

$TEXTO_IDENTIDADE = 'Eu sou o Satiro-IA, um modelo de linguagem feito em assembly x86-64. Ainda estou aprendendo: respondo bem a saudacoes e a algumas perguntas sobre oceano, costa brasileira e mudancas climaticas. Quando nao sei algo, digo isso, e voce pode me ensinar a resposta certa. Tambem posso ler documentos que voce anexar.'
$TEXTO_AJUDA = 'Posso cumprimentar, falar sobre mim, responder perguntas que eu conheco e responder com base em documentos que voce anexar (PDF, Word, TXT, MD, CSV). Se eu errar, voce pode me corrigir com o botao "Corrigir", e eu passo a lembrar da resposta certa.'
$TEXTO_NAO_SEI = 'Ainda nao sei responder isso com seguranca. Se voce souber a resposta, clique em "Corrigir" e me ensine, ou anexe um documento sobre o assunto.'

function Regra-Basica([string]$texto) {
    $n = Normaliza $texto
    if ($n -match '^(oi|ola|bom dia|boa tarde|boa noite|e ai|hey)\b') { return 'Olá! Em que posso ajudar?' }
    if ($n -match 'tudo bem|como vai|como voce esta') { return 'Estou bem, obrigado por perguntar! Em que posso ajudar?' }
    if ($n -match 'quem (e|voce)|qual (e )?(o )?seu nome|voce e quem|o que voce e') { return $TEXTO_IDENTIDADE }
    if ($n -match 'o que voce (faz|sabe|pode)|^ajuda') { return $TEXTO_AJUDA }
    if ($n -match 'obrigad|valeu|^obg') { return 'De nada!' }
    if ($n -match '^(tchau|adeus)|ate logo|ate mais') { return 'Até logo! Volte quando quiser.' }
    return $null
}

# Configuracoes de geracao (dados\config_chat.json). Valores fora da faixa sao recusados.
$configArq = Join-Path $root 'dados\config_chat.json'
$CONFIG_PADRAO = [pscustomobject]@{ temperatura = 0.8; top_k = 40; top_p = 0.95; repeticao = 1.2; contexto = 256; max_tokens = 120; semente = 0; mostrar_modelo = 0; pensamento_profundo = 0 }
$CONFIG_FAIXA = @{
    temperatura = @(0.0, 2.0); top_k = @(1, 200); top_p = @(0.05, 1.0); repeticao = @(1.0, 3.0)
    contexto = @(8, 256); max_tokens = @(10, 400); semente = @(0, 2147483647); mostrar_modelo = @(0, 1); pensamento_profundo = @(0, 1)
}
$CULTURA = [Globalization.CultureInfo]::InvariantCulture
$CONFIG_INTEIROS = @('top_k','contexto','max_tokens','semente','mostrar_modelo','pensamento_profundo')

function Valida-Config($c) {
    $saida = [ordered]@{}
    foreach ($nome in $CONFIG_PADRAO.PSObject.Properties.Name) {
        $valor = $c.$nome
        if ($null -eq $valor -or "$valor" -eq '') { $valor = $CONFIG_PADRAO.$nome }
        $num = [double]::Parse("$valor", $CULTURA)
        $min, $max = $CONFIG_FAIXA[$nome]
        if ($num -lt $min -or $num -gt $max) { throw "$nome fora da faixa ($min a $max)" }
        if ($nome -in $CONFIG_INTEIROS) { $num = [int64][math]::Round($num) }
        $saida[$nome] = $num
    }
    return [pscustomobject]$saida
}

function Le-Config {
    if (Test-Path $configArq) {
        try { return Valida-Config (Get-Content $configArq -Raw -Encoding UTF8 | ConvertFrom-Json) }
        catch { Write-Host "config invalida, usando padroes: $($_.Exception.Message)" }
    }
    return Valida-Config $CONFIG_PADRAO
}

function Args-Chat($c) {
    $t = $c.temperatura.ToString('0.###', $CULTURA)
    $p = $c.top_p.ToString('0.###', $CULTURA)
    $r = $c.repeticao.ToString('0.###', $CULTURA)
    $a = "-t $t -k $($c.top_k) -p $p -r $r -c $($c.contexto) -n $($c.max_tokens)"
    if ([int64]$c.semente -gt 0) { $a += " -s $($c.semente)" }
    return $a
}

$script:config = Le-Config

function Inicia-Chat {
    $psi = New-Object System.Diagnostics.ProcessStartInfo $exe
    $psi.Arguments = Args-Chat $script:config
    $psi.WorkingDirectory = $root
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    Le-Ate-Prompt $p | Out-Null      # saudacao inicial termina em "\r\n> "
    return $p
}

# Le bytes do chat ate o prompt "\r\n> " (o texto da IA nunca tem quebra de linha)
function Le-Ate-Prompt($p) {
    $out = $p.StandardOutput.BaseStream
    $buf = New-Object System.Collections.Generic.List[byte]
    while ($true) {
        $b = $out.ReadByte()
        if ($b -lt 0) { break }
        $buf.Add([byte]$b)
        $n = $buf.Count
        if ($n -ge 4 -and $buf[$n-4] -eq 13 -and $buf[$n-3] -eq 10 -and $buf[$n-2] -eq 62 -and $buf[$n-1] -eq 32) { break }
    }
    return [Text.Encoding]::UTF8.GetString($buf.ToArray())
}

function Envia-Mensagem($p, $texto) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($texto + "`n")
    $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $p.StandardInput.BaseStream.Flush()
    $bruto = Le-Ate-Prompt $p
    $resp = $bruto -replace "`r`n> $", ''
    if ($resp.StartsWith('IA:')) { $resp = $resp.Substring(3).TrimStart() }
    return $resp
}

function Passos-Base([string]$msg) {
    $termos = Palavras $msg
    if ($termos.Count -eq 0) { return @('Não encontrei termos principais na pergunta.') }
    return @('Termos principais da pergunta: ' + ($termos -join ', '))
}

# Monta a resposta de uma mensagem. Devolve resposta, origem e (no pensamento profundo) os passos.
function Responde([string]$msg) {
    Verifica-Troca
    # o chat le uma linha por mensagem: quebras de linha viram espaco
    $msg = ($msg -replace '\s*[\r\n]+\s*', ' ').Trim()
    if ($msg.Length -eq 0) { return [pscustomobject]@{ resposta = ''; origem = 'regra' } }
    if ($msg -eq '/sair') {
        return [pscustomobject]@{ resposta = 'Para encerrar o servidor, use Ctrl+C na aba do terminal.'; origem = 'regra' }
    }
    $profundo = ($script:config.pensamento_profundo -eq 1)
    $passos = @(Passos-Base $msg)

    $corrigida = Busca-Ensino $msg
    if ($corrigida) {
        $passos += 'Encontrei uma correção sua para esta pergunta. Usei a mais recente.'
        return Monta $corrigida.R 'ensinada' $passos $profundo
    }
    $r = Regra-Basica $msg
    if ($r) {
        $passos += 'Reconheci uma mensagem básica (cumprimento, identidade, agradecimento ou despedida).'
        return Monta $r 'regra' $passos $profundo
    }
    $docs = @(Busca-Documentos $msg)
    if ($docs.Count -gt 0) {
        # frases iguais em documentos diferentes aparecem uma vez so
        $vistos = @{}
        $unicos = @($docs | Where-Object { if ($vistos.ContainsKey($_.S.Texto)) { $false } else { $vistos[$_.S.Texto] = $true; $true } })
        $passos += "Procurei nos documentos anexados: $($unicos.Count) trecho(s) com termos em comum."
        foreach ($d in $unicos) {
            $passos += ("Fonte '{0}': {1} de {2} termos da pergunta aparecem no trecho." -f $d.S.Doc, $d.Inter, (Palavras $msg).Count)
        }
        $confianca = if ($unicos[0].Inter -ge 3) { 'alta' } else { 'média' }
        $passos += "Confiança na resposta: $confianca."
        $texto = (($unicos | ForEach-Object { '"' + $_.S.Texto + '" (' + $_.S.Doc + ')' }) -join ' ')
        return Monta ('Encontrei isto nos seus documentos: ' + $texto) 'documento' $passos $profundo
    }
    $passos += 'Não encontrei trechos de documentos com termos suficientes em comum.'
    $conhecida = Busca-Par $msg
    if ($conhecida) {
        $origem = if ($conhecida.Origem -eq 'ensino') { 'ensinada' } else { 'cadastrada' }
        $passos += ("Encontrei uma pergunta conhecida parecida (semelhança {0:P0})." -f $conhecida.Score)
        $passos += 'Confiança na resposta: alta.'
        return Monta $conhecida.R $origem $passos $profundo
    }
    $passos += 'Não encontrei pergunta conhecida parecida.'
    # nao conhece: manda ao modelo so para ele aprender com a conversa
    if ($script:chat.HasExited) { $script:chat = Inicia-Chat }
    $gerada = Envia-Mensagem $script:chat $msg
    if ($script:config.mostrar_modelo -eq 1 -and $gerada) {
        $passos += ("Resposta gerada pelo modelo (temperatura {0}, contexto {1} tokens). Pode estar errada." -f $script:config.temperatura, $script:config.contexto)
        return Monta $gerada 'modelo' $passos $profundo
    }
    $passos += 'Consultei o modelo, mas a resposta gerada não é confiável, então não foi mostrada.'
    $passos += 'Confiança na resposta: baixa.'
    return Monta $TEXTO_NAO_SEI 'nao_sei' $passos $profundo
}

function Monta([string]$resposta, [string]$origem, $passos, [bool]$profundo) {
    if ($profundo) { return [pscustomobject]@{ resposta = $resposta; origem = $origem; passos = @($passos) } }
    return [pscustomobject]@{ resposta = $resposta; origem = $origem }
}

# Grava uma correcao do usuario: pergunta + resposta certa
function Ensina([string]$pergunta, [string]$resposta) {
    $pergunta = ($pergunta -replace '\s*[\r\n]+\s*', ' ').Trim()
    $resposta = ($resposta -replace '\s*[\r\n]+\s*', ' ').Trim()
    if ($pergunta.Length -eq 0 -or $resposta.Length -eq 0) { throw 'Pergunta e resposta nao podem ser vazias.' }
    if ($pergunta.Length -gt $MAX_TEXTO -or $resposta.Length -gt $MAX_TEXTO) { throw "Pergunta e resposta devem ter no maximo $MAX_TEXTO caracteres." }
    Grava-Ensino $pergunta $resposta
    $disparado = Dispara-Ciclo
    return [pscustomobject]@{ ok = $true; total = @($pares | Where-Object { $_.Origem -eq 'ensino' }).Count; ciclo = $disparado }
}

# Quando ha N correcoes novas, roda o ciclo de correcoes em segundo plano (ver ciclo_correcoes.ps1)
function Dispara-Ciclo {
    $cfg = Get-Content (Join-Path $root 'dados\ciclo_config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $total = 0
    if (Test-Path $arquivoHistorico) { $total = @([IO.File]::ReadAllLines($arquivoHistorico, [Text.Encoding]::UTF8) | Where-Object { $_.StartsWith('R: ') }).Count }
    $incorporadas = 0
    $estadoArq = Join-Path $root 'dados\ciclo_estado.json'
    if (Test-Path $estadoArq) { $incorporadas = [int](Get-Content $estadoArq -Raw -Encoding UTF8 | ConvertFrom-Json).incorporadas }
    $novas = $total - $incorporadas
    $travado = Test-Path (Join-Path $root 'dados\ciclo.lock')
    if ($novas -ge [int]$cfg.N -and -not $travado) {
        Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'ciclo_correcoes.ps1')) -WindowStyle Hidden
        return $true
    }
    return $false
}

# Se o ciclo preparou um chat novo, troca o executavel e reinicia o chat (antes da proxima resposta)
function Verifica-Troca {
    $novo = Join-Path $root 'build\chat_llm.exe.novo'
    if (-not (Test-Path $novo)) { return }
    if ($script:chat -and -not $script:chat.HasExited) { $script:chat.Kill(); $script:chat.WaitForExit() }
    Move-Item -LiteralPath $novo -Destination $exe -Force
    $script:chat = Inicia-Chat
    Write-Host ("[{0}] modelo trocado pelo ciclo de correcoes" -f (Get-Date -Format 'HH:mm:ss'))
}

function Reinicia-Chat {
    if ($script:chat -and -not $script:chat.HasExited) { $script:chat.Kill(); $script:chat.WaitForExit() }
    $script:chat = Inicia-Chat
}

function Responde-Json($res, $objeto, [int]$status = 200) {
    $bytes = [Text.Encoding]::UTF8.GetBytes(($objeto | ConvertTo-Json -Compress -Depth 5))
    $res.StatusCode = $status
    $res.ContentType = 'application/json; charset=utf-8'
    $res.OutputStream.Write($bytes, 0, $bytes.Length)
}

function Le-Corpo($req) {
    $leitor = New-Object IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)
    $texto = $leitor.ReadToEnd()
    if (-not $texto) { return [pscustomobject]@{} }
    return $texto | ConvertFrom-Json
}

# ---- envio de arquivos grandes em partes e processamento em segundo plano ----
$UPLOAD_DIR = Join-Path $root 'dados\uploads'
$EXTENSOES_OK = @('.pdf','.docx','.txt','.md','.csv')
$UPLOAD_MAX = 300MB

function Id-Seguro([string]$id) { return ($id -match '^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$') }

function Upload-Inicia([string]$nome) {
    $nome = [IO.Path]::GetFileName($nome)
    $ext = [IO.Path]::GetExtension($nome).ToLowerInvariant()
    if ($EXTENSOES_OK -notcontains $ext) { throw "formato nao suportado: $ext (use .pdf, .docx, .txt, .md ou .csv)" }
    New-Item -ItemType Directory -Force $UPLOAD_DIR | Out-Null
    $id = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 6))
    [IO.File]::WriteAllBytes((Join-Path $UPLOAD_DIR "$id.part"), [byte[]]@())
    [IO.File]::WriteAllText((Join-Path $UPLOAD_DIR "$id.nome"), $nome, $UTF8SemBom)
    return $id
}

function Upload-Parte([string]$id, [string]$b64) {
    if (-not (Id-Seguro $id)) { throw 'identificador invalido' }
    $arq = Join-Path $UPLOAD_DIR "$id.part"
    if (-not (Test-Path $arq)) { throw 'envio nao encontrado' }
    if ($b64.Contains(',')) { $b64 = $b64.Substring($b64.LastIndexOf(',') + 1) }
    $bytes = [Convert]::FromBase64String($b64)
    if ((Get-Item $arq).Length + $bytes.Length -gt $UPLOAD_MAX) { throw 'arquivo maior que 300 MB' }
    $fs = [IO.File]::Open($arq, [IO.FileMode]::Append, [IO.FileAccess]::Write)
    try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Close() }
    return (Get-Item $arq).Length
}

function Upload-Fim([string]$id) {
    if (-not (Id-Seguro $id)) { throw 'identificador invalido' }
    $parte = Join-Path $UPLOAD_DIR "$id.part"
    if (-not (Test-Path $parte)) { throw 'envio nao encontrado' }
    $nome = [IO.File]::ReadAllText((Join-Path $UPLOAD_DIR "$id.nome"), [Text.Encoding]::UTF8)
    $ext = [IO.Path]::GetExtension($nome).ToLowerInvariant()
    $arquivo = Join-Path $UPLOAD_DIR "$id$ext"
    Move-Item -LiteralPath $parte -Destination $arquivo -Force
    [IO.File]::WriteAllText((Join-Path $UPLOAD_DIR "$id.estado"), 'processando', $UTF8SemBom)
    # extracao em processo separado: PDFs grandes podem levar minutos e nao travam a interface
    Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'processa_documento.ps1'),'-Id',$id,'-Arquivo',$arquivo,'-Nome',$nome) -WindowStyle Hidden
    return [pscustomobject]@{ id = $id; nome = $nome; estado = 'processando' }
}

# documentos ainda sendo processados (ou com erro), para a lista da interface
function Pendentes {
    if (-not (Test-Path $UPLOAD_DIR)) { return @() }
    $lista = @()
    foreach ($e in Get-ChildItem $UPLOAD_DIR -Filter '*.estado') {
        $id = [IO.Path]::GetFileNameWithoutExtension($e.Name)
        $estado = [IO.File]::ReadAllText($e.FullName, [Text.Encoding]::UTF8).Trim()
        if ($estado -eq 'ok') { continue }
        $nomeArq = Join-Path $UPLOAD_DIR "$id.nome"
        $nome = if (Test-Path $nomeArq) { [IO.File]::ReadAllText($nomeArq, [Text.Encoding]::UTF8) } else { $id }
        $lista += [pscustomobject]@{ id = $id; nome = $nome; estado = $estado }
    }
    return $lista
}

# ---- reset de fabrica: guarda TUDO em dados\backups\<data-hora> e restaura o estado original ----
function Restaura-Fabrica {
    $fabrica = Join-Path $root 'dados\fabrica\modelo_chat4.bin'
    if (-not (Test-Path $fabrica)) { throw 'modelo de fabrica ausente: reset cancelado, nada foi alterado' }
    $bk = Join-Path $root ("dados\backups\antes-do-reset-" + (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))
    New-Item -ItemType Directory -Force $bk | Out-Null
    # nada e apagado: tudo que o usuario fez vai para o backup
    foreach ($item in 'ensino_usuario.txt','ensino_historico.txt','ciclo_estado.json','ciclo_log.txt','config_chat.json','modelo_vivo.bin','modelo_vivo.otim','modelo_chat4.bin','modelo_chat4.otim','modelo_chat4.pos','ciclo.lock') {
        $p = Join-Path $root "dados\$item"
        if (Test-Path $p) { Move-Item -LiteralPath $p -Destination $bk -Force }
    }
    foreach ($pasta in 'documentos','versoes','uploads') {
        $p = Join-Path $root "dados\$pasta"
        if (Test-Path $p) { Move-Item -LiteralPath $p -Destination (Join-Path $bk $pasta) -Force }
    }
    Copy-Item -LiteralPath $fabrica -Destination (Join-Path $root 'dados\modelo_chat4.bin') -Force
    # reconstroi o chat com o modelo de fabrica e volta as configuracoes padrao
    if ($script:chat -and -not $script:chat.HasExited) { $script:chat.Kill(); $script:chat.WaitForExit() }
    cmd /c "interface\ciclo\chat.bat dados\modelo_chat4.bin build\chat_llm.exe.novo" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'falha ao montar o chat de fabrica (o modelo ja foi restaurado; rode o build manualmente)' }
    Move-Item -LiteralPath (Join-Path $root 'build\chat_llm.exe.novo') -Destination $exe -Force
    $script:config = Valida-Config $CONFIG_PADRAO
    [IO.File]::WriteAllText($configArq, ($script:config | ConvertTo-Json), $UTF8SemBom)
    $pares.Clear()
    Le-Pares-Arquivo $arquivoPares 'treino'
    $unicos = @($pares | Sort-Object P, R -Unique)
    $pares.Clear()
    foreach ($u in $unicos) { [void]$pares.Add($u) }
    Carrega-Documentos
    $script:chat = Inicia-Chat
    return $bk
}

$script:chat = Inicia-Chat
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($prefixo)
$listener.Start()
Write-Output "Interface em $prefixo  (Ctrl+C para encerrar). Pares de treino: $(@($pares | Where-Object { $_.Origem -eq 'treino' }).Count), ensinados: $(@($pares | Where-Object { $_.Origem -eq 'ensino' }).Count), documentos: $($script:documentos.Count)"

try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        $req = $ctx.Request
        $res = $ctx.Response
        $rota = $req.Url.AbsolutePath
        try {
            if ($req.HttpMethod -eq 'GET' -and $rota -eq '/') {
                $html = [IO.File]::ReadAllBytes($pagina)
                $res.ContentType = 'text/html; charset=utf-8'
                $res.OutputStream.Write($html, 0, $html.Length)
            }
            elseif ($req.HttpMethod -eq 'POST' -and $rota -eq '/api/msg') {
                $dados = Le-Corpo $req
                Responde-Json $res (Responde ([string]$dados.msg).Trim())
            }
            elseif ($req.HttpMethod -eq 'GET' -and $rota -eq '/api/config') {
                Responde-Json $res $script:config
            }
            elseif ($req.HttpMethod -eq 'POST' -and $rota -eq '/api/config') {
                $nova = Valida-Config (Le-Corpo $req)
                [IO.File]::WriteAllText($configArq, ($nova | ConvertTo-Json), $UTF8SemBom)
                $script:config = $nova
                Reinicia-Chat
                Responde-Json $res $nova
            }
            elseif ($req.HttpMethod -eq 'POST' -and $rota -eq '/api/limpar') {
                # limpa a conversa: o chat reinicia e esquece o historico (correcoes e documentos continuam)
                Reinicia-Chat
                Responde-Json $res ([pscustomobject]@{ ok = $true })
            }
            elseif ($req.HttpMethod -eq 'POST' -and $rota -eq '/api/ensinar') {
                $dados = Le-Corpo $req
                Responde-Json $res (Ensina ([string]$dados.pergunta) ([string]$dados.resposta))
            }
            elseif ($req.HttpMethod -eq 'GET' -and $rota -eq '/api/documentos') {
                # recarrega o indice: documentos grandes terminam em segundo plano
                Carrega-Documentos
                Responde-Json $res ([pscustomobject]@{ documentos = @($script:documentos); pendentes = @(Pendentes) })
            }
            elseif ($req.HttpMethod -eq 'POST' -and $rota -eq '/api/upload/inicio') {
                $dados = Le-Corpo $req
                Responde-Json $res ([pscustomobject]@{ id = (Upload-Inicia ([string]$dados.nome)) })
            }
            elseif ($req.HttpMethod -eq 'POST' -and $rota -eq '/api/upload/parte') {
                $dados = Le-Corpo $req
                Responde-Json $res ([pscustomobject]@{ ok = $true; tamanho = (Upload-Parte ([string]$dados.id) ([string]$dados.dados)) })
            }
            elseif ($req.HttpMethod -eq 'POST' -and $rota -eq '/api/upload/fim') {
                $dados = Le-Corpo $req
                Responde-Json $res (Upload-Fim ([string]$dados.id))
            }
            elseif ($req.HttpMethod -eq 'POST' -and $rota -eq '/api/upload/descartar') {
                $dados = Le-Corpo $req
                if (-not (Id-Seguro ([string]$dados.id))) { throw 'identificador invalido' }
                $estadoArq = Join-Path $UPLOAD_DIR (([string]$dados.id) + '.estado')
                if (Test-Path $estadoArq) {
                    New-Item -ItemType Directory -Force (Join-Path $UPLOAD_DIR 'descartados') | Out-Null
                    Move-Item -LiteralPath $estadoArq -Destination (Join-Path $UPLOAD_DIR 'descartados') -Force
                }
                Responde-Json $res ([pscustomobject]@{ ok = $true })
            }
            elseif ($req.HttpMethod -eq 'POST' -and $rota -eq '/api/reset') {
                $dados = Le-Corpo $req
                if ([string]$dados.confirmar -ne 'RESTAURAR') { throw 'para restaurar o padrão de fábrica, confirme com a palavra RESTAURAR' }
                $bk = Restaura-Fabrica
                Responde-Json $res ([pscustomobject]@{ ok = $true; backup = $bk; config = $script:config })
            }
            elseif ($req.HttpMethod -eq 'POST' -and $rota -eq '/api/anexo') {
                $dados = Le-Corpo $req
                $nome = [IO.Path]::GetFileName([string]$dados.nome)
                $b64 = [string]$dados.dados
                if ($b64.Contains(',')) { $b64 = $b64.Substring($b64.LastIndexOf(',') + 1) }
                $bytes = [Convert]::FromBase64String($b64)
                $doc = Adiciona-Documento $nome $bytes
                Responde-Json $res ([pscustomobject]@{ ok = $true; documento = $doc })
            }
            elseif ($req.HttpMethod -eq 'POST' -and $rota -eq '/api/documento/remover') {
                $dados = Le-Corpo $req
                Remove-Documento ([string]$dados.id)
                Responde-Json $res ([pscustomobject]@{ ok = $true; documentos = @($script:documentos) })
            }
            else {
                $res.StatusCode = 404
            }
        }
        catch {
            Responde-Json $res ([pscustomobject]@{ erro = $_.Exception.Message }) 400
        }
        finally {
            $res.Close()
        }
    }
}
finally {
    $listener.Stop()
    if (-not $script:chat.HasExited) { $script:chat.Kill() }
}
