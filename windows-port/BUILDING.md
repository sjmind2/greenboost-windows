# Building GreenBoost for Windows

## Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| Visual Studio 2022 | With C++ desktop workload | Compiler |
| Windows Driver Kit (WDK) | 10/11 | KMDF driver build |
| CMake | 3.20+ | Build system |
| Microsoft Detours | vcpkg or NuGet | CUDA hook injection (optional) |
| NVIDIA GPU Driver | 535+ (CUDA 12+) | Runtime |

## Quick Start

```powershell
cd windows-port

# Build everything (clean, configure, build, sign, collect)
.\build.ps1

# Install (requires Administrator)
.\tools\install.ps1
```

Outputs are collected to `tools\outputs\`:
- `greenboost_cuda.dll` — CUDA shim DLL
- `greenboost_win.sys` — KMDF driver
- `greenboost_win.inf` — Driver installation file
- `test_ioctl.exe` — IOCTL test tool

## Build Options

```powershell
# Default: Release build with signing
.\build.ps1

# Debug build
.\build.ps1 -Config Debug

# Skip driver signing (for testing without driver)
.\build.ps1 -NoSign
```

## Detours Setup (Optional)

The shim can use Microsoft Detours for API hooking. If not available, it falls back to manual IAT patching.

```powershell
# Install vcpkg (if not already installed)
git clone https://github.com/Microsoft/vcpkg.git
cd vcpkg
.\bootstrap-vcpkg.bat
.\vcpkg integrate install

# Install Detours
.\vcpkg install detours:x64-windows

# Set environment variable
$env:VCPKG_ROOT = "C:\path\to\vcpkg"

# Build with Detours
cmake -B build -G "Visual Studio 17 2022" -A x64 `
    -DCMAKE_TOOLCHAIN_FILE="$env:VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake" `
    -DGB_BUILD_DRIVER=ON
```

## Driver Signing & Secure Boot

### ⚠️ Important: Secure Boot Requirement

**The kernel driver requires test signing to be enabled.** However, if your system has **Secure Boot** enabled, you cannot enable test signing:

```
bcdedit /set testsigning on
# Error: 该值受安全引导策略保护，无法进行修改或删除。
# (The value is protected by Secure Boot policy and cannot be modified.)
```

### Solution 1: Disable Secure Boot (Recommended for Development)

1. Restart PC and enter BIOS/UEFI setup (usually F2, Del, or F12)
2. Find **Secure Boot** option (usually under Security or Boot tab)
3. Set to **Disabled**
4. Save and exit BIOS
5. After reboot, run:
   ```powershell
   bcdedit /set testsigning on
   # Reboot again
   ```

### Solution 2: Temporary Disable Driver Signature Enforcement

This works per-boot only (resets after restart):

```powershell
# Reboot to advanced startup
shutdown /r /o /t 0

# After reboot:
# Troubleshoot → Advanced options → Startup settings → Restart → Press F7
# (Disable driver signature enforcement)
```

### Solution 3: EV Code Signing Certificate (Production)

For production deployment without disabling Secure Boot:

1. Purchase an **EV Code Signing Certificate** from a trusted CA:
   - China: 阿里云 (~¥6,000/yr), 沃通 (~¥4,888/yr)
   - International: DigiCert, Sectigo, GlobalSign (~$300-500/yr)

2. Sign the driver with EV certificate
3. Submit to Microsoft WHQL certification
4. Driver will load on any Windows system without test mode

### Manual Signing (if needed)

The build script automatically creates a test certificate and signs the driver. For manual signing:

```powershell
# Run the signing script separately
.\sign.ps1

# Or manually:
makecert -r -pe -ss PrivateCertStore -n "CN=GreenBoostTestCert" GreenBoostTest.cer
certmgr /add GreenBoostTest.cer /s /r localMachine root
certmgr /add GreenBoostTest.cer /s /r localMachine trustedpublisher
signtool sign /s PrivateCertStore /n "GreenBoostTestCert" /fd sha256 build\driver\Release\greenboost_win.sys
```

## Installation

```powershell
# As Administrator
cd windows-port\tools
.\install.ps1

# Options:
.\install.ps1 -SkipDriver     # Install shim only (no driver)
.\install.ps1 -SkipShim       # Install driver only
.\install.ps1 -Force          # Force install even without test signing
.\install.ps1 -Uninstall      # Remove GreenBoost
```

## Verification

```powershell
# Run IOCTL tests (driver must be loaded)
.\tools\outputs\test_ioctl.exe

# Run diagnostics
.\tools\diagnose.ps1

# Check driver status
sc query GreenBoost

# Check test signing status
bcdedit | findstr testsigning
```

## Troubleshooting

### Build Errors

| Error | Solution |
|-------|----------|
| `Cannot find source file: greenboost_cuda_shim_win.c` | Ensure you're in `windows-port/` directory |
| `DETOURS_LIBRARY_RELEASE-NOTFOUND` | Install Detours via vcpkg or use IAT fallback |
| `wdm.lib not found` | Install WDK from Visual Studio Installer |
| `BufferOverflowK.lib not found` | WDK version mismatch, update WDK |

### Driver Installation Errors

| Error | Solution |
|-------|----------|
| `Test signing is NOT enabled` | Disable Secure Boot, then `bcdedit /set testsigning on` |
| `该值受安全引导策略保护` | Disable Secure Boot in BIOS |
| `Driver installation failed` | Check driver signature with `signtool verify /pa driver.sys` |

### Runtime Errors

| Error | Solution |
|-------|----------|
| CUDA applications don't see extended VRAM | Ensure shim DLL is injected via `withdll.exe` |
| `cudaMalloc` returns out of memory | Check driver is loaded: `sc query GreenBoost` |
| BSOD when loading driver | Check kernel logs: `!analyze -v` in WinDbg |

## Directory Structure

```
windows-port/
├── build.ps1           # Main build script
├── sign.ps1            # Driver signing script
├── CMakeLists.txt      # Top-level CMake config
├── driver/             # KMDF driver source
│   ├── CMakeLists.txt
│   ├── greenboost_win.c
│   ├── greenboost_win.h
│   └── greenboost_win.inf
├── shim/               # CUDA shim DLL source
│   ├── CMakeLists.txt
│   └── greenboost_cuda_shim_win.c
├── tests/              # Test utilities
│   └── test_ioctl.c
├── tools/
│   ├── install.ps1     # Installation script
│   ├── diagnose.ps1    # Diagnostics script
│   └── outputs/        # Build artifacts (generated)
└── BUILDING.md         # This file
```

## Workflow Summary

```
1. build.ps1
   ├── [1/5] Clean build directory
   ├── [2/5] Configure CMake
   ├── [3/5] Build all targets
   ├── [4/5] Sign driver (sign.ps1)
   └── [5/5] Collect outputs to tools/outputs/

2. install.ps1
   ├── Detect hardware (GPU, RAM, NVMe)
   ├── Configure registry settings
   ├── Install driver (requires test signing)
   └── Setup shim injection for LM Studio/Ollama
```
