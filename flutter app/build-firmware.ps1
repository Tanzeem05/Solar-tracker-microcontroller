param([string]$CompilerDirectory = (Join-Path $PSScriptRoot '.tooling\avr\avr\bin'))
$ErrorActionPreference = 'Stop'
$compiler = Join-Path $CompilerDirectory 'avr-gcc.exe'
if (!(Test-Path -LiteralPath $compiler)) { throw 'Run setup-avr.ps1 or pass -CompilerDirectory for an existing AVR GCC bin directory.' }
$buildDirectory = Join-Path $PSScriptRoot 'firmware-build'
New-Item -ItemType Directory -Force -Path $buildDirectory | Out-Null
$sourceFile = Join-Path $PSScriptRoot 'main.c'
$elf = Join-Path $buildDirectory 'main.elf'
$hex = Join-Path $buildDirectory 'main.hex'
& $compiler -mmcu=atmega32 -std=gnu99 -Os -Wall -Wextra -ffunction-sections -fdata-sections '-Wl,--gc-sections' -o $elf $sourceFile
if ($LASTEXITCODE -ne 0) { throw 'ATmega32 firmware compilation failed' }
& (Join-Path $CompilerDirectory 'avr-objcopy.exe') -O ihex -R .eeprom $elf $hex
if ($LASTEXITCODE -ne 0) { throw 'HEX generation failed' }
& (Join-Path $CompilerDirectory 'avr-size.exe') -C --mcu=atmega32 $elf
if ($LASTEXITCODE -ne 0) { throw 'Firmware size check failed' }
Write-Output "Built $hex (ATmega32, F_CPU=1 MHz). This script does not flash hardware or change fuses."
