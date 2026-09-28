# Clone-system.sh

## What it does

1. **Detects the boot mode:**
   - **pi:** Raspberry Pi firmware boot. It finds the boot files in either `/boot/firmware` (Bookworm and later) or `/boot` (older releases).
   - **efi:** UEFI with GRUB.
   - **bios:** legacy BIOS with GRUB.
2. **Builds a new layout from options:**
   - A boot/EFI partition, a root partition and optional swap.
   - Any number of extra partitions via `--part /home:rest`, `--part /var:20G:xfs`, and so on.
   - One partition can take the remaining space (`rest`); it's always placed last on the disk.
   - On an MBR table with more than 4 partitions, the extra ones automatically become logical partitions.
3. **Safety checks before anything is written:**
   - It refuses to write to the disk the system is running from.
   - It checks that the source data fits in the new layout.
   - With `--plan` it only shows the layout and stops.
   - Otherwise you have to type the device name to confirm.
4. **Copies each source filesystem** with `rsync -aAXH`, which keeps permissions, ACLs, extended attributes and hard links. This works whether or not the old and new layouts match: a source `/home` that was on the root partition ends up on a new `/home` partition, and the reverse also works.
5. **Updates the clone's boot configuration:**
   - Writes a new `fstab` (PARTUUID on a Pi, UUID elsewhere). Network shares, tmpfs and other entries from the old one are kept.
   - On a Pi, updates `root=` and `rootfstype=` in `cmdline.txt`.
   - Points the hibernation resume setting at the new swap, and turns off `dphys-swapfile` when a swap partition is created.
   - Rebuilds the initramfs and installs GRUB inside a chroot.
   - On EFI it uses `--no-nvram`, so the current machine's boot entries aren't touched, and `--removable`, so the disk boots on other machines.
6. **Optional:** `-N newname` sets a new hostname and `-I` creates a new machine-id and SSH host keys, for when the clone will run alongside the original.

## Typical use (Pi, SD card to USB SSD)

```bash
sudo ./clone-system.sh --plan --boot 512M --root 40G --swap 2G --part /home:rest /dev/sda
```

```bash
sudo ./clone-system.sh --boot 512M --root 40G --swap 2G --part /home:rest /dev/sda
```

**Limitations:**

- It doesn't recreate LUKS encryption or LVM; the clone uses plain partitions (it warns you).
- It doesn't create btrfs subvolumes.
- A Pi booting from a GPT disk needs a Pi 4 or 5.
- On a Pi, a root filesystem other than ext4 needs an initramfs.
- When cloning a running system, stop databases first so the copy is consistent.

---

