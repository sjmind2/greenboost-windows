#!/usr/bin/env bash
# GreenBoost v2.3 — Setup & installation script
# Author: Ferran Duarri
# Hardware: ASRock B760M-ITX/D4 | i9-14900KF | RTX 5070 OC | 64 GB DDR4-3600 | Samsung 990 EVO Plus 4 TB
#
# 3-tier memory hierarchy:
#   Tier 1 — RTX 5070 VRAM      12 GB   ~336 GB/s GDDR7  (hot layers)
#   Tier 2 — DDR4 pool          51 GB   ~57.6 GB/s dual-ch (cold layers)
#   Tier 3 — NVMe swap         576 GB   ~7.25 GB/s seq     (frozen pages)
#   Combined capacity          639 GB
#
# USAGE:
#   sudo ./greenboost_setup.sh install          — build + install system-wide
#   sudo ./greenboost_setup.sh uninstall        — remove module + all config
#   sudo ./greenboost_setup.sh load             — insmod with default params
#   sudo ./greenboost_setup.sh unload           — rmmod
#   sudo ./greenboost_setup.sh install-sys-configs — install v2.3 system config files
#   sudo ./greenboost_setup.sh tune             — runtime tuning (governor, NVMe, sysctl)
#   sudo ./greenboost_setup.sh tune-grub        — GRUB/boot parameter optimization
#   sudo ./greenboost_setup.sh tune-sysctl      — consolidate + enhance sysctl (persistent)
#   sudo ./greenboost_setup.sh tune-libs        — install missing AI/compute libraries
#   sudo ./greenboost_setup.sh tune-all         — run all tune-* commands
#        ./greenboost_setup.sh status           — show pool info + system state
#        ./greenboost_setup.sh build            — build only (no install)
#        ./greenboost_setup.sh help             — show this help
#
# ENVIRONMENT (for load command):
#   GPU_PHYS_GB=12     physical VRAM in GB       (RTX 5070 default)
#   VIRT_VRAM_GB=51    DDR4 pool size in GB      (80% of 64 GB DDR4)
#   RESERVE_GB=12      minimum free system RAM to always maintain
#   NVME_SWAP_GB=576   total NVMe swap capacity  (Samsung 990 Evo Plus)
#   NVME_POOL_GB=512   GreenBoost soft cap on T3 allocations

DRIVER_NAME="greenboost"
SHIM_LIB="libgreenboost_cuda.so"
SHIM_DEST="/usr/local/lib"
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colours
RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[1;33m'
BLU='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${GRN}[GreenBoost]${NC} $*"; }
warn()  { echo -e "${YLW}[GreenBoost] WARN:${NC} $*"; }
die()   { echo -e "${RED}[GreenBoost] ERROR:${NC} $*" >&2; exit 1; }

# ---- Helpers -----------------------------------------------------------

need_root() {
    [[ $EUID -eq 0 ]] || die "Root required. Use: sudo $0 $1"
}

check_deps() {
    info "Checking build prerequisites..."
    command -v make >/dev/null || die "make not found (apt install build-essential)"
    command -v gcc  >/dev/null || die "gcc not found (apt install gcc)"
    local kdir="/lib/modules/$(uname -r)/build"
    [[ -d "$kdir" ]] || die "Kernel headers not found at $kdir
    Install with: sudo apt install linux-headers-$(uname -r)"
    info "Kernel headers : $kdir  ✓"

    if lsmod | grep -q "^nvidia "; then
        info "NVIDIA driver  : loaded  ✓"
    else
        warn "NVIDIA driver not loaded — run: sudo modprobe nvidia"
    fi

    if lsmod | grep -q "^nvidia_uvm "; then
        info "NVIDIA UVM     : loaded  ✓  (managed memory / DDR4 overflow ready)"
    else
        warn "nvidia_uvm not loaded — CUDA UVM overflow unavailable"
        warn "Fix: sudo modprobe nvidia_uvm"
    fi
}

# ---- Commands ----------------------------------------------------------

cmd_install_sys_configs() {
    need_root install-sys-configs

    info "Installing GreenBoost v2.3 system configuration files..."

    # 1. Ollama service — inject GreenBoost env vars + LD_PRELOAD
    local svc="/etc/systemd/system/ollama.service"
    if [[ -f "$svc" ]]; then
        # Add environment lines if not already present
        if ! grep -q "GREENBOOST_VRAM_HEADROOM_MB" "$svc"; then
            sed -i '/^\[Service\]/a Environment="OLLAMA_FLASH_ATTENTION=1"\nEnvironment="OLLAMA_KV_CACHE_TYPE=q8_0"\nEnvironment="OLLAMA_NUM_CTX=131072"\nEnvironment="OLLAMA_MAX_LOADED_MODELS=1"\nEnvironment="OLLAMA_KEEP_ALIVE=-1"\nEnvironment="GREENBOOST_VRAM_HEADROOM_MB=1024"\nEnvironment="GREENBOOST_DEBUG=0"\nEnvironment="LD_PRELOAD=/usr/local/lib/libgreenboost_cuda.so"' "$svc"
            info "Ollama service: GreenBoost env vars injected"
        else
            info "Ollama service: already configured (skip)"
        fi
        systemctl daemon-reload
        info "Ollama service: daemon-reload done"
    else
        warn "Ollama service not found at $svc — skipping"
    fi

    # 2. NVMe udev rule — scheduler=none, read_ahead=4096, nr_requests=2048
    cat > /etc/udev/rules.d/99-nvme-greenboost.rules << 'UDEVEOF'
# GreenBoost v2.3 — NVMe tuning for T3 swap performance
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/scheduler}="none"
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/read_ahead_kb}="4096"
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/nr_requests}="2048"
UDEVEOF
    udevadm control --reload-rules && udevadm trigger || true
    info "NVMe udev rule installed: /etc/udev/rules.d/99-nvme-greenboost.rules"

    # 3. CPU governor service — P-cores only (E-cores stay on powersave)
    cat > /etc/systemd/system/cpu-perf.service << 'CPUEOF'
