<#
====================================================================
  Install-VirtualCables.ps1
  Tout-en-un : auto-elevation, telechargement, extraction,
  installation, renommage.

  Les installeurs ne sont PLUS embarques : ils sont telecharges
  depuis les sources officielles, puis extraits dans Cable A / B.
    Cable A = VB-Audio Virtual Cable
              https://download.vb-audio.com/Download_CABLE/VBCABLE_Driver_Pack45.zip
    Cable B = VB-Audio Hi-Fi Cable (ASIO Bridge)
              http://vincent.burel.free.fr/VirtualAudioApps/HiFiCableAsioBridgeSetup_v1007.zip

  Detection : par device PnP (FriendlyName).
  Renommage : prise de possession TrustedInstaller + PKEY_Device_DeviceDesc.
    - Hi-Fi Cable Input  (Render,  VB-Audio Hi-Fi Cable)   -> "Connect Speaker"
    - CABLE Output       (Capture, VB-Audio Virtual Cable) -> "Connect Mic"

  Optimisations :
    - Add-Type (C#) compile UNE seule fois au demarrage.
    - Detection PnP mise en cache (1 seul scan, pas 1 par appel).
    - Effet visuel raccourci (1 s).
    - Telechargement ignore si le cable est deja installe.
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
$script:RebootNeeded = $false

# -- PKEYs --
$NAME_PKEY  = '{a45c254e-df1c-4efd-8020-67d146a850e0},2'   # PKEY_Device_DeviceDesc (nom affiche)
$IFACE_PKEY = '{b3f8fa53-0004-438e-9003-51a46e139bfc},6'   # PKEY_DeviceInterface_FriendlyName (driver)

# -- Config cables : URL a telecharger + dossier d'extraction + motif de l'exe --
$Cables = @(
    @{ Label = 'VB-CABLE'
       Url   = 'https://download.vb-audio.com/Download_CABLE/VBCABLE_Driver_Pack45.zip'
       Dir   = Join-Path $BASE 'Cable A'
       Exe   = 'VBCABLE_Setup_x64.exe'
       Pnp   = 'VB-Audio Virtual Cable' },

    @{ Label = 'HiFi Cable ASIO Bridge'
       Url   = 'http://vincent.burel.free.fr/VirtualAudioApps/HiFiCableAsioBridgeSetup_v1007.zip'
       Dir   = Join-Path $BASE 'Cable B'
       Exe   = 'HiFiCableAsioBridgeSetup*.exe'
       Pnp   = 'VB-Audio Hi-Fi Cable' }
)

# -- Cibles de renommage --
$Targets = @(
    [pscustomobject]@{ Slot='speaker'; Flow='Render';  Iface='VB-Audio Hi-Fi Cable';   Names=@('Hi-Fi Cable Input','Connect Speaker'); New='Connect Speaker' }
    [pscustomobject]@{ Slot='mic';     Flow='Capture'; Iface='VB-Audio Virtual Cable'; Names=@('CABLE Output','Connect Mic');          New='Connect Mic' }
)

# ===== C# COMPILE UNE SEULE FOIS (sinon recompile a chaque appel = lent) =====
$tokenManipulatorSig = @'
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
if (-not ('TokenManipulator' -as [type])) {
    Add-Type $tokenManipulatorSig -ErrorAction SilentlyContinue
}

# ===== AFFICHAGE =====
function Write-StepDone {
    param([string]$Text)
    Write-Host "  [v] $Text" -ForegroundColor Green -NoNewline
    Start-Sleep -Milliseconds 1000
    $blank = ' ' * ($Text.Length + 8)
    Write-Host "`r$blank`r" -NoNewline
}

# ===== DETECTION (avec cache : 1 seul scan PnP pour toute l'execution) =====
$script:PnpCache = $null
function Get-AudioPnpNames {
    if ($null -eq $script:PnpCache) {
        $script:PnpCache = @(
            Get-PnpDevice -Class 'AudioEndpoint','MEDIA' -ErrorAction SilentlyContinue |
            Where-Object { $_.Status -eq 'OK' } |
            Select-Object -ExpandProperty FriendlyName
        )
    }
    return $script:PnpCache
}
function Reset-PnpCache { $script:PnpCache = $null }

function Test-CableInstalled {
    param([string]$PnpName)
    $names = Get-AudioPnpNames
    foreach ($n in $names) { if ($n -like "*$PnpName*") { return $true } }
    return $false
}

# ===== TELECHARGEMENT + EXTRACTION =====
# Renvoie le chemin de l'exe d'installation, en le telechargeant/extrayant si besoin.
function Resolve-Installer {
    param([hashtable]$Cfg)

    # 1) Deja extrait ? on reutilise.
    if (Test-Path $Cfg.Dir) {
        $found = Get-ChildItem -Path $Cfg.Dir -Filter $Cfg.Exe -Recurse -File -ErrorAction SilentlyContinue |
                 Select-Object -First 1
        if ($found) { return $found.FullName }
    }

    # 2) Telecharger le zip.
    Write-Host "Downloading $($Cfg.Label)..." -NoNewline
    New-Item -ItemType Directory -Path $Cfg.Dir -Force | Out-Null
    $zip = Join-Path $env:TEMP ("vbdl_{0}.zip" -f [IO.Path]::GetRandomFileName())
    try {
        [Net.ServicePointManager]::SecurityProtocol = `
            [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11
        Invoke-WebRequest -Uri $Cfg.Url -OutFile $zip -UseBasicParsing
        Write-Host " done." -ForegroundColor Green
    } catch {
        Write-Host " FAILED." -ForegroundColor Red
        Write-Host "  [X] Download error ($($Cfg.Url)): $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }

    # 3) Extraire dans Cable A / Cable B.
    Write-Host "Extracting $($Cfg.Label)..." -NoNewline
    try {
        Expand-Archive -Path $zip -DestinationPath $Cfg.Dir -Force
        Write-Host " done." -ForegroundColor Green
    } catch {
        Write-Host " FAILED." -ForegroundColor Red
        Write-Host "  [X] Extract error: $($_.Exception.Message)" -ForegroundColor Red
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        return $null
    }
    Remove-Item $zip -Force -ErrorAction SilentlyContinue

    # 4) Localiser l'exe (recursif : certains zip ont un sous-dossier).
    $found = Get-ChildItem -Path $Cfg.Dir -Filter $Cfg.Exe -Recurse -File -ErrorAction SilentlyContinue |
             Select-Object -First 1
    if (-not $found) {
        Write-Host "  [X] Setup introuvable apres extraction (motif: $($Cfg.Exe))." -ForegroundColor Red
        return $null
    }
    return $found.FullName
}

# ===== INSTALLATION =====
function Install-Cable {
    param([hashtable]$Cfg)

    if (Test-CableInstalled $Cfg.Pnp) {
        Write-Host "[OK] $($Cfg.Label) is already installed." -ForegroundColor Cyan
        return
    }

    $installer = Resolve-Installer $Cfg
    if (-not $installer) {
        Write-Host "[X] $($Cfg.Label): installer unavailable, skipping." -ForegroundColor Red
        return
    }

    Write-Host "Installing $($Cfg.Label)..." -NoNewline
    Start-Process -FilePath $installer `
        -ArgumentList '-i', '-h' `
        -WorkingDirectory (Split-Path $installer) `
        -Wait | Out-Null
    Write-Host ""

    Reset-PnpCache   # un nouveau device est apparu -> rescanner
    if (Test-CableInstalled $Cfg.Pnp) {
        Write-StepDone "$($Cfg.Label) installed"
        Write-Host "[OK] $($Cfg.Label) installed." -ForegroundColor Green
    } else {
        Write-Host "[!] $($Cfg.Label): driver not loaded yet, a restart is required." -ForegroundColor Yellow
        $script:RebootNeeded = $true
    }
}

# ===== RENOMMAGE (prise de possession TrustedInstaller) =====
function Enable-Privilege {
    param([string]$Privilege)
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