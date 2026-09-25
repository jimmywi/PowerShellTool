# Application detection and removal

`Detection.ps1` defines `Get-Application`, which finds entries in the Windows uninstall registry. `Remediate.ps1` defines `Uninstall-Application`, which removes matching entries using the registered uninstaller. Both search machine and current-user entries in 32-bit and 64-bit registry views.

**As supplied, the calls at the bottom of both scripts are commented out.** Running a file by itself only defines its function; it does not detect or uninstall anything. This is useful when calling the functions yourself. To deploy either script in Intune, enable an entry point as shown below.

## Run the functions locally

In a PowerShell session, from the directory containing the scripts:

```powershell
. .\Detection.ps1
Get-Application -Name 'Winamp' -FilterScript { $_.Publisher -like '*Winamp*' }
Get-Command Get-Application -Syntax  # Show available parameters

. .\Remediate.ps1
Uninstall-Application -Name 'Winamp' -FilterScript { $_.Publisher -like '*Winamp*' } -AdditionalArgumentList '/S'
```

The leading `. ` **dot-sources** each file to load its function into the current session. `Get-Application` returns matching objects; no output means no match. `Uninstall-Application` actually runs the uninstaller, so check its criteria before calling it. The `/S` above is a Winamp-specific example, not a general EXE uninstall argument.

From **Command Prompt (`cmd.exe`)**, you can run the same functions in a new PowerShell process:

```bat
powershell.exe -NoProfile -Command ". .\Detection.ps1; Get-Application -Name 'Winamp' -FilterScript { $_.Publisher -like '*Winamp*' }"
powershell.exe -NoProfile -Command ". .\Remediate.ps1; Uninstall-Application -Name 'Winamp' -FilterScript { $_.Publisher -like '*Winamp*' } -AdditionalArgumentList '/S'"
```

Replace the example name and publisher with your target. To select only a particular version, add a version check to the filter in **both** scripts; for example, when calling the detection function:

```powershell
Get-Application -Name 'Tailscale' -FilterScript { $_.Publisher -like '*Tailscale*' -and $_.DisplayVersion -eq '1.98.8' }
```

Both functions support `-Name`, `-NameMatch` (`Contains`, `Exact`, `Wildcard`, `Regex`), `-ProductCode` (MSI GUID), `-ApplicationType` (`All`, `MSI`, `EXE`), `-IncludeUpdatesAndHotfixes`, and `-FilterScript`. Filter objects expose `DisplayName`, `DisplayVersion`, `Publisher`, `ProductCode`, and `Type`. `Uninstall-Application` also accepts `-ArgumentList` (replaces registered arguments), `-AdditionalArgumentList` (appends arguments), `-SuccessExitCodes`, `-IgnoreExitCodes`, `-PassThru`, and `-LogFilePath`.

Uninstall results are logged to `%SystemRoot%\Temp\Uninstall-Application.log` by default. Run with the permissions needed to remove the app. Under the system account, `CurrentUser` means the system profile, not the signed-in user's profile.

## Intune Remediations

Intune Remediations runs the remediation script when its detection script exits `1`. To make these files run automatically, remove the `<#` and `#>` surrounding the entry point at the bottom of **each** file, and give them the **same target criteria**. For example:

At the bottom of `Detection.ps1`:

```powershell
$detectionParameters = @{
    Name = @('Tailscale')
    FilterScript = { $_.Publisher -like '*Tailscale*' -and $_.DisplayVersion -eq '1.98.8' }
}
$matchedApplications = @(Get-Application @detectionParameters)
if ($matchedApplications.Count -gt 0) { exit 1 }
exit 0
```

At the bottom of `Remediate.ps1`:

```powershell
$uninstallParameters = @{
    Name = @('Tailscale')
    FilterScript = { $_.Publisher -like '*Tailscale*' -and $_.DisplayVersion -eq '1.98.8' }
}
Uninstall-Application @uninstallParameters
```

Test from PowerShell before uploading:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Detection.ps1
$LASTEXITCODE  # 1 = found (run remediation); 0 = absent

powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Remediate.ps1
$LASTEXITCODE  # 0 = no match or removal succeeded; nonzero = error
```

In the Intune admin center, go to **Devices > Scripts and remediations > Remediations**, create a package, upload `Detection.ps1` as the detection script and `Remediate.ps1` as the remediation script, then select the execution context and assign a schedule. Use the system context for machine-wide installs or the logged-on user context for per-user installs. Once removed, the next detection should return `0`.

## Intune Win32 app (`.intunewin`)

To deploy removal as a **Required** Win32 app, enable the `Remediate.ps1` entry point as above. Win32 app detection has the **opposite success condition** from Remediations: it must exit `0` **and write output** when the target is **absent**.

1. Make a separate copy of `Detection.ps1` called `Win32-Detection.ps1`. In that copy, uncomment the entry point and use the same `$detectionParameters` as remediation. Replace its final match/exit block with:

   ```powershell
   $matchedApplications = @(Get-Application @detectionParameters)
   if ($matchedApplications.Count -gt 0) { exit 1 }
   Write-Output 'Target application is absent'
   exit 0
   ```

2. Place the configured `Remediate.ps1` in a source directory, such as `C:\Packages\Remove-App\Source`. Download Microsoft's **Win32 Content Prep Tool** (`IntuneWinAppUtil.exe`) and run it from PowerShell, writing the output outside the source directory:

   ```powershell
   .\IntuneWinAppUtil.exe -c "C:\Packages\Remove-App\Source" -s "Remediate.ps1" -o "C:\Packages\Remove-App\Output" -q
   ```

3. In Intune, create a **Windows app (Win32)** and upload the resulting `.intunewin` file. Set the install command to:

   ```text
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Remediate.ps1
   ```

   If an uninstall command is required, the same command is safe when there is no matching app. Set the install behavior to the appropriate system or user context.

4. Configure a **custom detection script** using `Win32-Detection.ps1` (uploaded as the Win32 app's detection rule, not as the Remediations script). Assign the Win32 app as **Required**. Intune runs the removal while the target is present and regards the app as installed when the target is gone.
