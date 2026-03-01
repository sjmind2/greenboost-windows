/*
 * GreenBoost v2.0 — CUDA LD_PRELOAD memory shim
 *
 * Intercepts CUDA memory allocations and routes large allocations to
 * GreenBoost DDR4 via DMA-BUF + cudaImportExternalMemory (primary path)
 * or cuMemAllocManaged UVM (fallback).  Exposes combined 12 GB VRAM +
 * 51 GB DDR4 pool to CUDA applications without code changes.
 *
 * USAGE:
 *   LD_PRELOAD=/usr/local/lib/libgreenboost_cuda.so  ./your_cuda_app
 *
 * ENVIRONMENT VARIABLES:
 *   GREENBOOST_USE_DMA_BUF    1 = use DMA-BUF import (default), 0 = UVM only
 *   GREENBOOST_VRAM_HEADROOM_MB  keep ≥ this many MB free in VRAM (default 1024)
 *   GREENBOOST_DEBUG          1 = verbose logging to stderr
 *
 * PREREQUISITES:
 *   greenboost.ko loaded:   sudo insmod greenboost.ko
 *   nvidia_uvm.ko loaded:   sudo modprobe nvidia_uvm
 *
 * Author  : Ferran Duarri
 * License : GPL v2
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <pthread.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>

#include "greenboost_ioctl.h"   /* gb_alloc_req, GB_IOCTL_ALLOC — userspace-safe */

/* ------------------------------------------------------------------ */
/*  Minimal CUDA type definitions (no CUDA SDK headers needed)         */
/* ------------------------------------------------------------------ */

typedef unsigned long long CUdeviceptr;
typedef int                CUresult;
typedef int                cudaError_t;
typedef unsigned int       CUmemAttach_flags;
typedef struct CUstream_st *CUstream;
typedef CUstream            cudaStream_t;

#define CUDA_SUCCESS                0
#define CUDA_ERROR_NOT_SUPPORTED    801
#define CUDA_ERROR_OUT_OF_MEMORY    2
#define CU_MEM_ATTACH_GLOBAL        0x1u
#define CU_MEM_ATTACH_HOST          0x2u

/* cudaExternalMemory types (runtime API, no SDK needed) */
typedef void *cudaExternalMemory_t;

typedef enum {
    cudaExternalMemoryHandleTypeOpaqueFd = 1,
} cudaExternalMemoryHandleType;

struct cudaExternalMemoryHandleDesc {
    cudaExternalMemoryHandleType type;
    union {
        int fd;
        struct { void *handle; const char *name; } win32;
    } handle;
    unsigned long long size;
    unsigned int flags;
};

struct cudaExternalMemoryBufferDesc {
    unsigned long long offset;
    unsigned long long size;
    unsigned int flags;
};

/* ------------------------------------------------------------------ */
/*  Open-addressed hash map — replaces alloc_table[65536]              */
/*  131072 slots × 64 bytes = 8 MB, aligned for cache-line access      */
/* ------------------------------------------------------------------ */

#define HT_BITS   17u
#define HT_SIZE   (1u << HT_BITS)
#define HT_MASK   (HT_SIZE - 1u)
#define HT_LOCKS  64u

typedef struct {
    CUdeviceptr           ptr;          /* 8 B  — 0 = empty slot         */
    size_t                size;         /* 8 B                            */
    int                   is_managed;   /* 4 B  — 1 = UVM, 0 = device    */
    int                   gb_buf_id;    /* 4 B  — -1 if not DMA-BUF      */
    cudaExternalMemory_t  ext_mem;      /* 8 B  — non-NULL if imported    */
    uint8_t               _pad[32];     /* pad to 64 bytes                */
} __attribute__((aligned(64))) gb_ht_entry_t;

static gb_ht_entry_t      gb_htable[HT_SIZE];
static pthread_mutex_t    ht_locks[HT_LOCKS];

