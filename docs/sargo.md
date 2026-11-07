# Google Pixel 3a (`sargo`, SDM670)

iOS 16.7.16 (iPhone X userland) on a Pixel 3a, through the same XNU + `fastboot boot` shim approach as the Redmi Note 10 Pro. Experimental bring-up; **it installs into `userdata` and erases Android/postmarketOS user data.**

## Status (2026-11-07)

| Area | State |
| --- | --- |
| Boot | ABL -> `fastboot boot` shim -> XNU (nothing flashed to boot partitions) |
| Storage | Qualcomm sdhci-msm v5 eMMC driver inside XNU (`xnu/patches/0082`), GPT lookup of `userdata`, ADMA2 reads/writes |
| Root | 16 GiB HFSX (case-sensitive HFS+) image built from the IPSW, mounted read/write |
| Userland | launchd, daemons, backboardd and SpringBoard run; the iOS lock screen is shown (2026-11-07) |
| Display | Bootloader framebuffer, CPU rendering (no Adreno driver) |
| SMP | `cpus=8` boots; core count not yet confirmed on screen |
| Touch | Synaptics RMI4 on GENI SE9 (patches 0088-0094); the SDM670 TLMM is tiled (NORTH 0x3900000, WEST 0x3500000) |
| Not done | OLED command-mode refresh, buttons, battery, Wi-Fi/BT/audio/camera, GPU; the UI is slow (CPU rendering, debug output) |

## Hardware notes

- Stock SDM670 DTBs from the phone's own boot image are required by the bootloader (a mainline DTB is refused with "Invalid Parameter").
- Image format the Pixel ABL accepts: boot header v2, 4 KiB pages, **LZ4-frame** kernel, AVB footer. `tools/mkboot-sargo.py` copies header, DTBs and the AVB block from a template (TWRP's sargo image works) and replaces kernel and ramdisk.
- The device tree seen by XNU is built by `tools/mkadt.py --sargo`. The CPU nodes must be `qcom,kryo470` (the name SweetCPU matches); with `qcom,kryo360` XNU stalls in `ml_wait_max_cpus` before `bsd_init`.
- Pixel userdata is eMMC, not UFS: `shim/emmc.c` (bootloader-side probe) and `xnu/patches/0082` (kernel driver) replace the UFS path.

## Build and boot

1. Kernel: push to a fork and run the `xnu` GitHub Actions workflow (macOS runner); patches in `xnu/patches/` are applied in order.
2. ADT: `python3 -I tools/mkadt.py shim/out/sargo.adt --sargo`
3. Payload: `python3 -I tools/mkpayload.py kernel.development.sweet shim/out/sargo.adt shim/out/payload-sargo.bin --cmdline "debug=0xc serial=3 cpus=1 keepsyms=1 -enable_kprintf_spam -noprogress rd=ufsroot0 ufsroot=userdata ufsrw=1 rootrw=1 unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin launchd_unsecure_cache=1 wdt=-1 sweetfb_hz=30"`
4. Image: `cd shim && SARGO_OUT=out/sargo-xnu.img ./build-sargo.sh out/payload-sargo.bin`
5. Boot: `fastboot boot shim/out/sargo-xnu.img`. Keep `ufsrw=1 rootrw=1`: in my runs a read-only root reached launchd, which then exited and panicked.

## Device tree: the /product node

`tools/mkadt.py` copies `/product` from the real iPhone X (D22AP) device tree. Without it SpringBoard aborts with `Failed to load bounding path bitmap data ... BoundingPathBitmap-1125x2436-375x812-3.00x`, because MobileGestalt has no `artwork-device-subtype`. Extract it from the IPSW (kept out of git):

```
ipsw img4 im4p extract DeviceTree.d22ap.im4p -o research/ipsw-x/d22ap.adt
```

then re-run `mkadt.py ... --sargo`. Only the boot image changes; no reflash.

## Root image

`tools/mkiosroot.sh` builds the HFSX image from the IPSW dmgs (needs apfs-fuse, mkfs.hfsplus, rsync). Two sargo-specific steps:

- **The image starts 1 MiB into `userdata`.** The first ~17 KB of the partition are rewritten with a stale GPT on every boot (cause unknown); `xnu/patches/0087` skips the first MiB.
- **Run `tools/sweet-root-tweaks.py`** on the mounted image (loop mount with `-o force`, as root). Without it the first boot sits in the data migration for about an hour. The activation data ark is only seeded when its container exists, so re-run after the first boot.
- **Clear the journaled bit** in the volume header (attributes at offset 4 of the header at image offset 1024: `00 00 21 00` -> `00 00 01 00`). XNU cannot create a journal on a read-only root and the mount fails otherwise.

## Writing userdata

`fastboot flash userdata` printed OKAY on this ABL but wrote nothing. Use TWRP instead:

```
fastboot boot twrp-3.7.1_12-1-sargo.img
adb exec-in 'dd of=/dev/block/mmcblk0p72 bs=1M seek=1 conv=fsync' < ios16-root.img
```

Verify after `adb reboot bootloader` and re-entering TWRP: reads straight after the write can come from the page cache and look correct while the media is not.

## Debugging

The console is a circular framebuffer buffer (newest text wraps to the top; the red bar is the cursor). A webcam works for reading it: set manual exposure (V4L2 `exposure_auto=1`) or the screen is blown out.
