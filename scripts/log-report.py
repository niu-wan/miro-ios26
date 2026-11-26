#!/usr/bin/env python3
"""分析一次上机测试的日志，给出结论并写 REPORT.md。

    ./scripts/log-report.py                    # 取 out/run-resident 下最新一次
    ./scripts/log-report.py out/run-resident/20261123-181900
    ./scripts/log-report.py --quiet <dir>      # 只写文件，不打印

为什么单独写一个：resident-boot-test.sh 结尾那段 grep 只找 panic 和
"Library not loaded"，而这次要判断的是三件更细的事：

  1. 环境变量到底有没有送到 launchd —— 两种证据
       a) boot-arg `exec_env=` 生效时会打 `exec: launchd gets ... (exec_env)`
       b) 内核 envp 补丁没有日志，只能靠"dyld 报错里出现真实路径"反推
  2. dyld 是否还在用 (null) 找缓存 —— `dyld cache '(null)' not loaded: (null)`
  3. 是否跨过了 dyld 这一关 —— `hello, launchd UUID:` 是 libignition 之后
     launchd 主体真正跑起来的标志

退出码：0 = 有实质进展（跨过 dyld），1 = 仍卡在同一处，2 = 日志/参数问题。
"""
import argparse
import os
import re
import sys
import glob

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RUNDIR = os.path.join(ROOT, 'out', 'run-resident')

# 关心的特征。顺序即报告里的顺序。
PATTERNS = [
    ('exec_env 注入',      re.compile(r'exec:\s+(\S+)\s+gets\s+(.+?)\s+\(exec_env\)')),
    ('dyld cache 路径',    re.compile(r"dyld cache '([^']*)' not loaded(?::\s*(.*))?")),
    ('launchd 启动',       re.compile(r'hello,\s*launchd\s+UUID:\s*(\S+)')),
    ('libSystem 解析',     re.compile(r"Library not loaded:\s*(\S+)")),
    ('panic',              re.compile(r'^== PANIC:.*|^panic\(.*', re.M)),
    ('initproc 失败',      re.compile(r'initproc failed to start[^\n]*')),
    ('ramfs 挂载',         re.compile(r'hakios: mount ramfs on ([^\n]*)')),
    ('/dev 创建',          re.compile(r'hakios: mkdir /dev -> (-?\d+)')),
    ('共享区 check_np',    re.compile(r'check_np\([^)]*\)\s+vm_shared_region_start_address\(\) returned (\S+)')),
    ('ignition 完成',      re.compile(r'ignition sequence complete')),
    ('内核崩溃帧',         re.compile(r'hakios: crash (\S+) signal (\d+) pc (\S+)')),
]


def newest_rundir():
    cands = [d for d in glob.glob(os.path.join(RUNDIR, '*')) if os.path.isdir(d)]
    return sorted(cands)[-1] if cands else None


def read_log(rundir):
    """优先 loader-log.txt，否则取编号最大的 log-NNN.txt。返回 (path, text)。"""
    cands = [os.path.join(rundir, 'loader-log.txt')]
    cands += sorted(glob.glob(os.path.join(rundir, 'log-*.txt')))
    for p in reversed(cands):
        if os.path.isfile(p) and os.path.getsize(p) > 0:
            raw = open(p, 'rb').read()
            # 日志里混着内核二进制串，先按 latin-1 解，再统一成可读形式
            txt = raw.decode('latin-1').replace('\x00', '')
            return p, txt
    return None, ''


PROBE = re.compile(r'miro: lookup (\S+)')
# loader 解析载荷时逐条打印：payload entry 'kernel' size ... 
PAYLOAD_ENTRY = re.compile(r"payload entry '([^']*)' size ([0-9a-fA-F]+)")


def first(pat, text, group=1):
    m = pat.search(text)
    if not m:
        return None
    try:
        return m.group(group)
    except IndexError:
        return m.group(0)


def analyse(text):
    r = {}
    for name, pat in PATTERNS:
        r[name] = first(pat, text)
    # 单独收所有 dyld 相关行，便于看上下文
    r['_dyld_lines'] = [l.strip() for l in text.splitlines()
                        if 'dyld' in l and ('cache' in l or 'loaded' in l)][:8]
    # 内核探针（patch-lookup-probe.sh）：dyld 有没有去找共享缓存
    r['_lookups'] = PROBE.findall(text)
    # 载荷解析结果：正常应是 kernel/loader.efi/ramdisk/cmdline 四条。
    # 少于四条或名字异常 = USB 传输把数据弄错位了，这一轮结果不可用。
    r['_payload'] = PAYLOAD_ENTRY.findall(text)
    return r


