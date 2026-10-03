$script:KanoInfraNativeToolLib = $PSScriptRoot

function Resolve-KanoCppInfraTool {
    param([Parameter(Mandatory = $true)][string]$CppRoot)
    if ($env:KANO_CPP_INFRA_TOOL) {
        if (Test-Path -LiteralPath $env:KANO_CPP_INFRA_TOOL -PathType Leaf) {
            return $env:KANO_CPP_INFRA_TOOL
        }
        throw 'KANO_CPP_INFRA_TOOL is set but does not identify a file.'
    }
    $patterns = @(
        (Join-Path $CppRoot 'out/bin/*/release/kano-cpp-infra-tool.exe'),
        (Join-Path $CppRoot 'out/bin/*/debug/kano-cpp-infra-tool.exe'),
        (Join-Path $CppRoot 'out/bin/*/kano-cpp-infra-tool.exe')
    )
    foreach ($pattern in $patterns) {
        $candidate = Get-ChildItem -Path $pattern -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($candidate) { return $candidate.FullName }
    }
    return $null
}

function New-KanoCppInfraUnattendedTemp {
    param([Parameter(Mandatory = $true)][string]$CppRoot)
    if ($env:KANO_UNATTENDED_TEMP_DIR) {
        if (-not (Test-Path -LiteralPath $env:KANO_UNATTENDED_TEMP_DIR -PathType Container)) {
            throw 'Inherited unattended temp directory is unavailable.'
        }
        return [System.IO.Path]::GetFullPath($env:KANO_UNATTENDED_TEMP_DIR)
    }
    $tempRoot = if ($env:KANO_UNATTENDED_TEMP_ROOT) { $env:KANO_UNATTENDED_TEMP_ROOT } else { Join-Path $CppRoot 'out/tmp/unattended' }
    $tempRoot = [System.IO.Path]::GetFullPath($tempRoot)
    $runDirectory = Join-Path $tempRoot ('job-' + [Guid]::NewGuid().ToString('N'))
    [System.IO.Directory]::CreateDirectory($runDirectory) | Out-Null
    return $runDirectory
}

# Script mode re-enters the complete caller under one deadline and exits the
# original process. Executable mode returns its exit code for Invoke-Checked.
function Invoke-KanoCppInfraWatchdog {
    [CmdletBinding(DefaultParameterSetName = 'Script')]
    param(
        [Parameter(Mandatory = $true)][string]$CppRoot,
        [Parameter(Mandatory = $true, ParameterSetName = 'Script')][string]$ScriptPath,
        [Parameter(Mandatory = $true, ParameterSetName = 'Executable')][string]$Executable,
        [string[]]$Arguments = @(),
        [int]$TimeoutMs = 0,
        [int]$CleanupTimeoutMs = 0
    )
    if ($env:KANO_UNATTENDED -match '^(0|false|no|off)$') {
        if ($PSCmdlet.ParameterSetName -eq 'Script') { return }
        & $Executable @Arguments | Out-Host
        return $LASTEXITCODE
    }
    if ($PSCmdlet.ParameterSetName -eq 'Script' -and $env:KANO_UNATTENDED_WATCHDOG_ACTIVE -eq '1') { return }
    if ($TimeoutMs -eq 0) {
        $TimeoutMs = if ($env:KANO_UNATTENDED_TIMEOUT_MS) { [int]$env:KANO_UNATTENDED_TIMEOUT_MS } else { 900000 }
    }
    if ($CleanupTimeoutMs -eq 0) {
        $CleanupTimeoutMs = if ($env:KANO_UNATTENDED_CLEANUP_TIMEOUT_MS) { [int]$env:KANO_UNATTENDED_CLEANUP_TIMEOUT_MS } else { 5000 }
    }
    if ($TimeoutMs -le 0 -or $CleanupTimeoutMs -le 0) { throw 'Unattended deadlines must be positive milliseconds.' }
    if ($PSCmdlet.ParameterSetName -eq 'Script') {
        $Executable = (Get-Process -Id $PID).Path
        $Arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + $Arguments
    }
    $tool = Resolve-KanoCppInfraTool -CppRoot $CppRoot
    $hasNativeWatchdog = $false
    if ($tool -and (Test-Path -LiteralPath "$tool.unattended-v1" -PathType Leaf)) {
        $expectedHash = (Get-Content -LiteralPath "$tool.unattended-v1" -Raw).Trim()
        $actualHash = (Get-FileHash -LiteralPath $tool -Algorithm SHA256).Hash
        $hasNativeWatchdog = $expectedHash -match '^[a-fA-F0-9]{64}$' -and $expectedHash -eq $actualHash
    }
    $watchdogArguments = @('--timeout-ms', [string]$TimeoutMs, '--cleanup-timeout-ms', [string]$CleanupTimeoutMs, '--', $Executable) + $Arguments
    $previousEnvironment = @{}
    foreach ($name in @('KANO_UNATTENDED', 'KANO_UNATTENDED_WATCHDOG_ACTIVE', 'KANO_UNATTENDED_TEMP_DIR', 'TEMP', 'TMP', 'TMPDIR')) {
        $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
    try {
        $runDirectory = New-KanoCppInfraUnattendedTemp -CppRoot $CppRoot
        $env:TEMP = $runDirectory
        $env:TMP = $runDirectory
        $env:TMPDIR = $runDirectory
        $env:KANO_UNATTENDED_TEMP_DIR = $runDirectory
        $env:KANO_UNATTENDED = '1'
        $env:KANO_UNATTENDED_WATCHDOG_ACTIVE = '1'
        if ($hasNativeWatchdog) {
            & $tool watchdog @watchdogArguments | Out-Host
        } else {
            # Existing interpreter only: tool bootstrap never installs packages.
            $python = @('python3', 'python') | ForEach-Object {
                Get-Command $_ -CommandType Application -ErrorAction SilentlyContinue
            } | Where-Object { $_.Source -notmatch '[\\/]WindowsApps[\\/]' } | Select-Object -First 1
            if (-not $python) {
                throw 'A strict native watchdog and an existing Python 3 bootstrap interpreter are both unavailable. Set KANO_CPP_INFRA_TOOL to a built watchdog.'
            }
            & $python.Source (Join-Path $script:KanoInfraNativeToolLib 'watchdog-bootstrap.py') @watchdogArguments | Out-Host
        }
        $code = $LASTEXITCODE
    } finally {
        foreach ($name in $previousEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process')
        }
    }
    $global:LASTEXITCODE = $code
    if ($PSCmdlet.ParameterSetName -eq 'Script') { exit $code }
    return $code
}
