#!/bin/sh
# dump-ext4-quotas.sh - Export user quota data from EXT4 filesystem
#
# Designed for CentOS 6 compatibility (POSIX sh, uses repquota).
# Dumps user quotas to a portable TSV file that can be imported by
# apply-xfs-quotas.sh on a Rocky 9 / XFS target system.
#
# Usage: dump-ext4-quotas.sh -d <device> [-o <output>] [-u <uid-min>] [-U <uid-max>]

set -e

SCRIPT_NAME="dump-ext4-quotas.sh"
VERSION="1.0"

# ---- Defaults ---------------------------------------------------------------
DEVICE=""
OUTPUT="quotas-dump.txt"
UID_MIN=1000
UID_MAX=65534

# ---- Helper functions -------------------------------------------------------

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME -d <device|mountpoint> [OPTIONS]

Export user quotas from an EXT4 filesystem to a portable TSV file.
Designed for CentOS 6 / EXT4 source systems.

Required:
  -d, --device <path>    Source EXT4 device or mount point (e.g. /dev/sda1 or /home)

Options:
  -o, --output <file>    Output file path (default: quotas-dump.txt)
  -u, --uid-min <uid>    Minimum UID to export (default: 1000)
  -U, --uid-max <uid>    Maximum UID to export (default: 65534)
  -h, --help             Show this help message and exit

Examples:
  # Dump quotas for /home to the default output file
  $SCRIPT_NAME -d /home

  # Dump quotas for a specific device with a custom output file
  $SCRIPT_NAME -d /dev/sda2 -o /tmp/home-quotas.txt

  # Export only system accounts (UID 500-999, CentOS 6 style)
  $SCRIPT_NAME -d /home -u 500 -U 999

  # Export a narrow UID range
  $SCRIPT_NAME -d /home -u 2000 -U 3000 -o /tmp/dept-quotas.txt

Notes:
  - Block limits are stored in KB (as reported by repquota).
  - The output file can be transferred to the target server and imported
    with apply-xfs-quotas.sh.
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

# ---- Argument parsing (POSIX getopt-compatible loop) -----------------------