```bash
#!/usr/bin/env bash
#
# clone-system.sh - Clone a Debian / Raspberry Pi OS system onto another disk,
#                   creating a brand-new partition layout on the way.
#
# The target disk is repartitioned from scratch (it does NOT need to match the
# source layout), filesystems are created, the system is copied with rsync,
# and fstab / cmdline.txt / GRUB / initramfs are fixed up for the new layout.
#
# Supported boot modes (auto-detected, override with --mode):
#   pi    Raspberry Pi firmware boot  (FAT boot partition + cmdline.txt)
#   efi   UEFI + GRUB                 (ESP at /boot/efi)
#   bios  Legacy BIOS + GRUB          (bios_grub partition on GPT)
#
# Examples:
#   # Pi: SD card -> USB SSD, 1G boot, 40G root, 4G swap, rest as /home
#   sudo ./clone-system.sh --boot 1G --root 40G --swap 4G --part /home:rest /dev/sda
#
#   # PC: clone to NVMe with btrfs root and separate /var
#   sudo ./clone-system.sh --root 60G:btrfs --part /var:20G --part /home:rest /dev/nvme1n1
#
#   # Clone an offline system mounted at /mnt/old (mount its /boot etc. too)
#   sudo ./clone-system.sh --source /mnt/old --mode pi /dev/sdb
#
set -Eeuo pipefail

readonly VERSION="1.0"
readonly PROG=${0##*/}

# ----------------------------------------------------------------- defaults --
SRC="/"
TARGET=""
MODE=""                 # pi | efi | bios            (auto)
TABLE=""                # msdos | gpt                (auto)
BOOT_SIZE="512M"        # Pi boot / EFI system partition
ROOT_SPEC="rest"        # SIZE[:FS]
SWAP_SIZE="0"
START_MIB=4             # first partition offset (Pi images use 4 MiB)
NEW_HOSTNAME=""
RESET_ID=0
ASSUME_YES=0
PLAN_ONLY=0
declare -a EXTRA_SPECS=() EXCLUDES=()

# Layout arrays (one entry per partition, same index everywhere)
declare -a P_ROLE=() P_MNT=() P_SIZE=() P_FS=() P_LABEL=()
declare -a P_NUM=() P_DEV=() P_START=() P_END=()
USE_EXT=0 EXT_START=0 DISK_MIB=0

MNT=""
PI_BOOT_DIR=""
declare -a SRC_MP=() SRC_REL=() SRC_FSTYPE=()

# ------------------------------------------------------------------ helpers --
if [[ -t 1 ]]; then
  C_R=$'\e[31m' C_G=$'\e[32m' C_Y=$'\e[33m' C_B=$'\e[1m' C_0=$'\e[0m'
else
  C_R="" C_G="" C_Y="" C_B="" C_0=""
fi
log()  { printf '%s==>%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%sWARNING:%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%sERROR:%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
$PROG $VERSION - clone a Debian / Raspberry Pi system to a new disk with a new partition layout

Usage: sudo $PROG [options] TARGET_DEVICE

Layout options (sizes: 512M, 32G, 1T, or "rest" for all remaining space):
  -b, --boot SIZE          Pi boot / EFI system partition size     (default: $BOOT_SIZE)
  -r, --root SIZE[:FS]     Root partition                          (default: rest:ext4)
  -p, --part MNT:SIZE[:FS] Extra partition, repeatable. e.g. /home:rest  /var:10G:xfs
  -w, --swap SIZE          Swap partition (0 = none)               (default: $SWAP_SIZE)
  -t, --table msdos|gpt    Partition table   (default: msdos for pi, gpt otherwise)
      FS is one of: ext4 (default), ext3, ext2, xfs, btrfs, f2fs, vfat
      Exactly one partition may be "rest"; it is placed last on the disk.

Source / system options:
  -s, --source DIR         Root of the system to clone (default: /). For an offline
                           system, mount it (and its /boot etc.) under DIR first.
  -m, --mode pi|efi|bios   Boot mode (default: auto-detect)
  -x, --exclude PATH       Don't copy PATH (absolute, as seen by the source system). Repeatable.
  -N, --hostname NAME      Give the clone a new hostname
  -I, --reset-identity     New machine-id and SSH host keys on the clone

Other:
      --plan               Show the layout that would be created, then exit
  -y, --yes                Don't ask for confirmation (DANGEROUS)
  -h, --help               This help

The TARGET device is completely erased.
EOF
}

# Convert a size string to MiB. "rest" -> -1
to_mib() {
  local s=${1^^}
  case $s in REST|100%) echo -1; return ;; esac
  [[ $s =~ ^([0-9]+)([KMGT]?)(I?B)?$ ]] || die "Invalid size '$1' (use e.g. 512M, 32G, rest)"
  local n=${BASH_REMATCH[1]}
  case ${BASH_REMATCH[2]} in
    K)    echo $(( (n + 1023) / 1024 )) ;;
    ""|M) echo "$n" ;;
    G)    echo $(( n * 1024 )) ;;
    T)    echo $(( n * 1024 * 1024 )) ;;
  esac
}

human_mib() {
  local m=$1
  if (( m >= 1048576 )); then awk -v m="$m" 'BEGIN{printf "%.1f TiB", m/1048576}'
  elif (( m >= 1024 )); then awk -v m="$m" 'BEGIN{printf "%.1f GiB", m/1024}'
  else echo "$m MiB"; fi
}

# /dev/sda + 2 -> /dev/sda2 ; /dev/nvme0n1 + 2 -> /dev/nvme0n1p2
part_dev() { if [[ $1 =~ [0-9]$ ]]; then echo "${1}p$2"; else echo "$1$2"; fi; }

valid_fs() { [[ $1 =~ ^(ext[234]|xfs|btrfs|f2fs|vfat)$ ]]; }

# ------------------------------------------------------------ arg parsing --
parse_args() {
  while (( $# )); do
    case $1 in
      -b|--boot)           BOOT_SIZE=${2:?}; shift ;;
      -r|--root)           ROOT_SPEC=${2:?}; shift ;;
      -p|--part)           EXTRA_SPECS+=("${2:?}"); shift ;;
      -w|--swap)           SWAP_SIZE=${2:?}; shift ;;
      -t|--table)          TABLE=${2:?}; shift ;;
      -s|--source)         SRC=${2:?}; shift ;;
      -m|--mode)           MODE=${2:?}; shift ;;
      -x|--exclude)        EXCLUDES+=("${2:?}"); shift ;;
      -N|--hostname)       NEW_HOSTNAME=${2:?}; shift ;;
      -I|--reset-identity) RESET_ID=1 ;;
      --plan)              PLAN_ONLY=1 ;;
      -y|--yes)            ASSUME_YES=1 ;;
      -h|--help)           usage; exit 0 ;;
      -*)                  die "Unknown option: $1 (see --help)" ;;
      *)  [[ -z $TARGET ]] || die "Only one target device allowed"; TARGET=$1 ;;
    esac
    shift
  done
  [[ -n $TARGET ]] || { usage; exit 1; }
  [[ -z $TABLE || $TABLE =~ ^(msdos|gpt)$ ]] || die "--table must be msdos or gpt"
  [[ -z $MODE  || $MODE  =~ ^(pi|efi|bios)$ ]] || die "--mode must be pi, efi or bios"
  [[ -z $NEW_HOSTNAME || $NEW_HOSTNAME =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] \
    || die "Invalid hostname '$NEW_HOSTNAME'"
  # Validate sizes here, in the main shell, so a bad value aborts immediately
  to_mib "$BOOT_SIZE" >/dev/null
  to_mib "$SWAP_SIZE" >/dev/null
  to_mib "${ROOT_SPEC%%:*}" >/dev/null
  local spec ex
  for spec in "${EXTRA_SPECS[@]}"; do
    [[ $spec == /*:* ]] || die "Bad --part '$spec' (want MOUNTPOINT:SIZE[:FS])"
    spec=${spec#*:}; to_mib "${spec%%:*}" >/dev/null
  done
  for ex in "${EXCLUDES[@]}"; do [[ $ex == /* ]] || die "--exclude needs an absolute path: $ex"; done
  SRC=$(realpath -e "$SRC") || die "Source '$SRC' does not exist"
}

# ------------------------------------------------------------ sanity checks --
preflight() {
  (( EUID == 0 )) || die "Must be run as root (sudo)"
  [[ -b $TARGET ]] || die "$TARGET is not a block device"
  TARGET=$(realpath "$TARGET")
  [[ $(lsblk -dno TYPE "$TARGET") =~ ^(disk|loop)$ ]] \
    || die "$TARGET is not a whole disk (give e.g. /dev/sda, not /dev/sda1)"
  [[ -e $SRC/bin/sh && -f $SRC/etc/fstab ]] || die "$SRC does not look like a Linux root filesystem"

  # Never clone onto the disk we are copying from (MAJ:MIN also works for /dev/root)
  local majmin src_dev src_disk=""
  src_dev=$(findmnt -no SOURCE --target "$SRC" | sed 's/\[.*\]//')
  majmin=$(findmnt -no MAJ:MIN --target "$SRC")
  src_disk=$(lsblk -no PKNAME "/dev/block/$majmin" 2>/dev/null | head -n1 || true)
  [[ -n $src_disk ]] || src_disk=$(lsblk -no PKNAME "$src_dev" 2>/dev/null | head -n1 || true)
  if [[ /dev/$src_disk == "$TARGET" || $src_dev == "$TARGET" ]]; then
    die "$TARGET holds the source system ($src_dev) - refusing to overwrite it"
  fi

  local cmd missing=()
  for cmd in parted rsync wipefs blkid lsblk findmnt partprobe udevadm blockdev mkswap awk; do
    command -v "$cmd" >/dev/null || missing+=("$cmd")
  done
  (( ${#missing[@]} == 0 )) || die "Missing tools: ${missing[*]}  (apt install parted rsync dosfstools util-linux)"
  (( RESET_ID )) && ! command -v ssh-keygen >/dev/null && die "--reset-identity needs ssh-keygen (openssh-client)"

  if [[ -s $SRC/etc/crypttab ]] && grep -qv '^\s*\(#\|$\)' "$SRC/etc/crypttab"; then
    warn "Source uses /etc/crypttab (LUKS). Encryption is NOT recreated; the clone may not boot."
  fi
  if [[ $src_dev == /dev/mapper/* ]]; then
    warn "Source root is on device-mapper (LVM/LUKS). The clone will use plain partitions."
  fi
}

detect_mode() {
  if [[ -z $MODE ]]; then
    if [[ -f $SRC/boot/firmware/config.txt || -f $SRC/boot/config.txt ]] \
       && [[ -f $SRC/boot/firmware/cmdline.txt || -f $SRC/boot/cmdline.txt ]]; then
      MODE=pi
    elif [[ -d $SRC/boot/efi/EFI ]] || { [[ $SRC == / ]] && [[ -d /sys/firmware/efi ]]; }; then
      MODE=efi
    else
      MODE=bios
    fi
  fi
  if [[ $MODE == pi ]]; then
    # Bookworm and later mount the FAT partition at /boot/firmware
    if [[ -f $SRC/boot/firmware/cmdline.txt ]]; then PI_BOOT_DIR=/boot/firmware
    elif [[ -f $SRC/boot/cmdline.txt ]];        then PI_BOOT_DIR=/boot
    else die "Pi mode, but no cmdline.txt found in $SRC/boot or $SRC/boot/firmware"; fi
  fi
  if [[ -z $TABLE ]]; then
    if [[ $MODE == pi ]]; then TABLE=msdos; else TABLE=gpt; fi
  fi
  if [[ $MODE == pi && $TABLE == gpt ]]; then
    warn "GPT on a Raspberry Pi needs a Pi 4/400/5 with a recent bootloader EEPROM."
  fi
  if [[ $MODE == efi && $TABLE == msdos ]]; then
    warn "UEFI with an msdos table works on most firmware, but GPT is recommended."
  fi
}

# ------------------------------------------------------------ layout build --
add_part() { P_ROLE+=("$1"); P_MNT+=("$2"); P_SIZE+=("$3"); P_FS+=("$4"); P_LABEL+=("$5"); }

build_layout() {
  local -a r_role=() r_mnt=() r_size=() r_fs=() r_label=()
  local spec mp size mib fs label i rest_idx=-1

  # Fixed partitions at the start of the disk
  mib=$(to_mib "$BOOT_SIZE")
  case $MODE in
    pi)   add_part boot "$PI_BOOT_DIR" "$mib" vfat bootfs ;;
    efi)  add_part boot /boot/efi      "$mib" vfat EFI ;;
    bios) if [[ $TABLE == gpt ]]; then add_part biosgrub - 1 none ""; fi ;;
  esac

  # Root
  IFS=: read -r size fs <<<"$ROOT_SPEC"
  fs=${fs:-ext4}
  { valid_fs "$fs" && [[ $fs != vfat ]]; } || die "Unsupported root filesystem '$fs'"
  mib=$(to_mib "$size")
  r_role+=(root); r_mnt+=(/); r_size+=("$mib"); r_fs+=("$fs"); r_label+=(rootfs)

  # Extra data partitions
  local -A seen=(["/"]=1)
  [[ ${#P_MNT[@]} -gt 0 ]] && seen[${P_MNT[0]}]=1
  for spec in "${EXTRA_SPECS[@]}"; do
    IFS=: read -r mp size fs <<<"$spec"
    mp=${mp%/}
    [[ -z ${seen[$mp]:-} ]] || die "Mountpoint $mp specified twice (or clashes with boot/root)"
    seen[$mp]=1
    fs=${fs:-ext4}
    valid_fs "$fs" || die "Unsupported filesystem '$fs' for $mp"
    mib=$(to_mib "$size")
    label=${mp##*/}
    r_role+=(data); r_mnt+=("$mp"); r_size+=("$mib"); r_fs+=("$fs"); r_label+=("${label:0:16}")
  done

  # Swap
  mib=$(to_mib "$SWAP_SIZE")
  if (( mib != 0 )); then
    r_role+=(swap); r_mnt+=(swap); r_size+=("$mib"); r_fs+=(swap); r_label+=(swap)
  fi

  # The single "rest" partition goes last so it can grow to the end of the disk
  for i in "${!r_size[@]}"; do
    if (( r_size[i] < 0 )); then
      (( rest_idx < 0 )) || die "Only one partition may use 'rest'"
      rest_idx=$i
    elif (( r_size[i] == 0 )); then
      die "Partition ${r_mnt[i]} has size 0"
    fi
  done
  for i in "${!r_size[@]}"; do
    if (( i != rest_idx )); then
      add_part "${r_role[i]}" "${r_mnt[i]}" "${r_size[i]}" "${r_fs[i]}" "${r_label[i]}"
    fi
  done
  if (( rest_idx >= 0 )); then
    add_part "${r_role[rest_idx]}" "${r_mnt[rest_idx]}" -1 "${r_fs[rest_idx]}" "${r_label[rest_idx]}"
  fi
}

# Compute partition numbers, device names and MiB boundaries
plan_layout() {
  local end_limit start end size num=0 n=${#P_ROLE[@]} i
  DISK_MIB=$(( $(blockdev --getsize64 "$TARGET") / 1048576 ))
  end_limit=$(( DISK_MIB - 1 ))       # keep last MiB free (GPT backup header)

  if [[ $TABLE == msdos ]] && (( n > 4 )); then USE_EXT=1; fi
  start=$START_MIB
  for (( i = 0; i < n; i++ )); do
    if (( USE_EXT && i == 3 )); then   # partitions 4.. become logicals (5, 6, ...)
      EXT_START=$start; num=4; start=$(( start + 1 ))
    fi
    size=${P_SIZE[i]}
    if (( size < 0 )); then end=$end_limit; else end=$(( start + size )); fi
    (( end <= end_limit )) \
      || die "Layout does not fit: '${P_MNT[i]}' would end at $(human_mib "$end"), disk is $(human_mib "$DISK_MIB")"
    [[ ${P_ROLE[i]} == biosgrub ]] || (( end - start >= 16 )) \
      || die "Not enough space left for '${P_MNT[i]}'"
    num=$(( num + 1 ))
    P_START[i]=$start; P_END[i]=$end; P_NUM[i]=$num; P_DEV[i]=$(part_dev "$TARGET" "$num")
    if (( USE_EXT && i >= 3 )); then start=$(( end + 1 )); else start=$end; fi   # 1 MiB gap for EBRs
  done
}

# Collect the source filesystems that will be copied (real, local filesystems only)
collect_sources() {
  local mp fstype src_norm=${SRC%/} rel
  local -a target_mps
  mapfile -t target_mps < <(lsblk -nro MOUNTPOINT "$TARGET" | grep -v '^$' || true)
  while read -r mp fstype; do
    [[ $fstype =~ ^(ext[234]|xfs|btrfs|f2fs|vfat|exfat|jfs|reiserfs)$ ]] || continue
    mp=$(printf '%b' "$mp")                                 # decode \040 etc.
    rel=${mp#"$src_norm"}; rel=${rel:-/}
    [[ $rel == /mnt/* || $rel == /media/* ]] && continue    # removable / ad-hoc mounts
    if printf '%s\n' "${target_mps[@]}" | grep -qxF -- "$mp"; then
      die "Source filesystem $mp lives on the target disk $TARGET"
    fi
    SRC_MP+=("$mp"); SRC_REL+=("$rel"); SRC_FSTYPE+=("$fstype")
  done < <(findmnt -R -n -l -o TARGET,FSTYPE "$SRC")
  [[ ${SRC_REL[0]:-} == / ]] || die "Could not identify the source root filesystem at $SRC"
}

show_plan() {
  local i size used=0 cap=0 u what
  echo
  printf '%sSource%s  %s   (mode: %s)\n' "$C_B" "$C_0" "$SRC" "$MODE"
  for i in "${!SRC_MP[@]}"; do
    u=$(df -B1M --output=used "${SRC_MP[i]}" | tail -n1 | tr -d ' ')
    used=$(( used + u ))
    printf '   %-22s %-6s %10s used\n' "${SRC_REL[i]}" "${SRC_FSTYPE[i]}" "$(human_mib "$u")"
  done
  echo
  printf '%sTarget%s  %s  %s  %s   (table: %s)\n' "$C_B" "$C_0" "$TARGET" \
    "$(lsblk -dno MODEL "$TARGET" 2>/dev/null | xargs)" "$(human_mib "$DISK_MIB")" "$TABLE"
  printf '   %-3s %-18s %10s  %-6s %s\n' "#" "Device" "Size" "FS" "Mount"
  for i in "${!P_ROLE[@]}"; do
    size=$(( P_END[i] - P_START[i] ))
    [[ ${P_ROLE[i]} =~ ^(root|data|boot)$ ]] && cap=$(( cap + size ))
    what=${P_MNT[i]}; [[ ${P_ROLE[i]} == biosgrub ]] && what="(BIOS boot)"
    printf '   %-3s %-18s %10s  %-6s %s\n' "${P_NUM[i]}" "${P_DEV[i]}" "$(human_mib "$size")" "${P_FS[i]}" "$what"
  done
  if (( USE_EXT )); then echo "   (partitions 5+ are logical partitions inside an extended partition)"; fi
  echo
  (( used * 105 / 100 < cap )) \
    || die "Source uses $(human_mib "$used") but the new layout only holds $(human_mib "$cap")"
  echo "Data to copy: ~$(human_mib "$used"), capacity of new layout: $(human_mib "$cap")"
  echo "(Each partition must hold the data that lands in it - check the sizes above.)"
  if (( ${#EXCLUDES[@]} )); then echo "Excluded: ${EXCLUDES[*]}"; fi
  if [[ -n $NEW_HOSTNAME ]]; then echo "New hostname: $NEW_HOSTNAME"; fi
  if (( RESET_ID )); then echo "machine-id and SSH host keys will be regenerated"; fi
  echo
}

confirm() {
  (( ASSUME_YES )) && return 0
  lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$TARGET"
  echo
  printf '%sALL DATA ON %s WILL BE DESTROYED.%s\n' "$C_R$C_B" "$TARGET" "$C_0"
  local ans
  read -r -p "Type the device name ($TARGET) to continue: " ans
  [[ $ans == "$TARGET" ]] || die "Aborted"
}

# --------------------------------------------------------- disk operations --
cleanup() {
  local rc=$?
  if [[ -n $MNT && -d $MNT ]]; then
    sync
    umount -R "$MNT" 2>/dev/null || { sleep 2; umount -R -l "$MNT" 2>/dev/null || true; }
    rmdir "$MNT" 2>/dev/null || true
  fi
  (( rc == 0 )) || printf '%sFailed (exit %d). The target disk is incomplete.%s\n' "$C_R" "$rc" "$C_0" >&2
}

release_target() {
  local dev mp
  while read -r dev mp; do
    [[ -n $mp ]] || continue
    if [[ $mp == "[SWAP]" ]]; then swapoff "/dev/$dev"; else umount "$(printf '%b' "$mp")"; fi
    log "Released /dev/$dev ($mp)"
  done < <(lsblk -nro NAME,MOUNTPOINT "$TARGET")
}

partition_disk() {
  local i ptype fstype name t
  log "Wiping $TARGET"
  wipefs -a -q "$TARGET"
  dd if=/dev/zero of="$TARGET" bs=1M count=$START_MIB conv=fsync status=none
  parted -s "$TARGET" mklabel "$TABLE"

  for i in "${!P_ROLE[@]}"; do
    if (( USE_EXT && i == 3 )); then
      parted -s -a optimal "$TARGET" mkpart extended "${EXT_START}MiB" "$(( DISK_MIB - 1 ))MiB"
    fi
    case ${P_FS[i]} in vfat) fstype=fat32 ;; swap) fstype=linux-swap ;; *) fstype=ext4 ;; esac
    if [[ $TABLE == gpt ]]; then
      name=${P_LABEL[i]:-${P_ROLE[i]}}
      parted -s -a optimal "$TARGET" mkpart "$name" "$fstype" "${P_START[i]}MiB" "${P_END[i]}MiB"
    else
      if (( USE_EXT && i >= 3 )); then ptype=logical; else ptype=primary; fi
      parted -s -a optimal "$TARGET" mkpart "$ptype" "$fstype" "${P_START[i]}MiB" "${P_END[i]}MiB"
    fi
    case $MODE:${P_ROLE[i]}:$TABLE in
      pi:boot:msdos)      parted -s "$TARGET" set "${P_NUM[i]}" lba on ;;
      efi:boot:*)         parted -s "$TARGET" set "${P_NUM[i]}" esp on ;;
      bios:biosgrub:gpt)  parted -s "$TARGET" set "${P_NUM[i]}" bios_grub on ;;
      bios:root:msdos)    parted -s "$TARGET" set "${P_NUM[i]}" boot on ;;
    esac
  done

  partprobe "$TARGET" || true
  udevadm settle
  for i in "${!P_DEV[@]}"; do
    t=0
    until [[ -b ${P_DEV[i]} ]]; do
      (( t++ < 20 )) || die "${P_DEV[i]} did not appear"
      sleep 0.5
    done
  done
  parted -s "$TARGET" unit MiB print
}

check_mkfs_tools() {
  local fs tool
  for fs in "${P_FS[@]}"; do
    case $fs in none|swap) continue ;; vfat) tool=mkfs.vfat ;; *) tool=mkfs.$fs ;; esac
    command -v "$tool" >/dev/null || die "$tool not found (install dosfstools / xfsprogs / btrfs-progs / f2fs-tools)"
  done
}

make_filesystems() {
  local i dev l
  for i in "${!P_ROLE[@]}"; do
    dev=${P_DEV[i]}; l=${P_LABEL[i]}
    log "Creating ${P_FS[i]} on $dev ${P_MNT[i]}"
    case ${P_FS[i]} in
      ext2|ext3|ext4) "mkfs.${P_FS[i]}" -F -q -L "$l" "$dev" ;;
      xfs)   mkfs.xfs   -f -q -L "${l:0:12}" "$dev" ;;
      btrfs) mkfs.btrfs -f -q -L "$l" "$dev" ;;
      f2fs)  mkfs.f2fs  -f -q -l "$l" "$dev" ;;
      vfat)  l=${l^^}; mkfs.vfat -F 32 -n "${l:0:11}" "$dev" >/dev/null ;;
      swap)  mkswap -L "$l" "$dev" >/dev/null ;;
      none)  wipefs -a -q "$dev" ;;
    esac
  done
  udevadm settle
}

# Index list of mountable partitions, shallowest mountpoint first ("/" first)
mount_order() {
  local i d
  for i in "${!P_MNT[@]}"; do
    [[ ${P_MNT[i]} == /* ]] || continue
    if [[ ${P_MNT[i]} == / ]]; then d=0; else d=$(tr -cd / <<<"${P_MNT[i]}" | wc -c); fi
    printf '%s %s\n' "$d" "$i"
  done | sort -n -s -k1,1 | cut -d' ' -f2
}

mount_target() {
  local i
  MNT=$(mktemp -d /mnt/clone.XXXXXX)
  for i in $(mount_order); do
    mkdir -p "$MNT${P_MNT[i]}"
    mount "${P_DEV[i]}" "$MNT${P_MNT[i]}"
  done
  log "New filesystems mounted under $MNT"
}

copy_system() {
  local i mp rel dst ex base
  local -a opts
  for i in "${!SRC_MP[@]}"; do
    mp=${SRC_MP[i]%/}/; rel=${SRC_REL[i]}; base=${rel%/}
    dst="$MNT$base/"
    mkdir -p "$dst"
    opts=(--exclude=/lost+found)
    if [[ $rel == / ]]; then
      opts+=(--exclude='/dev/*' --exclude='/proc/*' --exclude='/sys/*' --exclude='/run/*'
             --exclude='/tmp/*' --exclude='/mnt/*' --exclude='/media/*'
             --exclude=/var/swap --exclude='/var/cache/apt/archives/*.deb')
    fi
    for ex in "${EXCLUDES[@]}"; do
      if [[ $ex == "$base"/* ]]; then opts+=("--exclude=/${ex#"$base"/}"); fi
    done
    log "Copying $rel  ->  ${dst%/}"
    # -x: one filesystem per pass; nested source mounts get their own pass.
    if [[ ${SRC_FSTYPE[i]} =~ ^(vfat|exfat)$ ]]; then
      rsync -rtx --modify-window=2 --info=progress2 "${opts[@]}" "$mp" "$dst"
    else
      rsync -aAXHx --numeric-ids --info=progress2 "${opts[@]}" "$mp" "$dst"
    fi
  done
  # Make sure the pseudo-filesystem mountpoints exist with sane permissions
  mkdir -p "$MNT"/{dev,proc,sys,run,tmp,mnt,media}
  chmod 1777 "$MNT/tmp"
}

# "PARTUUID=..." on a Pi (Raspberry Pi OS convention), "UUID=..." elsewhere
part_id() {
  local tag=UUID
  [[ $MODE == pi ]] && tag=PARTUUID
  echo "$tag=$(blkid -c /dev/null -s "$tag" -o value "$1")"
}

write_fstab() {
  local fstab="$MNT/etc/fstab" tmp i opts pass spec mp type rest line header=0
  local -A managed=()
  cp -a "$fstab" "$fstab.pre-clone"
  for i in "${!P_MNT[@]}"; do managed[${P_MNT[i]}]=1; done
  for i in "${!SRC_REL[@]}"; do managed[${SRC_REL[i]}]=1; done

  tmp=$(mktemp)
  {
    echo "# /etc/fstab - generated by $PROG on $(date '+%F %T')"
    echo "# Original saved as /etc/fstab.pre-clone"
    echo "# <device>                                <mount>         <type>  <options>          <dump> <pass>"
    for i in $(mount_order); do
      case ${P_FS[i]} in
        vfat) if [[ $MODE == efi ]]; then opts="umask=0077"; else opts="defaults"; fi; pass=2 ;;
        ext*) opts="defaults,noatime"; if [[ ${P_MNT[i]} == / ]]; then pass=1; else pass=2; fi ;;
        *)    opts="defaults,noatime"; pass=0 ;;
      esac
      printf '%-42s %-15s %-7s %-18s 0 %s\n' "$(part_id "${P_DEV[i]}")" "${P_MNT[i]}" "${P_FS[i]}" "$opts" "$pass"
    done
    for i in "${!P_ROLE[@]}"; do
      if [[ ${P_ROLE[i]} == swap ]]; then
        printf '%-42s %-15s %-7s %-18s 0 0\n' "$(part_id "${P_DEV[i]}")" none swap sw
      fi
    done

    # Keep everything else (network shares, tmpfs, bind mounts, swap files...)
    while IFS= read -r line; do
      [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
      read -r spec mp type rest <<<"$line"
      mp=$(printf '%b' "$mp")
      [[ -n ${managed[$mp]:-} ]] && continue                                        # replaced
      [[ $type == swap && $spec =~ ^(UUID=|PARTUUID=|LABEL=|/dev/) ]] && continue   # old swap partition
      if (( header++ == 0 )); then echo "# --- carried over from the source fstab ---"; fi
      echo "$line"
    done < "$fstab.pre-clone"
  } > "$tmp"
  cat "$tmp" > "$fstab"; rm -f "$tmp"
  log "Wrote new /etc/fstab"
  sed 's/^/     /' "$fstab"
}

fix_pi_cmdline() {
  local cmdline="$MNT$PI_BOOT_DIR/cmdline.txt" root_dev="" root_fs="" line i id
  for i in "${!P_ROLE[@]}"; do
    if [[ ${P_ROLE[i]} == root ]]; then root_dev=${P_DEV[i]}; root_fs=${P_FS[i]}; fi
  done
  id=$(part_id "$root_dev")
  cp -a "$cmdline" "$cmdline.pre-clone"
  line=$(tr '\n' ' ' < "$cmdline" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')
  line=$(sed -E 's# ?init=/usr/lib/raspi-config/init_resize\.sh##' <<<"$line")  # we sized it ourselves
  if [[ $line =~ (^|\ )root= ]]; then
    line=$(sed -E "s#(^| )root=[^ ]+#\1root=$id#" <<<"$line")
  else
    line="root=$id $line"
  fi
  if [[ $line =~ (^|\ )rootfstype= ]]; then
    line=$(sed -E "s#(^| )rootfstype=[^ ]+#\1rootfstype=$root_fs#" <<<"$line")
  else
    line="$line rootfstype=$root_fs"
  fi
  printf '%s\n' "$line" > "$cmdline"
  log "Updated $PI_BOOT_DIR/cmdline.txt"
  echo "     $line"
  if [[ $root_fs != ext4 ]]; then
    warn "Pi kernels need an initramfs to mount a $root_fs root. Make sure 'auto_initramfs=1' (or an 'initramfs' line) is in config.txt."
  fi
}

customise() {
  local old i swap_dev="" resume="$MNT/etc/initramfs-tools/conf.d/resume"
  if [[ -n $NEW_HOSTNAME ]]; then
    old=$(tr -d '[:space:]' < "$MNT/etc/hostname" 2>/dev/null || true)
    echo "$NEW_HOSTNAME" > "$MNT/etc/hostname"
    if [[ -n $old ]]; then
      sed -i -E "s/(^|[[:space:]])${old}([[:space:]]|$)/\1${NEW_HOSTNAME}\2/g" "$MNT/etc/hosts"
    fi
    log "Hostname: ${old:-?} -> $NEW_HOSTNAME"
  fi

  if (( RESET_ID )); then
    : > "$MNT/etc/machine-id"          # systemd generates a new one on first boot
    if [[ -e $MNT/var/lib/dbus/machine-id && ! -L $MNT/var/lib/dbus/machine-id ]]; then
      rm -f "$MNT/var/lib/dbus/machine-id"
      ln -s /etc/machine-id "$MNT/var/lib/dbus/machine-id"
    fi
    if [[ -d $MNT/etc/ssh ]]; then
      rm -f "$MNT"/etc/ssh/ssh_host_*
      ssh-keygen -A -f "$MNT" >/dev/null
    fi
    log "Reset machine-id and generated new SSH host keys"
  fi

  for i in "${!P_ROLE[@]}"; do
    if [[ ${P_ROLE[i]} == swap ]]; then swap_dev=${P_DEV[i]}; fi
  done
  if [[ -n $swap_dev ]]; then
    # A swap partition replaces the Pi's swap file
    rm -f "$MNT"/etc/systemd/system/*.wants/dphys-swapfile.service
  fi
  if [[ -f $resume ]]; then
    if [[ -n $swap_dev ]]; then
      echo "RESUME=UUID=$(blkid -c /dev/null -s UUID -o value "$swap_dev")" > "$resume"
    else
      echo "RESUME=none" > "$resume"
    fi
  fi
}

in_chroot() { chroot "$MNT" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root LC_ALL=C "$@"; }

chroot_tasks() {
  if ! chroot "$MNT" /bin/true 2>/dev/null; then
    warn "Cannot execute the cloned system's binaries on this machine (different architecture?)."
    warn "Skipping initramfs/bootloader update."
    [[ $MODE == pi ]] || die "GRUB could not be installed - run this script on a machine of the same architecture."
    return 0
  fi
  mount --bind /dev     "$MNT/dev"
  mount --bind /dev/pts "$MNT/dev/pts"
  mount -t proc  proc   "$MNT/proc"
  mount -t sysfs sysfs  "$MNT/sys"
  mount -t tmpfs tmpfs  "$MNT/run"

  if [[ -x $MNT/usr/sbin/update-initramfs ]] && compgen -G "$MNT/boot/initrd.img-*" >/dev/null; then
    log "Updating initramfs"
    in_chroot update-initramfs -u -k all || warn "update-initramfs failed"
  fi

  case $MODE in
    efi)
      local arch target
      arch=$(in_chroot dpkg --print-architecture)
      case $arch in
        amd64) target=x86_64-efi ;; arm64) target=arm64-efi ;; i386) target=i386-efi ;;
        *) die "Don't know the GRUB EFI target for $arch" ;;
      esac
      log "Installing GRUB ($target) to the new ESP"
      # --no-nvram:  don't touch this machine's firmware boot entries
      # --removable: also install to EFI/BOOT/ so the disk boots on any machine
      in_chroot grub-install --target="$target" --efi-directory=/boot/efi --bootloader-id=debian --no-nvram --recheck
      in_chroot grub-install --target="$target" --efi-directory=/boot/efi --removable --no-nvram --recheck
      in_chroot GRUB_DISABLE_OS_PROBER=true update-grub
      ;;
    bios)
      log "Installing GRUB (i386-pc) to $TARGET"
      in_chroot grub-install --target=i386-pc --recheck "$TARGET"
      in_chroot GRUB_DISABLE_OS_PROBER=true update-grub
      ;;
  esac
}

# ---------------------------------------------------------------------- main --
main() {
  parse_args "$@"
  preflight
  detect_mode
  build_layout
  plan_layout
  collect_sources
  show_plan
  (( PLAN_ONLY )) && exit 0
  check_mkfs_tools
  if [[ $SRC == / ]]; then
    warn "Cloning a running system: stop databases and other busy services first for a consistent copy."
  fi
  confirm

  trap cleanup EXIT
  trap 'die "Command failed at line $LINENO: $BASH_COMMAND"' ERR

  release_target
  partition_disk
  make_filesystems
  mount_target
  copy_system
  write_fstab
  if [[ $MODE == pi ]]; then fix_pi_cmdline; fi
  customise
  chroot_tasks

  log "Syncing..."
  sync
  echo
  printf '%sClone complete.%s\n' "$C_G$C_B" "$C_0"
  case $MODE in
    pi)   echo "Power off, then boot from $TARGET (for USB/NVMe boot, check BOOT_ORDER with 'sudo rpi-eeprom-config')." ;;
    efi)  echo "Boot $TARGET from the firmware boot menu (installed on the removable path, so it works on any machine)." ;;
    bios) echo "Select $TARGET as the boot disk in the BIOS." ;;
  esac
  echo "Originals are kept on the clone as /etc/fstab.pre-clone$( [[ $MODE == pi ]] && echo " and $PI_BOOT_DIR/cmdline.txt.pre-clone")."
}

main "$@"
```

