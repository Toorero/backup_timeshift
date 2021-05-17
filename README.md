# backup timeshift

This is a small script that backups btrfs snapshots organized in a [Timeshift](https://github.com/teejee2008/timeshift) structure to another place, a hard-drive for instance.
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

## Workings

1. If `--force-mount` option was set execute `mount <DEST>` (See `man fstab` on how to configure mount for this behaviour)
2. Search for all possible `@*` folders at **second** level.
3. For each possible `@*` subvolume candidate search all folders (`subdir`) at **first** level if they contain said candidate:
   1. Create a **readonly** snapshot copy at `<ROOT>/../readonly/subdir` because only they can be send via `btrfs send`
   2. Sync readonly snapshot to `<DEST>/snapshots/subdir`. (Incremental sync is automatically applied in `ls` order)
4. Search for orphaned **readonly** snapshots (pendant in `<ROOT>` got deleted) and delete them at `<ROOT>` **and** `<DEST>`

## TODOs

- [ ] dry-run option
- [ ] no-deletion at `<DEST>` option
- [ ] small description if `--help`
