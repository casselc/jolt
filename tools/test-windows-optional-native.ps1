[CmdletBinding()]
param(
    [string]$Chez = $env:JOLT_CHEZ,
    [ValidateSet("x86-64", "aarch64")]
    [string]$ExpectedArch,
    [int]$TimeoutSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-Executable {
    param([string]$Requested)

    if ($Requested -and (Test-Path -LiteralPath $Requested -PathType Leaf)) {
        return (Resolve-Path -LiteralPath $Requested).Path
    }
    if ($Requested) {
        $requestedCommand = Get-Command $Requested -ErrorAction SilentlyContinue
        if ($requestedCommand) {
            return $requestedCommand.Source
        }
    }
    foreach ($name in @("scheme.exe", "chez.exe", "chezscheme.exe")) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command) {
            return $command.Source
        }
    }
    throw "Could not find Chez Scheme. Pass -Chez."
}

function Invoke-Jolt {
    param(
        [string]$Project,
        [string]$Arguments
    )

    $savedPwd = $env:JOLT_PWD
    try {
        $env:JOLT_PWD = $Project
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $script:ChezPath
        $startInfo.WorkingDirectory = $script:Repo
        $startInfo.Arguments = '--script "host\chez\cli.ss" ' + $Arguments
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true

        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        if (-not $process.Start()) {
            throw "Failed to start Chez Scheme"
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill()
            throw "Jolt child exceeded the $TimeoutSeconds-second watchdog"
        }
        $process.WaitForExit()
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
        if ($process.ExitCode -ne 0) {
            throw "Jolt child exited $($process.ExitCode):`n$stderr`n$stdout"
        }
        return $stdout.Trim()
    }
    finally {
        $env:JOLT_PWD = $savedPwd
    }
}

if ($TimeoutSeconds -le 0) {
    throw "-TimeoutSeconds must be positive"
}

$script:Repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$script:ChezPath = Resolve-Executable $Chez
$savedAot = $env:JOLT_AOT_CACHE
$savedChez = $env:JOLT_CHEZ
$savedVersion = $env:JOLT_VERSION
$emptyProject = Join-Path ([IO.Path]::GetTempPath()) ("jolt-optional-native-" + [guid]::NewGuid().ToString("N"))

New-Item -ItemType Directory -Path $emptyProject | Out-Null
try {
    $env:JOLT_AOT_CACHE = "0"
    $env:JOLT_CHEZ = $script:ChezPath
    $env:JOLT_VERSION = "dev"

    $archOutput = Invoke-Jolt $emptyProject '-e "(println (name (:arch (jolt.host/target))))"'
    $archLines = @($archOutput -split "\r?\n" | Where-Object { $_ })
    $observedArch = $archLines[-1]
    if ($ExpectedArch -and $observedArch -ne $ExpectedArch) {
        throw "Expected native architecture $ExpectedArch, observed $observedArch"
    }

    $unusedProject = Join-Path $script:Repo "test\chez\optional-lib-app"
    $unusedOutput = Invoke-Jolt $unusedProject "-m app.optional-lib"
    if ($unusedOutput -ne "optional lib app ran successfully") {
        throw "Missing optional library prevented startup: $unusedOutput"
    }

    $calledProject = Join-Path $script:Repo "test\chez\optional-lib-call-app"
    $calledOutput = Invoke-Jolt $calledProject "-m app.optional-lib-call"
    if ($calledOutput -notmatch "(?m)^caught expected error:") {
        throw "Missing optional symbol did not fail catchably at call time: $calledOutput"
    }
    if ($calledOutput -match "UNEXPECTED") {
        throw "Missing optional symbol unexpectedly resolved: $calledOutput"
    }

    Write-Host "optional-native Windows gate: 4/4 passed ($observedArch)"
}
finally {
    $env:JOLT_AOT_CACHE = $savedAot
    $env:JOLT_CHEZ = $savedChez
    $env:JOLT_VERSION = $savedVersion
    if (Test-Path -LiteralPath $emptyProject) {
        Remove-Item -LiteralPath $emptyProject -Recurse -Force
    }
}
