# Documentos anexados ao Satiro-IA: leitura (txt, md, csv, docx, pdf), divisao em trechos e busca.
# Carregado por server.ps1 depois de Normaliza e Palavras (usa $root e $UTF8SemBom do servidor).
#
# Limites honestos:
#   - PDF: extrai o texto de PDFs com texto embutido (fluxos comprimidos, fontes simples). PDF escaneado
#     (imagem) nao tem texto e precisa de OCR, que nao existe aqui. Fontes com codificacao propria
#     (Identity-H, muito comuns) podem sair com caracteres trocados.
#   - .doc (Word antigo, binario) e .xls nao sao suportados: salve como .docx.

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$DOC_DIR = Join-Path $root 'dados\documentos'
$DOC_INDICE = Join-Path $DOC_DIR 'indice.json'
$DOC_REMOVIDOS = Join-Path $DOC_DIR 'removidos'
$DOC_LIMITE_BYTES = 300MB
$script:sentencas = New-Object System.Collections.ArrayList
$script:df = @{}                  # em quantos trechos cada termo aparece (peso IDF)
$script:documentos = New-Object System.Collections.ArrayList

function Decodifica-Xml([string]$s) {
    return $s.Replace('&lt;', '<').Replace('&gt;', '>').Replace('&quot;', '"').Replace('&apos;', "'").Replace('&amp;', '&')
}

function Texto-Docx([string]$caminho) {
    $zip = [IO.Compression.ZipFile]::OpenRead($caminho)
    try {
        $entrada = $zip.Entries | Where-Object { $_.FullName -eq 'word/document.xml' } | Select-Object -First 1
        if (-not $entrada) { throw 'arquivo .docx sem word/document.xml' }
        $leitor = New-Object IO.StreamReader($entrada.Open(), [Text.Encoding]::UTF8)
        $xml = $leitor.ReadToEnd()
        $leitor.Close()
    }
    finally { $zip.Dispose() }
    $linhas = @()
    foreach ($p in [regex]::Matches($xml, '<w:p[ >].*?</w:p>', 'Singleline')) {
        $partes = [regex]::Matches($p.Value, '<w:t(?: [^>]*)?>(.*?)</w:t>', 'Singleline') | ForEach-Object { $_.Groups[1].Value }
        $linhas += Decodifica-Xml (($partes) -join '')
    }
    return ($linhas -join "`n")
}

function Desescapa-Pdf([string]$s) {
    $sb = New-Object Text.StringBuilder
    $i = 0
    while ($i -lt $s.Length) {
        $c = $s[$i]
        if ($c -eq '\' -and $i + 1 -lt $s.Length) {
            $n = $s[$i + 1]
            if ($n -match '[0-7]') {
                $oct = ''
                $j = $i + 1
                while ($j -lt $s.Length -and $oct.Length -lt 3 -and $s[$j] -match '[0-7]') { $oct += $s[$j]; $j++ }
                [void]$sb.Append([char][Convert]::ToInt32($oct, 8))
                $i = $j
                continue
            }
            switch ($n) {
                'n' { [void]$sb.Append("`n") }
                'r' { }
                't' { [void]$sb.Append(' ') }
                default { [void]$sb.Append($n) }
            }
            $i += 2
            continue
        }
        [void]$sb.Append($c)
        $i++
    }
    return $sb.ToString()
}

function Texto-Pdf([byte[]]$bytes) {
    $latin = [Text.Encoding]::GetEncoding(28591)
    $texto = $latin.GetString($bytes)
    $saida = New-Object Text.StringBuilder
    foreach ($m in [regex]::Matches($texto, '(?s)<<(.*?)>>\s*stream\r?\n(.*?)\r?\nendstream')) {
        $dict = $m.Groups[1].Value
        $dados = $latin.GetBytes($m.Groups[2].Value)
        if ($dict -match 'FlateDecode') {
            try {
                $ms = [IO.MemoryStream]::new($dados, 2, $dados.Length - 2)
                $ds = New-Object IO.Compression.DeflateStream($ms, [IO.Compression.CompressionMode]::Decompress)
                $out = New-Object IO.MemoryStream
                $ds.CopyTo($out)
                $dados = $out.ToArray()
            }
            catch { continue }
        }
        $conteudo = $latin.GetString($dados)
        if ($conteudo -notmatch '\sTj|\sTJ') { continue }
        # operadores de nova linha (Td, T*, ET) separam as linhas do texto
        foreach ($linha in [regex]::Split($conteudo, '\bT\*|\bTd\b|\bTD\b|\bET\b')) {
            $pedacos = [regex]::Matches($linha, '\(((?:\\.|[^\\()])*)\)') | ForEach-Object { Desescapa-Pdf $_.Groups[1].Value }
            if ($pedacos) { [void]$saida.Append((($pedacos) -join '') + "`n") }
        }
    }
    return $saida.ToString()
}

