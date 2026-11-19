#!/usr/bin/env bash
# offline-kernel.sh — 完全不联网地编 arm64e 内核、打 XNUP 载荷、上机测试。
#
# 存在的理由：GitHub Actions 那条路要么需要可写的 token，要么需要 github.com
# 可达，两条都不稳。本机其实具备完整工具链（xnu-deps 里的 xnu-clang、cctools、
# iPhoneOS26.5.xnu.sdk），因此整个链路可以离线跑完。
#
#   ./scripts/offline-kernel.sh check     只做预检，不写任何东西
#   ./scripts/offline-kernel.sh sync      把源码树对齐到正式版（bsd_init.c + init envp 补丁）
#   ./scripts/offline-kernel.sh build     对齐 + 编内核 + 严格校验产物
#   ./scripts/offline-kernel.sh payload   用新内核打载荷 out/payload-local-envp.bin
#   ./scripts/offline-kernel.sh boot      上机：驻留根盘 + 新载荷
#   ./scripts/offline-kernel.sh all       build → payload → boot（无设备时停在 payload）
#
# 环境变量：
#   IMG     根盘镜像            默认 out/root-slim2.apfs
#   PAYLOAD 载荷输出             默认 out/payload-local-envp.bin
#   JOBS    并行度               默认 nproc
#   ALLOW_FULL_REBUILD=1        允许在架构切换时清空 BUILD/obj（会重编数小时）
#
# 三条硬约束（都是踩过的坑）：
#   1. make 加 -k 会在报错后仍返回、留下**陈旧内核**。这里绝不用 -k，且产物必须
#      同时满足「时间戳更新」和「三个补丁字符串都在」才算成功。
#   2. 源码树里的 bsd_init.c 可能是过时版本（缺 ramfs 补丁）。以 work/bsd_init.c
#      为准，每次 build 前对齐。
#   3. 载荷条目之间没有 16 字节对齐；打包一律走 scripts/mkpayload.py。
set -uo pipefail

