# FinaSU 的 `selinux_hide` 与 SUSFS 如何共存（源码级说明）

> 结论先写：**两者不是"互斥"，而是"分工"。** 与 SUSFS 一起编译时，FinaSU 不再自己
> patch `write_op[]`、不再自己 hook `sel_handle_status_ops`——这两件事**交给 SUSFS 的
> `50_add_susfs_in_gki-*.patch` 在 `security/selinux/` 里内联完成**；FinaSU 只负责
> 导出状态变量与伪 status 页，并在 `ksu_selinux_hide_enable()` 里直接返回 0。
> 最终效果：SUSFS 全功能 + SELinux 完整隐藏，同时成立。

---

## 1. 分工表

| 能力 | 谁实现 | 位置 | 生效条件 |
| --- | --- | --- | --- |
| `selinux_state` 读写策略切换（伪 status 页） | FinaSU 提供页 / SUSFS 补丁接管入口 | `feature/selinux_hide.c` 导出 `fake_status`；补丁改 `sel_open_handle_status` | `ksu_selinux_hide_running` 为真 |
| `/sys/fs/selinux/context` 按**原始策略**解析 | SUSFS 补丁内联 | `security/selinux/selinuxfs.c` → `write_op[SEL_CONTEXT] = handle_sel_write_context` → `susfs_sel_write_context()` | 同上 + `current_uid >= 10000` |
| `/sys/fs/selinux/access` 按**原始策略**算 AV | SUSFS 补丁内联 | `write_op[SEL_ACCESS] = handle_sel_write_access` → `susfs_sel_write_access()` | 同上 |
| `setprocattr`（`echo u:r:su:s0 > /proc/self/attr/current`）不被审计暴露 | SUSFS 补丁内联 | `security/selinux/hooks.c`：`LSM_HOOK_INIT(setprocattr, handle_selinux_setprocattr)` | 同上 |
| `setenforce` / `policyload` 不推进可见 sequence | SUSFS 补丁内联 | `security/selinux/status.c` 的 `selinux_status_update_setenforce/policyload` | `susfs_is_current_ksu_domain()` |
| `sidtab` 双策略同步（KernelSU 注入的 type 在原始策略里不存在时回退） | **FinaSU 主体** | `security_context_to_sid_with_policy(backup_sepolicy, ..., &orig_sid_p, &orig_rc_p)` | 始终 |
| avc 日志里 `su` 的 tsid 伪装 | SUSFS 补丁内联 | `security/selinux/avc.c` 的 `avc_audit_post_callback`（`susfs_is_avc_log_spoofing_enabled` static key） | `ksu_susfs enable_avc_log_spoofing 1` |
| avc 日志 tsid 的**另一条**影子路径 | FinaSU kprobe | `feature/avc_spoof.c`（`slow_avc_audit`） | `ksud feature set avc_spoof 1` |

两条 avc 路径互不冲突，可叠加。

---

## 2. 关键代码契约（编译期）

### 2.1 FinaSU 侧：`#ifdef CONFIG_KSU_SUSFS` 分支只导出、不 patch

`feature/selinux_hide.c`：

```c
#ifdef CONFIG_KSU_SUSFS
DEFINE_STATIC_KEY_FALSE(fake_status_initialize_key);
struct page *fake_status = NULL;
void initialize_fake_status(void)          // ← 全局，供 selinuxfs.c extern
#else
static DEFINE_STATIC_KEY_FALSE(fake_status_initialize_key);
static struct page *fake_status = NULL;
static void initialize_fake_status(void)
#endif
```

```c
static int ksu_selinux_hide_enable()
{
    if (!backup_sepolicy)
        return -EAGAIN;
#ifdef CONFIG_KSU_SUSFS
    return 0;                 // ← 钩子已由 SUSFS 补丁装好，这里什么都不做
#else
    selinux_write_op = find_kernel_symbol_exact("write_op");
    ... ksu_patch_text(...)   // 非 SUSFS 时才自己 patch
#endif
}
```

`bool ksu_selinux_hide_running / ksu_selinux_hide_enabled` 始终是全局变量（无 `static`），
SUSFS 补丁直接 `extern` 它们做门控。

