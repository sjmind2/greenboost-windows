# BUILD NOW — GreenBoost Windows Port

## EXECUTION PATTERN

**Follow this iterative pattern:**
1. Read a section of this file
2. Build what that section specifies — WRITE THE ACTUAL CODE FILES
3. Test/validate what you built (compile check, syntax check)
4. Read the file AGAIN to find where you are
5. Continue to next section
6. Repeat until complete

**DO NOT just review or refine docs. WRITE CODE. CREATE FILES. BUILD THE PROJECT.**

---

## CONTEXT

The spec has already been reviewed and refined. All architecture decisions are made. The reviewed spec is at `windows-port/CC_INSTRUCTIONS.md` in this repo. The original Linux source is in the repo root (`greenboost.c`, `greenboost_cuda_shim.c`, `greenboost_ioctl.h`, `architecture.md`).

Your job: **execute the 6-phase build plan and produce compilable source code.**

---

## REQUIRED READING — DO THIS FIRST

Before writing ANY code, read these files completely:

1. **`windows-port/CC_INSTRUCTIONS.md`** — The full reviewed build spec. This is your blueprint. Follow it.
2. **`greenboost_ioctl.h`** — The IOCTL interface contract
3. **`greenboost.c`** — Linux kernel module (port source)
4. **`greenboost_cuda_shim.c`** — Linux CUDA shim (port source)
5. **`architecture.md`** — Architecture reference

After reading, proceed to Phase 1 below.

**After reading all required files, read this document again to find Phase 1.**

---

## Phase 1: Create Project Structure + Windows IOCTL Header

**ACTION: Create these files and directories.**

Create the directory structure:
```
windows-port/
  driver/
    greenboost_ioctl_win.h
    greenboost_win.h
    greenboost_win.c
    greenboost_win.inf
    CMakeLists.txt
  shim/
    greenboost_cuda_shim_win.h
    greenboost_cuda_shim_win.c
    greenboost_cuda.def
    CMakeLists.txt
  tools/
    install.ps1
    diagnose.ps1
  tests/
    test_ioctl.c
  CMakeLists.txt
```

**greenboost_ioctl_win.h**: Port `greenboost_ioctl.h` to Windows. Use CTL_CODE macro for IOCTLs. Replace Linux types with Windows types. Change `fd` fields to `HANDLE`. Add explicit `buf_id` return field to `gb_alloc_req`. See CC_INSTRUCTIONS.md "CRITICAL REQUIREMENTS" section for the exact mapping.

**CMakeLists.txt (top-level)**: CMake project that builds both driver and shim subdirectories. Target Windows x64 only.

**Deliverable:** All files created. `greenboost_ioctl_win.h` compiles in both kernel and userspace contexts.

**After completing Phase 1, read this document again to find Phase 2.**

---

## Phase 2: KMDF Driver — Full Implementation

**ACTION: Write the complete driver in `driver/greenboost_win.c`.**

Port `greenboost.c` (1268 lines) to a Windows KMDF driver. Follow the architecture mapping in CC_INSTRUCTIONS.md. Key translations:

- `DriverEntry` + WDF device creation + symbolic link `\\.\GreenBoost`
- `GB_DEVICE_WIN` struct (global state) — port from `struct gb_device`
- `GB_BUF_WIN` struct (per-buffer) — port from `struct gb_buf`
- `GbAllocTier2()` — use `MmAllocateContiguousMemorySpecifyCache` for 2MB blocks
- `GbAllocTier3()` — use standard paged pool allocations
- `GbRelease()` — free memory, remove from IDR/LRU, update counters
- `GbEvtIoDeviceControl()` — IOCTL dispatcher handling all 7 IOCTLs
- Buffer tracking via interlocked ID counter + linked list (replaces Linux IDR)
- LRU list with spinlock (direct port)
- Section object creation for sharing memory with userspace
- All error paths must handle both contiguous and MDL-based cleanup

**driver/greenboost_win.h**: Internal header with struct definitions, function prototypes, debug macros.

**driver/greenboost_win.inf**: Standard KMDF driver INF for device installation.

**driver/CMakeLists.txt**: WDK build configuration.

**Deliverable:** Complete driver source that would compile with WDK. All IOCTLs implemented. Memory allocation and deallocation working.

**After completing Phase 2, read this document again to find Phase 3.**

---

## Phase 3: Watchdog Thread + Memory Pressure

**ACTION: Add watchdog to the driver (can be in same `greenboost_win.c` or a separate file).**

- `PsCreateSystemThread` to create watchdog
- 1-second polling interval via `KeDelayExecutionThread`
- Query memory via `ZwQuerySystemInformation(SystemMemoryListInformation)` or `MmQuerySystemMemoryInformation`
- Compare available RAM against `SafetyReserveGb`
- Update `SwapPressure` and `OomActive` atomics
- Signal named event `\\BaseNamedObjects\\GreenBoostPressure` via `KeSetEvent`
- CPU affinity via `KeSetSystemGroupAffinityThread` (auto-detect P-core mask)
- Clean shutdown on driver unload (`WatchdogRunning = FALSE`, wait for thread exit)

**Deliverable:** Watchdog code integrated into driver. Thread lifecycle managed correctly.

