#!/usr/bin/env bash
# 在 bsd_init() 执行 init 之前，用内核身份去打开并读一下 dyld 共享缓存。
#
#   用法： ./patch-dyldmap-probe.sh <xnu-src>
#
# 为什么：
#   要把共享缓存映射进 shared region（这样 dyld 通过 check_np 就能拿到地址），
#   第一步必须先确认**内核自己**能不能定位并读取那个文件。
#   在此之前所有尝试都是用户态的（dyld），而 dyld 根本不去读文件
#   （VFS 探针 0 命中），所以内核这条路径从未被验证过。
#
#   这一步只读 0x40 字节头，打印 magic / mappingOffset / mappingCount。
#   拿到这三个值就说明「内核 → VFS → APFS → 缓存文件」整条链是通的，
#   后面才值得去写真正的映射代码。
#
# 幂等：重复运行不会重复插入。
set -uo pipefail

TREE=${1:?用法: $0 <xnu-src>}
[ -f "$TREE/bsd/kern/bsd_init.c" ] || { echo "不像 xnu 树：$TREE" >&2; exit 1; }

python3 - "$TREE" <<'PY'
import sys

tree = sys.argv[1]
path = tree + '/bsd/kern/bsd_init.c'
s = open(path, encoding='utf-8', errors='surrogateescape').read()

MARK = 'miro: 内核能不能读 dyld 共享缓存'
if MARK in s:
    print('  已是目标状态:', path)
    sys.exit(0)

helper = '''/*
 * miro: 内核能不能读 dyld 共享缓存
 *
 * 在 exec init 之前，以内核身份打开共享缓存并读 0x40 字节头。
 * 只为验证「内核 -> VFS -> APFS -> 缓存文件」这条链是否通，
 * 以及内核看到的 mappingOffset/mappingCount 是否与离线解析一致。
 */
static void
miro_probe_dyld_cache(void)
{
	vnode_t vp = NULLVP;
	vfs_context_t ctx;
	unsigned char hdr[0x40];
	int err;
	int resid = 0;
	uint32_t moff = 0;
	uint32_t mcnt = 0;

	ctx = vfs_context_create(NULL);

	err = vnode_lookup("System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e",
	    0, &vp, ctx);
	if (err != 0) {
		printf("miro: cache lookup failed (%d)\\n", err);
		vfs_context_rele(ctx);
		return;
	}

	err = vn_rdwr(UIO_READ, vp, (caddr_t)hdr, sizeof(hdr), 0,
	    UIO_SYSSPACE, 0, NOCRED, &resid, NULL);
	if (err == 0) {
		memcpy(&moff, hdr + 0x10, 4);
		memcpy(&mcnt, hdr + 0x14, 4);
		printf("miro: cache ok magic=%.8s mapoff=0x%x mapcnt=%u\\n",
		    hdr, moff, mcnt);
	} else {
		printf("miro: cache read failed (%d)\\n", err);
	}

	vnode_put(vp);
	vfs_context_rele(ctx);
}

'''

call = '''	/* miro: 映射进 shared region 之前，先确认内核能读到它 */
	miro_probe_dyld_cache();

'''

anchor = '\tload_init_program(p);\n'
if anchor not in s:
    print('  找不到 load_init_program(p) 调用点', file=sys.stderr)
    sys.exit(1)

# helper 插在 bsd_init 定义之前。锚点要带上单独一行的 "void"：
# 源码里是 "void\nbsd_init(void)\n{\n"，只锚函数名会让那个 void 悬空，
# 编译报 "cannot combine with previous 'void' declaration specifier"。
fna = 'void\nbsd_init(void)\n{\n'
if fna not in s:
    print('  找不到 bsd_init() 定义', file=sys.stderr)
    sys.exit(1)
s = s.replace(fna, helper + fna, 1)

# 调用插在 load_init_program 之前（只替换第一个，即 bsd_init 里的那个）
s = s.replace(anchor, call + anchor, 1)

open(path, 'w', encoding='utf-8', errors='surrogateescape').write(s)
print('  已插入内核探针:', path)
PY
