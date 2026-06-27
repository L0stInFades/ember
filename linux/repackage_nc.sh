#!/bin/bash
set -e
export LC_ALL=C LANG=C PATH=/build/buildroot/output/host/bin:$PATH
PREFIX=riscv32-buildroot-linux-gnu-
KDIR=$(ls -d /build/buildroot/output/build/linux-*/ | head -1)
echo "=== compile 128MB DTB ==="
dtc -I dts -O dtb -o /out/device.dtb /out/device.dts
echo "=== repackage OpenSBI with uncompressed Image + 128MB DTB ==="
cd /build/opensbi
make PLATFORM=generic CROSS_COMPILE=$PREFIX PLATFORM_RISCV_XLEN=32 \
     FW_PAYLOAD=y FW_PAYLOAD_PATH=/out/Image_nc FW_FDT_PATH=/out/device.dtb \
     -j"$(nproc)" 2>&1 | tail -5
cat build/platform/generic/firmware/fw_payload.bin > /out/fw_payload_nc.bin
ls -la /out/fw_payload_nc.bin
echo "REPACK_OK"
