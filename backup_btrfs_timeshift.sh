#! /usr/bin/env bash

#set -x
# Todo: dry-run, no-deletion

VERBOSE=
VVERBOSE=
MOUNT=

# --- ARGUMENT PARSING ---
for i in "$@"
do
case $i in
    --help|-h)
        echo "-h, --help                        Shows this help message and exits"
        echo "-r=<ROOT>, --root=<ROOT>          Sets root from where to backup (default: /run/timeshift/backup/timeshift-btrfs/snapshots)"
        echo "-d=<DEST>, --destination=<DEST>   Sets root wherre to save the copy of the snapshots (default: /mnt/backup-timeshift)"
        echo "-v,--verbose                      Enables verbose output"
        echo "-vb,--vbrtfs						Enables verbose output for btrfs send/receive"
        echo "--force-mount						Forces script to mount <DEST> first"
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

logv() {
    { [ $VERBOSE ] || [ $VVERBOSE ] ; } && echo "$@"
    return 0
}

logvv() {
    [ $VVERBOSE ] && echo "$@"
    return 0
}



ROOT="${ROOT:=/run/timeshift/backup/timeshift-btrfs/snapshots}"
SYNC_DEST="${SYNC_DEST:=/mnt/backup-timeshift}"

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
        then
            echo "  Syncing '$readonly_subdir' to '$SYNC_DEST'..."
            mkdir -p "$SYNC_DEST/snapshots/$(basename $subdir)"

            if [ -d "$past_subdir/$subv" ] && [ -d "$past_subdir/$subv" ]
            then
                logv "Creating incremental backup of $(basename $subdir)"
                btrfs $(logvv "-v") send -p "$past_subdir/$subv" "$readonly_subdir/$subv" | btrfs $(logvv "-v") receive "$SYNC_DEST/snapshots/$(basename $subdir)"
            else
                btrfs $(logvv "-v") send "$readonly_subdir/$subv" | btrfs $(logvv "-v") receive "$SYNC_DEST/snapshots/$(basename $subdir)"
            fi
        fi

        past_subdir="$readonly_subdir"
    done

    echo "$subv_bold" "Syncing deletion of deleted timeshift backups..."
    for subdir in "$ROOT/../readonly/"*
    do
        if ! [ -d "$ROOT/$(basename $subdir)" ]
        then
            logv "  Deleting $(basename $subdir)..."
            btrfs subvolume delete "$subdir/$subv"
            #rmdir $subdir
            btrfs subvolume delete "$SYNC_DEST/snapshots/$(basename $subdir)/$subv"
            #rmdir "$SYNC_DEST/snapshots/$(basename $subdir)"
        fi
    done

    # to suppress multiple syncing attempts for the same prefix (@, @home...)
    synced_subv+=([$subv]=1)
done

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

#set +x
