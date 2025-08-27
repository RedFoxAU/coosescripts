#!/bin/bash
# LXC-safe unified Ollama NFS setup script
# Usage: ./setup_ollama_lxc_safe.sh [--dry-run] [--stage2]

OLLAMA_UID=999
OLLAMA_GID=996
MOUNT_POINT="/mnt/ollama_models"
DRYRUN=false
STAGE2=false
NFS_SERVER="10.33.99.244"
NFS_PATH="/mnt/twelves/ollama_models"

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

# Detect LXC environment
if [ -f /proc/1/environ ] && grep -q container=lxc /proc/1/environ; then
    echo "ℹ️ Running inside LXC container (unprivileged)"
    IN_LXC=true
else
    IN_LXC=false
fi

# Determine mapped UID/GID for LXC
if $IN_LXC; then
    CONTAINER_UID=$(awk '/^0 / {print $2}' /proc/1/uid_map)
    CONTAINER_GID=$(awk '/^0 / {print $2}' /proc/1/gid_map)
    MAPPED_UID=$((OLLAMA_UID + CONTAINER_UID))
    MAPPED_GID=$((OLLAMA_GID + CONTAINER_GID))
    echo "ℹ️ Container mapped UID/GID for NFS: $MAPPED_UID:$MAPPED_GID"
else
    MAPPED_UID=$OLLAMA_UID
    MAPPED_GID=$OLLAMA_GID
fi

# --- Group handling ---
EXISTING_GROUP=$(getent group "$MAPPED_GID" | cut -d: -f1)
if [ -n "$EXISTING_GROUP" ]; then
    echo "⚠️ GID $MAPPED_GID already used by group '$EXISTING_GROUP'. Adding 'ollama' user to this group."
    TARGET_GROUP="$EXISTING_GROUP"
else
    if ! getent group ollama >/dev/null; then
        if ! $IN_LXC; then
            run_cmd "groupadd -g $MAPPED_GID ollama"
        else
            echo "ℹ️ Skipping groupadd in unprivileged LXC"
        fi
    fi
    TARGET_GROUP="ollama"
fi

# --- User handling ---
if id ollama >/dev/null 2>&1; then
    echo "User 'ollama' exists. Ensuring membership in group '$TARGET_GROUP'"
    if ! id -Gn ollama | grep -qw "$TARGET_GROUP"; then
        if ! $IN_LXC; then
            run_cmd "usermod -aG $TARGET_GROUP ollama"
        else
            echo "ℹ️ Skipping usermod in unprivileged LXC"
        fi
    fi
else
    if ! $IN_LXC; then
        run_cmd "useradd -u $MAPPED_UID -g $MAPPED_GID -m -s /bin/bash ollama"
    else
        echo "ℹ️ Skipping useradd in unprivileged LXC"
    fi
fi

# --- NFS mount ---
if $IN_LXC; then
    echo "ℹ️ In LXC: ensure $MOUNT_POINT exists and points to host-mounted/bind-mounted NFS."
    [ ! -d "$MOUNT_POINT" ] && run_cmd "mkdir -p $MOUNT_POINT"
else
    [ ! -d "$MOUNT_POINT" ] && run_cmd "mkdir -p $MOUNT_POINT"
    if ! grep -q "$MOUNT_POINT" /etc/fstab; then
        FSTAB_LINE="$NFS_SERVER:$NFS_PATH $MOUNT_POINT nfs defaults,nofail,x-systemd.automount,_netdev,rsize=131072,wsize=131072,timeo=14,retrans=3 0 0"
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
    if command -v systemctl >/dev/null 2>&1 && ! $IN_LXC; then
        run_cmd "systemctl stop ollama"
    else
        echo "ℹ️ Skipping systemctl stop/start in unprivileged LXC"
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

    if command -v systemctl >/dev/null 2>&1 && ! $IN_LXC; then
        run_cmd "systemctl start ollama"
        run_cmd "ollama status || true"
    else
        echo "ℹ️ Skipping systemctl start in unprivileged LXC"
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
echo "====================="
ollama list
echo "====================="
ls -la /mnt/ollama_models/models
echo "====================="
