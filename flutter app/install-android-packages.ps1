$ErrorActionPreference = 'Stop'
$env:JAVA_HOME = 'D:\Development\jdk-17'
$env:ANDROID_HOME = 'D:\Development\android-sdk'
$env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
$androidCli = "$env:ANDROID_HOME\cmdline-tools\latest\bin\android.exe"
# Current command-line tools use Android CLI and slash-separated package IDs.
# Disabling optional metrics also avoids a blocked prefs.dll in its bundled JRE.
# The generated Flutter 3.47.5 project also requires this exact NDK version.
& $androidCli --no-metrics --sdk=$env:ANDROID_HOME sdk install 'platform-tools' 'platforms/android-36' 'build-tools/36.0.0' 'ndk/28.2.13676358'
if ($LASTEXITCODE -ne 0) { throw 'Android package installation failed' }
