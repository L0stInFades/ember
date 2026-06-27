#!/bin/bash
set -e
export LC_ALL=C LANG=C PATH=/build/buildroot/output/host/bin:$PATH
PREFIX=riscv32-buildroot-linux-gnu-
echo "=== DTB ==="; dtc -I dts -O dtb -o /out/device.dtb /out/device.dts
echo "=== OpenSBI payload (soft-float Image + new DTB) ==="
cd /build/opensbi && make distclean >/dev/null 2>&1 || true
make PLATFORM=generic CROSS_COMPILE=$PREFIX PLATFORM_RISCV_XLEN=32 \
     FW_PAYLOAD=y FW_PAYLOAD_PATH=/out/Image_sf FW_FDT_PATH=/out/device.dtb \
     -j"$(nproc)" 2>&1 | tail -4
cat build/platform/generic/firmware/fw_payload.bin > /out/fw_payload_sf.bin
ls -la /out/fw_payload_sf.bin
echo "REPACK_SF_OK"
