param(
  [Parameter(Mandatory = $true)]
  [string]$Action,

  [string]$Path = "",
  [string]$Root = "",
  [string]$CanonicalRoot = "",
  [string]$BuildDir = "",
  [string]$Config = "Debug",
  [string]$Generator = "Ninja",
  [string]$Arch = "x64",
  [string]$CoverageBuildDir = "",
  [string]$Vcvars = "",
  [string]$ConfigurePreset = "",
  [string]$BuildPreset = "",
  [string]$BuildTarget = "",
  [switch]$SkipConfigure,
  [string]$VcvarsVersion = "",
  [string]$PreferredDrive = "",
  [string]$Mode = "auto",
  [string]$Drive = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($VcvarsVersion)) {
  $VcvarsVersion = $env:KANO_VCVARS_VERSION
}
if ([string]::IsNullOrWhiteSpace($VcvarsVersion)) {
  # Default to 2026 MSVC toolchain (14.44.35207)
  $VcvarsVersion = "14.44.35207"
}

function Get-SubstMappings {
  $mappings = @{}
  @(& cmd.exe /d /c subst) | ForEach-Object {
    if ($_ -match "^([A-Z]):\\:\s*=>\s*(.+)$") {
      $letter = $matches[1].ToUpperInvariant()
      $target = $matches[2].Trim()
      if (-not [string]::IsNullOrWhiteSpace($target)) {
        $mappings[$letter] = $target
      }
    }
  }
  return $mappings
}

