# ============================================================
# GreenBoost Windows Port - Build Script
# Functions: Clean, Configure, Build, Sign, Collect outputs
# Requires: Run as Administrator
# ============================================================

param(
    [string]$Config = "Release",
    [string]$Arch = "x64",
    [switch]$NoSign,
    [switch]$Clean
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$buildDir = Join-Path $scriptDir "build"
$outputsDir = Join-Path $scriptDir "tools\outputs"

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host " $Message" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
}

function Test-Administrator {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

try {
    Write-Host ""
    Write-Host "  ____                              ____            _     _     " -ForegroundColor Green
    Write-Host " / ___| _ __   __ _  ___ ___  _ __  / ___| _   _ ___| |__ | | ___" -ForegroundColor Green
    Write-Host " \___ \| '_ \ / _` |/ __/ _ \| '_ \| |  _| | | / __| '_ \| |/ _ \" -ForegroundColor Green
    Write-Host "  ___) | |_) | (_| | (_| (_) | | | | |_| | |_| \__ \ | | | |  __/" -ForegroundColor Green
    Write-Host " |____/| .__/ \__,_|\___\___/|_| |_|\____|\__, |___/_| |_|_|\___|" -ForegroundColor Green
    Write-Host "       |_|                                |___/                  " -ForegroundColor Green
    Write-Host ""

    if (-not (Test-Administrator)) {
        Write-Host "[WARNING] Not running as Administrator. Driver signing may fail." -ForegroundColor Yellow
    }

    Write-Step "[1/5] Clean Build Directory"
    if (Test-Path $buildDir) {
        Write-Host "Removing existing build directory..." -ForegroundColor Yellow
        Remove-Item -Path $buildDir -Recurse -Force
        Write-Host "Build directory cleaned." -ForegroundColor Green
    } else {
        Write-Host "No existing build directory found." -ForegroundColor Gray
    }

    Write-Step "[2/5] Configure CMake"
    $configureArgs = @(
        "-B", "build",
        "-G", "Visual Studio 17 2022",
        "-A", $Arch,
        "-DCMAKE_BUILD_TYPE=$Config",
        "-DGB_BUILD_DRIVER=ON"
    )
    Write-Host "Running: cmake $configureArgs" -ForegroundColor Gray
    & cmake $configureArgs
    if ($LASTEXITCODE -ne 0) {
        throw "CMake configuration failed with exit code: $LASTEXITCODE"
    }
    Write-Host "CMake configuration completed." -ForegroundColor Green

    Write-Step "[3/5] Build Project"
    $buildArgs = @(
        "--build", "build",
        "--config", $Config
    )
    Write-Host "Running: cmake $buildArgs" -ForegroundColor Gray
    & cmake $buildArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Build failed with exit code: $LASTEXITCODE"
    }
    Write-Host "Build completed." -ForegroundColor Green

    $shimPath = Join-Path $buildDir "shim\$Config\greenboost_cuda.dll"
    $driverPath = Join-Path $buildDir "driver\$Config\greenboost_win.sys"
    $testPath = Join-Path $buildDir "tests\$Config\test_ioctl.exe"

    Write-Host ""
    Write-Host "Build Artifacts:" -ForegroundColor White
    if (Test-Path $shimPath) {
        Write-Host "  [DLL]  $shimPath" -ForegroundColor Green
    }
    if (Test-Path $driverPath) {
        Write-Host "  [SYS]  $driverPath" -ForegroundColor Green
    }
    if (Test-Path $testPath) {
        Write-Host "  [EXE]  $testPath" -ForegroundColor Green
    }

    if (-not $NoSign) {
        Write-Step "[4/5] Sign Driver"
        $signScript = Join-Path $scriptDir "sign.ps1"
        if (Test-Path $signScript) {
            Write-Host "Running sign.ps1..." -ForegroundColor Gray
            & $signScript
            if ($LASTEXITCODE -ne 0) {
                throw "Signing failed with exit code: $LASTEXITCODE"
            }
            Write-Host "Driver signed successfully." -ForegroundColor Green
        } else {
            Write-Host "[WARNING] sign.ps1 not found, skipping signing." -ForegroundColor Yellow
        }
    } else {
        Write-Step "[4/5] Sign Driver (Skipped)"
        Write-Host "Signing skipped due to -NoSign flag." -ForegroundColor Yellow
    }

    Write-Step "[5/5] Collect Outputs"
    Write-Host "Collecting build artifacts to tools\outputs..." -ForegroundColor Gray

    if (Test-Path $outputsDir) {
        Remove-Item -Path $outputsDir -Recurse -Force
    }
    New-Item -Path $outputsDir -ItemType Directory -Force | Out-Null

    $collected = @()

    if (Test-Path $shimPath) {
        Copy-Item -Path $shimPath -Destination $outputsDir -Force
        $collected += "greenboost_cuda.dll"
        Write-Host "  Copied: greenboost_cuda.dll" -ForegroundColor Green
    }

    if (Test-Path $driverPath) {
        Copy-Item -Path $driverPath -Destination $outputsDir -Force
        $collected += "greenboost_win.sys"
        Write-Host "  Copied: greenboost_win.sys" -ForegroundColor Green
    }

    $infSource = Join-Path $scriptDir "driver\greenboost_win.inf"
    if (Test-Path $infSource) {
        Copy-Item -Path $infSource -Destination $outputsDir -Force
        $collected += "greenboost_win.inf"
        Write-Host "  Copied: greenboost_win.inf" -ForegroundColor Green
    }

    if (Test-Path $testPath) {
        Copy-Item -Path $testPath -Destination $outputsDir -Force
        $collected += "test_ioctl.exe"
        Write-Host "  Copied: test_ioctl.exe" -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "============================================" -ForegroundColor Green
    Write-Host " BUILD COMPLETED SUCCESSFULLY!" -ForegroundColor Green
    Write-Host "============================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Outputs collected to: $outputsDir" -ForegroundColor White
    foreach ($item in $collected) {
        Write-Host "  - $item" -ForegroundColor Gray
    }
    Write-Host ""
    Write-Host "To install, run: .\tools\install.ps1" -ForegroundColor Cyan
    Write-Host ""

} catch {
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Red
    Write-Host " BUILD FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "============================================" -ForegroundColor Red
    Write-Host ""
    exit 1
}
