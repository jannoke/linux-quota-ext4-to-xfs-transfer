#!/bin/sh
# dump-ext4-quotas.sh - Export user and group quota data from EXT4 filesystem
#
# Designed for CentOS 6 compatibility (POSIX sh, uses repquota).
# Dumps user and/or group quotas to a portable TSV file that can be imported by
# apply-xfs-quotas.sh on a Rocky 9 / XFS target system.
#
# Usage: dump-ext4-quotas.sh -d <device> [-o <output>] [-t <type>] [-u <uid-min>] [-U <uid-max>]

set -e

SCRIPT_NAME="dump-ext4-quotas.sh"
VERSION="1.1"

# ---- Defaults ---------------------------------------------------------------
DEVICE=""
OUTPUT="quotas-dump.txt"
QUOTA_TYPE="all"
UID_MIN=1000
UID_MAX=65534

# ---- Helper functions -------------------------------------------------------

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME -d <device|mountpoint> [OPTIONS]

Export user and/or group quotas from an EXT4 filesystem to a portable TSV file.
Designed for CentOS 6 / EXT4 source systems.

Required:
  -d, --device <path>    Source EXT4 device or mount point (e.g. /dev/sda1 or /home)

Options:
  -o, --output <file>    Output file path (default: quotas-dump.txt)
  -t, --type <type>      Quota type to dump: user, group, or all (default: all)
  -u, --uid-min <id>     Minimum UID/GID to export (default: 1000)
  -U, --uid-max <id>     Maximum UID/GID to export (default: 65534)
  -h, --help             Show this help message and exit

Examples:
  # Dump all (user + group) quotas from /home
  $SCRIPT_NAME -d /home

  # Dump only group quotas
  $SCRIPT_NAME -d /home -t group -o /tmp/home-group-quotas.txt

  # Dump only user quotas for a specific device
  $SCRIPT_NAME -d /dev/sda2 -t user -o /tmp/home-quotas.txt

  # Export only IDs 2000-3000
  $SCRIPT_NAME -d /home -u 2000 -U 3000 -o /tmp/dept-quotas.txt

Notes:
  - Block limits are stored in KB (as reported by repquota).
  - The output file can be transferred to the target server and imported
    with apply-xfs-quotas.sh.
  - Named entries (usernames/groupnames) are resolved to numeric IDs via getent.
  - Entries that cannot be resolved to numeric IDs are skipped.
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

# ---- Argument parsing (POSIX-compatible loop) --------------------------------

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
        -t|--type)
            shift
            [ $# -gt 0 ] || die "Option --type requires an argument"
            QUOTA_TYPE="$1"
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

# Validate quota type
case "$QUOTA_TYPE" in
    user|group|all) ;;
    *) die "--type must be 'user', 'group', or 'all'" ;;
esac

# Validate numeric ID range
echo "$UID_MIN" | grep -qE '^[0-9]+$' || die "--uid-min must be a non-negative integer"
echo "$UID_MAX" | grep -qE '^[0-9]+$' || die "--uid-max must be a non-negative integer"
[ "$UID_MIN" -le "$UID_MAX" ] || die "--uid-min ($UID_MIN) must be <= --uid-max ($UID_MAX)"

# ---- Sanity checks ----------------------------------------------------------

# Check that required tools are available
command -v repquota >/dev/null 2>&1 || die "'repquota' not found. Install quota-tools: yum install quota"
command -v getent >/dev/null 2>&1 || die "'getent' not found. Install glibc-common."

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

# Check that the required quota type(s) are enabled on the mount
MOUNT_OPTS=$(awk -v mp="$MOUNT_POINT" '$2 == mp { print $4 }' /proc/mounts)
HAS_USR_QUOTA=0
HAS_GRP_QUOTA=0
if echo "$MOUNT_OPTS" | grep -q "usrquota\|usrjquota"; then HAS_USR_QUOTA=1; fi
if echo "$MOUNT_OPTS" | grep -q "grpquota\|grpjquota"; then HAS_GRP_QUOTA=1; fi

case "$QUOTA_TYPE" in
    user)
        [ "$HAS_USR_QUOTA" -eq 1 ] || \
            die "User quotas are not enabled on $MOUNT_POINT. Mount with 'usrquota' option."
        ;;
    group)
        [ "$HAS_GRP_QUOTA" -eq 1 ] || \
            die "Group quotas are not enabled on $MOUNT_POINT. Mount with 'grpquota' option."
        ;;
    all)
        if [ "$HAS_USR_QUOTA" -eq 0 ] && [ "$HAS_GRP_QUOTA" -eq 0 ]; then
            die "Neither user nor group quotas are enabled on $MOUNT_POINT."
        fi
        if [ "$HAS_USR_QUOTA" -eq 0 ]; then
            echo "WARNING: User quotas not enabled on $MOUNT_POINT, skipping user quotas." >&2
        fi
        if [ "$HAS_GRP_QUOTA" -eq 0 ]; then
            echo "WARNING: Group quotas not enabled on $MOUNT_POINT, skipping group quotas." >&2
        fi
        ;;
