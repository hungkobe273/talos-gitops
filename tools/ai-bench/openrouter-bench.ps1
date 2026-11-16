# So sánh model miễn phí trên OpenRouter: cùng bộ câu hỏi, đo thời gian và token/s, lưu câu trả lời để chấm.
# Key đọc từ biến môi trường OPENROUTER_API_KEY (không in ra, không ghi vào file).
# Free tier: 20 request/phút, 50 request/ngày (chưa nạp credit). Mặc định 6 model x 4 câu = 24 request.
# Chạy: pwsh -NoProfile -File openrouter-bench.ps1
# Chạy lại vài cặp: pwsh -NoProfile -File openrouter-bench.ps1 -Only 'google/gemma-4-31b-it:free|yaml','...'
# 16/11 lần 1: model suy luận (reasoning) dùng hết max_tokens 800 để "nghĩ", content rỗng -> nâng lên 4000,
# ghi thêm finish_reason và số token suy luận. 429 "rate-limited upstream" là nhà cung cấp hết lượt chung, thử lại 1 lần.
param(
    [string[]]$Models = @(
        'google/gemma-4-31b-it:free',
        'nvidia/nemotron-3-ultra-550b-a55b:free',
        'nvidia/nemotron-3.5-lightning:free',
        'baidu/ernie-5.5-flash-preview:free',
        'inclusionai/ling-3.2-flash:free',
        'openrouter/free'
    ),
    [string[]]$Only = @(),
    [int]$MaxTokens = 4000,
    [int]$PauseSec = 4,
    [int]$Retry429 = 1,
    [int]$RetryWaitSec = 20
)

$ErrorActionPreference = 'Stop'
if (-not $env:OPENROUTER_API_KEY) { throw 'Chưa đặt OPENROUTER_API_KEY' }

# Câu hỏi chung chung, không chứa IP, tên máy, secret hay dữ liệu công ty: model free có thể bị lưu prompt.
$Prompts = [ordered]@{
    'vi-giai-thich' = 'Giải thích ngắn gọn bằng tiếng Việt cho sinh viên năm 3: Kubernetes là gì, khác gì so với chạy Docker trên một máy? Tối đa 150 từ.'
    'k8s-loi'       = 'Pod Kubernetes của tôi ở trạng thái CrashLoopBackOff. Liệt kê 5 lệnh kubectl theo thứ tự để tìm nguyên nhân, mỗi lệnh một dòng giải thích ngắn bằng tiếng Việt.'
    'yaml'          = 'Viết manifest Kubernetes Deployment cho nginx 2 replica, có resources requests/limits, readinessProbe HTTP cổng 80, chạy non-root. Chỉ trả về YAML.'
    'tom-tat'       = 'Tóm tắt đoạn sau trong 3 gạch đầu dòng tiếng Việt: "GitOps là cách vận hành trong đó trạng thái mong muốn của hạ tầng và ứng dụng được khai báo trong Git. Một agent trong cụm như Argo CD liên tục so sánh trạng thái thật với Git và tự đồng bộ khi lệch. Mọi thay đổi đi qua pull request nên có lịch sử, review và dễ quay lui. Nhược điểm là secret không được để thẳng trong Git, cần công cụ như Sealed Secrets hoặc External Secrets."'
}

$jobs = @()
# pwsh -File truyền cả danh sách 'a','b' thành một chuỗi: tách lại theo dấu phẩy, bỏ nháy.
$Only = @($Only | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().Trim("'").Trim('"') } | Where-Object { $_ })
if ($Only.Count -gt 0) {
    foreach ($p in $Only) {
        $m, $k = $p -split '\|', 2
        if (-not $Prompts.Contains([string]$k)) { throw "Sai cặp '$p': câu '$k' không có trong bộ câu hỏi" }
        $jobs += , @($m, $k)
    }
} else {
    foreach ($m in $Models) { foreach ($k in $Prompts.Keys) { $jobs += , @($m, $k) } }
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir = Join-Path $PSScriptRoot "results-$stamp"
New-Item -ItemType Directory -Force $outDir | Out-Null
$headers = @{ Authorization = "Bearer $($env:OPENROUTER_API_KEY)" }
$rows = @()
$sent = 0

foreach ($j in $jobs) {
    $m, $k = $j
    $body = @{
        model      = $m
        max_tokens = $MaxTokens
        messages   = @(@{ role = 'user'; content = $Prompts[$k] })
    } | ConvertTo-Json -Depth 5
    $row = [ordered]@{ model = $m; prompt = $k; ok = $false; seconds = $null; out_tokens = $null; reasoning_tokens = $null
                       content_chars = $null; finish = $null; tok_per_s = $null; served_by = $null; tries = 0; error = $null }
    for ($try = 0; $try -le $Retry429; $try++) {
        Write-Host ("{0} {1} / {2}{3}" -f (Get-Date -Format HH:mm:ss), $m, $k, $(if ($try) { " (thử lại $try)" } else { '' }))
        $row.tries = $try + 1; $sent++
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            $r = Invoke-RestMethod -Uri 'https://openrouter.ai/api/v1/chat/completions' -Method Post -Headers $headers `
                -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 300
            $sw.Stop()
            $text = [string]$r.choices[0].message.content
            $row.ok = $text.Trim().Length -gt 0
            $row.seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
            $row.out_tokens = $r.usage.completion_tokens
            $row.reasoning_tokens = $r.usage.completion_tokens_details.reasoning_tokens
            $row.content_chars = $text.Length
            $row.finish = $r.choices[0].finish_reason
            if ($row.out_tokens -and $row.seconds) { $row.tok_per_s = [math]::Round($row.out_tokens / $row.seconds, 1) }
            $row.served_by = "$($r.model) / $($r.provider)"
            $row.error = if ($row.ok) { $null } else { 'content rỗng' }
            $safe = ($m -replace '[/:]', '_')
            Set-Content -Encoding utf8 -Path (Join-Path $outDir "$safe--$k.md") -Value "# $m / $k ($($row.served_by))`n`n$text"
            break
        } catch {
            $sw.Stop()
            $row.seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
            $msg = $_.ErrorDetails.Message
            if (-not $msg) { $msg = $_.Exception.Message }
            $flat = ($msg -replace '\s+', ' ')
            $row.error = $flat.Substring(0, [math]::Min(200, $flat.Length))
            if ($flat -match '"code": ?429' -and $try -lt $Retry429) { Start-Sleep -Seconds $RetryWaitSec; continue }
            break
        }
    }
    $rows += [pscustomobject]$row
    Start-Sleep -Seconds $PauseSec
}

$rows | Export-Csv -Encoding utf8 (Join-Path $outDir 'summary.csv')
$rows | Format-Table model, prompt, ok, seconds, out_tokens, reasoning_tokens, content_chars, finish, tries -AutoSize
Write-Host ("{0} xong, {1} request, kết quả ở {2}" -f (Get-Date -Format HH:mm:ss), $sent, $outDir)
