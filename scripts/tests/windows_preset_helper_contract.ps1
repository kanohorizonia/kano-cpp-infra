# KOG_CONTRACT_TEST: Windows preset helper contracts
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-Contract([bool]$Condition, [string]$Message) {
  if (-not $Condition) {
    throw $Message
  }
}

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\..")).Path
$helper = Join-Path $repoRoot "scripts\lib\windows_preset_helper.ps1"
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("kano-cpp-infra-windows-contract-" + [guid]::NewGuid().ToString("N"))
$substDrive = ""

try {
  $buildCommand = @(& $helper -Action cmake-build-command -BuildPreset windows-ninja-msvc-release -BuildTarget kog_runtime_artifact)
  Assert-Contract `
    ($buildCommand.Count -eq 1 -and $buildCommand[0] -eq "cmake --build --preset windows-ninja-msvc-release --target kog_runtime_artifact") `
    "CMake build command did not preserve the bounded target."

  [void](New-Item -ItemType Directory -Path $testRoot -Force)

  $toolDirectories = New-Object System.Collections.Generic.List[string]
  foreach ($tool in @("cmake", "ninja", "git", "bash", "pixi", "python")) {
    $toolDirectory = Join-Path $testRoot ("tool-" + $tool)
    [void](New-Item -ItemType Directory -Path $toolDirectory -Force)
    Set-Content -LiteralPath (Join-Path $toolDirectory ($tool + ".exe")) -Value "contract" -Encoding Ascii
    [void]$toolDirectories.Add($toolDirectory)
  }

  $paddingDirectories = New-Object System.Collections.Generic.List[string]
  foreach ($index in 0..95) {
    $paddingDirectory = Join-Path $testRoot ("padding-{0:D3}-{1}" -f $index, ("x" * 32))
    [void](New-Item -ItemType Directory -Path $paddingDirectory -Force)
    [void]$paddingDirectories.Add($paddingDirectory)
  }

  $oversizedEntries = @($paddingDirectories.ToArray()) + @($toolDirectories.ToArray())
  $oversizedPath = [string]::Join(";", $oversizedEntries)
  Assert-Contract ($oversizedPath.Length -gt 4096) "Synthetic PATH must reproduce an oversized inherited environment."

  $boundedPath = & $helper -Action bounded-build-path -Path $oversizedPath
  Assert-Contract ($boundedPath.Length -le 2048) "Bounded PATH exceeds the cmd.exe safety budget."
  foreach ($toolDirectory in $toolDirectories) {
    Assert-Contract ($boundedPath.Split(";") -contains $toolDirectory) ("Bounded PATH dropped required tool directory: " + $toolDirectory)
  }

  $shortPath = [string]::Join(";", $toolDirectories.ToArray())
  $unchangedPath = & $helper -Action bounded-build-path -Path $shortPath
  Assert-Contract ($unchangedPath -ceq $shortPath) "A short PATH must remain byte-for-byte unchanged."

  $longRoot = $testRoot
  foreach ($segment in @(("a" * 60), ("b" * 60))) {
    $longRoot = Join-Path $longRoot $segment
  }
  [void](New-Item -ItemType Directory -Path $longRoot -Force)
  $markerName = "subst-contract.marker"
  Set-Content -LiteralPath (Join-Path $longRoot $markerName) -Value "contract" -Encoding Ascii

  $substResult = & $helper `
    -Action prepare-subst-root `
    -Root $longRoot `
    -ConfigurePreset windows-ninja-msvc `
    -Mode on

  $substFields = @($substResult -split "`t")
  Assert-Contract ($substFields.Count -eq 3) "prepare-subst-root returned an invalid contract."
  $mappedRoot = $substFields[0]
  $substDrive = $substFields[1]
  $cleanupRequired = $substFields[2]
  Assert-Contract ($cleanupRequired -eq "1") "Forced SUBST must report caller-owned cleanup."
  Assert-Contract ($substDrive -match "^[A-Z]:$") "SUBST result did not include a drive."
  Assert-Contract (Test-Path -LiteralPath $mappedRoot) "Mapped SUBST root is not accessible."

  Assert-Contract (Test-Path -LiteralPath (Join-Path $mappedRoot $markerName)) "SUBST drive points at the wrong root."

  $canonicalRoot = (Resolve-Path -LiteralPath $longRoot).Path
  $cacheArguments = @(& $helper -Action cmake-cache-arguments -CanonicalRoot $canonicalRoot)
  $expectedCanonicalArgument = ('"-DKANO_CPP_INFRA_CANONICAL_SOURCE_ROOT:PATH={0}"' -f $canonicalRoot)
  Assert-Contract `
    ($cacheArguments -contains $expectedCanonicalArgument) `
    "CMake cache arguments did not preserve the physical source root."

  & $helper -Action cleanup-subst -Drive $substDrive
  Assert-Contract (-not (Test-Path -LiteralPath $mappedRoot)) "SUBST mapping remained after cleanup."
  $substDrive = ""
} finally {
  if (-not [string]::IsNullOrWhiteSpace($substDrive)) {
    & $helper -Action cleanup-subst -Drive $substDrive 2>$null
  }
  Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "PASS: Windows preset helper contracts"