function Extrai-Texto([string]$caminho, [string]$nome) {
    $ext = [IO.Path]::GetExtension($nome).ToLowerInvariant()
    if ($ext -in @('.txt', '.md', '.csv')) {
        # UTF-8 e o padrao; sem BOM e com bytes invalidos, o arquivo provavelmente
        # veio do Bloco de Notas antigo (ANSI/Latin-1): decodificar como Latin-1
        $bytes = [IO.File]::ReadAllBytes($caminho)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            $bytes = $bytes[3..($bytes.Length - 1)]
        }
        $estrito = [Text.UTF8Encoding]::new($false, $true)
        try { return $estrito.GetString($bytes) } catch {
            return [Text.Encoding]::GetEncoding(28591).GetString($bytes)
        }
    }
    if ($ext -eq '.docx') { return Texto-Docx $caminho }
    if ($ext -eq '.pdf') {
        $t = Texto-Pdf ([IO.File]::ReadAllBytes($caminho))
        # guarda de qualidade: PDF escaneado ou com fontes nao suportadas vira ruído
        # binário que pareceria indexado (milhares de "trechos" sem sentido). Texto
        # real tem espaços a cada poucos letras e maioria de letras; ruído, não.
        if ($t.Length -gt 500) {
            $espacos = ([regex]::Matches($t, ' ')).Count
            $letras = ([regex]::Matches($t, '\p{L}')).Count
            if (($espacos / $t.Length) -lt 0.06 -or ($letras / $t.Length) -lt 0.55) {
                throw 'nao consegui extrair texto legivel deste PDF (ele parece escaneado ou usa fontes nao suportadas pelo extrator)'
            }
        }
        return $t
    }
    throw "formato nao suportado: $ext (use .txt, .md, .csv, .docx ou .pdf)"
}

# Divide o texto em frases (trechos) e as indexa; devolve quantos trechos entraram.
# TokSet (hashtable) existe para a busca ser O(1) por termo: documentos grandes geram
# milhares de trechos e a intersecao com -contains/Where-Object viraria o gargalo.
function Divide-Sentencas([string]$texto, [string]$nome) {
    $n = 0
    foreach ($p in [regex]::Split($texto, '(?<=[\.\!\?])\s+|\n+')) {
        $t = $p.Trim()
        if ($t.Length -ge 20) {
            $n++
            $conj = @{}
            foreach ($w in (Palavras $t)) { $conj[$w] = $true }
            [void]$script:sentencas.Add([pscustomobject]@{ Doc = $nome; Texto = $t; Tok = @($conj.Keys); TokSet = $conj })
        }
    }
    return $n
}

# Le o indice de documentos. Entradas invalidas (de versoes antigas) sao descartadas.
function Le-Indice {
    # emite um objeto por documento valido (lista vazia = nada emitido, sem aninhar arrays)
    if (-not (Test-Path $DOC_INDICE)) { return }
    $raw = Get-Content $DOC_INDICE -Raw -Encoding UTF8
    if (-not $raw -or -not $raw.Trim()) { return }
    # ConvertFrom-Json por atribuicao (nao pelo pipeline): pelo pipeline a lista inteira vira um so item
    $lidos = ConvertFrom-Json -InputObject $raw
    foreach ($x in @($lidos)) {
        if ($x.id -is [string] -and $x.nome -is [string] -and $x.id -ne '') {
            [pscustomobject]@{ id = [string]$x.id; nome = [string]$x.nome }
        }
    }
}

