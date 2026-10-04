[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $SourceIso,

    [Parameter(Mandatory = $true)]
    [string] $OutputIso,

    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 999)]
    [int] $Index,

    [string] $AppxRemovalConfig = (Join-Path $PSScriptRoot '..\config\remove-apps.json')
)

$ErrorActionPreference = 'Stop'

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'This builder must run on Windows.'
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated PowerShell window.'
}

Import-Module Dism -ErrorAction Stop

$oscdimg = Get-Command oscdimg.exe -ErrorAction SilentlyContinue
if ($null -eq $oscdimg) {
    throw 'oscdimg.exe was not found on PATH. Install the Windows ADK Deployment Tools.'
}

$sourcePath = (Resolve-Path -LiteralPath $SourceIso).Path
$outputPath = [IO.Path]::GetFullPath($OutputIso)
$outputDirectory = Split-Path -Parent $outputPath
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    throw "Output directory does not exist: $outputDirectory"
}
if ([string]::Equals($sourcePath, $outputPath, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The output ISO path must be different from the source ISO path.'
}
if (Test-Path -LiteralPath $outputPath) {
    throw "Output already exists; choose a new path: $outputPath"
}
if (-not (Test-Path -LiteralPath $AppxRemovalConfig -PathType Leaf)) {
    throw "App removal configuration was not found: $AppxRemovalConfig"
}

$config = Get-Content -LiteralPath $AppxRemovalConfig -Raw | ConvertFrom-Json
$removeDisplayNames = @($config.removeDisplayNames | Where-Object { $_ -is [string] -and $_.Trim().Length -gt 0 })
if ($removeDisplayNames.Count -eq 0) {
    throw 'The configuration must contain at least one non-empty removeDisplayNames entry.'
}

$workPath = Join-Path ([IO.Path]::GetTempPath()) ("DebloatedWindowsISO-" + [Guid]::NewGuid().ToString('N'))
$stagePath = Join-Path $workPath 'media'
$mountPath = Join-Path $workPath 'mounted-image'
$exportPath = Join-Path $workPath 'install.wim'
$isoMounted = $false
$imageMounted = $false

try {
    New-Item -ItemType Directory -Path $stagePath, $mountPath | Out-Null

    Mount-DiskImage -ImagePath $sourcePath -ErrorAction Stop | Out-Null
    $isoMounted = $true
    $volume = Get-DiskImage -ImagePath $sourcePath | Get-Volume |
        Where-Object { $_.DriveLetter } |
        Select-Object -First 1
    if ($null -eq $volume) {
        throw 'Could not find a drive letter for the mounted source ISO.'
    }

    $mediaRoot = "$($volume.DriveLetter):\"
    $sourcesPath = Join-Path $mediaRoot 'sources'
    $imageFiles = @(
        (Join-Path $sourcesPath 'install.wim'),
        (Join-Path $sourcesPath 'install.esd')
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
    $splitImageFiles = @(Get-ChildItem -LiteralPath $sourcesPath -Filter 'install*.swm' -ErrorAction SilentlyContinue)
    if ($splitImageFiles.Count -gt 0) {
        throw 'Split install.swm media is not supported.'
    }
    if ($imageFiles.Count -ne 1) {
        throw 'Expected exactly one sources\install.wim or sources\install.esd in the ISO.'
    }

    $imagePath = $imageFiles[0]
    $availableImages = @(Get-WindowsImage -ImagePath $imagePath)
    if (-not ($availableImages | Where-Object { $_.ImageIndex -eq $Index })) {
        $availableImages | Format-Table ImageIndex, ImageName | Out-Host
        throw "Image index $Index is not present in $imagePath."
    }

    Write-Host "Exporting image index $Index to a clean WIM..."
    Export-WindowsImage -SourceImagePath $imagePath -SourceIndex $Index `
        -DestinationImagePath $exportPath -CompressionType Max -CheckIntegrity | Out-Null

    Mount-WindowsImage -ImagePath $exportPath -Index 1 -Path $mountPath -CheckIntegrity | Out-Null
    $imageMounted = $true

    $provisionedPackages = @(Get-AppxProvisionedPackage -Path $mountPath)
    foreach ($displayName in $removeDisplayNames) {
        $matches = @($provisionedPackages | Where-Object { $_.DisplayName -eq $displayName })
        if ($matches.Count -eq 0) {
            Write-Host "Not present; skipping: $displayName"
            continue
        }

        foreach ($package in $matches) {
            Write-Host "Removing provisioned app: $($package.DisplayName)"
            Remove-AppxProvisionedPackage -Path $mountPath -PackageName $package.PackageName | Out-Null
        }
    }

    Dismount-WindowsImage -Path $mountPath -Save -CheckIntegrity | Out-Null
    $imageMounted = $false

    Write-Host 'Copying Windows installation media...'
    $robocopyArgs = @(
        $mediaRoot, $stagePath,
        '/E', '/COPY:DAT', '/R:2', '/W:2', '/NFL', '/NDL', '/NJH', '/NJS', '/NP',
        '/XF', 'install.wim', 'install.esd'
    )
    & robocopy.exe @robocopyArgs | Out-Host
    if ($LASTEXITCODE -ge 8) {
        throw "robocopy failed with exit code $LASTEXITCODE."
    }

    $stagedSourcesPath = Join-Path $stagePath 'sources'
    Remove-Item -LiteralPath (Join-Path $stagedSourcesPath 'install.wim') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $stagedSourcesPath 'install.esd') -Force -ErrorAction SilentlyContinue
    Move-Item -LiteralPath $exportPath -Destination (Join-Path $stagedSourcesPath 'install.wim')

    $biosBoot = Join-Path $stagePath 'boot\etfsboot.com'
    $uefiBoot = Join-Path $stagePath 'efi\microsoft\boot\efisys.bin'
    if (-not (Test-Path -LiteralPath $biosBoot -PathType Leaf) -or
        -not (Test-Path -LiteralPath $uefiBoot -PathType Leaf)) {
        throw 'The ISO is missing the BIOS or UEFI boot image required to create bootable media.'
    }

    Write-Host "Creating bootable ISO: $outputPath"
    $bootData = "-bootdata:2#p0,e,b$biosBoot#pEF,e,b$uefiBoot"
    & $oscdimg.Source -m -o -u2 -udfver102 $bootData $stagePath $outputPath
    if ($LASTEXITCODE -ne 0) {
        throw "oscdimg failed with exit code $LASTEXITCODE."
    }

    $hash = (Get-FileHash -LiteralPath $outputPath -Algorithm SHA256).Hash
    Write-Host "Created ISO: $outputPath"
    Write-Host "SHA-256: $hash"
}
finally {
    if ($imageMounted) {
        Dismount-WindowsImage -Path $mountPath -Discard | Out-Null
    }
    if ($isoMounted) {
        Dismount-DiskImage -ImagePath $sourcePath | Out-Null
    }
    if (Test-Path -LiteralPath $workPath) {
        Remove-Item -LiteralPath $workPath -Recurse -Force
    }
}