static inline uint32_t ht_hash(CUdeviceptr ptr)
{
    /* Fibonacci hash — good distribution for pointer-sized keys */
    return (uint32_t)((ptr * 0x9E3779B97F4A7C15ULL) >> (64 - HT_BITS));
}

static inline pthread_mutex_t *ht_lock(uint32_t h)
{
    return &ht_locks[h & (HT_LOCKS - 1u)];
}

/* Returns 1 on success, 0 if table is full. */
static int ht_insert(CUdeviceptr ptr, size_t size, int is_managed,
                     int gb_buf_id, cudaExternalMemory_t ext_mem)
{
    uint32_t h = ht_hash(ptr);
    uint32_t i;
    for (i = 0; i < HT_SIZE; i++) {
        gb_ht_entry_t *e = &gb_htable[(h + i) & HT_MASK];
        pthread_mutex_t *lk = ht_lock((h + i) & HT_MASK);
        pthread_mutex_lock(lk);
        if (e->ptr == 0) {
            e->ptr        = ptr;
            e->size       = size;
            e->is_managed = is_managed;
            e->gb_buf_id  = gb_buf_id;
            e->ext_mem    = ext_mem;
            pthread_mutex_unlock(lk);
            return 1;
        }
        pthread_mutex_unlock(lk);
    }
    return 0; /* table full */
}

