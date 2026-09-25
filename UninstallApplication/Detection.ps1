function Get-Application {
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
        [scriptblock]$FilterScript
    )

    Set-StrictMode -Version Latest

    if ($null -eq $Name) { $Name = @() }
    $nameFilterEnabled = $Name.Count -gt 0
    $uninstallSubKey = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    $views = @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)
    $hives = @([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryHive]::CurrentUser)

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
                        $isMsi = ($subKey.GetValue('WindowsInstaller') -eq 1) -or ($subKeyName -match '^[{][0-9A-Fa-f-]{36}[}]$')
                        $type = if ($isMsi) { 'MSI' } else { 'EXE' }
                        if ($ApplicationType -ne 'All' -and $ApplicationType -ne $type) { continue }

                        $applicationProductCode = if ($isMsi -and $subKeyName -match '^[{][0-9A-Fa-f-]{36}[}]$') {
                            [guid]$subKeyName
                        }
                        else {
                            $null
                        }
                        if ($ProductCode -and ($null -eq $applicationProductCode -or $ProductCode -notcontains $applicationProductCode)) { continue }

                        $application = [pscustomobject]@{
                            DisplayName           = [string]$displayName
                            DisplayVersion        = [string]$subKey.GetValue('DisplayVersion')
                            Publisher             = [string]$publisherValue
                            ProductCode           = if ($null -ne $applicationProductCode) { [string]$applicationProductCode } else { '' }
                            Type                  = $type
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
                Write-Verbose "Unable to read uninstall registry view [$hive/$view]: $($_.Exception.Message)"
            }
            finally {
                if ($uninstallKey) { $uninstallKey.Dispose() }
                if ($baseKey) { $baseKey.Dispose() }
            }
        }
    }

    # The same MSI can be visible through both registry views.
    $applications |
        Group-Object {
            if ($_.Type -eq 'MSI') {
                $_.ProductCode
            }
            else {
                "$($_.DisplayName)|$($_.DisplayVersion)|$($_.Publisher)"
            }
        } |
        ForEach-Object { $_.Group[0] }
}

# Configure the application criteria for the remediation detection here.
<#
$detectionParameters = @{
    Name = @('VLC')
    FilterScript = { $_.Publisher -like '*VIDEO*' }
}

$matchedApplications = @(Get-Application @detectionParameters)
if ($matchedApplications.Count -gt 0) {
    Write-Output "Found Application"
    $matchedApplications | ForEach-Object { Write-Output " - $($_.DisplayName) $($_.DisplayVersion) by $($_.Publisher)" }
    exit 1
}

exit 0
#>