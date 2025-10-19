#!/bin/bash
# Debian12 NVMe migration script (soft version)
# Root 37GB + LVM /home
# UEFI / BIOS detection, pvmove optional la final

set -euo pipefail
IFS=$'\n\t'

echo "=== Debian12 NVMe Migration Script (soft) ==="

# 1️⃣ Detect boot mode
if [ -d /sys/firmware/efi ]; then
    BOOT_MODE="UEFI"
else
    BOOT_MODE="BIOS"
fi
echo "Sistem detectat automat ca: $BOOT_MODE"
read -rp "Confirma modul boot sau schimba (BIOS/UEFI): " USER_BOOT
if [[ "$USER_BOOT" =~ ^(BIOS|UEFI)$ ]]; then
    BOOT_MODE="$USER_BOOT"
fi
echo "Boot mode folosit: $BOOT_MODE"

# 2️⃣ Detect root
ROOT_DEV=$(findmnt -no SOURCE /)
ROOT_DISK=$(lsblk -no PKNAME "$ROOT_DEV" 2>/dev/null || echo "")
if [ -z "$ROOT_DISK" ]; then
    ROOT_DISK=$(echo "$ROOT_DEV" | sed -E 's/p?[0-9]+$//')
else
    ROOT_DISK="/dev/$ROOT_DISK"
fi
echo "Root device: $ROOT_DEV, Root disk: $ROOT_DISK"

# 3️⃣ Detect swap
SWAP_PART=$(swapon --noheadings --show=NAME --bytes | awk '{print $1; exit}' || true)
SWAP_SIZE_BYTES=0
if [ -n "$SWAP_PART" ]; then
    SWAP_SIZE_BYTES=$(blockdev --getsize64 "$SWAP_PART" || echo 0)
fi
SWAP_SIZE_GI=$(( (SWAP_SIZE_BYTES + 1024**3 - 1)/1024**3 ))
[ "$SWAP_SIZE_GI" -lt 1 ] && SWAP_SIZE_GI=1
echo "Swap: $SWAP_PART ($(numfmt --to=iec $SWAP_SIZE_BYTES))"

# 4️⃣ Detect /home LV + VG
HOME_SOURCE=$(findmnt -no SOURCE /home || true)
VG_NAME=$(lvs --noheadings -o vg_name "$HOME_SOURCE" 2>/dev/null | awk '{print $1}' || true)
LV_NAME=$(lvs --noheadings -o lv_name "$HOME_SOURCE" 2>/dev/null | awk '{print $1}' || true)
echo "/home LV detectat: $VG_NAME/$LV_NAME"

# 5️⃣ Noul disk
lsblk -o NAME,SIZE,MODEL,TRAN
read -rp "Introduceți noul NVMe (USB case, ex: /dev/sdb): " NEW_DISK
[ -b "$NEW_DISK" ] || { echo "Dispozitiv invalid."; exit 1; }
read -rp "⚠️ Toate datele de pe $NEW_DISK vor fi șterse. Continuați? (yes/no): " CONFIRM
[ "$CONFIRM" = "yes" ] || exit 0

# 6️⃣ Partiții
ROOT_SIZE_GI=37
echo "Root: ${ROOT_SIZE_GI}GiB, Swap: ${SWAP_SIZE_GI}GiB, rest LVM/EFI"

parted -s "$NEW_DISK" mklabel gpt
parted -s "$NEW_DISK" mkpart primary ext4 1MiB ${ROOT_SIZE_GI}GiB
parted -s "$NEW_DISK" mkpart primary linux-swap ${ROOT_SIZE_GI}GiB $((ROOT_SIZE_GI+SWAP_SIZE_GI))

if [ "$BOOT_MODE" = "UEFI" ]; then
    parted -s "$NEW_DISK" mkpart ESP fat32 $((ROOT_SIZE_GI+SWAP_SIZE_GI))GiB 100%
    parted -s "$NEW_DISK" set 3 boot on
else
    parted -s "$NEW_DISK" mkpart primary $((ROOT_SIZE_GI+SWAP_SIZE_GI))GiB 100%
    parted -s "$NEW_DISK" set 3 lvm on
fi
sleep 2

if [[ "$NEW_DISK" =~ nvme ]]; then
    NEW_ROOT="${NEW_DISK}p1"
    NEW_SWAP="${NEW_DISK}p2"
    NEW_EXTRA="${NEW_DISK}p3"
