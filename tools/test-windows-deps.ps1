[CmdletBinding()]
param(
    [string]$Chez = $env:JOLT_CHEZ,
    [string]$GitSh = $env:JOLT_SH,
    [string]$TempBase = [IO.Path]::GetTempPath(),
    [int]$TimeoutSeconds = 600,
    [switch]$KeepTemp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-Executable {
    param(
        [string]$Requested,
        [string[]]$FallbackNames,
        [string]$Description
    )

    if ($Requested) {
        $requestedCommand = Get-Command $Requested -ErrorAction SilentlyContinue
        if ($requestedCommand) {
            return $requestedCommand.Source
        }
        if (Test-Path -LiteralPath $Requested -PathType Leaf) {
            return (Resolve-Path -LiteralPath $Requested).Path
        }
        throw "$Description does not name an executable: $Requested"
    }

    foreach ($name in $FallbackNames) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command) {
            return $command.Source
        }
    }
    throw "Could not find $Description. Pass its path explicitly."
}

function Resolve-GitSh {
    param([string]$Requested)

    if ($Requested) {
        return Resolve-Executable $Requested @() "Git for Windows sh"
    }

    $git = Resolve-Executable "" @("git.exe", "git") "Git"
    $gitRoot = Split-Path -Parent (Split-Path -Parent $git)
    foreach ($candidate in @(
        (Join-Path $gitRoot "bin\sh.exe"),
        (Join-Path $gitRoot "usr\bin\sh.exe")
    )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    throw "Could not find Git for Windows sh beside $git. Pass -GitSh."
}

function Convert-ToMsysPath {
    param([string]$Path)

    $full = [IO.Path]::GetFullPath($Path)
    if ($full -notmatch "^([A-Za-z]):[\\/](.*)$") {
        throw "The dependency child launcher needs a drive-letter path, got: $full"
    }
    return "/" + $Matches[1].ToLowerInvariant() + "/" +
        $Matches[2].Replace("\", "/")
}

function Quote-Posix {
    param([string]$Value)

    $quote = [string][char]39
    return $quote + $Value.Replace($quote, $quote + "\" + $quote + $quote) +
        $quote
}

if ($TimeoutSeconds -le 0) {
    throw "-TimeoutSeconds must be positive"
}

$repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$chezPath = Resolve-Executable $Chez @("scheme.exe", "chez.exe", "chezscheme.exe") "Chez Scheme"
$gitShPath = Resolve-GitSh $GitSh
$tempParent = [IO.Path]::GetFullPath($TempBase)
$testRoot = Join-Path $tempParent ("jolt-deps-test." + [guid]::NewGuid().ToString("N").Substring(0, 12))
$cacheRoot = Join-Path $testRoot "jolt-cache"

# The formal Windows path budget is intentionally bounded at an 80-character
# cache root. Refuse to turn a runner-path accident into a misleading product
# failure.
if ($cacheRoot.Length -gt 80) {
    throw "Generated JOLT_GITLIBS path is $($cacheRoot.Length) characters; use -TempBase with a shorter path (maximum cache root length is 80)."
}

$environmentNames = @(
    "GIT_ALLOW_PROTOCOL",
    "GIT_CONFIG_NOSYSTEM",
    "GIT_CONFIG_GLOBAL",
    "GITLIBS",
    "JOLT_AOT_CACHE",
    "JOLT_CHEZ",
    "JOLT_DEPSTEST_JOLTC",
    "JOLT_GITLIBS",
    "JOLT_PWD",
    "JOLT_SH",
    "JOLT_VERSION"
)
$savedEnvironment = @{}
foreach ($name in $environmentNames) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
}

New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    $cliPath = Join-Path $repo "host\chez\cli.ss"
    $env:GIT_ALLOW_PROTOCOL = "file"
    $env:GIT_CONFIG_NOSYSTEM = "1"
    $env:GIT_CONFIG_GLOBAL = Join-Path $testRoot "gitconfig"
    $env:GITLIBS = Join-Path $testRoot "tools-gitlibs"
    $env:JOLT_AOT_CACHE = "0"
    $env:JOLT_CHEZ = $chezPath
    $env:JOLT_DEPSTEST_JOLTC =
        (Quote-Posix (Convert-ToMsysPath $chezPath)) + " --script " +
        (Quote-Posix (Convert-ToMsysPath $cliPath))
    $env:JOLT_GITLIBS = $cacheRoot
    $env:JOLT_PWD = $repo
    $env:JOLT_SH = $gitShPath
    $env:JOLT_VERSION = "dev"

    Write-Host "Repository: $repo"
    Write-Host "Chez:       $chezPath"
    Write-Host "Git sh:     $gitShPath"
    Write-Host "Test root:  $testRoot"
    Write-Host "Cache root: $cacheRoot ($($cacheRoot.Length) characters)"

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $chezPath
    $startInfo.WorkingDirectory = $repo
    $startInfo.UseShellExecute = $false
    $quotedRoot = $testRoot.Replace('"', '\"')
    $startInfo.Arguments =
        '--script "host\chez\cli.ss" run "test\deps_test.clj" "' +
        $quotedRoot + '"'

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw "Failed to start Chez Scheme"
    }
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        $process.Kill()
        throw "Dependency suite exceeded the $TimeoutSeconds-second watchdog"
    }
    if ($process.ExitCode -ne 0) {
        throw "Dependency suite exited with code $($process.ExitCode)"
    }

    Write-Host "OK: native Windows dependency suite passed"
}
finally {
    foreach ($name in $environmentNames) {
        $value = $savedEnvironment[$name]
        if ($null -eq $value) {
            Remove-Item -Path ("Env:{0}" -f $name) -ErrorAction SilentlyContinue
        }
        else {
            Set-Item -Path ("Env:{0}" -f $name) -Value $value
        }
    }

    if ($KeepTemp) {
        Write-Host "Kept test root: $testRoot"
    }
    elseif (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
