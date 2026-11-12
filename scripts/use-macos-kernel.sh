#!/bin/bash
# 把 macOS CI 编出来的内核接进来：还原 loader 签名逻辑 → 重编 loader → 重打 payload。
#
#   ./scripts/use-macos-kernel.sh /path/to/mach.development.bcm2837
#
# 为什么要还原 loader：Linux 工具链的 fixup 语义不自洽，我们曾把 loader 的非 addrDiv
# 签名强制成修饰符 0；macOS 的 Apple clang 产生的 fixup 是标准 ABI，必须用原版逻辑
# （modifier = diversity）才对得上。
set -euo pipefail
ROOT=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
KERNEL=${1:?用法: use-macos-kernel.sh <kernel 路径>}
LOADER_SRC=/home/niu/project/dome/hakios-ref/base/xnuloader

[ -f "$KERNEL" ] || { echo "找不到内核: $KERNEL"; exit 1; }
echo "内核: $KERNEL ($(stat -c %s "$KERNEL") 字节)"

# 1. 还原 loader 的签名逻辑
if grep -q "modifier = 0;" "$LOADER_SRC/loader.c"; then
	echo "→ 还原 loader.c 的 modifier"
	python3 - "$LOADER_SRC/loader.c" <<'PY'
import sys
p=sys.argv[1]
s=open(p,encoding='utf-8').read()
import re
s2=re.sub(r'/\*\n\s*\*\s*redwood/miro: this toolchain emits.*?\*/\n(\s*)modifier = 0;',
          r'\1modifier = diversity;', s, flags=re.S)
if s2==s:
    s2=s.replace('modifier = 0;','modifier = diversity;',1)
open(p,'w',encoding='utf-8').write(s2)
print('   done')
PY
else
	echo "→ loader 已是原版逻辑"
fi

# 2. 重编 loader
echo "→ 编译 loader"
( cd "$LOADER_SRC" && ./build.sh >/dev/null 2>&1 ) && echo "   ok: $(stat -c %s "$LOADER_SRC/loader.efi") 字节"
cp "$LOADER_SRC/loader.efi" "$ROOT/out/loader-miro.efi"

# 3. 重打 payload
# 3. 重打 payload
#    根盘默认用 root-smoke2.apfs：它比 v1 多了 /dev 等空目录。
#    根盘是只读 APFS，内核里 mkdir("/dev") 不可能成功，所以 /dev 必须在镜像里。
#    重新生成：./scripts/mkroot-image.sh [full]
echo "→ 打包 payload"
python3 /home/niu/project/dome/hakios-ref/base/xnuloader/mkpayload.py \
	-o "$ROOT/out/payload-kernel-arm64e-rd.bin" \
	kernel="$KERNEL" loader.efi="$ROOT/out/loader-miro.efi" \
	ramdisk="${ROOTIMAGE:-$ROOT/out/root-smoke2.apfs}" --usb
cp "$KERNEL" "$ROOT/out/mach.development.bcm2837.arm64e.macos"

echo
echo "完成。上机命令："
echo "  cd $ROOT && ./scripts/offline-boot-test.sh --rd --only arm64e"