[Unit]
Description=GreenBoost CPU performance governor (P-cores 0-15)
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'for cpu in $(seq 0 15); do echo performance > /sys/devices/system/cpu/cpu${cpu}/cpufreq/scaling_governor; done'
ExecStop=/bin/bash  -c 'for cpu in $(seq 0 15); do echo powersave  > /sys/devices/system/cpu/cpu${cpu}/cpufreq/scaling_governor; done'

[Install]
WantedBy=multi-user.target
CPUEOF
    systemctl daemon-reload
    systemctl enable --now cpu-perf.service
    info "CPU governor service installed and started"

    # 4. Hugepages sysfs.d — 51 GB T2 pool pre-allocated at 2MB
    mkdir -p /etc/sysfs.d
    cat > /etc/sysfs.d/greenboost-hugepages.conf << 'HPEOF'
# GreenBoost v2.3 — T2 pool hugepage pre-allocation
# 51 GB at 2 MB pages = 26112 pages. Allocated at boot before fragmentation.
kernel/mm/hugepages/hugepages-2048kB/nr_hugepages = 26112
kernel/mm/transparent_hugepage/enabled = always
vm/nr_overcommit_hugepages = 4096
HPEOF
    info "Hugepages sysfs conf: /etc/sysfs.d/greenboost-hugepages.conf"

    # Apply hugepages immediately (may fail if system lacks contiguous memory)
    echo 26112 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages 2>/dev/null \
        && info "Hugepages: $(cat /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages) x 2MB allocated" \
        || warn "Hugepages: immediate allocation failed (will apply at next boot)"

    # 5. VM sysctl — reduce swap pressure, tune write-back
    cat > /etc/sysctl.d/99-greenboost.conf << 'SYSCTLEOF'
# GreenBoost v2.3 — VM tuning for 3-tier model pool
vm.swappiness = 5
vm.dirty_ratio = 20
vm.dirty_background_ratio = 5
SYSCTLEOF
    sysctl -p /etc/sysctl.d/99-greenboost.conf 2>&1 | sed 's/^/  /'
    info "sysctl conf installed: /etc/sysctl.d/99-greenboost.conf"

    echo ""
    info "System config installation complete."
    info "Reboot recommended to activate hugepage pre-allocation."
    warn "Restart Ollama to pick up new env vars: sudo systemctl restart ollama"
}

cmd_build() {
    info "Building GreenBoost v2.3 (3-tier: VRAM + DDR4 + NVMe)..."
    make -C "$MODULE_DIR" all || die "Build failed — check output above"
    info "Build complete:"
    info "  Kernel module : $MODULE_DIR/greenboost.ko"
    info "  CUDA shim     : $MODULE_DIR/$SHIM_LIB"
}

cmd_install() {
    need_root install
    check_deps
    cmd_build

    info "Installing kernel module..."
    make -C "$MODULE_DIR" install || die "Module install failed"

    info "Installing CUDA shim to $SHIM_DEST/..."
    cp "$MODULE_DIR/$SHIM_LIB" "$SHIM_DEST/"
    ldconfig

    # modprobe defaults
    info "Writing /etc/modprobe.d/greenboost.conf ..."
    cat > /etc/modprobe.d/greenboost.conf << 'MODEOF'
# GreenBoost v2.3 — 3-tier pool: RTX 5070 VRAM + DDR4 + NVMe swap
# Tier 1: physical_vram_gb=12   RTX 5070 (12 GB GDDR7)
# Tier 2: virtual_vram_gb=51    DDR4 pool (80% of 64 GB, hugepages)
#          safety_reserve_gb=12  always keep ≥12 GB free in RAM
# Tier 3: nvme_swap_gb=576      Samsung 990 Evo Plus NVMe swap capacity
#          nvme_pool_gb=512      GreenBoost soft cap on T3 allocations
options greenboost physical_vram_gb=12 virtual_vram_gb=51 safety_reserve_gb=12 nvme_swap_gb=576 nvme_pool_gb=512
MODEOF

    # profile.d helper
    cat > /etc/profile.d/greenboost.sh << PROFEOF
# GreenBoost v2.3 — shell helpers
export GREENBOOST_SHIM="$SHIM_DEST/$SHIM_LIB"
greenboost-run() { LD_PRELOAD="\$GREENBOOST_SHIM" "\$@"; }
export -f greenboost-run
PROFEOF

    # Standalone wrapper
    cat > /usr/local/bin/greenboost-run << WRAPEOF
#!/usr/bin/env bash
# Run a CUDA application with GreenBoost DDR4 overflow enabled
LD_PRELOAD="$SHIM_DEST/$SHIM_LIB" "\$@"
WRAPEOF
    chmod +x /usr/local/bin/greenboost-run

    info ""
    info "Installation complete!"
    info "  Load module    : sudo modprobe greenboost"
    info "  Run CUDA app   : greenboost-run your_cuda_app"
    info "  Pool status    : cat /sys/class/greenboost/greenboost/pool_info"
}

