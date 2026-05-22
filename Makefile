# LinuxOnTab-kernel build system
#
# Targets:
#   make all            — compile all C programs + rebuild rootfs.ext4
#   make tcplisten      — compile tcplisten.c → rootfs/sbin/tcplisten
#   make sftp-server    — compile sftp-server.c → rootfs/usr/lib/sftp-server
#   make rootfs         — rebuild rootfs.ext4 from the staging tree
#   make packages       — rebuild package tarballs from wasm-distro results
#   make clean          — remove compiled object files
#   make distro-build   — build all packages via @tombl/distro Nix flake
#
# Override toolchain paths at the command line, e.g.:
#   make tcplisten CLANG=/path/to/clang
#
# Requirements (macOS):
#   brew install binaryen e2fsprogs
#   nix (for distro-build target)

# ── Toolchain ──────────────────────────────────────────────────────────────────
# Use the patched clang from @tombl/distro (adds wasm32-unknown-linux-musl triple)
CLANG     ?= /nix/store/sa4f4iaw4zmkdnfiidjpys8dlgkzridc-clang/bin/clang
WASM_LD   ?= /nix/store/l62m9j22mhh21n6w9g3rzb5f8kp55f8a-lld-19.1.7/bin/wasm-ld
SYSROOT   ?= /nix/store/10s1qmch2cmk1aa9di1wpq4znlh1vr7s-musl-sysroot
WASM_OPT  ?= /opt/homebrew/bin/wasm-opt
WASM_DISTRO ?= /private/tmp/wasm-distro

# ── Paths ──────────────────────────────────────────────────────────────────────
ROOTFS    := $(CURDIR)/rootfs
STAGING   := $(ROOTFS)
OUTPUT    := $(CURDIR)/shell/linux-dist/rootfs.ext4
SYSROOT_DIR := $(ROOTFS)/sysroot

# ── Common compile flags ───────────────────────────────────────────────────────
WASM_CFLAGS := \
  --target=wasm32-unknown-linux-musl \
  --sysroot=$(SYSROOT) \
  -nostdlib \
  -O2 -fno-exceptions \
  -matomics -mbulk-memory \
  -I$(CURDIR)/sysroot

WASM_LDFLAGS := \
  --target=wasm32-unknown-linux-musl \
  --sysroot=$(SYSROOT) \
  --no-standard-libraries \
  -fuse-ld=$(WASM_LD) \
  -Wl,--import-memory \
  -Wl,--export-memory \
  -Wl,--export-table \
  -Wl,--export=__heap_base \
  -Wl,--export=__data_end \
  -Wl,-z,stack-size=$$((4 * 1024 * 1024)) \
  -Wl,--shared-memory \
  -Wl,--max-memory=$$((256 * 1024 * 1024))

WASM_LIBS := \
  $(SYSROOT)/lib/crt1.o \
  -lc

# ── Phony targets ──────────────────────────────────────────────────────────────
.PHONY: all tcplisten sftp-server rootfs packages distro-build clean help

all: tcplisten sftp-server rootfs

help:
	@echo "LinuxOnTab-kernel build targets:"
	@echo "  make all             compile everything + rebuild rootfs.ext4"
	@echo "  make tcplisten       compile tcplisten.c → rootfs/sbin/tcplisten"
	@echo "  make sftp-server     compile sftp-server.c → rootfs/usr/lib/sftp-server"
	@echo "  make rootfs          rebuild rootfs.ext4 from staging tree"
	@echo "  make packages        repack package tarballs from wasm-distro results"
	@echo "  make distro-build    build WASM packages via Nix (slow, first time)"
	@echo "  make clean           remove temp build files"
	@echo ""
	@echo "Toolchain overrides:"
	@echo "  CLANG=$(CLANG)"
	@echo "  WASM_LD=$(WASM_LD)"
	@echo "  SYSROOT=$(SYSROOT)"
	@echo "  WASM_OPT=$(WASM_OPT)"
	@echo "  WASM_DISTRO=$(WASM_DISTRO)"

# ── tcplisten ──────────────────────────────────────────────────────────────────
tcplisten: rootfs/sbin/tcplisten

rootfs/sbin/tcplisten: tcplisten.c sysroot/wasm_fork.c
	@echo "[compile] tcplisten.c → $@"
	$(CLANG) $(WASM_CFLAGS) -DASYNCIFY_BUF_SIZE=8192 \
	  -c tcplisten.c -o /tmp/tcplisten.o
	$(CLANG) $(WASM_CFLAGS) -DASYNCIFY_BUF_SIZE=8192 \
	  -c sysroot/wasm_fork.c -o /tmp/wasm_fork.o
	$(CLANG) $(WASM_LDFLAGS) \
	  $(SYSROOT)/lib/crt1.o /tmp/tcplisten.o /tmp/wasm_fork.o \
	  -lc -o /tmp/tcplisten.wasm
	$(WASM_OPT) --asyncify -O1 /tmp/tcplisten.wasm -o $@
	chmod +x $@
	@echo "[done] $@ ($(shell wc -c < $@) bytes)"

# ── sftp-server ───────────────────────────────────────────────────────────────
sftp-server: rootfs/usr/lib/sftp-server

rootfs/usr/lib/sftp-server: sftp-server.c
	@echo "[compile] sftp-server.c → $@"
	$(CLANG) $(WASM_CFLAGS) -c sftp-server.c -o /tmp/sftp-server.o
	$(CLANG) $(WASM_LDFLAGS) \
	  $(SYSROOT)/lib/crt1.o /tmp/sftp-server.o \
	  -lc -o /tmp/sftp-server.wasm
	$(WASM_OPT) --asyncify -O1 /tmp/sftp-server.wasm -o $@
	chmod +x $@
	@echo "[done] $@ ($(shell wc -c < $@) bytes)"

# ── rootfs ────────────────────────────────────────────────────────────────────
rootfs:
	@echo "[build-rootfs] rebuilding $(OUTPUT)..."
	bash build-rootfs.sh

# ── packages ──────────────────────────────────────────────────────────────────
packages:
	@echo "[packages] repacking from wasm-distro results at $(WASM_DISTRO)..."
	bash packages/make-packages.sh $(WASM_DISTRO) $(ROOTFS)/packages
	@echo "[packages] done. Run 'make rootfs' to apply."

# ── distro-build ──────────────────────────────────────────────────────────────
# Builds all WASM packages from source via the @tombl/distro Nix flake.
# Requires Nix to be installed. First run downloads from linuxwasm.cachix.org.
distro-build:
	@if [ ! -d "$(WASM_DISTRO)" ]; then \
	  echo "[distro] cloning tombl/distro to $(WASM_DISTRO)..."; \
	  git clone --depth=1 https://github.com/tombl/distro "$(WASM_DISTRO)"; \
	fi
	@echo "[distro] building WASM packages (using cachix for speed)..."
	cd "$(WASM_DISTRO)" && nix build \
	  .#busybox .#sqlite3 .#dropbear .#musl .#compiler-rt .#libcxx .#sysroot \
	  --accept-flake-config \
	  --no-link \
	  --print-out-paths
	@echo "[distro] done. Run 'make packages' to repackage."

# ── clean ─────────────────────────────────────────────────────────────────────
clean:
	rm -f /tmp/tcplisten.o /tmp/wasm_fork.o /tmp/tcplisten.wasm
	rm -f /tmp/sftp-server.o /tmp/sftp-server.wasm
	rm -f rootfs/packages/.index-fragments.txt
	@echo "[clean] done"
