#!/bin/bash
# Rebuild kernel Image with an UNCOMPRESSED embedded initramfs (bypass gzip inflate),
# then repackage OpenSBI fw_payload with our DTB.
set -e
export LC_ALL=C LANG=C PATH=/build/buildroot/output/host/bin:$PATH
PREFIX=riscv32-buildroot-linux-gnu-
KDIR=$(ls -d /build/buildroot/output/build/linux-*/ | head -1)
echo "KDIR=$KDIR"
cd "$KDIR"

echo "=== set INITRAMFS compression = NONE ==="
export BR_BINARIES_DIR=/build/buildroot/output/images
sed -i 's/^CONFIG_INITRAMFS_COMPRESSION_GZIP=y/# CONFIG_INITRAMFS_COMPRESSION_GZIP is not set/' .config
grep -q '^CONFIG_INITRAMFS_COMPRESSION_NONE=y' .config || echo 'CONFIG_INITRAMFS_COMPRESSION_NONE=y' >> .config
sed -i 's#^CONFIG_INITRAMFS_SOURCE=.*#CONFIG_INITRAMFS_SOURCE="/build/buildroot/output/images/rootfs.cpio"#' .config
make ARCH=riscv CROSS_COMPILE=$PREFIX olddefconfig
sed -i 's#^CONFIG_INITRAMFS_SOURCE=.*#CONFIG_INITRAMFS_SOURCE="/build/buildroot/output/images/rootfs.cpio"#' .config
grep -E "INITRAMFS_COMPRESSION" .config || true

echo "=== rebuild Image ==="
make ARCH=riscv CROSS_COMPILE=$PREFIX -j"$(nproc)" Image
ls -la arch/riscv/boot/Image

echo "=== compile our DTB ==="
dtc -I dts -O dtb -o /out/device.dtb /out/device.dts

echo "=== repackage OpenSBI fw_payload ==="
cd /build/opensbi
make PLATFORM=generic CROSS_COMPILE=$PREFIX PLATFORM_RISCV_XLEN=32 \
     FW_PAYLOAD=y FW_PAYLOAD_PATH="$KDIR/arch/riscv/boot/Image" FW_FDT_PATH=/out/device.dtb \
     -j"$(nproc)"
cat build/platform/generic/firmware/fw_payload.bin > /out/fw_payload_nc.bin
cat "$KDIR/arch/riscv/boot/Image" > /out/Image_nc
echo "=== sizes ==="; ls -la /out/fw_payload_nc.bin /out/Image_nc
echo "REBUILD_OK"