cmd_load() {
    need_root load
    local phys="${GPU_PHYS_GB:-12}"
    local virt="${VIRT_VRAM_GB:-51}"
    local res="${RESERVE_GB:-12}"
    local nvme_sw="${NVME_SWAP_GB:-576}"
    local nvme_pool="${NVME_POOL_GB:-512}"

    if lsmod | grep -q "^${DRIVER_NAME} "; then
        warn "Module already loaded — reloading..."
        rmmod "$DRIVER_NAME" || die "Failed to unload existing module"
    fi

    local ko="$MODULE_DIR/greenboost.ko"
    [[ -f "$ko" ]] || die "greenboost.ko not found — run: make  or  $0 build"

    insmod "$ko" \
        physical_vram_gb="$phys"  \
        virtual_vram_gb="$virt"   \
        safety_reserve_gb="$res"  \
        nvme_swap_gb="$nvme_sw"   \
        nvme_pool_gb="$nvme_pool" \
        || die "insmod failed — check: dmesg | tail -20"

    info "GreenBoost v2.3 loaded — 3-tier pool active!"
    info ""
    info "  T1 RTX 5070 VRAM : ${phys} GB   ~336 GB/s  [hot layers]"
    info "  T2 DDR4 pool     : ${virt} GB    ~50 GB/s  [cold layers]"
    info "  T3 NVMe swap     : ${nvme_sw} GB  ~1.8 GB/s [frozen pages]"
    info "  ─────────────────────────────────────────"
    info "  Combined view    : $(( phys + virt + nvme_sw )) GB total model capacity"
    info ""
    info "Pool info  : cat /sys/class/greenboost/greenboost/pool_info"
    info "Kernel log : dmesg | grep greenboost"
    echo ""
    dmesg | grep greenboost | tail -8 | sed 's/^/  /'
}

cmd_unload() {
    need_root unload
    if lsmod | grep -q "^${DRIVER_NAME} "; then
        rmmod "$DRIVER_NAME" && info "GreenBoost unloaded" \
            || die "rmmod failed — check: dmesg | tail -5"
    else
        info "GreenBoost is not loaded"
    fi
}

cmd_uninstall() {
    need_root uninstall

    # 1. Unload if running
    if lsmod | grep -q "^${DRIVER_NAME} "; then
        info "Unloading module..."
        rmmod "$DRIVER_NAME" || warn "rmmod failed — continuing cleanup"
    fi

    # 2. Remove installed kernel module
    local ko_path="/lib/modules/$(uname -r)/extra/greenboost.ko"
    local ko_upd="/lib/modules/$(uname -r)/updates/greenboost.ko"
    for f in "$ko_path" "$ko_upd"; do
        if [[ -f "$f" ]]; then
            rm -f "$f" && info "Removed $f"
        fi
    done
    depmod -a && info "depmod updated"

    # 3. Remove CUDA shim
    rm -f "$SHIM_DEST/$SHIM_LIB" && info "Removed $SHIM_DEST/$SHIM_LIB"
    ldconfig

    # 4. Remove config files
    rm -f /etc/modprobe.d/greenboost.conf  && info "Removed modprobe config"
    rm -f /etc/profile.d/greenboost.sh     && info "Removed profile.d entry"
    rm -f /usr/local/bin/greenboost-run    && info "Removed greenboost-run wrapper"
    rm -f /etc/modules-load.d/greenboost.conf && info "Removed modules-load entry"

    info ""
    info "GreenBoost uninstalled cleanly."
}