while [ $# -gt 0 ]; do
    case "$1" in
        -d|--device)
            shift
            [ $# -gt 0 ] || die "Option --device requires an argument"
            DEVICE="$1"
            ;;
        -o|--output)
            shift
            [ $# -gt 0 ] || die "Option --output requires an argument"
            OUTPUT="$1"
            ;;
        -u|--uid-min)
            shift
            [ $# -gt 0 ] || die "Option --uid-min requires an argument"
            UID_MIN="$1"
            ;;
        -U|--uid-max)
            shift
            [ $# -gt 0 ] || die "Option --uid-max requires an argument"
            UID_MAX="$1"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown option: $1  (run with -h for help)"
            ;;
    esac
    shift
done

# ---- Validate arguments -----------------------------------------------------

[ -n "$DEVICE" ] || die "Device/mount point is required. Use -d <device>."

# Validate numeric UIDs
echo "$UID_MIN" | grep -qE '^[0-9]+$' || die "--uid-min must be a non-negative integer"
echo "$UID_MAX" | grep -qE '^[0-9]+$' || die "--uid-max must be a non-negative integer"
[ "$UID_MIN" -le "$UID_MAX" ] || die "--uid-min ($UID_MIN) must be <= --uid-max ($UID_MAX)"

# ---- Sanity checks ----------------------------------------------------------

# Check that repquota is available
command -v repquota >/dev/null 2>&1 || die "'repquota' not found. Install quota-tools: yum install quota"

# Resolve the device: accept both block device paths and mount points
if [ -b "$DEVICE" ]; then
    MOUNT_POINT=$(awk -v dev="$DEVICE" '$1 == dev { print $2; exit }' /proc/mounts)
    [ -n "$MOUNT_POINT" ] || die "Device $DEVICE is not mounted"
elif [ -d "$DEVICE" ]; then
    MOUNT_POINT="$DEVICE"
    DEVICE=$(awk -v mp="$MOUNT_POINT" '$2 == mp { print $1; exit }' /proc/mounts)
    [ -n "$DEVICE" ] || die "Cannot determine device for mount point $MOUNT_POINT"
else
    die "Device/mount point does not exist: $DEVICE"
fi

# Verify the filesystem is EXT4
FS_TYPE=$(awk -v mp="$MOUNT_POINT" '$2 == mp { print $3 }' /proc/mounts)
if [ "$FS_TYPE" != "ext4" ] && [ "$FS_TYPE" != "ext3" ] && [ "$FS_TYPE" != "ext2" ]; then
    echo "WARNING: Filesystem type is '$FS_TYPE', not ext4. Proceeding anyway." >&2
fi

# Check that quotas are enabled on the mount
MOUNT_OPTS=$(awk -v mp="$MOUNT_POINT" '$2 == mp { print $4 }' /proc/mounts)
echo "$MOUNT_OPTS" | grep -q "usrquota\|usrjquota" || \
    die "User quotas do not appear to be enabled on $MOUNT_POINT. Mount with 'usrquota' option."

# ---- Run repquota and parse output ------------------------------------------

TODAY=$(date +%Y-%m-%d)

echo "Dumping quotas from $DEVICE ($MOUNT_POINT) ..." >&2
echo "UID range: $UID_MIN - $UID_MAX" >&2

# repquota output format (after the header lines):
#   username/uid  --  block_used  block_soft  block_hard  grace  inode_used  inode_soft  inode_hard  grace
#
# The -n flag prints UIDs numerically. The -a flag can be used with a
# specific mount point. We use -n and specify the mount point explicitly.
#
# On older repquota (CentOS 6) the columns are separated by whitespace:
#   #uid    flags   block_used block_soft block_hard ...  inode_used inode_soft inode_hard

REPQUOTA_OUT=$(repquota -n "$MOUNT_POINT" 2>&1) || \
    die "repquota failed on $MOUNT_POINT: $REPQUOTA_OUT"

# Write the output file
{
    echo "# ext4-quota-dump v${VERSION}"
    echo "# source: $DEVICE"
    echo "# mountpoint: $MOUNT_POINT"
    echo "# date: $TODAY"
    echo "# type: user"
    echo "# uid-min: $UID_MIN"
    echo "# uid-max: $UID_MAX"
    printf 'UID\tBLOCK_SOFT\tBLOCK_HARD\tINODE_SOFT\tINODE_HARD\n'

    # Parse repquota output
    # Skip header lines (lines not starting with '#<digits>' or a digit after optional '#')
    # repquota -n outputs lines like:  #1000           --      12345   1048576  2097152          0          0  10000  20000
    echo "$REPQUOTA_OUT" | awk -v uid_min="$UID_MIN" -v uid_max="$UID_MAX" '
    /^#[0-9]/ {
        # Strip leading # to get numeric UID
        uid = substr($1, 2)
        if (uid+0 < uid_min+0 || uid+0 > uid_max+0) next
        # Fields: #uid flags block_used block_soft block_hard ... inode_used inode_soft inode_hard ...
        # $2 = flags (-- or +- etc.), $3=used, $4=soft, $5=hard, $6=grace(optional)
        # inode fields follow; their position depends on whether a grace column is present.
        # We skip used-blocks ($3) and used-inodes and only export limits.
        block_soft = $4
        block_hard = $5
        # Determine inode field positions by checking for a grace period token
        # Grace tokens contain "days" or look like "none" / time expressions.
        # A reliable heuristic: if field 6 is purely numeric it is the next used-inode count
        # (no grace); otherwise field 7 is used-inode.
        if ($6 ~ /^[0-9]+$/) {
            inode_soft = $7
            inode_hard = $8
        } else {
            inode_soft = $8
            inode_hard = $9
        }
        # Only write the line if at least one limit is non-zero
        if (block_soft+0 > 0 || block_hard+0 > 0 || inode_soft+0 > 0 || inode_hard+0 > 0) {
            printf "%s\t%s\t%s\t%s\t%s\n", uid, block_soft, block_hard, inode_soft, inode_hard
        }
    }
    '
} > "$OUTPUT"

EXPORTED=$(grep -c '^[0-9]' "$OUTPUT" 2>/dev/null || echo 0)
echo "Done. Exported $EXPORTED quota entries to $OUTPUT" >&2
