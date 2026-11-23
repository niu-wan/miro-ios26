#!/usr/bin/env bash
# 在 VFS 的 lookup() 里加一条探针：dyld 有没有去找共享缓存。
#
#   用法： ./patch-lookup-probe.sh <xnu-src>
#
# 为什么需要：
#   dyld 找不到共享缓存时有两种表现——要么报 `dyld cache '...' not loaded`，
#   要么**完全沉默**，只在后面抛一句 `Library not loaded: libSystem`。
#   我们遇到的是后者：设了 DYLD_SHARED_CACHE_DIR 之后连报错都没了，缓存依然
#   没装上。静态分析到这一步已经没有信息量，只能让内核告诉我们它有没有被查过。
#
# 为什么打在 lookup() 而不是 open()：
#   namei_setup 会先把用户态路径 copyinstr 到内核缓冲 ni_pathbuf
#   （bsd/vfs/vfs_lookup.c:350/356），cnp->cn_nameptr 指向该内核缓冲，直接
#   打印是安全的；而 ndp->ni_dirp 是用户态地址，解引用会踩页。
#
# 只匹配 dyld_shared_cache* 这一类组件名：loader 的日志环只有 32 KB，全量打印会
# 把真正有用的 panic 段冲掉。
#
# 幂等：重复运行不会重复插入。
set -uo pipefail

TREE=${1:?用法: $0 <xnu-src>}
[ -f "$TREE/bsd/vfs/vfs_lookup.c" ] || { echo "不像 xnu 树：$TREE" >&2; exit 1; }

python3 - "$TREE" <<'PY'
import sys

tree = sys.argv[1]
path = tree + '/bsd/vfs/vfs_lookup.c'
s = open(path, encoding='utf-8', errors='surrogateescape').read()

MARK = 'miro: 探针 —— dyld 到底有没有去找共享缓存'
if MARK in s:
    print('  已是目标状态:', path)
    sys.exit(0)

anchor = '''	int error = 0;
	struct componentname *cnp = &ndp->ni_cnd;
	vfs_context_t ctx = cnp->cn_context;
	int vbusyflags = 0;
	int nc_generation = 0;
	vnode_t last_dp = NULLVP;
	int keep_going;
	int atroot;
'''

if anchor not in s:
    print('  找不到 lookup() 的变量声明块，可能上游已改动', file=sys.stderr)
    sys.exit(1)

probe = anchor + '''
	/*
	 * miro: 探针 —— dyld 到底有没有去找共享缓存。
	 * 只关心 dyld_shared_cache* 这一类组件名，其它路径不打，避免刷爆 32 KB 日志环。
	 */
	if (cnp->cn_namelen >= 17 && cnp->cn_nameptr != NULL &&
	    strncmp(cnp->cn_nameptr, "dyld_shared_cache", 17) == 0) {
		printf("miro: lookup %.*s\\n", (int)cnp->cn_namelen, cnp->cn_nameptr);
	}
'''

s = s.replace(anchor, probe, 1)
open(path, 'w', encoding='utf-8', errors='surrogateescape').write(s)
print('  已插入探针:', path)
PY
