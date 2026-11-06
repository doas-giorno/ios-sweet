#!/bin/bash
# Pixel 3a (sargo, SDM670) shim build. clang+lld instead of aarch64-linux-gnu-gcc,
# and no mkbootimg: the image reuses the header and appended DTB of the phone's
# own boot image (tools/mkboot-sargo.py).
#   usage: build-sargo.sh [payload.bin]   -> out/sargo-boot.img
set -euo pipefail
cd "$(dirname "$0")"
LLVM=${LLVM:-/usr/lib/llvm/22/bin}
CC="$LLVM/clang --target=aarch64-linux-gnu"
CFLAGS="-DSARGO -O2 -ffreestanding -nostdlib -fno-pic -mgeneral-regs-only -mstrict-align -fno-stack-protector -fno-jump-tables -Wall -Wextra"
SRC="start.S shim.c console.c mmu.c fdt.c loader.c emmc.c"	# emmc.c instead of ufs.c: the 3a has eMMC
mkdir -p out/sargo
objs=
for f in $SRC; do
	$CC $CFLAGS -c $f -o out/sargo/${f%.*}.o
	objs="$objs out/sargo/${f%.*}.o"
done
abs=$($LLVM/llvm-readelf -r ${objs/out\/sargo\/start.o/} | grep -c ABS64 || true)
[ "$abs" = 0 ] || { echo "error: $abs absolute relocations in C objects" >&2; exit 1; }
$CC $CFLAGS -fuse-ld=lld -static -T shim.ld -Wl,--build-id=none -Wl,-N $objs -o out/sargo/shim.elf
$LLVM/llvm-objcopy -O binary out/sargo/shim.elf out/sargo/Image
size=$($LLVM/llvm-nm out/sargo/shim.elf | awk '$3=="_end"{print strtonum("0x"$1)}')
truncate -s "$size" out/sargo/Image
python3 -I ../tools/mkboot-sargo.py out/sargo/Image out/sargo-boot.img ${1:+"$1"}
ls -l out/sargo/Image out/sargo-boot.img
