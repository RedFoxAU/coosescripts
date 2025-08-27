## Deployment script to link Truenas Dataset to linux host
## Stage 1 only (user/group + NFS mount)
#sudo ./setup_ollama_nfs.sh
#
## Stage 1 + Stage 2 (symlink models)
#sudo ./setup_ollama_nfs.sh --stage2
#
## Dry run (print actions without changing anything)
#sudo ./setup_ollama_nfs.sh --dry-run --stage2
#
#!/bin/bash
# LXC-safe Ollama NFS setup and model symlink script
# Usage: 
#   ./setup_ollama_lxc.sh [--dry-run] [--stage2]

OLLAMA_UID=999
OLLAMA_GID=996
MOUNT_POINT="/mnt/ollama_models"
DRYRUN=false
STAGE2=false

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRYRUN=true ;;
        --stage2) STAGE2=true ;;
    esac
done

run_cmd() {
    if $DRYRUN; then
        echo "[DRY-RUN] $*"
    else
        eval "$@"
    fi
}

echo "=== Stage 1: User/Group setup ==="

# Detect if running inside LXC
if [ -f /proc/1/environ ] && grep -q container=lxc /proc/1/environ; then
    echo "ℹ️ Running inside LXC container"
    IN_LXC=true
else
    IN_LXC=false
fi

# --- Group handling ---
EXISTING_GROUP=$(getent group "$OLLAMA_GID" | cut -d: -f1)
if [ -n "$EXISTING_GROUP" ]; then
    echo "⚠️ GID $OLLAMA_GID already used by group '$EXISTING_GROUP'. Adding 'ollama' user to this group."
    GID_FOR_USER="$OLLAMA_GID"
else
    if ! getent group ollama >/dev/null; then
        run_cmd "groupadd -g $OLLAMA_GID ollama"
    fi
    GID_FOR_USER="$OLLAMA_GID"
fi

# --- User handling ---
if id ollama >/dev/null 2>&1; then
    echo "User 'ollama' exists. Ensuring membership in group with GID $GID_FOR_USER"
    TARGET_GROUP=$(getent group "$GID_FOR_USER" | cut -d: -f1)
    if ! id -Gn ollama | grep -qw "$TARGET_GROUP"; then
        run_cmd "usermod -aG $TARGET_GROUP ollama"
    fi
else
    run_cmd "useradd -u $OLLAMA_UID -g $GID_FOR_USER -m -s /bin/bash ollama"
fi

# --- NFS mount warning for LXC ---
if $IN_LXC; then
    echo "ℹ️ In LXC container, NFS should be mounted by the host or bind-mounted."
    echo "ℹ️ Make sure $MOUNT_POINT exists inside container and points to host-mounted NFS."
    [ ! -d "$MOUNT_POINT" ] && run_cmd "mkdir -p $MOUNT_POINT"
else
    echo "ℹ️ Running on host: NFS mount commands can be executed"
    [ ! -d "$MOUNT_POINT" ] && run_cmd "mkdir -p $MOUNT_POINT"
    if ! grep -q "$MOUNT_POINT" /etc/fstab; then
        echo "Adding NFS mount entry to /etc/fstab"
        FSTAB_LINE="truenas:/mnt/twelves/ollama_models $MOUNT_POINT nfs defaults,nofail,x-systemd.automount,_netdev,rsize=131072,wsize=131072,timeo=14,retrans=3 0 0"
        run_cmd "echo '$FSTAB_LINE' >> /etc/fstab"
        run_cmd "systemctl daemon-reload"
        run_cmd "systemctl restart remote-fs.target"
    fi
fi

echo "✅ Stage 1 complete."

# -------------------
# Stage 2: Symlink ollama models
# -------------------
if $STAGE2; then
    echo
    echo "=== Stage 2: Relink ollama models to NFS share ==="

    MODEL_DIRS=(
        "/usr/share/ollama/.ollama/models"
        "/root/.ollama/models"
    )

    # Stop ollama service if systemctl exists
    if command -v systemctl >/dev/null 2>&1; then
        run_cmd "systemctl stop ollama"
    else
        echo "ℹ️ systemctl not found, please stop ollama manually if needed"
    fi

    for DIR in "${MODEL_DIRS[@]}"; do
        PARENT=$(dirname "$DIR")
        [ ! -d "$PARENT" ] && run_cmd "mkdir -p $PARENT"

        if [ -L "$DIR" ]; then
            echo "ℹ️ $DIR is already a symlink, skipping."
            continue
        fi

        if [ -d "$DIR" ] && [ "$(ls -A "$DIR")" ]; then
            echo "⚠️ $DIR is not empty."
            read -p "Delete contents and replace with symlink? (y/N): " ans
            [[ "$ans" != "y" ]] && continue
            run_cmd "rm -rf $DIR"
        elif [ -d "$DIR" ]; then
            run_cmd "rm -rf $DIR"
        fi

        run_cmd "ln -s $MOUNT_POINT/models $DIR"
    done

    # Start ollama service if systemctl exists
    if command -v systemctl >/dev/null 2>&1; then
        run_cmd "systemctl start ollama"
        run_cmd "ollama status || true"
    else
        echo "ℹ️ systemctl not found, please start ollama manually"
    fi

    echo "✅ Stage 2 complete. Models directories are now symlinked to $MOUNT_POINT/models"
fi

# -------------------
# Summary report
# -------------------
OLLAMA_FINAL_UID=$(id -u ollama 2>/dev/null || echo "N/A")
OLLAMA_FINAL_GID=$(id -g ollama 2>/dev/null || echo "N/A")
OLLAMA_GROUPS=$(id -Gn ollama 2>/dev/null || echo "N/A")

echo
echo "=== Summary Report ==="
echo "User: ollama"
echo "UID: $OLLAMA_FINAL_UID"
echo "Primary GID: $OLLAMA_FINAL_GID"
echo "Groups: $OLLAMA_GROUPS"
echo "NFS mount: $MOUNT_POINT/models"
if $STAGE2; then
    for DIR in "${MODEL_DIRS[@]}"; do
        if [ -e "$DIR" ]; then
            if [ -L "$DIR" ]; then
                LINK_TARGET=$(readlink -f "$DIR")
                echo "Symlink: $DIR -> $LINK_TARGET"
            else
                echo "Directory exists (not symlink): $DIR"
            fi
        fi
    done
fi
echo "====================="
