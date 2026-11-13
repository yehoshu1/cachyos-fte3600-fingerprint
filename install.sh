#!/usr/bin/env bash
#
# Install support for the FocalTech FTE3600 (FT9361) SPI fingerprint sensor
# on Arch-based systems.
#
# - builds the out-of-tree focal_spi module (AUR)
# - patches it to tolerate the missing ACPI reset GPIO
# - holds the reset line high with a systemd service
# - installs the patched libfprint + fprintd
# - hooks fingerprint auth into PAM (sudo, display manager, screen lock)
#
# Run as your normal user; the script calls sudo itself.
#
set -euo pipefail

GPIO_CHIP="${GPIO_CHIP:-gpiochip0}"
GPIO_LINE="${GPIO_LINE:-305}"
SPI_PKG="focaltech-spi-dkms"
LIB_PKG="libfprint-ftexx00"
PAM_TIMEOUT="${PAM_TIMEOUT:-10}"
PAM_SERVICES=(sudo lightdm gdm sddm cinnamon-screensaver)
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

msg()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# sanity checks
# ---------------------------------------------------------------------------
[ "$(id -u)" -ne 0 ] || die "run this as your normal user, not as root"

command -v yay  >/dev/null || die "yay is required (AUR helper)"
command -v sudo >/dev/null || die "sudo is required"
command -v python3 >/dev/null || die "python3 is required"

if ! compgen -G '/sys/bus/acpi/devices/FTE3600:*' >/dev/null; then
    die "no ACPI FTE3600 device found; this guide does not apply to this machine"
fi

if [ ! -d "/lib/modules/$(uname -r)/build" ]; then
    die "kernel headers missing for $(uname -r); install the matching *-headers package"
fi

msg "Caching sudo credentials"
sudo -v

# ---------------------------------------------------------------------------
# packages
# ---------------------------------------------------------------------------
msg "Installing $SPI_PKG and $LIB_PKG from the AUR"
yay -S --needed --noconfirm "$SPI_PKG" "$LIB_PKG"

msg "Installing fprintd"
# the AUR package provides libfprint-2.so but not the versioned soname
sudo pacman -S --needed --noconfirm --assume-installed 'libfprint-2.so=2-64' fprintd

msg "Installing libgpiod (used to hold the reset line)"
sudo pacman -S --needed --noconfirm libgpiod

# ---------------------------------------------------------------------------
# patch the module: a missing reset GPIO must not abort probe
# ---------------------------------------------------------------------------
msg "Patching focal_spi.c (tolerate missing reset GPIO)"
SRC="$(compgen -G "/usr/src/${SPI_PKG}-*/focal_spi.c" | head -n1 || true)"
[ -n "$SRC" ] || die "could not find /usr/src/${SPI_PKG}-*/focal_spi.c"

sudo python3 - "$SRC" <<'PY'
import pathlib, sys

path = pathlib.Path(sys.argv[1])
src = path.read_text()

old = '''\tgpiod = devm_gpiod_get_index(dev, NULL, 0, GPIOD_OUT_LOW);
\tif (IS_ERR(gpiod)) {
\t\terror = PTR_ERR(gpiod);
\t\tif (error != -EPROBE_DEFER)
\t\t\tdev_err(dev,"Failed to get power GPIO 0: %d\\n",error);
\t\treturn error;
\t}'''

new = '''\tgpiod = devm_gpiod_get_index(dev, NULL, 0, GPIOD_OUT_LOW);
\tif (IS_ERR(gpiod)) {
\t\terror = PTR_ERR(gpiod);
\t\tif (error == -ENOENT) {
\t\t\t/* Some ACPI tables do not describe the reset line. */
\t\t\tdev_warn(dev, "No reset GPIO in ACPI, continuing without it\\n");
\t\t\tdata->gpiod_rst = NULL;
\t\t\treturn 0;
\t\t}
\t\tif (error != -EPROBE_DEFER)
\t\t\tdev_err(dev,"Failed to get power GPIO 0: %d\\n",error);
\t\treturn error;
\t}'''

if "No reset GPIO in ACPI" in src:
    print("already patched")
elif old in src:
    path.write_text(src.replace(old, new))
    print("patched")
