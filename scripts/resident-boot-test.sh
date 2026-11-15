#!/bin/bash
# 驻留根盘测试：把大根盘（>64 MB payload 区放不下）放到 loader 的"驻留区"，
# 再跑内核。payload 区只有 64 MB（PAYLOAD_MAX_SIZE 0x04000000），大镜像必须走这条路。
#
#   ./scripts/resident-boot-test.sh out/root-fullz.apfs [payload]
#
# 流程：adb reboot bootloader → boot loader → stage payload → oem ramdisk →
#       stage 大镜像 → oem run → 抢在自动重启前 get_staged 抓日志
set -u
ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
IMG=${1:?用法: resident-boot-test.sh <根盘镜像> [payload]}
PAYLOAD=${2:-$ROOT/out/payload-kernel-arm64e-rd.bin}
LOADER=$ROOT/out/miro-p2-platform.img
RUN=$ROOT/out/run-resident/$(date +%Y%m%d-%H%M%S)
mkdir -p "$RUN"

# 沙箱里没有 /dev/bus/usb：走宿主代理，否则 fastboot 永远看不到设备
. "$ROOT/scripts/fb-env.sh"

say() { printf '%s\n' "$*"; }
fb() { timeout "${FB_TIMEOUT:-30}" fastboot "$@"; }

# 关键：fastboot 是通过宿主代理执行的，宿主的工作目录不是这里 —— 必须用绝对路径
IMG=$(readlink -f "$IMG")
PAYLOAD=$(readlink -f "$PAYLOAD")
[ -f "$IMG" ] || { say "缺镜像 $IMG"; exit 2; }
[ -f "$PAYLOAD" ] || { say "缺 payload $PAYLOAD"; exit 2; }
[ -f "$LOADER" ] || { say "缺 loader $LOADER"; exit 2; }

fb_seen() { fb devices 2>/dev/null | awk 'NF{found=1}END{exit !found}'; }

say "→ 进 bootloader"
if ! fb_seen; then
	timeout 20 adb reboot bootloader >/dev/null 2>&1
	for _ in $(seq 1 45); do sleep 2; fb_seen && break; done
fi
# 关键：必须确认真的在 fastboot，否则后面的 fastboot boot 只会干等
if ! fb_seen; then
	say "  设备不在 fastboot（USB 可能停在 loader 的 busy 状态）——先长按电源重启回 Android"
	exit 3
fi
fb devices 2>/dev/null | head -2

PRODUCT=$(fb getvar product 2>&1 | awk -F': ' '/^product:/{print $2;exit}')
if [ "$PRODUCT" = "xnuloader" ]; then
	# loader 已经驻留（上一次跑过），它不实现 fastboot boot，直接复用
	say "→ loader 已驻留，跳过 boot"
else
	say "→ boot loader"
	fb boot "$LOADER" > "$RUN/boot.out" 2>&1 || { say "boot 失败"; tail -2 "$RUN/boot.out"; exit 4; }
	sleep 6
	PRODUCT=$(fb getvar product 2>&1 | awk -F': ' '/^product:/{print $2;exit}')
fi
say "  product: $PRODUCT"

say "→ stage payload（$(basename "$PAYLOAD")）"
FB_TIMEOUT=180 fb stage "$PAYLOAD" > "$RUN/stage-payload.out" 2>&1 || { say "stage payload 失败"; tail -2 "$RUN/stage-payload.out"; exit 4; }

say "→ oem ramdisk（声明下一次下载进驻留区）"
fb oem ramdisk > "$RUN/ramdisk.out" 2>&1 || { say "oem ramdisk 失败"; tail -2 "$RUN/ramdisk.out"; exit 4; }

say "→ stage 根盘（$(basename "$IMG")，$(stat -c %s "$IMG") B，约 1 分钟）"
FB_TIMEOUT=600 fb stage "$IMG" > "$RUN/stage-image.out" 2>&1 || { say "stage 镜像失败"; tail -3 "$RUN/stage-image.out"; exit 4; }
tail -1 "$RUN/stage-image.out"

say "→ oem run"
fb oem run > "$RUN/run.out" 2>&1 || true

say "→ 等 result（抢在自动重启前）"
for i in $(seq 1 60); do
	R=$(fb getvar result 2>&1 | awk -F': ' '/^result:/{print $2;exit}')
	[ -n "$R" ] && [ "$R" != "idle" ] && { say "  [$i] result: $R"; break; }
	sleep 3
done

say "→ get_staged 抓日志"
if fb get_staged "$RUN/loader-log.txt" > "$RUN/getstaged.out" 2>&1 && [ -s "$RUN/loader-log.txt" ]; then
	say "  日志 $(stat -c %s "$RUN/loader-log.txt") B"
else
	say "  没抓到日志（设备可能已经重启回 Android）"
fi

say ""
say "结果目录: $RUN"
[ -f "$RUN/loader-log.txt" ] && strings -a "$RUN/loader-log.txt" | grep -E "PANIC:|Library not loaded|unable to resolve|launchd\|.*Notice|hakios: /dev" | tail -15