cmd_tune() {
    need_root tune

    info "Tuning workstation for GreenBoost / LLM workloads..."
    info "Hardware: i9-14900KF | RTX 5070 | DDR4-3600 | Samsung 990 EVO Plus"
    echo ""

    # ── CPU governor → performance (P-cores run at 6 GHz, not 800 MHz) ──
    local changed=0
    for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [[ -w "$gov" ]] && echo performance > "$gov" && changed=1
    done
    [[ $changed -eq 1 ]] && info "CPU governor      : performance (all 32 CPUs)" \
                          || warn "CPU governor      : could not set (check cpufreq driver)"

    # ── NVMe scheduler → none (best latency for Samsung 990 EVO Plus) ──
    for sched in /sys/block/nvme*/queue/scheduler; do
        [[ -w "$sched" ]] && echo none > "$sched" 2>/dev/null || true
    done
    info "NVMe scheduler    : none (was: mq-deadline)"

    # ── NVMe read-ahead → 4 MB (large sequential model weight loading) ──
    for ra in /sys/block/nvme*/queue/read_ahead_kb; do
        [[ -w "$ra" ]] && echo 4096 > "$ra"
    done
    info "NVMe read_ahead   : 4096 KB = 4 MB (was: 128 KB)"

    # ── NVMe nr_requests → 1024 ──────────────────────────────────────────
    for nr in /sys/block/nvme*/queue/nr_requests; do
        [[ -w "$nr" ]] && echo 1024 > "$nr"
    done
    info "NVMe nr_requests  : 1024"

    # ── THP → always (GreenBoost 2 MB hugepage pool requires it) ─────────
    echo always > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
    info "THP               : always"

    # ── vm.swappiness → 10 (prefer RAM; only page to NVMe under pressure) ─
    sysctl -qw vm.swappiness=10
    info "vm.swappiness     : 10 (was default 60)"

    # ── vm.dirty_ratio / background_ratio (reduce write stalls) ──────────
    sysctl -qw vm.dirty_ratio=40
    sysctl -qw vm.dirty_background_ratio=10
    info "vm.dirty_ratio    : 40 / background: 10"

    echo ""
    info "Tuning done. To make permanent add to /etc/sysctl.conf:"
    info "  vm.swappiness=10"
    info "  vm.dirty_ratio=40"
    info "  vm.dirty_background_ratio=10"
    info "And add to /etc/rc.local for NVMe + THP settings."
}

# ---- tune-grub ---------------------------------------------------------
# Validate each candidate flag against the kernel config, then apply.
# Strategy: read-only checks first; only write GRUB if all checks pass.
# Security mitigations are NEVER touched.

_grub_has()  { grep -qw "$1" /proc/cmdline; }
_kcfg_has()  { grep -q "^${1}=y" /boot/config-"$(uname -r)" 2>/dev/null; }

_grub_check_flag() {
    local flag="$1" desc="$2" kcfg="$3"
    if _grub_has "$flag"; then
        info "  [skip]    $flag  — already active"
        return 1
    fi
    if [[ -n "$kcfg" ]] && ! _kcfg_has "$kcfg"; then
        warn "  [skip]    $flag  — kernel not built with $kcfg"
        return 1
    fi
    info "  [add]     $flag  — $desc"
    return 0
}