/* Returns 1 if found, fills *out_size, *out_managed, *out_ext_mem. */
static int ht_remove(CUdeviceptr ptr, size_t *out_size, int *out_managed,
                     cudaExternalMemory_t *out_ext_mem)
{
    uint32_t h = ht_hash(ptr);
    uint32_t i;
    for (i = 0; i < HT_SIZE; i++) {
        gb_ht_entry_t *e = &gb_htable[(h + i) & HT_MASK];
        pthread_mutex_t *lk = ht_lock((h + i) & HT_MASK);
        pthread_mutex_lock(lk);
        if (e->ptr == ptr) {
            if (out_size)     *out_size     = e->size;
            if (out_managed)  *out_managed  = e->is_managed;
            if (out_ext_mem)  *out_ext_mem  = e->ext_mem;
            memset(e, 0, sizeof(*e));
            pthread_mutex_unlock(lk);
            return 1;
        }
        pthread_mutex_unlock(lk);
        if (e->ptr == 0)
            break; /* empty slot — key not present */
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/*  Function pointer types                                              */
/* ------------------------------------------------------------------ */

typedef CUresult    (*pfn_cuMemAlloc_v2)(CUdeviceptr *, size_t);
typedef CUresult    (*pfn_cuMemFree_v2)(CUdeviceptr);
typedef CUresult    (*pfn_cuMemAllocManaged)(CUdeviceptr *, size_t, CUmemAttach_flags);
typedef CUresult    (*pfn_cuMemGetInfo)(size_t *, size_t *);
typedef CUresult    (*pfn_cuMemAllocAsync)(CUdeviceptr *, size_t, CUstream);
typedef cudaError_t (*pfn_cudaMalloc)(void **, size_t);
typedef cudaError_t (*pfn_cudaFree)(void *);
typedef cudaError_t (*pfn_cudaMallocManaged)(void **, size_t, unsigned int);
typedef cudaError_t (*pfn_cudaMallocAsync)(void **, size_t, cudaStream_t);
typedef cudaError_t (*pfn_cudaImportExternalMemory)(cudaExternalMemory_t *,
                                                    const struct cudaExternalMemoryHandleDesc *);
typedef cudaError_t (*pfn_cudaExternalMemoryGetMappedBuffer)(void **, cudaExternalMemory_t,
                                                             const struct cudaExternalMemoryBufferDesc *);
typedef cudaError_t (*pfn_cudaDestroyExternalMemory)(cudaExternalMemory_t);

/* ------------------------------------------------------------------ */
/*  Global state                                                        */
/* ------------------------------------------------------------------ */

static pfn_cuMemAlloc_v2                   real_cuMemAlloc_v2;
static pfn_cuMemFree_v2                    real_cuMemFree_v2;
static pfn_cuMemAllocManaged               real_cuMemAllocManaged;
static pfn_cuMemGetInfo                    real_cuMemGetInfo;
static pfn_cuMemAllocAsync                 real_cuMemAllocAsync;
static pfn_cudaMalloc                      real_cudaMalloc;
static pfn_cudaFree                        real_cudaFree;
static pfn_cudaMallocManaged               real_cudaMallocManaged;
static pfn_cudaMallocAsync                 real_cudaMallocAsync;
static pfn_cudaImportExternalMemory        real_cudaImportExternalMemory;
static pfn_cudaExternalMemoryGetMappedBuffer real_cudaExternalMemoryGetMappedBuffer;
static pfn_cudaDestroyExternalMemory       real_cudaDestroyExternalMemory;

static size_t vram_headroom_bytes = 1024ULL * 1024 * 1024; /* 1 GB */
static int    gb_debug            = 0;
static int    gb_use_dmabuf       = 1;
static int    initialized         = 0;

/* /dev/greenboost fd — opened lazily on first DMA-BUF allocation */
static int        gb_dev_fd       = -1;
static pthread_mutex_t gb_dev_lock = PTHREAD_MUTEX_INITIALIZER;

#define gb_log(fmt, ...) \
    do { if (gb_debug) fprintf(stderr, "[GreenBoost] " fmt "\n", ##__VA_ARGS__); } while (0)

/* ------------------------------------------------------------------ */
/*  GreenBoost /dev/greenboost helper                                  */
/* ------------------------------------------------------------------ */

static int gb_open_device(void)
{
    pthread_mutex_lock(&gb_dev_lock);
    if (gb_dev_fd < 0) {
        gb_dev_fd = open("/dev/greenboost", O_RDWR | O_CLOEXEC);
        if (gb_dev_fd < 0)
            fprintf(stderr, "[GreenBoost] Cannot open /dev/greenboost: %m\n");
    }
    pthread_mutex_unlock(&gb_dev_lock);
    return gb_dev_fd;
}

/* ------------------------------------------------------------------ */
/*  DMA-BUF import path: allocate DDR4 via GreenBoost, import as CUDA  */
/* ------------------------------------------------------------------ */

static CUresult gb_import_as_cuda_ptr(CUdeviceptr *dptr, size_t bytesize,
                                       cudaExternalMemory_t *ext_out)
{
    struct gb_alloc_req req;
    struct cudaExternalMemoryHandleDesc hdesc;
    struct cudaExternalMemoryBufferDesc bdesc;
    cudaExternalMemory_t ext_mem;
    void *mapped_ptr;
    int fd, ret;

    if (!real_cudaImportExternalMemory || !real_cudaExternalMemoryGetMappedBuffer)
        return CUDA_ERROR_NOT_SUPPORTED;

    fd = gb_open_device();
    if (fd < 0)
        return CUDA_ERROR_NOT_SUPPORTED;

    memset(&req, 0, sizeof(req));
    req.size  = bytesize;
    req.flags = GB_ALLOC_WEIGHTS;

    if (ioctl(fd, GB_IOCTL_ALLOC, &req) < 0) {
        gb_log("GB_IOCTL_ALLOC failed for %zu MB: %m", bytesize >> 20);
        return CUDA_ERROR_OUT_OF_MEMORY;
    }

    /* Import DMA-BUF fd as CUDA external memory.
     * cudaImportExternalMemory with OpaqueFd takes ownership of the fd. */
    memset(&hdesc, 0, sizeof(hdesc));
    hdesc.type        = cudaExternalMemoryHandleTypeOpaqueFd;
    hdesc.handle.fd   = req.fd;
    hdesc.size        = bytesize;

    ret = real_cudaImportExternalMemory(&ext_mem, &hdesc);
    if (ret != CUDA_SUCCESS) {
        gb_log("cudaImportExternalMemory failed ret=%d for %zu MB", ret, bytesize >> 20);
        close(req.fd); /* fd not consumed on failure */
        return CUDA_ERROR_OUT_OF_MEMORY;
    }

    memset(&bdesc, 0, sizeof(bdesc));
    bdesc.size = bytesize;

    ret = real_cudaExternalMemoryGetMappedBuffer(&mapped_ptr, ext_mem, &bdesc);
    if (ret != CUDA_SUCCESS) {
        gb_log("cudaExternalMemoryGetMappedBuffer failed ret=%d", ret);
        real_cudaDestroyExternalMemory(ext_mem);
        return CUDA_ERROR_OUT_OF_MEMORY;
    }

    *dptr    = (CUdeviceptr)(uintptr_t)mapped_ptr;
    *ext_out = ext_mem;
    gb_log("DMA-BUF import: %zu MB at cuda_ptr=0x%llx", bytesize >> 20,
           (unsigned long long)*dptr);
    return CUDA_SUCCESS;
}

/* ------------------------------------------------------------------ */
/*  Constructor — runs before main()                                    */
/* ------------------------------------------------------------------ */

__attribute__((constructor))
static void gb_shim_init(void)
{
    void *libcuda, *libcudart = NULL;
    const char *env;
    uint32_t i;

    env = getenv("GREENBOOST_USE_DMA_BUF");
    if (env) gb_use_dmabuf = (env[0] != '0');

    env = getenv("GREENBOOST_VRAM_HEADROOM_MB");
    if (env) vram_headroom_bytes = (size_t)atoll(env) * 1024ULL * 1024ULL;

    env = getenv("GREENBOOST_DEBUG");
    if (env && env[0] == '1') gb_debug = 1;

    /* Initialize lock arrays */
    for (i = 0; i < HT_LOCKS; i++)
        pthread_mutex_init(&ht_locks[i], NULL);

    libcuda = dlopen("libcuda.so.1", RTLD_NOW | RTLD_GLOBAL);
    if (!libcuda) {
        fprintf(stderr, "[GreenBoost] WARNING: cannot open libcuda.so.1: %s\n", dlerror());
        return;
    }

    /* libcudart is Ollama-bundled — try versioned/Ollama-specific paths */
    {
        static const char *cudart_paths[] = {
            "libcudart.so",
            "libcudart.so.13",
            "libcudart.so.12",
            "/usr/local/lib/ollama/cuda_v13/libcudart.so.13.0.96",
            "/usr/local/lib/ollama/mlx_cuda_v13/libcudart.so",
            "/usr/local/lib/ollama/cuda_v12/libcudart.so.12",
            NULL
        };
        const char **p;
        for (p = cudart_paths; *p && !libcudart; p++) {
            libcudart = dlopen(*p, RTLD_NOW | RTLD_GLOBAL);
            if (libcudart)
                fprintf(stderr, "[GreenBoost] libcudart loaded: %s\n", *p);
        }
        if (!libcudart)
            fprintf(stderr, "[GreenBoost] WARNING: libcudart not found — runtime API resolved lazily\n");
    }

    /* Driver API (cu*) — always from libcuda.so.1 */
    real_cuMemAlloc_v2     = (pfn_cuMemAlloc_v2)     dlsym(libcuda, "cuMemAlloc_v2");
    real_cuMemFree_v2      = (pfn_cuMemFree_v2)      dlsym(libcuda, "cuMemFree_v2");
    real_cuMemAllocManaged = (pfn_cuMemAllocManaged)  dlsym(libcuda, "cuMemAllocManaged");
    real_cuMemAllocAsync   = (pfn_cuMemAllocAsync)    dlsym(libcuda, "cuMemAllocAsync");
    real_cuMemGetInfo      = (pfn_cuMemGetInfo)       dlsym(libcuda, "cuMemGetInfo_v2");
    if (!real_cuMemGetInfo)
        real_cuMemGetInfo  = (pfn_cuMemGetInfo)       dlsym(libcuda, "cuMemGetInfo");

    /* Runtime API (cuda*) — live in libcudart, not libcuda */
    if (libcudart) {
        real_cudaMalloc        = (pfn_cudaMalloc)        dlsym(libcudart, "cudaMalloc");
        real_cudaFree          = (pfn_cudaFree)           dlsym(libcudart, "cudaFree");
        real_cudaMallocManaged = (pfn_cudaMallocManaged)  dlsym(libcudart, "cudaMallocManaged");
        real_cudaMallocAsync   = (pfn_cudaMallocAsync)    dlsym(libcudart, "cudaMallocAsync");

        real_cudaImportExternalMemory        = (pfn_cudaImportExternalMemory)
            dlsym(libcudart, "cudaImportExternalMemory");
        real_cudaExternalMemoryGetMappedBuffer = (pfn_cudaExternalMemoryGetMappedBuffer)
            dlsym(libcudart, "cudaExternalMemoryGetMappedBuffer");
        real_cudaDestroyExternalMemory       = (pfn_cudaDestroyExternalMemory)
            dlsym(libcudart, "cudaDestroyExternalMemory");
    }
    /* Fallback: some CUDA versions export runtime wrappers from libcuda.so.1 */
    if (!real_cudaMalloc)        real_cudaMalloc        = (pfn_cudaMalloc)        dlsym(libcuda, "cudaMalloc");
    if (!real_cudaFree)          real_cudaFree          = (pfn_cudaFree)           dlsym(libcuda, "cudaFree");
    if (!real_cudaMallocManaged) real_cudaMallocManaged = (pfn_cudaMallocManaged)  dlsym(libcuda, "cudaMallocManaged");
    if (!real_cudaMallocAsync)   real_cudaMallocAsync   = (pfn_cudaMallocAsync)    dlsym(libcuda, "cudaMallocAsync");

    if (!real_cuMemAlloc_v2 || !real_cuMemFree_v2) {
        fprintf(stderr, "[GreenBoost] WARNING: failed to resolve core CUDA symbols\n");
        return;
    }

    initialized = 1;

    fprintf(stderr, "[GreenBoost] v2.0 loaded — vram_headroom=%zuMB use_dmabuf=%d debug=%d\n",
            vram_headroom_bytes >> 20, gb_use_dmabuf, gb_debug);
    fprintf(stderr, "[GreenBoost] DMA-BUF import   : %s\n",
            (real_cudaImportExternalMemory && gb_use_dmabuf) ? "available" : "disabled");
    fprintf(stderr, "[GreenBoost] UVM overflow      : %s\n",
            real_cuMemAllocManaged ? "available" : "unavailable (load nvidia_uvm)");
    fprintf(stderr, "[GreenBoost] Async alloc hooks : cuMemAllocAsync=%s cudaMallocAsync=%s\n",
            real_cuMemAllocAsync ? "hooked" : "missing",
            real_cudaMallocAsync ? "hooked" : "missing");
    fprintf(stderr, "[GreenBoost] Combined VRAM     : 12 GB physical + 51 GB DDR4 via GreenBoost\n");
}

/* ------------------------------------------------------------------ */
/*  Destructor                                                          */
/* ------------------------------------------------------------------ */

__attribute__((destructor))
static void gb_shim_fini(void)
{
    if (gb_dev_fd >= 0) {
        close(gb_dev_fd);
        gb_dev_fd = -1;
    }
    gb_log("shim unloaded");
}

/* ------------------------------------------------------------------ */
/*  VRAM-aware overflow decision                                        */
/* ------------------------------------------------------------------ */

static int gb_needs_overflow(size_t bytesize)
{
    size_t free_vram = 0, total_vram = 0;

    if (!real_cuMemGetInfo)
        return 0;

    if (real_cuMemGetInfo(&free_vram, &total_vram) != CUDA_SUCCESS)
        return 0;

    if (bytesize + vram_headroom_bytes > free_vram) {
        gb_log("VRAM: req=%zuMB free=%zuMB headroom=%zuMB → OVERFLOW to DDR4",
               bytesize >> 20, free_vram >> 20, vram_headroom_bytes >> 20);
        return 1;
    }
    gb_log("VRAM: req=%zuMB free=%zuMB → fits", bytesize >> 20, free_vram >> 20);
    return 0;
}

/* Try DMA-BUF path first, fall back to UVM */
static CUresult gb_overflow_alloc(CUdeviceptr *dptr, size_t bytesize)
{
    cudaExternalMemory_t ext_mem = NULL;
    CUresult ret;

    if (gb_use_dmabuf && real_cudaImportExternalMemory) {
        ret = gb_import_as_cuda_ptr(dptr, bytesize, &ext_mem);
        if (ret == CUDA_SUCCESS) {
            ht_insert(*dptr, bytesize, 0 /* not UVM */, -1, ext_mem);
            return CUDA_SUCCESS;
        }
        gb_log("DMA-BUF import failed (ret=%d), falling back to UVM", ret);
    }

    if (!real_cuMemAllocManaged)
        return CUDA_ERROR_OUT_OF_MEMORY;

    ret = real_cuMemAllocManaged(dptr, bytesize, CU_MEM_ATTACH_GLOBAL);
    if (ret == CUDA_SUCCESS)
        ht_insert(*dptr, bytesize, 1 /* UVM */, -1, NULL);
    return ret;
}

/* ------------------------------------------------------------------ */
/*  cuMemAlloc_v2 override                                              */
/* ------------------------------------------------------------------ */

CUresult cuMemAlloc_v2(CUdeviceptr *dptr, size_t bytesize)
{
    CUresult ret;

    if (!initialized || !real_cuMemAlloc_v2)
        return CUDA_ERROR_OUT_OF_MEMORY;

    if (gb_needs_overflow(bytesize)) {
        ret = gb_overflow_alloc(dptr, bytesize);
        if (ret == CUDA_SUCCESS)
            return CUDA_SUCCESS;
        gb_log("overflow alloc failed (ret=%d), falling back to device alloc", ret);
    }

    ret = real_cuMemAlloc_v2(dptr, bytesize);
    if (ret == CUDA_SUCCESS)
        ht_insert(*dptr, bytesize, 0, -1, NULL);
    return ret;
}

/* ------------------------------------------------------------------ */
/*  cuMemFree_v2 override                                               */
/* ------------------------------------------------------------------ */

CUresult cuMemFree_v2(CUdeviceptr dptr)
{
    cudaExternalMemory_t ext_mem = NULL;
    size_t sz = 0;
    int managed = 0;

    if (!initialized || !real_cuMemFree_v2)
        return CUDA_SUCCESS;

    if (ht_remove(dptr, &sz, &managed, &ext_mem)) {
        gb_log("cuMemFree_v2 ptr=0x%llx size=%zu MB managed=%d ext_mem=%p",
               (unsigned long long)dptr, sz >> 20, managed, ext_mem);
        if (ext_mem && real_cudaDestroyExternalMemory)
            real_cudaDestroyExternalMemory(ext_mem);
    }

    return real_cuMemFree_v2(dptr);
}

/* ------------------------------------------------------------------ */
/*  cuMemAllocAsync override (CUDA 11.2+ stream-ordered allocator)      */
/* ------------------------------------------------------------------ */

CUresult cuMemAllocAsync(CUdeviceptr *dptr, size_t bytesize, CUstream hStream)
{
    CUresult ret;

    if (!initialized)
        return CUDA_ERROR_OUT_OF_MEMORY;

    /* Fall back to sync cuMemAlloc_v2 if async driver API not available */
    if (!real_cuMemAllocAsync)
        return cuMemAlloc_v2(dptr, bytesize);

    if (gb_needs_overflow(bytesize)) {
        ret = gb_overflow_alloc(dptr, bytesize);
        if (ret == CUDA_SUCCESS)
            return CUDA_SUCCESS;
    }

    ret = real_cuMemAllocAsync(dptr, bytesize, hStream);
    if (ret == CUDA_SUCCESS)
        ht_insert(*dptr, bytesize, 0, -1, NULL);
    return ret;
}

/* ------------------------------------------------------------------ */
/*  cudaMalloc override                                                 */
/* ------------------------------------------------------------------ */

cudaError_t cudaMalloc(void **devPtr, size_t size)
{
    cudaError_t ret;
    CUdeviceptr dptr = 0;

    if (!initialized)
        return (cudaError_t)CUDA_ERROR_OUT_OF_MEMORY;

    /* Lazy resolve: libcudart may have been loaded by caller after our constructor.
     * RTLD_NEXT skips our own symbol and finds the real one in the next library. */
    if (!real_cudaMalloc)
        real_cudaMalloc = (pfn_cudaMalloc)dlsym(RTLD_NEXT, "cudaMalloc");
    if (!real_cudaMalloc)
        return (cudaError_t)CUDA_ERROR_OUT_OF_MEMORY;

    if (gb_needs_overflow(size)) {
        ret = (cudaError_t)gb_overflow_alloc(&dptr, size);
        if (ret == CUDA_SUCCESS) {
            *devPtr = (void *)(uintptr_t)dptr;
            return CUDA_SUCCESS;
        }
        gb_log("cudaMalloc overflow failed (ret=%d), falling back", ret);
    }

    ret = real_cudaMalloc(devPtr, size);
    if (ret == CUDA_SUCCESS)
        ht_insert((CUdeviceptr)(uintptr_t)*devPtr, size, 0, -1, NULL);
    return ret;
}

/* ------------------------------------------------------------------ */
/*  cudaMallocAsync override                                            */
/* ------------------------------------------------------------------ */

cudaError_t cudaMallocAsync(void **devPtr, size_t size, cudaStream_t stream)
{
    cudaError_t ret;
    CUdeviceptr dptr = 0;

    if (!initialized)
        return (cudaError_t)CUDA_ERROR_OUT_OF_MEMORY;

    /* Lazy resolve: RTLD_NEXT skips our own symbol, finds real cudaMallocAsync in libcudart */
    if (!real_cudaMallocAsync)
        real_cudaMallocAsync = (pfn_cudaMallocAsync)dlsym(RTLD_NEXT, "cudaMallocAsync");

    /* Fall back to sync cudaMalloc (stream ordering ignored — safe for model weights) */
    if (!real_cudaMallocAsync)
        return cudaMalloc(devPtr, size);

    if (gb_needs_overflow(size)) {
        ret = (cudaError_t)gb_overflow_alloc(&dptr, size);
        if (ret == CUDA_SUCCESS) {
            *devPtr = (void *)(uintptr_t)dptr;
            return CUDA_SUCCESS;
        }
    }

    ret = real_cudaMallocAsync(devPtr, size, stream);
    if (ret == CUDA_SUCCESS)
        ht_insert((CUdeviceptr)(uintptr_t)*devPtr, size, 0, -1, NULL);
    return ret;
}

/* ------------------------------------------------------------------ */
/*  cudaFree override                                                   */
/* ------------------------------------------------------------------ */

cudaError_t cudaFree(void *devPtr)
{
    cudaExternalMemory_t ext_mem = NULL;
    size_t sz = 0;
    int managed = 0;
    CUdeviceptr dptr = (CUdeviceptr)(uintptr_t)devPtr;

    if (!initialized)
        return CUDA_SUCCESS; /* free before init: no-op is safe */

    if (!real_cudaFree)
        real_cudaFree = (pfn_cudaFree)dlsym(RTLD_NEXT, "cudaFree");
    if (!real_cudaFree)
        return CUDA_SUCCESS;

    if (ht_remove(dptr, &sz, &managed, &ext_mem)) {
        gb_log("cudaFree ptr=0x%llx size=%zu MB managed=%d ext_mem=%p",
               (unsigned long long)dptr, sz >> 20, managed, ext_mem);
        if (ext_mem && real_cudaDestroyExternalMemory)
            real_cudaDestroyExternalMemory(ext_mem);
    }

    return real_cudaFree(devPtr);
}
