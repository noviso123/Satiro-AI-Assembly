# Ciclo automatico de correcoes do Satiro-IA.
#
# Quando ha N correcoes novas (dados\ciclo_config.json), o servidor roda este script. Ele:
#   1. junta o treino: texto base do ajuste (sft_pr) + conversas basicas + as correcoes;
#   2. faz um ajuste fino a partir do modelo de producao (dados\modelo_chat4.bin) e grava um
#      CANDIDATO (dados\ciclo_candidato.bin), sem tocar no modelo de producao;
#   3. testa o modelo atual e o candidato no texto de validacao (pira_valid) e no teste basico
#      (dados\teste_basico.txt, perguntas que nao estao no treino);
#   4. troca o modelo SOMENTE se o candidato nao piorar em nenhum dos dois testes (com a
#      tolerancia de dados\ciclo_config.json no texto de validacao). Antes de trocar, guarda o
#      modelo atual em dados\versoes\<data-hora>\ para poder voltar atras (interface\reverter.ps1).
#   5. se trocou, monta build\chat_llm.exe.novo; o servidor troca o executavel na proxima mensagem.
#
# Nunca mexe no modelo de producao se algo falhar. Registra tudo em dados\ciclo_log.txt.
# Uso manual:  powershell -ExecutionPolicy Bypass -File interface\ciclo_correcoes.ps1 [-Forcar]

param([switch]$Forcar)

$ErrorActionPreference = 'Stop'
$root = (Get-Item $PSScriptRoot).Parent.FullName
Set-Location $root
$dados = Join-Path $root 'dados'
$ciclo = Join-Path $PSScriptRoot 'ciclo'
$log = Join-Path $dados 'ciclo_log.txt'
$lock = Join-Path $dados 'ciclo.lock'
$estadoArq = Join-Path $dados 'ciclo_estado.json'
$ensino = Join-Path $dados 'ensino_usuario.txt'
$producao = Join-Path $dados 'modelo_chat4.bin'
$candidato = Join-Path $dados 'ciclo_candidato.bin'
$UTF8SemBom = New-Object Text.UTF8Encoding($false)

function Registra([string]$msg) {
    $linha = "[{0}] {1}" -f (Get-Date -Format 'dd/MM/yyyy HH:mm:ss'), $msg
    [IO.File]::AppendAllText($log, $linha + "`n", $UTF8SemBom)
    Write-Output $linha
}

function Roda([string]$comando) {
    # stderr com EAP=Stop viraria NativeCommandError no PS 5.1 (um aviso do asm abortaria
    # o ciclo); a falha real ja e coberta pelo exit code abaixo
    $eapAntiga = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $saida = cmd /c $comando 2>&1 }
    finally { $ErrorActionPreference = $eapAntiga }
    if ($LASTEXITCODE -ne 0) { throw "falhou: $comando`n$($saida -join "`n")" }
    return ($saida -join "`n")
}

function Conta-Pares([string]$caminho) {
    if (-not (Test-Path $caminho)) { return 0 }
    return @([IO.File]::ReadAllLines($caminho, [Text.Encoding]::UTF8) | ? { $_.StartsWith('R: ') }).Count
}

function Le-Estado {
    if (Test-Path $estadoArq) { return (Get-Content $estadoArq -Raw -Encoding UTF8 | ConvertFrom-Json) }
    return [pscustomobject]@{ incorporadas = 0 }
}

function Bits-Basic([string]$resultado) {
    $m = [regex]::Match($resultado, 'bits por byte x1000: (\d+)')
    if (-not $m.Success) { throw "resultado de avaliacao nao reconhecido: $resultado" }
    return [int]$m.Groups[1].Value
}

# ---- inicio ----
# lock por abertura exclusiva: dois ciclos disparados quase juntos (TOCTOU) nao passam,
# e o handle fica segurado durante o ciclo inteiro
$fluxoLock = $null
for ($i = 0; $i -lt 5 -and -not $fluxoLock; $i++) {
    try { $fluxoLock = [IO.File]::Open($lock, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) } catch { Start-Sleep -Milliseconds 500 }
}
if (-not $fluxoLock) { Write-Output 'ciclo ja em andamento'; exit 0 }

