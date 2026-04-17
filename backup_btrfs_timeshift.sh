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


setopt NULL_GLOB PIPE_FAIL NO_UNSET ERR_EXIT


function err() {
    echo "\e[1m\e[31mERROR: \e[0m$@"
    exit 1
}

## ARGUMENT PARSING ##

# Defaults
_verbose=0
_vverbose=0
_delete=1
_quiet=0
_debug=0

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
--no-delete                       Does not sync deletion of snapshot at <ROOT>. Does delete obsolute readonly subvolume at <ROOT>
-q,--quiet                        Supresses output to a minimum
--subvol=@<subv>                  Only backup specified subvolume
--subvol-pattern=<pattern>        Only backup subvolumes matching the shell pattern (default: @*)
-l,--license                      Show the licensing terms and conditions of the program

This program comes with ABSOLUTELY NO WARRANTY.
This is free software, and you are welcome to redistribute it under certain conditions;
type backup_timeshift -l to show the licensing terms and conditions.
EOF
#--dry-run                         Will only simulate backup process without altering any files" # TODO
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
        _quiet=0
        _verbose=1
        shift
        ;;
    -vb|--vbtrfs)
        _quiet=0
        _verbose=1
        _vverbose=1
        shift
        ;;
    --no-delete)
        _delete=0
        shift
        ;;
    -q|--quiet)
        _quiet=1
        shift
        ;;
    # TODO: support dry-run
    # --dry-run)
    #     _dry_run=1
    #     shift
    #     ;;
    --debug)
        _debug=1
        shift
        ;;
    --subvol=@*)
        _subv="${i#*=}"
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

# env defaults
if [[ ! -v ROOT ]]; then
    readonly ts_pid=$(pgrep timeshift-gtk) \
        || err "Can't determine timeshift root: Open timeshift-gtk or manually specify a root"
    ROOT="/run/timeshift/$ts_pid/backup/timeshift-btrfs/snapshots"
fi
: "${SYNC_DEST:=/mnt/backup-timeshift}"
: "${SUBVOL_PATTERN:=@*}"

readonly verbose=$_verbose
readonly vverbose=$_vverbose
readonly quiet=$_quiet

readonly delete=$_delete
readonly debug=$_debug

## HELPERS ##

function indent() {
    sed 's/^/  /'
}

if (( $quiet )); then
    function log() { :; }
else
    function log() { echo "$*" }
fi

if (( $verbose || $vverbose )); then
    function logv() { echo "$*"; }
else
    function logv() { :; }
fi

if (( $vverbose )); then
    function logvv() { echo "$*"; }
else
    function logvv() { :; }
fi

## END HELPERS ##

function umount_dest() {
    (( ! $mounted )) && return

    logv "Unmount and removing created mountpoint"
    sleep 3

    mountpoint -q "$SYNC_DEST" || err "Not a mountpoint to unmount: '$SYNC_DEST'"

    # unmount and remove the mountpoint
    umount "$SYNC_DEST" || err "Failed to unmount '$SYNC_DEST'"
    if (( $created_mountpoint )); then
        rmdir "$SYNC_DEST" || err "Failed to remove the mountpoint: '$SYNC_DEST'"
    fi
}


function backup_incremental() {
    CRITICAL="$3/$(basename $2)"
    (( $debug )) && set -x
    btrfs $(logvv "-v") send -p "$1" "$2" | btrfs $(logvv "-v") receive "$3" # todo indent output
    (( $debug )) && set +x
    unset CRITICAL
}

function backup() {
    CRITICAL="$2/$(basename $1)"
    (( $debug )) && set -x
    btrfs $(logvv "-v") send "$1" | btrfs $(logvv "-v") receive "$2" # todo indent output
    (( $debug )) && set +x
    unset CRITICAL
}

# a snapshot is deleted if original snapshot by Timeshift isn't present anymore
function snapshot_deleted() {
    local snapshot="${1##*/}"
    local subv="$2"

    [[ ! -d $ROOT/$snapshot/$subv ]]
}

# delete all snapshot subvolumes at $sync_dest which aren't present at $ROOT
function sync_subv_deletion() {
    local sync_dest=$1
    local subv=$2

    local snapshot_path
    for snapshot_path in "$sync_dest"*(/); do
        if [[ ! -d $snapshot_path/$subv ]]; then
            continue
        fi

        if snapshot_deleted "$snapshot_path" "$subv"; then
            logv "Deleting ${snapshot_path##*/}..." | indent
            btrfs subvolume delete "$snapshot_path/$subv" | indent

            rmdir --ignore-fail-on-non-empty "$snapshot_path"
        fi
    done
}

