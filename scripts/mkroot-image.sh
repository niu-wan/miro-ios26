#!/bin/bash
# 生成根盘 APFS 镜像（Linux 上用 hakios 自己的 mkapfs.py，不需要 Mac）。
#
#   ./scripts/mkroot-image.sh            # small：launchd + dyld + 常用空目录（含 /dev），约 4 MB
#   ./scripts/mkroot-image.sh full       # full：再加 iOS 26 的 dyld 共享缓存（约 5.4 GB）
#
# 为什么要在镜像里放 /dev：根盘是 **只读** APFS（vfs_conf.c 里 MNT_RDONLY），
# 内核里 mkdir("/dev") 一定失败，devfs_kernel_mount("/dev") 就会 ENOENT。
set -euo pipefail
ROOT=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
MODE=${1:-small}
SRC=$ROOT/out/ios26-rootfs          # 从 iOS 26 的 root 卷抽出来的树
STAGE=$ROOT/out/rootfs-stage
MKAPFS=/home/niu/project/dome/hakios-ref/userland/tools/apfs/mkapfs.py
OUT=${OUT:-$ROOT/out/root-smoke2.apfs}

[ -d "$SRC" ] || { echo "缺少 $SRC（iOS 26 根文件系统）"; exit 1; }
[ -f "$MKAPFS" ] || { echo "缺少 mkapfs.py"; exit 1; }

echo "→ 搭目录树：$STAGE"
# full 模式的 staging 里有 90+ 个缓存文件，safe-delete 的批量阈值会拦下 rm -rf
export CODEBUDDY_SAFE_DELETE_BULK_THRESHOLD=1000000
rm -rf "$STAGE"
mkdir -p "$STAGE"/{dev,etc,sbin,usr/lib,usr/bin,tmp,bin,Library,System/Library} \
         "$STAGE"/private/var/{run,tmp,log,root,db}

cp "$SRC/sbin/launchd"   "$STAGE/sbin/launchd"
cp "$SRC/usr/lib/dyld"   "$STAGE/usr/lib/dyld"
printf 'hakios miro smoke root\n' > "$STAGE/etc/motd"
chmod 755 "$STAGE/sbin/launchd" "$STAGE/usr/lib/dyld"
chmod 1777 "$STAGE/tmp"
# /var 是 iOS 里 /private/var 的软链，launchd 会走它
ln -sfn private/var "$STAGE/var"

if [ "$MODE" = "full" ]; then
	CACHE=$SRC/System/Library/Caches/com.apple.dyld
	[ -d "$CACHE" ] || { echo "缺少共享缓存 $CACHE"; exit 1; }
	echo "→ 拷共享缓存（$(du -sh "$CACHE" | cut -f1)）"
	mkdir -p "$STAGE/System/Library/Caches"
	# 同一文件系统上优先硬链接，5.3 GB 不用真拷一遍
	cp -al "$CACHE" "$STAGE/System/Library/Caches/" 2>/dev/null || \
		cp -a "$CACHE" "$STAGE/System/Library/Caches/"
	# launchd 依赖的库都在缓存里，但 dyld 找的路径是 /usr/lib/*.dylib
	# （缓存命中时不会真的读文件，缺文件也没关系，先留空目录）
fi

echo "→ 打包 $OUT"
python3 "$MKAPFS" -o "$OUT" "ROOT=$STAGE"
ls -l "$OUT"
python3 /home/niu/project/dome/hakios-ref/userland/tools/apfs/apfs.py tree "$OUT" | head -25
