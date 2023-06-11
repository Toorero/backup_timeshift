# backup timeshift

This is a small script that backups btrfs snapshots organized in a [Timeshift](https://github.com/teejee2008/timeshift) structure to another place. This can be used to backup the snapshots to a different drive.
Whenever possible the script will copy the snapshots incremental.
All `@*` folders under the `<ROOT>` folder are considered snapshots.

#### Example `<ROOT>`
The following figure shows an example layout:
```
<ROOT>
├── 2021-05-06_02-03-24
│   └── @
├── 2021-05-16_17-24-47
│   ├── @
│   └── @home
..............
└── 2021-05-17_00-57-13
    ├── @
    └── @home
```

To copy the snapshots to an arbitray destination `<DEST>` execute:
```bash
backup_btrfs_timeshift --root=<ROOT> --destination=<DEST>
```

##### Mounting destination
If your destination is another drive and you want to make sure it was properly mounted (so you don't just copy the snapshots into a "normal" folder) it is advisable to use the `--force-mount` option.

## Implementation

1. If `--force-mount` option was set or the `<DEST>` doesn't exist yet, try to mount `<DEST>` (See `man fstab` on how to configure mount for this behaviour)
2. Search for all possible `@*` folders at **second** level.
3. For each possible `@*` subvolume candidate, search all folders (`subdir`) at **first** level if they contain said candidate:
   1. Search for orphaned **readonly** snapshots (pendant in `<ROOT>` got deleted) and delete them at `<ROOT>` **and** `<DEST>` (unless `--no-delete` specified)
   2. Create a **readonly** snapshot copy at `<ROOT>/../readonly/subdir` because only they can be send via `btrfs send`
   3. Sync readonly snapshot to `<DEST>/snapshots/subdir`. (Incremental sync is automatically applied in `find` order)

## TODOs

- [ ] dry-run option
