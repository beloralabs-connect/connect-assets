<#
====================================================================
  Install-VirtualCables.ps1
  Tout-en-un : auto-elevation, detection, installation, renommage.

  Cable A = VB-Audio Virtual Cable -> VBCABLE_Setup_x64.exe
  Cable B = VB-Audio Hi-Fi Cable   -> HiFiCableAsioBridgeSetup.exe

  Detection : par device PnP (FriendlyName).
  Renommage : prise de possession TrustedInstaller + PKEY_Device_DeviceDesc.
    - Hi-Fi Cable Input  (Render,  VB-Audio Hi-Fi Cable)   -> "Connect Speaker"
    - CABLE Output       (Capture, VB-Audio Virtual Cable) -> "Connect Mic"
====================================================================
#>

param([switch]$Silent)

# -- Auto-elevation : relance en admin si necessaire --
$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Requesting administrator rights..." -ForegroundColor Yellow
    $relaunchArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($Silent) { $relaunchArgs += '-Silent' }
    Start-Process powershell -Verb RunAs -ArgumentList $relaunchArgs
    exit
}

$ErrorActionPreference = 'Stop'
$BASE = Split-Path -Parent $MyInvocation.MyCommand.Path

# Suivi : un reboot n'est requis QUE si un driver installe n'est pas encore charge
$script:RebootNeeded = $false

# -- PKEYs --
$NAME_PKEY  = '{a45c254e-df1c-4efd-8020-67d146a850e0},2'   # PKEY_Device_DeviceDesc (nom affiche)
$IFACE_PKEY = '{b3f8fa53-0004-438e-9003-51a46e139bfc},6'   # PKEY_DeviceInterface_FriendlyName (driver)

# -- Config cables --
$Cables = @(
    @{ Label = 'VB-CABLE'              ; Installer = Join-Path $BASE 'Cable A\VBCABLE_Setup_x64.exe'         ; Pnp = 'VB-Audio Virtual Cable' },
    @{ Label = 'HiFi Cable ASIO Bridge'; Installer = Join-Path $BASE 'Cable B\HiFiCableAsioBridgeSetup.exe' ; Pnp = 'VB-Audio Hi-Fi Cable'  }
)

# -- Cibles de renommage --
$Targets = @(
    [pscustomobject]@{ Slot='speaker'; Flow='Render';  Iface='VB-Audio Hi-Fi Cable';   Names=@('Hi-Fi Cable Input','Connect Speaker'); New='Connect Speaker' }
    [pscustomobject]@{ Slot='mic';     Flow='Capture'; Iface='VB-Audio Virtual Cable'; Names=@('CABLE Output','Connect Mic');          New='Connect Mic' }
)

# ===== AFFICHAGE =====
function Write-StepDone {
    param([string]$Text)
    Write-Host "  [v] $Text" -ForegroundColor Green -NoNewline
    Start-Sleep -Seconds 2
    $blank = ' ' * ($Text.Length + 8)
    Write-Host "`r$blank`r" -NoNewline
}

# ===== DETECTION & INSTALLATION =====
function Test-CableInstalled {
    param([string]$PnpName)
    $d = Get-PnpDevice -FriendlyName "*$PnpName*" -ErrorAction SilentlyContinue |
         Where-Object { $_.Status -eq 'OK' }
    return [bool]$d
}

