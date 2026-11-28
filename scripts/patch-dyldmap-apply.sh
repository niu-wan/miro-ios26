#!/usr/bin/env bash
# 让内核在 dyld 询问共享区时，主动把 dyld 共享缓存映射进 shared region。
#
#   用法： ./patch-dyldmap-apply.sh <xnu-src>
#
# 为什么：
#   本移植版内核里 shared region 是**空**的（没有缓存映射），而 iOS 26 的 dyld
#   不会自己去读缓存文件（VFS 探针 0 命中，已实测）。它只会调
#   shared_region_check_np() 问内核"共享区在哪"。
#
#   那就把答案准备好：dyld 来问、发现是空的，内核当场把缓存映射进去再回答。
#   选 syscall 入口而不是 exec 路径的理由：
#     - 系统调用上下文可以睡眠，能做 vnode_lookup / 读文件
#     - 有 proc，可拿 root dir
#     - 不碰 vm_shared_region_enter 的锁状态
#
#   缓存按记录地址直映射（slide=0）：dyld 缓存是按固定基址 0x180000000 构建的，
#   不滑动时内部指针天然正确，省掉整套 slide/fixup 逻辑。
#
# 分两步：
#   第一步只映射桩文件（mappingCount=1）。目的是验证 check_np 能返回有效地址。
#   验证通过后再把 .NN 子缓存逐个加进来（见 MIRO_DYLD_MAP_ALL）。
#
# 幂等：重复运行不会重复插入。
set -uo pipefail

TREE=${1:?用法: $0 <xnu-src>}
[ -f "$TREE/bsd/vm/vm_unix.c" ] || { echo "不像 xnu 树：$TREE" >&2; exit 1; }
[ -f "$TREE/osfmk/vm/vm_shared_region.c" ] || { echo "不像 xnu 树：$TREE" >&2; exit 1; }

python3 - "$TREE" <<'PY'
import sys

tree = sys.argv[1]

# ---------------------------------------------------------------- 1) 包装函数
p1 = tree + '/osfmk/vm/vm_shared_region.c'
s1 = open(p1, encoding='utf-8', errors='surrogateescape').read()
MARK1 = 'miro: 给 BSD 侧用的 mapping 包装'

if MARK1 not in s1:
    anchor1 = '''static void
vm_shared_region_release(vm_shared_region_t shared_region)
{
	vm_shared_region_lock();
	assert(shared_region->sr_mapping_in_progress == current_thread());
	shared_region->sr_mapping_in_progress = THREAD_NULL;
	vm_shared_region_wakeup((event_t) &shared_region->sr_mapping_in_progress);
	vm_shared_region_unlock();
}
'''
    assert anchor1 in s1, 'vm_shared_region_release 形式变了'

    wrapper = anchor1 + '''
/*
 * miro: 给 BSD 侧用的 mapping 包装
 *
 * vm_shared_region_map_file() 要求 sr_mapping_in_progress == current_thread()，
 * 而那套 acquire/release 是本文件里的 static 函数。BSD 侧（bsd_init / check_np）
 * 够不着，所以在这里包一层。
 */
kern_return_t
miro_shared_region_map_file(vm_shared_region_t shared_region,
    int count, struct _sr_file_mappings *mappings)
{
	kern_return_t kr;

	vm_shared_region_acquire(shared_region);
	kr = vm_shared_region_map_file(shared_region, count, mappings);
	vm_shared_region_release(shared_region);
	return kr;
}
'''
    s1 = s1.replace(anchor1, wrapper, 1)
    open(p1, 'w', encoding='utf-8', errors='surrogateescape').write(s1)
    print('  已加 wrapper:', p1)
else:
    print('  wrapper 已是目标状态')

# ---------------------------------------------------------------- 2) 映射本体
p2 = tree + '/bsd/vm/vm_unix.c'
s2 = open(p2, encoding='utf-8', errors='surrogateescape').read()
MARK2 = 'miro: dyld 缓存映射（check_np 触发）'

if MARK2 in s2:
    print('  映射本体已是目标状态')
    sys.exit(0)

