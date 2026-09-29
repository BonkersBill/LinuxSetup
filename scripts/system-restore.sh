#!/usr/bin/env bash
#
# system-restore.sh - Build a new, bootable disk from an archive made by
#                     system-backup.sh, with a partition layout of your choice.
#
# The partitioning, alignment, fstab, cmdline.txt, initramfs and GRUB handling
# come from clone-system.sh, which must be in the same directory as this script.
#
# Examples:
#   # Show what would be created, change nothing
#   sudo ./system-restore.sh --plan pi4.tar.zst /dev/sda
#
#   # Pi: 512M boot, 64G root, 4G swap, rest as /home
#   sudo ./system-restore.sh --boot 512M --root 64G --swap 4G --part /home:rest pi4.tar.zst /dev/sda
#
#   # Same filesystems as the original system; a second Pi gets its own identity
#   sudo ./system-restore.sh --like-source --hostname pi4-b --reset-identity pi4.tar.zst /dev/sda
#
set -Eeuo pipefail

HERE=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
if [[ ! -r $HERE/clone-system.sh ]]; then
  echo "ERROR: $HERE/clone-system.sh is required (it provides the partitioning code)" >&2
  exit 1
fi
# shellcheck source=clone-system.sh
source "$HERE/clone-system.sh"

readonly RESTORE_VERSION="1.0"
ARCHIVE=""
COMP=none
LIKE_SOURCE=0
LAYOUT_OPTS=0
M_FORMAT="" M_CREATED="" M_HOSTNAME="" M_OS="" M_ARCH="" M_MODE="" M_PI_BOOT_DIR="" M_USED=0
declare -a M_FS_REL=() M_FS_TYPE=() M_FS_USED=() M_FS_SIZE=()

usage() {
  cat <<EOF
$PROG $RESTORE_VERSION - restore a system-backup.sh archive onto a new disk with a new partition layout

Usage: sudo $PROG [options] ARCHIVE TARGET_DEVICE

Layout options (sizes: 512M, 32G, 1T, or "rest" for all remaining space):
  -b, --boot SIZE          Pi boot / EFI system partition size     (default: $BOOT_SIZE)
  -r, --root SIZE[:FS]     Root partition                          (default: rest:ext4)
  -p, --part MNT:SIZE[:FS] Extra partition, repeatable. e.g. /home:rest  /var:10G:xfs
  -w, --swap SIZE          Swap partition (0 = none)               (default: $SWAP_SIZE)
      --like-source        Recreate the original system's filesystems (sizes from the
                           archive); root takes the rest. Not with --boot/--root/--part.
  -t, --table msdos|gpt    Partition table   (default: msdos for pi, gpt otherwise)
  -f, --first-sector N     Start sector of partition 1 (default: 4 MiB, aligned)
  -a, --align N            Partitions 2.. start on multiples of N sectors (default: $ALIGN_SECTORS),
                           combined with the disk's reported I/O topology
      --no-topology        Ignore the disk's reported topology; align to --align only
      FS is one of: ext4 (default), ext3, ext2, xfs, btrfs, f2fs, vfat

System options:
  -m, --mode pi|efi|bios   Boot mode (default: as recorded in the archive)
  -N, --hostname NAME      Give the new system a new hostname
  -I, --reset-identity     New machine-id and SSH host keys

Other:
      --plan               Show the archive and the layout that would be created, then exit
  -y, --yes                Don't ask for confirmation (DANGEROUS)
  -h, --help               This help

The TARGET device is completely erased.
EOF
}

