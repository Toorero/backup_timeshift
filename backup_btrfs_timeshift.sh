#! /usr/bin/env zsh

#set -x
# Todo: dry-run

VERBOSE=
VVERBOSE=
MOUNT=
DELETE=true
QUIET=
DEBUG=
DRY=


# --- ARGUMENT PARSING ---
for i in "$@"
do
case $i in
    --help|-h)
        echo "-h, --help                        Shows this help message and exits"
        echo "-r=<ROOT>, --root=<ROOT>          Sets root from where to backup (default: /run/timeshift/backup/timeshift-btrfs/snapshots)"
        echo "-d=<DEST>, --destination=<DEST>   Sets root wherre to save the copy of the snapshots (default: /mnt/backup-timeshift)"
        echo "-v,--verbose                      Enables verbose output"
        echo "-vb,--vbrtfs                      Enables verbose output for btrfs send/receive"
        echo "--force-mount                     Forces script to mount <DEST> first"
        echo "--no-delete                       Does not sync deletion of snapshot at <ROOT>. Does delete obsolute readonly subvolume at <ROOT>"
        echo "-q,--quiet                        Supresses output to a minimum"
        #echo "--dry-run                         Will only simulate backup process without altering any files" # WIP
        exit 0
        shift
        ;;
    --root=*)
        ROOT="${i#*=}"
        shift
        ;;
    --dest*=*|-d=*)
        SYNC_DEST="${i#*=}"
        shift
        ;;
    -v|--verbose)
        VERBOSE=true
        shift
        ;;
    -vb|--vbtrfs)
        VVERBOSE=true
        shift
        ;;
    --force-mount)
        MOUNT=true
        shift
        ;;
    --no-delete)
        DELETE=
        shift
        ;;
    -q|--quiet)
        QUIET=true
        shift
        ;;
    --dry-run)
        DRY=true
        shift
        ;;
    --debug)
        DEBUG=true
        shift
        ;;
    *)
        echo "Unknown argument detected: \"$i\""
        exit 1
    	;;
esac
done
if [ "$(id -u)" -ne 0 ]; then
        echo "ERROR This utility needs to run as root to create btrfs subvolumes!"
        exit 1
fi

## HELPERS ##

log() {
    [ ! $QUIET ] && echo "$@"
    return 0
}

logv() {
    { [ $VERBOSE ] || [ $VVERBOSE ] ; } && echo "$@"
    return 0
}

logvv() {
    [ $VVERBOSE ] && echo "$@"
    return 0
}

err() {
    echo "\e[1m\e[31mERROR: \e[0m$@"
    exit 1
}

function umount_dest() {
    if [ $MOUNT ]
    then
        logv "Unmount and removing created mountpoint..."
        sleep 3
        umount "$SYNC_DEST" && rmdir "$SYNC_DEST"
        echo "Finished."
    fi
}

# a snapshot is deleted if original directory by timeshift isn't present anymore
function snapshot_deleted() {
    ! [ -d "$ROOT/$(basename $1)" ]
}

function backup_incremental() {
    CRITICAL="$3/$(basename $2)"
    [ $DEBUG ] && set -x
    btrfs $(logvv "-v") send -p "$1" "$2" | btrfs $(logvv "-v") receive "$3"
    [ $DEBUG ] && set +x
    CRITICAL=
}

function backup() {
    CRITICAL="$2/$(basename $1)"
    [ $DEBUG ] && set -x
    btrfs $(logvv "-v") send "$1" | btrfs $(logvv "-v") receive "$2"
    [ $DEBUG ] && set +x
    CRITICAL=
}

function sync_subv_deletion() {
    subv=$1

    [ $DELETE ] && log "$(tput bold)${subv}$(tput sgr0) Syncing deletion of deleted timeshift backups..."
    ! [ $DELETE ] && logv "$(tput bold)${subv}$(tput sgr0) Syncing deletion of readonly backups at destination only..."
    for subdir in "$ROOT/../readonly/"*
    do
        if snapshot_deleted "$subdir" && [ -d "$subdir/$subv" ]
        then
            logv "  Deleting $(basename $subdir)..."
            btrfs subvolume delete "$subdir/$subv"
            [ $DELETE ] && btrfs subvolume delete "$SYNC_DEST/snapshots/$(basename $subdir)/$subv"
        fi
    done
}

