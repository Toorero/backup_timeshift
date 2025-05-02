#! /usr/bin/env zsh

# backup-timeshift Copyright (C) 2025 Julius Rüberg
#
# This program is free software: you can redistribute it and/or
# modify it under the terms of the GNU General Public License as published
# by the Free Software Foundation, either version 3 of the License,
# or (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
# See the GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License along with this program.
# If not, see <https://www.gnu.org/licenses/>.

#set -x
# Todo: dry-run

VERBOSE=
VVERBOSE=
MOUNT=
DELETE=true
QUIET=
DEBUG=
DRY=
SUBVOL_PATTERN="@*"
SYNC_DEST="/mnt/backup-timeshift"


# --- ARGUMENT PARSING ---
for i in "$@"
do
case $i in
    --help|-h)
cat << EOF
backup-timeshift Copyright (C) 2025 Julius Rüberg

-h, --help                        Shows this help message and exits
-r=<ROOT>, --root=<ROOT>          Sets root from where to backup (default: /run/timeshift/PID/backup/timeshift-btrfs/snapshots)
-d=<DEST>, --destination=<DEST>   Sets root wherre to save the copy of the snapshots (default: /mnt/backup-timeshift)
-v,--verbose                      Enables verbose output
-vb,--vbrtfs                      Enables verbose output for btrfs send/receive
--force-mount                     Forces script to mount <DEST> first
--no-delete                       Does not sync deletion of snapshot at <ROOT>. Does delete obsolute readonly subvolume at <ROOT>
-q,--quiet                        Supresses output to a minimum
--subvol=@<subv>                  Only backup specified subvolume
--subvol-pattern=<pattern>        Only backup subvolumes matching the shell pattern (default: @*)
-l,--license                      Show the licensing terms and conditions of the program

This program comes with ABSOLUTELY NO WARRANTY.
This is free software, and you are welcome to redistribute it under certain conditions;
type backup_timeshift -l to show the licensing terms and conditions.
EOF
#--dry-run                         Will only simulate backup process without altering any files" # WIP
        exit 0
        ;;
    --license|-l)
        cat COPYING
        exit 0
        ;;
    --root=*|-r=*)
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
    --subvol=@*)
        subv="${i#*=}"
        shift
        ;;
    --subvol-pattern=*)
        SUBVOL_PATTERN="${i#*=}"
        shift
        ;;
    *)
        echo "\e[1m\e[31mERROR: \e[0mUnknown argument detected: \"$i\""
        exit 2
    	;;
esac
done

ROOT="${ROOT:=/run/timeshift/$(pgrep timeshift-gtk)/backup/timeshift-btrfs/snapshots}"

## HELPERS ##

err() {
    echo "\e[1m\e[31mERROR: \e[0m$@"
    exit 1
}

indent() {
    sed 's/^/  /'
}

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

## END HELPERS ##

function umount_dest() {
    if [ $MOUNT ]
    then
        logv "Unmount and removing created mountpoint"
        sleep 3
        umount "$SYNC_DEST" && rmdir "$SYNC_DEST"
        log "Finished."
    fi
}

# a snapshot is deleted if original DIRECTORY by timeshift isn't present anymore
# WARNING: this does NOT cover partial deletion, e.g. only deleting @home but leaving @
function snapshot_deleted() {
    ! [ -d "$ROOT/$(basename $1)" ]
}

function backup_incremental() {
    CRITICAL="$3/$(basename $2)"
    [ $DEBUG ] && set -x
    btrfs $(logvv "-v") send -p "$1" "$2" | btrfs $(logvv "-v") receive "$3" # todo indent output
    [ $DEBUG ] && set +x
    unset CRITICAL
}

function backup() {
    CRITICAL="$2/$(basename $1)"
    [ $DEBUG ] && set -x
    btrfs $(logvv "-v") send "$1" | btrfs $(logvv "-v") receive "$2" # todo indent output
    [ $DEBUG ] && set +x
    unset CRITICAL
}

function sync_subv_deletion() {
    local subdir
    ! [ -d  "$ROOT/../readonly/" ] && return # don't sync deletion on first run

    [ $DELETE ] && log "$(tput bold)${subv}$(tput sgr0) Syncing deletion of deleted timeshift backups:"
    ! [ $DELETE ] && logv "$(tput bold)${subv}$(tput sgr0) Syncing deletion of readonly backups at destination only:"
    for subdir in "$ROOT/../readonly/"*
    do
        if snapshot_deleted "$subdir" && [ -d "$subdir/$subv" ]
        then
            logv "Deleting $(basename $subdir)..." | indent
            btrfs subvolume delete "$subdir/$subv" | indent
            [ $DELETE ] && btrfs subvolume delete "$SYNC_DEST/snapshots/$(basename $subdir)/$subv" | indent
        fi
    done
    log " "
}

