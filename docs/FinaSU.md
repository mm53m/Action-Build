# FinaSU 分支（第 5 个管理器）

本分支在原有 4 个管理器分支（`SukiSU-Ultra` / `KernelSU` / `KernelSU-Next` / `BakaSU`）之外，新增 **FinaSU** 作为内核内置的 KSU 驱动管理器，替换掉原来的 KernelSU 驱动集成方式。

- 上游管理器：<https://github.com/LyraVoid/FinaSU>
- 本分支：`mm53m/Action-Build` @ `FinaSU`（基于 `KernelSU` 分支复制，工作流逐步改写）

## 与 KernelSU 分支的差异

| 位置 | 改动 |
| --- | --- |
| `KSU_META` 默认值 | `master/master/`（FinaSU 的管理器 ref / 内置 ref / 手动回退 hash） |
| 拉取方式 | `git clone https://github.com/LyraVoid/FinaSU.git`，`git fetch --tags --force` 后 checkout 指定 ref → **始终跟随上游最新版** |
| 驱动挂载 | 调用 FinaSU 自带的 `kernel/setup.sh --dir <FinaSU>`：把 `FinaSU/kernel` 软链到 `drivers/kernelsu`，并改写 `drivers/Makefile`、`drivers/Kconfig` |
| 版本号 | 与 FinaSU `kernel/Kbuild` 相同公式：`KSU_VERSION = git rev-list --count HEAD + 30000`；版本标识走 `git describe --tags` |
| 内核配置 | 追加 FinaSU 内置集成必需项：`KSU`、`KPROBES`、`KALLSYMS_ALL`、`EXT4_FS`、`HEADERS_INSTALL` |
| 编译参数 | `MAKE_ARGS` 增加 `KSU_REQUIRE_PREINIT=1`，避免 `usr/include` 缺失时 preinit 静默关闭 |
| SUSFS 补丁路径 | `10_enable_susfs_for_ksu.patch` 打到 `kernel_workspace/FinaSU`（不再有 `./KernelSU` 目录） |
| 管理器 APK | 优先取 FinaSU **Release** 的 APK（签名与 `kernel/Kbuild` 内置 `KSU_EXPECTED_SIZE/HASH` 默认值一致），失败再回退 CI 的 `manager-gradle` 产物 |
| 产物命名 | `AnyKernel3_FinaSU_<KSUVER>_<机型>(<内核版本>)_...zip` |

## 使用

工作流 `Build All OnePlus Kernels` 的 `KSU_META` 参数格式不变（三段，`/` 分隔）：

```
管理器 ref / 内置 ref / 手动回退提交 hash(可省略)
master/master/
dev/master/                       # 用 FinaSU 的 dev 分支
master/master/abc1234             # 回退到指定提交
v1.5.1/master/                    # 用 tag
```

`master/master/` 表示管理器层与内置层都用 `master`；只有需要钉住特定分支/提交时才改。

## 已知待验证项（首次运行重点看这几步）

1. **Initialize Repo and Sync** —— 与其它分支一致的常见超时点。
2. **Add FinaSU** —— `setup.sh --dir` 是否在 `kernel_platform` 下正确找到 `common/drivers`。
3. **Apply Patches FinaSU** —— `10_enable_susfs_for_ksu.patch` 对 FinaSU 新版 `kernel/` 的上下文是否仍匹配（`|| true` 会吞掉失败，看 `check_rejects` 输出）。
4. **Build Kernel FAST** —— 首次带 `CONFIG_KALLSYMS_ALL=y` / `KSU_REQUIRE_PREINIT=1` 的编译。
5. **Download Latest FinaSU Manager APK** —— Release 资源名是否仍匹配 `*.apk`。
