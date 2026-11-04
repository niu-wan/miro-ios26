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
