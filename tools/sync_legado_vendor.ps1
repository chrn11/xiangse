# 从 legado-ios 同步引擎源码到 LegadoBridge/Vendor

param(
    [string]$LegadoIosRoot = 'D:\soft\legado-ios',
    [string]$VendorRoot = 'D:\soft\xiangse\LegadoBridge\Vendor'
)

$ErrorActionPreference = 'Stop'

$paths = @(
    'Core\RuleEngine',
    'Core\Network\AnalyzeUrl.swift',
    'Core\Network\DecompressInterceptor.swift',
    'Core\Network\BackstageWebView.swift',
    'Core\Network\ConcurrentRateLimiter.swift',
    'Core\Network\CookieStore.swift',
    'Core\Network\StrResponse.swift',
    'Core\Model\WebBook.swift',
    'Core\Model\BookSourcePart.swift',
    'Core\Utils\LegadoExceptions.swift',
    'Core\Utils\ChineseUtils.swift',
    'Core\Cache\ImageCacheManager.swift'
)

New-Item -ItemType Directory -Force -Path $VendorRoot | Out-Null

foreach ($rel in $paths) {
    $src = Join-Path $LegadoIosRoot $rel
    if (-not (Test-Path $src)) {
        Write-Warning "跳过缺失: $src"
        continue
    }
    $dest = Join-Path $VendorRoot $rel
    if (Test-Path $src -PathType Container) {
        Copy-Item -Recurse -Force $src $dest
    } else {
        $destDir = Split-Path $dest -Parent
        New-Item -ItemType Directory -Force -Path $destDir | Out-Null
        Copy-Item -Force $src $dest
    }
    Write-Host "已同步: $rel"
}

$manifest = @{
    syncedAt = (Get-Date).ToString('o')
    legadoIosRoot = $LegadoIosRoot
    paths = $paths
}
$manifest | ConvertTo-Json | Set-Content -Encoding utf8 (Join-Path $VendorRoot 'manifest.json')
Write-Host '同步完成'
