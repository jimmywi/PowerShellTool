<#
.SYNOPSIS
    Uninstalls matching applications by name, product code, or custom filter.

.DESCRIPTION
    Can be used as an Intune Remediations remediation script, an SCCM/ConfigMgr
    deployment script, or run locally. Configure the application criteria in
    the Uninstall-Application call at the end of this script.

    The script searches the standard per-machine and current-user uninstall
    registry locations, preferring QuietUninstallString for EXE applications.
    MSI applications are removed through msiexec.exe.
#>

function Uninstall-Application {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [string[]]$Name,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Contains', 'Exact', 'Wildcard', 'Regex')]
        [string]$NameMatch = 'Contains',

        [Parameter(Mandatory = $false)]
        [guid[]]$ProductCode,

        [Parameter(Mandatory = $false)]
        [ValidateSet('All', 'MSI', 'EXE')]
        [string]$ApplicationType = 'All',

        [Parameter(Mandatory = $false)]
        [switch]$IncludeUpdatesAndHotfixes,

        [Parameter(Mandatory = $false, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [scriptblock]$FilterScript,

        [Parameter(Mandatory = $false)]
        [string[]]$ArgumentList,

        [Parameter(Mandatory = $false)]
        [string[]]$AdditionalArgumentList,

        [Parameter(Mandatory = $false)]
        [int[]]$SuccessExitCodes = @(0, 1641, 3010),

        [Parameter(Mandatory = $false)]
        [string[]]$IgnoreExitCodes,

        [Parameter(Mandatory = $false)]
        [switch]$PassThru,

        [Parameter(Mandatory = $false)]
        [string]$LogFilePath
    )

    if ($null -eq $Name) { $Name = @() }
    $nameFilterEnabled = $Name.Count -gt 0

    if ([string]::IsNullOrWhiteSpace($LogFilePath)) {
        $LogFilePath = Join-Path $env:SystemRoot 'Temp\Uninstall-Application.log'
    }

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

function Write-Log {
    param ([Parameter(Mandatory)][string]$Message)

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $PID, $Message
    try {
        $logDirectory = Split-Path -Path $LogFilePath -Parent
        if (-not (Test-Path -LiteralPath $logDirectory)) {
            New-Item -Path $logDirectory -ItemType Directory -Force | Out-Null
        }
        Add-Content -LiteralPath $LogFilePath -Value $line -Encoding UTF8
    }
    catch {
        Write-Verbose $line
    }
}

function Test-ApplicationName {
    param ([Parameter(Mandatory)][string]$DisplayName)

    switch ($NameMatch) {
        'Contains' { return @($Name | Where-Object { $DisplayName.IndexOf($_, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count -gt 0 }
        'Exact'    { return @($Name | Where-Object { $DisplayName.Equals($_, [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0 }
        'Wildcard' { return @($Name | Where-Object { $DisplayName -like $_ }).Count -gt 0 }
        'Regex'    { return @($Name | Where-Object { $DisplayName -match $_ }).Count -gt 0 }
        default    { throw "Unsupported NameMatch value: $NameMatch" }
    }
}

function Get-UninstallApplications {
    $uninstallSubKey = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    $views = @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)
    $hives = @([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryHive]::CurrentUser)

    $applications = foreach ($hive in $hives) {
        foreach ($view in $views) {
            $baseKey = $null
            $uninstallKey = $null
            try {
                # OpenBaseKey avoids the 32-bit/64-bit PowerShell registry redirect.
                $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, $view)
                $uninstallKey = $baseKey.OpenSubKey($uninstallSubKey)
                if ($null -eq $uninstallKey) { continue }

                foreach ($subKeyName in $uninstallKey.GetSubKeyNames()) {
                    $subKey = $null
                    try {
                        $subKey = $uninstallKey.OpenSubKey($subKeyName)
                        if ($null -eq $subKey) { continue }

                        $displayName = $subKey.GetValue('DisplayName')
                        if ($null -eq $displayName -or [string]::IsNullOrWhiteSpace([string]$displayName)) { continue }
                        $releaseType = $subKey.GetValue('ReleaseType')
                        if ($subKey.GetValue('SystemComponent') -eq 1 -or $releaseType -in @('Security Update', 'Update', 'Hotfix')) {
                            if (-not $IncludeUpdatesAndHotfixes) { continue }
                        }
                        if ($nameFilterEnabled -and -not (Test-ApplicationName -DisplayName ([string]$displayName))) { continue }
                        $publisherValue = $subKey.GetValue('Publisher')
                        # EXE installers can also register under a GUID-shaped key (for example, Tailscale).
                        $isMsi = ($subKey.GetValue('WindowsInstaller') -eq 1) -or
                            (($subKeyName -match '^\{[0-9A-Fa-f-]{36}\}$') -and
                             ([string]$subKey.GetValue('UninstallString') -match '\bmsiexec(?:\.exe)?\b'))
                        $type = if ($isMsi) { 'MSI' } else { 'EXE' }
                        if ($ApplicationType -ne 'All' -and $ApplicationType -ne $type) { continue }
                        if ($ProductCode -and (!$isMsi -or $ProductCode -notcontains ([guid]$subKeyName))) { continue }

                        $application = [pscustomobject]@{
                            DisplayName = [string]$displayName
                            DisplayVersion = [string]$subKey.GetValue('DisplayVersion')
                            Publisher = [string]$publisherValue
                            ProductCode = if ($isMsi) { [string]$subKeyName } else { '' }
                            Type = $type
                            QuietUninstallString = [string]$subKey.GetValue('QuietUninstallString')
                            UninstallString = [string]$subKey.GetValue('UninstallString')
                        }

                        if (-not $FilterScript -or ($application | ForEach-Object -Process $FilterScript -ErrorAction Ignore)) {
                            $application
                        }
                    }
                    finally {
                        if ($subKey) { $subKey.Dispose() }
                    }
                }
            }
            catch {
                Write-Log "Unable to read uninstall registry view [$hive/$view]: $($_.Exception.Message)"
            }
            finally {
                if ($uninstallKey) { $uninstallKey.Dispose() }
                if ($baseKey) { $baseKey.Dispose() }
            }
        }
    }

    # The same MSI can be visible through both registry views.
    $applications | Group-Object { if ($_.Type -eq 'MSI') { $_.ProductCode } else { "$($_.DisplayName)|$($_.DisplayVersion)|$($_.UninstallString)" } } | ForEach-Object { $_.Group[0] }
}

function Split-UninstallCommand {
    param ([Parameter(Mandatory)][string]$CommandLine)

    $commandLine = [Environment]::ExpandEnvironmentVariables($CommandLine.Trim())
    if ($commandLine -match '^\s*"(?<path>[^"]+)"\s*(?<args>.*)$') {
        return [pscustomobject]@{ FilePath = $Matches.path; Arguments = $Matches.args.Trim() }
    }
    if ($commandLine -match '^\s*(?<path>.+?\.exe)\s*(?<args>.*)$') {
        return [pscustomobject]@{ FilePath = $Matches.path; Arguments = $Matches.args.Trim() }
    }
    throw "Unable to parse uninstall command: $CommandLine"
}

function Invoke-Uninstall {
    param ([Parameter(Mandatory)]$Application)

    if ($Application.Type -eq 'MSI') {
        $filePath = Join-Path $env:SystemRoot 'System32\msiexec.exe'
        $msiArguments = if ($null -ne $ArgumentList) { $ArgumentList } else { @('/qn', '/norestart') }
        $arguments = @("/x $($Application.ProductCode)", ($msiArguments -join ' '), ($AdditionalArgumentList -join ' ')) -join ' '
    }
    else {
        $command = if ($Application.QuietUninstallString) { $Application.QuietUninstallString } else { $Application.UninstallString }
        if (-not $command) {
            Write-Log "Skipping '$($Application.DisplayName)': no uninstall string found."
            return $true
        }
        $parsed = Split-UninstallCommand -CommandLine $command
        $filePath = $parsed.FilePath
        $baseArguments = if ($null -ne $ArgumentList) { $ArgumentList -join ' ' } else { $parsed.Arguments }
        $arguments = @($baseArguments, ($AdditionalArgumentList -join ' ')) -join ' '
        if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
            $commandInfo = Get-Command -Name $filePath -ErrorAction SilentlyContinue
            if ($commandInfo) { $filePath = $commandInfo.Source }
        }
    }

    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        throw "Uninstaller was not found: $filePath"
    }

    Write-Log "Uninstalling '$($Application.DisplayName) $($Application.DisplayVersion)' using $filePath $arguments"
    $process = Start-Process -FilePath $filePath -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
    Write-Log "Exit code: $($process.ExitCode)"
    $ignored = $IgnoreExitCodes -contains '*' -or $IgnoreExitCodes -contains ([string]$process.ExitCode)
    if (-not $ignored -and $process.ExitCode -notin $SuccessExitCodes) {
        throw "Uninstaller returned exit code $($process.ExitCode)."
    }
    if ($PassThru) {
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            FilePath = $filePath
            DisplayName = $Application.DisplayName
        }
    }
    return $true
}

    try {
        if (-not $nameFilterEnabled -and -not $ProductCode -and -not $FilterScript) {
            throw 'Specify -Name, -ProductCode, or -FilterScript.'
        }

        Write-Log "Searching for applications matching '$($Name -join ', ')' ($NameMatch)."
        $matchedApplications = @(Get-UninstallApplications)
        if ($matchedApplications.Count -eq 0) {
            Write-Log 'No matching applications found.'
            return
        }

        $failed = $false
        foreach ($application in $matchedApplications) {
            try {
                $result = Invoke-Uninstall -Application $application
                if ($PassThru) { $result }
            }
            catch {
                $failed = $true
                Write-Log "ERROR: $($_.Exception.Message)"
            }
        }

        if ($failed) { throw 'One or more applications failed to uninstall.' }
    }
    catch {
        Write-Log "FATAL: $($_.Exception.Message)"
        throw
    }
}

# Configure the remediation criteria here, for example:
# Uninstall-Application -Name 'Application Name'
# Uninstall-Application -Name 'VLC' -FilterScript { $_.Publisher -like '*VIDEO*' }'
<#
$uninstallParameters = @{
    Name = @('VLC')
    FilterScript = { $_.Publisher -like '*VIDEO*' }
}
Uninstall-Application @uninstallParameters
#>