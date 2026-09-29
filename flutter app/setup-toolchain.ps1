param([switch]$SkipFlutter)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$devRoot = 'D:\Development'
New-Item -ItemType Directory -Force -Path $devRoot | Out-Null
if (-not $SkipFlutter -and -not (Test-Path "$devRoot\flutter\bin\flutter.bat")) {
    $releases = Invoke-RestMethod 'https://storage.googleapis.com/flutter_infra_release/releases/releases_windows.json'
    $stable = $releases.releases | Where-Object hash -eq $releases.current_release.stable | Select-Object -First 1
    Write-Output "Downloading Flutter $($stable.version)"
    curl.exe --fail --location --retry 3 --output "$devRoot\flutter-sdk.zip" "$($releases.base_url)/$($stable.archive)"
    if ($LASTEXITCODE -ne 0) { throw 'Flutter download failed' }
    if ((Get-FileHash "$devRoot\flutter-sdk.zip" -Algorithm SHA256).Hash -ne $stable.sha256) { throw 'Flutter checksum mismatch' }
    tar -xf "$devRoot\flutter-sdk.zip" -C $devRoot
    if ($LASTEXITCODE -ne 0) { throw 'Flutter extraction failed' }
}
if (-not (Test-Path "$devRoot\jdk-17\bin\java.exe")) {
    $jdk = Invoke-RestMethod 'https://api.adoptium.net/v3/assets/latest/17/hotspot?architecture=x64&image_type=jdk&os=windows&vendor=eclipse'
    Write-Output 'Downloading Temurin JDK 17'
    curl.exe --fail --location --retry 3 --output "$devRoot\jdk17.zip" $jdk[0].binary.package.link
    if ($LASTEXITCODE -ne 0) { throw 'JDK download failed' }
    if ((Get-FileHash "$devRoot\jdk17.zip" -Algorithm SHA256).Hash -ne $jdk[0].binary.package.checksum) { throw 'JDK checksum mismatch' }
    Expand-Archive "$devRoot\jdk17.zip" -DestinationPath "$devRoot\jdk-extract" -Force
    $jdkDirectory = Get-ChildItem "$devRoot\jdk-extract" -Directory | Select-Object -First 1
    Copy-Item -LiteralPath $jdkDirectory.FullName -Destination "$devRoot\jdk-17" -Recurse
}
$sdkRoot = "$devRoot\android-sdk"
if (-not (Test-Path "$sdkRoot\cmdline-tools\latest\bin\sdkmanager.bat")) {
    [xml]$repository = (Invoke-WebRequest 'https://dl.google.com/android/repository/repository2-1.xml' -UseBasicParsing).Content
    $commandTools = $repository.SelectNodes('//*[local-name()="remotePackage"]') | Where-Object { $_.path -eq 'cmdline-tools;latest' } | Select-Object -First 1
    $archive = $commandTools.archives.archive | Where-Object { $_.'host-os' -eq 'windows' } | Select-Object -First 1
    Write-Output 'Downloading Android command-line tools'
    curl.exe --fail --location --retry 3 --output "$devRoot\android-tools.zip" "https://dl.google.com/android/repository/$($archive.complete.url)"
    if ($LASTEXITCODE -ne 0) { throw 'Android tools download failed' }
    Expand-Archive "$devRoot\android-tools.zip" -DestinationPath "$devRoot\android-tools-extract" -Force
    New-Item -ItemType Directory -Force -Path "$sdkRoot\cmdline-tools" | Out-Null
    Copy-Item -LiteralPath "$devRoot\android-tools-extract\cmdline-tools" -Destination "$sdkRoot\cmdline-tools\latest" -Recurse
}
$env:JAVA_HOME = "$devRoot\jdk-17"
$env:ANDROID_HOME = $sdkRoot
$env:ANDROID_SDK_ROOT = $sdkRoot
$env:Path = "$devRoot\flutter\bin;$sdkRoot\platform-tools;$env:JAVA_HOME\bin;$env:Path"
[Environment]::SetEnvironmentVariable('ANDROID_HOME', $sdkRoot, 'User')
[Environment]::SetEnvironmentVariable('ANDROID_SDK_ROOT', $sdkRoot, 'User')
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
foreach ($addition in @("$devRoot\flutter\bin", "$sdkRoot\platform-tools")) {
    if (($userPath -split ';') -notcontains $addition) { $userPath += ";$addition" }
}
[Environment]::SetEnvironmentVariable('Path', $userPath, 'User')
if (Test-Path "$devRoot\flutter\bin\flutter.bat") {
    & "$devRoot\flutter\bin\flutter.bat" config --jdk-dir "$devRoot\jdk-17" --android-sdk $sdkRoot --no-analytics
    & "$devRoot\flutter\bin\flutter.bat" --version
}
& 'C:\Users\HP\AppData\Local\Programs\Microsoft VS Code\bin\code.cmd' --install-extension Dart-Code.flutter --force
Write-Output 'Base toolchain installed. Android platforms and licenses follow project creation.'