function sync_subv() {
    local subdir
    local past_subdir

    log "$(tput bold)${subv}$(tput sgr0) Syncing timeshift backups:"

    # iterate over all subdirs of $ROOT to find the $subv
    for subdir in "$ROOT/"*(/); do
        # subv not present e.g. later enabled backup of @home
        if [[ ! -d $subdir/$subv ]]; then
            logv "  Skipping since $subv not present in $subdir"
            continue
        fi

        local readonly_subdir="$ROOT/../readonly/$(basename $subdir)"
        if [[ -d $SYNC_DEST/snapshots/$(basename $subdir)/$subv && -d $readonly_subdir/$subv ]]; then
            logv "Skipping already synced snapshot '$(basename $subdir)'" | indent
            past_subdir="$readonly_subdir"
            continue
        fi

        # readonly subv exists
        if [[ -d $readonly_subdir/$subv ]]; then
            logvv "Readonly snapshot '$(basename $subdir)' already exists." | indent
        else
            logv "Creating readonly snapshot of '$(basename $subdir)'" | indent
            mkdir -p "$readonly_subdir"

            CRITICAL="$readonly_subdir/$subv"
            btrfs subvolume snapshot -r "$subdir/$subv" "$readonly_subdir/$subv" | indent
            unset CRITICAL
        fi

        # if readonly is synced
        if [[ -d $SYNC_DEST/snapshots/$(basename $subdir)/$subv ]]; then
            logvv "Readonly already synced" | indent
        else
            log "Syncing '$readonly_subdir' to '$SYNC_DEST'..." | indent
            mkdir -p "$SYNC_DEST/snapshots/$(basename $subdir)"

            if [[ -d $past_subdir/$subv ]]; then
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

# delete partial send snapshots, cleanup mountpoint
function ihandler() {
    log "Exiting..."
    log

    [[ -v CRITICAL ]] && btrfs subv del "$CRITICAL"
    umount_dest

    [[ -v 1 ]] && exit $1
}


## MAIN ##

# check for privileges first
(( $EUID != 0 )) \
    && err "This utility needs to run as root to create btrfs subvolumes!"

function require_command() {
    local cmd=$1
    [[ -v commands[$cmd] ]] || err "Missing '$cmd' command"
}

require_command btrfs
require_command find
require_command systemd-inhibit

exec {inhibit_fd}> >(\
    systemd-inhibit --why="Backup of Timeshift snapshots" \
                    --who="backup_btrfs_timeshift" \
                    --what=idle:sleep:handle-lid-switch:shutdown \
                    --mode=block \
                    cat
)
                

# check if root & dest do exist
[[ -d $ROOT ]] || err "Folder '$ROOT' doesn't exist!"

# prohibit multiple backups to the same destination
readonly lockfile="/var/lock/backup-timeshift-$(echo $SYNC_DEST | base64).lock"
exec {lock_fd}>"$lockfile"

if ! flock -n "$lock_fd"; then
    err "Another instance of this script is already backing up to '$SYNC_DEST'"
fi

trap "ihandler" EXIT
trap "ihandler 129" HUP
trap "ihandler 130" INT
trap "ihandler 130" QUIT
trap "ihandler 130" TERM

# mount sync destination
if ! mountpoint -q "$SYNC_DEST"; then
    if [[ -d $SYNC_DEST ]]; then
        readonly created_mountpoint=0
    else 
        mkdir -p "$SYNC_DEST" || err "Failed to create mountpoint '$SYNC_DEST'"
        readonly created_mountpoint=1
    fi
    mount "$SYNC_DEST" || err "Failed to mount '$SYNC_DEST'!"

    readonly mounted=1
    logv "Mounted '$SYNC_DEST'"
else
    # already mounted => no cleanup
    readonly created_mountpoint=0
    readonly mounted=0
fi


declare -A synced_subv

# detect all subvolumes of which there are backups
# subv = [@, @home, @var, ...]
for snapshot_subv in ${_subv:-"$ROOT/"*/*(/)}; do
    subv=${snapshot_subv##*/}

    # skip already iterated subvolume prefixes
    [[ -v synced_subv[$subv] ]] && continue

    if [[ -d  $ROOT/../readonly/ ]]; then
        logv "$(tput bold)${subv}$(tput sgr0) Syncing deletion of readonly backups at destination:"
        sync_subv_deletion "$ROOT/../readonly/" "$subv"
    fi

    if (( $delete )); then
        log "$(tput bold)${subv}$(tput sgr0) Syncing deletion of deleted timeshift backups:"
        sync_subv_deletion "$SYNC_DEST/snapshots/" "$subv"
    fi

    sync_subv

    # to suppress multiple syncing attempts for the same prefix (@, @home...)
    synced_subv+=([$subv]=1)
done

log "Backup finished."
