param()
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$scratchRoot = if ($env:FARMCTL_PICO_VERIFY_WORK) { $env:FARMCTL_PICO_VERIFY_WORK } else { Join-Path $env:TEMP 'farmctl-pico-native-verify' }
New-Item -ItemType Directory -Force -Path $scratchRoot | Out-Null
$work = Join-Path $scratchRoot ('fresh-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$mpArchive = Join-Path $work 'micropython.tar.gz'
$monoArchive = Join-Path $work 'monocypher.tar.gz'
$gnuArchive = Join-Path $work 'arm-gnu-toolchain.zip'
$arWheel = Join-Path $work 'ar-1.0.1-py3-none-any.whl'
$elftoolsWheel = Join-Path $work 'pyelftools-0.31-py3-none-any.whl'
$mpUrl = 'https://github.com/micropython/micropython/archive/0fd6c573ea815774668bbb16b8e197c8822368b2.tar.gz'
$monoUrl = 'https://github.com/LoupVaillant/Monocypher/archive/ab2b16dd619ad5f6979a4fbe69cfa324a6fcc35f.tar.gz'
$gnuUrl = 'https://gitlab.arm.com/api/v4/projects/tooling%2Fgnu-toolchains-for-arm/packages/generic/gnu-toolchain/14.3.rel1/arm-gnu-toolchain-14.3.rel1-mingw-w64-x86_64-arm-none-eabi.zip'

function Fetch-Verified([string]$url, [string]$path, [string]$expected) {
    # curl follows the signed S3 redirect used by Arm's official package host;
    # Windows PowerShell's Invoke-WebRequest can report success on a zero-byte body.
    & curl.exe --fail --location --retry 3 --output $path $url
    if ($LASTEXITCODE -ne 0) { throw "Download failed: $url" }
    if ((Get-Item -LiteralPath $path).Length -eq 0) { throw "Empty download: $url" }
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
    if ($actual -ne $expected) { throw "SHA-256 mismatch for $path`: $actual" }
}

function Get-RecordPath([string]$path) {
    $fullPath = [IO.Path]::GetFullPath($path)
    $workRoot = [IO.Path]::GetFullPath($work).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $repoRoot = [IO.Path]::GetFullPath($repo).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if ($fullPath.StartsWith($workRoot, [StringComparison]::OrdinalIgnoreCase)) {
        return '<work>/' + $fullPath.Substring($workRoot.Length).Replace('\', '/')
    }
    if ($fullPath.StartsWith($repoRoot, [StringComparison]::OrdinalIgnoreCase)) {
        return '<repo>/' + $fullPath.Substring($repoRoot.Length).Replace('\', '/')
    }
    return $fullPath.Replace('\', '/')
}
Fetch-Verified $mpUrl $mpArchive '77331374753ac6e524b9f7aa606fbcfd1cc2c6ae9fb567c971a2e31cb5de6225'
Fetch-Verified $monoUrl $monoArchive '60dda1114a817826a0c753275190968e1b4a2d9f7e31e3d6daa09272c4746f5f'
Fetch-Verified $gnuUrl $gnuArchive '864c0c8815857d68a1bbba2e5e2782255bb922845c71c97636004a3d74f60986'
Fetch-Verified 'https://files.pythonhosted.org/packages/de/b9/919ec85022e3b4c7b8bdf7729720666fe4d5eaff016a85b301bf0ce67798/ar-1.0.1-py3-none-any.whl' $arWheel 'ee6b676acbe1c31b28e108361f23e44432324dafc87a782e9286896bf77dec8e'
Fetch-Verified 'https://files.pythonhosted.org/packages/f8/64/711030d9fe9ccaf6ee3ab1bcf4801c6bb3d0e585af18824a50b016b4f39c/pyelftools-0.31-py3-none-any.whl' $elftoolsWheel 'f52de7b3c7e8c64c8abc04a79a1cf37ac5fb0b8a49809827130b858944840607'

$mpDir = Join-Path $work 'micropython'
$monoDir = Join-Path $work 'monocypher'
$gnuDir = Join-Path $work 'gnu'
if (-not (Test-Path (Join-Path $mpDir 'tools\mpy_ld.py'))) {
    New-Item -ItemType Directory -Force -Path $mpDir | Out-Null
    tar -xzf $mpArchive -C $mpDir --strip-components=1
    if ($LASTEXITCODE -ne 0) { throw 'MicroPython extraction failed' }
}
if (-not (Test-Path (Join-Path $monoDir 'src\monocypher.c'))) {
    New-Item -ItemType Directory -Force -Path $monoDir | Out-Null
    tar -xzf $monoArchive -C $monoDir --strip-components=1
    if ($LASTEXITCODE -ne 0) { throw 'Monocypher extraction failed' }
}
if (-not (Test-Path (Join-Path $gnuDir 'bin\arm-none-eabi-gcc.exe'))) {
    New-Item -ItemType Directory -Force -Path $gnuDir | Out-Null
    Expand-Archive -LiteralPath $gnuArchive -DestinationPath $gnuDir
}
$gcc = Join-Path $gnuDir 'bin\arm-none-eabi-gcc.exe'
if (-not (Test-Path $gcc)) { throw 'Pinned Arm GNU compiler missing after extraction' }

$venv = Join-Path $work 'venv'
python -m venv $venv
if ($LASTEXITCODE -ne 0) { throw 'Python venv creation failed' }
$python = Join-Path $venv 'Scripts\python.exe'
& $python -m pip install --disable-pip-version-check --no-index --no-deps $elftoolsWheel
if ($LASTEXITCODE -ne 0) { throw 'Installing pinned pyelftools failed' }
& $python -m pip install --disable-pip-version-check --no-index --no-deps $arWheel
if ($LASTEXITCODE -ne 0) { throw 'Installing pinned ar linker dependency failed' }
$env:PYTHONHASHSEED = '42'
$sourceFiles = @(
    (Join-Path $repo 'firmware\pico_native_verify\native\verify.c'),
    (Join-Path $repo 'firmware\pico_native_verify\adapter\verifier.c'),
    (Join-Path $monoDir 'src\monocypher.c'),
    (Join-Path $monoDir 'src\optional\monocypher-ed25519.c')
)
$queryFlags = @('-mthumb','-mcpu=cortex-m3','-mfloat-abi=soft')
$libgcc = (& $gcc @queryFlags '-print-libgcc-file-name').Trim()
$libm = (& $gcc @queryFlags '-print-file-name=libm.a').Trim()
$libc = (& $gcc @queryFlags '-print-file-name=libc.a').Trim()
$mpyLd = Join-Path $mpDir 'tools\mpy_ld.py'

function Build-Link([string]$name) {
    $out = Join-Path $work $name
    New-Item -ItemType Directory -Path $out | Out-Null
    $config = Join-Path $out 'verify_config.h'
    $log = Join-Path $out 'build.log'
    $objects = @()
    $flags = @('-std=c99','-Os','-Wall','-Werror','-DNDEBUG','-DNO_QSTR',
        '-DMICROPY_ENABLE_DYNRUNTIME','-DMP_CONFIGFILE=<verify_config.h>',
        '-DMICROPY_FLOAT_IMPL=MICROPY_FLOAT_IMPL_FLOAT','-fpic','-fno-common',
        '-U_FORTIFY_SOURCE','-mthumb','-mcpu=cortex-m3','-I',$out,
        '-I',$mpDir,'-I',(Join-Path $repo 'firmware\pico_native_verify\adapter'),
        '-I',(Join-Path $monoDir 'src'),'-I',(Join-Path $monoDir 'src\optional'))
    Push-Location $out
    try {
        & $python $mpyLd --arch armv7m --preprocess -o $config @sourceFiles *> $log
        if ($LASTEXITCODE -ne 0) { throw 'mpy_ld preprocess failed' }
        for ($index=0; $index -lt $sourceFiles.Count; $index++) {
            $obj = Join-Path $out "source$index.o"
            & $gcc @flags -c $sourceFiles[$index] -o $obj *>> $log
            if ($LASTEXITCODE -ne 0) { throw "GCC compile failed: $($sourceFiles[$index])" }
            $objects += $obj
        }
        $raw = Join-Path $out 'verify.mpy'
        # mpy_ld's verbose "using <archive>:<member>" trace is the authoritative
        # record of archive members actually selected and loaded into this link.
        & $python $mpyLd --arch armv7m --qstrs $config -vv -l $libgcc -l $libm -l $libc -o $raw @objects *>> $log
        if ($LASTEXITCODE -ne 0) { throw 'mpy_ld link failed' }
        $linkTrace = @(Get-Content -LiteralPath $log | Where-Object { $_ -match '^using .+\.a:.+$' })
        if ($linkTrace.Count -eq 0) { throw "No selected archive-member trace found in $log" }
        $linkTrace | Set-Content -Encoding UTF8 (Join-Path $out 'selected-archive-members.txt')
        return $raw
    } finally { Pop-Location }
}

$first = Build-Link 'seed42-a'
$second = Build-Link 'seed42-b'
$firstHash = (Get-FileHash -Algorithm SHA256 $first).Hash.ToLowerInvariant()
$secondHash = (Get-FileHash -Algorithm SHA256 $second).Hash.ToLowerInvariant()
$secondSize = (Get-Item $second).Length
$firstSize = (Get-Item $first).Length
if ($firstHash -ne $secondHash -or $firstSize -ne $secondSize) {
    throw "Reproducibility/reference mismatch: sizes $firstSize / $((Get-Item $second).Length), hashes $firstHash / $secondHash"
}
Rename-Item $first 'verify.mpy.UNQUALIFIED'
Rename-Item $second 'verify-second.mpy.UNQUALIFIED'
Write-Output "PASS: two byte-identical pinned GNU builds, size=$firstSize SHA256=$firstHash"
Write-Output "Fresh outputs remain UNQUALIFIED at $work"
$consumed = @($sourceFiles + @($mpyLd, (Join-Path $work 'seed42-a\verify_config.h'), $libgcc, $libm, $libc)) | ForEach-Object {
    if (Test-Path -LiteralPath $_ -PathType Leaf) {
        [pscustomobject]@{ path = Get-RecordPath $_; sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $_).Hash.ToLowerInvariant() }
    }
}
$objectsRecord = @((Join-Path $work 'seed42-a\source0.o'), (Join-Path $work 'seed42-a\source1.o'), (Join-Path $work 'seed42-a\source2.o'), (Join-Path $work 'seed42-a\source3.o')) | ForEach-Object {
    [pscustomobject]@{ path = Get-RecordPath $_; sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $_).Hash.ToLowerInvariant() }
}
$gitRevision = (& git -C $repo rev-parse HEAD).Trim()
$pythonVersion = (& $python --version 2>&1 | Out-String).Trim()
$pipFreeze = (& $python -m pip list --format=freeze | Out-String).Trim()
$archiveRecord = @($mpArchive, $monoArchive, $gnuArchive, $arWheel, $elftoolsWheel) | ForEach-Object {
    [pscustomobject]@{ path = Get-RecordPath $_; sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $_).Hash.ToLowerInvariant() }
}
$selectedMembers = @()
foreach ($buildName in @('seed42-a', 'seed42-b')) {
    $logPath = Join-Path (Join-Path $work $buildName) 'selected-archive-members.txt'
    foreach ($line in Get-Content -LiteralPath $logPath) {
        if ($line -match '^using (.+\.a):(.+)$') {
            $archivePath = $Matches[1]
            $memberName = $Matches[2]
            $archiveKind = switch -Regex ([IO.Path]::GetFileName($archivePath)) {
                '^libgcc\.a$' { 'libgcc'; break }
                '^libm\.a$' { 'libm'; break }
                '^libc\.a$' { 'libc'; break }
                default { 'unknown' }
            }
            $selectedMembers += [pscustomobject]@{ build = $buildName; archive = $archiveKind; archivePath = Get-RecordPath $archivePath; member = $memberName }
        }
    }
}
if (@($selectedMembers | Where-Object { $_.archive -eq 'unknown' }).Count -gt 0) { throw 'Unexpected archive in selected-member link trace' }
$toolchainFiles = @($libgcc, $libm, $libc) | ForEach-Object {
    [pscustomobject]@{ path = Get-RecordPath $_; sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $_).Hash.ToLowerInvariant(); originUrl = $gnuUrl; toolchainArchiveSha256 = '864c0c8815857d68a1bbba2e5e2782255bb922845c71c97636004a3d74f60986' }
}
[pscustomobject]@{ gitRevision = $gitRevision; pythonVersion = $pythonVersion; packages = $pipFreeze; archives = $archiveRecord; toolchainLibraries = $toolchainFiles; selectedArchiveMembers = $selectedMembers; consumedInputs = $consumed; objects = $objectsRecord; artifactSize = $firstSize; artifactSha256 = $firstHash; seed = 42 } |
    ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 (Join-Path $work 'build-record.json')
$env:FARMCTL_PICO_VERIFY_WORK = $work
& (Join-Path $PSScriptRoot 'test_host.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Host fixture validation failed' }