helper = '''/*
 * miro: dyld 缓存映射（check_np 触发）
 *
 * dyld 只会调 shared_region_check_np() 问内核要共享区地址；本移植版内核
 * 建出来的共享区是空的，于是 dyld 判定"无缓存"并放弃（它不会自己去读文件）。
 * 这里在回答之前先把缓存映射进去。
 *
 * 只映射桩文件（mappingCount=1，地址 0x180000000）。先验证机制，
 * 再扩展到 .NN 子缓存。
 */
#define MIRO_DYLD_CACHE_PATH "System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e"

/* 在 osfmk/vm/vm_shared_region.c 里定义（那里 acquire/release 是 static） */
extern kern_return_t miro_shared_region_map_file(vm_shared_region_t shared_region,
    int count, struct _sr_file_mappings *mappings);

static int
miro_map_dyld_cache(vm_shared_region_t shared_region)
{
	vnode_t vp = NULLVP;
	vfs_context_t ctx;
	unsigned char *hdr = NULL;
	struct shared_file_mapping_slide_np *maps = NULL;
	struct _sr_file_mappings srfm;
	uint32_t moff = 0, mcnt = 0, i;
	int err, resid = 0;
	kern_return_t kr = KERN_FAILURE;

	ctx = vfs_context_create(NULL);

	err = vnode_lookup(MIRO_DYLD_CACHE_PATH, 0, &vp, ctx);
	if (err != 0) {
		printf("miro: map: lookup failed (%d)\\n", err);
		goto out;
	}

	hdr = kalloc_data(0x1000, Z_WAITOK | Z_ZERO);
	if (hdr == NULL) {
		goto out;
	}
	err = vn_rdwr(UIO_READ, vp, (caddr_t)hdr, 0x1000, 0,
	    UIO_SYSSPACE, 0, NOCRED, &resid, NULL);
	if (err != 0) {
		printf("miro: map: read failed (%d)\\n", err);
		goto out;
	}

	memcpy(&moff, hdr + 0x10, 4);
	memcpy(&mcnt, hdr + 0x14, 4);
	if (mcnt == 0 || mcnt > 64 || moff + mcnt * 32 > 0x1000) {
		printf("miro: map: bad header moff=0x%x mcnt=%u\\n", moff, mcnt);
		goto out;
	}

	maps = kalloc_data(mcnt * sizeof(*maps), Z_WAITOK | Z_ZERO);
	if (maps == NULL) {
		goto out;
	}
	for (i = 0; i < mcnt; i++) {
		const unsigned char *e = hdr + moff + i * 32;
		uint64_t a, sz, fo;
		uint32_t mp, ip;

		memcpy(&a, e, 8);
		memcpy(&sz, e + 8, 8);
		memcpy(&fo, e + 16, 8);
		memcpy(&mp, e + 24, 4);
		memcpy(&ip, e + 28, 4);

		maps[i].sms_address = a;
		maps[i].sms_size = sz;
		maps[i].sms_file_offset = fo;
		maps[i].sms_max_prot = mp;
		maps[i].sms_init_prot = ip;
	}

	memset(&srfm, 0, sizeof(srfm));
	srfm.vp = vp;
	srfm.mappings_count = mcnt;
	srfm.mappings = maps;
	srfm.slide = 0;
	srfm.file_control = ubc_getobject(vp, UBC_HOLDOBJECT);
	if (srfm.file_control == MEMORY_OBJECT_CONTROL_NULL) {
		printf("miro: map: no memory object\\n");
		goto out;
	}

	kr = miro_shared_region_map_file(shared_region, 1, &srfm);
	printf("miro: map: %u mapping(s) at 0x%llx -> kr=0x%x\\n",
	    mcnt, (unsigned long long)maps[0].sms_address, kr);

out:
	if (maps != NULL) {
		kfree_data(maps, mcnt * sizeof(*maps));
	}
	if (hdr != NULL) {
		kfree_data(hdr, 0x1000);
	}
	if (vp != NULL) {
		vnode_put(vp);
	}
	vfs_context_rele(ctx);
	return kr == KERN_SUCCESS ? 0 : -1;
}

'''

# 插在 shared_region_check_np 定义之前
anchor2 = '''/*
 * shared_region_check_np:
'''
if anchor2 not in s2:
    print('  找不到 shared_region_check_np 的注释块', file=sys.stderr)
    sys.exit(1)
s2 = s2.replace(anchor2, helper + anchor2, 1)

# 在 check_np 的空共享区分支里调用
old_call = '''			kr = vm_shared_region_start_address(shared_region, &start_address);
			if (kr != KERN_SUCCESS) {'''
new_call = '''			kr = vm_shared_region_start_address(shared_region, &start_address);
			if (kr != KERN_SUCCESS && !miro_map_attempted) {
				/*
				 * miro: 共享区是空的 —— dyld 不会自己去读缓存，
				 * 所以内核在这里替它映射，然后再试一次。
				 */
				miro_map_attempted = 1;
				(void)miro_map_dyld_cache(shared_region);
				kr = vm_shared_region_start_address(shared_region, &start_address);
			}
			if (kr != KERN_SUCCESS) {'''
if old_call not in s2:
    print('  找不到 check_np 里的 start_address 调用', file=sys.stderr)
    sys.exit(1)
s2 = s2.replace(old_call, new_call, 1)

# 声明 miro_map_attempted（放在函数体开头）
old_decl = '''	int                     error = 0;
	kern_return_t           kr = KERN_FAILURE;
	task_t                  task = current_task();
'''
new_decl = '''	int                     error = 0;
	kern_return_t           kr = KERN_FAILURE;
	task_t                  task = current_task();
	static int              miro_map_attempted = 0;   /* miro: 只尝试映射一次 */
'''
if old_decl not in s2:
    print('  找不到 check_np 的变量声明块', file=sys.stderr)
    sys.exit(1)
s2 = s2.replace(old_decl, new_decl, 1)

open(p2, 'w', encoding='utf-8', errors='surrogateescape').write(s2)
print('  已插入映射本体:', p2)
PY
