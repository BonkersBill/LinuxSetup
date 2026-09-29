#!/usr/bin/env bash
#
# system-backup.sh - Archive a Debian / Raspberry Pi OS system into ONE file.
#
# The archive is a compressed tar of every local filesystem of the system,
# preserving owners, permissions, ACLs, extended attributes (file capabilities),
# hard links and sparse files. A small metadata header at the start of the
# archive records the boot mode, architecture and original filesystem layout.
#
# Put it onto a new disk - with any partition layout - using system-restore.sh.
#
# Examples:
#   sudo ./system-backup.sh /media/pi/usb/pi4-$(date +%F).tar.zst
#   sudo ./system-backup.sh --exclude /home/pi/Downloads --verify /mnt/nas/pc.tar.zst
#   sudo ./system-backup.sh --source /mnt/old --compress xz old-system.tar.xz
#
set -Eeuo pipefail

readonly VERSION="1.0"
readonly PROG=${0##*/}

SRC="/"
OUTPUT=""
MODE=""                 # pi | efi | bios            (auto)
COMP=""                 # zstd | gzip | xz | none    (default: zstd if installed, else gzip)
LEVEL=""
VERIFY=0
FORCE=0
PI_BOOT_DIR=""
USED_MIB=0
TMPD=""
declare -a EXCLUDES=() TAR_EXCL=()
declare -a SRC_MP=() SRC_REL=() SRC_FSTYPE=() SRC_USED=() SRC_SIZE=()

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
$PROG $VERSION - archive a Debian / Raspberry Pi system into a single file

Usage: sudo $PROG [options] OUTPUT_FILE

  -s, --source DIR         Root of the system to archive (default: /). For an offline
                           system, mount it (and its /boot etc.) under DIR first.
  -x, --exclude PATH       Don't archive PATH (absolute, as seen by the source system). Repeatable.
  -c, --compress TYPE      zstd (default if installed), gzip, xz or none
  -l, --level N            Compression level (default: zstd 3, gzip 6, xz 6)
  -m, --mode pi|efi|bios   Record this boot mode instead of auto-detecting it
      --verify             Read the finished archive back and check it
  -f, --force              Overwrite OUTPUT_FILE if it exists
  -h, --help               This help

Restore with:  sudo ./system-restore.sh [layout options] OUTPUT_FILE /dev/sdX
EOF
}

human_mib() {
  local m=$1
  if (( m >= 1048576 )); then awk -v m="$m" 'BEGIN{printf "%.1f TiB", m/1048576}'
  elif (( m >= 1024 )); then awk -v m="$m" 'BEGIN{printf "%.1f GiB", m/1024}'
  else echo "$m MiB"; fi
}

# Architecture of an ELF binary, read from its header (works for offline systems too)
elf_arch() {
  local m
  m=$(od -An -tu2 -j18 -N2 "$1" 2>/dev/null | tr -d ' ')
  case $m in
    62) echo amd64 ;; 183) echo arm64 ;; 40) echo armhf ;; 3) echo i386 ;; 243) echo riscv64 ;;
    *) echo unknown ;;
  esac
}

compress() {
  case $COMP in
    zstd) if (( ${LEVEL:-3} > 19 )); then zstd -q -T0 --ultra "-$LEVEL" -c; else zstd -q -T0 "-${LEVEL:-3}" -c; fi ;;
    gzip) if command -v pigz >/dev/null; then pigz "-${LEVEL:-6}" -c; else gzip "-${LEVEL:-6}" -c; fi ;;
    xz)   xz -T0 "-${LEVEL:-6}" -c ;;
    none) cat ;;
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

# Show progress when pv is installed and we're on a terminal
progress() {
  if command -v pv >/dev/null && [[ -t 2 ]]; then pv -s "$1"; else cat; fi
}

