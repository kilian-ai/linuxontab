# LinuxOnTab Kernel Integration Worktree

This is a **git worktree** for the `feature/linux-kernel-integration` branch.

## Quick Start

```bash
# Navigate to worktree
cd /Users/kilian/.ai/LinuxOnTab-kernel

# Check branch
git branch
# Output: * feature/linux-kernel-integration

# View changes from main
git log main..HEAD
```

## Structure

- **`shell/`** — v86 emulator UI + xterm.js (same as main)
- **`services/`** — Relay infrastructure (same as main)
- **`local/`** — Guest-side scripts (same as main)
- **`kernels/linux/`** — **NEW**: tombl/linux kernel fork
  - `services-linuxontab/` — Copy of relay services
  - `shell-ui-linuxontab.html` — Copy of shell UI
  - `local-linuxontab/` — Copy of guest scripts
  - `LINUXONTAB-INTEGRATION.md` — Integration guide

## Key Points

### ✅ This Worktree Does NOT Affect Main

- **Main branch** (`/Users/kilian/.ai/LinuxOnTab`) → stays at production code
- **Feature branch** (this worktree) → isolated development
- **Separate git history**: Each worktree has independent commits

### Development Flow

1. **Edit files in this worktree**
2. **Commit to feature branch**: `git add -A && git commit -m "..."`
3. **Push to remote**: `git push origin feature/linux-kernel-integration`
4. **Never affects main** until explicitly merged via PR

### Important Commands

```bash
# Check status
git status

# View commits on this branch (not on main)
git log --oneline main..HEAD

# Compare with main
git diff main shell/index.html

# Stash changes if needed
git stash

# Switch back to main worktree
cd /Users/kilian/.ai/LinuxOnTab
git status  # should show: On branch main
```

## Next Steps

1. **Review the kernel**: `ls -la kernels/linux/`
2. **Read integration guide**: `kernels/linux/LINUXONTAB-INTEGRATION.md`
3. **Start kernel customization**:
   ```bash
   cd kernels/linux
   # [build kernel per tombl/linux instructions]
   ```
4. **Test with shell UI**:
   ```bash
   # Open locally
   python3 -m http.server 8080
   open http://localhost:8080/shell-ui-linuxontab.html
   ```
5. **Commit when ready**:
   ```bash
   git add -A
   git commit -m "kernel: [your changes]"
   git push origin feature/linux-kernel-integration
   ```

## Links

- **Feature branch**: [GitHub WIP](https://github.com/kilian-ai/linuxontab/tree/feature/linux-kernel-integration)
- **Main branch**: [Live LinuxOnTab](https://github.com/kilian-ai/linuxontab)
- **Kernel source**: [kernels/linux/](./kernels/linux/)
- **Integration guide**: [kernels/linux/LINUXONTAB-INTEGRATION.md](./kernels/linux/LINUXONTAB-INTEGRATION.md)

---

**Branch**: `feature/linux-kernel-integration`
**Worktree path**: `/Users/kilian/.ai/LinuxOnTab-kernel`
**Main path**: `/Users/kilian/.ai/LinuxOnTab`