**After completing Phase 3, read this document again to find Phase 4.**

---

## Phase 4: CUDA Shim DLL — Full Implementation

**ACTION: Write the complete shim in `shim/greenboost_cuda_shim_win.c`.**

Port `greenboost_cuda_shim.c` (1143 lines) to Windows. Key translations:

- `DllMain(DLL_PROCESS_ATTACH)` replaces `__attribute__((constructor))`
- Use Microsoft Detours for hooking (or manual IAT patching as fallback)
- Hook these CUDA functions: `cudaMalloc`, `cudaFree`, `cudaMallocAsync`, `cuMemAllocAsync`, `cuMemFree`, `cuDeviceTotalMem_v2`, `cudaMemGetInfo`, `cuMemGetInfo`
- Hook NVML: `nvmlDeviceGetMemoryInfo`, `nvmlDeviceGetMemoryInfo_v2`
- `gb_open_device()` — `CreateFileW(L"\\\\.\\GreenBoost")`
- `gb_alloc_from_driver()` — `DeviceIoControl(GB_IOCTL_ALLOC)` then `MapViewOfFile` then `cuMemHostRegister(DEVICEMAP)` then `cuMemHostGetDevicePointer`
- Hash table — direct port with `CRITICAL_SECTION` replacing `pthread_mutex_t`. FIX the deletion bug: use tombstone markers instead of zeroing.
- Prefetch worker thread — port `pthread_create` to `CreateThread`, `pthread_cond_t` to `CONDITION_VARIABLE`, `madvise(MADV_WILLNEED)` to `PrefetchVirtualMemory`
- VRAM reporting hooks — report `physical_vram + virtual_vram` on total mem queries
- Config from registry: read `HKLM\SOFTWARE\GreenBoost\*` for params
- ALL failures must gracefully fall through to real CUDA. Never crash the host process.

**shim/greenboost_cuda_shim_win.h**: Header with types, function pointers, config.

**shim/greenboost_cuda.def**: DLL exports if using proxy DLL approach.

**shim/CMakeLists.txt**: Build config linking against Detours.

**Deliverable:** Complete shim source. All hooks implemented. Hash table bug fixed. Graceful fallthrough on all error paths.

**After completing Phase 4, read this document again to find Phase 5.**

---

## Phase 5: Tools + Integration

**ACTION: Write the PowerShell installer and diagnostic tools.**

**tools/install.ps1:**
- Detect NVIDIA GPU and VRAM via `nvidia-smi`
- Detect system RAM via `Get-CimInstance Win32_PhysicalMemory`
- Detect NVMe via `Get-PhysicalDisk`
- Detect CPU topology (P/E cores) via `Get-CimInstance Win32_Processor`
- Compute optimal config values (80% of RAM for pool, etc.)
- Write config to registry `HKLM\SOFTWARE\GreenBoost\`
- Install driver via `pnputil` or `devcon`
- Enable test signing if needed (`bcdedit /set testsigning on`)
- Copy shim DLL to appropriate location
- Create LM Studio launcher script that injects the shim

**tools/diagnose.ps1:**
- Check driver loaded (`sc query greenboost`)
- Check device accessible (try `CreateFile \\.\GreenBoost`)
- Query pool info via IOCTL
- Check if shim loaded in target process
- Report VRAM visibility
- Overall health status

**tests/test_ioctl.c:**
- Open `\\.\GreenBoost`
- Call GB_IOCTL_GET_INFO, print stats
- Call GB_IOCTL_ALLOC for various sizes, verify handles
- Free allocations, verify cleanup
- Stress test with rapid alloc/free cycles

**Deliverable:** All tools created and functional.

**After completing Phase 5, read this document again to find Phase 6.**

---

## Phase 6: Documentation + Final Validation

**ACTION: Update README and create remaining docs.**

- Update `windows-port/README.md` with build instructions, dependencies, usage
- Create `windows-port/BUILDING.md` — step-by-step build from source
- Create `windows-port/TROUBLESHOOTING.md` — common issues and fixes
- Review all source files for TODO/FIXME items
- Ensure all files have license headers (GPL v2, attribution to Ferran Duarri)
- Commit everything

**Deliverable:** Complete, documented, buildable project.

---

## SUCCESS CRITERIA

When done, the repo should contain:

- [ ] `windows-port/driver/greenboost_win.c` — Complete KMDF driver (~800-1200 lines)
- [ ] `windows-port/driver/greenboost_win.h` — Driver header
- [ ] `windows-port/driver/greenboost_ioctl_win.h` — Windows IOCTL definitions
- [ ] `windows-port/driver/greenboost_win.inf` — Driver INF
- [ ] `windows-port/shim/greenboost_cuda_shim_win.c` — Complete CUDA shim (~800-1100 lines)
- [ ] `windows-port/shim/greenboost_cuda_shim_win.h` — Shim header
- [ ] `windows-port/tools/install.ps1` — Installer
- [ ] `windows-port/tools/diagnose.ps1` — Diagnostics
- [ ] `windows-port/tests/test_ioctl.c` — IOCTL tests
- [ ] All CMakeLists.txt files present
- [ ] All files have GPL v2 headers with Ferran Duarri attribution
- [ ] README and docs updated
- [ ] Everything committed and pushed