function Grava-Indice($lista) {
    $arr = @($lista)
    if ($arr.Count -eq 0) { [IO.File]::WriteAllText($DOC_INDICE, '[]', $UTF8SemBom); return }
    [IO.File]::WriteAllText($DOC_INDICE, (ConvertTo-Json -InputObject $arr), $UTF8SemBom)
}

# Acrescenta um documento ao indice com exclusao mutua entre processos: uploads grandes
# terminam em filhos separados, e quem grava por ultimo nao pode apagar a entrada do outro
# (por isso re-le o indice DENTRO do lock antes de gravar).
function Adiciona-No-Indice([string]$id, [string]$nome) {
    $lock = Join-Path $DOC_DIR 'indice.lock'
    $fluxo = $null
    try {
        for ($i = 0; $i -lt 100 -and -not $fluxo; $i++) {
            try { $fluxo = [IO.File]::Open($lock, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) } catch { Start-Sleep -Milliseconds 100 }
        }
        if (-not $fluxo) { throw 'indice de documentos ocupado' }
        $indice = @(Le-Indice)
        if (@($indice | Where-Object { $_.id -eq $id }).Count -eq 0) {
            $indice = @($indice) + @([pscustomobject]@{ id = $id; nome = $nome })
        }
        Grava-Indice $indice
    }
    finally {
        if ($fluxo) { $fluxo.Close() }
    }
}

function Carrega-Documentos {
    $script:sentencas.Clear()
    $script:documentos.Clear()
    foreach ($d in (Le-Indice)) {
        $arq = Join-Path $DOC_DIR ($d.id + '.txt')
        if (-not (Test-Path $arq)) { continue }
        $texto = [IO.File]::ReadAllText($arq, [Text.Encoding]::UTF8)
        $n = Divide-Sentencas $texto $d.nome
        [void]$script:documentos.Add([pscustomobject]@{ id = $d.id; nome = $d.nome; trechos = $n })
    }
    # raro entre os trechos vale mais na busca (peso IDF): termo em 1 de 500
    # trechos pesa mais que um termo em 400 deles
    $script:df = @{}
    foreach ($s in $script:sentencas) {
        foreach ($t in $s.Tok) {
            if ($script:df.ContainsKey($t)) { $script:df[$t]++ } else { $script:df[$t] = 1 }
        }
    }
}

# Remove da lista e move o texto para dados\documentos\removidos (nada e apagado de vez)
function Remove-Documento([string]$id) {
    $todos = @(Le-Indice)
    $ficam = @($todos | Where-Object { $_.id -ne $id })
    if ($ficam.Count -eq $todos.Count) { throw 'documento nao encontrado' }
    New-Item -ItemType Directory -Force $DOC_REMOVIDOS | Out-Null
    $arq = Join-Path $DOC_DIR ($id + '.txt')
    if (Test-Path $arq) { Move-Item -LiteralPath $arq -Destination $DOC_REMOVIDOS -Force }
    Grava-Indice $ficam
    Carrega-Documentos
}

# Trechos dos documentos que tem termos em comum com a pergunta (os mais relevantes
# primeiro). Peso por termo = IDF (termo raro entre os trechos pesa mais), como no
# BM25 simplificado: um nome proprio exclusivo de um trecho vence uma palavra comum.
function Busca-Documentos([string]$pergunta) {
    $tok = Palavras $pergunta
    if ($tok.Count -eq 0) { return @() }
    # perguntas curtas (ate 2 termos) aceitam um termo em comum; as demais pedem dois, para evitar ruido
    $minimo = if ($tok.Count -le 2) { 1 } else { 2 }
    $N = [Math]::Max($script:sentencas.Count, 1)
    $achados = foreach ($s in $script:sentencas) {
        $inter = 0
        $peso = 0.0
        foreach ($t in $tok) {
            if ($s.TokSet.ContainsKey($t)) {
                $inter++
                $df = 1
                if ($script:df.ContainsKey($t)) { $df = [int]$script:df[$t] }
                $peso += [Math]::Log(1.0 + $N / (1.0 + $df))
            }
        }
        if ($inter -ge $minimo) { [pscustomobject]@{ S = $s; Inter = $inter; Score = $peso } }
    }
    return @($achados | Sort-Object -Property Score -Descending | Select-Object -First 3)
}
