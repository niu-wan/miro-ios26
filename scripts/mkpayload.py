#!/usr/bin/env python3
"""XNUP 载荷打包/检视工具（离线，不联网）。

XNUP 是 xnuloader 认的 payload 容器。格式（本机实测校正过，不是推测）：

  头部    "XNUP" + u32 total_size        total_size = 文件长度 - 8
  条目    char name[16] + u32 size + u32 reserved + size 字节数据
  结束    全零的 name[16] + u32 0 + u32 0

三个容易踩错的点，都在这里固化成代码：

1. **条目之间没有 16 字节对齐填充**。数据紧接着下一个条目的 name[16] 开始。
   按 16 对齐去解析，会把下一个条目的 size 字段读错（实测把 ramdisk 的
   4 MB 读成了 150 MB）。

2. **条目名可以为空**。空名不等于结束；结束的标志是 size == 0。
   ramdisk 条目在部分载荷里就是空名。

3. **loader 打印的 size 是十六进制**。日志里 `payload entry 'kernel' size 14db760`
   指的是 0x14db760 = 21,870,432，别当成十进制。

用法：
    # 看结构
    ./mkpayload.py list out/payload-kernel-arm64e-rd.bin

    # 把 kernel 条目换成新内核，其余条目（loader.efi / ramdisk / cmdline）原样保留
    ./mkpayload.py replace --src out/payload-kernel-arm64e-rd.bin \\
                           --entry kernel --with mach.development.bcm2837 \\
                           --out out/payload-local-envp.bin

    # 直接从内核 + 基准载荷生成（等价于上面，路径写死成项目约定）
    ./mkpayload.py build --kernel <mach.development.bcm2837> --out out/payload-local-envp.bin
"""
import argparse
import os
import struct
import sys

MAGIC = b'XNUP'
HDR = 8
ENT = 24  # name[16] + size(4) + reserved(4)


def parse(path):
    """返回 [(name_bytes, data_bytes), ...]，按文件里的顺序。"""
    d = open(path, 'rb').read()
    if d[:4] != MAGIC:
        raise SystemExit('%s: 不是 XNUP（头是 %r）' % (path, d[:4]))
    declared = struct.unpack_from('<I', d, 4)[0]
    if declared != len(d) - HDR:
        print('  警告：头部声明 %d，实际 %d（按实际处理）' % (declared, len(d) - HDR),
              file=sys.stderr)
    off, out = HDR, []
    while off + ENT <= len(d):
        name = d[off:off + 16]
        size, _ = struct.unpack_from('<II', d, off + 16)
        if size == 0:
            break
        if off + ENT + size > len(d):
            raise SystemExit('条目 @%d size=%d 越界' % (off, size))
        out.append((name, d[off + ENT: off + ENT + size]))
        off = off + ENT + size          # 注意：无对齐填充
    return out


def write(path, entries):
    buf = bytearray(MAGIC + b'\0\0\0\0')
    for name, data in entries:
        if len(name) > 16:
            raise SystemExit('条目名超过 16 字节: %r' % name)
        buf += name.ljust(16, b'\0')
        buf += struct.pack('<II', len(data), 0)
        buf += data
    buf += b'\0' * 16 + struct.pack('<II', 0, 0)
    struct.pack_into('<I', buf, 4, len(buf) - HDR)
    with open(path, 'wb') as f:
        f.write(buf)
    return len(buf)


def name_of(raw):
    return raw.split(b'\0')[0].decode('utf-8', 'replace') or '(空名)'


def do_list(a):
    ents = parse(a.src)
    total = os.path.getsize(a.src)
    print('%s  %d 字节  %d 条目' % (a.src, total, len(ents)))
    for i, (name, data) in enumerate(ents):
        extra = ''
        if name_of(name) == 'cmdline':
            extra = '  = %r' % data.rstrip(b'\0').decode('utf-8', 'replace')
        print('  [%d] %-14s size=%-10d (0x%x)%s'
              % (i, name_of(name), len(data), len(data), extra))


def do_replace(a):
    ents = parse(a.src)
    new = open(a.with_file, 'rb').read()
    hit = False
    out = []
    for raw, data in ents:
        if name_of(raw) == a.entry:
            out.append((raw, new))
            hit = True
        else:
            out.append((raw, data))
    if not hit:
        raise SystemExit('%s 里没有名为 %r 的条目（现有：%s）'
                         % (a.src, a.entry, ', '.join(name_of(n) for n, _ in ents)))
    n = write(a.out, out)
    print('  %s: %d → %d 字节（替换 %s 为 %d 字节）'
          % (a.out, os.path.getsize(a.src), n, a.entry, len(new)))


def do_build(a):
    base = a.base
    if not os.path.isfile(base):
        raise SystemExit('缺基准载荷 %s' % base)
    ents = parse(base)
    kn = open(a.kernel, 'rb').read()
    out = [(raw, kn if name_of(raw) == 'kernel' else d) for raw, d in ents]
    if not any(name_of(r) == 'kernel' for r, _ in out):
        raise SystemExit('基准载荷里没有 kernel 条目')
    n = write(a.out, out)
    print('  %s: %d 字节（kernel=%d）' % (a.out, n, len(kn)))


def do_cmdline(a):
    """改 cmdline 条目。内核侧 exec_env=NAME:VAR=VALUE 就是在命令行里注入环境变量，
    改这里不需要重编内核，秒级生效。"""
    ents = parse(a.src)
    payload = a.text.encode() + b'\0'
    if b' ' in a.text.encode():
        pass  # 允许空格：多个 boot-arg 用空格分隔
    hit = False
    out = []
    for raw, data in ents:
        if name_of(raw) == 'cmdline':
            out.append((raw, payload))
            hit = True
        else:
            out.append((raw, data))
    if not hit:
        # 没有 cmdline 条目就追加一个
        out.append((b'cmdline'.ljust(16, b'\0'), payload))
    n = write(a.out, out)
    print('  %s: cmdline = %r（%d 字节，含 NUL）' % (a.out, a.text, len(payload)))
    print('  文件 %d 字节' % n)


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    p = argparse.ArgumentParser(description='XNUP 载荷打包/检视（离线）')
    sub = p.add_subparsers(dest='cmd', required=True)

    l = sub.add_parser('list', help='列出条目')
    l.add_argument('src')
    l.set_defaults(fn=do_list)

    r = sub.add_parser('replace', help='替换某个条目的数据')
    r.add_argument('--src', required=True)
    r.add_argument('--entry', required=True)
    r.add_argument('--with', dest='with_file', required=True)
    r.add_argument('--out', required=True)
    r.set_defaults(fn=do_replace)

    b = sub.add_parser('build', help='用新内核 + 基准载荷生成')
    b.add_argument('--kernel', required=True)
    b.add_argument('--base', default=os.path.join(root, 'out', 'payload-kernel-arm64e-rd.bin'))
    b.add_argument('--out', required=True)
    b.set_defaults(fn=do_build)

    c = sub.add_parser('cmdline', help='设置 cmdline 条目（可注入 exec_env= 等 boot-arg）')
    c.add_argument('--src', required=True)
    c.add_argument('--text', required=True)
    c.add_argument('--out', required=True)
    c.set_defaults(fn=do_cmdline)

    a = p.parse_args()
    a.fn(a)


if __name__ == '__main__':
    main()
