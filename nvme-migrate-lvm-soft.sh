#!/usr/bin/env bash
#
# ╔════════════════════════════════════════════════════════════════════════════╗
# ║  Debian 12 NVMe Migration Script v1.3 (Fixed BIOS Boot)                   ║
# ║  Root 37GB + LVM /home + UEFI/BIOS auto-detection                         ║
# ╚════════════════════════════════════════════════════════════════════════════╝
#
# Author: karen20ced4
# Repository: https://github.com/karen20ced4/NVME-Migrate
# Version: 1.3
# Date: 2025-10-20
#
# Changelog v1.3:
# - FIX CRITICAL: Added BIOS Boot Partition for GPT+BIOS systems
# - BIOS mode now creates 4 partitions (p1=BIOS Boot, p2=root, p3=swap, p4=LVM)
# - Auto-install grub-pc in chroot if missing (BIOS mode)
# - Fixed partition numbering: root is now p2 (not p1) in BIOS mode
# - Added better error handling for GRUB installation
#
# Changelog v1.2:
# - Fix lsblk: afișare corectă disk-uri (compatibilitate util-linux)
# - Afișare îmbunătățită device-uri USB/SATA/NVMe
# - Verificare robustă pentru toate tipurile de adaptoare USB-NVMe
# - Header cu informații versiune și dată
# - Mesaje de așteptare pentru detectare USB
#
# Changelog v1.1:
# - Adăugat verificare comenzi necesare
# - Corectare unități parted (GiB consistent)
# - Adăugat mkfs.fat pentru ESP (UEFI)
# - Fix rsync: exclude /home pentru a evita loop-uri
# - Adăugat partprobe/udevadm settle
# - Validări: NEW_DISK ≠ ROOT_DISK
# - Logică clară: p3 = ESP (UEFI) sau LVM (BIOS)
# - Adăugat update-initramfs în chroot
# - fstab: adăugat entry pentru /boot/efi (UEFI)
# - Detectare PV vechi îmbunătățită cu fallback interactiv
# - Interfață text îmbunătățită cu culori și progress
# - Validări extinse pentru VG/LV
# - Backup automat fstab
# - Logging detaliat
# - Safety checks extinse

set -euo pipefail
IFS=$'\n\t'

# ═══════════════════════════════════════════════════════════════════════════
#  SCRIPT INFO
# ═══════════════════════════════════════════════════════════════════════════
SCRIPT_VERSION="1.3"
SCRIPT_DATE="2025-10-20"
SCRIPT_AUTHOR="karen20ced4"
SCRIPT_REPO="https://github.com/karen20ced4/NVME-Migrate"

# ═══════════════════════════════════════════════════════════════════════════
#  COLOR DEFINITIONS
# ═══════════════════════════════════════════════════════════════════════════
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    DIM='\033[2m'
    NC='\033[0m' # No Color
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' DIM='' NC=''
fi

# ═══════════════════════════════════════════════════════════════════════════
#  HELPER FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════

print_header() {
    echo -e "${CYAN}${BOLD}"
    echo "╔════════════════════════════════════════════════════════════════════════════╗"
    echo "║  Debian 12 NVMe Migration Script v${SCRIPT_VERSION}                                      ║"
    echo "║  Root 37GB + LVM /home + UEFI/BIOS auto-detection                         ║"
    echo "╚════════════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo -e "${DIM}Version: ${SCRIPT_VERSION} | Date: ${SCRIPT_DATE} | Author: ${SCRIPT_AUTHOR}${NC}"
    echo -e "${DIM}Repository: ${SCRIPT_REPO}${NC}\n"
}

print_step() {
    echo -e "\n${BLUE}${BOLD}[STEP $1/$2]${NC} ${BOLD}$3${NC}"
    echo -e "${DIM}────────────────────────────────────────────────────────────────────────────${NC}"
}

print_success() {
    echo -e "${GREEN}${BOLD}✔${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}${BOLD}⚠${NC} $1"
}

print_error() {
    echo -e "${RED}${BOLD}✖${NC} $1"
}

print_info() {
    echo -e "${CYAN}ℹ${NC} $1"
}

confirm_action() {
    local prompt="$1"
    local default="${2:-no}"
    local response
    
    if [ "$default" = "yes" ]; then
        read -rp "$(echo -e ${YELLOW}${BOLD}${prompt}${NC} [Y/n]: )" response
        response=${response:-y}
    else
        read -rp "$(echo -e ${YELLOW}${BOLD}${prompt}${NC} [y/N]: )" response
        response=${response:-n}
    fi
    
    [[ "$response" =~ ^[Yy] ]]
}

show_progress() {
    local current=$1
    local total=$2
    local width=50
    local percentage=$((current * 100 / total))
    local filled=$((width * current / total))
    local empty=$((width - filled))
    
    printf "\r${CYAN}Progress: [${GREEN}"
    printf "%${filled}s" | tr ' ' '█'
    printf "${DIM}"
    printf "%${empty}s" | tr ' ' '░'
    printf "${CYAN}] ${BOLD}%3d%%${NC}" $percentage
}

# ═══════════════════════════════════════════════════════════════════════════
#  MAIN SCRIPT
# ═══════════════════════════════════════════════════════════════════════════

clear
print_header

TOTAL_STEPS=15
CURRENT_STEP=0

# ───────────────────────────────────────────────────────────────────────────
print_step $((++CURRENT_STEP)) $TOTAL_STEPS "Verificare comenzi necesare"
# ───────────────────────────────────────────────────────────────────────────

