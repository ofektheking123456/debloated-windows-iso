# Debloated Windows ISO builder

Build a Windows installation ISO from official Microsoft installation media, with a configurable set of preinstalled inbox apps removed. This repository contains the build script and configuration only; it does not contain or distribute Windows files.

## Requirements

- A Windows PC and an official Microsoft Windows installation ISO.
- Windows PowerShell 5.1, run as Administrator.
- The **Deployment Tools** feature from the [Windows ADK](https://learn.microsoft.com/windows-hardware/get-started/adk-install), which provides `oscdimg.exe`.
- Enough free disk space for a copy of the installation media, a working image, and the output ISO.

## Build

1. Download the Windows ISO directly from Microsoft and note its path.
2. In an elevated Windows PowerShell window, inspect the available editions. Replace `E:` with the drive letter assigned to the mounted ISO:

   ```powershell
   Mount-DiskImage -ImagePath 'C:\Downloads\Windows.iso'
   Get-WindowsImage -ImagePath 'E:\sources\install.esd' |
       Format-Table ImageIndex, ImageName
   Dismount-DiskImage -ImagePath 'C:\Downloads\Windows.iso'
   ```

   If the ISO has `install.wim` instead of `install.esd`, use that file path.
3. From the repository directory, run the builder with the desired image index:

   ```powershell
   .\scripts\Build-DebloatedIso.ps1 `
       -SourceIso 'C:\Downloads\Windows.iso' `
       -OutputIso 'C:\Downloads\Windows-debloated.iso' `
       -Index 1
   ```

The output ISO contains only the selected edition. The script copies the ISO contents, exports that edition to a fresh WIM, removes matching provisioned app packages, and creates a bootable BIOS/UEFI ISO. It prints the output SHA-256 hash when finished.

## Customize removed apps

Edit [`config/remove-apps.json`](config/remove-apps.json) before building. Entries are exact `DisplayName` values from the selected image's provisioned Appx packages. Packages not present in a particular Windows release are skipped with a notice. The default list targets optional consumer apps; it intentionally keeps Microsoft Store, Edge, Windows security components, and core Windows apps.

This builder does not disable services, change registry settings, or remove Windows features. Review the package list and test the resulting ISO in a virtual machine before installing it on a primary device. Windows updates may restore or change included apps.

## Limitations

- Use installation media and a Windows license obtained from Microsoft. The user is responsible for complying with Microsoft's license terms.
- The script requires an ISO with `sources\install.wim` or `sources\install.esd`; split `install.swm` media is not supported.
- `oscdimg.exe` must be on `PATH`. Install the Windows ADK Deployment Tools if it is unavailable.
- No ISO is downloaded, bundled, or uploaded by this project.
