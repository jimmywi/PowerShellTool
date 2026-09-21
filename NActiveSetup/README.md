# NActiveSetup

Standalone Active Setup helper for native PowerShell.

## Script

`Set-NativeActiveSetup.ps1`

## Flow

```text
Start
  |
  v
Validate StubExePath and extension
  |
  v
Build registry path and stub command
  |
  v
Read existing HKLM Version
  |
  v
Generate higher Version if omitted
  |
  v
Write HKLM Active Setup entry
  |
  v
Disable or NoExecute?
  | yes
  v
Stop
  |
 no
  v
Running as SYSTEM?
  | yes                       | no
  v                          v
Get active console user      Start stub as current user
via Win32 token APIs         and write HKCU entry
  |
  v
Launch stub in user session
  |
  v
Write HKCU Active Setup entry
```

## File type handling

```text
.exe  -> run directly
.vbs  -> wscript.exe //nologo
.js   -> wscript.exe //nologo
.cmd  -> cmd.exe /c
.bat  -> cmd.exe /c
.ps1  -> powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File
```

## Example

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Set-NativeActiveSetup.ps1 `
  -StubExePath 'C:\Path\To\Fixup.ps1' `
  -Key 'MyAppFixup' `
  -Description 'My App Fixup' `
  -Arguments '-Mode Repair'
```

## Notes

- Same `-Key` is reused every time.
- `Version` auto-increases when omitted.
- If run as `SYSTEM` and a console user is logged on, the stub is launched in that user session.
- `-NoExecuteForCurrentUser` only writes the HKLM entry.