ROOT=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
DOME=$(cd "$ROOT/.." && pwd)
HAKIOS=$DOME/hakios-ref/base
TREE=$DOME/.build/xnu-src
DEPS=$HAKIOS/xnu-deps
SDK=$DEPS/sdk/iPhoneOS26.5.xnu.sdk
OUT=$ROOT/out
KERNEL=$TREE/BUILD/obj/DEVELOPMENT_ARM64_BCM2837/mach.development.bcm2837
BASE_PAYLOAD=$OUT/payload-kernel-arm64e-rd.bin
IMG=${IMG:-$OUT/root-slim2.apfs}
PAYLOAD=${PAYLOAD:-$OUT/payload-local-envp.bin}
JOBS=${JOBS:-$(nproc)}
PY=${PY:-python3}
# 内核命令行。exec_env=NAME:VAR=VALUE 是 dada 补丁自带的机制（kern_exec.c 里
# PE_parse_boot_arg_str("exec_env")），对 basename 为 NAME 的程序注入环境变量，
# 并打印 `exec: launchd gets ... (exec_env)` —— 改这里不用重编内核。
# 与内核侧的 envp 补丁是双保险：同一个变量给两遍，dyld 的 getenv 取第一个，值相同。
CMDLINE=${CMDLINE:-cpus=2 exec_env=launchd:DYLD_SHARED_CACHE_DIR=/System/Library/Caches/com.apple.dyld}

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; DIM=$'\033[2m'; RST=$'\033[0m'
ok()   { printf '  %s✓%s %s\n' "$GRN" "$RST" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$RED" "$RST" "$*"; }
warn() { printf '  %s!%s %s\n' "$YEL" "$RST" "$*"; }
step() { printf '\n%s== %s%s\n' "$DIM" "$*" "$RST"; }
die()  { bad "$*"; exit 1; }

# 内核里必须出现的三个标记：envp 补丁、ramfs 挂载、/dev 创建
MARKERS=("DYLD_SHARED_CACHE_DIR" "mount ramfs" "mkdir /dev")

# 注意：不能写成 `strings ... | grep -q`。本脚本开了 pipefail，grep -q 一命中就退出
# 会让 strings 收到 SIGPIPE，整条管道返回 141，把「找到了」误判成「没找到」。
# 这里让 grep 排空全部输入（不用 -q），状态就只反映是否匹配。
kernel_has() { strings -a "$1" 2>/dev/null | grep -F -- "$2" >/dev/null 2>&1; }

# ---------------------------------------------------------------- check
cmd_check() {
	step "预检（离线，不联网）"
	local fail=0

	[ -f "$TREE/Makefile" ] && ok "内核树 $TREE" || { bad "缺内核树 $TREE"; fail=1; }
	[ -x "$DEPS/host/bin/xnu-clang" ] && ok "xnu-clang（$("$DEPS/host/bin/xnu-clang" --version 2>/dev/null | head -1)）" \
		|| { bad "缺 $DEPS/host/bin/xnu-clang"; fail=1; }
	[ -d "$SDK" ] && ok "SDK $(basename "$SDK")" || { bad "缺 SDK $SDK"; fail=1; }
	[ -f "$HAKIOS/xnu-build.sh" ] && ok "xnu-build.sh" || { bad "缺 $HAKIOS/xnu-build.sh"; fail=1; }
	[ -f "$ROOT/work/bsd_init.c" ] && ok "正式版 bsd_init.c（$(stat -c %s "$ROOT/work/bsd_init.c") 字节）" \
		|| { bad "缺 work/bsd_init.c"; fail=1; }
	[ -f "$BASE_PAYLOAD" ] && ok "基准载荷 $(basename "$BASE_PAYLOAD")" \
		|| { bad "缺基准载荷 $BASE_PAYLOAD（需要它提供 loader.efi/ramdisk/cmdline）"; fail=1; }
	[ -f "$ROOT/scripts/patch-init-envp.sh" ] && ok "init envp 补丁脚本" || { bad "缺 patch-init-envp.sh"; fail=1; }
	[ -f "$ROOT/scripts/mkpayload.py" ] || command -v "$PY" >/dev/null || { bad "缺 $PY"; fail=1; }

	# 架构戳：不匹配时 xnu-build.sh 会清空 BUILD/obj 全量重编
	local stamp
	stamp=$(cat "$TREE/BUILD/obj/redwood-arch" 2>/dev/null || echo '(无)')
	if [ "$stamp" = "arm64e" ]; then
		ok "BUILD/obj 架构戳 arm64e（可增量编）"
	else
		warn "BUILD/obj 架构戳是 $stamp，不是 arm64e —— build 会触发全量重编"
		warn "  要允许请设 ALLOW_FULL_REBUILD=1"
	fi

	[ -f "$IMG" ] && ok "根盘 $(basename "$IMG")（$(numfmt --to=iec "$(stat -c %s "$IMG")")）" \
		|| warn "缺根盘 $IMG（只影响 boot 步骤）"

	if command -v fastboot >/dev/null; then
		local dev
		dev=$(timeout 15 fastboot devices 2>/dev/null | head -1)
		[ -n "$dev" ] && ok "设备在线：$dev" || warn "设备未连接（只影响 boot 步骤）"
	else
		warn "本机没有 fastboot（只影响 boot 步骤）"
	fi

	[ $fail -eq 0 ] && printf '\n  预检通过。\n' || { printf '\n'; die "预检未通过"; }
}

# ---------------------------------------------------------------- sync
cmd_sync() {
	step "对齐源码树"

	local src=$TREE/bsd/kern/bsd_init.c
	if ! cmp -s "$ROOT/work/bsd_init.c" "$src"; then
		cp "$src" "$ROOT/out/bsd_init.c.tree.bak" 2>/dev/null
		cp "$ROOT/work/bsd_init.c" "$src"
		ok "bsd_init.c ← work/ 正式版（原文件备份到 out/bsd_init.c.tree.bak）"
	else
		ok "bsd_init.c 已是正式版"
	fi

	grep -q "VNOP_MKDIR" "$src" || die "bsd_init.c 里没有 VNOP_MKDIR，版本不对"
	grep -q "hakios_mount_var" "$src" || die "bsd_init.c 里没有 ramfs 补丁（hakios_mount_var）"

	bash "$ROOT/scripts/patch-init-envp.sh" "$TREE" || die "init envp 补丁失败"
}

# ---------------------------------------------------------------- build
cmd_build() {
	cmd_check || exit 1
	cmd_sync || exit 1

	local stamp
	stamp=$(cat "$TREE/BUILD/obj/redwood-arch" 2>/dev/null || echo '')
	if [ "$stamp" != "arm64e" ] && [ "${ALLOW_FULL_REBUILD:-0}" != "1" ]; then
		die "架构戳是 '$stamp'，build 会清空 BUILD/obj 全量重编。确认要跑请设 ALLOW_FULL_REBUILD=1"
	fi

	step "编内核（arm64e / BCM2837 / DEVELOPMENT，$JOBS 路并行）"
	local t0 before
	t0=$(date +%s)
	before=0
	[ -f "$KERNEL" ] && before=$(stat -c %Y "$KERNEL")
	local log=$OUT/build-offline.log
	mkdir -p "$OUT"

	# 显式设 XNU_SRC：xnu-env.sh 的默认值指向另一棵树
	(
		export XNU_SRC=$TREE
		export RC_DARWIN_KERNEL_VERSION=12377.121.6
		export XNU_ARCH=arm64e
		export MACHINE=BCM2837
		# shellcheck disable=SC1091
		source "$HAKIOS/xnu-env.sh"
		cd "$HAKIOS" || exit 1
		# 不用 -k：报错必须让 make 失败，否则会留下陈旧内核
		./xnu-build.sh -j"$JOBS"
	) > "$log" 2>&1
	local rc=$?

	printf '  make 退出码 %d，用时 %ds，日志 %s\n' "$rc" "$(( $(date +%s) - t0 ))" "$log"
	if [ $rc -ne 0 ]; then
		printf '  错误摘要：\n'
		grep -oE "error: [^\"]{0,90}" "$log" | sed -E 's/[0-9]+/N/g' | sort | uniq -c | sort -rn | head -10 | sed 's/^/    /'
		grep -nE "error:|Error [0-9]|\*\*\*" "$log" | head -8 | sed 's/^/    /'
		die "构建失败，见 $log"
	fi

	[ -f "$KERNEL" ] || die "make 返回 0 但没有产物 $KERNEL"

	# 陈旧检测：时间戳没变说明根本没重链接
	local after
	after=$(stat -c %Y "$KERNEL")
	if [ "$after" = "$before" ]; then
		warn "内核时间戳未变（可能 Makefile 认为已最新）；继续校验内容"
	fi

	step "校验产物"
	local missing=0 m
	for m in "${MARKERS[@]}"; do
		if kernel_has "$KERNEL" "$m"; then ok "含标记：$m"; else bad "缺标记：$m"; missing=1; fi
	done
	[ $missing -eq 0 ] || die "内核缺少补丁标记，产物不可用"

	local noundefs
	noundefs=$(file -b "$KERNEL" | tr ',' '\n' | grep -c NOUNDEFS)
	[ "$noundefs" -ge 1 ] && ok "NOUNDEFS（符号全部解析）" || warn "未看到 NOUNDEFS 标志"

	printf '  %s\n' "$KERNEL"
	printf '  %s 字节  %s\n' "$(stat -c %s "$KERNEL")" "$(file -b "$KERNEL" | cut -c1-60)"
}

# ---------------------------------------------------------------- payload
cmd_payload() {
	step "打载荷"
	[ -f "$KERNEL" ] || die "缺内核 $KERNEL，先跑 build"
	[ -f "$BASE_PAYLOAD" ] || die "缺基准载荷 $BASE_PAYLOAD"

	"$PY" "$ROOT/scripts/mkpayload.py" build --kernel "$KERNEL" --base "$BASE_PAYLOAD" --out "$PAYLOAD" \
		|| die "打包失败"

	if [ -n "${CMDLINE:-}" ]; then
		"$PY" "$ROOT/scripts/mkpayload.py" cmdline --src "$PAYLOAD" --text "$CMDLINE" --out "$PAYLOAD" \
			|| die "写 cmdline 失败"
	fi

	local missing=0 m
	for m in "${MARKERS[@]}"; do
		if kernel_has "$PAYLOAD" "$m"; then :; else bad "载荷里缺 $m"; missing=1; fi
	done
	[ $missing -eq 0 ] || die "载荷内容校验失败"

	[ "$(stat -c %s "$PAYLOAD")" -lt $((64 * 1024 * 1024)) ] \
		&& ok "大小 $(numfmt --to=iec "$(stat -c %s "$PAYLOAD")")（payload 区上限 64 MB）" \
		|| die "载荷超过 64 MB，必须改走驻留区"

	"$PY" "$ROOT/scripts/mkpayload.py" list "$PAYLOAD"
}

# ---------------------------------------------------------------- boot
cmd_boot() {
	step "上机测试"
	local dev
	dev=$(timeout 15 fastboot devices 2>/dev/null | head -1)
	[ -n "$dev" ] || die "设备未连接（fastboot devices 为空）"
	[ -f "$PAYLOAD" ] || die "缺载荷 $PAYLOAD"
	[ -f "$IMG" ] || die "缺根盘 $IMG"
	ok "设备：$dev"

	"$ROOT/scripts/resident-boot-test.sh" "$IMG" "$PAYLOAD"
}

# ---------------------------------------------------------------- main
case ${1:-} in
	check)   cmd_check ;;
	sync)    cmd_sync ;;
	build)   cmd_build ;;
	payload) cmd_payload ;;
	boot)    cmd_boot ;;
	all)
		cmd_build || exit 1
		cmd_payload || exit 1
		if [ -n "$(timeout 15 fastboot devices 2>/dev/null | head -1)" ]; then
			cmd_boot
		else
			warn "设备未连接，停在载荷这一步"
		fi
		;;
	*)
		sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
		;;
esac
