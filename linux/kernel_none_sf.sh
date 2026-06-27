#!/bin/bash
# Rebuild ONLY the soft-float kernel with a truly UNCOMPRESSED (NONE) embedded
# initramfs (avoids bunzip2 + misaligned storm), then OpenSBI payload. Reuses toolchain.
set -e
export LC_ALL=C LANG=C PATH=/build/buildroot/output/host/bin:$PATH
PREFIX=riscv32-buildroot-linux-gnu-
KDIR=$(ls -d /build/buildroot/output/build/linux-*/ | head -1)
export BR_BINARIES_DIR=/build/buildroot/output/images
cd "$KDIR"
echo "=== force INITRAMFS_COMPRESSION = NONE ==="
for o in GZIP BZIP2 LZMA XZ LZO LZ4 ZSTD; do
  sed -i "s/^CONFIG_INITRAMFS_COMPRESSION_${o}=y/# CONFIG_INITRAMFS_COMPRESSION_${o} is not set/" .config
done
sed -i 's/^# CONFIG_INITRAMFS_COMPRESSION_NONE is not set/CONFIG_INITRAMFS_COMPRESSION_NONE=y/' .config
grep -q '^CONFIG_INITRAMFS_COMPRESSION_NONE=y' .config || echo 'CONFIG_INITRAMFS_COMPRESSION_NONE=y' >> .config
sed -i 's#^CONFIG_INITRAMFS_SOURCE=.*#CONFIG_INITRAMFS_SOURCE="/build/buildroot/output/images/rootfs.cpio"#' .config
make ARCH=riscv CROSS_COMPILE=$PREFIX olddefconfig
echo "--- effective ---"; grep -E "INITRAMFS_COMPRESSION_(NONE|BZIP2|GZIP)" .config
if ! grep -q '^CONFIG_INITRAMFS_COMPRESSION_NONE=y' .config; then echo "ERROR: NONE not set"; exit 1; fi
echo "=== build Image ==="
make ARCH=riscv CROSS_COMPILE=$PREFIX -j"$(nproc)" Image
ls -la arch/riscv/boot/Image
echo "=== DTB (100MHz) + OpenSBI payload ==="
dtc -I dts -O dtb -o /out/device.dtb /out/device.dts
cd /build/opensbi && make distclean >/dev/null 2>&1 || true
make PLATFORM=generic CROSS_COMPILE=$PREFIX PLATFORM_RISCV_XLEN=32 \
     FW_PAYLOAD=y FW_PAYLOAD_PATH="$KDIR/arch/riscv/boot/Image" FW_FDT_PATH=/out/device.dtb \
     -j"$(nproc)" 2>&1 | tail -3
cat "$KDIR/arch/riscv/boot/Image" > /out/Image_sf
cat "$KDIR/vmlinux" > /out/vmlinux_sf
cat build/platform/generic/firmware/fw_payload.bin > /out/fw_payload_sf.bin
echo "=== sizes ==="; ls -la /out/fw_payload_sf.bin /out/Image_sf
echo "KNONE_OK"