function sync_subv() {
    subv=$1

    log "$(tput bold)${subv}$(tput sgr0) Syncing timeshift backups..."

    # iterate over all subdirs of $ROOT to find the $subvol
    for subdir in "$ROOT/"*
    do
        # subvol not present e.g. later enabled backup of @home
        if ! [ -d "$subdir/$subv" ]
        then
            logv "  Skipping since $subv not present in $subdir"
            continue
        fi

        readonly_subdir="$ROOT/../readonly/$(basename $subdir)"
        if [ -d "$SYNC_DEST/snapshots/$(basename $subdir)/$subv" ] && [ -d "$readonly_subdir/$subv" ]
        then
            logv "  Skipping already synced snapshot '$(basename $subdir)'"
            past_subdir="$readonly_subdir"
            continue
        fi

        # readonly subv exists
        if [ -d "$readonly_subdir/$subv" ]
        then
            logvv "  Readonly snapshot '$(basename $subdir)' already exists."
        else
            logv "  Creating readonly snapshot of '$(basename $subdir)'"
            mkdir -p "$readonly_subdir"
            
            CRITICAL="$readonly_subdir/$subv"
            btrfs subvolume snapshot -r "$subdir/$subv" "$readonly_subdir/$subv"
            CRITICAL=
        fi

        # if readonly is synced
        if [ -d "$SYNC_DEST/snapshots/$(basename $subdir)/$subv" ]
        then
            logvv "  Readonly already synced"
        else
            log "  Syncing '$readonly_subdir' to '$SYNC_DEST'..."
            mkdir -p "$SYNC_DEST/snapshots/$(basename $subdir)"

            if [ -d "$past_subdir/$subv" ]
            then
                logv "  Creating incremental backup of $(basename $subdir)"
                backup_incremental "$past_subdir/$subv" "$readonly_subdir/$subv" "$SYNC_DEST/snapshots/$(basename $subdir)"
            else
                backup "$readonly_subdir/$subv" "$SYNC_DEST/snapshots/$(basename $subdir)"
            fi
        fi

        past_subdir="$readonly_subdir"
    done
}

function cleanup() {
    log "Cleaning up left over directorys..."

    for subdir in "$ROOT/../readonly/"*
    do
        if snapshot_deleted "$subdir"
        then
            logv "  Deleting $(basename $subdir)..."
            rmdir $subdir
            rmdir "$SYNC_DEST/snapshots/$(basename $subdir)"
        fi
    done
}

function ihandler() {
    # delete snapshot if int in critical section
    [ $CRITICAL ] && btrfs subv del "$CRITICAL"
    umount_dest
    exit 1
}


## MAIN ##

# stores critical subv to delete to avoid corruption on INT
CRITICAL=

ROOT="${ROOT:=/run/timeshift/backup/timeshift-btrfs/snapshots}"
SYNC_DEST="${SYNC_DEST:=/mnt/backup-timeshift}"

# check if root to sync from and sync destination exist
! [ -d "$ROOT" ] && err "Folder '$ROOT' doesn't exist!"
# try to mount sync destination
{ ! [ -d "$SYNC_DEST" ] || [ $MOUNT ] ; } \
    && ! { mkdir -p "$SYNC_DEST" && mount "$SYNC_DEST" && MOUNT=true && logv "Mounted '$SYNC_DEST'"; } \
    && err "Folder '$SYNC_DEST' doesn't exist or can't be mounted!"

trap ihandler INT

# searching for all kind of subvolume backups of timeshift (@ and @home but we do it in a more general manner)
# e.g. subv = [@, @home, @var, ...]
declare -A synced_subv
for subv in $(find "$ROOT" -maxdepth 2 -mindepth 2 -type d -iname "@*" -exec basename {} \;)
do
    # skip already iterated subvolume prefixes
    [ -n "${synced_subv[$subv]}" ] && continue

    sync_subv_deletion $subv
    sync_subv $subv

    # to suppress multiple syncing attempts for the same prefix (@, @home...)
    synced_subv+=([$subv]=1)
done

cleanup
umount_dest


#set +x