# ------------------------------------------------------------ arg parsing --
restore_parse_args() {
  while (( $# )); do
    case $1 in
      -b|--boot)           BOOT_SIZE=${2:?}; LAYOUT_OPTS=1; shift ;;
      -r|--root)           ROOT_SPEC=${2:?}; LAYOUT_OPTS=1; shift ;;
      -p|--part)           EXTRA_SPECS+=("${2:?}"); LAYOUT_OPTS=1; shift ;;
      -w|--swap)           SWAP_SIZE=${2:?}; shift ;;
      --like-source)       LIKE_SOURCE=1 ;;
      -t|--table)          TABLE=${2:?}; shift ;;
      -f|--first-sector)   FIRST_SECTOR=${2:?}; FIRST_SECTOR_USER=1; shift ;;
      -a|--align)          ALIGN_SECTORS=${2:?}; shift ;;
      --no-topology)       USE_TOPOLOGY=0 ;;
      -m|--mode)           MODE=${2:?}; shift ;;
      -N|--hostname)       NEW_HOSTNAME=${2:?}; shift ;;
      -I|--reset-identity) RESET_ID=1 ;;
      --plan)              PLAN_ONLY=1 ;;
      -y|--yes)            ASSUME_YES=1 ;;
      -h|--help)           usage; exit 0 ;;
      -*)                  die "Unknown option: $1 (see --help)" ;;
      *)
        if   [[ -z $ARCHIVE ]]; then ARCHIVE=$1
        elif [[ -z $TARGET ]];  then TARGET=$1
        else die "Too many arguments (want ARCHIVE TARGET_DEVICE)"; fi ;;
    esac
    shift
  done
  [[ -n $ARCHIVE && -n $TARGET ]] || { usage; exit 1; }
  (( LIKE_SOURCE && LAYOUT_OPTS )) && die "--like-source can't be combined with --boot/--root/--part"
  [[ -z $TABLE || $TABLE =~ ^(msdos|gpt)$ ]] || die "--table must be msdos or gpt"
  [[ -z $MODE  || $MODE  =~ ^(pi|efi|bios)$ ]] || die "--mode must be pi, efi or bios"
  [[ -z $FIRST_SECTOR || $FIRST_SECTOR =~ ^[0-9]+$ ]] || die "--first-sector must be a sector number"
  [[ $ALIGN_SECTORS =~ ^[1-9][0-9]*$ ]] || die "--align must be a positive number of sectors"
  [[ -z $NEW_HOSTNAME || $NEW_HOSTNAME =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] \
    || die "Invalid hostname '$NEW_HOSTNAME'"
  to_mib "$BOOT_SIZE" >/dev/null
  to_mib "$SWAP_SIZE" >/dev/null
  to_mib "${ROOT_SPEC%%:*}" >/dev/null
  local spec
  for spec in "${EXTRA_SPECS[@]}"; do
    [[ $spec == /*:* ]] || die "Bad --part '$spec' (want MOUNTPOINT:SIZE[:FS])"
    spec=${spec#*:}; to_mib "${spec%%:*}" >/dev/null
  done
  ARCHIVE=$(realpath -e "$ARCHIVE") || die "Archive '$ARCHIVE' not found"
  [[ -f $ARCHIVE && -r $ARCHIVE ]] || die "$ARCHIVE is not a readable file"
}

# Parent disk of the filesystem holding PATH (empty if unknown)
disk_of() {
  local majmin
  majmin=$(findmnt -no MAJ:MIN --target "$1" 2>/dev/null) || return 0
  lsblk -no PKNAME "/dev/block/$majmin" 2>/dev/null | head -n1 || true
}

restore_preflight() {
  (( EUID == 0 )) || die "Must be run as root (sudo)"
  [[ -b $TARGET ]] || die "$TARGET is not a block device"
  TARGET=$(realpath "$TARGET")
  [[ $(lsblk -dno TYPE "$TARGET") =~ ^(disk|loop)$ ]] \
    || die "$TARGET is not a whole disk (give e.g. /dev/sda, not /dev/sda1)"
  local d
  d=$(disk_of /)
  [[ -n $d && /dev/$d == "$TARGET" ]] && die "$TARGET holds the running system - refusing to overwrite it"
  d=$(disk_of "$ARCHIVE")
  [[ -n $d && /dev/$d == "$TARGET" ]] && die "The archive is stored on $TARGET - copy it somewhere else first"

  local cmd missing=()
  for cmd in tar parted wipefs blkid lsblk findmnt partprobe udevadm blockdev mkswap awk od; do
    command -v "$cmd" >/dev/null || missing+=("$cmd")
  done
  (( ${#missing[@]} == 0 )) || die "Missing tools: ${missing[*]}  (apt install parted dosfstools util-linux)"
  (( RESET_ID )) && ! command -v ssh-keygen >/dev/null && die "--reset-identity needs ssh-keygen (openssh-client)"
  return 0
}

# ---------------------------------------------------------------- archive --
detect_compression() {
  local magic
  magic=$(head -c 6 "$ARCHIVE" | od -An -tx1 | tr -d ' \n')
  case $magic in
    28b52ffd*)    COMP=zstd; command -v zstd >/dev/null || die "Archive is zstd-compressed: apt install zstd" ;;
    1f8b*)        COMP=gzip ;;
    fd377a585a00) COMP=xz;   command -v xz   >/dev/null || die "Archive is xz-compressed: apt install xz-utils" ;;
    *)            COMP=none ;;
  esac
}

decompress() {
  case $COMP in
    zstd) zstd -q -dc ;;
    gzip) if command -v pigz >/dev/null; then pigz -dc; else gzip -dc; fi ;;
    xz)   xz -dc ;;
    none) cat ;;
  esac
}

# The metadata is the first member, so only the start of the archive is read
read_meta() {
  local meta line key val rel type used size
  meta=$( { decompress < "$ARCHIVE" | tar -xOf - --occurrence=1 ./.clone-archive/meta; } 2>/dev/null || true)
  [[ $meta == *FORMAT=* ]] || die "$ARCHIVE is not an archive made by system-backup.sh"

  # Parse KEY=VALUE lines - never source them
  while IFS= read -r line; do
    [[ $line =~ ^([A-Z_0-9]+)=(.*)$ ]] || continue
    key=${BASH_REMATCH[1]} val=${BASH_REMATCH[2]}
    case $key in
      FORMAT)      M_FORMAT=$val ;;
      CREATED)     M_CREATED=$val ;;
      HOSTNAME)    M_HOSTNAME=$val ;;
      OS)          M_OS=$val ;;
      ARCH)        M_ARCH=$val ;;
      MODE)        M_MODE=$val ;;
      PI_BOOT_DIR) M_PI_BOOT_DIR=$val ;;
      USED_MIB)    M_USED=$val ;;
      FS_[0-9]*)
        IFS='|' read -r rel type used size <<<"$val"
        [[ $rel == /* && $used =~ ^[0-9]+$ && $size =~ ^[0-9]+$ ]] || die "Corrupt metadata line: $line"
        M_FS_REL+=("$rel"); M_FS_TYPE+=("$type"); M_FS_USED+=("$used"); M_FS_SIZE+=("$size") ;;
    esac
  done <<<"$meta"

  [[ $M_FORMAT == 1 ]] || die "Unsupported archive format '$M_FORMAT' (this script understands format 1)"
  [[ $M_MODE =~ ^(pi|efi|bios)$ ]] || die "Archive metadata has an invalid boot mode '$M_MODE'"
  [[ -z $M_PI_BOOT_DIR || $M_PI_BOOT_DIR =~ ^/boot(/firmware)?$ ]] || die "Archive metadata has an invalid Pi boot dir"
  [[ $M_USED =~ ^[0-9]+$ ]] || die "Archive metadata has an invalid size"
  [[ ${M_FS_REL[0]:-} == / ]] || die "Archive metadata does not list a root filesystem"
}

setup_mode() {
  local host_arch
  [[ -n $MODE ]] || MODE=$M_MODE
  if [[ $MODE == pi ]]; then
    PI_BOOT_DIR=$M_PI_BOOT_DIR
    [[ -n $PI_BOOT_DIR ]] || die "The archive has no Raspberry Pi boot files; it can't be restored in pi mode"
  fi
  if [[ -z $TABLE ]]; then
    if [[ $MODE == pi ]]; then TABLE=msdos; else TABLE=gpt; fi
  fi
  if [[ $MODE == pi && $TABLE == gpt ]]; then
    warn "GPT on a Raspberry Pi needs a Pi 4/400/5 with a recent bootloader EEPROM."
  fi
  host_arch=$(od -An -tu2 -j18 -N2 /usr/bin/env | tr -d ' ')
  case $host_arch in 62) host_arch=amd64 ;; 183) host_arch=arm64 ;; 40) host_arch=armhf ;; 3) host_arch=i386 ;; esac
  if [[ $M_ARCH != "$host_arch" ]]; then
    warn "Archive is $M_ARCH but this machine is $host_arch: initramfs/GRUB can't be updated from here."
    [[ $MODE == pi ]] || die "Restore a $MODE-mode $M_ARCH system from a $M_ARCH machine (GRUB must be installed)."
  fi
  # write_fstab() replaces the fstab entries for these mountpoints
  SRC_REL=("${M_FS_REL[@]}")
  SRC_FSTYPE=("${M_FS_TYPE[@]}")
}

# --like-source: rebuild the original filesystems, root takes the rest
apply_like_source() {
  (( LIKE_SOURCE )) || return 0
  local i rel fs boot_rel=/boot/efi
  [[ $MODE == pi ]] && boot_rel=$PI_BOOT_DIR
  EXTRA_SPECS=()
  for i in "${!M_FS_REL[@]}"; do
    rel=${M_FS_REL[i]}; fs=${M_FS_TYPE[i]}
    case $rel in
      /) valid_fs "$fs" && [[ $fs != vfat ]] || fs=ext4
         ROOT_SPEC="rest:$fs" ;;
      "$boot_rel") BOOT_SIZE="${M_FS_SIZE[i]}M" ;;
      *) valid_fs "$fs" || fs=ext4
         EXTRA_SPECS+=("$rel:${M_FS_SIZE[i]}M:$fs") ;;
    esac
  done
}

show_restore_plan() {
  local i asize
  asize=$(( $(stat -c %s "$ARCHIVE") / 1048576 ))
  echo
  printf '%sArchive%s %s   (%s, %s)\n' "$C_B" "$C_0" "$ARCHIVE" "$(human_mib "$asize")" "$COMP"
  echo "   created $M_CREATED on '$M_HOSTNAME': $M_OS ($M_ARCH, boot mode $M_MODE)"
  for i in "${!M_FS_REL[@]}"; do
    printf '   %-22s %-6s %10s used of %s\n' "${M_FS_REL[i]}" "${M_FS_TYPE[i]}" \
      "$(human_mib "${M_FS_USED[i]}")" "$(human_mib "${M_FS_SIZE[i]}")"
  done
  echo
  print_target_layout
  (( M_USED * 105 / 100 < PLAN_CAP_MIB )) \
    || die "The archive holds $(human_mib "$M_USED") but the new layout only holds $(human_mib "$PLAN_CAP_MIB")"
  echo "Data to restore: ~$(human_mib "$M_USED"), capacity of new layout: $(human_mib "$PLAN_CAP_MIB")"
  echo "(Each partition must hold the data that lands in it - check the sizes above.)"
  if [[ -n $NEW_HOSTNAME ]]; then echo "New hostname: $NEW_HOSTNAME"; fi
  if (( RESET_ID )); then echo "machine-id and SSH host keys will be regenerated"; fi
  echo
}

# ---------------------------------------------------------------- restore --
# Mount everything except FAT partitions: FAT can't hold owners/permissions, so tar
# would fail on it. FAT content is extracted onto root first and moved afterwards.
mount_target_posix() {
  local i
  MNT=$(mktemp -d /mnt/restore.XXXXXX)
  for i in $(mount_order); do
    [[ ${P_FS[i]} == vfat ]] && continue
    mkdir -p "$MNT${P_MNT[i]}"
    mount "${P_DEV[i]}" "$MNT${P_MNT[i]}"
  done
  log "New filesystems mounted under $MNT"
}

extract_archive() {
  local -a opts=(--extract --file=- --directory="$MNT" --preserve-permissions --same-owner
                 --numeric-owner --xattrs --xattrs-include='*' --acls
                 --anchored --exclude=./.clone-archive)
  log "Extracting $ARCHIVE"
  if command -v pv >/dev/null && [[ -t 2 ]]; then
    pv "$ARCHIVE" | decompress | tar "${opts[@]}"
  else
    decompress < "$ARCHIVE" | tar "${opts[@]}"
  fi
  [[ -f $MNT/etc/fstab ]] || die "Extraction finished but $MNT/etc/fstab is missing"
  mkdir -p "$MNT"/{dev,proc,sys,run,tmp,mnt,media}
  chmod 1777 "$MNT/tmp"
}

move_into_fat() {
  local i mp tmpm
  for i in $(mount_order); do
    [[ ${P_FS[i]} == vfat ]] || continue
    mp=${P_MNT[i]}
    mkdir -p "$MNT$mp"
    tmpm=$(mktemp -d /mnt/restore-fat.XXXXXX)
    mount "${P_DEV[i]}" "$tmpm"
    log "Moving $mp onto its FAT partition ${P_DEV[i]}"
    cp -r --preserve=timestamps "$MNT$mp/." "$tmpm/"
    umount "$tmpm"
    rmdir "$tmpm"
    find "$MNT$mp" -mindepth 1 -delete
    mount "${P_DEV[i]}" "$MNT$mp"
  done
}

# ------------------------------------------------------------------- main --
restore_main() {
  restore_parse_args "$@"
  restore_preflight
  detect_compression
  read_meta
  setup_mode
  apply_like_source
  build_layout
  plan_layout
  show_restore_plan
  (( PLAN_ONLY )) && exit 0
  check_mkfs_tools
  confirm

  trap cleanup EXIT
  trap 'die "Command failed at line $LINENO: $BASH_COMMAND"' ERR

  release_target
  partition_disk
  make_filesystems
  mount_target_posix
  extract_archive
  move_into_fat
  write_fstab
  if [[ $MODE == pi ]]; then fix_pi_cmdline; fi
  customise
  chroot_tasks

  log "Syncing..."
  sync
  echo
  printf '%sRestore complete.%s\n' "$C_G$C_B" "$C_0"
  case $MODE in
    pi)   echo "Power off, then boot from $TARGET (for USB/NVMe boot, check BOOT_ORDER with 'sudo rpi-eeprom-config')." ;;
    efi)  echo "Boot $TARGET from the firmware boot menu (installed on the removable path, so it works on any machine)." ;;
    bios) echo "Select $TARGET as the boot disk in the BIOS." ;;
  esac
}

restore_main "$@"