function sync_subv() {
    local subdir
    local past_subdir

    log "$(tput bold)${subv}$(tput sgr0) Syncing timeshift backups:"

    # iterate over all subdirs of $ROOT to find the $subvol
    for subdir in "$ROOT/"*
    do
        # subvol not present e.g. later enabled backup of @home
        if ! [ -d "$subdir/$subv" ]
        then
            logv "  Skipping since $subv not present in $subdir"
            continue
        fi

        local readonly_subdir="$ROOT/../readonly/$(basename $subdir)"
        if [ -d "$SYNC_DEST/snapshots/$(basename $subdir)/$subv" ] && [ -d "$readonly_subdir/$subv" ]
        then
            logv "Skipping already synced snapshot '$(basename $subdir)'" | indent
            past_subdir="$readonly_subdir"
            continue
        fi

        # readonly subv exists
        if [ -d "$readonly_subdir/$subv" ]
        then
            logvv "Readonly snapshot '$(basename $subdir)' already exists." | indent
        else
            logv "Creating readonly snapshot of '$(basename $subdir)'" | indent
            mkdir -p "$readonly_subdir"

            CRITICAL="$readonly_subdir/$subv"
            btrfs subvolume snapshot -r "$subdir/$subv" "$readonly_subdir/$subv" | indent
            unset CRITICAL
        fi

        # if readonly is synced
        if [ -d "$SYNC_DEST/snapshots/$(basename $subdir)/$subv" ]
        then
            logvv "Readonly already synced" | indent
        else
            log "Syncing '$readonly_subdir' to '$SYNC_DEST'..." | indent
            mkdir -p "$SYNC_DEST/snapshots/$(basename $subdir)"

            if [ -d "$past_subdir/$subv" ]
            then
                logv "Creating incremental backup of $(basename $subdir)" | indent
                backup_incremental "$past_subdir/$subv" "$readonly_subdir/$subv" "$SYNC_DEST/snapshots/$(basename $subdir)"
            else
                backup "$readonly_subdir/$subv" "$SYNC_DEST/snapshots/$(basename $subdir)"
            fi
        fi

        past_subdir="$readonly_subdir"
    done
    log " "
}

function cleanup() {
    local subdir
    log "Cleaning up left over directorys:"

    for subdir in "$ROOT/../readonly/"*
    do
        if snapshot_deleted "$subdir"
        then
            logv "Deleting $(basename $subdir)" | indent
            rmdir $subdir | indent
            rmdir "$SYNC_DEST/snapshots/$(basename $subdir)" | indent
        fi
    done
}

function ihandler() {
    # delete snapshot if in critical section
    [ $CRITICAL ] && btrfs subv del "$CRITICAL"
    umount_dest
    exit 130
}


## MAIN ##

# check for privileges first
[ "$(id -u)" -ne 0 ] \
    && err "This utility needs to run as root to create btrfs subvolumes!"


# check if root & dest do exist
[ -d "$ROOT" ] || err "Folder '$ROOT' doesn't exist!"

# mount sync destination
if ! [ -d "$SYNC_DEST" ] || [ $MOUNT ]  # if dest doesn't exist or forced mount
then
    { mkdir -p "$SYNC_DEST" && mount "$SYNC_DEST" } \
        || err "Folder '$SYNC_DEST' doesn't exist or can't be mounted!"
    
    MOUNT=true                          # set mount to true if not already by forced mount
    logv "Mounted '$SYNC_DEST'"
fi

trap "ihandler" INT HUP TERM QUIT

if [ $subv ] # only perform backup of specific subvolume (e.g. @home)
then
    sync_subv_deletion
    sync_subv
else
    declare -A synced_subv
    
    # detect all subvolumes of which there are backups
    # subv = [@, @home, @var, ...]
    for subv in $(find "$ROOT" -maxdepth 2 -mindepth 2 -type d -iname "$SUBVOL_PATTERN" -exec basename {} \;)
    do
        # skip already iterated subvolume prefixes
        [ -n "${synced_subv[$subv]}" ] && continue

        sync_subv_deletion
        sync_subv

        # to suppress multiple syncing attempts for the same prefix (@, @home...)
        synced_subv+=([$subv]=1)
    done
fi

cleanup
umount_dest
trap -