function Expand-SubstPath([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) {
    return ""
  }

  $candidate = $Value.Trim()
  if ($candidate -notmatch "^(?<drive>[A-Za-z]):(?<rest>(\\|/).*)?$") {
    return $candidate
  }

  $driveLetter = $matches["drive"].ToUpperInvariant()
  $mappings = Get-SubstMappings
  if (-not $mappings.ContainsKey($driveLetter)) {
    return $candidate
  }

  $targetRoot = $mappings[$driveLetter] -replace "/", "\"
  while ($targetRoot.Length -gt 3 -and $targetRoot.EndsWith("\")) {
    $targetRoot = $targetRoot.Substring(0, $targetRoot.Length - 1)
  }

  $rest = $matches["rest"]
  if ([string]::IsNullOrWhiteSpace($rest)) {
    return $targetRoot
  }

  $normalizedRest = $rest -replace "/", "\"
  if ($normalizedRest.StartsWith("\")) {
    return $targetRoot + $normalizedRest
  }
  return $targetRoot + "\" + $normalizedRest
}

function Resolve-AbsoluteWindowsPath([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) {
    return ""
  }

  $candidate = Expand-SubstPath $Value
  $resolved = Resolve-Path -LiteralPath $candidate -ErrorAction SilentlyContinue
  if ($resolved) {
    $candidate = $resolved.Path
  }

  $candidate = $candidate -replace "/", "\"
  while ($candidate.Length -gt 3 -and $candidate.EndsWith("\")) {
    $candidate = $candidate.Substring(0, $candidate.Length - 1)
  }
  return $candidate
}

function Get-ProjectedBuildPathLength([string]$InRoot, [string]$InPreset) {
  $buildRoot = Join-Path $InRoot ("out\obj\" + $InPreset)
  # CMake target directories and MSVC dependency sidecars commonly add 160+
  # characters beyond the configured binary directory.
  return $buildRoot.Length + 180
}

function Prepare-SubstRoot([string]$InRoot, [string]$InPreset, [string]$InPreferredDrive, [string]$InMode) {
  $tab = [char]9
  $root = Resolve-AbsoluteWindowsPath $InRoot
  if ([string]::IsNullOrWhiteSpace($root)) {
    $root = $InRoot
  }

  $modeName = $InMode.Trim().ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($modeName)) {
    $modeName = "auto"
  }

  $pathLimit = 240
  $configuredLimit = $env:KANO_WINDOWS_PATH_LIMIT
  if ([string]::IsNullOrWhiteSpace($configuredLimit)) {
    $configuredLimit = $env:INF_WINDOWS_PATH_LIMIT
  }
  if ($configuredLimit -match "^\d+$" -and [int]$configuredLimit -gt 0) {
    $pathLimit = [int]$configuredLimit
  }

  $projectedLength = Get-ProjectedBuildPathLength -InRoot $root -InPreset $InPreset
  $shouldMap = $modeName -eq "on" -or ($modeName -ne "off" -and $projectedLength -ge $pathLimit)
  if (-not [string]::IsNullOrWhiteSpace($InPreferredDrive)) {
    $shouldMap = $true
  }
  if (-not $shouldMap) {
    Write-Output ($root + $tab + $tab + "0")
    return
  }

  $mappings = Get-SubstMappings
  foreach ($entry in $mappings.GetEnumerator()) {
    $mappedRoot = Resolve-AbsoluteWindowsPath $entry.Value
    if ($mappedRoot.Equals($root, [System.StringComparison]::OrdinalIgnoreCase)) {
      Write-Output (($entry.Key + ":\") + $tab + ($entry.Key + ":") + $tab + "0")
      return
    }
  }

  $preferred = ""
  if ($InPreferredDrive -match "^([A-Za-z]):?$") {
    $preferred = $matches[1].ToUpperInvariant()
  }

  $candidates = New-Object System.Collections.Generic.List[string]
  if (-not [string]::IsNullOrWhiteSpace($preferred)) {
    [void]$candidates.Add($preferred)
  }
  foreach ($letter in @("Z","Y","X","W","V","U","T","S","R","Q","P","O","N","M","L","K","J","I","H","G","F","E","D")) {
    if (-not $candidates.Contains($letter)) {
      [void]$candidates.Add($letter)
    }
  }

  $used = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  Get-PSDrive -PSProvider FileSystem | ForEach-Object { [void]$used.Add($_.Name) }
  foreach ($letter in $mappings.Keys) {
    [void]$used.Add($letter)
  }

  foreach ($letter in $candidates) {
    if ($used.Contains($letter)) {
      continue
    }
    $target = $letter + ":"
    & cmd.exe /d /c subst $target $root | Out-Null
    if (Test-Path -LiteralPath ($target + "\")) {
      Write-Output (($target + "\") + $tab + $target + $tab + "1")
      return
    }
  }

  throw ("No available SUBST drive for projected Windows build path length {0} (limit {1})." -f $projectedLength, $pathLimit)
}

function Remove-SubstDrive([string]$InDrive) {
  if ([string]::IsNullOrWhiteSpace($InDrive)) {
    return
  }
  $target = $InDrive.Trim()
  if ($target -match "^[A-Za-z]$") {
    $target += ":"
  }
  & cmd.exe /d /c subst $target /d | Out-Null
}

function Detect-VsDevCmd {
  # Use vswhere to discover all installed Visual Studio instances with C++ toolset,
  # then select the newest version (VS2026/18 > VS2022/17).
  $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
  if (-not (Test-Path -LiteralPath $vswhere)) {
    return $null
  }

  $allVsdev = & $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -find "Common7\Tools\VsDevCmd.bat" 2>$null

  if (-not $allVsdev -or $allVsdev.Count -eq 0) {
    return $null
  }

  # Parse VS version and sort descending (newest first)
  # VS2026/18 uses folder "2026" or "18", VS2022/17 uses "2022" or "17"
  # Two-digit versions (18, 17) represent VS2026/VS2022 and should sort above four-digit (2022, 2019)
  $sorted = $allVsdev | ForEach-Object {
    $path = $_
    if ($path -match 'Visual Studio\\([^\\]+)\\') {
      $versionStr = $matches[1]
      $sortKey = if ($versionStr -match '^\d+$') {
        if ([int]$versionStr -lt 100) { [int]$versionStr * 1000 } else { [int]$versionStr }
      } else { 0 }
      [PSCustomObject]@{ Path = $path; VersionStr = $versionStr; SortKey = $sortKey }
    } else {
      [PSCustomObject]@{ Path = $path; VersionStr = "0"; SortKey = 0 }
    }
  } | Sort-Object -Property SortKey -Descending

  $selected = $sorted | Select-Object -First 1
  if ($selected) { Write-Output $selected.Path }
}

function Detect-Vcvarsall {
  # Use vswhere to discover all installed Visual Studio instances with C++ toolset,
  # then select the newest version (VS2026/18 > VS2022/17).
  # vswhere is the canonical way to find VS installations regardless of install path.
  $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
  if (-not (Test-Path -LiteralPath $vswhere)) {
    throw "vswhere.exe not found at '$vswhere'. Please repair Visual Studio installation."
  }

  # Find all VS installations with C++ toolset, return full path to vcvarsall.bat
  # Wrap in @() to ensure array even when vswhere returns a single string
  $allVcvars = @(& $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -find "VC\Auxiliary\Build\vcvarsall.bat" 2>$null)

  if (-not $allVcvars -or $allVcvars.Count -eq 0) {
    throw "No Visual Studio installation with C++ toolset found. Please install Visual Studio with C++ workload."
  }

  # Parse VS version from installation path and sort descending (newest first)
  # VS2026/18 uses folder "2026" or "18", VS2022/17 uses "2022" or "17"
  # Two-digit versions (18, 17) represent VS2026/VS2022 and should sort above four-digit (2022, 2019)
  $sorted = $allVcvars | ForEach-Object {
    $path = $_
    # Extract version folder name (last path component before Community/Professional/Enterprise)
    if ($path -match 'Visual Studio\\([^\\]+)\\') {
      $versionStr = $matches[1]
      # Convert to sortable number: "2026" -> 2026, "18" -> 18000 (treat 2-digit as VS2026+)
      $sortKey = if ($versionStr -match '^\d+$') {
        if ([int]$versionStr -lt 100) { [int]$versionStr * 1000 } else { [int]$versionStr }
      } else { 0 }
      [PSCustomObject]@{
        Path = $path
        VersionStr = $versionStr
        SortKey = $sortKey
      }
    } else {
      [PSCustomObject]@{ Path = $path; VersionStr = "0"; SortKey = 0 }
    }
  } | Sort-Object -Property SortKey -Descending

  # Return the newest VS installation's vcvarsall.bat
  $selected = $sorted | Select-Object -First 1
  Write-Output $selected.Path
}

function Format-CMakeCacheArgument([string]$Name, [string]$Value) {
  $escapedValue = $Value.Replace('"', '""')
  return ('"-D{0}={1}"' -f $Name, $escapedValue)
}

function Get-AdditionalCMakeCacheArguments([string]$CanonicalSourceRoot = "") {
  $arguments = New-Object System.Collections.Generic.List[string]
  $buildPrefix = "KANO"
  $cmakeVarPrefix = "KANO"

  if (-not [string]::IsNullOrWhiteSpace($CanonicalSourceRoot)) {
    $physicalSourceRoot = Resolve-AbsoluteWindowsPath $CanonicalSourceRoot
    if ([string]::IsNullOrWhiteSpace($physicalSourceRoot)) {
      $physicalSourceRoot = $CanonicalSourceRoot
    }
    [void]$arguments.Add((Format-CMakeCacheArgument -Name "KANO_CPP_INFRA_CANONICAL_SOURCE_ROOT:PATH" -Value $physicalSourceRoot))
  }

  $valueMap = @{
    "VERSION_STR" = [Environment]::GetEnvironmentVariable("${buildPrefix}_VERSION_STR")
    "BUILD_BRANCH" = [Environment]::GetEnvironmentVariable("${buildPrefix}_BUILD_BRANCH")
    "BUILD_REVISION_HASH_SHORT" = [Environment]::GetEnvironmentVariable("${buildPrefix}_BUILD_REVISION_HASH_SHORT")
    "BUILD_REVISION_HASH" = [Environment]::GetEnvironmentVariable("${buildPrefix}_BUILD_REVISION_HASH")
    "BUILD_DIRTY" = [Environment]::GetEnvironmentVariable("${buildPrefix}_BUILD_DIRTY")
    "BUILD_HOST_NAME" = [Environment]::GetEnvironmentVariable("${buildPrefix}_BUILD_HOST_NAME")
    "BUILD_PLATFORM" = [Environment]::GetEnvironmentVariable("${buildPrefix}_BUILD_PLATFORM")
  }

  if (-not [string]::IsNullOrWhiteSpace($valueMap["VERSION_STR"])) {
    [void]$arguments.Add((Format-CMakeCacheArgument -Name "${cmakeVarPrefix}_VERSION_STR" -Value $valueMap["VERSION_STR"]))
  }
  if (-not [string]::IsNullOrWhiteSpace($valueMap["BUILD_BRANCH"])) {
    [void]$arguments.Add((Format-CMakeCacheArgument -Name "${cmakeVarPrefix}_BUILD_BRANCH" -Value $valueMap["BUILD_BRANCH"]))
  }
  if (-not [string]::IsNullOrWhiteSpace($valueMap["BUILD_REVISION_HASH_SHORT"])) {
    [void]$arguments.Add((Format-CMakeCacheArgument -Name "${cmakeVarPrefix}_BUILD_REVISION_HASH_SHORT" -Value $valueMap["BUILD_REVISION_HASH_SHORT"]))
  }
  if (-not [string]::IsNullOrWhiteSpace($valueMap["BUILD_REVISION_HASH"])) {
    [void]$arguments.Add((Format-CMakeCacheArgument -Name "${cmakeVarPrefix}_BUILD_REVISION_HASH" -Value $valueMap["BUILD_REVISION_HASH"]))
    [void]$arguments.Add((Format-CMakeCacheArgument -Name "${cmakeVarPrefix}_BUILD_REVISION" -Value $valueMap["BUILD_REVISION_HASH"]))
  }
  if (-not [string]::IsNullOrWhiteSpace($valueMap["BUILD_DIRTY"])) {
    [void]$arguments.Add((Format-CMakeCacheArgument -Name "${cmakeVarPrefix}_BUILD_DIRTY" -Value $valueMap["BUILD_DIRTY"]))
  }
  if (-not [string]::IsNullOrWhiteSpace($valueMap["BUILD_HOST_NAME"])) {
    [void]$arguments.Add((Format-CMakeCacheArgument -Name "${cmakeVarPrefix}_BUILD_HOST_NAME" -Value $valueMap["BUILD_HOST_NAME"]))
  }
  if (-not [string]::IsNullOrWhiteSpace($valueMap["BUILD_PLATFORM"])) {
    [void]$arguments.Add((Format-CMakeCacheArgument -Name "${cmakeVarPrefix}_BUILD_PLATFORM" -Value $valueMap["BUILD_PLATFORM"]))
  }

  $rawCacheArgsJson = $env:KANO_CPP_INFRA_CMAKE_CACHE_ARGS_JSON
  if ([string]::IsNullOrWhiteSpace($rawCacheArgsJson)) {
    $rawCacheArgsJson = $env:INF_CMAKE_CACHE_ARGS_JSON
  }

  if (-not [string]::IsNullOrWhiteSpace($rawCacheArgsJson)) {
    try {
      $parsedCacheArgs = $rawCacheArgsJson | ConvertFrom-Json -ErrorAction Stop
      foreach ($property in $parsedCacheArgs.PSObject.Properties) {
        $name = [string]$property.Name
        if ([string]::IsNullOrWhiteSpace($name)) {
          continue
        }
        $value = ""
        if ($null -ne $property.Value) {
          $value = [string]$property.Value
        }
        [void]$arguments.Add((Format-CMakeCacheArgument -Name $name -Value $value))
      }
    } catch {
      throw ("Invalid KANO_CPP_INFRA_CMAKE_CACHE_ARGS_JSON/INF_CMAKE_CACHE_ARGS_JSON: {0}" -f $_.Exception.Message)
    }
  }

  return $arguments.ToArray()
}

function Get-WindowsSdkToolPaths {
  $roots = @(
    'C:\Program Files (x86)\Windows Kits\10\bin',
    'C:\Program Files\Windows Kits\10\bin'
  )

  $latestDir = $null
  foreach ($root in $roots) {
    if (-not (Test-Path -LiteralPath $root)) {
      continue
    }

    $dirs = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
      Sort-Object Name -Descending
    foreach ($dir in $dirs) {
      $candidate = Join-Path $dir.FullName 'x64'
      if (Test-Path -LiteralPath $candidate) {
        $latestDir = $candidate
        break
      }
    }
    if ($latestDir) {
      break
    }
  }

  if (-not $latestDir) {
    return $null
  }

  $rc = Join-Path $latestDir 'rc.exe'
  $mt = Join-Path $latestDir 'mt.exe'
  if ((-not (Test-Path -LiteralPath $rc)) -or (-not (Test-Path -LiteralPath $mt))) {
    return $null
  }

  $rc = $rc -replace '\\','/'
  $mt = $mt -replace '\\','/'

  return @{
    Rc = $rc
    Mt = $mt
  }
}

function Get-PixiEnvironmentRoot([string]$ProjectRoot) {
  # Check for infra-level pixi env first (src/cpp/shared/infra/.pixi/envs/default)
  # This takes priority over root-level .pixi since infra has its own environment
  $infraPixiRoot = Join-Path $ProjectRoot "shared\infra\.pixi\envs\default"
  if (Test-Path -LiteralPath $infraPixiRoot) {
    return (Resolve-Path -LiteralPath $infraPixiRoot).Path
  }

  # Fall back to root-level .pixi/envs/default
  $rootPixiEnvRoot = Join-Path $ProjectRoot ".pixi\envs\default"
  if (Test-Path -LiteralPath $rootPixiEnvRoot) {
    return (Resolve-Path -LiteralPath $rootPixiEnvRoot).Path
  }

  # Search up the tree for any .pixi/envs/default
  $root = $ProjectRoot
  while (-not [string]::IsNullOrWhiteSpace($root)) {
    $pixiEnvRoot = Join-Path $root ".pixi\envs\default"
    if (Test-Path -LiteralPath $pixiEnvRoot) {
      return (Resolve-Path -LiteralPath $pixiEnvRoot).Path
    }
    $parentRoot = Split-Path -Parent $root
    if ([string]::IsNullOrWhiteSpace($parentRoot) -or $parentRoot -eq $root) {
      break
    }
    $root = $parentRoot
  }

  throw "pixi environment root not found from $ProjectRoot. Run './scripts/kog self install-prereq' from the repository root."
}

function Test-ValidExecutable([string]$Path) {
  # Returns true only if the path points to a non-empty, valid executable file.
  if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
  $resolved = Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue
  if (-not $resolved) { return $false }
  $item = Get-Item -LiteralPath $resolved.Path -ErrorAction SilentlyContinue
  if (-not $item) { return $false }
  # Must be a file with non-zero length (WinGet symlinks can be 0-byte stubs)
  return ($item.Length -gt 0)
}

function Get-GlobalToolPath([string]$ToolName) {
  # Check common global pixi locations first — these are always valid executables.
  # This avoids picking up broken WinGet 0-byte stub symlinks from PATH.
  $userPixiBin = $null
  if ($env:HOME) {
    $userPixiBin = Join-Path $env:HOME ".pixi\bin"
  } elseif ($env:USERPROFILE) {
    $userPixiBin = Join-Path $env:USERPROFILE ".pixi\bin"
  }
  if ($userPixiBin) {
    $pixiToolPath = Join-Path $userPixiBin "$ToolName.exe"
    if (Test-ValidExecutable $pixiToolPath) {
      return (Resolve-Path -LiteralPath $pixiToolPath).Path
    }
    $pixiToolPathNoExt = Join-Path $userPixiBin $ToolName
    if (Test-ValidExecutable $pixiToolPathNoExt) {
      return (Resolve-Path -LiteralPath $pixiToolPathNoExt).Path
    }
  }

  # Try PowerShell-native PATH search, but validate the result is a real executable.
  $candidates = @(Get-Command -Name $ToolName -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source)
  foreach ($candidate in $candidates) {
    if (Test-ValidExecutable $candidate) {
      return (Resolve-Path -LiteralPath $candidate -ErrorAction SilentlyContinue).Path
    }
  }

  # Fallback to cmd.exe where, validating each result.
  $output = cmd.exe /c "where $ToolName 2>nul"
  if ($null -ne $output -and $output.Trim() -ne "") {
    foreach ($line in $output.Trim().Split([Environment]::NewLine)) {
      $toolPath = $line.Trim()
      if (Test-ValidExecutable $toolPath) {
        return (Resolve-Path -LiteralPath $toolPath).Path
      }
    }
  }

  return $null
}

function Get-PixiBuildToolPrefix([string]$ProjectRoot) {
  # First check for global tools (cmake, ninja) in PATH - these may come from ~/.pixi
  $cmakePath = Get-GlobalToolPath "cmake"
  $ninjaPath = Get-GlobalToolPath "ninja"
  $resolved = New-Object System.Collections.Generic.List[string]

  if ($cmakePath -and $ninjaPath) {
    $cmakeDir = Split-Path -Parent $cmakePath
    if ($cmakeDir) {
      [void]$resolved.Add($cmakeDir)
    }
  }

  # If global tools found, return them (allow pixi env to be missing)
  if ($resolved.Count -gt 0) {
    return [string]::Join(';', $resolved)
  }

  # Fall back to pixi environment
  $pixiEnvRoot = $null
  $pixiEnvFound = $false
  try {
    $pixiEnvRoot = Get-PixiEnvironmentRoot -ProjectRoot $ProjectRoot
    $pixiEnvFound = $true
  } catch {
    # No pixi environment found — will use global tools only
  }

  if ($pixiEnvFound -and $pixiEnvRoot) {
    $candidates = @(
      (Join-Path $pixiEnvRoot "Library\bin"),
      (Join-Path $pixiEnvRoot "Scripts"),
      (Join-Path $pixiEnvRoot "bin")
    )
    foreach ($candidate in $candidates) {
      if (Test-Path -LiteralPath $candidate) {
        [void]$resolved.Add((Resolve-Path -LiteralPath $candidate).Path)
      }
    }
  }

  if ($resolved.Count -eq 0) {
    if ($pixiEnvRoot) {
      throw "pixi build tool environment not found under $pixiEnvRoot. Run './scripts/kog self install-prereq' from the repository root."
    } else {
      throw "pixi build tool environment not found. Run './scripts/kog self install-prereq' from the repository root to install."
    }
  }

  return [string]::Join(';', $resolved)
}

function Get-PixiNinjaPath([string]$ProjectRoot) {
  # Check global tools in PATH first (from ~/.pixi/bin or WinGet links)
  $globalNinjaPath = Get-GlobalToolPath "ninja"
  if ($globalNinjaPath) {
    return $globalNinjaPath
  }

  # Fall back to per-repo pixi environment
  $pixiEnvRoot = $null
  try {
    $pixiEnvRoot = Get-PixiEnvironmentRoot -ProjectRoot $ProjectRoot
  } catch {
    # No pixi environment found — fall through to error
  }

  if ($pixiEnvRoot) {
    $ninjaPath = Join-Path $pixiEnvRoot "Library\bin\ninja.exe"
    if (Test-Path -LiteralPath $ninjaPath) {
      return (Resolve-Path -LiteralPath $ninjaPath).Path
    }
  }

  if ($pixiEnvRoot) {
    throw "pixi ninja.exe not found at $ninjaPath and not in PATH. Run './scripts/kog self install-prereq' from the repository root."
  } else {
    throw "ninja.exe not found in PATH and no pixi environment found. Run './scripts/kog self install-prereq' from the repository root to install pixi environment."
  }
}

function Get-LlvmToolPrefix {
  $candidates = New-Object System.Collections.Generic.List[string]
  if ($env:KANO_LLVM_BIN) { [void]$candidates.Add($env:KANO_LLVM_BIN) }
  if ($env:LLVM_BIN) { [void]$candidates.Add($env:LLVM_BIN) }
  [void]$candidates.Add("C:\Program Files\LLVM\bin")
  [void]$candidates.Add("C:\Program Files\Microsoft Visual Studio\18\Community\VC\Tools\Llvm\x64\bin")
  [void]$candidates.Add("C:\Program Files\Microsoft Visual Studio\18\Community\VC\Tools\Llvm\bin")
  [void]$candidates.Add("C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\Llvm\x64\bin")
  [void]$candidates.Add("C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\Llvm\bin")

  foreach ($candidate in $candidates) {
    if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
    $clang = Join-Path $candidate "clang-cl.exe"
    $profdata = Join-Path $candidate "llvm-profdata.exe"
    $cov = Join-Path $candidate "llvm-cov.exe"
    if ((Test-ValidExecutable $clang) -and (Test-ValidExecutable $profdata) -and (Test-ValidExecutable $cov)) {
      return (Resolve-Path -LiteralPath $candidate).Path
    }
  }

  return $null
}

function Get-OptionalLlvmPathStep([string]$ConfigurePreset) {
  if ([string]::IsNullOrWhiteSpace($ConfigurePreset) -or ($ConfigurePreset -notmatch "clang")) {
    return ""
  }
  $llvmPrefix = Get-LlvmToolPrefix
  if ([string]::IsNullOrWhiteSpace($llvmPrefix)) {
    throw "LLVM tools are required for clang preset '$ConfigurePreset'. Install LLVM or set KANO_LLVM_BIN."
  }
  return ('set "PATH={0};%PATH%"' -f $llvmPrefix)
}

function Add-BoundedPathEntry(
  [System.Collections.Generic.List[string]]$Entries,
  [System.Collections.Generic.HashSet[string]]$Seen,
  [string]$Candidate,
  [int]$MaxLength,
  [bool]$Required
) {
  if ([string]::IsNullOrWhiteSpace($Candidate)) {
    return $false
  }
  $normalized = $Candidate.Trim().Trim('"')
  if (-not (Test-Path -LiteralPath $normalized -PathType Container)) {
    return $false
  }
  if ($Seen.Contains($normalized)) {
    return $true
  }

  $separatorLength = if ($Entries.Count -eq 0) { 0 } else { 1 }
  $currentLength = [string]::Join(";", $Entries).Length
  $projectedLength = $currentLength + $separatorLength + $normalized.Length
  if ($projectedLength -gt $MaxLength) {
    if ($Required) {
      throw ("Required Windows build PATH entries exceed safety budget {0}." -f $MaxLength)
    }
    return $false
  }

  [void]$Entries.Add($normalized)
  [void]$Seen.Add($normalized)
  return $true
}

function Get-BoundedBuildPath([string]$OriginalPath) {
  if ([string]::IsNullOrWhiteSpace($OriginalPath)) {
    return $OriginalPath
  }

  $maxLength = 2048
  $configuredLimit = $env:KANO_WINDOWS_CMD_PATH_LIMIT
  if ([string]::IsNullOrWhiteSpace($configuredLimit)) {
    $configuredLimit = $env:INF_WINDOWS_CMD_PATH_LIMIT
  }
  if ($configuredLimit -match "^\d+$" -and [int]$configuredLimit -ge 512) {
    $maxLength = [int]$configuredLimit
  }
  if ($OriginalPath.Length -le $maxLength) {
    return $OriginalPath
  }

  $pathEntries = @($OriginalPath.Split(";") | ForEach-Object { $_.Trim().Trim('"') } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  $selected = New-Object System.Collections.Generic.List[string]
  $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  $coveredTools = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  $requiredTools = @("cmake.exe", "ctest.exe", "ninja.exe", "git.exe", "bash.exe", "sh.exe", "pixi.exe", "python.exe", "python3.exe")

  foreach ($entry in $pathEntries) {
    foreach ($tool in $requiredTools) {
      if ($coveredTools.Contains($tool)) {
        continue
      }
      if (Test-Path -LiteralPath (Join-Path $entry $tool) -PathType Leaf) {
        [void](Add-BoundedPathEntry -Entries $selected -Seen $seen -Candidate $entry -MaxLength $maxLength -Required $true)
        [void]$coveredTools.Add($tool)
      }
    }
  }

  $systemRoot = $env:SystemRoot
  foreach ($systemPath in @(
    (Join-Path $systemRoot "System32"),
    $systemRoot,
    (Join-Path $systemRoot "System32\Wbem"),
    (Join-Path $systemRoot "System32\WindowsPowerShell\v1.0")
  )) {
    [void](Add-BoundedPathEntry -Entries $selected -Seen $seen -Candidate $systemPath -MaxLength $maxLength -Required $true)
  }

  foreach ($llvmPath in @($env:KANO_LLVM_BIN, $env:LLVM_BIN)) {
    if (-not [string]::IsNullOrWhiteSpace($llvmPath)) {
      [void](Add-BoundedPathEntry -Entries $selected -Seen $seen -Candidate $llvmPath -MaxLength $maxLength -Required $true)
    }
  }

  foreach ($entry in $pathEntries) {
    [void](Add-BoundedPathEntry -Entries $selected -Seen $seen -Candidate $entry -MaxLength $maxLength -Required $false)
  }

  return [string]::Join(";", $selected)
}

function Invoke-CmdChain([string]$CmdLine) {
  cmd.exe /d /s /c $CmdLine
  if (-not $?) { exit $LASTEXITCODE }
}

function Invoke-CmdSteps([string[]]$Steps) {
  if ($null -eq $Steps -or $Steps.Count -eq 0) {
    return
  }

  $originalPath = $env:PATH
  $boundedPath = Get-BoundedBuildPath -OriginalPath $originalPath
  $pathWasBound = -not [string]::Equals($originalPath, $boundedPath, [System.StringComparison]::Ordinal)

  $tempBase = [System.IO.Path]::GetTempFileName()
  $tempCmd = [System.IO.Path]::ChangeExtension($tempBase, ".cmd")
  Move-Item -LiteralPath $tempBase -Destination $tempCmd -Force

  try {
    $scriptLines = New-Object System.Collections.Generic.List[string]
    [void]$scriptLines.Add("@echo off")
    foreach ($step in $Steps) {
      if (-not [string]::IsNullOrWhiteSpace($step)) {
        [void]$scriptLines.Add($step)
      }
    }

    Set-Content -LiteralPath $tempCmd -Value ($scriptLines -join "`r`n") -Encoding Ascii
    if ($pathWasBound) {
      Write-Host ("[launcher][path][info] bounded inherited PATH from {0} to {1} characters" -f $originalPath.Length, $boundedPath.Length)
      $env:PATH = $boundedPath
    }
    cmd.exe /d /c ('"{0}"' -f $tempCmd)
    if (-not $?) {
      exit $LASTEXITCODE
    }
  } finally {
    if ($pathWasBound) {
      $env:PATH = $originalPath
    }
    Remove-Item -LiteralPath $tempCmd -Force -ErrorAction SilentlyContinue
  }
}

function Get-CMakeBuildCommand([string]$InBuildPreset, [string]$InBuildTarget) {
  if ([string]::IsNullOrWhiteSpace($InBuildPreset)) {
    throw "BuildPreset is required"
  }
  $command = "cmake --build --preset $InBuildPreset"
  if ([string]::IsNullOrWhiteSpace($InBuildTarget)) {
    return $command
  }
  if ($InBuildTarget -notmatch "^[A-Za-z0-9_.:+-]+$") {
    throw "BuildTarget contains unsupported characters"
  }
  return "$command --target $InBuildTarget"
}

function Run-Preset {
  if ([string]::IsNullOrWhiteSpace($Root) -or [string]::IsNullOrWhiteSpace($ConfigurePreset) -or [string]::IsNullOrWhiteSpace($BuildPreset)) {
    throw "Root, ConfigurePreset, and BuildPreset are required"
  }
  $resolvedVcvars = $Vcvars
  if ([string]::IsNullOrWhiteSpace($resolvedVcvars)) { $resolvedVcvars = Detect-Vcvarsall }
  if ([string]::IsNullOrWhiteSpace($resolvedVcvars)) { throw "vcvarsall.bat not found" }

  # Validate that the selected MSVC toolset has all required headers
  Validate-MsvcToolsetHeaders -VcvarsVersion $VcvarsVersion

  $canonicalSourceRoot = $CanonicalRoot
  if ([string]::IsNullOrWhiteSpace($canonicalSourceRoot)) {
    $canonicalSourceRoot = Resolve-AbsoluteWindowsPath $Root
  }
  $rootPath = (Resolve-Path -LiteralPath $Root).Path
  Set-Location -LiteralPath $rootPath
  $pixiNinjaPath = Get-PixiNinjaPath -ProjectRoot $rootPath

  $configureCommand = "cmake --preset $ConfigurePreset"
  $configureCommand += " " + (Format-CMakeCacheArgument -Name "CMAKE_MAKE_PROGRAM:FILEPATH" -Value $pixiNinjaPath)
  foreach ($additionalArgument in (Get-AdditionalCMakeCacheArguments -CanonicalSourceRoot $canonicalSourceRoot)) { $configureCommand += " " + $additionalArgument }
  $sdkTools = Get-WindowsSdkToolPaths
  if ($sdkTools) {
    $configureCommand += " " + (Format-CMakeCacheArgument -Name "CMAKE_MT" -Value $sdkTools.Mt)
    $configureCommand += " " + (Format-CMakeCacheArgument -Name "CMAKE_RC_COMPILER" -Value $sdkTools.Rc)
    Write-Host "[launcher][cmake][info] forcing SDK tools mt=$($sdkTools.Mt) rc=$($sdkTools.Rc)"
  }

  $vcvarsCommand = ('call "{0}" {1} -vcvars_ver={2}' -f $resolvedVcvars, $Arch, $VcvarsVersion)
  $buildCommand = Get-CMakeBuildCommand -InBuildPreset $BuildPreset -InBuildTarget $BuildTarget
  $steps = @(
    $vcvarsCommand,
    'if errorlevel 1 exit /b %errorlevel%',
    (Get-OptionalLlvmPathStep -ConfigurePreset $ConfigurePreset),
    'set "CC="',
    'set "CXX="'
  )
  if ($SkipConfigure) {
    Write-Host "[launcher][cmake][info] reusing validated configure cache"
  } else {
    $steps += @(
      $configureCommand,
      'if errorlevel 1 exit /b %errorlevel%'
    )
  }
  $steps += $buildCommand
  Invoke-CmdSteps $steps
}

function Configure-Preset {
  if ([string]::IsNullOrWhiteSpace($Root) -or [string]::IsNullOrWhiteSpace($ConfigurePreset)) {
    throw "Root and ConfigurePreset are required"
  }
  $resolvedVcvars = $Vcvars
  if ([string]::IsNullOrWhiteSpace($resolvedVcvars)) { $resolvedVcvars = Detect-Vcvarsall }
  if ([string]::IsNullOrWhiteSpace($resolvedVcvars)) { throw "vcvarsall.bat not found" }

  # Validate that the selected MSVC toolset has all required headers
  Validate-MsvcToolsetHeaders -VcvarsVersion $VcvarsVersion

  $canonicalSourceRoot = $CanonicalRoot
  if ([string]::IsNullOrWhiteSpace($canonicalSourceRoot)) {
    $canonicalSourceRoot = Resolve-AbsoluteWindowsPath $Root
  }
  $rootPath = (Resolve-Path -LiteralPath $Root).Path
  Set-Location -LiteralPath $rootPath
  $pixiNinjaPath = Get-PixiNinjaPath -ProjectRoot $rootPath

  $configureCommand = "cmake --preset $ConfigurePreset"
  $configureCommand += " " + (Format-CMakeCacheArgument -Name "CMAKE_MAKE_PROGRAM:FILEPATH" -Value $pixiNinjaPath)
  foreach ($additionalArgument in (Get-AdditionalCMakeCacheArguments -CanonicalSourceRoot $canonicalSourceRoot)) { $configureCommand += " " + $additionalArgument }
  $sdkTools = Get-WindowsSdkToolPaths
  if ($sdkTools) {
    $configureCommand += " " + (Format-CMakeCacheArgument -Name "CMAKE_MT" -Value $sdkTools.Mt)
    $configureCommand += " " + (Format-CMakeCacheArgument -Name "CMAKE_RC_COMPILER" -Value $sdkTools.Rc)
    Write-Host "[launcher][cmake][info] forcing SDK tools mt=$($sdkTools.Mt) rc=$($sdkTools.Rc)"
  }

  $vcvarsCommand = ('call "{0}" {1} "-vcvars_ver={2}"' -f $resolvedVcvars, $Arch, $VcvarsVersion)
  Invoke-CmdSteps @(
    $vcvarsCommand,
    'if errorlevel 1 exit /b %errorlevel%',
    (Get-OptionalLlvmPathStep -ConfigurePreset $ConfigurePreset),
    'set "CC="',
    'set "CXX="',
    $configureCommand
  )
}

function Build-Presets {
  $allPresets = @(
    @{ Name = "windows-ninja-msvc";         Config = "Debug";   Arch = "x64" },
    @{ Name = "windows-ninja-msvc";         Config = "Release"; Arch = "x64" },
    @{ Name = "windows-ninja-msvc";         Config = "Debug";   Arch = "x86" },
    @{ Name = "windows-ninja-msvc";         Config = "Release"; Arch = "x86" },
    @{ Name = "windows-ninja-msvc-arm64";   Config = "Debug";   Arch = "arm64" },
    @{ Name = "windows-ninja-msvc-arm64";   Config = "Release"; Arch = "arm64" }
  )

  $resolvedVcvars = $Vcvars
  if ([string]::IsNullOrWhiteSpace($resolvedVcvars)) { $resolvedVcvars = Detect-Vcvarsall }
  if ([string]::IsNullOrWhiteSpace($resolvedVcvars)) { throw "vcvarsall.bat not found" }

  # Validate that the selected MSVC toolset has all required headers
  Validate-MsvcToolsetHeaders -VcvarsVersion $VcvarsVersion

  $canonicalSourceRoot = $CanonicalRoot
  if ([string]::IsNullOrWhiteSpace($canonicalSourceRoot)) {
    $canonicalSourceRoot = Resolve-AbsoluteWindowsPath $Root
  }
  $rootPath = if ([string]::IsNullOrWhiteSpace($Root)) { pwd } else { (Resolve-Path -LiteralPath $Root).Path }
  Set-Location -LiteralPath $rootPath

  $pixiNinjaPath = Get-PixiNinjaPath -ProjectRoot $rootPath

  foreach ($preset in $allPresets) {
    $configurePreset = $preset.Name
    $buildPreset = "$($preset.Name)-$($preset.Config.ToLower())"
    $presetArch = $preset.Arch

    $vcvarsCommand = ('call "{0}" {1} -vcvars_ver={2}' -f $resolvedVcvars, $presetArch, $VcvarsVersion)
    $configureCommand = "cmake --preset $configurePreset"
    $configureCommand += " " + (Format-CMakeCacheArgument -Name "CMAKE_MAKE_PROGRAM:FILEPATH" -Value $pixiNinjaPath)
    foreach ($additionalArgument in (Get-AdditionalCMakeCacheArguments -CanonicalSourceRoot $canonicalSourceRoot)) { $configureCommand += " " + $additionalArgument }
    $sdkTools = Get-WindowsSdkToolPaths
    if ($sdkTools) {
      $configureCommand += " " + (Format-CMakeCacheArgument -Name "CMAKE_MT" -Value $sdkTools.Mt)
      $configureCommand += " " + (Format-CMakeCacheArgument -Name "CMAKE_RC_COMPILER" -Value $sdkTools.Rc)
      Write-Host "[launcher][cmake][info] forcing SDK tools mt=$($sdkTools.Mt) rc=$($sdkTools.Rc)"
    }

    Write-Host "=== Configuring $configurePreset ($presetArch) ===" -ForegroundColor Cyan
    Invoke-CmdSteps @(
      $vcvarsCommand,
      'if errorlevel 1 exit /b %errorlevel%',
      'set "CC="',
      'set "CXX="',
      $configureCommand
    )

    Write-Host "=== Building $buildPreset ===" -ForegroundColor Green
    Invoke-CmdSteps @(
      $vcvarsCommand,
      'if errorlevel 1 exit /b %errorlevel%',
      'set "CC="',
      'set "CXX="',
      "cmake --build --preset $buildPreset"
    )
  }
}

function Kano-TestPath {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
  return [System.IO.File]::Exists($Path) -or [System.IO.Directory]::Exists($Path)
}

function Validate-MsvcToolsetHeaders {
  param([string]$VcvarsVersion)

  # Detect Visual Studio root from vcvarsall location
  $resolvedVcvars = $Vcvars
  if ([string]::IsNullOrWhiteSpace($resolvedVcvars)) {
    $resolvedVcvars = Detect-Vcvarsall
  }
  if ([string]::IsNullOrWhiteSpace($resolvedVcvars)) {
    throw "vcvarsall.bat not found; cannot validate toolset headers"
  }

  # Extract Visual Studio root from vcvarsall path
  # e.g., C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat
  # Walk up 3 levels: Build → Auxiliary → VC (now at VC)
  # Then walk up 1 more: VC → Community (now at installation root like Community/Professional/Enterprise)
  $vsRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $resolvedVcvars)))

  # Construct toolset include directory path
  # e.g., C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\14.44.35207\include
  $toolsetInclude = Join-Path $vsRoot "VC\Tools\MSVC\$VcvarsVersion\include"

  # Required header files for a native C++ build
  $requiredHeaders = @("string", "filesystem", "chrono", "vcruntime.h")
  $missingHeaders = @()

  foreach ($header in $requiredHeaders) {
    $headerPath = Join-Path $toolsetInclude $header
    if (-not (Test-Path -LiteralPath $headerPath)) {
      $missingHeaders += $header
    }
  }

  if ($missingHeaders.Count -gt 0) {
    $missingList = [string]::Join(", ", $missingHeaders)
    throw "Selected MSVC toolset ($VcvarsVersion) is incomplete. Missing core headers: $missingList. " + `
          "Expected location: $toolsetInclude. Please repair or reinstall the matching Visual Studio toolset, " + `
          "or override with -VcvarsVersion or KANO_VCVARS_VERSION to use a different toolset."
  }
}

switch ($Action) {
  "probe" {
    Write-Output "ok"
  }
  "bounded-build-path" {
    Write-Output (Get-BoundedBuildPath -OriginalPath $Path)
  }
  "cmake-cache-arguments" {
    Get-AdditionalCMakeCacheArguments -CanonicalSourceRoot $CanonicalRoot
  }
  "cmake-build-command" {
    Get-CMakeBuildCommand -InBuildPreset $BuildPreset -InBuildTarget $BuildTarget
  }
  "prepare-subst-root" {
    Prepare-SubstRoot -InRoot $Root -InPreset $ConfigurePreset -InPreferredDrive $PreferredDrive -InMode $Mode
  }
  "cleanup-subst" {
    Remove-SubstDrive -InDrive $Drive
  }
  "detect-vcvarsall" {
    $found = Detect-Vcvarsall
    if ($found) { Write-Output $found }
  }
  "detect-vsdevcmd" {
    $found = Detect-VsDevCmd
    if ($found) { Write-Output $found }
  }
  "test-path" {
    if ([string]::IsNullOrWhiteSpace($Path)) { exit 1 }
    $exists = Kano-TestPath -LiteralPath $Path
    if ($exists) { exit 0 } else { exit 1 }
  }
  "run-preset" {
    Run-Preset
  }
  "configure-preset" {
    Configure-Preset
  }
  "build-presets" {
    Build-Presets
  }
  default {
    throw "Unknown action: $Action"
  }
}