function Install-Cable {
    param([hashtable]$Cfg)

    if (Test-CableInstalled $Cfg.Pnp) {
        Write-Host "[OK] $($Cfg.Label) is already installed." -ForegroundColor Cyan
        return
    }
    if (-not (Test-Path $Cfg.Installer)) {
        Write-Host "[X] File not found: $($Cfg.Installer)" -ForegroundColor Red
        return
    }

    Write-Host "Installing $($Cfg.Label)..." -NoNewline
    Start-Process -FilePath $Cfg.Installer `
        -ArgumentList '-i', '-h' `
        -WorkingDirectory (Split-Path $Cfg.Installer) `
        -Wait | Out-Null
    Write-Host ""

    if (Test-CableInstalled $Cfg.Pnp) {
        Write-StepDone "$($Cfg.Label) installed"
        Write-Host "[OK] $($Cfg.Label) installed." -ForegroundColor Green
    } else {
        # Installe mais pas encore charge -> ce cas (et seulement lui) exige un reboot
        Write-Host "[!] $($Cfg.Label): driver not loaded yet, a restart is required." -ForegroundColor Yellow
        $script:RebootNeeded = $true
    }
}

# ===== RENOMMAGE (prise de possession TrustedInstaller) =====
function Enable-Privilege {
    param([string]$Privilege)
    $sig = @'
using System;
using System.Runtime.InteropServices;
public class TokenManipulator {
    [DllImport("kernel32.dll")] internal static extern IntPtr GetCurrentProcess();
    [DllImport("advapi32.dll", SetLastError = true)] internal static extern bool OpenProcessToken(IntPtr h, int acc, ref IntPtr phtok);
    [DllImport("advapi32.dll", SetLastError = true)] internal static extern bool LookupPrivilegeValue(string host, string name, ref long pluid);
    [DllImport("advapi32.dll", SetLastError = true)] internal static extern bool AdjustTokenPrivileges(IntPtr htok, bool disall, ref TokPriv1Luid newst, int len, IntPtr prev, IntPtr relen);
    [StructLayout(LayoutKind.Sequential, Pack = 1)] internal struct TokPriv1Luid { public int Count; public long Luid; public int Attr; }
    public static void AddPrivilege(string privilege) {
        TokPriv1Luid tp; IntPtr htok = IntPtr.Zero;
        OpenProcessToken(GetCurrentProcess(), 0x20 | 0x8, ref htok);
        tp.Count = 1; tp.Luid = 0; tp.Attr = 0x2;
        LookupPrivilegeValue(null, privilege, ref tp.Luid);
        AdjustTokenPrivileges(htok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
    }
}
'@
    Add-Type $sig -ErrorAction SilentlyContinue
    [TokenManipulator]::AddPrivilege($Privilege)
}

function Take-RegKeyOwnership {
    param([string]$SubPath)   # relatif a HKLM
    $admins = New-Object System.Security.Principal.SecurityIdentifier(
        [System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)

    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
        $SubPath,
        [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
        [System.Security.AccessControl.RegistryRights]::TakeOwnership)
    $acl = $key.GetAccessControl(); $acl.SetOwner($admins); $key.SetAccessControl($acl); $key.Close()

    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
        $SubPath,
        [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
        [System.Security.AccessControl.RegistryRights]::ChangePermissions)
    $acl = $key.GetAccessControl()
    $rule = New-Object System.Security.AccessControl.RegistryAccessRule($admins, "FullControl", "Allow")
    $acl.SetAccessRule($rule); $key.SetAccessControl($acl); $key.Close()
}

function Find-DeviceGuid {
    param($Flow, $Iface, $Names)
    $base = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\$Flow"
    foreach ($k in (Get-ChildItem $base -ErrorAction SilentlyContinue)) {
        $pp = Join-Path $k.PSPath 'Properties'
        if (-not (Test-Path $pp)) { continue }
        $p = Get-ItemProperty -Path $pp -ErrorAction SilentlyContinue
        if (-not $p) { continue }
        if ($p.$IFACE_PKEY -eq $Iface -and ($Names -contains $p.$NAME_PKEY)) {
            return $k.PSChildName
        }
    }
    return $null
}

function Get-CurrentName {
    param($Flow, $Guid)
    $pp = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\$Flow\$Guid\Properties"
    return (Get-ItemProperty -Path $pp -Name $NAME_PKEY -ErrorAction SilentlyContinue).$NAME_PKEY
}

function Invoke-Rename {
    Enable-Privilege "SeTakeOwnershipPrivilege"
    Enable-Privilege "SeRestorePrivilege"
    $changed = $false

    foreach ($t in $Targets) {
        try {
            $guid = Find-DeviceGuid -Flow $t.Flow -Iface $t.Iface -Names $t.Names
            if (-not $guid) {
                Write-Host "  [-] $($t.New): device not found (cable not installed?)" -ForegroundColor DarkGray
                continue
            }
            $cur = Get-CurrentName -Flow $t.Flow -Guid $guid
            if ($cur -eq $t.New) {
                Write-Host "  [OK] Already named '$($t.New)'" -ForegroundColor Cyan
                continue
            }
            $sub = "SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\$($t.Flow)\$guid\Properties"
            Take-RegKeyOwnership -SubPath $sub
            Set-ItemProperty -Path "HKLM:\$sub" -Name $NAME_PKEY -Value $t.New
            Write-Host "  [v] Renamed '$cur' -> '$($t.New)'" -ForegroundColor Green
            $changed = $true
        } catch {
            Write-Host "  [X] $($t.New): $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    if ($changed) {
        Write-Host "Restarting audio service..." -NoNewline
        try { Restart-Service -Name Audiosrv -Force -ErrorAction Stop; Write-Host " done." -ForegroundColor Green }
        catch { Write-Host " skipped." -ForegroundColor Yellow }
    }
}

# ===== EXECUTION =====
Write-Host ""
Write-Host "===============================" -ForegroundColor White
Write-Host "   VIRTUAL CABLE INSTALLER" -ForegroundColor White
Write-Host "===============================" -ForegroundColor White
Write-Host ""

foreach ($c in $Cables) {
    Write-Host "=== $($c.Label) ===" -ForegroundColor White
    Install-Cable $c
    Write-Host ""
}

Write-Host "=== Renaming endpoints ===" -ForegroundColor White
Invoke-Rename
Write-Host ""

Write-Host "===============================" -ForegroundColor Green
Write-Host "   Installation done!" -ForegroundColor Green
Write-Host "===============================" -ForegroundColor Green
if ($script:RebootNeeded) {
    Write-Host "A Windows restart is required to finish loading the driver(s)." -ForegroundColor Yellow
} else {
    Write-Host "All cables are installed and active. No restart needed." -ForegroundColor Gray
}
Write-Host ""
if (-not $Silent) { Read-Host "Press Enter to close" }