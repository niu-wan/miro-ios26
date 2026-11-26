#!/usr/bin/env bash
# 让 shared_region_check_np() 在共享区为空时报 EINVAL 而不是 ENOMEM。
#
#   用法： ./patch-shared-region-einval.sh <xnu-src>
#
# 为什么：
#   bsd/vm/vm_unix.c:1207 的注释把 dyld 的预期流程写得很清楚：
#     EINVAL = 没有共享区；ENOMEM = 共享区存在但为空
#   - 为空时，dyld 应当调 shared_region_map_and_slide_2_np() 把缓存映射进来
#   - 判到"没有共享区"，dyld 会自己走 mmap 私有映射
#
#   我们这个移植版内核的情况是：共享区对象**存在但没有任何映射**，
#   vm_shared_region_start_address() 返回 KERN_FAILURE，于是返回 ENOMEM。
#   实测 dyld 收到 ENOMEM 之后既不映射也不读文件 —— 探针证明它连
#   /System/Library/Caches/com.apple.dyld 都没查过，直接在更早的判定里放弃了。
#
#   而 dyld 对 EINVAL 的处理不同（它本来就要应付"没有共享区"这种正常情况，
#   比如 macOS 上就是这样）。所以这里把空共享区的返回值改成 EINVAL，
#   看能否把 dyld 推到它自己的 mmap 分支。
#
# 幂等：重复运行不会重复修改。
set -uo pipefail

TREE=${1:?用法: $0 <xnu-src>}
[ -f "$TREE/bsd/vm/vm_unix.c" ] || { echo "不像 xnu 树：$TREE" >&2; exit 1; }

python3 - "$TREE" <<'PY'
import sys

tree = sys.argv[1]
path = tree + '/bsd/vm/vm_unix.c'
s = open(path, encoding='utf-8', errors='surrogateescape').read()

MARK = 'miro: 空共享区报 EINVAL'
if MARK in s:
    print('  已是目标状态:', path)
    sys.exit(0)

old = '''				    (uint64_t)uap->start_address, kr));
				error = ENOMEM;
			}'''

new = '''				    (uint64_t)uap->start_address, kr));
				/*
				 * miro: 空共享区报 EINVAL。
				 * 原来这里返回 ENOMEM（"共享区为空"），但实测 dyld 收到
				 * ENOMEM 后既不调 map_and_slide_2_np 也不读缓存文件，
				 * 直接判定无缓存。而 EINVAL（"没有共享区"）是 dyld 在
				 * 正常平台也会遇到的情况，会走自己的 mmap 分支。
				 */
				error = EINVAL;
			}'''

if old not in s:
    print('  找不到 check_np 里的 ENOMEM 分支，可能上游已改动', file=sys.stderr)
    sys.exit(1)

s = s.replace(old, new, 1)
open(path, 'w', encoding='utf-8', errors='surrogateescape').write(s)
print('  已改 check_np 返回值:', path)
PY