### 2.2 SUSFS 补丁侧：引用 FinaSU 的符号

`security/selinux/selinuxfs.c` 顶部：

```c
#ifdef CONFIG_KSU_SUSFS
extern struct page *fake_status;
extern struct static_key_false fake_status_initialize_key;
extern bool ksu_selinux_hide_running __read_mostly;
extern bool ksu_selinux_hide_enabled __read_mostly;
extern void initialize_fake_status(void);
...
#endif
```

`security/selinux/hooks.c`：

```c
static int handle_selinux_setprocattr(const char *name, void *value, size_t size)
{
    if (likely(!strcmp(name, "current") &&
               current_uid().val >= 10000 &&
               ksu_selinux_hide_running))
        return susfs_selinux_setprocattr(name, value, size);
    return selinux_setprocattr(name, value, size);
}
...
#ifdef CONFIG_KSU_SUSFS
    LSM_HOOK_INIT(setprocattr, handle_selinux_setprocattr),
#else
    LSM_HOOK_INIT(setprocattr, selinux_setprocattr),
#endif
```

注意：SUSFS 补丁**替换**了 `setprocattr` 的槽位（不是链式追加），所以 FinaSU 在
`CONFIG_KSU_SUSFS` 下**必须**放弃自己的 `ksu_lsm_hook(&selinux_setprocattr_hook)`
（`ksu_selinux_hide_unhook()` 里也是 `#ifndef CONFIG_KSU_SUSFS` 才 unhook）。

### 2.3 顺序：先 patch 内核，再编译驱动

链路是「内核 `security/selinux/*.c` 引用驱动符号」→ 只要 `CONFIG_KSU=y`（内建进
vmlinux）且 `CONFIG_KSU_SUSFS=y`，链接期即可解析。**驱动侧不要再打**
`susfs4ksu` 的 `10_enable_susfs_for_ksu.patch`（那个补丁面向上游 KernelSU 的手动钩子
模型，会把 `hook/tp_marker.o` 等编译单元移出 Kbuild，而 FinaSU 的 kprobe 模型仍引用
这些符号 → vmlinux 链接 undefined symbol）。

---

## 3. 构建配置（缺一不可）

```config
CONFIG_KSU=y                 # 必须内建；LKM 形态拿不到导出的驱动符号
CONFIG_KSU_SUSFS=y           # 驱动侧原生 SUSFS + 上面的 else 分支关闭
CONFIG_KALLSYMS_ALL=y
CONFIG_KPROBES=y
CONFIG_EXT4_FS=y
CONFIG_HEADERS_INSTALL=y
CONFIG_SECURITY_SELINUX=y
CONFIG_SECURITY_SELINUX_DEVELOP=y   # setenforce 需要
CONFIG_KSU_HOOK_SUSFS_INLINE=y      # 可选：走补丁提供的直连入口，替代 tracepoint
```

`CONFIG_KSU_SUSFS` 九个功能项（`KSU_SUSFS_SUS_PATH` / `SUS_MAP` / `SUS_MOUNT` /
`SUS_KSTAT` / `SPOOF_UNAME` / `ENABLE_LOG` / `HIDE_KSU_SUSFS_SYMBOLS` /
`SPOOF_CMDLINE_OR_BOOTCONFIG` / `OPEN_REDIRECT`）与隐藏能力无关，但影响检测面，建议全开。

> `CONFIG_KSU_HOOK_SUSFS_INLINE` 需要补丁真的把 `ksu_handle_*` 入口点插进了
> `fs/exec.c`、`fs/open.c`、`fs/stat.c`、`fs/read_write.c`、`drivers/input/input.c`、
> `kernel/reboot.c`、`kernel/sys.c`。打开前跑一遍
> `KernelSU/kernel/tools/check_susfs_inline.sh <kernel_dir>`，它会逐条校验
> `require_hook` / `reject_hook`；不通过就留在 tracepoint 后端（功能等价，实现更"脏"）。

---

## 4. 运行时启用顺序（重要）

隐藏是**运行时开关**，不是编译后就自动生效：

