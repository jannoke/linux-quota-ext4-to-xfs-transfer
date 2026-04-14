#!/bin/bash
# apply-xfs-quotas.sh - Import quota data from dump file and apply to XFS filesystem
#
# Designed for Rocky 9 / XFS target systems. Reads the TSV file produced by
# dump-ext4-quotas.sh and applies the quotas using xfs_quota.
#
# Usage: apply-xfs-quotas.sh -d <device> -i <input> [OPTIONS]

set -euo pipefail

SCRIPT_NAME="apply-xfs-quotas.sh"

# ---- Defaults ---------------------------------------------------------------
DEVICE=""
INPUT=""
DRY_RUN=0
FORCE=0
UID_MIN=1000
UID_MAX=65534

# ---- Helper functions -------------------------------------------------------

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME -d <device|mountpoint> -i <input-file> [OPTIONS]

Apply user quotas from a dump file (created by dump-ext4-quotas.sh) to an
XFS filesystem. Designed for Rocky 9 / XFS target systems.

Required:
  -d, --device <path>    Target XFS device or mount point (e.g. /dev/sdb1 or /home)
  -i, --input  <file>    Input dump file produced by dump-ext4-quotas.sh

Options:
  -n, --dry-run          Print the xfs_quota commands that would be run, but
                         do not execute them
  -f, --force            Overwrite existing quotas without prompting
  -u, --uid-min <uid>    Minimum UID to apply (default: 1000)
  -U, --uid-max <uid>    Maximum UID to apply (default: 65534)
  -h, --help             Show this help message and exit

Examples:
  # Apply quotas (will prompt before overwriting existing entries)
  $SCRIPT_NAME -d /home -i quotas-dump.txt

  # Dry-run: show what would be applied without making changes
  $SCRIPT_NAME -d /home -i quotas-dump.txt --dry-run

  # Force overwrite all existing quotas without prompting
  $SCRIPT_NAME -d /home -i quotas-dump.txt --force

  # Apply only a subset of UIDs
  $SCRIPT_NAME -d /home -i quotas-dump.txt -u 2000 -U 3000

  # Specify device by block device path with force flag
  $SCRIPT_NAME -d /dev/sdb1 -i /tmp/home-quotas.txt --force

Notes:
  - EXT4 stores block limits in 1 KB units.  XFS uses the same 1 KB unit when
    limits are set via 'xfs_quota -x -c "limit ..."', so no conversion is needed.
  - Inode limits are dimensionless counts and require no conversion.
  - User quotas must be enabled on the XFS mount (mount option: usrquota).
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

