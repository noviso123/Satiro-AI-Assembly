# Extrai o texto de um documento grande em segundo plano e o registra no indice de documentos.
# Chamado pelo servidor: powershell -File processa_documento.ps1 -Id <id> -Arquivo <caminho> -Nome <nome>
# Estado em dados\uploads\<id>.estado: "processando", "ok" ou "erro: <mensagem>".
param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Arquivo, [Parameter(Mandatory)][string]$Nome)

$ErrorActionPreference = 'Stop'
$root = (Get-Item $PSScriptRoot).Parent.FullName
$pastaInterface = Join-Path $root 'interface'
$UTF8SemBom = New-Object Text.UTF8Encoding($false)
$estado = Join-Path $root "dados\uploads\$Id.estado"

function Diz([string]$texto) { [IO.File]::WriteAllText($estado, $texto, $UTF8SemBom) }

# funcoes de leitura e indice (as mesmas do servidor); Palavras/Normaliza so sao usadas na busca
$STOPWORDS = @()
function Normaliza([string]$s) { $s.ToLowerInvariant() }
function Palavras([string]$s) { @() }
. (Join-Path $pastaInterface 'documentos.ps1')

try {
    Diz 'processando'
    $texto = Extrai-Texto $Arquivo $Nome
    if (-not $texto -or $texto.Trim().Length -lt 20) { throw 'nao consegui extrair texto deste arquivo (PDF escaneado precisa de OCR)' }
    [IO.File]::WriteAllText((Join-Path $DOC_DIR ($Id + '.txt')), $texto, $UTF8SemBom)
    $indice = @(Le-Indice) + @([pscustomobject]@{ id = $Id; nome = $Nome })
    Grava-Indice $indice
    Diz 'ok'
}
catch {
    Diz ('erro: ' + $_.Exception.Message)
}
finally {
    Remove-Item -LiteralPath $Arquivo -Force -ErrorAction SilentlyContinue
}
