$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$work = if ($env:FARMCTL_PICO_VERIFY_WORK) { $env:FARMCTL_PICO_VERIFY_WORK } else { Join-Path $env:TEMP 'farmctl-pico-native-verify' }
$mono = Join-Path $work 'monocypher'
if (-not (Test-Path (Join-Path $mono 'src\monocypher.c'))) {
    throw "Pinned Monocypher sources not found under $mono; run build.ps1 first"
}
$gccCommand = Get-Command gcc -ErrorAction SilentlyContinue
if (-not $gccCommand) { throw 'Host fixture build requires gcc on PATH (for example MSYS2 UCRT64)' }
$output = Join-Path $work 'host-fixtures'
New-Item -ItemType Directory -Force -Path $output | Out-Null
$include = Join-Path $mono 'src'
$optional = Join-Path $include 'optional'
$adapter = Join-Path $repo 'firmware\pico_native_verify\adapter\verifier.c'
$monocypher = Join-Path $include 'monocypher.c'
$ed25519 = Join-Path $optional 'monocypher-ed25519.c'
$verifyLibrary = Join-Path $output 'farmctl_verifier.dll'
$signerLibrary = Join-Path $output 'farmctl_fixture_signer.dll'
& $gccCommand.Source -std=c99 -O2 -Wall -Wextra -Werror -shared -I $include -I $optional `
    $adapter $monocypher $ed25519 -o $verifyLibrary
if ($LASTEXITCODE -ne 0) { throw 'Host verifier library build failed' }
& $gccCommand.Source -std=c99 -O2 -Wall -Wextra -Werror -shared -I $include -I $optional `
    (Join-Path $PSScriptRoot 'fixture_signer.c') $monocypher $ed25519 -o $signerLibrary
if ($LASTEXITCODE -ne 0) { throw 'Synthetic fixture signer build failed' }
$env:FARMCTL_VERIFY_LIBRARY = $verifyLibrary
$env:FARMCTL_FIXTURE_SIGNER = $signerLibrary
python -m unittest discover -s (Join-Path $PSScriptRoot '.') -p 'test_host.py' -v
if ($LASTEXITCODE -ne 0) { throw 'Host synthetic fixture checks failed' }
