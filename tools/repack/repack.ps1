# 重打包编排脚本（Windows 本地调用 macOS CI 产物）
param(
    [string]$IpaIn = 'D:\soft\xiangse\ipa\香色闺阁2.56.1_未加密.ipa',
    [string]$OutDir = 'D:\soft\xiangse\dist'
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$work = 'D:\soft\xiangse\analysis\repack-work'
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $work | Out-Null

Copy-Item $IpaIn "$work\payload.zip"
Expand-Archive -Force "$work\payload.zip" "$work"

$app = "$work\Payload\StandarReader.app"
$frameworks = "$app\Frameworks"
New-Item -ItemType Directory -Force -Path $frameworks | Out-Null

$dylibSrc = 'D:\soft\xiangse\LegadoBridge\.build\iphoneos\LegadoBridge.framework'
if (Test-Path $dylibSrc) {
    Copy-Item -Recurse -Force $dylibSrc $frameworks
    Write-Host "已拷贝 LegadoBridge.framework"
} else {
    Write-Warning "LegadoBridge.framework 未编译，manifest 仍会写入"
}

$manifest = @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>LegadoBridgeVersion</key><string>1.0.0-mvp</string>
  <key>InjectPath</key><string>@executable_path/Frameworks/LegadoBridge.framework/LegadoBridge</string>
  <key>BuiltAt</key><string>$((Get-Date).ToUniversalTime().ToString('o'))</string>
</dict></plist>
"@
Set-Content -Encoding utf8 "$app\legado-bridge-manifest.plist" $manifest

$outIpa = Join-Path $OutDir 'StandarReader-legado-bridge.ipa'
if (Test-Path $outIpa) { Remove-Item $outIpa }
Compress-Archive -Path "$work\Payload" -DestinationPath "$outIpa.zip" -Force
Rename-Item "$outIpa.zip" 'StandarReader-legado-bridge.ipa'

$hash = Get-FileHash $outIpa -Algorithm SHA256
"$($hash.Hash)  StandarReader-legado-bridge.ipa" | Set-Content "$outIpa.sha256"
Write-Host "输出: $outIpa"
Write-Host "SHA256: $($hash.Hash)"
Write-Host "注意: insert_dylib 需在 macOS CI 执行 repack.sh 完成最终注入"
