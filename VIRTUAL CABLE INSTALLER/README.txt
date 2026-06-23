VIRTUAL CABLE INSTALLER
=======================

Installs the VB-Audio virtual audio cables and sets up the
"Connect Speaker" and "Connect Mic" devices for your app.

Included:
  - Cable A : VB-Audio Virtual Cable
  - Cable B : VB-Audio Hi-Fi Cable (ASIO Bridge)


INSTALLATION
------------
1. Unzip the package into any folder.
2. Open the unzipped folder.
3. Double-click Install.bat.
4. When Windows asks for administrator rights, click Yes.
5. Let the window run. It installs both cables, then renames the
   devices. You will see "Installation done!" at the end.
6. If the window says a restart is required, reboot. Otherwise it is
   ready - no restart needed.


WHAT IT DOES
------------
- Checks whether each cable is already installed (no useless reinstall).
- Installs missing cables silently.
- Renames the audio devices:
    Hi-Fi Cable Input  ->  Connect Speaker
    CABLE Output       ->  Connect Mic
- Restarts the audio service to apply the new names.

Safe to run again: re-running Install.bat breaks nothing and just
confirms everything is in place.


VERIFY IT WORKED
----------------
Open Windows Sound settings (right-click the speaker icon -> Sound settings):
  - Output list  -> you should see "Connect Speaker"
  - Input list   -> you should see "Connect Mic"


WINDOWS WARNINGS (NORMAL)
-------------------------
- "Windows protected your PC" / unknown publisher: the installer is not
  digitally signed. Click "More info" -> "Run anyway". It is safe.
- Driver signature prompt: Windows may ask you to confirm the VB-Audio
  driver install. Accept to continue (this cannot be automated).


TROUBLESHOOTING
---------------
"Connect" devices do not show up right away:
  VB-Audio drivers are sometimes registered after a short delay.
  Reboot, then run Install.bat again - the rename will complete.

"File not found" in the window:
  The folder was unzipped incorrectly. Keep this structure intact:

    Virtual Cable Installer\
      Install.bat
      Install-VirtualCables.ps1
      Cable A\   (VBCABLE_Setup_x64.exe + driver files)
      Cable B\   (HiFiCableAsioBridgeSetup.exe)

  All files must stay in the same folder.


UNINSTALL
---------
Run the original installers in uninstall mode (or via Settings ->
Apps), then reboot to finish removing the drivers.
