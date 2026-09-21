[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$StubExePath,

    [Parameter(Mandatory = $false)]
    [string]$Key,

    [Parameter(Mandatory = $false)]
    [string]$Description,

    [Parameter(Mandatory = $false)]
    [string]$Arguments = [System.Management.Automation.Language.NullString]::Value,

    [Parameter(Mandatory = $false)]
    [string]$Version,

    [Parameter(Mandatory = $false)]
    [string]$Locale = [System.Management.Automation.Language.NullString]::Value,

    [Parameter(Mandatory = $false)]
    [switch]$Wow6432Node,

    [Parameter(Mandatory = $false)]
    [switch]$NoExecuteForCurrentUser,

    [Parameter(Mandatory = $false)]
    [switch]$DisableActiveSetup,

    [Parameter(Mandatory = $false)]
    [ValidateSet('Bypass', 'Unrestricted', 'RemoteSigned', 'AllSigned', 'Restricted', 'Default', 'Undefined')]
    [string]$ExecutionPolicy = 'Bypass'
)

Set-StrictMode -Version 3

if (-not ('NativeActiveSetup' -as [type]))
{
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class NativeActiveSetup
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFO
    {
        public Int32 cb;
        public String lpReserved;
        public String lpDesktop;
        public String lpTitle;
        public Int32 dwX;
        public Int32 dwY;
        public Int32 dwXSize;
        public Int32 dwYSize;
        public Int32 dwXCountChars;
        public Int32 dwYCountChars;
        public Int32 dwFillAttribute;
        public Int32 dwFlags;
        public Int16 wShowWindow;
        public Int16 cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION
    {
        public IntPtr hProcess;
        public IntPtr hThread;
        public Int32 dwProcessId;
        public Int32 dwThreadId;
    }

    [DllImport("kernel32.dll")]
    private static extern UInt32 WTSGetActiveConsoleSessionId();

    [DllImport("wtsapi32.dll", SetLastError = true)]
    private static extern Boolean WTSQueryUserToken(UInt32 SessionId, out IntPtr Token);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern Boolean DuplicateTokenEx(
        IntPtr ExistingToken,
        UInt32 dwDesiredAccess,
        IntPtr lpTokenAttributes,
        Int32 ImpersonationLevel,
        Int32 TokenType,
        out IntPtr DuplicateToken
    );

    [DllImport("userenv.dll", SetLastError = true)]
    private static extern Boolean CreateEnvironmentBlock(out IntPtr lpEnvironment, IntPtr hToken, Boolean bInherit);

    [DllImport("userenv.dll", SetLastError = true)]
    private static extern Boolean DestroyEnvironmentBlock(IntPtr lpEnvironment);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern Boolean CreateProcessAsUser(
        IntPtr hToken,
        String lpApplicationName,
        StringBuilder lpCommandLine,
        IntPtr lpProcessAttributes,
        IntPtr lpThreadAttributes,
        Boolean bInheritHandles,
        Int32 dwCreationFlags,
        IntPtr lpEnvironment,
        String lpCurrentDirectory,
        ref STARTUPINFO lpStartupInfo,
        out PROCESS_INFORMATION lpProcessInformation
    );

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern Boolean CloseHandle(IntPtr hObject);

    public static Boolean TryStartProcessInActiveConsoleSession(String applicationName, String commandLine, String workingDirectory, out String userSid, out String userName)
    {
        userSid = null;
        userName = null;

        UInt32 sessionId = WTSGetActiveConsoleSessionId();
        if (sessionId == 0xFFFFFFFF)
        {
            return false;
        }

        IntPtr userToken = IntPtr.Zero;
        IntPtr primaryToken = IntPtr.Zero;
        IntPtr environment = IntPtr.Zero;
        PROCESS_INFORMATION processInfo = new PROCESS_INFORMATION();

        try
        {
            if (!WTSQueryUserToken(sessionId, out userToken))
            {
                return false;
            }

            using (System.Security.Principal.WindowsIdentity identity = new System.Security.Principal.WindowsIdentity(userToken))
            {
                if (identity.User != null)
                {
                    userSid = identity.User.Value;
                }
                userName = identity.Name;
            }

            const UInt32 TOKEN_ALL_ACCESS = 0x000F01FF;
            const Int32 SecurityImpersonation = 2;
            const Int32 TokenPrimary = 1;

            if (!DuplicateTokenEx(userToken, TOKEN_ALL_ACCESS, IntPtr.Zero, SecurityImpersonation, TokenPrimary, out primaryToken))
            {
                return false;
            }

            CreateEnvironmentBlock(out environment, primaryToken, false);

            STARTUPINFO startupInfo = new STARTUPINFO();
            startupInfo.cb = Marshal.SizeOf(typeof(STARTUPINFO));
            startupInfo.lpDesktop = "winsta0\\default";

            StringBuilder commandBuilder = new StringBuilder(commandLine);
            const Int32 CREATE_UNICODE_ENVIRONMENT = 0x00000400;
            const Int32 CREATE_NO_WINDOW = 0x08000000;

            Boolean created = CreateProcessAsUser(
                primaryToken,
                applicationName,
                commandBuilder,
                IntPtr.Zero,
                IntPtr.Zero,
                false,
                CREATE_UNICODE_ENVIRONMENT | CREATE_NO_WINDOW,
                environment,
                workingDirectory,
                ref startupInfo,
                out processInfo
            );

            if (!created)
            {
                return false;
            }

            return true;
        }
        finally
        {
            if (processInfo.hThread != IntPtr.Zero)
            {
                CloseHandle(processInfo.hThread);
            }
            if (processInfo.hProcess != IntPtr.Zero)
            {
                CloseHandle(processInfo.hProcess);
            }
            if (environment != IntPtr.Zero)
            {
                DestroyEnvironmentBlock(environment);
            }
            if (primaryToken != IntPtr.Zero)
            {
                CloseHandle(primaryToken);
            }
            if (userToken != IntPtr.Zero)
            {
                CloseHandle(userToken);
            }
        }
    }
}
'@
}

