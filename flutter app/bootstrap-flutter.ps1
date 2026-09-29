$ErrorActionPreference = 'Stop'
$flutterRoot = 'D:\Development\flutter'
$engineVersion = (Get-Content "$flutterRoot\bin\internal\engine.version" -Raw).Trim()
$cachePath = "$flutterRoot\bin\cache"
New-Item -ItemType Directory -Force $cachePath | Out-Null
if (-not (Test-Path "$cachePath\dart-sdk\bin\dart.exe")) {
    curl.exe --fail --location --retry 3 --output 'D:\Development\dart-sdk.zip' "https://storage.googleapis.com/flutter_infra_release/flutter/$engineVersion/dart-sdk-windows-x64.zip"
    if ($LASTEXITCODE -ne 0) { throw 'Dart download failed' }
    tar -xf 'D:\Development\dart-sdk.zip' -C $cachePath
    if ($LASTEXITCODE -ne 0) { throw 'Dart extraction failed' }
    Set-Content "$cachePath\engine-dart-sdk.stamp" $engineVersion -Encoding Ascii
}
Write-Output 'Dart SDK bootstrap complete.'
