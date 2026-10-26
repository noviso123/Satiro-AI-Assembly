# Valida o codificador do montador (tools/asm) contra o NASM, instrucao por instrucao.
# Para cada linha: monta com o NASM (binario plano) e com build\asm.exe (secao .text do COFF),
# e compara os bytes. Uso: powershell -File tests\as_enc_check.ps1 [arquivo_de_casos]
param([string]$Casos = "tests\as_enc_casos.txt")

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
$nasm = "C:\Program Files\NASM\nasm.exe"
$tmp = Join-Path $env:TEMP "asm_enc_check"
New-Item -ItemType Directory -Force $tmp | Out-Null

$linhas = Get-Content $Casos | Where-Object { $_.Trim() -ne "" -and -not $_.StartsWith(";") }
$ok = 0; $falha = 0
foreach ($ln in $linhas) {
    $src = Join-Path $tmp "caso.asm"
    Set-Content -Path $src -Value ("bits 64`ndefault rel`nsection .text`ntlab: db 0x90`n" + $ln + "`n") -Encoding ascii
    & $nasm -f bin $src -o (Join-Path $tmp "caso_nasm.bin") 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Output ("[NASM REJEITOU] " + $ln); $falha++; continue }
    $ref = [IO.File]::ReadAllBytes((Join-Path $tmp "caso_nasm.bin"))

    $obj = Join-Path $tmp "caso_ours.obj"
    $saida = & (Join-Path $root "build\asm.exe") $src $obj 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $obj)) {
        Write-Output ("[NOSSO ERRO] " + $ln + " -> " + ($saida -join " ")); $falha++; continue
    }
    $ob = [IO.File]::ReadAllBytes($obj)
    $p = [BitConverter]::ToUInt32($ob, 20 + 20)
    $s = [BitConverter]::ToUInt32($ob, 20 + 16)
    $ours = $ob[$p..($p + $s - 1)]

    $a = ($ref | ForEach-Object { $_.ToString("X2") }) -join " "
    $b = ($ours | ForEach-Object { $_.ToString("X2") }) -join " "
    if ($a -eq $b) { $ok++ } else {
        $falha++
        Write-Output ("[DIFERENTE] " + $ln)
        Write-Output ("     NASM: " + $a)
        Write-Output ("     NOSSO: " + $b)
    }
}
Write-Output ("validados: $ok, falhas: $falha")
