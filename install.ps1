#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$Version = $env:HOUNDDOG_VERSION
)

# Stop the script on errors.
$ErrorActionPreference = 'Stop'
# Disable progress bar for faster downloads.
$ProgressPreference = 'SilentlyContinue'

if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = 'latest'
}

function Test-HoundDogVersionFormat {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Candidate
    )

    return $Candidate -match '^\d+\.\d+\.\d+(-(alpha|beta))?$'
}

# Check CPU architecture.
$Arch = switch ($env:PROCESSOR_ARCHITECTURE) {
    'AMD64' { 'amd64' }
    'ARM64' { 'arm64' }
    'x86' { 'amd64' }
    default { throw 'Unsupported CPU architecture. HoundDog CLI requires an AMD64, ARM64, or x86 processor.' }
}
$ReleaseRootUrl = "https://github.com/hounddogai/hounddog/releases"
$Version = $Version.Trim()
if ($Version -ne 'latest' -and -not (Test-HoundDogVersionFormat -Candidate $Version)) {
    throw "Invalid version '$Version'. Use x.y.z, x.y.z-alpha, or x.y.z-beta (without a leading 'v')."
}

$TagsToTry = if ($Version -eq 'latest') {
    @('latest')
} else {
    @($Version, "v$Version")
}
$TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())

try {
    # Determine if running with admin privileges
    $IsAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    # Set installation path and PATH scope based on privileges
    if ($IsAdmin) {
        # Admin: Install to Program Files and update System PATH
        $InstallPath = Join-Path $env:ProgramFiles "hounddog\bin"
        $PathScope = "Machine"
        Write-Host "Installing HoundDog CLI for all users..."
    } else {
        # Non-admin: Install to user's local app data and update User PATH
        $InstallPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'hounddog\bin'
        $PathScope = "User"
        Write-Host "Installing HoundDog CLI for current user only..."
    }

    # Create the installation directory if it doesn't exist
    if (Test-Path $InstallPath) {
        Remove-Item -Path "$InstallPath\*" -Force -Recurse -ErrorAction SilentlyContinue
    } else {
        New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
    }

    # Create a temporary directory for downloading the ZIP archive.
    New-Item -ItemType Directory -Path $TempDir -Force | Out-Null

    # Download the ZIP archive and checksum file.
    $ZipPath = Join-Path $TempDir 'hounddog.zip'
    $ChecksumPath = Join-Path $TempDir 'hounddog.zip.sha256'
    $ResolvedTag = $null
    foreach ($Tag in $TagsToTry) {
        if ($Tag -eq 'latest') {
            $BaseDownloadUrl = "$ReleaseRootUrl/latest/download"
        } else {
            $BaseDownloadUrl = "$ReleaseRootUrl/download/$Tag"
        }

        $DownloadUrl = "$BaseDownloadUrl/hounddog-windows-$Arch.zip"
        Write-Host "Downloading ZIP from $DownloadUrl ..."
        try {
            Invoke-WebRequest -Uri $DownloadUrl -OutFile $ZipPath -UseBasicParsing
            Invoke-WebRequest -Uri "$DownloadUrl.sha256" -OutFile $ChecksumPath -UseBasicParsing
            $ResolvedTag = $Tag
            break
        } catch {
            continue
        }
    }

    if (-not $ResolvedTag) {
        throw "Failed to download HoundDog CLI version '$Version'. Ensure the release exists and uses x.y.z, x.y.z-alpha, or x.y.z-beta."
    }

    # Download the SHA256 checksum file and verify the integrity of the binary.
    Write-Host "Verifying checksum ..."
    $ExpectedHash = (Get-Content -Path $ChecksumPath).Split(' ')[0] # Get only the hash, sometimes files include filename
    $ActualHash = Get-FileHash -Path $ZipPath -Algorithm SHA256 | Select-Object -ExpandProperty Hash
    if ($ActualHash -ne $ExpectedHash) {
        throw "Checksum verification failed."
    }

    # Extract the ZIP archive to the installation directory.
    Write-Host "Extracting ZIP to $InstallPath ..."
    Expand-Archive -Path $ZipPath -DestinationPath $InstallPath -Force

    # Verify the extracted file.
    $ExtractedFiles = Get-ChildItem -Path $InstallPath -ErrorAction SilentlyContinue
    if ($ExtractedFiles.Count -eq 0) {
        throw "No files found in $InstallPath after extraction."
    }
    if (-not (Test-Path (Join-Path $InstallPath 'hounddog.exe'))) {
        throw "hounddog.exe not found in $InstallPath after extraction."
    }

    # Update PATH based on admin status
    $CurrentPath = [System.Environment]::GetEnvironmentVariable('Path', $PathScope)

    # Only add the HoundDog installation path if it's not already in the PATH
    if ($CurrentPath -notlike "*$InstallPath*") {
        # Ensure PATH ends with semicolon before appending
        if ($CurrentPath -and -not $CurrentPath.EndsWith(';')) {
            $CurrentPath = "$CurrentPath;"
        }
        
        # Add the new path
        $NewPath = "$CurrentPath$InstallPath"
        
        try {
            [Environment]::SetEnvironmentVariable('Path', $NewPath, $PathScope)
            Write-Host "Added HoundDog CLI to $PathScope PATH."
        } catch {
            Write-Host "Failed to update $PathScope PATH: $_" -ForegroundColor Red
            exit 1
        }
    } else {
        $NewPath = $CurrentPath
    }

    # Update current session's PATH
    $env:Path = $NewPath

    # Test installation.
    if (Get-Command hounddog -ErrorAction SilentlyContinue) {
        Write-Host "`nHoundDog CLI installed successfully."
        if ($Version -ne 'latest') {
            Write-Host "Installed version: $Version"
        }
        Write-Host "Run 'hounddog --help' to get started."
    } else {
        throw "Cannot find 'hounddog' command in PATH."
    }
} catch {
    Write-Host "$_ Aborting installation." -ForegroundColor Red
    exit 1
} finally {
    # Clean up the temporary directory.
    if (Test-Path $TempDir) {
        Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
