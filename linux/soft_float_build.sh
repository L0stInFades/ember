#!/bin/bash
# Rebuild buildroot for SOFT-FLOAT (rv32imac / ilp32) so userspace uses no F/D
# instructions, plus an UNCOMPRESSED embedded initramfs (avoids the inflate path),
# then build OpenSBI fw_payload. Output: /out/fw_payload_sf.bin
set -e
export LC_ALL=C LANG=C
cd /build/buildroot

echo "=== kernel config fragment: uncompressed initramfs ==="
cat > /out/linux_nc.fragment <<'EOF'
CONFIG_INITRAMFS_COMPRESSION_NONE=y
# CONFIG_INITRAMFS_COMPRESSION_GZIP is not set
# CONFIG_RD_GZIP is not set
# CONFIG_DEBUG_VM_PGTABLE is not set
# CONFIG_DEBUG_VM is not set
EOF

echo "=== reconfigure: soft-float ilp32, custom rv32imac, keep initramfs ==="
# strip any prior variant/float/abi/fragment lines
sed -i -E '/^BR2_riscv_g/d;/^# BR2_riscv_g/d;/^BR2_riscv_custom/d;/^# BR2_riscv_custom/d;/^BR2_RISCV_ISA_RV[FDCMA]/d;/^# BR2_RISCV_ISA_RV[FDCMA]/d;/^BR2_RISCV_ABI/d;/^# BR2_RISCV_ABI/d;/^BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES/d' .config
cat >> .config <<'EOF'
# BR2_riscv_g is not set
BR2_riscv_custom=y
BR2_RISCV_ISA_RVM=y
BR2_RISCV_ISA_RVA=y
BR2_RISCV_ISA_RVC=y
# BR2_RISCV_ISA_RVF is not set
# BR2_RISCV_ISA_RVD is not set
BR2_RISCV_ABI_ILP32=y
BR2_TARGET_ROOTFS_INITRAMFS=y
BR2_TARGET_ROOTFS_CPIO=y
BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES="/out/linux_nc.fragment"
EOF
make olddefconfig
echo "--- effective riscv/abi config ---"
grep -E "BR2_RISCV_ABI|BR2_RISCV_ISA_RV[FDCMA]|BR2_riscv" .config || true
# hard fail if F/D still enabled
if grep -qE '^BR2_RISCV_ISA_RV[FD]=y' .config; then echo "ERROR: F/D still enabled"; exit 1; fi

echo "=== full clean rebuild (toolchain ABI changed) ==="
make clean
chown -R b /build 2>/dev/null || true
sudo -u b bash -c 'cd /build/buildroot && make -j"$(nproc)"'

echo "=== verify userspace ISA (expect no f/d) ==="
PREFIX=$(ls output/host/bin/ | grep -E 'riscv32.*-gcc$' | head -1 | sed 's/gcc$//')
output/host/bin/${PREFIX}readelf -A output/target/bin/busybox 2>/dev/null | grep Tag_RISCV_arch || true

echo "=== DTB + OpenSBI payload ==="
dtc -I dts -O dtb -o /out/device.dtb /out/device.dts
sudo -u b bash -c "
set -e
cd /build/opensbi && make distclean >/dev/null 2>&1 || true
export PATH=/build/buildroot/output/host/bin:\$PATH
make PLATFORM=generic CROSS_COMPILE=$PREFIX PLATFORM_RISCV_XLEN=32 \
     FW_PAYLOAD=y FW_PAYLOAD_PATH=/build/buildroot/output/images/Image FW_FDT_PATH=/out/device.dtb \
     -j\$(nproc)
"
cat output/images/Image > /out/Image_sf
cat output/build/linux-*/vmlinux > /out/vmlinux_sf 2>/dev/null || true
cat /build/opensbi/build/platform/generic/firmware/fw_payload.bin > /out/fw_payload_sf.bin
echo "=== sizes ==="; ls -la /out/Image_sf /out/fw_payload_sf.bin
echo "SOFTFLOAT_OK"
