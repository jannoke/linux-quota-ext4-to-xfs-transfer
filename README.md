# EXT4 to XFS Quota Transfer Tools

Transfer disk quota settings from an EXT4 filesystem (CentOS 6) to an XFS filesystem (Rocky 9), either between two machines or on the same host during a storage migration.

---

## Overview

When migrating data from an EXT4 partition to an XFS partition you need to preserve per-user disk quotas.  These two scripts automate that process:

| Script | Run on | Purpose |
|--------|--------|---------|
| `dump-ext4-quotas.sh` | Source (CentOS 6 / EXT4) | Export quota limits to a portable TSV file |
| `apply-xfs-quotas.sh` | Target (Rocky 9 / XFS)   | Import the TSV file and apply limits with `xfs_quota` |

The dump file is plain text and can be reviewed, edited, or transferred with `scp` / `rsync`.

---

## Prerequisites

### Source server (CentOS 6 / EXT4)

- `quota` / `repquota` — usually in the `quota` package: `yum install quota`
- EXT4 filesystem mounted with the `usrquota` option  
  Example `/etc/fstab` entry:
  ```
  /dev/sda2  /home  ext4  defaults,usrquota  0 2
  ```
- Quotas initialised and turned on:
  ```bash
  quotacheck -cum /home
  quotaon /home
  ```

### Target server (Rocky 9 / XFS)

- `xfs_quota` — usually in the `xfsprogs` package: `dnf install xfsprogs`
- XFS filesystem mounted with the `usrquota` option  
  Example `/etc/fstab` entry:
  ```
  /dev/sdb1  /home  xfs  defaults,usrquota  0 2
  ```

---

## Installation

```bash
# Clone or download the repository
git clone https://github.com/jannoke/linux-quota-ext4-to-xfs-transfer.git
cd linux-quota-ext4-to-xfs-transfer

# Make the scripts executable
chmod +x dump-ext4-quotas.sh apply-xfs-quotas.sh
```

---

## Usage

### Step 1 – Export quotas from the EXT4 source

Run **on the source server** (CentOS 6):

```bash
./dump-ext4-quotas.sh -d /home -o quotas-dump.txt
```

Transfer the dump file to the target server:

```bash
scp quotas-dump.txt user@target:/tmp/quotas-dump.txt
```

### Step 2 – Apply quotas to the XFS target

Run **on the target server** (Rocky 9):

```bash
./apply-xfs-quotas.sh -d /home -i /tmp/quotas-dump.txt
```

---

## Detailed Usage Examples

### `dump-ext4-quotas.sh`

```bash
# Basic: dump all quotas from /home
./dump-ext4-quotas.sh -d /home

# Specify a block device instead of a mount point
./dump-ext4-quotas.sh -d /dev/sda2 -o /tmp/home-quotas.txt

# Export only UIDs 2000–3000
./dump-ext4-quotas.sh -d /home -u 2000 -U 3000 -o dept-quotas.txt

# Show help
./dump-ext4-quotas.sh --help
```

### `apply-xfs-quotas.sh`

```bash
# Basic: apply quotas (prompts before overwriting existing entries)
./apply-xfs-quotas.sh -d /home -i quotas-dump.txt

# Dry-run: see exactly which xfs_quota commands would run
./apply-xfs-quotas.sh -d /home -i quotas-dump.txt --dry-run

# Force overwrite all existing quotas without prompting
./apply-xfs-quotas.sh -d /home -i quotas-dump.txt --force

# Apply only a subset of UIDs from the dump file
./apply-xfs-quotas.sh -d /home -i quotas-dump.txt -u 2000 -U 3000

# Specify device by block device path
./apply-xfs-quotas.sh -d /dev/sdb1 -i /tmp/home-quotas.txt --force

# Show help
./apply-xfs-quotas.sh --help
```

---

## Dump File Format

The dump file is a plain-text TSV (tab-separated values) file with comment header lines followed by one row per user.

```
# ext4-quota-dump v1.0
# source: /dev/sda2
# mountpoint: /home
# date: 2026-04-14
# type: user
# uid-min: 1000
# uid-max: 65534
UID	BLOCK_SOFT	BLOCK_HARD	INODE_SOFT	INODE_HARD
1000	1048576	2097152	10000	20000
1001	524288	1048576	5000	10000
```

| Column | Description |
|--------|-------------|
| `UID` | Numeric user ID |
| `BLOCK_SOFT` | Soft block limit in **KB** |
| `BLOCK_HARD` | Hard block limit in **KB** |
| `INODE_SOFT` | Soft inode (file count) limit |
| `INODE_HARD` | Hard inode (file count) limit |

Only users that have at least one non-zero limit are included.

You can edit the file manually before applying it to the target — for example to adjust limits or remove specific users.

---

## Unit Conversion

| Detail | EXT4 (`repquota`) | XFS (`xfs_quota`) |
|--------|-------------------|-------------------|
| Block unit | 1 KB | 1 KB when using the `k` suffix in limit commands |
| Inode unit | count | count |

`dump-ext4-quotas.sh` stores block limits in KB (as `repquota` reports them).  
`apply-xfs-quotas.sh` passes these values directly to `xfs_quota` with the `k` suffix, so **no manual conversion is necessary**.

---

## Troubleshooting

### `repquota` reports "No filesystems with quota detected"

- Ensure the EXT4 filesystem is mounted with `usrquota` in `/etc/fstab`.
- Run `quotaon -av` to enable quotas, then re-run the dump script.

### `xfs_quota: cannot set limits: Operation not permitted`

- Ensure you are running `apply-xfs-quotas.sh` as **root**.
- Verify that the XFS filesystem is mounted with `usrquota`.  
  Check with: `grep usrquota /proc/mounts`

### Quotas appear to be zero after applying

- Run `xfs_quota -x -c "report -u" /home` to verify that limits were set.
- Confirm the target mount point matches the device you specified with `-d`.

### `command not found: xfs_quota`

```bash
dnf install xfsprogs
```

### `command not found: repquota`

```bash
yum install quota
```

---

## License

MIT License

Copyright (c) 2026

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