## What it does

1. **Detects the boot mode:**
   - **pi:** Raspberry Pi firmware boot. It finds the boot files in either `/boot/firmware` (Bookworm and later) or `/boot` (older releases).
   - **efi:** UEFI with GRUB.
   - **bios:** legacy BIOS with GRUB.
2. **Builds a new layout from options:**
   - A boot/EFI partition, a root partition and optional swap.
   - Any number of extra partitions via `--part /home:rest`, `--part /var:20G:xfs`, and so on.
   - One partition can take the remaining space (`rest`); it's always placed last on the disk.
   - On an MBR table with more than 4 partitions, the extra ones automatically become logical partitions.
3. **Safety checks before anything is written:**
   - It refuses to write to the disk the system is running from.
   - It checks that the source data fits in the new layout.
   - With `--plan` it only shows the layout and stops.
   - Otherwise you have to type the device name to confirm.
4. **Copies each source filesystem** with `rsync -aAXH`, which keeps permissions, ACLs, extended attributes and hard links. This works whether or not the old and new layouts match: a source `/home` that was on the root partition ends up on a new `/home` partition, and the reverse also works.
5. **Updates the clone's boot configuration:**
   - Writes a new `fstab` (PARTUUID on a Pi, UUID elsewhere). Network shares, tmpfs and other entries from the old one are kept.
   - On a Pi, updates `root=` and `rootfstype=` in `cmdline.txt`.
   - Points the hibernation resume setting at the new swap, and turns off `dphys-swapfile` when a swap partition is created.
   - Rebuilds the initramfs and installs GRUB inside a chroot.
   - On EFI it uses `--no-nvram`, so the current machine's boot entries aren't touched, and `--removable`, so the disk boots on other machines.
6. **Optional:** `-N newname` sets a new hostname and `-I` creates a new machine-id and SSH host keys, for when the clone will run alongside the original.

## Typical use (Pi, SD card to USB SSD)

```bash
sudo ./clone-system.sh --plan --boot 512M --root 40G --swap 2G --part /home:rest /dev/sda
```
```bash
sudo ./clone-system.sh --boot 512M --root 40G --swap 2G --part /home:rest /dev/sda
```

**Limitations:**
- It doesn't recreate LUKS encryption or LVM; the clone uses plain partitions (it warns you).
- It doesn't create btrfs subvolumes.
- A Pi booting from a GPT disk needs a Pi 4 or 5.
- On a Pi, a root filesystem other than ext4 needs an initramfs.
- When cloning a running system, stop databases first so the copy is consistent.