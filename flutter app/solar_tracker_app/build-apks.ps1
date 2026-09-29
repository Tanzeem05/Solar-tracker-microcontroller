param([switch]$UniversalRelease)

$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
try {
    flutter pub get
    if ($LASTEXITCODE -ne 0) { throw 'Dependency resolution failed' }
    flutter analyze
    if ($LASTEXITCODE -ne 0) { throw 'Analysis failed' }
    flutter test
    if ($LASTEXITCODE -ne 0) { throw 'Tests failed' }
    flutter build apk --debug --target-platform android-arm64
    if ($LASTEXITCODE -ne 0) { throw 'Debug build failed' }
    if ($UniversalRelease) {
        flutter build apk --release
    } else {
        flutter build apk --release --target-platform android-arm64
    }
    if ($LASTEXITCODE -ne 0) { throw 'Release build failed' }
    Get-ChildItem 'build\app\outputs\flutter-apk\*.apk' | Select-Object Name,Length,FullName
} finally {
    Pop-Location
}