esac

# ---- Run repquota and parse output ------------------------------------------

TODAY=$(date +%Y-%m-%d)

echo "Dumping quotas from $DEVICE ($MOUNT_POINT) ..." >&2
echo "Quota type: $QUOTA_TYPE  |  ID range: $UID_MIN - $UID_MAX" >&2

# repquota output format (after the header lines):
#   name/uid  flags  block_used  block_soft  block_hard  [grace]  inode_used  inode_soft  inode_hard  [grace]
#
# With -n flag, numeric IDs appear as #uid / #gid.  Without -n (or when the
# system cannot resolve an ID), named entries appear as plain strings.
# We handle all three variants:
#   #386179504  -- already numeric, strip the '#'
#   2004        -- already numeric, use as-is
#   gs003       -- name, resolve to numeric ID with getent

# dump_quota_type TYPE
#   TYPE = "user" or "group"
#   Runs repquota, resolves all names to numeric IDs, applies the ID range
#   filter, and writes matching lines as:
#     TYPE<TAB>ID<TAB>BLOCK_SOFT<TAB>BLOCK_HARD<TAB>INODE_SOFT<TAB>INODE_HARD
dump_quota_type() {
    _qt="$1"
    if [ "$_qt" = "group" ]; then
        _repquota_flags="-ng"
        _getent_db="group"
    else
        _repquota_flags="-n"
        _getent_db="passwd"
    fi

    _out=$(repquota $_repquota_flags "$MOUNT_POINT" 2>&1) || \
        die "repquota failed for ${_qt} quotas on $MOUNT_POINT: $_out"

    # Use awk to identify data lines (second field matches flags pattern [-+][-+])
    # and extract the relevant columns.  Grace-period detection:
    #   - No block grace: $3=bused  $4=bsoft  $5=bhard  $6=iused  $7=isoft  $8=ihard
    #   - Block grace:    $3=bused  $4=bsoft  $5=bhard  $6=brace  $7=iused  $8=isoft  $9=ihard
    # Heuristic: if $6 is purely numeric there is no block grace field.
    printf '%s\n' "$_out" | awk '
        $2 ~ /^[-+][-+]$/ {
            name = $1
            block_soft = $4
            block_hard = $5
            if ($6 ~ /^[0-9]+$/) {
                inode_soft = $7
                inode_hard = $8
            } else {
                inode_soft = $8
                inode_hard = $9
            }
            if (block_soft+0 > 0 || block_hard+0 > 0 || inode_soft+0 > 0 || inode_hard+0 > 0) {
                printf "%s\t%s\t%s\t%s\t%s\n", name, block_soft, block_hard, inode_soft, inode_hard
            }
        }
    ' | while IFS=$(printf '\t') read -r _name _bs _bh _is _ih; do
        # Resolve _name to a numeric ID
        case "$_name" in
            \#*)
                # Numeric ID with leading '#' (repquota -n style)
                _id="${_name#\#}"
                ;;
            *[!0-9]*)
                # Named entry (username or groupname) – resolve with getent
                _id=$(getent "$_getent_db" "$_name" 2>/dev/null | cut -d: -f3)
                ;;
            *)
                # Already a bare number
                _id="$_name"
                ;;
        esac

        # Skip entries that could not be resolved
        [ -n "$_id" ] || continue

        # Ensure the resolved value is purely numeric
        case "$_id" in
            *[!0-9]*) continue ;;
        esac

        # Apply ID range filter
        [ "$_id" -ge "$UID_MIN" ] && [ "$_id" -le "$UID_MAX" ] || continue

        printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$_qt" "$_id" "$_bs" "$_bh" "$_is" "$_ih"
    done
}

# ---- Write output file -------------------------------------------------------
{
    echo "# ext4-quota-dump v${VERSION}"
    echo "# source: $DEVICE"
    echo "# mountpoint: $MOUNT_POINT"
    echo "# date: $TODAY"
    echo "# uid-min: $UID_MIN"
    echo "# uid-max: $UID_MAX"
    printf 'TYPE\tID\tBLOCK_SOFT\tBLOCK_HARD\tINODE_SOFT\tINODE_HARD\n'

    case "$QUOTA_TYPE" in
        user)
            dump_quota_type user
            ;;
        group)
            dump_quota_type group
            ;;
        all)
            if [ "$HAS_USR_QUOTA" -eq 1 ]; then dump_quota_type user;  fi
            if [ "$HAS_GRP_QUOTA" -eq 1 ]; then dump_quota_type group; fi
            ;;
    esac
} > "$OUTPUT"

EXPORTED=$(grep -cE $'^(user|group)\t' "$OUTPUT" 2>/dev/null || echo 0)
echo "Done. Exported $EXPORTED quota entries to $OUTPUT" >&2