else:
    print("warning: upstream source changed, patch not applied", file=sys.stderr)
PY

# ---------------------------------------------------------------------------
# rebuild DKMS for every installed kernel with headers
# ---------------------------------------------------------------------------
msg "Rebuilding the DKMS module"
PKG_VER="$(dkms status "$SPI_PKG" 2>/dev/null | head -n1 | sed -E 's|^[^/]+/([^,]+),.*|\1|')"
[ -n "$PKG_VER" ] || die "could not determine DKMS package version"

sudo dkms remove "${SPI_PKG}/${PKG_VER}" --all >/dev/null 2>&1 || true
sudo dkms install "${SPI_PKG}/${PKG_VER}"

for kdir in /lib/modules/*; do
    k="$(basename "$kdir")"
    [ "$k" = "$(uname -r)" ] && continue
    [ -d "$kdir/build" ] || continue
    msg "Building for additional kernel $k"
    sudo dkms install "${SPI_PKG}/${PKG_VER}" -k "$k" || warn "build failed for $k"
done

# ---------------------------------------------------------------------------
# autoload + reset line
# ---------------------------------------------------------------------------
msg "Installing module autoload entry"
sudo install -Dm644 "$HERE/files/modules-load.conf" /etc/modules-load.d/focal_spi.conf

msg "Installing reset-line service (${GPIO_CHIP} line ${GPIO_LINE})"
sudo install -Dm644 "$HERE/files/focal-gpio.service" /etc/systemd/system/focal-gpio.service
sudo sed -i "s|@GPIO_CHIP@|${GPIO_CHIP}|g; s|@GPIO_LINE@|${GPIO_LINE}|g" \
    /etc/systemd/system/focal-gpio.service
sudo systemctl daemon-reload
sudo systemctl enable focal-gpio.service
sudo systemctl restart focal-gpio.service

msg "Loading the module"
sudo modprobe -r focal_spi >/dev/null 2>&1 || true
sudo modprobe focal_spi

if ! systemctl is-active --quiet focal-gpio.service; then
    die "focal-gpio.service is not running; check: journalctl -u focal-gpio.service"
fi

# ---------------------------------------------------------------------------
# PAM
# ---------------------------------------------------------------------------
msg "Configuring PAM (fingerprint first, password fallback)"
for svc in "${PAM_SERVICES[@]}"; do
    f="/etc/pam.d/$svc"
    if [ ! -f "$f" ]; then
        warn "skipping $svc (no $f)"
        continue
    fi
    if grep -q 'pam_fprintd\.so' "$f"; then
        echo "    $svc already configured"
        continue
    fi
    sudo cp -n "$f" "$f.bak-fprint"
    sudo sed -i "1a auth       sufficient   pam_fprintd.so timeout=${PAM_TIMEOUT}" "$f"
    echo "    patched $svc"
done

# ---------------------------------------------------------------------------
# protect the AUR packages from being clobbered by updates
# ---------------------------------------------------------------------------
msg "Adding IgnorePkg entries"
if grep -q '^IgnorePkg' /etc/pacman.conf; then
    for p in "$SPI_PKG" "$LIB_PKG"; do
        if ! grep -qE "^IgnorePkg.*[[:space:]]${p}([[:space:]]|$)" /etc/pacman.conf; then
            sudo sed -i -E "s|^(IgnorePkg.*)$|\1 ${p}|" /etc/pacman.conf
        fi
    done
else
    sudo sed -i "s|^#IgnorePkg   =.*$|IgnorePkg   = ${SPI_PKG} ${LIB_PKG}|" /etc/pacman.conf
fi

msg "Restarting fprintd"
sudo systemctl restart fprintd

# ---------------------------------------------------------------------------
cat <<EOF

Done.

Next steps:
  1. fprintd-list "\$USER"                     # device should be listed
  2. fprintd-enroll -f right-index-finger      # touch the sensor ~6-12 times
  3. fprintd-verify -f right-index-finger      # expect: verify-match
  4. sudo -k && sudo -v                        # touch instead of typing

If enrollment fails with "init sensor error!", the reset line is not held:
  systemctl status focal-gpio.service
  sudo gpioinfo -c ${GPIO_CHIP} | grep 'line ${GPIO_LINE}'

EOF