# ---- Argument parsing -------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--device)
            shift
            [[ $# -gt 0 ]] || die "Option --device requires an argument"
            DEVICE="$1"
            ;;
        -i|--input)
            shift
            [[ $# -gt 0 ]] || die "Option --input requires an argument"
            INPUT="$1"
            ;;
        -n|--dry-run)
            DRY_RUN=1
            ;;
        -f|--force)
            FORCE=1
            ;;
        -u|--uid-min)
            shift
            [[ $# -gt 0 ]] || die "Option --uid-min requires an argument"
            UID_MIN="$1"
            ;;
        -U|--uid-max)
            shift
            [[ $# -gt 0 ]] || die "Option --uid-max requires an argument"
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

[[ -n "$DEVICE" ]] || die "Device/mount point is required. Use -d <device>."
[[ -n "$INPUT"  ]] || die "Input file is required. Use -i <file>."
[[ -f "$INPUT"  ]] || die "Input file not found: $INPUT"

[[ "$UID_MIN" =~ ^[0-9]+$ ]] || die "--uid-min must be a non-negative integer"
[[ "$UID_MAX" =~ ^[0-9]+$ ]] || die "--uid-max must be a non-negative integer"
(( UID_MIN <= UID_MAX ))     || die "--uid-min ($UID_MIN) must be <= --uid-max ($UID_MAX)"

# ---- Sanity checks ----------------------------------------------------------

# Check that xfs_quota is available
command -v xfs_quota >/dev/null 2>&1 || die "'xfs_quota' not found. Install xfsprogs: dnf install xfsprogs"

# Resolve device / mount point
if [[ -b "$DEVICE" ]]; then
    MOUNT_POINT=$(awk -v dev="$DEVICE" '$1 == dev { print $2; exit }' /proc/mounts)
    [[ -n "$MOUNT_POINT" ]] || die "Device $DEVICE is not mounted"
elif [[ -d "$DEVICE" ]]; then
    MOUNT_POINT="$DEVICE"
    DEVICE=$(awk -v mp="$MOUNT_POINT" '$2 == mp { print $1; exit }' /proc/mounts)
    [[ -n "$DEVICE" ]] || die "Cannot determine device for mount point $MOUNT_POINT"
else
    die "Device/mount point does not exist: $DEVICE"
fi

# Verify the filesystem is XFS
FS_TYPE=$(awk -v mp="$MOUNT_POINT" '$2 == mp { print $3 }' /proc/mounts)
[[ "$FS_TYPE" == "xfs" ]] || \
    die "Filesystem at $MOUNT_POINT is '$FS_TYPE', not xfs."

# Check that user quotas are enabled
MOUNT_OPTS=$(awk -v mp="$MOUNT_POINT" '$2 == mp { print $4 }' /proc/mounts)
echo "$MOUNT_OPTS" | grep -q "usrquota\|uquota\|quota" || \
    die "User quotas do not appear to be enabled on $MOUNT_POINT. Remount with 'usrquota' option."

# ---- Helper: get current XFS quota for a UID --------------------------------

# Returns "block_soft block_hard inode_soft inode_hard" for the given UID,
# or empty string if no quota is set (all limits are zero).
get_current_xfs_quota() {
    local uid="$1"
    # xfs_quota -x -c "quota -u <uid>" <mountpoint>
    # Output example:
    #   Disk quotas for User 1000 (uid 1000):
    #   Filesystem              blocks      quota      limit  grace  files  quota  limit  grace
    #   /home                     1234    1048576    2097152             56  10000  20000
    local raw
    raw=$(xfs_quota -x -c "quota -u $uid" "$MOUNT_POINT" 2>/dev/null || true)
    # Extract the data line (third line, starts with the mount point)
    local data_line
    data_line=$(echo "$raw" | awk -v mp="$MOUNT_POINT" '$1 == mp { print }')
    if [[ -z "$data_line" ]]; then
        echo ""
        return
    fi
    # Fields: $1=filesystem $2=blocks_used $3=block_soft $4=block_hard ($5=grace optional)
    #         then files_used inode_soft inode_hard
    # Use awk to parse reliably
    echo "$data_line" | awk '{
        b_soft = $3; b_hard = $4
        # grace field is present when quota is exceeded; detect by checking
        # whether field 5 looks like a time token (contains letters)
        if ($5 ~ /[a-zA-Z]/) {
            i_soft = $7; i_hard = $8
        } else {
            i_soft = $6; i_hard = $7
        }
        # Only report non-zero limits
        if (b_soft+0 > 0 || b_hard+0 > 0 || i_soft+0 > 0 || i_hard+0 > 0) {
            printf "%s %s %s %s", b_soft, b_hard, i_soft, i_hard
        }
    }'
}

# ---- Apply a single quota ---------------------------------------------------

apply_quota() {
    local uid="$1"
    local b_soft="$2"
    local b_hard="$3"
    local i_soft="$4"
    local i_hard="$5"

    # xfs_quota limit command uses 1K-block units by default for bsoft/bhard,
    # which matches the KB values stored by dump-ext4-quotas.sh.
    # Inode limits are plain counts.
    local cmd="limit -u bsoft=${b_soft}k bhard=${b_hard}k isoft=${i_soft} ihard=${i_hard} ${uid}"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[dry-run] xfs_quota -x -c \"$cmd\" \"$MOUNT_POINT\""
        return
    fi

    xfs_quota -x -c "$cmd" "$MOUNT_POINT"
}

# ---- Main loop: parse input file and apply quotas ---------------------------

APPLIED=0
SKIPPED=0
ERRORS=0

echo "Applying quotas to $DEVICE ($MOUNT_POINT) ..." >&2
[[ "$DRY_RUN" -eq 1 ]] && echo "(dry-run mode - no changes will be made)" >&2

while IFS=$'\t' read -r uid b_soft b_hard i_soft i_hard; do
    # Skip comment and header lines
    [[ "$uid" =~ ^# ]] && continue
    [[ "$uid" == "UID" ]] && continue
    [[ -z "$uid" ]] && continue

    # Skip non-numeric UIDs (safety guard)
    [[ "$uid" =~ ^[0-9]+$ ]] || continue

    # Apply UID range filter
    (( uid < UID_MIN || uid > UID_MAX )) && continue

    # Check if a quota already exists for this UID
    if [[ "$FORCE" -eq 0 && "$DRY_RUN" -eq 0 ]]; then
        existing=$(get_current_xfs_quota "$uid")
        if [[ -n "$existing" ]]; then
            echo -n "Quota already exists for UID $uid ($existing). Overwrite? [y/N] "
            read -r answer </dev/tty
            if [[ ! "$answer" =~ ^[Yy]$ ]]; then
                echo "  Skipped UID $uid" >&2
                (( SKIPPED++ )) || true
                continue
            fi
        fi
    fi

    if apply_quota "$uid" "$b_soft" "$b_hard" "$i_soft" "$i_hard"; then
        [[ "$DRY_RUN" -eq 0 ]] && echo "  Applied quota for UID $uid: bsoft=${b_soft}k bhard=${b_hard}k isoft=${i_soft} ihard=${i_hard}" >&2
        (( APPLIED++ )) || true
    else
        echo "  ERROR: Failed to apply quota for UID $uid" >&2
        (( ERRORS++ )) || true
    fi
done < "$INPUT"

# ---- Summary ----------------------------------------------------------------

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "" >&2
    echo "Dry-run complete. $APPLIED quota command(s) would be applied." >&2
else
    echo "" >&2
    echo "Done. Applied: $APPLIED, Skipped: $SKIPPED, Errors: $ERRORS" >&2
    [[ "$ERRORS" -eq 0 ]] || exit 1
fi