def verdict(r):
    """返回 (等级, 一句话结论, 建议)。等级：progress / stuck / unknown

    注意一个容易误判的情形：设了 DYLD_SHARED_CACHE_DIR 之后，dyld 不再打印
    `dyld cache '(null)' not loaded`，看上去"报错没了"，但缓存其实仍未装载
    —— launchd 依旧死在 libSystem。所以不能只看 dyld cache 那一条是否存在，
    必须结合 libSystem 是否解析成功来判断。
    """
    if r.get('launchd 启动'):
        return ('progress', 'launchd 已经跑起来（出现 hello, launchd UUID）',
                '下一关是 launchd 加载 job；看日志里第一个失败的 service。')

    # 先排除「这一轮根本没跑对」：载荷在 USB 上错位时，loader 只认出一两个
    # 条目，ramdisk 条目丢失会让 rd_size=0，驻留区于是被当成普通 ramdisk，
    # 5 GB 的 ramdisk 直接把 kernel 的 kmem_range_init 撑爆。
    # 那个 panic 看起来像内核/镜像问题，其实与两者都无关 —— 必须挡在这里，
    # 否则会把一次传输抖动误读成内核回归。
    ents = r.get('_payload') or []
    names = [n for n, _ in ents]
    if ents and (len(ents) < 4 or 'ramdisk' not in names):
        return ('invalid',
                f"载荷传输损坏：loader 只解析出 {len(ents)} 条 {names}，缺 ramdisk",
                '不要看后面的 panic —— 那是负载错位的连带结果'
                '（rd_size=0 → 驻留区被当普通 ramdisk → kmem_range_init panic）。'
                '与内核、镜像大小都无关，重跑一次即可。')

    env_hit = bool(r.get('exec_env 注入'))
    env_note = '（exec_env 注入已生效）' if env_hit else ''

    # 缓存这一关是否真的过了：libSystem 从缓存解析成功 = 过了
    libsys = r.get('libSystem 解析')

    if libsys:
        # 内核探针给出的关键区分：dyld 到底有没有去查缓存文件
        lk = r.get('_lookups') or []
        if lk:
            uniq = sorted(set(lk))
            more = '：' + '、'.join(uniq[:3]) + ('…' if len(uniq) > 3 else '')
            return ('stuck',
                    f'dyld **确实**查找了缓存文件（探针 {len(lk)} 次，{len(uniq)} 种）'
                    f'{more}{env_note}，但仍未装载：libSystem 解析失败',
                    '问题不在"找不找"，在"找到之后"：缓存头校验、子缓存预检、'
                    '或 vm 映射。下一步在 mapSplitCacheSystemWide 的失败分支加探针。')
        if r.get('dyld cache 路径') is None:
            return ('stuck',
                    f'dyld 从未查找缓存文件（探针 0 命中），libSystem 解析失败{env_note}',
                    '前提：所用内核确实带 patch-lookup-probe（否则 0 命中不代表没查）。'
                    '若内核带探针，则 dyld 在更早就放弃了：方向转向 cryptex 路径解析、'
                    '或 ProcessConfig 对平台二进制的 DYLD_* 过滤。')
        return ('stuck',
                f"dyld 报缓存 '{r.get('dyld cache 路径')}' 未装载，libSystem 解析失败{env_note}",
                '看 errorMessage：open() failed 查文件与权限；dynamic config 查 .dylddata 子缓存。')

    if r.get('dyld cache 路径') is None and not r.get('ignition 完成'):
        return ('unknown', '没有 dyld 缓存相关日志，无法判断',
                '确认日志是否抓全（loader-log.txt 是否为空）。')

    return ('progress', f'libSystem 已解析，dyld 这一关过了{env_note}',
            '继续看 launchd 主体是否起来。')


def build_report(rundir, logpath, r, lvl, msg, adv):
    lines = []
    lines.append('# 上机测试报告\n')
    lines.append(f'- 结果目录：`{rundir}`')
    lines.append(f'- 日志文件：`{logpath}`（{os.path.getsize(logpath)} 字节）' if logpath else '- 日志文件：**缺失**')
    lines.append(f'- 结论等级：**{lvl}**\n')
    lines.append(f'## 结论\n\n{msg}\n')
    lines.append(f'## 建议\n\n{adv}\n')
    lines.append('## 关键特征\n')
    lines.append('| 特征 | 值 |')
    lines.append('|---|---|')
    for name, _ in PATTERNS:
        v = r.get(name)
        cell = str(v).replace('|', '\\|') if v not in (None, '') else '—'
        if len(cell) > 90:
            cell = cell[:90] + '…'
        lines.append(f'| {name} | {cell} |')
    lines.append('')
    if r['_payload']:
        lines.append('## 载荷解析（loader 侧）\n')
        lines.append('```')
        for n, sz in r['_payload']:
            lines.append(f"{n:12s} size {sz}  ({int(sz, 16)})")
        lines.append('```\n')
    if r['_lookups']:
        lines.append('## 内核探针：dyld 查找缓存文件\n')
        lines.append(f'命中 {len(r["_lookups"])} 次：\n')
        lines.append('```')
        for n in r['_lookups'][:20]:
            lines.append(n)
        if len(r['_lookups']) > 20:
            lines.append(f'…（另有 {len(r["_lookups"]) - 20} 条）')
        lines.append('```\n')
    if r['_dyld_lines']:
        lines.append('## dyld 相关行\n')
        lines.append('```')
        lines.extend(r['_dyld_lines'])
        lines.append('```\n')
    if r.get('panic'):
        lines.append('## panic\n')
        lines.append('```')
        lines.append(r['panic'])
        lines.append('```\n')
    return '\n'.join(lines)


def main():
    ap = argparse.ArgumentParser(description='分析上机测试日志')
    ap.add_argument('rundir', nargs='?')
    ap.add_argument('--quiet', action='store_true')
    a = ap.parse_args()

    rundir = a.rundir or newest_rundir()
    if not rundir or not os.path.isdir(rundir):
        print('找不到结果目录（out/run-resident 下为空）', file=sys.stderr)
        return 2

    logpath, text = read_log(rundir)
    if not text:
        print(f'{rundir} 里没有可用日志', file=sys.stderr)
        return 2

    r = analyse(text)
    lvl, msg, adv = verdict(r)
    report = build_report(rundir, logpath, r, lvl, msg, adv)
    out = os.path.join(rundir, 'REPORT.md')
    open(out, 'w', encoding='utf-8').write(report)

    if not a.quiet:
        print(report)
        print(f'\n（已写入 {out}）')

    return 0 if lvl == 'progress' else 1


if __name__ == '__main__':
    sys.exit(main())
