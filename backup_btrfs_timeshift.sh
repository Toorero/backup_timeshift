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
autoload -U colors && colors


function err() {
    echo "$fg_bold[red]ERROR:$reset_color $@"
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
$fg_bold[cyan]backup-timeshift Copyright (C) 2025 Julius Rüberg$reset_color

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
        echo "$fg_bold[red]ERROR:$reset_color Unknown argument detected: \"$i\""
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
    function log() { if [[ -v 2 ]]; then; echo "$2"; fi; }
else
    function log() { echo "${1- }"; }
fi

if (( $verbose || $vverbose )); then
    function logv() { echo "${1- }"; }
else
    function logv() { if [[ -v 2 ]]; then; echo "$2"; fi; }
fi

if (( $vverbose )); then
    function logvv() { echo "${1- }"; }
else
    function logvv() { if [[ -v 2 ]]; then; echo "$2"; fi; }
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
    local parent_subv=$1
    local subv=$2
    local dest=$3

    CRITICAL="$dest"
    (( $debug )) && set -x
    # TODO: indent output
    btrfs $(logvv "-v" "-q") send -p "$parent_subv" "$subv" | btrfs $(logvv "-v" "-q") receive "${dest%/*}" 
    (( $debug )) && set +x
    unset CRITICAL
}

function backup() {
    local subv=$1
    local dest=$2

    CRITICAL="$dest"
    (( $debug )) && set -x
    # TODO: indent output
    btrfs $(logvv "-v") send "$subv" | btrfs $(logvv "-v") receive "${dest%/*}"
    (( $debug )) && set +x
    unset CRITICAL
}

# a snapshot is deleted if original snapshot by Timeshift isn't present anymore
function snapshot_deleted() {
    local snapshot=$1
    local subv=$2

    [[ ! -d $ROOT/$snapshot/$subv ]]
}

# delete all snapshot subvolumes at $sync_dest which aren't present at $ROOT
function sync_subv_deletion() {
    local sync_dest=$1
    local subv=$2

    local snapshot_path
    for snapshot_path in "$sync_dest"/*/"$subv"(/); do
        local snapshot=${${snapshot_path#$sync_dest/}%/$subv}

        if snapshot_deleted "$snapshot" "$subv"; then
            logv "Deleting ${snapshot}..." | indent
            btrfs subvolume delete "$snapshot_path" | indent

            rmdir --ignore-fail-on-non-empty "${snapshot_path%/$subv}"
        fi
    done
}

# send all snapshots of $subvol to $SYNC_DEST
function sync_subv() {
    local subv=$1

    log "$fg_bold[cyan]$subv$reset_color Syncing timeshift backups:"

    local snapshot_path
    local past_snapshot
    local past_readonly_snapshot_path

    for snapshot_path in "$ROOT"/*/"$subv"(/); do
        local snapshot=${${snapshot_path#$ROOT/}%/$subv} # usually date of the snapshot

        local readonly_snapshot_path=$ROOT/../readonly/$snapshot/$subv
        local dest_snapshot_path=$SYNC_DEST/snapshots/$snapshot/$subv

        # Create readonly snapshot.
        # This is needed since we can only send readonly snapshots.
        if [[ ! -d $readonly_snapshot_path ]]; then
            logv "Creating readonly snapshot of '$snapshot'" | indent
            mkdir -p "${readonly_snapshot_path%/$subv}"

            CRITICAL="$readonly_snapshot_path"
            btrfs subvolume snapshot -r "$snapshot_path" "${readonly_snapshot_path%/$subv}" | indent
            unset CRITICAL
        else
            logvv "Readonly snapshot '$snapshot' already exists." | indent
        fi

        # Send readonly snapshot to $SYNC_DEST
        if [[ ! -d $dest_snapshot_path ]]; then
            mkdir -p "${dest_snapshot_path%$subv}"

            if [[ -v past_readonly_snapshot_path && -d $past_readonly_snapshot_path ]]; then
                log "Syncing '$snapshot' (incremental) ..." | indent
                backup_incremental \
                    "$past_readonly_snapshot_path" \
                    "$readonly_snapshot_path" \
                    "$dest_snapshot_path"
            else
                log "Syncing '$snapshot' ..." | indent
                backup "$readonly_snapshot_path" "$dest_snapshot_path"
            fi
        else
            logv "Skipping '$snapshot': Already synced" | indent
        fi

        past_snapshot=$snapshot
        past_readonly_snapshot_path=$readonly_snapshot_path
    done
    log " "
}

# delete partial send snapshots, cleanup mountpoint
function ihandler() {
    log "Exiting..."
    log " "

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
    (( ${+synced_subv[$subv]} )) && continue

    # sync deletion: readonly 
    if [[ -d  $ROOT/../readonly/ ]]; then
        logv "$fg_bold[cyan]$subv$reset_color Syncing deletion of readonly backups at destination:"
        sync_subv_deletion "$ROOT/../readonly" "$subv"
        log " "
    fi

    # sync deletion: $SYNC_DEST
    if (( $delete )); then
        log "$fg_bold[cyan]$subv$reset_color Syncing deletion of deleted timeshift backups:"
        sync_subv_deletion "$SYNC_DEST/snapshots" "$subv"
        log " "
    fi

    sync_subv "$subv"

    # to suppress multiple syncing attempts for the same prefix (@, @home...)
    synced_subv+=([$subv]=1)
done

log "Backup finished."
