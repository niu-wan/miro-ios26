# miro 内核构建（GitHub Actions）

在 macOS runner 上用 Xcode 的 cctools/mig/SDK 编 `xnu-12377.121.6` + HakiOS dada 补丁的 arm64e 内核。

## 怎么用（三条命令，有网络的地方跑）

```bash
# 1. 在 GitHub 建一个空仓库（private 也行），拿到地址
# 2. 把本目录推上去
git init && git add -A && git commit -m "miro kernel build"
git branch -M main
git remote add origin https://github.com/<你>/<仓库>.git
git push -u origin main
# 3. 打开 Actions 页，等 build-miro-kernel 跑完，下载 artifact
```

`workflow_dispatch` 也开着，可以在网页上手动重跑。

## 拿到的东西

`mach.development.bcm2837`（arm64e 内核）+ `.unstripped`（带符号，分析用）。
回来以后：

```bash
./scripts/offline-test.sh /  # 用 mkpayload 把它塞进 payload：
python3 xnuloader/mkpayload.py -o out/payload-miro-kernel.bin \
  kernel=mach.development.bcm2837 loader.efi=/tmp/loader-miro.efi --usb
# 再用 mkxnuimg 打成 boot.img 上机
```

## 说明

- runner 没装 theos：macOS 上 `xnu-build.sh` 会走 `XNU_HOST_DARWIN` 分支，用 Xcode 自带的工具。
- 触摸固件头已经预生成好放在 `focaltech/`，不依赖任何手机数据。
- Xcode 要带 iPhoneOS 26 SDK；workflow 里会挑 `/Applications` 下最新的 Xcode。

---

# iOS 26 用户态抽取（`usermode.yml`）

内核已经编出来了，剩下的是「iOS 用户态数据」——IPSW 里的卷是 AEA 加密的。

## 为什么必须 macOS

| 环节 | 为什么 Linux 不行 |
|---|---|
| 解密 `.dmg.aea` | AEA profile 1，密钥要经 WKMS 取回；macOS 自带 `/usr/bin/aea` 是 Apple 官方实现 |
| 挂载解出来的 APFS | Linux 靠 FUSE，而本机**没有 `/dev/fuse`**；macOS 用 `hdiutil`，原生 |

## 关键技巧：不下 11.4 GB 整包

IPSW 是 ZIP64，但目标 `.dmg.aea` 在 zip 里是 **STORED**（`compress_type=0`），
所以可以按字节区间直取。`scripts/fetch-aea.py` 会：

1. Range 读尾部 → 找 EOCD → 若是 ZIP64 再读 locator/EOCD record；
2. 解析中央目录，读出条目的 header offset / size；
3. 由 local file header 算出数据起点（跳过文件名和 extra）；
4. 分块 Range 下载。

两个目标卷：

| 条目 | 大小 | 内容 |
|---|---|---|
| `094-97204-090.dmg.aea`（`Cryptex1,SystemOS`） | 1.9 GB | dyld 共享缓存（84 个子缓存 + atlas + symbols） |
| `094-95330-090.dmg.aea`（`OS`） | 8.3 GB | rootfs（`/System` `/usr` `/bin`…） |

## 跑法

网页 Actions → `ios26-usermode` → Run workflow → 选 `component`：

- `cryptex`：只抽 dyld 缓存，约 10 分钟，产物 `ios26-dyld-cache`
- `systemos`：抽 rootfs 精简集，约 25 分钟，产物 `ios26-rootfs`
- `both`：两个 job 并行

本地验证过的前提：

- `094-95330-090.dmg.aea` 数据起点 71，魔数 `AEA1` ✓
- `094-97204-090.dmg.aea` 数据起点 9140502237，魔数 `AEA1` ✓
- 两者 `usize == csize`（8388608000 / 2013265920），确认未压缩 ✓

## 磁盘

runner 默认只剩 ~14 GB，所以每个 job 第一步都清 Xcode 的 simulator runtime 和多余 Xcode。
`systemos` job 要 8.3 GB 输入 + 8.3 GB 解密输出，清理后才够。

