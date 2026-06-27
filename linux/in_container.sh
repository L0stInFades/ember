#!/bin/bash
# Builds RV32 MMU Linux (buildroot qemu_riscv32_virt) + OpenSBI fw_payload with embedded DTB.
# Idempotent: safe to re-run; skips finished stages. Copies via cat (macOS bind-mount safe).
set -e
export DEBIAN_FRONTEND=noninteractive
echo "=== [1/7] apt deps ==="
apt-get update -qq
apt-get install -y -qq sudo build-essential git wget cpio python3 bc bison flex \
    libssl-dev unzip rsync file gawk libncurses-dev device-tree-compiler \
    ca-certificates locales >/dev/null
export LC_ALL=C LANG=C

chmod 777 /out
useradd -m b 2>/dev/null || true
mkdir -p /build && chown -R b /build

echo "=== [2/7] clone buildroot ==="
sudo -u b bash -c '
set -e
cd /build
[ -d buildroot ] || git clone --depth 1 --branch 2024.02.9 https://github.com/buildroot/buildroot.git
cd buildroot
if [ ! -f output/images/Image ]; then
  echo "=== [3/7] defconfig qemu_riscv32_virt ==="
  make qemu_riscv32_virt_defconfig
  grep -q BR2_TARGET_ROOTFS_INITRAMFS=y .config || {
    echo "BR2_TARGET_ROOTFS_INITRAMFS=y" >> .config
    echo "BR2_TARGET_ROOTFS_CPIO=y"      >> .config
  }
  make olddefconfig
  echo "=== [4/7] build toolchain+kernel+rootfs (long) ==="
  make -j"$(nproc)"
else
  echo "=== [3-4/7] buildroot Image present, skipping ==="
fi
'

echo "=== [5/7] compile our DTB + copy kernel ==="
dtc -I dts -O dtb -o /out/device.dtb /out/device.dts
cat /build/buildroot/output/images/Image > /out/Image
cat /build/buildroot/output/images/vmlinux > /out/vmlinux 2>/dev/null || true

echo "=== [6/7] build OpenSBI fw_payload (embed kernel + dtb) ==="
PREFIX=$(ls /build/buildroot/output/host/bin/ | grep -E 'riscv32.*-linux-.*-gcc$' | head -1 | sed 's/gcc$//')
echo "toolchain prefix = $PREFIX"
sudo -u b bash -c "
set -e
cd /build
[ -d opensbi ] || git clone --depth 1 --branch v1.5.1 https://github.com/riscv-software-src/opensbi.git
cd opensbi
export PATH=/build/buildroot/output/host/bin:\$PATH
make PLATFORM=generic CROSS_COMPILE=$PREFIX PLATFORM_RISCV_XLEN=32 \
     FW_PAYLOAD=y FW_PAYLOAD_PATH=/out/Image FW_FDT_PATH=/out/device.dtb \
     -j\$(nproc)
"
cat /build/opensbi/build/platform/generic/firmware/fw_payload.bin > /out/fw_payload.bin
cat /build/opensbi/build/platform/generic/firmware/fw_payload.elf > /out/fw_payload.elf 2>/dev/null || true

echo "=== [7/7] done. artifacts in /out: ==="
ls -la /out
echo "BUILD_OK"
