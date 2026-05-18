#!/bin/bash
# Setup script: Clone and integrate Linux kernel with LinuxOnTab relay services
# Usage: bash SETUP-KERNEL.sh
# Note: This clones a large repository (~10GB). May take 1-2 hours depending on network.

set -e

WORKTREE_DIR="$(cd "$(dirname "$0")" && pwd)"
KERNELS_DIR="$WORKTREE_DIR/kernels"
LINUX_DIR="$KERNELS_DIR/linux"

echo "=== LinuxOnTab Kernel Integration Setup ==="
echo "Worktree: $WORKTREE_DIR"
echo "Branch: $(git -C "$WORKTREE_DIR" branch --show-current)"
echo ""

# Step 1: Clone kernel
if [ -d "$LINUX_DIR" ]; then
    echo "✓ Linux kernel already cloned at $LINUX_DIR"
else
    echo "→ Cloning tombl/linux (this may take 1-2 hours)..."
    cd "$KERNELS_DIR"
    git clone https://github.com/tombl/linux.git
    echo "✓ Linux kernel cloned"
fi

cd "$LINUX_DIR"

# Step 2: Copy relay services
if [ ! -d "services-linuxontab" ]; then
    echo "→ Copying relay services..."
    cp -r "$WORKTREE_DIR/services" services-linuxontab
    echo "✓ Services copied"
else
    echo "✓ Services already present"
fi

# Step 3: Copy shell UI
if [ ! -f "shell-ui-linuxontab.html" ]; then
    echo "→ Copying shell UI..."
    cp "$WORKTREE_DIR/shell/index.html" shell-ui-linuxontab.html
    echo "✓ Shell UI copied"
else
    echo "✓ Shell UI already present"
fi

# Step 4: Copy guest scripts
if [ ! -d "local-linuxontab" ]; then
    echo "→ Copying guest scripts..."
    cp -r "$WORKTREE_DIR/local" local-linuxontab
    echo "✓ Guest scripts copied"
else
    echo "✓ Guest scripts already present"
fi

# Step 5: Commit changes
echo ""
echo "→ Checking git status..."
cd "$WORKTREE_DIR"
git status

if git -C "$LINUX_DIR" status --short | grep -q .; then
    echo "→ Committing kernel integration..."
    git add kernels/linux/
    git commit -m "kernel: integrate tombl/linux with relay services

- Clone tombl/linux
- Copy relay services (relay/, relay-tunnel/, wisp-backend/)
- Copy shell UI (index.html → shell-ui-linuxontab.html)
- Copy guest scripts (tunnel-up.sh, tunnel-listen.sh, etc.)

Branch: feature/linux-kernel-integration (isolated from main)"
    echo "✓ Committed"
else
    echo "✓ No changes to commit"
fi

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Next steps:"
echo "1. Build kernel:    cd kernels/linux && make -j8"
echo "2. Copy to shell:   cp kernels/linux/arch/x86/boot/bzImage ../shell/linux.iso"
echo "3. Commit:          git add shell/ && git commit -m 'kernel: update build'"
echo ""
echo "For more info: cat $LINUX_DIR/README.md"
echo "Or: cat kernels/README.md"
