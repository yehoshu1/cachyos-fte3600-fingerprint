# FocalTech FTE3600 fingerprint sensor on Arch / CachyOS

Getting the **FocalTech FTE3600 (FT9361)** SPI fingerprint reader working on Linux:
driver, reset-line workaround, `fprintd` enrollment, and PAM login.

Tested on:

| | |
|---|---|
| Distro | CachyOS (Arch-based) |
| Kernel | 7.3.3-1-cachyos, 6.18.60-2-cachyos-lts |
| CPU | Intel Raptor Lake-P |
| Desktop | Cinnamon (X11) |
| Sensor | `ACPI\FTE3600` on Intel PCH SPI |

## TL;DR

```bash
git clone https://github.com/yehoshu1/cachyos-fte3600-fingerprint.git
cd cachyos-fte3600-fingerprint
./install.sh
fprintd-enroll -f right-index-finger   # touch the sensor ~6-12 times
sudo -k && sudo -v                      # test: touch instead of typing
```

## Why this is not plug-and-play

The sensor is **not USB** — `lsusb` will never show it. It sits on the Intel
PCH SPI controller:

```
$ ls /sys/bus/acpi/devices/ | grep FTE
FTE3600:00
$ cat /sys/bus/spi/devices/spi-FTE3600:00/modalias
acpi:FTE3600:FTE3600:
```

Three separate problems have to be solved:

1. **No in-tree driver.** The kernel enumerates the ACPI device but binds
   nothing to it. An out-of-tree SPI module is required
   (`focaltech-spi-dkms`).
2. **The ACPI firmware does not expose the reset GPIO** the stock driver asks
   for, so probe fails with:

   ```
   focalfp-spi spi-FTE3600:00: Failed to get power GPIO 0: -2
   probe with driver focalfp-spi failed with error -2
   ```

   The fix is twofold: make the driver tolerate a missing reset line, and
   hold that line high from userspace.
3. **`libfprint` has no upstream driver.** A patched `libfprint` build
   (`libfprint-ftexx00`, proprietary blob) is needed for `fprintd`.

If the reset line is low when `fprintd` opens the device you get:

```
failed to claim device: ... Open failed with error: init sensor error!
```

## How it works

```
ACPI FTE3600:00
      |
      +-- SPI (Intel pxa2xx-spi) --> focal_spi.ko --> /dev/focal_moh_spi
      |                                                    |
      |                                              libfprint-ftexx00
      |                                                    |
      +-- GPIO 305 (reset) -- held HIGH by  -----------> fprintd
          focal-gpio.service
```

* `focal_spi.ko` is patched to continue when the ACPI GPIO lookup fails.
* `focal-gpio.service` runs `gpioset gpiochip0 305=1` for the lifetime of the
  boot, keeping the sensor out of reset.
* `fprintd` (via the patched libfprint) then talks to `/dev/focal_moh_spi`.

### Finding the right GPIO line

On this machine the ACPI `_CRS` for the sensor contains a `GpioInt` (line 306,
used as IRQ) and a `GpioIo` (line 305, reset). The reset line is the `GpioIo`
pin listed in the same resource template:

```bash
sudo cat /sys/kernel/debug/gpio | grep FPNT   # shows the GpioInt line
sudo gpioinfo -c gpiochip0 | grep 'line 30[0-9]'
```

If your pin numbers differ, override them:

```bash
GPIO_CHIP=gpiochip0 GPIO_LINE=305 ./install.sh
```

## Install

### Requirements

* Arch-based distro with `yay`
* Kernel headers matching the running kernel (`linux-cachyos-headers`,
  `linux-headers`, ...)
* `sudo`

### Manual steps (what the script does)

