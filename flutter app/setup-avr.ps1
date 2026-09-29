$ErrorActionPreference = 'Stop'
$toolRoot = Join-Path $PSScriptRoot '.tooling'
$archive = Join-Path $toolRoot 'avr-gcc.zip'
$destination = Join-Path $toolRoot 'avr'
New-Item -ItemType Directory -Force -Path $toolRoot | Out-Null
$expected = 'a54f64755fff4cb792a1495e5defdd789902a2a3503982e81b898299cf39800e'
if (!(Test-Path -LiteralPath $archive) -or (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $expected) {
    & curl.exe --fail --location --retry 3 --silent --show-error 'https://downloads.arduino.cc/tools/avr-gcc-7.3.0-atmel3.6.1-arduino7-i686-w64-mingw32.zip' --output $archive
    if ($LASTEXITCODE -ne 0) { throw 'AVR compiler download failed' }
}
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $expected) {
    throw 'AVR archive checksum does not match the official Arduino package index'
}
Expand-Archive -LiteralPath $archive -DestinationPath $destination -Force
Get-ChildItem -LiteralPath $destination -Recurse -Filter avr-gcc.exe | Select-Object -ExpandProperty FullName