function Get-NativeActiveSetupRegistryRoot
{
    param([switch]$UseWow6432Node)

    if ($UseWow6432Node -and [System.Environment]::Is64BitOperatingSystem)
    {
        return 'SOFTWARE\Wow6432Node\Microsoft\Active Setup\Installed Components'
    }

    return 'SOFTWARE\Microsoft\Active Setup\Installed Components'
}

function Get-NativeActiveSetupCommand
{
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [string]$Args,

        [Parameter(Mandatory = $false)]
        [string]$PowerShellExecutionPolicy
    )

    $extension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    switch ($extension)
    {
        '.exe'
        {
            $filePath = $Path
            $arguments = $Args
            $stubPath = if ([string]::IsNullOrWhiteSpace($Args)) { '"{0}"' -f $Path } else { '"{0}" {1}' -f $Path, $Args }
        }
        '.vbs'
        {
            $filePath = Join-Path $env:WINDIR 'System32\wscript.exe'
            $arguments = if ([string]::IsNullOrWhiteSpace($Args)) { '//nologo "{0}"' -f $Path } else { '//nologo "{0}" {1}' -f $Path, $Args }
            $stubPath = '"{0}" {1}' -f $filePath, $arguments
        }
        '.js'
        {
            $filePath = Join-Path $env:WINDIR 'System32\wscript.exe'
            $arguments = if ([string]::IsNullOrWhiteSpace($Args)) { '//nologo "{0}"' -f $Path } else { '//nologo "{0}" {1}' -f $Path, $Args }
            $stubPath = '"{0}" {1}' -f $filePath, $arguments
        }
        '.cmd'
        {
            $filePath = Join-Path $env:WINDIR 'System32\cmd.exe'
            $arguments = if ([string]::IsNullOrWhiteSpace($Args)) { '/c ""{0}""' -f $Path } else { '/c ""{0}" {1}"' -f $Path, $Args }
            $stubPath = '"{0}" {1}' -f $filePath, $arguments
        }
        '.bat'
        {
            $filePath = Join-Path $env:WINDIR 'System32\cmd.exe'
            $arguments = if ([string]::IsNullOrWhiteSpace($Args)) { '/c ""{0}""' -f $Path } else { '/c ""{0}" {1}"' -f $Path, $Args }
            $stubPath = '"{0}" {1}' -f $filePath, $arguments
        }
        '.ps1'
        {
            $filePath = Join-Path $PSHOME 'powershell.exe'
            $policy = if ([string]::IsNullOrWhiteSpace($PowerShellExecutionPolicy)) { 'Bypass' } else { $PowerShellExecutionPolicy }
            $arguments = '-NoProfile -ExecutionPolicy {0} -WindowStyle Hidden -File "{1}"' -f $policy, $Path
            if (-not [string]::IsNullOrWhiteSpace($Args))
            {
                $arguments = '{0} {1}' -f $arguments, $Args
            }
            $stubPath = '"{0}" {1}' -f $filePath, $arguments
        }
        default
        {
            throw "Unsupported StubExePath extension [$extension]."
        }
    }

    [pscustomobject]@{
        FilePath = $filePath
        Arguments = $arguments
        StubPath = $stubPath
    }
}

function Get-NativeActiveSetupVersion
{
    param([string]$CurrentVersion)

    $generated = [System.DateTime]::Now.ToString('yyyyMMdd.HHmmss.fff')
    if ([string]::IsNullOrWhiteSpace($CurrentVersion))
    {
        return $generated
    }

    try
    {
        $newVersion = [version]$generated
        $existingVersion = [version]$CurrentVersion
        if ($newVersion -gt $existingVersion)
        {
            return $generated
        }

        $parts = $generated.Split('.')
        $parts[2] = ([int]$parts[2] + 1).ToString()
        return $parts -join '.'
    }
    catch
    {
        return $generated
    }
}

