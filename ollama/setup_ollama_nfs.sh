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
# Setup NFS mount for ollama models with UID/GID handling and symlinked models
# Supports --dry-run and --stage2

NFS_SERVER="truenas"
NFS_PATH="/mnt/twelves/ollama_models"
MOUNT_POINT="/mnt/ollama_models"
OLLAMA_UID=999
OLLAMA_GID=996
FALLBACK_UID=2000

DRYRUN=false
STAGE2=false

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRYRUN=true ;;
        --stage2)  STAGE2=true ;;
    esac
done

run_cmd() {
    if $DRYRUN; then
        echo "[DRY-RUN] $*"
    else
        eval "$@"
    fi
}

echo "=== Stage 1: User/Group and NFS mount setup ==="

# Ensure mount point exists
if [ ! -d "$MOUNT_POINT" ]; then
    run_cmd "mkdir -p $MOUNT_POINT"
fi

# --- Group handling ---
EXISTING_GROUP=$(getent group "$OLLAMA_GID" | cut -d: -f1)
if [ -n "$EXISTING_GROUP" ]; then
    echo "⚠️ GID $OLLAMA_GID already used by group '$EXISTING_GROUP'."
    if getent group ollama >/dev/null; then
        echo "⚠️ Group 'ollama' exists. Adding 'ollama' user to existing group '$EXISTING_GROUP'."
    else
        run_cmd "groupadd -g $OLLAMA_GID ollama" || true
    fi
    GID_FOR_USER="$OLLAMA_GID"
else
    if getent group ollama >/dev/null; then
        echo "⚠️ Group 'ollama' exists with a different GID. Will use existing."
        GID_FOR_USER=$(getent group ollama | cut -d: -f3)
    else
        run_cmd "groupadd -g $OLLAMA_GID ollama"
        GID_FOR_USER="$OLLAMA_GID"
    fi
fi

# --- User handling ---
if id ollama >/dev/null 2>&1; then
    echo "User 'ollama' exists. Ensuring membership in group with GID $GID_FOR_USER"
    USER_GROUPS=$(id -Gn ollama)
    TARGET_GROUP=$(getent group "$GID_FOR_USER" | cut -d: -f1)
    if ! echo "$USER_GROUPS" | grep -qw "$TARGET_GROUP"; then
        run_cmd "usermod -aG $TARGET_GROUP ollama"
    fi
else
    run_cmd "useradd -u $OLLAMA_UID -g $GID_FOR_USER -m -s /bin/bash ollama"
fi

# --- NFS fstab entry ---
if ! grep -q "$MOUNT_POINT" /etc/fstab; then
    echo "Adding NFS mount entry to /etc/fstab..."
    FSTAB_LINE="$NFS_SERVER:$NFS_PATH  $MOUNT_POINT  nfs  defaults,nofail,x-systemd.automount,_netdev,rsize=131072,wsize=131072,timeo=14,retrans=3  0  0"
    run_cmd "echo '$FSTAB_LINE' >> /etc/fstab"
else
    echo "fstab entry for $MOUNT_POINT already exists."
fi

run_cmd "systemctl daemon-reload"
run_cmd "systemctl restart remote-fs.target"

echo "✅ Stage 1 complete. Check with: mount | grep $MOUNT_POINT"

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

    for DIR in "${MODEL_DIRS[@]}"; do
        PARENT=$(dirname "$DIR")
        if [ -d "$PARENT" ]; then
            echo "Processing $DIR ..."

            # Already a symlink?
            if [ -L "$DIR" ]; then
                echo "ℹ️  $DIR is already a symlink, skipping."
                continue
            fi

            # Exists as a directory?
            if [ -d "$DIR" ]; then
                if [ "$(ls -A "$DIR")" ]; then
                    echo "⚠️  $DIR is not empty."
                    read -p "Delete contents and replace with symlink? (y/N): " ans
                    [[ "$ans" != "y" ]] && continue
                fi
                run_cmd "systemctl stop ollama"
                run_cmd "rm -rf $DIR"
            fi

            # Create symlink
            run_cmd "ln -s $MOUNT_POINT/models $DIR"

            run_cmd "systemctl start ollama"
            run_cmd "ollama status || true"
        fi
    done

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
