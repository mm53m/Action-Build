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

## 参数清单（Actions → Run workflow 里逐个选）

| 参数 | 类型 | 默认 | 含义 |
| --- | --- | --- | --- |
| `FILE` | choice | `oneplus_15` | 机型配置。格式 `机型_变体`，一加 Ace 2 = `oneplus_ace2_b`（`_b` 只是变体后缀，`FILE_CONF` 会剥掉，`FILE_BASE=OnePlusAce2`） |
| `KSU_META` | string | `master/master/` | `管理器ref/内置ref/回退hash` |
| `FAST_BUILD` | bool | `true` | 极速构建（走 `Build Kernel FAST`，失败自动回退普通构建） |
| `KPM` | choice | `KPN` | 内核模块实现：`KPM` 开启 / `KPN` 关闭 / `N/A` 不处理 |
| `LSM_BBG` | bool | `true` | BBG 关键分区写入保护模块 |
| `NETFILTER` | bool | `true` | 网络功能扩展（netfilter 相关补丁） |
| `CCM` | bool | `true` | 拥塞控制 BBRv1+BBRv3+ECN |
| `DROID_SPACES` | bool | `false` | DroidSpaces 轻量容器支持 |
| `RE_KERNEL` | bool | `false` | Re-Kernel 补丁 |
| `LZ4_UPDATE` | bool | `false` | 升级 lz4 到上游最新 |
| `ZRAM` | string | `0/lz4kd/8589934592` | `开关/算法/大小`，`0` 关闭 |
| `SUSFS_META` | string | 空 | SUSFS 回退：`hash` / `HEAD~N` 的数字 N / `-1` 关闭 SUSFS |
| `SUSFS_CI` | choice | `CI` | SUSFS 模块从 CI 还是 Release 拉 |
| `SUSFS_DEV` | bool | `false` | 用 SUSFS 的 `-dev` 分支 |
| `SCHED_HMBIRD` | bool | `false` | 风驰调度（HMBIRD）驱动 1.0 |
| `UNICODE_BYPASS` | bool | `false` | Unicode 不可见码点绕过修复 |
| `SUFFIX` | string | 空 | 自定义内核后缀（空=RAND_STR，`-1` 关闭） |
| `RESUBLEVEL` | string | 空 | 内核 SUBLEVEL 欺骗 |
| `DYNAMIC_REPO` | string | `Numbersf` | 动态清单仓库 owner |
| `BUILD_TIME` | string | 固定值 | 内核构建时间戳（`F`=当前 UTC，`-1` 关闭） |
| `SPACE_NOCLEAN` | bool | `false` | 停用空间清扫 |
| `BUILD_NOCACHE` | bool | `false` | 本次不用缓存 |

### 一加 Ace 2 的常用组合

```
FILE=oneplus_ace2_b  KSU_META=master/master/  FAST_BUILD=true
KPM=KPN  LSM_BBG=true  NETFILTER=true  CCM=true
DROID_SPACES=true  RE_KERNEL=true  LZ4_UPDATE=true
ZRAM=0/lz4kd/8589934592  SUSFS_META=（空，跟随最新）
```

## 固定构建方案（一加 Ace 2，所有构建都用这套）

从首次构建（run 42739973829，job 名 `[FAST] [BBG] [DS] [REKER] [LZ4UPD] For oneplus_ace2_b`）反解出来的完整参数，作为默认方案固定下来：

| 参数 | 值 | 依据 |
| --- | --- | --- |
| `FILE` | `oneplus_ace2_b` | job 名 `For oneplus_ace2_b` |
| `FAST_BUILD` | `true` | `[FAST]` |
| `LSM_BBG` | `true` | `[BBG]` |
| `DROID_SPACES` | `true` | `[DS]` |
| `RE_KERNEL` | `true` | `[REKER]` |
| `LZ4_UPDATE` | `true` | `[LZ4UPD]` |
| `KPM` | **`N/A`** | 既无 `[KPM]` 也无 `[KPN]` 标签 → 只有 `N/A` 符合 |
| `ZRAM` | `0/lz4kd/8589934592` | 无 `[ZRAM]` 标签 → 不是 `1/` 开头，保持默认关闭 |
| `KSU_META` | `master/master/` | 跟随 FinaSU 最新 |
| `SUSFS_META` | 空 | 跟随最新 SUSFS |
| `SUSFS_CI` | `CI` | 默认 |
| `SCHED_HMBIRD` | `false` | 无 `[HMBIRD]` |
| `UNICODE_BYPASS` | `false` | 默认 |
| `SUFFIX` / `RESUBLEVEL` | 空 | job 名 `For oneplus_ace2_b ` 后无后缀 |
| `NETFILTER` / `CCM` | `true` | 默认 |
| `DYNAMIC_REPO` | `Numbersf` | 默认 |
| `BUILD_TIME` | `Wed Jul 15 11:18:49 UTC 2026` | 默认 |
| `SPACE_NOCLEAN` / `BUILD_NOCACHE` | `false` | 默认 |

一键触发脚本：[`scripts/dispatch-ace2.sh`](../scripts/dispatch-ace2.sh)（`GITHUB_TOKEN=xxx ./scripts/dispatch-ace2.sh`，`DRY_RUN=1` 只打印 payload）。
