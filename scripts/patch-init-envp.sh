#!/usr/bin/env bash
# 给 PID 1（launchd）传一个最小环境变量：DYLD_SHARED_CACHE_DIR。
#
#   用法： ./patch-init-envp.sh <xnu-src>
#
# 为什么需要：
#   原生 XNU 在 load_init_program_at_path() 里写死 init_exec_args.envp = NULL，
#   真机上没问题——launchd 依赖的 dyld 共享缓存来自内核已经建好的 shared region。
#   我们自己造根盘时那条路走不通（shared region 是空的，check_np 返回 ENOMEM），
#   dyld 必须靠 DYLD_SHARED_CACHE_DIR 自己去 open() 缓存文件。
#
#   已从 iOS 26 的 /usr/lib/dyld 反汇编确认这个环境变量是被支持的：
#     0x1c138: adrp x1, #0x97000 ; add x1, x1, #0x32f   ; "DYLD_SHARED_CACHE_DIR"
#     0x1c140: bl   #0x884c                            ; 环境变量查找
#     0x1c144: cbz  x0, #0x1c168                       ; 没找到就跳过
#     0x1c158: bl   #0x2581c                           ; 用该目录的 fd 找缓存
#
# 幂等：重复运行不会重复插入。
set -uo pipefail

TREE=${1:?用法: $0 <xnu-src>}
[ -f "$TREE/bsd/kern/kern_exec.c" ] || { echo "不像是 xnu 树：$TREE" >&2; exit 1; }

python3 - "$TREE" <<'PY'
import sys

tree = sys.argv[1]
path = tree + '/bsd/kern/kern_exec.c'
s = open(path, encoding='utf-8', errors='surrogateescape').read()

MARK = 'miro: init 也需要一个最小环境'
if MARK in s:
    print('  已是目标状态:', path)
    sys.exit(0)

old = '''\tif (proc_is64bit(p)) {
\t\tuser64_addr_t argv64bit[3] = {};

\t\targv64bit[0] = argv0;
\t\targv64bit[1] = argv1;
\t\targv64bit[2] = USER_ADDR_NULL;

\t\terror = copyout(argv64bit, scratch_addr, sizeof(argv64bit));
\t\tif (error) {
\t\t\treturn error;
\t\t}
\t} else {
\t\tuser32_addr_t argv32bit[3] = {};

\t\targv32bit[0] = (user32_addr_t)argv0;
\t\targv32bit[1] = (user32_addr_t)argv1;
\t\targv32bit[2] = USER_ADDR_NULL;

\t\terror = copyout(argv32bit, scratch_addr, sizeof(argv32bit));
\t\tif (error) {
\t\t\treturn error;
\t\t}
\t}

\t/*
\t * Set up argument block for fake call to execve.
\t */
\tinit_exec_args.fname = argv0;
\tinit_exec_args.argp = scratch_addr;
\tinit_exec_args.envp = USER_ADDR_NULL;
'''

new = '''\tuser_addr_t argv_addr = scratch_addr;

\tif (proc_is64bit(p)) {
\t\tuser64_addr_t argv64bit[3] = {};

\t\targv64bit[0] = argv0;
\t\targv64bit[1] = argv1;
\t\targv64bit[2] = USER_ADDR_NULL;

\t\terror = copyout(argv64bit, scratch_addr, sizeof(argv64bit));
\t\tif (error) {
\t\t\treturn error;
\t\t}
\t\tscratch_addr = USER_ADDR_ALIGN(scratch_addr + sizeof(argv64bit), sizeof(user_addr_t));
\t} else {
\t\tuser32_addr_t argv32bit[3] = {};

\t\targv32bit[0] = (user32_addr_t)argv0;
\t\targv32bit[1] = (user32_addr_t)argv1;
\t\targv32bit[2] = USER_ADDR_NULL;

\t\terror = copyout(argv32bit, scratch_addr, sizeof(argv32bit));
\t\tif (error) {
\t\t\treturn error;
\t\t}
\t\tscratch_addr = USER_ADDR_ALIGN(scratch_addr + sizeof(argv32bit), sizeof(user_addr_t));
\t}

\t/*
\t * miro: init 也需要一个最小环境。
\t *
\t * 原生 XNU 给 init 传 envp = NULL，真机上没问题，因为 launchd 依赖的
\t * dyld 共享缓存来自内核已经建好的 shared region。我们自己造根盘时那条
\t * 路径走不通，dyld 需要靠 DYLD_SHARED_CACHE_DIR 自己去打开缓存文件。
\t * 这里塞一条进去，不影响正常启动。
\t */
\t{
\t\tconst char *init_env = "DYLD_SHARED_CACHE_DIR="
\t\t    "/System/Library/Caches/com.apple.dyld";
\t\tsize_t env_length = strlen(init_env) + 1;
\t\tuser_addr_t env_str = scratch_addr;

\t\terror = copyout(init_env, env_str, env_length);
\t\tif (error) {
\t\t\treturn error;
\t\t}
\t\tscratch_addr = USER_ADDR_ALIGN(scratch_addr + env_length, sizeof(user_addr_t));

\t\tif (proc_is64bit(p)) {
\t\t\tuser64_addr_t env64bit[2] = {};

\t\t\tenv64bit[0] = env_str;
\t\t\tenv64bit[1] = USER_ADDR_NULL;

\t\t\terror = copyout(env64bit, scratch_addr, sizeof(env64bit));
\t\t\tif (error) {
\t\t\t\treturn error;
\t\t\t}
\t\t} else {
\t\t\tuser32_addr_t env32bit[2] = {};

\t\t\tenv32bit[0] = (user32_addr_t)env_str;
\t\t\tenv32bit[1] = USER_ADDR_NULL;

\t\t\terror = copyout(env32bit, scratch_addr, sizeof(env32bit));
\t\t\tif (error) {
\t\t\t\treturn error;
\t\t\t}
\t\t}
\t}

\t/*
\t * Set up argument block for fake call to execve.
\t */
\tinit_exec_args.fname = argv0;
\tinit_exec_args.argp = argv_addr;
\tinit_exec_args.envp = scratch_addr;
'''

if old not in s:
    print('ERROR: %s 里找不到目标片段（上游代码可能变了）' % path, file=sys.stderr)
    sys.exit(1)

open(path, 'w', encoding='utf-8', errors='surrogateescape').write(s.replace(old, new))
print('  改:', path, '（init envp）')
PY

grep -n "DYLD_SHARED_CACHE_DIR" "$TREE/bsd/kern/kern_exec.c"
