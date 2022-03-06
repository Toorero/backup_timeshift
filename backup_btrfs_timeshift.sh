#! /usr/bin/env zsh

#set -x
<<<<<<< Updated upstream
# Todo: dry-run, no-deletion
=======
# Todo: dry-run
>>>>>>> Stashed changes

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
<<<<<<< Updated upstream
        echo "-vb,--vbrtfs						Enables verbose output for btrfs send/receive"
        echo "--force-mount						Forces script to mount <DEST> first"
=======
        echo "-vb,--vbrtfs                      Enables verbose output for btrfs send/receive"
        echo "--force-mount                     Forces script to mount <DEST> first"
        echo "--no-delete                       Does not sync deletion of snapshot at origin"
        echo "-q,--quiet                        Supresses output to a minimum"
        #echo "--dry-run                         Will only simulate backup process without altering any files" # WIP
>>>>>>> Stashed changes
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
<<<<<<< Updated upstream
=======
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
>>>>>>> Stashed changes
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

<<<<<<< Updated upstream
# check if root to sync from and sync destination exist
! [ -d "$ROOT" ] && echo "ERROR Folder '$ROOT' doesn't exist!" && exit 1
# try to mount sync destination
{ ! [ -d "$SYNC_DEST" ] || [ $MOUNT ] ; } \
    && ! { mkdir -p "$SYNC_DEST" && mount "$SYNC_DEST" && MOUNT=true && logv "Mounted '$SYNC_DEST'"; } \
    && echo "ERROR Folder '$SYNC_DEST' doesn't exist or can't be mounted!" && exit 1

# searching for all kind of subvolume backups of timeshift (@ and @home but we do it in a more general manner)
# e.g. subv = [@, @home, @var, ...]
declare -A synced_subv
for subv in $(find "$ROOT" -maxdepth 2 -mindepth 2 -type d -iname "@*" -exec basename {} \;)
do
	# skip already iterated subvolume prefixes
    [ -n "${synced_subv[$subv]}" ] && continue

    echo "$(tput bold)${subv} Syncing timeshift backups...$(tput sgr0)"
    
    # iterate over all subdirs of $ROOT to find the $subvol
    for subdir in "$ROOT/"*
    do
    	# subvol not present e.g. later enabled backup of @home
        ! [ -d "$subdir/$subv" ] && logv "  Skipping since $subv not present in $subdir" && continue
        
        readonly_subdir="$ROOT/../readonly/$(basename $subdir)"
        [ -d "$SYNC_DEST/snapshots/$(basename $subdir)/$subv" ] && [ -d "$readonly_subdir/$subv" ] && logv "  Skipping already synced snapshot '$(basename $subdir)'" && continue

        # test if readonly exists
        if ! [ -d "$readonly_subdir/$subv" ]
        then
            logv "  Creating readonly snapshot of '$(basename $subdir)'"
            mkdir -p "$readonly_subdir"
            btrfs subvolume snapshot -r "$subdir/$subv" "$readonly_subdir/$subv"
        fi
    
        # test if synced
        if ! [ -d "$SYNC_DEST/snapshots/$(basename $subdir)/$subv" ]
=======
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
    [ ! $DELETE ] && return 0

    subv=$1

    log "$(tput bold)${subv}$(tput sgr0) Syncing deletion of deleted timeshift backups..."
    for subdir in "$ROOT/../readonly/"*
    do
        if snapshot_deleted "$subdir"
        then
            logv "  Deleting $(basename $subdir)..."
            btrfs subvolume delete "$subdir/$subv"
            rmdir $subdir
            btrfs subvolume delete "$SYNC_DEST/snapshots/$(basename $subdir)/$subv"
            rmdir "$SYNC_DEST/snapshots/$(basename $subdir)"
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
>>>>>>> Stashed changes
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

<<<<<<< Updated upstream
            if [ -d "$past_subdir/$subv" ] && [ -d "$past_subdir/$subv" ]
            then
                logv "Creating incremental backup of $(basename $subdir)"
                btrfs $(logvv "-v") send -p "$past_subdir/$subv" "$readonly_subdir/$subv" | btrfs $(logvv "-v") receive "$SYNC_DEST/snapshots/$(basename $subdir)"
            else
                btrfs $(logvv "-v") send "$readonly_subdir/$subv" | btrfs $(logvv "-v") receive "$SYNC_DEST/snapshots/$(basename $subdir)"
=======
            if [ -d "$past_subdir/$subv" ]
            then
                logv "  Creating incremental backup of $(basename $subdir)"
                backup_incremental "$past_subdir/$subv" "$readonly_subdir/$subv" "$SYNC_DEST/snapshots/$(basename $subdir)"
            else
                backup "$readonly_subdir/$subv" "$SYNC_DEST/snapshots/$(basename $subdir)"
>>>>>>> Stashed changes
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
<<<<<<< Updated upstream
            btrfs subvolume delete "$subdir/$subv"
            #rmdir $subdir
            btrfs subvolume delete "$SYNC_DEST/snapshots/$(basename $subdir)/$subv"
            #rmdir "$SYNC_DEST/snapshots/$(basename $subdir)"
=======
            rmdir $subdir
            rmdir "$SYNC_DEST/snapshots/$(basename $subdir)"
>>>>>>> Stashed changes
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

<<<<<<< Updated upstream
=======
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

>>>>>>> Stashed changes
    # to suppress multiple syncing attempts for the same prefix (@, @home...)
    synced_subv+=([$subv]=1)
done

<<<<<<< Updated upstream
echo "Cleaning up left over directorys..."
for subdir in "$ROOT/../readonly/"*
do
    if ! [ -d "$ROOT/$(basename $subdir)" ]
    then
        logv "  Deleting $(basename $subdir)..."
        rmdir $subdir
        rmdir "$SYNC_DEST/snapshots/$(basename $subdir)"
    fi
done

[ $MOUNT ] && logv "Unmount and removing created mountpoint..." && sleep 3 && umount "$SYNC_DEST" && rmdir "$SYNC_DEST"
echo "Finished."
=======
cleanup
umount_dest

>>>>>>> Stashed changes

#set +x
