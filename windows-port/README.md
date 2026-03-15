# GreenBoost Windows Port

**Forked from [gitlab.com/IsolatedOctopi/nvidia_greenboost](https://gitlab.com/IsolatedOctopi/nvidia_greenboost)**

Original work by **Ferran Duarri** (GPL v2). Windows port by Chris Zuger / denoflore.

## What Is This?

GreenBoost is an open-source Linux kernel module that transparently extends NVIDIA GPU VRAM with system RAM and NVMe storage. It lets you run LLMs that are larger than your GPU's physical VRAM without the catastrophic speed penalty of standard CPU offloading.

This fork adds a **Windows port** consisting of:

- **KMDF driver** (`greenboost.sys`) replacing the Linux kernel module
- **CUDA proxy DLL** (`greenboost_cuda.dll`) replacing the LD_PRELOAD shim
- **PowerShell installer** replacing the bash setup scripts

## Architecture

The core insight that makes this port tractable: the CUDA memory registration path is platform-independent.

**Linux flow:**
```
kernel alloc_pages -> DMA-BUF fd -> mmap -> cuMemHostRegister -> cuMemHostGetDevicePointer
```

**Windows flow:**
```
driver MmAllocateContiguous -> Section handle -> MapViewOfFile -> cuMemHostRegister -> cuMemHostGetDevicePointer
```

Same CUDA calls. Different backing memory source. Everything else is plumbing.

## Status

**In Development** -- See `windows-port/CC_INSTRUCTIONS.md` for the full build spec.

## Original Project

All credit to Ferran Duarri for the original GreenBoost architecture and implementation. The Linux source in this repo is unmodified from the upstream GitLab repository.

## License

GPL v2, matching upstream. Attribution to Ferran Duarri required per license terms.