required_cmds=(parted lsblk rsync mkfs.ext4 mkswap pvcreate vgextend lvextend \
               blkid grub-install update-grub mkfs.fat partprobe udevadm \
               pvs vgs lvs readlink awk sed numfmt swapon stat update-initramfs \
               findmnt mount umount chroot blockdev)

missing=()
for cmd in "${required_cmds[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        missing+=("$cmd")
    fi
done

if [ "${#missing[@]}" -ne 0 ]; then
    print_error "Lipsesc comenzile necesare: ${missing[*]}"
    print_info "Instalează pachetele necesare:"
    echo "  apt install parted rsync lvm2 grub-common grub-efi-amd64 dosfstools gdisk e2fsprogs util-linux coreutils"
    exit 1
fi
print_success "Toate comenzile necesare sunt disponibile"

# ───────────────────────────────────────────────────────────────────────────
print_step $((++CURRENT_STEP)) $TOTAL_STEPS "Detectare mod boot (UEFI / BIOS)"
# ───────────────────────────────────────────────────────────────────────────

if [ -d /sys/firmware/efi ]; then
    BOOT_MODE="UEFI"
    print_info "Sistem detectat automat ca: ${GREEN}${BOLD}UEFI${NC}"
else
    BOOT_MODE="BIOS"
    print_info "Sistem detectat automat ca: ${GREEN}${BOLD}BIOS${NC}"
fi

read -rp "$(echo -e ${CYAN}Confirmi modul ${BOLD}$BOOT_MODE${NC}${CYAN} sau schimbi? [BIOS/UEFI/ENTER păstrează]: ${NC})" USER_BOOT
if [[ -n "$USER_BOOT" && "$USER_BOOT" =~ ^(BIOS|UEFI)$ ]]; then
    BOOT_MODE="$USER_BOOT"
    print_warning "Mod boot suprascris manual la: $BOOT_MODE"
fi
print_success "Boot mode folosit: ${BOLD}$BOOT_MODE${NC}"

# ───────────────────────────────────────────────────────────────────────────
print_step $((++CURRENT_STEP)) $TOTAL_STEPS "Detectare dispozitiv root"
# ───────────────────────────────────────────────────────────────────────────

ROOT_DEV=$(findmnt -no SOURCE /)
if [ -z "$ROOT_DEV" ]; then
    print_error "Nu am putut detecta root device (findmnt /)"
    exit 1
fi

# Detectare disc fizic pentru root
ROOT_DISK=""
pkname=$(lsblk -no PKNAME "$ROOT_DEV" 2>/dev/null || true)
if [ -n "$pkname" ]; then
    ROOT_DISK="/dev/$pkname"
else
    ROOT_DISK=$(echo "$ROOT_DEV" | sed -E 's/p?[0-9]+$//' || true)
fi
ROOT_DISK=$(readlink -f "$ROOT_DISK" 2>/dev/null || echo "$ROOT_DISK")

print_success "Root device: ${BOLD}$ROOT_DEV${NC}"
print_success "Root disk (fizic): ${BOLD}$ROOT_DISK${NC}"

# ───────────────────────────────────────────────────────────────────────────
print_step $((++CURRENT_STEP)) $TOTAL_STEPS "Detectare swap"
# ───────────────────────────────────────────────────────────────────────────

SWAP_PART=""
SWAP_SIZE_BYTES=0
SWAP_ENTRY=$(swapon --noheadings --show=NAME 2>/dev/null | head -n1 || true)

if [ -n "$SWAP_ENTRY" ]; then
    SWAP_PART="$SWAP_ENTRY"
    if [ -b "$SWAP_PART" ]; then
        SWAP_SIZE_BYTES=$(blockdev --getsize64 "$SWAP_PART" 2>/dev/null || echo 0)
    else
        # swap file
        SWAP_SIZE_BYTES=$(stat -c%s "$SWAP_PART" 2>/dev/null || echo 0)
    fi
fi

SWAP_SIZE_GI=$(( (SWAP_SIZE_BYTES + 1024**3 - 1) / 1024**3 ))
[ "$SWAP_SIZE_GI" -lt 1 ] && SWAP_SIZE_GI=1

if [ -n "$SWAP_PART" ]; then
    print_success "Swap: ${BOLD}$SWAP_PART${NC} ($(numfmt --to=iec $SWAP_SIZE_BYTES)) → ${SWAP_SIZE_GI} GiB"
else
    print_warning "Nu am detectat swap activ. Folosesc 1 GiB implicit."
fi

# ───────────────────────────────────────────────────────────────────────────
print_step $((++CURRENT_STEP)) $TOTAL_STEPS "Detectare /home LV + VG"
# ───────────────────────────────────────────────────────────────────────────

HOME_SOURCE=$(findmnt -no SOURCE /home 2>/dev/null || true)
VG_NAME=""
LV_NAME=""