cmd_tune_grub() {
    need_root tune-grub

    local grub_file="/etc/default/grub"
    local kver; kver="$(uname -r)"
    local kcfg="/boot/config-${kver}"

    [[ -f "$grub_file" ]] || die "GRUB config not found: $grub_file"

    info "Validating GRUB flags for: i9-14900KF | RTX 5070 | Samsung 990 EVO Plus"
    info "Kernel: $kver"
    echo ""

    # Read current GRUB cmdline value
    local current_line
    current_line=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$grub_file" | head -1 | sed 's/^GRUB_CMDLINE_LINUX_DEFAULT=//;s/^"//;s/"$//')

    local new_flags=""

    # ── Flag: transparent_hugepage=always ───────────────────────────────
    # GreenBoost T2 pool allocates 2MB compound pages. THP=always ensures
    # the kernel tries to satisfy those allocs from huge pages at boot.
    # Currently set to 'madvise' in GRUB — change to 'always'.
    if _kcfg_has "CONFIG_TRANSPARENT_HUGEPAGE"; then
        if echo "$current_line" | grep -q "transparent_hugepage=madvise"; then
            info "  [fix]     transparent_hugepage=madvise -> always  (GreenBoost T2 hugepage pool)"
            current_line="${current_line/transparent_hugepage=madvise/transparent_hugepage=always}"
        elif ! _grub_has "transparent_hugepage=always"; then
            info "  [add]     transparent_hugepage=always  (GreenBoost T2 hugepage pool)"
            new_flags="$new_flags transparent_hugepage=always"
        else
            info "  [skip]    transparent_hugepage=always  — already active"
        fi
    fi

    # ── Flag: skew_tick=1 ───────────────────────────────────────────────
    # Staggers per-CPU timer ticks on the i9-14900KF hybrid topology
    # (8 P-cores + 16 E-cores). Reduces lock contention when all 32 CPUs
    # fire timer interrupts simultaneously.
    # Runtime test: always safe — no kernel config dependency.
    _grub_check_flag "skew_tick=1" \
        "stagger timer ticks — reduces lock contention on hybrid P/E cores" "" \
        && new_flags="$new_flags skew_tick=1"

    # ── Flag: rcu_nocbs=16-31 ───────────────────────────────────────────
    # Offloads RCU (Read-Copy-Update) callback processing to E-cores
    # (CPU 16-31, up to 4.4 GHz). Frees the 6 GHz P-cores (0-15) from
    # RCU housekeeping during inference hot paths.
    # Kernel check: CONFIG_RCU_NOCB_CPU=y (confirmed built-in).
    _grub_check_flag "rcu_nocbs=16-31" \
        "offload RCU callbacks to E-cores, freeing P-cores for inference" \
        "CONFIG_RCU_NOCB_CPU" \
        && new_flags="$new_flags rcu_nocbs=16-31"

    # ── Flag: nohz_full=4-7 ─────────────────────────────────────────────
    # Makes the 4 golden P-cores (CPU 4-7, core_id 8+12, 6 GHz TVB boost)
    # tick-less when they have exactly one runnable thread. Combined with
    # rcu_nocbs, this eliminates the 1000 Hz timer interrupt during dense
    # matrix multiplications — directly reduces LLM token latency.
    # Kernel check: CONFIG_NO_HZ_FULL=y (confirmed built-in).
    # Safe: golden cores still handle regular tasks; tick resumes when
    # idle or when >1 task is runnable.
    _grub_check_flag "nohz_full=4-7" \
        "tick-less golden P-cores during single-thread inference (i9 core_id 8+12)" \
        "CONFIG_NO_HZ_FULL" \
        && new_flags="$new_flags nohz_full=4-7"

    # ── Flag: numa_balancing=disable ────────────────────────────────────
    # This workstation has a single NUMA node (all CPUs on node 0).
    # The kernel's automatic NUMA balancing task wastes cycles scanning
    # pages that will never need to move. Already disabled at runtime
    # via sysctl, this makes it persistent across reboots.
    _grub_check_flag "numa_balancing=disable" \
        "single NUMA node — disable page-migration scanning overhead" "" \
        && new_flags="$new_flags numa_balancing=disable"

    # ── Flag: workqueue.power_efficient=0 ──────────────────────────────
    # Kernel workqueues (DMA, NVMe completion, etc.) use power-efficient
    # mode by default, routing work to whichever CPU happens to be awake.
    # Disabling this routes workqueue items to the fastest available CPU
    # (P-core), which matters for DMA-BUF completion and NVMe IRQ paths.
    _grub_check_flag "workqueue.power_efficient=0" \
        "route kernel workqueues to P-cores instead of any-idle CPU" "" \
        && new_flags="$new_flags workqueue.power_efficient=0"

    # ── Fix: deduplicate nvidia-drm.modeset=1 ──────────────────────────
    local count; count=$(echo "$current_line" | grep -o "nvidia-drm.modeset=1" | wc -l)
    if [[ "$count" -gt 1 ]]; then
        info "  [fix]     nvidia-drm.modeset=1 appears ${count}× — deduplicating"
        # Remove all occurrences then add one back
        current_line=$(echo "$current_line" | sed 's/nvidia-drm\.modeset=1//g' | tr -s ' ')
        current_line="$current_line nvidia-drm.modeset=1"
    fi

    # ── Build new cmdline ───────────────────────────────────────────────
    local new_line="${current_line}${new_flags}"
    # Normalise multiple spaces
    new_line=$(echo "$new_line" | tr -s ' ' | sed 's/^ //;s/ $//')

    if [[ "$new_line" == "$current_line" ]] && [[ -z "$new_flags" ]]; then
        info ""
        info "GRUB is already fully optimised — nothing to change."
        return 0
    fi

    echo ""
    info "Current GRUB cmdline:"
    echo "  $current_line" | fold -s -w 100 | sed 's/^/  /'
    echo ""
    info "New GRUB cmdline:"
    echo "  $new_line" | fold -s -w 100 | sed 's/^/  /'
    echo ""

    # ── Backup + write ──────────────────────────────────────────────────
    local bak="${grub_file}.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$grub_file" "$bak"
    info "Backup saved: $bak"

    # Replace the GRUB_CMDLINE_LINUX_DEFAULT line
    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${new_line}\"|" "$grub_file"

    info "Running update-grub..."
    update-grub 2>&1 | grep -v "^$" | sed 's/^/  /'

    echo ""
    info "GRUB updated. Changes take effect on next reboot."
    warn "Reboot when ready: sudo reboot"
}

# ---- tune-sysctl -------------------------------------------------------
# Consolidate conflicting sysctl files and add missing compute settings.
# Writes /etc/sysctl.d/99-zzz-greenboost.conf — loaded last, wins all
# conflicts. Previous files are left untouched (history/documentation).