else
    NEW_ROOT="${NEW_DISK}1"
    NEW_SWAP="${NEW_DISK}2"
    NEW_EXTRA="${NEW_DISK}3"
fi

# 7️⃣ Formatare root si swap
mkfs.ext4 -F "$NEW_ROOT"
mkswap "$NEW_SWAP"

# 8️⃣ LVM /home (nu facem pvmove acum)
if [ "$BOOT_MODE" = "BIOS" ] || [ "$BOOT_MODE" = "UEFI" ]; then
    if ! [[ "$BOOT_MODE" = "UEFI" && -d /boot/efi ]]; then
        pvcreate -ff -y "$NEW_EXTRA"
        vgextend "$VG_NAME" "$NEW_EXTRA"
        echo "LVM extins cu noul PV $NEW_EXTRA. pvmove se va face la final la confirmare."
    fi
fi

# 9️⃣ Mount nou root si rsync
mkdir -p /mnt/newroot
mount "$NEW_ROOT" /mnt/newroot
mkdir -p /mnt/newroot/{dev,proc,sys,run,home,boot}
mount --bind /home /mnt/newroot/home || true

rsync -aAXHv --exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/mnt/*","/media/*","/lost+found"} / /mnt/newroot
for i in dev dev/pts proc sys run; do mount --bind /$i /mnt/newroot/$i; done

# 10️⃣ GRUB
if [ "$BOOT_MODE" = "UEFI" ] && [ -d /boot/efi ]; then
    mkdir -p /mnt/newroot/boot/efi
    mount "$NEW_EXTRA" /mnt/newroot/boot/efi
    rsync -aAXHv /boot/efi/ /mnt/newroot/boot/efi/
    chroot /mnt/newroot /bin/bash -c "grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian --recheck; update-grub"
else
    chroot /mnt/newroot /bin/bash -c "grub-install $NEW_DISK; update-grub"
fi

# 11️⃣ fstab
NEW_ROOT_UUID=$(blkid -s UUID -o value "$NEW_ROOT")
NEW_SWAP_UUID=$(blkid -s UUID -o value "$NEW_SWAP")
cat > /mnt/newroot/etc/fstab <<EOF
UUID=$NEW_ROOT_UUID  /      ext4   defaults  0 1
UUID=$NEW_SWAP_UUID  none   swap   sw        0 0
# /home ramane pe LVM (VG: $VG_NAME, LV: $LV_NAME)
EOF

# 12️⃣ Extindere LV /home si FS
lvextend -l +100%FREE "/dev/$VG_NAME/$LV_NAME" || true
FS_TYPE=$(blkid -s TYPE -o value "/dev/$VG_NAME/$LV_NAME" || true)
if [[ "$FS_TYPE" == "ext4" || -z "$FS_TYPE" ]]; then
    resize2fs "/dev/$VG_NAME/$LV_NAME" || true
elif [[ "$FS_TYPE" == "xfs" ]]; then
    if mountpoint -q /home; then
        xfs_growfs /home || true
    fi
fi

# 13️⃣ Cleanup
for i in run sys proc dev/pts dev; do umount /mnt/newroot/$i || true; done
umount /mnt/newroot/home || true
umount /mnt/newroot || true

echo
echo "✅ Migrare root + LVM pregatita!"
echo "1) Opreste serverul: sudo poweroff"
echo "2) Inlocuieste vechiul NVMe cu noul 512GB"
echo "3) Boot normal"

# 14️⃣ Optional: pvmove
read -rp "Vrei sa muti datele LVM /home de pe vechiul PV pe noul PV (pvmove)? (yes/no): " DO_PVMOVE
if [ "$DO_PVMOVE" = "yes" ]; then
    # detect PV vechi
    OLD_PV=""
    for pv in $(pvs --noheadings -o pv_name | awk '{print $1}'); do
        devpath=$(readlink -f "$pv")
        if [[ "$devpath" == $ROOT_DISK* ]]; then
            OLD_PV="$pv"
        fi
    done
    if [ -n "$OLD_PV" ]; then
        echo "Incep pvmove $OLD_PV -> $NEW_EXTRA ..."
        pvmove "$OLD_PV" "$NEW_EXTRA"
        vgreduce "$VG_NAME" "$OLD_PV" || true
        echo "pvmove complet."
    else
        echo "Nu am detectat PV vechi pe $ROOT_DISK. Sari peste pvmove."
    fi
else
    echo "Sari peste pvmove. Poti face manual mai tarziu."
fi

echo "✅ Script terminat."