# ------------------------------------------------------------ arg parsing --
parse_args() {
  while (( $# )); do
    case $1 in
      -s|--source)   SRC=${2:?}; shift ;;
      -x|--exclude)  EXCLUDES+=("${2:?}"); shift ;;
      -c|--compress) COMP=${2:?}; shift ;;
      -l|--level)    LEVEL=${2:?}; shift ;;
      -m|--mode)     MODE=${2:?}; shift ;;
      --verify)      VERIFY=1 ;;
      -f|--force)    FORCE=1 ;;
      -h|--help)     usage; exit 0 ;;
      -*)            die "Unknown option: $1 (see --help)" ;;
      *)  [[ -z $OUTPUT ]] || die "Only one output file allowed"; OUTPUT=$1 ;;
    esac
    shift
  done
  [[ -n $OUTPUT ]] || { usage; exit 1; }
  [[ -z $COMP  || $COMP =~ ^(zstd|gzip|xz|none)$ ]] || die "--compress must be zstd, gzip, xz or none"
  [[ -z $LEVEL || $LEVEL =~ ^[0-9]+$ ]] || die "--level must be a number"
  [[ -z $MODE  || $MODE =~ ^(pi|efi|bios)$ ]] || die "--mode must be pi, efi or bios"
  local ex
  for ex in "${EXCLUDES[@]}"; do [[ $ex == /* ]] || die "--exclude needs an absolute path: $ex"; done
  SRC=$(realpath -e "$SRC") || die "Source '$SRC' does not exist"
  OUTPUT=$(realpath -m "$OUTPUT")
}

preflight() {
  (( EUID == 0 )) || die "Must be run as root (sudo) to read every file"
  [[ -e $SRC/bin/sh && -f $SRC/etc/fstab ]] || die "$SRC does not look like a Linux root filesystem"
  [[ -d ${OUTPUT%/*} ]] || die "Directory ${OUTPUT%/*} does not exist"
  [[ ! -e $OUTPUT ]] || (( FORCE )) || die "$OUTPUT already exists (use --force to overwrite)"

  local cmd
  for cmd in tar findmnt df od awk; do
    command -v "$cmd" >/dev/null || die "Missing tool: $cmd"
  done
  if [[ -z $COMP ]]; then
    if command -v zstd >/dev/null; then COMP=zstd; else COMP=gzip; fi
  fi
  case $COMP in
    zstd) command -v zstd >/dev/null || die "zstd not installed (apt install zstd)" ;;
    xz)   command -v xz   >/dev/null || die "xz not installed (apt install xz-utils)" ;;
    gzip) command -v gzip >/dev/null || die "gzip not installed" ;;
  esac
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
    if [[ -f $SRC/boot/firmware/cmdline.txt ]]; then PI_BOOT_DIR=/boot/firmware
    elif [[ -f $SRC/boot/cmdline.txt ]];        then PI_BOOT_DIR=/boot
    else die "Pi mode, but no cmdline.txt found in $SRC/boot or $SRC/boot/firmware"; fi
  fi
}

# The local filesystems that make up the system (skips /mnt, /media and pseudo filesystems)
collect_sources() {
  local mp fstype src_norm=${SRC%/} rel used size
  while read -r mp fstype; do
    [[ $fstype =~ ^(ext[234]|xfs|btrfs|f2fs|vfat|exfat|jfs|reiserfs)$ ]] || continue
    mp=$(printf '%b' "$mp")                                 # decode \040 etc.
    rel=${mp#"$src_norm"}; rel=${rel:-/}
    [[ $rel == /mnt/* || $rel == /media/* ]] && continue    # removable / ad-hoc mounts
    read -r used size < <(df -B1M --output=used,size "$mp" | tail -n1)
    SRC_MP+=("$mp"); SRC_REL+=("$rel"); SRC_FSTYPE+=("$fstype"); SRC_USED+=("$used"); SRC_SIZE+=("$size")
    USED_MIB=$(( USED_MIB + used ))
  done < <(findmnt -R -n -l -o TARGET,FSTYPE "$SRC")
  [[ ${SRC_REL[0]:-} == / ]] || die "Could not identify the source root filesystem at $SRC"
}

show_plan() {
  local i avail
  echo
  printf '%sSource%s  %s   (mode: %s, arch: %s)\n' "$C_B" "$C_0" "$SRC" "$MODE" "$(elf_arch "$SRC/usr/bin/env")"
  for i in "${!SRC_REL[@]}"; do
    printf '   %-22s %-6s %10s used of %s\n' "${SRC_REL[i]}" "${SRC_FSTYPE[i]}" \
      "$(human_mib "${SRC_USED[i]}")" "$(human_mib "${SRC_SIZE[i]}")"
  done
  (( ${#EXCLUDES[@]} )) && echo "   excluded: ${EXCLUDES[*]}"
  avail=$(df -B1M --output=avail "${OUTPUT%/*}" | tail -n1 | tr -d ' ')
  printf '%sOutput%s  %s   (%s, %s free)\n\n' "$C_B" "$C_0" "$OUTPUT" "$COMP" "$(human_mib "$avail")"
  if [[ $COMP == none ]] && (( avail < USED_MIB )); then
    die "Not enough free space for an uncompressed archive (~$(human_mib "$USED_MIB") needed)"
  elif (( avail < USED_MIB / 2 )); then
    warn "Only $(human_mib "$avail") free for ~$(human_mib "$USED_MIB") of data - the archive may not fit."
  fi
  if [[ $SRC == / ]]; then
    warn "Archiving a running system: stop databases and other busy services first for a consistent copy."
  fi
}

# ------------------------------------------------------------- archiving --
write_meta() {
  local i os host
  mkdir -p "$TMPD/.clone-archive"
  host=$(tr -cd 'A-Za-z0-9.-' < "$SRC/etc/hostname" 2>/dev/null || true)
  os=$(sed -n 's/^PRETTY_NAME=//p' "$SRC/etc/os-release" 2>/dev/null | tr -d '"' | tr -d '|\n' || true)
  {
    echo "FORMAT=1"
    echo "CREATOR=$PROG $VERSION"
    echo "CREATED=$(date -Is)"
    echo "HOSTNAME=$host"
    echo "OS=$os"
    echo "ARCH=$(elf_arch "$SRC/usr/bin/env")"
    echo "MODE=$MODE"
    echo "PI_BOOT_DIR=$PI_BOOT_DIR"
    echo "USED_MIB=$USED_MIB"
    echo "FS_COUNT=${#SRC_REL[@]}"
    for i in "${!SRC_REL[@]}"; do    # mountpoint|fstype|used MiB|size MiB
      echo "FS_$i=${SRC_REL[i]}|${SRC_FSTYPE[i]}|${SRC_USED[i]}|${SRC_SIZE[i]}"
    done
  } > "$TMPD/.clone-archive/meta"
}

build_excludes() {
  local rel ex src_norm=${SRC%/}
  # --anchored: patterns match from the start of the member name (./proc/..., not */proc/*)
  TAR_EXCL=(--anchored --wildcards
    --exclude='./dev/*' --exclude='./proc/*' --exclude='./sys/*' --exclude='./run/*'
    --exclude='./tmp/*' --exclude='./mnt/*' --exclude='./media/*'
    --exclude=./lost+found --exclude=./var/swap --exclude='./var/cache/apt/archives/*.deb')
  for rel in "${SRC_REL[@]}"; do
    [[ $rel == / ]] || TAR_EXCL+=("--exclude=.$rel/lost+found")
  done
  for ex in "${EXCLUDES[@]}"; do
    TAR_EXCL+=("--exclude=.${ex%/}")
  done
  # Never archive the archive itself
  if [[ $OUTPUT == "$src_norm"/* ]]; then
    rel=${OUTPUT#"$src_norm"}
    TAR_EXCL+=("--exclude=.$rel" "--exclude=.$rel.part")
  fi
}

run_archive() {
  local rel rc rcfile="$TMPD/tar.rc"
  local -a paths=()
  for rel in "${SRC_REL[@]}"; do
    if [[ $rel == / ]]; then paths+=(.); else paths+=(".$rel"); fi
  done

  log "Writing $OUTPUT"
  # --one-file-system applies per path, so each listed filesystem is archived once
  # and nothing else (network mounts, pseudo filesystems) is crossed into.
  {
    tar --create --file=- --numeric-owner --xattrs --xattrs-include='*' --acls --sparse \
        --one-file-system --warning=no-file-ignored "${TAR_EXCL[@]}" \
        -C "$TMPD" ./.clone-archive \
        -C "$SRC" "${paths[@]}" \
      || echo $? > "$rcfile"
  } | progress $(( USED_MIB * 1048576 )) | compress > "$OUTPUT.part"

  rc=$(cat "$rcfile" 2>/dev/null || echo 0)
  if (( rc == 1 )); then
    warn "Some files changed while they were being read (normal on a running system)."
  elif (( rc > 1 )); then
    die "tar failed (exit $rc)"
  fi
  mv -f "$OUTPUT.part" "$OUTPUT"
}

verify_archive() {
  local n
  log "Verifying archive"
  n=$(decompress < "$OUTPUT" | tar -tf - | wc -l)
  (( n > 1 )) || die "Archive appears to be empty"
  log "Archive OK: $n entries"
  log "SHA-256: $(sha256sum "$OUTPUT" | cut -d' ' -f1)"
}

cleanup() {
  local rc=$?
  [[ -n $TMPD ]] && rm -rf "$TMPD"
  if (( rc != 0 )); then
    rm -f "$OUTPUT.part"
    printf '%sFailed (exit %d). No archive was written.%s\n' "$C_R" "$rc" "$C_0" >&2
  fi
}

main() {
  parse_args "$@"
  preflight
  detect_mode
  collect_sources
  show_plan

  TMPD=$(mktemp -d)
  trap cleanup EXIT
  trap 'die "Command failed at line $LINENO: $BASH_COMMAND"' ERR

  write_meta
  build_excludes
  run_archive
  (( VERIFY )) && verify_archive

  echo
  printf '%sArchive complete:%s %s (%s)\n' "$C_G$C_B" "$C_0" "$OUTPUT" \
    "$(human_mib $(( $(stat -c %s "$OUTPUT") / 1048576 )))"
  echo "Restore it onto a disk with:"
  echo "  sudo ./system-restore.sh --plan $OUTPUT /dev/sdX"
}

main "$@"