cmd_tune_sysctl() {
    need_root tune-sysctl

    local dest="/etc/sysctl.d/99-zzz-greenboost.conf"

    info "Writing definitive sysctl config: $dest"
    info "This file loads last (99-zzz) and wins over all conflicting files."
    echo ""

    # Show conflicts found
    info "Conflicts resolved:"
    info "  vm.swappiness       : multiple files set 10/20 → final: 10"
    info "  vm.dirty_ratio      : 15 vs 40 → final: 40 (Samsung 990 sustains 7 GB/s)"
    info "  vm.dirty_background_ratio: 5 vs 10 → final: 10"
    info "  kernel.sched_autogroup_enabled: 1 → 0 (bad for compute, groups by session)"
    info "New settings added:"
    info "  kernel.sched_migration_cost_ns: 5000000 (5ms — keep threads on P-cores)"
    info "  kernel.sched_min_granularity_ns: 10000000 (10ms — better for large tasks)"
    info "  kernel.sched_wakeup_granularity_ns: 15000000 (reduces spurious wakeups)"
    echo ""

    cat > "$dest" << 'SYSCTL_EOF'
# GreenBoost v2.3 — Definitive sysctl config
# Hardware: i9-14900KF | RTX 5070 | 64 GB DDR4-3600 | Samsung 990 EVO Plus 4 TB
# Loaded last (99-zzz) — wins all conflicts with earlier sysctl.d files.
# Do NOT edit other sysctl.d files; make changes here instead.

# ── Swap / memory pressure ───────────────────────────────────────────────
# Keep LLM weights in DDR4 (T2); only spill to NVMe (T3) under real pressure.
vm.swappiness = 10

# ── Write-back (Samsung 990 EVO Plus sustains 6,300 MB/s writes) ─────────
# Allow up to 40% dirty pages before throttling writes (~25 GB at 64 GB RAM).
# Background flush at 10% (~6.4 GB) — keeps NVMe busy without stalling allocs.
vm.dirty_ratio = 40
vm.dirty_background_ratio = 10
vm.dirty_writeback_centisecs = 1500
vm.dirty_expire_centisecs = 3000

# ── Memory allocation ─────────────────────────────────────────────────────
# LLM frameworks (llama.cpp, PyTorch, JAX) mmap model files and pre-reserve
# large virtual address ranges. Without overcommit the kernel rejects these.
vm.overcommit_memory = 1

# Max VMA regions: transformer models (70B+) split across thousands of mmap
# file segments. Default 65530 is too low; 2M covers any realistic case.
vm.max_map_count = 2147483642

# Always keep 512 MB free — prevents latency spikes under allocation storms.
vm.min_free_kbytes = 524288

# Proactive compaction: GreenBoost T2 needs contiguous 2 MB hugepage ranges.
# Value 20 = moderate background compaction (0=off, 100=aggressive).
vm.compaction_proactiveness = 20

# Overcommit hugepage pool: 10240 × 2 MB = 20 GB pre-reserved for THP allocs.
vm.nr_overcommit_hugepages = 10240

# Keep inode/dentry caches alive — LLM loaders open thousands of weight files.
vm.vfs_cache_pressure = 50

# Disable zone reclaim: single NUMA node — cross-zone reclaim wastes cycles.
vm.zone_reclaim_mode = 0

# ── CPU scheduler (i9-14900KF P-core / E-core hybrid) ────────────────────
# Disable session-based task grouping. sched_autogroup groups shell tasks
# together which is good for desktop but HURTS inference: Ollama worker
# threads (long-running compute) compete with short interactive tasks for
# scheduler time-slices in the same group.
kernel.sched_autogroup_enabled = 0

# Raise migration cost threshold: scheduler avoids migrating tasks to
# a different CPU unless the cache-miss penalty exceeds this value (5 ms).
# Effect: LLM inference threads stay on their assigned P-cores rather than
# bouncing between P-cores and E-cores (which have different cache hierarchies).
kernel.sched_migration_cost_ns = 5000000

# Minimum scheduling granularity (10 ms): gives large compute tasks
# (matrix multiplications, attention heads) more uninterrupted runtime
# before the scheduler can preempt them.
kernel.sched_min_granularity_ns = 10000000

# Wakeup granularity (15 ms): a waking task only preempts the current task
# if it has been sleeping for more than this long. Prevents short-lived
# system tasks from constantly interrupting inference threads.
kernel.sched_wakeup_granularity_ns = 15000000

# ── NUMA ──────────────────────────────────────────────────────────────────
# Single-socket i9-14900KF — all CPUs are on NUMA node 0. Automatic NUMA
# balancing scans pages and attempts cross-node migrations that will never
# happen. Disable to remove the page-scanning overhead.
kernel.numa_balancing = 0

# ── File system ───────────────────────────────────────────────────────────
# GGUF model files (70B+ = thousands of weight tensors) require many open
# file descriptors and inotify watches during model loading.
fs.file-max = 2097152
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 1024

# ── Network (Ollama API / distributed inference) ──────────────────────────
# Large buffers for Ollama HTTP streaming API and any future multi-GPU setup.
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_fastopen = 3

# ── Perf / profiling access ───────────────────────────────────────────────
# Allow nsys / perf / CUDA Nsight without sudo (needed for GPU profiling).
kernel.perf_event_paranoid = 1
kernel.kptr_restrict = 0
SYSCTL_EOF

    sysctl -p "$dest" 2>&1 | grep -v "^$" | sed 's/^/  /' || true
    echo ""
    info "sysctl applied and persistent (survives reboot via $dest)."
}

