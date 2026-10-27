# OCR de PDFs escaneados com recursos embutidos do Windows 10/11 (sem dependencias):
#   Windows.Data.Pdf renderiza cada pagina como imagem; Windows.Media.Ocr le o texto.
# Precisa apenas do pacote de idioma do Windows (no Windows em portugues, pt-BR ja vem).
# So funciona no Windows PowerShell 5.1 (o servidor roda nele); em outro host, o OCR
# simplesmente fica indisponivel e o erro claro do extrator e mostrado.

try { Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop } catch { }

[void][Windows.Data.Pdf.PdfDocument, Windows.Data.Pdf, ContentType = WindowsRuntime]
[void][Windows.Media.Ocr.OcrEngine, Windows.Media.Ocr, ContentType = WindowsRuntime]
[void][Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
[void][Windows.Storage.Streams.InMemoryRandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime]
[void][Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType = WindowsRuntime]
[void][Windows.Graphics.Imaging.SoftwareBitmap, Windows.Graphics.Imaging, ContentType = WindowsRuntime]
[void][Windows.Globalization.Language, Windows.Globalization, ContentType = WindowsRuntime]
[void][Windows.Data.Pdf.PdfPageRenderOptions, Windows.Data.Pdf, ContentType = WindowsRuntime]

$script:asTaskOp = ([System.WindowsRuntimeSystemExtensions].GetMethods() |
    Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
                   $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
$script:asTaskAcao = ([System.WindowsRuntimeSystemExtensions].GetMethods() |
    Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
                   $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction' })[0]

# Espera uma operacao WinRT e devolve o resultado
function Await-Op($operacao, [type]$tipo) {
    $asTask = $script:asTaskOp.MakeGenericMethod($tipo)
    $tarefa = $asTask.Invoke($null, @($operacao))
    $tarefa.Wait(-1) | Out-Null
    return $tarefa.Result
}

# Espera uma acao WinRT (sem resultado)
function Await-Acao($acao) {
    $tarefa = $script:asTaskAcao.Invoke($null, @($acao))
    $tarefa.Wait(-1) | Out-Null
}

# Devolve o motor de OCR (pt-BR primeiro) ou $null se o Windows nao tiver idioma com OCR
function Teste-PdfOcr {
    try {
        $motor = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage([Windows.Globalization.Language]::new('pt-BR'))
        if ($motor) { return $motor }
        return [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
    } catch { return $null }
}

# Converte um PDF (de preferencia escaneado) em texto, pagina por pagina, por OCR.
# maxPaginas limita o tempo: cada pagina leva ~1-2 s (renderizacao + reconhecimento).
function Converte-PdfOcr([string]$caminho, $motor, [int]$maxPaginas = 30) {
    $arquivo = Await-Op ([Windows.Storage.StorageFile]::GetFileFromPathAsync($caminho)) ([Windows.Storage.StorageFile])
    $pdf = Await-Op ([Windows.Data.Pdf.PdfDocument]::LoadFromFileAsync($arquivo)) ([Windows.Data.Pdf.PdfDocument])
    $saidas = New-Object System.Collections.Generic.List[string]
    $total = [Math]::Min([int]$pdf.PageCount, $maxPaginas)
    for ($i = 0; $i -lt $total; $i++) {
        $pagina = $pdf.GetPage([uint32]$i)
        try {
            $fluxo = New-Object Windows.Storage.Streams.InMemoryRandomAccessStream
            $opcoes = New-Object Windows.Data.Pdf.PdfPageRenderOptions
            $opcoes.DestinationWidth = [uint32]1700      # resolucao boa para o OCR ler
            Await-Acao ($pagina.RenderToStreamAsync($fluxo, $opcoes))
            $decod = Await-Op ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($fluxo)) ([Windows.Graphics.Imaging.BitmapDecoder])
            $bmp = Await-Op ($decod.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
            $bgra = [Windows.Graphics.Imaging.SoftwareBitmap]::Convert($bmp, [Windows.Graphics.Imaging.BitmapPixelFormat]::Bgra8, [Windows.Graphics.Imaging.BitmapAlphaMode]::Premultiplied)
            $resultado = Await-Op ($motor.RecognizeAsync($bgra)) ([Windows.Media.Ocr.OcrResult])
            $linhas = @($resultado.Lines | ForEach-Object { $_.Text })
            if ($linhas.Count -gt 0) { $saidas.Add(($linhas -join ' ')) }
            $bgra.Dispose(); $bmp.Dispose(); $fluxo.Dispose()
        } finally { $pagina.Dispose() }
    }
    return ($saidas -join "`n")
}