```bash
# 1) 先在管理器里"保存功能"，让 KernelSU 生成 backup_sepolicy（注入 su 规则时顺带备份原始策略）
#    重启一次，确保 backup_sepolicy 存在，否则 ksu_selinux_hide_enable() 返回 -EAGAIN
# 2) 打开 SELinux 隐藏
su -c 'ksud feature set selinux_hide 1'
su -c 'ksud feature get selinux_hide'      # 期望 1

# 3) 打开 SUSFS 的 avc 日志伪装
su -c 'ksu_susfs enable_avc_log_spoofing 1'
#    （可选，叠加 FinaSU 的 kprobe 版本）
su -c 'ksud feature set avc_spoof 1'

# 4) 持久化：/data/adb/modules/susfs4ksu/config.sh 里 avc_log_spoofing=1
```

验证：

```bash
# 普通 App（uid >= 10000）视角：应看到"原始"策略
su -c 'cat /sys/fs/selinux/status'                 # sequence / policyload 不应因 ksud 操作增长
# 用普通 shell（非 root）执行下面两条，应当查不到 KernelSU 注入的 allow
/sys/fs/selinux/access u:r:zygote:s0 u:object_r:system_file:s0 file read
# dmesg 里确认开关状态
su -c 'dmesg | grep -iE "selinux_hide|avc_log_spoof|fake_status"'
# 期望看到：
#   selinux_hide: set to 1
#   initialize_fake_status initialized: sequence=..., policyload=..., enforcing=1
```

---

## 5. 常见失败模式

| 现象 | 原因 | 处置 |
| --- | --- | --- |
| `ksud feature set selinux_hide 1` 返回 `-EAGAIN` | 没有 `backup_sepolicy`（从未经 KernelSU 注入规则/未保存功能） | 管理器里保存一次功能 → 重启 → 重试 |
| 链接报 `undefined symbol: fake_status` | 驱动侧打了 `10_enable_susfs_for_ksu.patch`，把 `feature/selinux_hide.o` 的全局版遮住了 | 删掉该补丁的应用 |
| 隐藏开着但 `/sys/fs/selinux/access` 仍看到 KSU allow | 调用进程 uid < 10000（root shell 自己）→ 门控放行原逻辑 | 用普通 App 或 uid>=10000 的进程验证 |
| `cat /sys/fs/selinux/status` sequence 每次 ksud 操作都涨 | `status.c` 的补丁没打上 | 核对 `selinux_status_update_setenforce` 里有 `susfs_is_current_ksu_domain()` |
| `dmesg` 里 avc 仍显示 `tcontext=u:r:su:s0` | avc 伪装两条路径都没开 | `ksu_susfs enable_avc_log_spoofing 1` + `ksud feature set avc_spoof 1` |
| setprocattr 失败（`echo ... > attr/current`） | 用了 SUSFS 补丁的 `handle_selinux_setprocattr` 但 `ksu_selinux_hide_running=0` | 先开 `selinux_hide` |

---

## 6. 与"FinaSU 不带 SUSFS"形态的差异

| 项目 | 不带 SUSFS | 带 SUSFS（本文档形态） |
| --- | --- | --- |
| `write_op[]` 接管 | FinaSU `ksu_patch_text`（运行时） | SUSFS 补丁（编译期静态表） |
| `sel_handle_status_ops->open` | FinaSU `ksu_patch_text` | SUSFS 补丁内联改写 `sel_open_handle_status` |
| `setprocattr` | FinaSU `ksu_lsm_hook` 替换槽位 | SUSFS 补丁 `LSM_HOOK_INIT` 替换槽位 |
| 伪装策略来源 | FinaSU `backup_sepolicy`（`&fake_state` 旧形态已废弃） | 同上，统一 `backup_sepolicy` + 8 参 `_with_policy` |
| sidtab 同步 | FinaSU 内部（#3877/#3873） | 同上 |
| 内核符号依赖 | `write_op`、`sel_handle_status_ops` 需 `find_kernel_symbol_exact`（KALLSYMS_ALL） | 无需运行时找符号，链接期解析 |

即：SUSFS 形态把"运行时 patch"换成了"编译期静态表"，因此更稳（不依赖 kallsyms 查找、
不受 ro_after_init 限制），代价是补丁必须与内核版本严格匹配（这也正是要把
`susfs4ksu` 分支 pin 到具体 commit 的原因）。
