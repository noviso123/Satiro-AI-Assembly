# Volta o modelo de producao para uma versao guardada pelo ciclo de correcoes.
# Uso:
#   powershell -ExecutionPolicy Bypass -File interface\reverter.ps1                 (lista as versoes)
#   powershell -ExecutionPolicy Bypass -File interface\reverter.ps1 -Versao <pasta>  (volta para ela)
#   ... -Simular  mostra o que faria, sem alterar nada.
# O modelo atual tambem e guardado antes de voltar, em dados\versoes\antes-de-reverter-<data-hora>.

param(
    [string]$Versao,
    [switch]$Simular
)

$ErrorActionPreference = 'Stop'
$root = (Get-Item $PSScriptRoot).Parent.FullName
Set-Location $root
$versoes = Join-Path $root 'dados\versoes'
$dados = Join-Path $root 'dados'

if (-not $Versao) {
    if (-not (Test-Path $versoes)) { Write-Output 'nenhuma versao guardada ainda'; exit 0 }
    Get-ChildItem $versoes -Directory | Sort-Object Name | % { Write-Output ("  " + $_.Name) }
    exit 0
}

$origem = Join-Path $versoes $Versao
if (-not (Test-Path (Join-Path $origem 'modelo_chat4.bin'))) { throw "versao nao encontrada: $Versao" }

$agora = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$guarda = Join-Path $versoes ("antes-de-reverter-" + $agora)
Write-Output "guardar atual em: $guarda"
Write-Output "restaurar de:     $origem"
if ($Simular) { Write-Output 'simulacao: nada foi alterado'; exit 0 }

New-Item -ItemType Directory -Force $guarda | Out-Null
Copy-Item (Join-Path $dados 'modelo_chat4.bin') $guarda
Copy-Item (Join-Path $origem 'modelo_chat4.bin') (Join-Path $dados 'modelo_chat4.bin') -Force
foreach ($extra in 'modelo_vivo.bin','modelo_vivo.otim') {
    $p = Join-Path $dados $extra
    if (Test-Path $p) { Move-Item $p (Join-Path $guarda $extra) }
}
# monta o chat com o modelo restaurado; o servidor troca o executavel na proxima mensagem
cmd /c "interface\ciclo\chat.bat dados\modelo_chat4.bin build\chat_llm.exe.novo" | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'falha ao montar o chat com o modelo restaurado (producao ja foi restaurada)' }
Write-Output 'modelo restaurado. O servidor passa a usar a versao restaurada na proxima mensagem.'