function Set-NativeActiveSetupRegistryValue
{
    param(
        [Parameter(Mandatory = $true)]
        [Microsoft.Win32.RegistryKey]$RootKey,

        [Parameter(Mandatory = $true)]
        [string]$SubKeyPath,

        [Parameter(Mandatory = $true)]
        [string]$Description,

        [Parameter(Mandatory = $true)]
        [string]$Version,

        [Parameter(Mandatory = $true)]
        [string]$StubPath,

        [Parameter(Mandatory = $false)]
        [string]$Locale,

        [Parameter(Mandatory = $false)]
        [bool]$IsInstalled = $true
    )

    $key = $RootKey.CreateSubKey($SubKeyPath)
    try
    {
        $key.SetValue('', $Description, [Microsoft.Win32.RegistryValueKind]::String)
        $key.SetValue('Version', $Version, [Microsoft.Win32.RegistryValueKind]::String)
        $key.SetValue('StubPath', $StubPath, [Microsoft.Win32.RegistryValueKind]::ExpandString)
        if (-not [string]::IsNullOrWhiteSpace($Locale))
        {
            $key.SetValue('Locale', $Locale, [Microsoft.Win32.RegistryValueKind]::String)
        }
        $key.SetValue('IsInstalled', [int]$IsInstalled, [Microsoft.Win32.RegistryValueKind]::DWord)
    }
    finally
    {
        $key.Close()
    }
}

if ([System.IO.Path]::GetExtension($StubExePath) -notmatch '^\.(exe|vbs|js|cmd|bat|ps1)$')
{
    throw "Unsupported StubExePath extension [$([System.IO.Path]::GetExtension($StubExePath))]."
}

if (($StubExePath -notmatch '%\w+%') -and -not (Test-Path -LiteralPath $StubExePath -PathType Leaf))
{
    throw "StubExePath not found: $StubExePath"
}

if ([string]::IsNullOrWhiteSpace($Key))
{
    $Key = [System.IO.Path]::GetFileNameWithoutExtension($StubExePath)
}

if ([string]::IsNullOrWhiteSpace($Description))
{
    $Description = $Key
}

$isSystem = [System.Security.Principal.WindowsIdentity]::GetCurrent().IsSystem
$paths = Get-NativeActiveSetupCommand -Path $StubExePath -Args $Arguments -PowerShellExecutionPolicy $ExecutionPolicy
$hklmRoot = [Microsoft.Win32.Registry]::LocalMachine
$hklmSubKeyPath = (Get-NativeActiveSetupRegistryRoot -UseWow6432Node:$Wow6432Node) + '\' + $Key
$hklmKey = $hklmRoot.CreateSubKey($hklmSubKeyPath)
$existingVersion = $null
try
{
    $existingVersion = $hklmKey.GetValue('Version')
}
catch
{
}
finally
{
    $hklmKey.Close()
}

if ([string]::IsNullOrWhiteSpace($Version))
{
    $Version = Get-NativeActiveSetupVersion -CurrentVersion ([string]$existingVersion)
}

Set-NativeActiveSetupRegistryValue -RootKey $hklmRoot -SubKeyPath $hklmSubKeyPath -Description $Description -Version $Version -StubPath $paths.StubPath -Locale $Locale -IsInstalled (-not $DisableActiveSetup)

if ($DisableActiveSetup -or $NoExecuteForCurrentUser)
{
    return
}

if ($isSystem)
{
    $userSid = $null
    $userName = $null
    if ([NativeActiveSetup]::TryStartProcessInActiveConsoleSession($paths.FilePath, $paths.Arguments, (Split-Path -Path $StubExePath -Parent), [ref]$userSid, [ref]$userName))
    {
        if (-not [string]::IsNullOrWhiteSpace($userSid))
        {
            $hkcuRoot = [Microsoft.Win32.Registry]::Users
            $hkcuSubKeyPath = "$userSid\Software\Microsoft\Active Setup\Installed Components\$Key"
            Set-NativeActiveSetupRegistryValue -RootKey $hkcuRoot -SubKeyPath $hkcuSubKeyPath -Description $Description -Version $Version -StubPath $paths.StubPath -Locale $Locale -IsInstalled $true
        }
    }
}
else
{
    Start-Process -FilePath $paths.FilePath -ArgumentList $paths.Arguments -WindowStyle Hidden | Out-Null
    $hkcuRoot = [Microsoft.Win32.Registry]::CurrentUser
    $hkcuSubKeyPath = "Software\Microsoft\Active Setup\Installed Components\$Key"
    Set-NativeActiveSetupRegistryValue -RootKey $hkcuRoot -SubKeyPath $hkcuSubKeyPath -Description $Description -Version $Version -StubPath $paths.StubPath -Locale $Locale -IsInstalled $true
}