try {
    $cfg = Get-Content (Join-Path $dados 'ciclo_config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $N = [int]$cfg.N
    $tol = [int]$cfg.tolerancia
    $lr = [string]$cfg.lr

    $total = Conta-Pares (Join-Path $dados 'ensino_historico.txt')   # historico: conta todas as correcoes, inclusive as substituidas
    $estado = Le-Estado
    $novas = $total - [int]$estado.incorporadas
    if (-not $Forcar -and $novas -lt $N) {
        Registra "sem ciclo: $novas correcoes novas (precisa de $N)"
        exit 0
    }
    if ($novas -le 0) { Registra 'sem correcoes novas para incorporar'; exit 0 }
    Registra "ciclo iniciado: $novas correcoes novas (total $total)"

    # 1. treino: base do ajuste + conversas + correcoes (correcoes repetidas para pesar mais)
    Roda "interface\ciclo\cod.bat dados\conversas_basicas.txt dados\ciclo_conv.tok" | Out-Null
    Roda "interface\ciclo\cod.bat dados\ensino_usuario.txt dados\ciclo_ensino.tok" | Out-Null
    $base = [IO.File]::ReadAllBytes((Join-Path $dados 'sft_pr.tok'))
    $conv = [IO.File]::ReadAllBytes((Join-Path $dados 'ciclo_conv.tok'))
    $ens = [IO.File]::ReadAllBytes((Join-Path $dados 'ciclo_ensino.tok'))
    $ms = New-Object IO.MemoryStream
    # o texto de oceano e repetido para o modelo nao esquecer o que ja sabe (replay)
    for ($i = 0; $i -lt 2; $i++) { $ms.Write($base, 0, $base.Length) }
    for ($i = 0; $i -lt 8; $i++) { $ms.Write($conv, 0, $conv.Length) }
    for ($i = 0; $i -lt 20; $i++) { $ms.Write($ens, 0, $ens.Length) }
    [IO.File]::WriteAllBytes((Join-Path $dados 'ciclo_treino.tok'), $ms.ToArray())

    # 2. ajuste fino -> candidato (o modelo de producao nao e alterado)
    Remove-Item ($candidato + '.otim'), ($candidato + '.pos'), $candidato -Force -ErrorAction SilentlyContinue
    Roda "interface\ciclo\ajuste.bat dados\ciclo_treino.tok dados\modelo_chat4.bin dados\ciclo_candidato.bin $lr" | Out-Null
    Registra 'candidato treinado'

    # 3. testes: validacao (texto de oceano) e teste basico (fora do treino)
    Roda "interface\ciclo\cod.bat dados\teste_basico.txt dados\ciclo_teste.tok" | Out-Null
    $atualVal = Bits-Basic (Roda "interface\ciclo\avalia.bat dados\modelo_chat4.bin dados\pira_valid.tok")
    $candVal = Bits-Basic (Roda "interface\ciclo\avalia.bat dados\ciclo_candidato.bin dados\pira_valid.tok")
    $atualBas = Bits-Basic (Roda "interface\ciclo\avalia.bat dados\modelo_chat4.bin dados\ciclo_teste.tok")
    $candBas = Bits-Basic (Roda "interface\ciclo\avalia.bat dados\ciclo_candidato.bin dados\ciclo_teste.tok")
    Registra "validacao: atual=$atualVal candidato=$candVal (x1000 bits/byte, menor e melhor)"
    Registra "teste basico: atual=$atualBas candidato=$candBas"

    # 4. decisao: nao pode piorar no teste basico, e a piora na validacao fica dentro da tolerancia
    $piorouBasico = $candBas -gt $atualBas
    $piorouVal = $candVal -gt ($atualVal + $tol)
    $estado = [pscustomobject]@{ incorporadas = $total }
    if ($piorouBasico -or $piorouVal) {
        Registra 'NAO TROCADO: o candidato piorou em pelo menos um teste; modelo atual mantido'
    }
    else {
        # monta o chat do candidato ANTES de promo-lo: se o build falhar, a producao
        # fica intacta (o contrario violaria o contrato "nunca mexe na producao")
        Roda "interface\ciclo\chat.bat dados\ciclo_candidato.bin build\chat_llm.exe.novo" | Out-Null
        $pasta = Join-Path $dados ("versoes\" + (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))
        New-Item -ItemType Directory -Force $pasta | Out-Null
        Copy-Item $producao (Join-Path $pasta 'modelo_chat4.bin')
        foreach ($extra in 'modelo_vivo.bin','modelo_vivo.otim') {
            $p = Join-Path $dados $extra
            if (Test-Path $p) { Move-Item $p (Join-Path $pasta $extra) }
        }
        Copy-Item $candidato $producao -Force
        Registra "TROCADO: modelo anterior guardado em $pasta; novo chat em build\chat_llm.exe.novo"
    }
    [IO.File]::WriteAllText((Join-Path $dados 'ciclo_estado.json'), ($estado | ConvertTo-Json), $UTF8SemBom)
    Remove-Item ($candidato + '.otim'), ($candidato + '.pos'), $candidato -Force -ErrorAction SilentlyContinue
}
catch {
    Registra "ERRO no ciclo, producao mantida: $($_.Exception.Message)"
}
finally {
    if ($fluxoLock) { $fluxoLock.Close() }
    Remove-Item $lock -Force -ErrorAction SilentlyContinue
}
