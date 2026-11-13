#!/usr/bin/env bash
#
# Undo install.sh: remove PAM hooks, services, DKMS module and AUR packages.
#
set -euo pipefail

SPI_PKG="focaltech-spi-dkms"
LIB_PKG="libfprint-ftexx00"
PAM_SERVICES=(sudo lightdm gdm sddm cinnamon-screensaver)

msg()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }

[ "$(id -u)" -ne 0 ] || { echo "run as your normal user" >&2; exit 1; }

msg "Caching sudo credentials"
sudo -v

msg "Restoring PAM configuration"
for svc in "${PAM_SERVICES[@]}"; do
    f="/etc/pam.d/$svc"
    [ -f "$f" ] || continue
    if [ -f "$f.bak-fprint" ]; then
        sudo cp "$f.bak-fprint" "$f"
        sudo rm -f "$f.bak-fprint"
        echo "    restored $svc"
    elif grep -q 'pam_fprintd\.so' "$f"; then
        sudo sed -i '/pam_fprintd\.so/d' "$f"
        echo "    removed pam_fprintd from $svc"
    fi
done

msg "Stopping and removing services"
sudo systemctl disable --now focal-gpio.service >/dev/null 2>&1 || true
sudo rm -f /etc/systemd/system/focal-gpio.service
sudo rm -f /etc/modules-load.d/focal_spi.conf
sudo systemctl daemon-reload

msg "Unloading module"
sudo modprobe -r focal_spi >/dev/null 2>&1 || true

msg "Removing DKMS module"
sudo dkms remove "${SPI_PKG}/$(dkms status "$SPI_PKG" 2>/dev/null | head -n1 | sed -E 's|^[^/]+/([^,]+),.*|\1|')" --all >/dev/null 2>&1 || true

msg "Removing packages"
sudo pacman -R --noconfirm fprintd "$LIB_PKG" "$SPI_PKG" 2>/dev/null || true

msg "Reinstalling stock libfprint/fprintd"
sudo pacman -S --needed --noconfirm libfprint fprintd 2>/dev/null || warn "could not reinstall stock packages"

msg "Cleaning IgnorePkg entries"
for p in "$SPI_PKG" "$LIB_PKG"; do
    sudo sed -i -E "s|[[:space:]]${p}([[:space:]]|$)| |g" /etc/pacman.conf
done
sudo sed -i -E 's|^(IgnorePkg[[:space:]]*=[[:space:]]*)$|#IgnorePkg   =|' /etc/pacman.conf

msg "Restarting fprintd"
sudo systemctl restart fprintd 2>/dev/null || true

cat <<'EOF'

Removed. Your enrolled prints may still live in /var/lib/fprintd (root only);
delete that directory if you want them gone.

EOF