# ---- tune-libs ---------------------------------------------------------
# Install missing libraries and kernel modules for AI/compute workloads.
# All packages chosen for AVX2/FMA/VNNI capabilities on i9-14900KF.

cmd_tune_libs() {
    need_root tune-libs

    info "Installing missing AI/compute libraries for i9-14900KF + RTX 5070..."
    echo ""

    # ── APT packages ──────────────────────────────────────────────────────
    local pkgs=(
        # BLAS/LAPACK — OpenBLAS compiled with AVX2+FMA for CPU inference
        libopenblas-dev
        libblas-dev
        liblapack-dev

        # OpenMP — multi-threaded CPU inference (llama.cpp uses this heavily)
        libomp-dev

        # hwloc — hardware topology library used by Ollama/llama.cpp for
        # CPU pinning; without it Ollama uses a generic thread affinity model
        hwloc
        libhwloc-dev

        # libnuma — NUMA-aware memory allocation (single node but still used
        # by CUDA and some ML runtimes for memory locality hints)
        libnuma-dev

        # OpenCL — GPU compute via OpenCL API (some inference backends use it)
        ocl-icd-opencl-dev

        # nvtop — real-time GPU + CPU monitor (shows all 3 tiers at a glance)
        nvtop

        # cpufrequtils — userspace CPU frequency tools (cpufreq-info, etc.)
        cpufrequtils

        # linux-tools — perf, turbostat (monitors P/E core frequencies + C-states)
        linux-tools-generic

        # intel-microcode — latest CPU microcode (fixes + performance patches
        # for i9-14900KF Raptor Lake stepping)
        intel-microcode
    )

    info "Packages to install:"
    local to_install=()
    for pkg in "${pkgs[@]}"; do
        if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
            info "  [ok]      $pkg"
        else
            info "  [install] $pkg"
            to_install+=("$pkg")
        fi
    done
    echo ""

    if [[ ${#to_install[@]} -eq 0 ]]; then
        info "All packages already installed."
    else
        apt-get install -y "${to_install[@]}" 2>&1 | tail -5
        info "Packages installed."
    fi

    echo ""

    # ── Kernel modules ────────────────────────────────────────────────────
    info "Kernel modules:"

    # cpuid — lets userspace read CPUID leaves directly. Used by turbostat,
    # CUDA diagnostics, and intel-microcode update verification.
    if lsmod | grep -q "^cpuid "; then
        info "  [ok]      cpuid  (loaded)"
    else
        modprobe cpuid && info "  [loaded]  cpuid" || warn "  cpuid: modprobe failed"
    fi

    # Ensure cpuid + msr auto-load at boot
    local ml_conf="/etc/modules-load.d/ai-workstation.conf"
    if ! grep -q "^cpuid" "$ml_conf" 2>/dev/null; then
        echo "cpuid" >> "$ml_conf"
        info "  [add]     cpuid -> $ml_conf (auto-load at boot)"
    else
        info "  [ok]      cpuid already in $ml_conf"
    fi

    echo ""

    # ── OpenBLAS CPU target selection ─────────────────────────────────────
    # Make sure the system BLAS points to OpenBLAS (AVX2/FMA optimised)
    # rather than the reference BLAS implementation.
    if command -v update-alternatives &>/dev/null && dpkg -l libopenblas-dev 2>/dev/null | grep -q "^ii"; then
        update-alternatives --set libblas.so.3-x86_64-linux-gnu \
            /usr/lib/x86_64-linux-gnu/openblas-pthread/libblas.so.3 2>/dev/null \
            && info "BLAS alternative: set to OpenBLAS (AVX2/FMA)" \
            || info "BLAS alternative: already set or path differs — check manually"
    fi

    echo ""
    info "tune-libs complete."
    info "  Turbostat (P/E core monitoring): sudo turbostat --quiet --Summary"
    info "  nvtop (GPU + CPU):               nvtop"
    info "  CPU frequency info:              cpufreq-info"
}

# ---- tune-all ----------------------------------------------------------

cmd_tune_all() {
    need_root tune-all
    info "Running full system tuning for GreenBoost v2.3..."
    echo ""
    cmd_tune
    echo ""
    cmd_tune_sysctl
    echo ""
    cmd_tune_grub
    echo ""
    cmd_tune_libs
    echo ""
    info "All tuning complete."
    info "Reboot to activate GRUB changes: sudo reboot"
}

cmd_status() {
    echo ""
    echo -e "${BLU}=== GreenBoost v2.3 Status (3-tier pool) ===${NC}"
    echo ""

    if lsmod | grep -q "^${DRIVER_NAME} "; then
        echo -e "  Module: ${GRN}LOADED ✓${NC}"
    else
        echo -e "  Module: ${RED}not loaded${NC}"
    fi

    local pool_f="/sys/class/greenboost/greenboost/pool_info"
    if [[ -r "$pool_f" ]]; then
        echo ""
        cat "$pool_f" | sed 's/^/  /'
    fi

    echo ""
    echo -e "${BLU}=== Recent kernel messages ===${NC}"
    dmesg | grep greenboost | tail -10 | sed 's/^/  /'
    echo ""
}

cmd_help() {
    echo ""
    echo -e "${BLU}GreenBoost v2.3 — 3-Tier GPU Memory Pool${NC}"
    echo "Author : Ferran Duarri"
    echo "Target : ASUS RTX 5070 12 GB + 64 GB DDR4-3600 + 4 TB Samsung 990 Evo Plus NVMe"
    echo ""
    echo "  Tier 1  RTX 5070 VRAM      12 GB   ~336 GB/s  [hot layers]"
    echo "  Tier 2  DDR4 pool          51 GB    ~50 GB/s  [cold layers, hugepages]"
    echo "  Tier 3  NVMe swap         576 GB    ~1.8 GB/s  [frozen pages, swappable 4K]"
    echo "          ─────────────────────────────────────"
    echo "          Combined capacity  639 GB"
    echo ""
    echo "USAGE:  sudo ./greenboost_setup.sh <command>"
    echo ""
    echo "COMMANDS:"
    echo "  install     Build and install module + CUDA shim system-wide"
    echo "  uninstall   Unload, remove module + all config files"
    echo "  build       Build only (no system install)"
    echo "  load        Load module with default 3-tier parameters"
    echo "  unload      Unload module (keeps installed files)"
    echo "  tune        Tune system for LLM workloads (governor, NVMe, THP, sysctl)"
    echo "  tune-grub   Fix GRUB boot params (THP=always, rcu_nocbs, nohz_full…)"
    echo "  tune-sysctl Consolidate sysctl files + apply compute-optimized knobs"
    echo "  tune-libs   Install missing AI/compute libraries (OpenBLAS, hwloc…)"
    echo "  tune-all    Run tune + tune-grub + tune-sysctl + tune-libs in sequence"
    echo "  status      Show module status and 3-tier pool info"
    echo "  help        Show this help"
    echo ""
    echo "ENVIRONMENT (for load):"
    echo "  GPU_PHYS_GB=12     Physical VRAM in GB          (RTX 5070 default: 12)"
    echo "  VIRT_VRAM_GB=51    DDR4 pool size in GB         (default: 51, 80% of 64 GB)"
    echo "  RESERVE_GB=12      System RAM to keep free      (default: 12)"
    echo "  NVME_SWAP_GB=576   NVMe swap capacity in GB     (default: 576)"
    echo "  NVME_POOL_GB=512   GreenBoost T3 soft cap in GB (default: 512)"
    echo ""
    echo "  Example: sudo VIRT_VRAM_GB=48 NVME_SWAP_GB=576 ./greenboost_setup.sh load"
    echo ""
    echo "CUDA SHIM (transparent DDR4 overflow via NVIDIA UVM):"
    echo "  Prerequisite  : sudo modprobe nvidia_uvm"
    echo "  One-shot      : LD_PRELOAD=./libgreenboost_cuda.so  ./your_cuda_app"
    echo "  After install : greenboost-run  ./your_cuda_app"
    echo "  Threshold     : GREENBOOST_THRESHOLD_MB=512  greenboost-run  ./app"
    echo "  Debug         : GREENBOOST_DEBUG=1  greenboost-run  ./app"
    echo ""
    echo "MONITORING:"
    echo "  cat /sys/class/greenboost/greenboost/pool_info   (3-tier table)"
    echo "  cat /sys/class/greenboost/greenboost/active_buffers"
    echo "  dmesg | grep greenboost"
    echo "  watch -n1 free -h                               (T2 RAM pressure)"
    echo "  watch -n1 swapon --show                         (T3 NVMe usage)"
    echo "  make status"
    echo ""
}

# ---- Entry point -------------------------------------------------------

COMMAND="${1:-help}"
case "$COMMAND" in
    install)            cmd_install            ;;
    uninstall)          cmd_uninstall          ;;
    build)              cmd_build              ;;
    load)               cmd_load               ;;
    unload)             cmd_unload             ;;
    install-sys-configs) cmd_install_sys_configs ;;
    tune)               cmd_tune               ;;
    tune-grub)          cmd_tune_grub          ;;
    tune-sysctl)        cmd_tune_sysctl        ;;
    tune-libs)          cmd_tune_libs          ;;
    tune-all)           cmd_tune_all           ;;
    status)             cmd_status             ;;
    help|--help|-h)     cmd_help               ;;
    *) die "Unknown command: '$COMMAND'  — use: $0 help" ;;
esac
