# Linux Kernel Integration

This directory is reserved for Linux kernel development integration with LinuxOnTab.

## Setup

The Linux kernel is **not** pre-cloned to keep the worktree lightweight. Clone it when ready:

```bash
cd kernels
git clone https://github.com/tombl/linux.git
cd linux
```

## After Cloning

Once you have `kernels/linux/`, the integration docs will be ready:

```bash
# Create integration guide
cat > kernels/linux/LINUXONTAB-INTEGRATION.md << 'GUIDE'
# LinuxOnTab + Linux Kernel Integration

[See ../kernels/README.md for setup instructions]
GUIDE

# Copy relay services
cp -r ../services kernels/linux/services-linuxontab

# Copy shell UI
cp ../shell/index.html kernels/linux/shell-ui-linuxontab.html

# Copy guest scripts
cp -r ../local kernels/linux/local-linuxontab

# Commit
git add kernels/
git commit -m "kernel: clone tombl/linux and integrate relay services"
```

## Directory Structure (after clone)

```
kernels/
├── README.md                        # This file
└── linux/                           # tombl/linux (after git clone)
    ├── services-linuxontab/         # [After copy] Relay services
    ├── shell-ui-linuxontab.html     # [After copy] Shell UI
    ├── local-linuxontab/            # [After copy] Guest scripts
    ├── arch/x86/boot/bzImage        # Compiled kernel (after make)
    └── [Linux kernel source]
```

## Build

```bash
cd kernels/linux
make -j8
# Produces: arch/x86/boot/bzImage
```

## Deployment

After building, copy the kernel into shell UI:

```bash
cp kernels/linux/arch/x86/boot/bzImage ../shell/linux.iso
git add shell/
git commit -m "kernel: update to latest build"
```

## Links

- **Kernel source**: https://github.com/tombl/linux
- **Parent worktree**: https://github.com/kilian-ai/linuxontab
- **Branch**: `feature/linux-kernel-integration`

## Notes

- This is a **git worktree**, not affected by main branch
- Kernel clone is on-demand to keep initial setup fast
- All changes are isolated to this branch until merged
