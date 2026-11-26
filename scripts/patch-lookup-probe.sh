#!/usr/bin/env bash
# 在 VFS 的 lookup() 里加探针：dyld 到底探过哪些路径。
#
#   用法： ./patch-lookup-probe.sh <xnu-src>
#
# 为什么需要：
#   dyld 找不到共享缓存时可能**完全沉默**，只在后面抛 `Library not loaded:
#   libSystem`。我们遇到的就是这种：设了 DYLD_SHARED_CACHE_DIR 之后连
#   `dyld cache '...' not loaded` 都不打印了，缓存依然没装上。
#
# 第一版只匹配组件名 `dyld_shared_cache*`，结果 0 命中。但 0 命中本身有两种
# 解释，无法区分：
#     a) dyld 连缓存目录都没进去
#     b) 进了目录，但没打开那个文件
# 所以这一版把匹配放宽到目录级，同时记录：
#     - dyld_shared_cache*   （缓存文件本身）
#     - com.apple.dyld       （缓存目录名）
#     - Cryptexes            （iOS 16+ 缓存所在的 cryptex 路径）
# 三者配合就能看出 dyld 停在哪一级。
#
# 为什么打在 lookup() 而不是 open()：
#   namei_setup 会先把用户态路径 copyinstr 到内核缓冲 ni_pathbuf
#   （bsd/vfs/vfs_lookup.c:350/356），cnp->cn_nameptr 指向该内核缓冲，直接
#   打印是安全的；而 ndp->ni_dirp 是用户态地址，解引用会踩页。
#
# 为什么按 cn_namelen 精确比对长度：
#   路径缓冲里的各组件**不是各自 NUL 结尾**，只是用 '/' 分隔。若 namelen 比
#   常量短还去 strncmp 固定长度，会跨过 '/' 读进下一个组件造成误匹配。
#
# 幂等：重复运行不会重复插入；也负责把旧版探针替换掉。
set -uo pipefail

TREE=${1:?用法: $0 <xnu-src>}
[ -f "$TREE/bsd/vfs/vfs_lookup.c" ] || { echo "不像 xnu 树：$TREE" >&2; exit 1; }

python3 - "$TREE" <<'PY'
import sys

tree = sys.argv[1]
path = tree + '/bsd/vfs/vfs_lookup.c'
s = open(path, encoding='utf-8', errors='surrogateescape').read()

MARK = 'miro: 探针 —— dyld 探过哪些路径'
OLD = 'miro: 探针 —— dyld 到底有没有去找共享缓存'

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

body = '''
	/*
	 * miro: 探针 —— dyld 探过哪些路径。
	 * 目录级 + 文件级都记，用来区分「没进目录」和「进了目录没开文件」。
	 * 只匹配这几类名字，其它路径不打，避免刷爆 32 KB 日志环。
	 */
	if (cnp->cn_nameptr != NULL) {
		int hit = 0;

		if (cnp->cn_namelen >= 17 &&
		    strncmp(cnp->cn_nameptr, "dyld_shared_cache", 17) == 0) {
			hit = 1;
		} else if (cnp->cn_namelen == 14 &&
		    strncmp(cnp->cn_nameptr, "com.apple.dyld", 14) == 0) {
			hit = 1;
		} else if (cnp->cn_namelen == 9 &&
		    strncmp(cnp->cn_nameptr, "Cryptexes", 9) == 0) {
			hit = 1;
		}
		if (hit) {
			printf("miro: lookup %.*s\\n", (int)cnp->cn_namelen, cnp->cn_nameptr);
		}
	}
'''

if OLD in s:
    # 旧版：定位旧注释块起点，到它的 printf 所在 if 块结尾
    start = s.rfind('\t/*', 0, s.find(OLD))
    ppos = s.find('printf("miro: lookup', start)
    end = s.find('\t}\n', ppos)
    if start < 0 or ppos < 0 or end < 0:
        print('  找到旧标记但定位不到代码块，请手工处理', file=sys.stderr)
        sys.exit(1)
    end += len('\t}\n')
    while s[end:end + 1] == '\n':
        end += 1
    s = s[:start] + body.lstrip('\n') + s[end:]
    open(path, 'w', encoding='utf-8', errors='surrogateescape').write(s)
    print('  已用新版替换旧探针:', path)
    sys.exit(0)

if anchor not in s:
    print('  找不到 lookup() 的变量声明块，可能上游已改动', file=sys.stderr)
    sys.exit(1)

s = s.replace(anchor, anchor + body, 1)
open(path, 'w', encoding='utf-8', errors='surrogateescape').write(s)
print('  已插入探针:', path)
PY
