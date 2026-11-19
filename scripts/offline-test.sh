#!/usr/bin/env bash
# miro 离线测试脚本 —— 全程不联网：不 apt、不 curl、不下载任何东西。
#
#   ./offline-test.sh check      检查本机已有的构建产物和工具（只读）
#   ./offline-test.sh pack       用本地源码重编 loader + 打 boot.img（不联网）
#   ./offline-test.sh boot       在连着的数据机上 fastboot boot 并读回日志/屏幕
#   ./offline-test.sh kernel     离线重编 XNU 内核（用已下载的源码和依赖）
#   ./offline-test.sh all        check → pack → boot（build 完直接上机）
#
# 需要的本地东西（都已经在这台机器上）：
#   .build/uefi-dada/            Mu-Silicium 树（含 miroPkg）
#   .build/xnu-src/              xnu-12377.121.6 + dada 补丁
#   ~/theos/                     工具链 + iPhoneOS16.5.sdk
#   ~/.tools/root|venv/          用户态 iasl、pyusb 等
set -uo pipefail

# ---------------------------------------------------------------- 路径
ROOT=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)      # hakios-miro/
DOME=$(cd "$ROOT/.." && pwd)                                  # project/dome
HAKIOS=$DOME/hakios-ref/base
TREE=$DOME/.build/uefi-dada
OUT=$ROOT/out
XNUSRC=$DOME/.build/xnu-src
PY=$HOME/.tools/venv/bin/python
FB=$ROOT/research/fb-probe/fb.py
IMG=$OUT/miro-offline.img
PAYLOAD=$OUT/usb-payload-offline.bin
LOADER=/tmp/loader-offline.efi

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; }
info() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die()  { printf '\033[31m错误：%s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- check
cmd_check() {
	info "1. 构建树"
	[ -d "$TREE/Platforms/Xiaomi/miroPkg" ] && ok "miroPkg 在 $TREE" || bad "缺 $TREE/Platforms/Xiaomi/miroPkg"
	[ -x "$TREE/Mu_Basecore/BaseTools/Source/C/bin/GenSec" ] && ok "BaseTools 已编" || bad "BaseTools 没编"
	[ -x "$TREE/Mu_Basecore/BaseTools/BinWrappers/PosixLike/build" ] && ok "EDK2 build 包装器在" || bad "缺 EDK2 build 包装器"

	info "2. 工具链"
	for t in clang lld-link llvm-objcopy dtc; do
		command -v "$t" >/dev/null && ok "$t" || bad "$t 缺失"
	done
	[ -x "$HOME/theos/toolchain/linux/iphone/bin/clang" ] && ok "theos 工具链" || bad "缺 theos 工具链"
	[ -d "$HOME/theos/sdks/iPhoneOS16.5.sdk" ] && ok "iPhoneOS16.5.sdk" || bad "缺 iPhoneOS SDK"

	info "3. 内核"
	[ -f "$XNUSRC/Makefile" ] && ok "xnu 源码在 $XNUSRC" || bad "缺 xnu 源码"
	[ -f "$XNUSRC/osfmk/kern/lock_rw.h" ] && ok "源码完整" || bad "源码不完整"
	[ -x "$HAKIOS/xnu-deps/host/bin/mig" ] && ok "mig 已编" || bad "mig 没编（xnu-deps/setup.sh --stage1）"

	info "4. 镜像"
	[ -f "$OUT/miro-p2-platform.img" ] && ok "已有 miro-p2-platform.img ($(stat -c %s "$OUT/miro-p2-platform.img") 字节)" || bad "还没打过镜像（跑 pack）"
	[ -f "$OUT/miro-info/live.dtb" ] && ok "真机 live.dtb 在" || bad "缺 live.dtb"

	info "5. 手机与工具"
	if command -v adb >/dev/null && adb devices 2>/dev/null | awk 'NR>1 && $2=="device"' | grep -q .; then
		ok "adb 连着手机"
	elif command -v fastboot >/dev/null && [ -n "$(timeout 3 fastboot devices 2>/dev/null)" ]; then
		ok "手机在 fastboot"
	else
		bad "手机没连（boot 需要它）"
	fi
	[ -x "$PY" ] && "$PY" -c 'import usb' 2>/dev/null && ok "pyusb 可用（读 loader 日志用）" || bad "pyusb 不可用"
}

# ---------------------------------------------------------------- pack
cmd_pack() {
	info "1. 编 loader（clang + lld-link，本地）"
	local src=$HAKIOS/xnuloader
	[ -f "$src/loader.c" ] || die "找不到 $src/loader.c"
	clang --target=aarch64-unknown-windows -ffreestanding -fno-builtin -fno-stack-protector \
		-fshort-wchar -mgeneral-regs-only -O1 -w \
		-DPAYLOAD_BASE=0xA8000000ULL -DPAYLOAD_MAX_SIZE=0x10000000ULL \
		-c "$src/loader.c" -o /tmp/loader-offline.obj || die "loader 编译失败"
	lld-link /subsystem:efi_application /entry:efi_main /nodefaultlib /base:0xA1000000 \
		/out:"$LOADER" /tmp/loader-offline.obj || die "loader 链接失败"
	ok "loader $LOADER ($(stat -c %s "$LOADER") 字节)"

	info "2. 打 payload"
	"$PY" "$src/mkpayload.py" -o "$PAYLOAD" loader.efi="$LOADER" --usb || die "mkpayload 失败"
	ok "payload $PAYLOAD ($(stat -c %s "$PAYLOAD") 字节)"

	info "3. 编 UEFI（miroPkg）"
	DEV=miro W="$TREE" bash "$ROOT/scripts/build-uefi-native.sh" > /tmp/offline-uefi.log 2>&1
	local rc=$?
	[ $rc -eq 0 ] || { tail -15 /tmp/offline-uefi.log; die "UEFI 编译失败（日志 /tmp/offline-uefi.log）"; }
	local fd=$TREE/Build/miroPkg/RELEASE_CLANGPDB/FV/SILICIUM_UEFI.fd
	ok "FD $fd ($(stat -c %s "$fd") 字节)"

	info "4. 打 boot.img"
	# mkxnuimg 用 base/Mu-Silicium 找 shim 和 FD
	ln -sfn "$TREE" "$HAKIOS/Mu-Silicium"
	( cd "$HAKIOS" && FD_BASE=0xA7100000 FD_SIZE=0x300000 PAYLOAD_BASE=0xA8000000 \
		HEADER_VERSION=4 UEFI_TARGET=miro \
		"$PY" mkxnuimg.py -p "$PAYLOAD" -o "$IMG" ) || die "mkxnuimg 失败"
	ok "镜像 $IMG ($(stat -c %s "$IMG") 字节)"
}

# ---------------------------------------------------------------- boot
wait_adb()  { for i in $(seq 1 60); do adb devices 2>/dev/null | awk 'NR>1 && $2=="device"' | grep -q . && return 0; sleep 2; done; return 1; }
wait_fb()   { for i in $(seq 1 30); do [ -n "$(timeout 3 fastboot devices 2>/dev/null)" ] && return 0; sleep 2; done; return 1; }
wait_ldr()  { for i in $(seq 1 30); do lsusb 2>/dev/null | grep -q "18d1:d00d" && return 0; sleep 2; done; return 1; }

cmd_boot() {
	[ -f "$IMG" ] || { [ -f "$OUT/miro-p2-platform.img" ] && IMG=$OUT/miro-p2-platform.img; }
	[ -f "$IMG" ] || die "没有可用的镜像（先跑 pack）"
	info "镜像：$IMG"

	if [ -n "$(timeout 3 fastboot devices 2>/dev/null)" ]; then
		ok "手机已在 fastboot，直接 boot"
	else
		wait_adb || die "adb 看不到手机（解锁屏幕、确认 USB 调试）"
		command -v adb >/dev/null || die "没有 adb"
		ok "adb 连着手机"
		adb reboot bootloader || die "重启到 bootloader 失败"
		wait_fb || die "进不去 fastboot（也可以用『电源+音量下』手动进）"
		ok "已进 fastboot"
	fi

	info "fastboot boot（不写任何分区）"
	timeout 90 fastboot boot "$IMG" 2>&1 | tail -3
	sleep 2
	if wait_ldr; then
		ok "xnuloader 起来了"
		info "读回信息"
		"$PY" "$FB" raw "getvar:screen" "getvar:product" 2>&1 | tail -4
		"$PY" "$FB" raw "oem memmap" >/dev/null 2>&1
		if "$PY" "$FB" log "$OUT/xnuloader-log-offline.txt" >/dev/null 2>&1; then
			ok "日志 → $OUT/xnuloader-log-offline.txt"
			grep -E "XNULOADER|display|platform|usb" "$OUT/xnuloader-log-offline.txt" | head -6
		fi
		info "回到 Android"
		"$PY" "$FB" raw "oem reboot" >/dev/null 2>&1 && ok "已发重启" || bad "重启命令没发出去（长按电源）"
	else
		bad "USB 上没有出现 xnuloader —— 可能黑屏/卡住，长按电源 10 秒回 Android"
	fi
}

cmd_kernel() {
	# 真正的构建逻辑收在 offline-kernel.sh：那边的 make 不加 -k，并且会校验
	# 产物里三个补丁标记都在，避免「make 返回 0 但内核是旧的」这种坑。
	[ -x "$ROOT/scripts/offline-kernel.sh" ] || die "缺 scripts/offline-kernel.sh"
	"$ROOT/scripts/offline-kernel.sh" build
}

# ---------------------------------------------------------------- main
case ${1:-} in
	check)  cmd_check ;;
	pack)   cmd_pack ;;
	boot)   cmd_boot ;;
	kernel) cmd_kernel ;;
	all)    cmd_check; cmd_pack; cmd_boot ;;
	*)      sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//' ;;
esac