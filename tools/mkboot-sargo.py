#!/usr/bin/env python3
"""Pack a Pixel 3a boot image from a template image the bootloader accepts.

The template (a v2 image such as TWRP's, or the phone's stock boot.img) supplies the
header, the DTB section (Google's downstream SDM670 DTBs: the bootloader picks one by
qcom,msm-id/board-id, a mainline DTB without those is refused with "Invalid Parameter")
and the AVB vbmeta block + footer (required; the hash no longer matches our contents,
which an unlocked bootloader tolerates). Only the kernel and ramdisk are replaced.

usage: mkboot-sargo.py Image out.img [payload.bin]
env:   SARGO_TEMPLATE  v2 boot image to copy header/DTBs/AVB from
                       (default ~/hackios/twrp/twrp-3.7.1_12-1-sargo.img)
       SARGO_KERNEL    lz4 (default) | gzip | raw
"""
import gzip, hashlib, os, struct, subprocess, sys

tpl_path = os.environ.get("SARGO_TEMPLATE", os.path.expanduser("~/hackios/twrp/twrp-3.7.1_12-1-sargo.img"))
image, out = sys.argv[1], sys.argv[2]
payload = sys.argv[3] if len(sys.argv) > 3 else None

d = open(tpl_path, "rb").read()
assert d[:8] == b"ANDROID!"
ksz, kaddr, rsz, raddr, ssz, saddr, tags, page, hv = struct.unpack("<9I", d[8:44])
assert hv == 2 and page == 4096 and ssz == 0, "template must be a v2 boot image with 4K pages"
dtb_size = struct.unpack("<I", d[1648:1652])[0]


def pad(b):
    return b + b"\0" * (-len(b) % page)


# DTB section sits after kernel and ramdisk (no second stage, no recovery dtbo)
dtb_off = page + len(pad(b"x" * ksz)) + len(pad(b"x" * rsz))
dtb = d[dtb_off:dtb_off + dtb_size]
assert dtb[:4] == b"\xd0\x0d\xfe\xed", "DTB section not where expected"

img = open(image, "rb").read()
# The Pixel bootloader takes an LZ4 frame kernel (like TWRP's); gzip is "Invalid Parameter",
# an uncompressed Image is "Unsupported".
comp = os.environ.get("SARGO_KERNEL", "lz4")
if comp == "raw":
    kernel = img
elif comp == "gzip":
    kernel = gzip.compress(img, 9, mtime=0)
else:
    kernel = subprocess.run(["lz4", "-9", "-B7", "-c", "-q"], input=img,
                            stdout=subprocess.PIPE, check=True).stdout
if payload:
    ramdisk = open(payload, "rb").read()
else:  # ABL dislikes a zero-size ramdisk: minimal gzip'd newc cpio (just the trailer)
    trailer = b"070701" + b"00000000" * 13 + b"0000000B" + b"00000000" + b"TRAILER!!!\0"
    trailer += b"\0" * (-len(trailer) % 4)
    ramdisk = gzip.compress(trailer, 9, mtime=0)

h = bytearray(d[:page])
struct.pack_into("<I", h, 8, len(kernel))
struct.pack_into("<I", h, 16, len(ramdisk))
h[64:64 + 512] = b"console=null".ljust(512, b"\0")
h[608:1632] = b"\0" * 1024  # drop the template's extra cmdline
sha = hashlib.sha1(kernel + struct.pack("<I", len(kernel)) + ramdisk + struct.pack("<I", len(ramdisk))
                   + struct.pack("<I", 0) + struct.pack("<I", 0) + dtb + struct.pack("<I", len(dtb))).digest()
h[576:608] = sha.ljust(32, b"\0")

img_out = bytes(h) + pad(kernel) + pad(ramdisk) + pad(dtb)
foot = d[-64:]
assert foot[:4] == b"AVBf", "template has no AVB footer"
vb_off = struct.unpack(">Q", foot[20:28])[0]
assert len(img_out) <= vb_off, "image does not fit before the vbmeta block"
open(out, "wb").write(img_out.ljust(vb_off, b"\0") + d[vb_off:])
print(f"wrote {out}: kernel {len(kernel)}, ramdisk {len(ramdisk)}, dtb section {len(dtb)}")