if [ -n "$HOME_SOURCE" ] && [[ "$HOME_SOURCE" == /dev/* ]]; then
    VG_NAME=$(lvs --noheadings -o vg_name "$HOME_SOURCE" 2>/dev/null | awk '{gsub(/^[ \t]+|[ \t]+$/,"",$1); print $1}' || true)
    LV_NAME=$(lvs --noheadings -o lv_name "$HOME_SOURCE" 2>/dev/null | awk '{gsub(/^[ \t]+|[ \t]+$/,"",$1); print $1}' || true)
fi

if [ -n "$VG_NAME" ] && [ -n "$LV_NAME" ]; then
    HOME_SIZE=$(lvs --noheadings --units g -o lv_size "$HOME_SOURCE" 2>/dev/null | awk '{print $1}' || echo "N/A")
    print_success "/home LV detectat: ${BOLD}$VG_NAME/$LV_NAME${NC} ($HOME_SOURCE, $HOME_SIZE)"
else
    print_warning "/home nu este o LV separată detectabilă"
    print_warning "Operațiunile LVM vor fi omise dacă nu furnizezi detalii manual"
    VG_NAME=""
    LV_NAME=""
fi

# ───────────────────────────────────────────────────────────────────────────
print_step $((++CURRENT_STEP)) $TOTAL_STEPS "Selectare dispozitiv NVMe nou"
# ───────────────────────────────────────────────────────────────────────────

echo -e "\n${BOLD}Dispozitive de stocare disponibile:${NC}"
echo -e "${DIM}(disk-uri fizice: HDD, SSD, NVMe, USB)${NC}\n"

# Afișare simplă și robustă - funcționează pe toate versiunile de util-linux
# Eliminăm loop devices și CD/DVD-uri
lsblk -d -p -o NAME,SIZE,MODEL,TRAN 2>/dev/null | while IFS= read -r line; do
    # Skip loop devices și CD/DVD
    if [[ "$line" =~ loop|sr[0-9] ]]; then
        continue
    fi
    
    if [[ "$line" =~ ^NAME ]]; then
        # Header cu bold
        echo -e "  ${BOLD}$line${NC}"
    else
        # Device entries
        echo "  $line"
    fi
done

echo -e "\n${BOLD}Vedere detaliată (cu partiții și filesystem-uri):${NC}"
lsblk -o NAME,SIZE,MODEL,TRAN,FSTYPE,MOUNTPOINT

echo -e "\n${CYAN}${BOLD}NOTĂ:${NC} ${DIM}Dacă ai conectat noul NVMe prin USB și nu apare mai sus:${NC}"
echo -e "${DIM}  1) Deconectează și reconectează case-ul USB${NC}"
echo -e "${DIM}  2) Așteaptă 10 secunde${NC}"
echo -e "${DIM}  3) Verifică cu: sudo dmesg | tail -20${NC}"
echo -e "${DIM}  4) Apoi rulează din nou scriptul${NC}"

echo ""
read -rp "$(echo -e ${CYAN}${BOLD}Introdu noul NVMe${NC}${CYAN} [ex: /dev/sdb sau /dev/nvme1n1]: ${NC})" NEW_DISK

if [ -z "$NEW_DISK" ] || [ ! -b "$NEW_DISK" ]; then
    print_error "Dispozitiv invalid sau inexistent: $NEW_DISK"
    exit 1
fi

NEW_DISK=$(readlink -f "$NEW_DISK")
print_success "Dispozitiv selectat: ${BOLD}$NEW_DISK${NC}"

# Verificare: NEW_DISK != ROOT_DISK
if [ "$NEW_DISK" = "$ROOT_DISK" ]; then
    print_error "EROARE CRITICĂ: NEW_DISK este același cu ROOT_DISK!"
    print_error "Ai selectat discul care conține root-ul curent ($ROOT_DISK)"
    print_error "Opresc scriptul pentru a preveni pierderea datelor."
    exit 1
fi

# Verificare: dispozitiv nu este montat
if mount | grep -q "^$NEW_DISK"; then
    print_warning "Dispozitivul $NEW_DISK sau partițiile sale sunt montate:"
    mount | grep "^$NEW_DISK"
    if ! confirm_action "Vrei să continui? (risc de pierdere date)" "no"; then
        exit 0
    fi
fi

# Afișare info despre disc
NEW_DISK_SIZE=$(lsblk -bno SIZE "$NEW_DISK" 2>/dev/null || echo 0)
NEW_DISK_SIZE_GB=$((NEW_DISK_SIZE / 1024**3))
NEW_DISK_MODEL=$(lsblk -dno MODEL "$NEW_DISK" 2>/dev/null | xargs || echo "Unknown")
print_info "Mărime disc nou: ${BOLD}${NEW_DISK_SIZE_GB} GB${NC} ($(numfmt --to=iec $NEW_DISK_SIZE))"
print_info "Model: ${BOLD}${NEW_DISK_MODEL}${NC}"

echo -e "\n${RED}${BOLD}╔═══════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}${BOLD}║  ⚠️  AVERTISMENT: TOATE DATELE DE PE $NEW_DISK VOR FI ȘTERSE! ⚠️       ║${NC}"
echo -e "${RED}${BOLD}╚═══════════════════════════════════════════════════════════════════════╝${NC}"

if ! confirm_action "Confirmă ștergerea COMPLETĂ a $NEW_DISK" "no"; then
    print_info "Operațiune anulată de utilizator."
    exit 0
fi

# ───────────────────────────────────────────────────────────────────────────
print_step $((++CURRENT_STEP)) $TOTAL_STEPS "Creare tabel partiții și partiționare"
# ───────────────────────────────────────────────────────────────────────────

ROOT_SIZE_GI=37
print_info "Schema partiții: Root=${ROOT_SIZE_GI}GiB, Swap=${SWAP_SIZE_GI}GiB, Rest=LVM/ESP"

if [ "$BOOT_MODE" = "UEFI" ]; then
    # ===== UEFI mode: GPT cu ESP =====
    parted -s "$NEW_DISK" mklabel gpt 2>/dev/null || {
        print_error "Eroare la creare tabel partiții GPT"
        exit 1
    }
    print_success "Tabel GPT creat (UEFI)"

    # Partiție 1: Root (ext4)
    parted -s "$NEW_DISK" mkpart primary ext4 1MiB "${ROOT_SIZE_GI}GiB" 2>/dev/null
    print_success "Partiție 1 (root): 1MiB - ${ROOT_SIZE_GI}GiB"

    # Partiție 2: Swap
    parted -s "$NEW_DISK" mkpart primary linux-swap "${ROOT_SIZE_GI}GiB" "$((ROOT_SIZE_GI + SWAP_SIZE_GI))GiB" 2>/dev/null
    print_success "Partiție 2 (swap): ${ROOT_SIZE_GI}GiB - $((ROOT_SIZE_GI + SWAP_SIZE_GI))GiB"

    # Partiție 3: ESP (EFI System Partition)
    parted -s "$NEW_DISK" mkpart ESP fat32 "$((ROOT_SIZE_GI + SWAP_SIZE_GI))GiB" 100% 2>/dev/null
    parted -s "$NEW_DISK" set 3 boot on 2>/dev/null
    parted -s "$NEW_DISK" set 3 esp on 2>/dev/null
    print_success "Partiție 3 (ESP): $((ROOT_SIZE_GI + SWAP_SIZE_GI))GiB - 100%"

    # Nume partiții
    if [[ "$NEW_DISK" =~ nvme ]]; then
        NEW_ROOT="${NEW_DISK}p1"
        NEW_SWAP="${NEW_DISK}p2"
        NEW_EXTRA="${NEW_DISK}p3"
    else
        NEW_ROOT="${NEW_DISK}1"
        NEW_SWAP="${NEW_DISK}2"
        NEW_EXTRA="${NEW_DISK}3"
    fi

else
    # ===== BIOS mode: GPT cu BIOS Boot Partition =====
    parted -s "$NEW_DISK" mklabel gpt 2>/dev/null || {
        print_error "Eroare la creare tabel partiții GPT"
        exit 1
    }
    print_success "Tabel GPT creat (BIOS)"

    # Partiție 1: BIOS Boot Partition (1-2 MiB, fără filesystem)
    parted -s "$NEW_DISK" mkpart primary 1MiB 2MiB 2>/dev/null
    parted -s "$NEW_DISK" set 1 bios_grub on 2>/dev/null
    print_success "Partiție 1 (BIOS Boot): 1MiB - 2MiB"

    # Partiție 2: Root (ext4)
    parted -s "$NEW_DISK" mkpart primary ext4 2MiB "${ROOT_SIZE_GI}GiB" 2>/dev/null
    print_success "Partiție 2 (root): 2MiB - ${ROOT_SIZE_GI}GiB"

    # Partiție 3: Swap
    parted -s "$NEW_DISK" mkpart primary linux-swap "${ROOT_SIZE_GI}GiB" "$((ROOT_SIZE_GI + SWAP_SIZE_GI))GiB" 2>/dev/null
    print_success "Partiție 3 (swap): ${ROOT_SIZE_GI}GiB - $((ROOT_SIZE_GI + SWAP_SIZE_GI))GiB"

    # Partiție 4: LVM
    parted -s "$NEW_DISK" mkpart primary "$((ROOT_SIZE_GI + SWAP_SIZE_GI))GiB" 100% 2>/dev/null
    parted -s "$NEW_DISK" set 4 lvm on 2>/dev/null
    print_success "Partiție 4 (LVM): $((ROOT_SIZE_GI + SWAP_SIZE_GI))GiB - 100%"

    # Nume partiții (BIOS are 4 partiții, nu 3!)
    if [[ "$NEW_DISK" =~ nvme ]]; then
        NEW_ROOT="${NEW_DISK}p2"  # root e p2 (p1 = BIOS Boot)
        NEW_SWAP="${NEW_DISK}p3"
        NEW_EXTRA="${NEW_DISK}p4" # LVM e p4
    else
        NEW_ROOT="${NEW_DISK}2"
        NEW_SWAP="${NEW_DISK}3"
        NEW_EXTRA="${NEW_DISK}4"
    fi
fi

# Update kernel partition table
print_info "Actualizare tabel partiții în kernel..."
partprobe "$NEW_DISK" 2>/dev/null || true
udevadm settle --timeout=10 2>/dev/null || true
sleep 2

# Verificare existență device nodes
for part in "$NEW_ROOT" "$NEW_SWAP" "$NEW_EXTRA"; do
    if [ ! -b "$part" ]; then
        print_warning "Aștept crearea device node pentru $part..."
        sleep 2
        udevadm settle --timeout=10 2>/dev/null || true
    fi
    if [ ! -b "$part" ]; then
        print_error "Device node $part nu există după partiționare!"
        exit 1
    fi
done

print_success "Device nodes create: $NEW_ROOT, $NEW_SWAP, $NEW_EXTRA"

# ───────────────────────────────────────────────────────────────────────────
print_step $((++CURRENT_STEP)) $TOTAL_STEPS "Formatare partiții"
# ───────────────────────────────────────────────────────────────────────────

# Formatare root (ext4)
print_info "Formatare $NEW_ROOT ca ext4..."
mkfs.ext4 -F -L "newroot" "$NEW_ROOT" >/dev/null 2>&1 || {
    print_error "Eroare la formatare root"
    exit 1
}
print_success "Root formatat: $NEW_ROOT (ext4)"

# Configurare swap
if [ -b "$NEW_SWAP" ]; then
    print_info "Configurare swap pe $NEW_SWAP..."
    mkswap -f -L "newswap" "$NEW_SWAP" >/dev/null 2>&1 || {
        print_error "Eroare la configurare swap"
        exit 1
    }
    print_success "Swap configurat: $NEW_SWAP"
else
    print_warning "$NEW_SWAP nu este block device; omit mkswap"
fi

# Formatare ESP (doar pentru UEFI)
if [ "$BOOT_MODE" = "UEFI" ]; then
    print_info "Formatare $NEW_EXTRA ca FAT32 (ESP)..."
    mkfs.fat -F32 -n "EFI" "$NEW_EXTRA" >/dev/null 2>&1 || {
        print_error "Eroare la formatare ESP"
        exit 1
    }
    print_success "ESP formatat: $NEW_EXTRA (FAT32)"
fi

udevadm settle --timeout=5 2>/dev/null || true
sleep 1

# ───────────────────────────────────────────────────────────────────────────
print_step $((++CURRENT_STEP)) $TOTAL_STEPS "Configurare LVM (dacă e cazul)"
# ───────────────────────────────────────────────────────────────────────────

if [ "$BOOT_MODE" = "BIOS" ]; then
    if [ -n "$VG_NAME" ]; then
        print_info "Creare PV pe $NEW_EXTRA și extindere VG '$VG_NAME'..."
        pvcreate -ff -y "$NEW_EXTRA" >/dev/null 2>&1 || {
            print_error "Eroare la pvcreate"
            exit 1
        }
        vgextend "$VG_NAME" "$NEW_EXTRA" >/dev/null 2>&1 || {
            print_error "Eroare la vgextend"
            exit 1
        }
        
        VG_SIZE=$(vgs --noheadings --units g -o vg_size "$VG_NAME" 2>/dev/null | awk '{print $1}')
        VG_FREE=$(vgs --noheadings --units g -o vg_free "$VG_NAME" 2>/dev/null | awk '{print $1}')
        print_success "LVM extins: VG '$VG_NAME' (total: $VG_SIZE, free: $VG_FREE)"
        print_info "pvmove se va face la final (opțional)"
    else
        print_warning "Nu am VG_NAME detectat; omit pvcreate/vgextend"
        print_info "Poți adăuga manual: pvcreate $NEW_EXTRA && vgextend <VG> $NEW_EXTRA"
    fi
else
    print_info "UEFI: p3 este ESP, nu-l folosim pentru LVM"
fi

# ───────────────────────────────────────────────────────────────────────────
print_step $((++CURRENT_STEP)) $TOTAL_STEPS "Montare și sincronizare sistem"
# ───────────────────────────────────────────────────────────────────────────

mkdir -p /mnt/newroot
mount "$NEW_ROOT" /mnt/newroot || {
    print_error "Eroare la montare $NEW_ROOT"
    exit 1
}
print_success "Montat: $NEW_ROOT → /mnt/newroot"

# Creare directoare standard
mkdir -p /mnt/newroot/{dev,proc,sys,run,home,boot,tmp}
print_success "Directoare create în /mnt/newroot"

# Rsync sistem (exclude /home pentru a evita loop)
echo -e "\n${CYAN}${BOLD}Sincronizare sistem...${NC} ${DIM}(poate dura câteva minute)${NC}\n"

rsync -aAXH --info=progress2 \
    --exclude={"/home/*","/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/mnt/*","/media/*","/lost+found","/swapfile"} \
    / /mnt/newroot || {
    print_error "Eroare la rsync"
    exit 1
}

echo "" # newline după progress
print_success "Sistem sincronizat (fără /home)"

# Bind mount pseudo-filesystems
print_info "Montare pseudo-filesystems pentru chroot..."
for fs in dev dev/pts proc sys run; do
    mount --bind "/$fs" "/mnt/newroot/$fs" || {
        print_error "Eroare la bind mount /$fs"
        exit 1
    }
done
print_success "Pseudo-filesystems montate"

# Bind /home (doar pentru chroot, nu pentru rsync)
if [ -d /home ] && mountpoint -q /home 2>/dev/null; then
    mount --bind /home /mnt/newroot/home || true
    print_success "/home montat (bind) pentru chroot"
fi

# ───────────────────────────────────────────────────────────────────────────
print_step $((++CURRENT_STEP)) $TOTAL_STEPS "Instalare GRUB și update initramfs"
# ───────────────────────────────────────────────────────────────────────────

# Mount efivars pentru UEFI
if [ "$BOOT_MODE" = "UEFI" ]; then
    if [ -d /sys/firmware/efi/efivars ]; then
        mkdir -p /mnt/newroot/sys/firmware/efi/efivars
        mount -t efivarfs efivarfs /mnt/newroot/sys/firmware/efi/efivars 2>/dev/null || true
        print_success "efivars montat în chroot"
    fi
fi

if [ "$BOOT_MODE" = "UEFI" ]; then
    # Montare ESP și copiere conținut existent
    mkdir -p /mnt/newroot/boot/efi
    mount "$NEW_EXTRA" /mnt/newroot/boot/efi || {
        print_error "Eroare la montare ESP"
        exit 1
    }
    print_success "ESP montat: $NEW_EXTRA → /mnt/newroot/boot/efi"
    
    if [ -d /boot/efi ] && [ "$(ls -A /boot/efi 2>/dev/null)" ]; then
        print_info "Copiere conținut /boot/efi existent..."
        rsync -aAXH /boot/efi/ /mnt/newroot/boot/efi/ || true
        print_success "Conținut EFI copiat"
    fi
    
    # Instalare GRUB UEFI
    print_info "Instalare GRUB (UEFI mode)..."
    chroot /mnt/newroot /bin/bash -c "
        set -e
        update-initramfs -u -k all 2>&1 | grep -v 'which: no'
        grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian --recheck --no-nvram 2>&1
        update-grub 2>&1
    " || {
        print_error "Eroare la instalare GRUB UEFI"
        exit 1
    }
    print_success "GRUB instalat (UEFI) pe $NEW_DISK"
else
    # Instalare GRUB BIOS
    print_info "Instalare GRUB (BIOS/MBR mode)..."
    chroot /mnt/newroot /bin/bash -c "
        set -e
        # Instalează grub-pc dacă lipsește
        if ! dpkg -l grub-pc 2>/dev/null | grep -q '^ii'; then
            echo 'grub-pc grub-pc/install_devices multiselect' | debconf-set-selections
            echo 'grub-pc grub-pc/install_devices_empty boolean true' | debconf-set-selections
            apt-get update -qq
            DEBIAN_FRONTEND=noninteractive apt-get install -y grub-pc grub-pc-bin
        fi
        update-initramfs -u -k all 2>&1 | grep -v 'which: no'
        grub-install --target=i386-pc --recheck $NEW_DISK 2>&1
        update-grub 2>&1
    " || {
        print_error "Eroare la instalare GRUB BIOS"
        print_info "Încerc instalare manuală grub-pc..."
        chroot /mnt/newroot bash -c "
            echo 'grub-pc grub-pc/install_devices multiselect' | debconf-set-selections
            echo 'grub-pc grub-pc/install_devices_empty boolean true' | debconf-set-selections
            apt-get update -qq
            DEBIAN_FRONTEND=noninteractive apt-get install -y grub-pc grub-pc-bin
            grub-install --target=i386-pc --recheck $NEW_DISK
            update-grub
        " || exit 1
    }
    print_success "GRUB instalat (BIOS) pe $NEW_DISK"
fi

# ───────────────────────────────────────────────────────────────────────────
print_step $((++CURRENT_STEP)) $TOTAL_STEPS "Actualizare /etc/fstab"
# ───────────────────────────────────────────────────────────────────────────

# Backup fstab original
if [ -f /mnt/newroot/etc/fstab ]; then
    cp /mnt/newroot/etc/fstab /mnt/newroot/etc/fstab.backup.$(date +%Y%m%d_%H%M%S)
    print_info "Backup fstab original salvat"
fi

# Obținere UUID-uri
NEW_ROOT_UUID=$(blkid -s UUID -o value "$NEW_ROOT" 2>/dev/null || true)
NEW_SWAP_UUID=""
if [ -b "$NEW_SWAP" ]; then
    NEW_SWAP_UUID=$(blkid -s UUID -o value "$NEW_SWAP" 2>/dev/null || true)
fi
ESP_UUID=""
if [ "$BOOT_MODE" = "UEFI" ]; then
    ESP_UUID=$(blkid -s UUID -o value "$NEW_EXTRA" 2>/dev/null || true)
fi

# Generare fstab nou
cat > /mnt/newroot/etc/fstab <<EOF
# /etc/fstab - generat de nvme-migrate-lvm-soft v${SCRIPT_VERSION}
# $(date)

# Root filesystem
UUID=$NEW_ROOT_UUID  /      ext4   defaults,noatime  0 1

EOF

if [ -n "$NEW_SWAP_UUID" ]; then
    cat >> /mnt/newroot/etc/fstab <<EOF
# Swap
UUID=$NEW_SWAP_UUID  none   swap   sw                0 0

EOF
fi

if [ -n "$ESP_UUID" ]; then
    cat >> /mnt/newroot/etc/fstab <<EOF
# EFI System Partition
UUID=$ESP_UUID       /boot/efi  vfat  umask=0077      0 1

EOF
fi

if [ -n "$VG_NAME" ] && [ -n "$LV_NAME" ]; then
    cat >> /mnt/newroot/etc/fstab <<EOF
# /home rămâne pe LVM (VG: $VG_NAME, LV: $LV_NAME)
# Entry existent păstrat din configurația originală

EOF
else
    cat >> /mnt/newroot/etc/fstab <<EOF
# /home: nu a fost detectat ca LV automat
# Verifică și adaugă manual dacă este necesar

EOF
fi

print_success "fstab actualizat cu UUID-uri noi"
print_info "Root UUID: $NEW_ROOT_UUID"
[ -n "$NEW_SWAP_UUID" ] && print_info "Swap UUID: $NEW_SWAP_UUID"
[ -n "$ESP_UUID" ] && print_info "ESP UUID: $ESP_UUID"

# ───────────────────────────────────────────────────────────────────────────
print_step $((++CURRENT_STEP)) $TOTAL_STEPS "Extindere LV /home și filesystem"
# ───────────────────────────────────────────────────────────────────────────

if [ -n "$VG_NAME" ] && [ -n "$LV_NAME" ]; then
    # Verificare spațiu liber
    FREE_EXTENTS=$(vgs --noheadings -o vg_free_count "$VG_NAME" 2>/dev/null | awk '{print $1}' || echo 0)
    
    if [ "$FREE_EXTENTS" -gt 0 ]; then
        print_info "Extindere LV /home cu spațiul liber ($FREE_EXTENTS extents)..."
        
        LV_SIZE_BEFORE=$(lvs --noheadings --units g -o lv_size "/dev/$VG_NAME/$LV_NAME" 2>/dev/null | awk '{print $1}')
        
        lvextend -l +100%FREE "/dev/$VG_NAME/$LV_NAME" 2>&1 | grep -v "New size" || true
        
        LV_SIZE_AFTER=$(lvs --noheadings --units g -o lv_size "/dev/$VG_NAME/$LV_NAME" 2>/dev/null | awk '{print $1}')
        print_success "LV extins: $LV_SIZE_BEFORE → $LV_SIZE_AFTER"
        
        # Resize filesystem
        FS_TYPE=$(blkid -s TYPE -o value "/dev/$VG_NAME/$LV_NAME" 2>/dev/null || true)
        print_info "Filesystem type: $FS_TYPE"
        
        if [[ "$FS_TYPE" == "ext4" || "$FS_TYPE" == "ext3" || "$FS_TYPE" == "ext2" ]]; then
            print_info "Extindere filesystem ext4..."
            resize2fs "/dev/$VG_NAME/$LV_NAME" 2>&1 | tail -n 3
            print_success "Filesystem ext4 extins"
        elif [[ "$FS_TYPE" == "xfs" ]]; then
            if mountpoint -q /home 2>/dev/null; then
                print_info "Extindere filesystem xfs..."
                xfs_growfs /home 2>&1 | tail -n 3
                print_success "Filesystem xfs extins"
            else
                print_warning "XFS: /home nu este montat; montează și rulează xfs_growfs manual"
            fi
        else
            print_warning "Filesystem $FS_TYPE necunoscut; resize manual dacă e necesar"
        fi
    else
        print_warning "Nu există spațiu liber în VG '$VG_NAME' pentru extindere"
    fi
else
    print_warning "Omit extindere LV (VG/LV nu detectat)"
fi

# ───────────────────────────────────────────────────────────────────────────
print_step $((++CURRENT_STEP)) $TOTAL_STEPS "Curățare mount-uri temporare"
# ───────────────────────────────────────────────────────────────────────────

print_info "Demontare mount-uri în ordine inversă..."

# Unmount /home bind
umount /mnt/newroot/home 2>/dev/null || true

# Unmount ESP (UEFI)
if [ "$BOOT_MODE" = "UEFI" ]; then
    umount /mnt/newroot/boot/efi 2>/dev/null || true
fi

# Unmount efivars
if [ -d /mnt/newroot/sys/firmware/efi/efivars ]; then
    umount /mnt/newroot/sys/firmware/efi/efivars 2>/dev/null || true
fi

# Unmount pseudo-filesystems
for fs in run sys proc dev/pts dev; do
    umount "/mnt/newroot/$fs" 2>/dev/null || true
done

# Unmount root
umount /mnt/newroot 2>/dev/null || {
    print_warning "Nu pot demonta /mnt/newroot; încerc lazy unmount..."
    umount -l /mnt/newroot 2>/dev/null || true
}

print_success "Mount-uri temporare curățate"

# ───────────────────────────────────────────────────────────────────────────
print_step $((++CURRENT_STEP)) $TOTAL_STEPS "Migrare completă - Rezumat"
# ───────────────────────────────────────────────────────────────────────────

echo -e "\n${GREEN}${BOLD}╔═══════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║  ✔ MIGRARE ROOT + LVM PREGĂTITĂ CU SUCCES!                           ║${NC}"
echo -e "${GREEN}${BOLD}╚═══════════════════════════════════════════════════════════════════════╝${NC}\n"

echo -e "${CYAN}${BOLD}Rezumat configurație:${NC}"
echo -e "  • Boot mode: ${BOLD}$BOOT_MODE${NC}"
echo -e "  • Disc nou: ${BOLD}$NEW_DISK${NC} (${NEW_DISK_SIZE_GB} GB, ${NEW_DISK_MODEL})"
echo -e "  • Root: ${BOLD}$NEW_ROOT${NC} (${ROOT_SIZE_GI} GiB, ext4)"
echo -e "  • Swap: ${BOLD}$NEW_SWAP${NC} (${SWAP_SIZE_GI} GiB)"
if [ "$BOOT_MODE" = "UEFI" ]; then
    echo -e "  • ESP: ${BOLD}$NEW_EXTRA${NC} (FAT32)"
else
    echo -e "  • LVM: ${BOLD}$NEW_EXTRA${NC} (PV în VG: $VG_NAME)"
fi
[ -n "$VG_NAME" ] && echo -e "  • /home: ${BOLD}$VG_NAME/$LV_NAME${NC}"

echo -e "\n${YELLOW}${BOLD}Pași următori:${NC}"
echo -e "  ${BOLD}1)${NC} Verifică /etc/fstab pe discul nou:"
echo -e "     ${DIM}mount $NEW_ROOT /mnt/newroot && cat /mnt/newroot/etc/fstab${NC}"
echo -e "  ${BOLD}2)${NC} Oprește serverul:"
echo -e "     ${DIM}sudo poweroff${NC}"
echo -e "  ${BOLD}3)${NC} Înlocuiește fizic vechiul NVMe ($ROOT_DISK) cu noul NVMe"
echo -e "  ${BOLD}4)${NC} Pornește serverul și verifică boot-ul"
echo -e "  ${BOLD}5)${NC} După boot verifică:"
echo -e "     ${DIM}df -h${NC}"
echo -e "     ${DIM}lsblk${NC}"
echo -e "     ${DIM}pvs && vgs && lvs${NC}"

# ───────────────────────────────────────────────────────────────────────────
print_step $((++CURRENT_STEP)) $TOTAL_STEPS "pvmove (opțional) - Mutare date LVM"
# ───────────────────────────────────────────────────────────────────────────

echo -e "\n${CYAN}${BOLD}Opțiune avansată: pvmove${NC}"
echo -e "${DIM}────────────────────────────────────────────────────────────────────────────${NC}"
print_info "pvmove mută datele LVM de pe vechiul PV (pe $ROOT_DISK) pe noul PV ($NEW_EXTRA)"
print_warning "Acest proces poate dura mult timp (ore) și necesită spațiu suficient"
print_warning "Se recomandă să faci backup înainte!"

if ! confirm_action "Vrei să rulezi pvmove ACUM?" "no"; then
    print_info "pvmove omis. Poți rula manual mai târziu cu:"
    echo -e "  ${DIM}pvmove <PV_VECHI> $NEW_EXTRA${NC}"
    echo -e "  ${DIM}vgreduce $VG_NAME <PV_VECHI>${NC}"
else
    if [ -z "$VG_NAME" ]; then
        print_error "Nu am VG_NAME detectat; nu pot rula pvmove automat"
    else
        # Detectare PV vechi
        OLD_PV=""
        print_info "Căutare PV vechi pe $ROOT_DISK..."
        
        while read -r pv; do
            pv_path=$(readlink -f "$pv" 2>/dev/null || echo "$pv")
            # Verifică dacă PV e pe același disc fizic cu root
            if [[ -n "$pv_path" && -n "$ROOT_DISK" && "$pv_path" == "$ROOT_DISK"* ]]; then
                OLD_PV="$pv"
                break
            fi
        done < <(pvs --noheadings -o pv_name 2>/dev/null | awk '{print $1}')
        
        if [ -z "$OLD_PV" ]; then
            print_warning "Nu am detectat automat PV vechi pe $ROOT_DISK"
            echo -e "\n${BOLD}PV-uri existente:${NC}"
            pvs -o pv_name,vg_name,pv_size,pv_free
            echo ""
            read -rp "$(echo -e ${CYAN}Introdu manual PV vechi [sau ENTER pentru a omite]: ${NC})" OLD_PV
        fi
        
        if [ -n "$OLD_PV" ] && [ -b "$OLD_PV" ]; then
            # Verificare: NEW_EXTRA este în VG
            if ! pvs --noheadings -o pv_name 2>/dev/null | grep -qF "$NEW_EXTRA"; then
                print_error "$NEW_EXTRA nu este un PV în VG; rulează pvcreate/vgextend mai întâi"
                if confirm_action "Vrei să adaug $NEW_EXTRA în VG '$VG_NAME' acum?" "yes"; then
                    pvcreate -ff -y "$NEW_EXTRA" || exit 1
                    vgextend "$VG_NAME" "$NEW_EXTRA" || exit 1
                    print_success "PV adăugat în VG"
                else
                    print_info "pvmove anulat"
                    OLD_PV=""
                fi
            fi
            
            if [ -n "$OLD_PV" ]; then
                OLD_PV_SIZE=$(pvs --noheadings --units g -o pv_size "$OLD_PV" 2>/dev/null | awk '{print $1}')
                print_info "Pornesc pvmove: ${BOLD}$OLD_PV${NC} ($OLD_PV_SIZE) → ${BOLD}$NEW_EXTRA${NC}"
                print_warning "Procesul poate dura mult! NU întrerupe..."
                
                echo ""
                pvmove -i 5 "$OLD_PV" "$NEW_EXTRA" || {
                    print_error "pvmove a eșuat sau a fost întrerupt"
                    print_warning "Poți relua cu: pvmove --abort sau pvmove $OLD_PV $NEW_EXTRA"
                    exit 1
                }
                
                print_success "pvmove complet!"
                print_info "Eliminare PV vechi din VG..."
                vgreduce "$VG_NAME" "$OLD_PV" || {
                    print_warning "vgreduce a eșuat; verifică manual cu pvs/vgs"
                }
                
                echo -e "\n${BOLD}Status LVM după pvmove:${NC}"
                pvs -o pv_name,vg_name,pv_size,pv_free,pv_used
                vgs -o vg_name,vg_size,vg_free
            fi
        else
            print_info "pvmove omis (PV invalid sau nespecificat)"
        fi
    fi
fi

# ───────────────────────────────────────────────────────────────────────────
#  FINAL
# ───────────────────────────────────────────────────────────────────────────

echo -e "\n${GREEN}${BOLD}╔═══════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║  ✔ SCRIPT TERMINAT CU SUCCES! (v${SCRIPT_VERSION})                              ║${NC}"
echo -e "${GREEN}${BOLD}╚═══════════════════════════════════════════════════════════════════════╝${NC}\n"

print_info "Log-ul complet poate fi găsit cu: journalctl -xe"
print_info "Pentru suport: $SCRIPT_REPO"
print_info "Script version: ${SCRIPT_VERSION} | Date: ${SCRIPT_DATE}"

exit 0