```bash
# 1. out-of-tree SPI module + patched libfprint
yay -S focaltech-spi-dkms libfprint-ftexx00

# 2. daemon (the patched libfprint provides libfprint-2.so)
sudo pacman -S --assume-installed 'libfprint-2.so=2-64' fprintd

# 3. patch the module so a missing reset GPIO is not fatal
sudoedit /usr/src/focaltech-spi-dkms-1.0.3/focal_spi.c
#   in focal_spi_get_gpio_config(): treat -ENOENT as "no GPIO" and return 0
sudo dkms remove focaltech-spi-dkms/1.0.3 --all
sudo dkms install  focaltech-spi-dkms/1.0.3

# 4. autoload + hold the reset line high
echo focal_spi | sudo tee /etc/modules-load.d/focal_spi.conf
sudo install -m644 files/focal-gpio.service /etc/systemd/system/
sudo systemctl enable --now focal-gpio.service

# 5. restart the daemon
sudo systemctl restart fprintd
```

## Enroll and test

```bash
fprintd-list "$USER"                  # should show the FocalTech device
fprintd-enroll -f right-index-finger  # touch repeatedly until enroll-completed
fprintd-verify -f right-index-finger  # expect verify-match
```

PAM hooks are added for `sudo`, the display manager and the screensaver so the
fingerprint is tried first, then the password after a 10 second timeout:

```
auth       sufficient   pam_fprintd.so timeout=10
```

Backups are written next to each edited file as `<service>.bak-fprint`.

At the greeter you may have to select your user / press Enter once so the PAM
conversation starts; the sensor has no visible prompt.

## Troubleshooting

**`init sensor error!`**
The reset line is not high. Check the service and the line:

```bash
systemctl status focal-gpio.service
sudo gpioinfo -c gpiochip0 | grep 'line 305'
sudo journalctl -k | grep -i focal
```

**`Failed to get power GPIO 0: -2`**
The source patch is missing (usually after a package update rebuilt
`focal_spi.c`). Re-run `./install.sh`; `IgnorePkg` is set to prevent this.

**Probe works but `fprintd` times out**
Check the reset line state first (`sudo gpioinfo`). If it is held, the upstream
repo also ships an alternative driver (`alt/focal_spi.c`) that configures the
SPI bus explicitly (mode 0, 1 MHz) and treats GPIOs as optional:

```bash
git clone https://github.com/vobademi/FTEXX00-Ubuntu
sudo cp FTEXX00-Ubuntu/alt/focal_spi.c /usr/src/focaltech-spi-dkms-*/focal_spi.c
sudo dkms remove focaltech-spi-dkms/<ver> --all
sudo dkms install  focaltech-spi-dkms/<ver>
```

On the board this repo was written for, the alternative driver fails earlier
(`init sensor error!`); the patched original plus the held reset line is the
combination that works.

**Sensor stops after suspend**

```bash
sudo systemctl restart fprintd
```

**Fingerprint prompt blocks scripts**
Remove the PAM line from `/etc/pam.d/sudo` (or restore
`/etc/pam.d/sudo.bak-fprint`).

**GUI password dialogs (polkit)**
Deliberately left on password auth; adding `pam_fprintd` there makes every
polkit prompt wait for a finger with no visible cue.

## Uninstall

```bash
./uninstall.sh
```

Removes the PAM lines, the GPIO service, the module autoload file, the DKMS
module and the AUR packages, then reinstalls stock `libfprint`/`fprintd`.

## Notes / caveats

* `libfprint-ftexx00` is a **proprietary** blob and conflicts with the repo
  `libfprint`. The SPI module itself is GPL-2.0.
* `IgnorePkg = focaltech-spi-dkms libfprint-ftexx00` is added to
  `/etc/pacman.conf` so a system update does not silently undo the patch.
* The setup is board-specific: it assumes the reset GPIO is line 305 on
  `gpiochip0`. Change `GPIO_LINE` if your ACPI tables differ.
* This repository documents a working configuration, not an upstream fix.

## License

Scripts and documentation: MIT. The kernel module and libfprint blob belong to
their respective upstreams.
