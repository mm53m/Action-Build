# 把 GKI_FinaSU 的「SUSFS×SELinux」工程做法适配进 mm53m/Action-Build（FinaSU 分支）

> 适用范围：`.github/workflows/Build Kernel OnePlus.yml`（分支 `FinaSU`，本地副本
> `/root/ab-work/wf-FinaSU.yml`，当前 56 steps）。
>
> **状态：A（pin）与 B（断言）已落地并通过构建验证**（run `42763053546` 成功）。
> C（SUSFS Inline 后端）与 D（第二签名槽）仍为可选，未启用。

## 0. 差距清单（对照 `/root/ref/GKI_FinaSU`）

| # | GKI_FinaSU 做法 | 我们的现状 | 影响 | 处置 |
| --- | --- | --- | --- | --- |
| 1 | `config/config` 里把 SUSFS 分支 pin 到 commit（`gki-android12-5.10=8930474a…`，2026-10-29） | 每次构建 clone `gitlab simonpunk/susfs4ksu` 分支最新（今天 tip `5436438b`，2026-11-09） | 上游 rebase 改变 `security/selinux/*` hunk 形态 → 与 FinaSU 的 `extern`/`->orig_*` 契约错位，链接期 `undefined symbol` 或 `-Werror` 中断 | **pin** |
| 2 | `scripts/susfs_fixes/apply.sh` 的 `verify_finasu_native_susfs()`：9 个 Kconfig + 5 个入口点 + 3 个 `my_*` 符号断言，失败即 `exit 1` | 无任何断言（`patch -p1 … \|\| true` 吞错） | 补丁部分命中/结构漂移时静默退化 | 加 `verify-susfs-selinux.sh` |
| 3 | 优先 `CONFIG_KSU_HOOK_SUSFS_INLINE=y`（`check_susfs_inline.sh` 通过才写，否则 `::warning` 回退） | 固定 `CONFIG_KSU_HOOK_TRACEPOINT=y`（产物 Image 内嵌 config 已证实 `# CONFIG_KSU_HOOK_SUSFS_INLINE is not set`） | 功能等价，但 tracepoint 后端要注册 `sys_enter` tracepoint + 替换 `sys_call_table` 入口，检测面更大 | 可选开启 |
| 4 | `KSU_EXPECTED_SIZE2`/`HASH2` 第二签名槽（官方 FinaSU 管理器 + 自签管理器都能连） | 只有单槽（`Pin FinaSU Manager Signature` 写 `KSU_EXPECTED_SIZE/HASH`） | 装了官方 release 包就连不上内核 | 可选 |
| 5 | `KSU_REQUIRE_PREINIT` 未显式设置（Kbuild 支持） | 我们已在 `MAKE_ARGS` 里传 `KSU_REQUIRE_PREINIT=1` | 更严，保留 | — |
| 6 | `scripts/susfs_fixes/apply.sh` 里针对 5.10.66~209 / 5.15 / 6.1 的上下文修补（`VMA_PAD_START`、`fdinfo.c`、`base.c`） | 无 | 我们 5.10.236 > 209，`VMA_PAD_START` 那条仅在源码缺 `VMA_PAD_START` 时才需要（补丁自身会 `sed`） | 低优先 |

**注意**：`selinux_hide` 本身不需要任何额外移植。GKI_FinaSU 全仓对 SELinux 只有
`build.yml:1286` 一条 `baseband_guard` 的 `sed`，和我们 `wf-FinaSU.yml:1044` 逐字相同；
它也没有任何"启用 selinux_hide"的代码——共存是 FinaSU 上游
（`5b83330b`/`cdf8711a`，2026-10-23）与 SUSFS `50_add` 主补丁之间的既有契约，
详见 `SELINUX-SUSFS-COEXIST.md`。

---

## 1. 补丁 A：pin SUSFS 提交

位置：`wf-FinaSU.yml` 的 `Download SUSFS` 步骤，`git clone … -b gki-…` 之后、
`SUSFS_META` 处理之前（约 794-806 行）。

```yaml
          # 固定 SUSFS 提交，避免上游 rebase 改变 security/selinux/* 的 hunk 形态，
          # 与 FinaSU 的 extern 契约（fake_status / ksu_selinux_hide_running）错位。
          # 取值来自 GKI_FinaSU config/config（2026-10-29 快照）。
          case "${{ env.KANDROID_VERSION }}-${{ env.KERNEL_VERSION }}" in
            12-5.10) SUSFS_PIN=8930474a298d07ab9f1beca926779cbc3656b79e ;;
            13-5.15) SUSFS_PIN=e30f1502a870434150efb16bd4a0d33277d7da57 ;;
            14-6.1)  SUSFS_PIN=ee155a1ad4219804a7c54cb39dd4fa1b5c2a3fa4 ;;
            15-6.6)  SUSFS_PIN=93114563fd6b08092b9ce8c0309738c921ac8bd1 ;;
            16-6.12) SUSFS_PIN=6b60a305d418148bd311f4fc9bddedc82d99e1fc ;;
            *)       SUSFS_PIN="" ;;
          esac
          if [ -n "$SUSFS_PIN" ] && [ -z "${{ github.event.inputs.SUSFS_META }}" ]; then
            git -C susfs4ksu fetch --depth 1 origin "$SUSFS_PIN" \
              && git -C susfs4ksu checkout "$SUSFS_PIN" \
              && echo "✅ SUSFS 已 pin 到 $SUSFS_PIN" \
              || echo "::warning title=SUSFS pin::无法切换到 $SUSFS_PIN，回退分支最新"
          fi
```

> `SUSFS_META` 非空（手动指定 hash/次数）时不 pin，保留手动能力。

---

## 2. 补丁 B：连通性断言（新增一步）

位置：紧接 `Apply Patches FinaSU`（`patch -p1 < 50_add_susfs…`）之后，编译之前。

```yaml
      - name: Verify SELinux x SUSFS Coexistence
        if: ${{ github.event.inputs.SUSFS_META != '-1' }}
        run: |
          bash "$GITHUB_WORKSPACE/scripts/verify-susfs-selinux.sh" \
               "$PWD" "$PWD/FinaSU"
        working-directory: kernel_workspace
```

配套文件 `scripts/verify-susfs-selinux.sh`（已放 `/root/ab-work/verify-susfs-selinux.sh`，
本地正反用例均已验证：契约完整 → 退出 0；删掉任一钩子 → 打印 `::error::` 并退出 1）。

它检查三组契约：

1. 内核侧：`hooks.c` 的 `handle_selinux_setprocattr`、`selinuxfs.c` 的
   `handle_sel_write_context/access` + `extern struct page *fake_status` +
   `ksu_selinux_hide_running` 门控、`ss/services.c` 的 `susfs_is_sus_type_rcu` /
   `susfs_spoof_avd_allowed_rcu`、`status.c` 的 `susfs_is_current_ksu_domain`、
   `avc.c` 的 `susfs_is_avc_log_spoofing_enabled`。
2. 驱动侧：`selinux_hide.c` 的 `fake_status` / `fake_status_initialize_key` /
   `initialize_fake_status` 必须是**非 static** 全局定义，`ksu_selinux_hide_running` /
   `ksu_selinux_hide_enabled` 全局可见，`enable()` 有 `#ifdef CONFIG_KSU_SUSFS` 早退。
3. Kbuild / Kconfig：`feature/selinux_hide.o` 编入、`init.c` 调 `susfs_init()`、
   `Kconfig` 有 `config KSU_SUSFS`；若 `.config` 已生成，再逐条核对
   `CONFIG_KSU=y`、9 个 `KSU_SUSFS_*`、`SECURITY_SELINUX_DEVELOP` 等是否真的生效。

---

## 3. 补丁 C（可选）：切到 SUSFS Inline 后端

位置：`Add Configuration Settings` 步骤，SUSFS 配置块之后（约 1118 行）。

```yaml
            # hook 后端：补丁已把 ksu_handle_* 入口点内联进 fs/*、kernel/*，
            # 校验通过就选 Inline（不注册 sys_enter tracepoint，检测面更小）
            chmod +x ../FinaSU/kernel/tools/check_susfs_inline.sh 2>/dev/null || true
            if bash ../FinaSU/kernel/tools/check_susfs_inline.sh . >/dev/null 2>&1; then
              set_config "CONFIG_KSU_HOOK_SUSFS_INLINE=y"
              echo "✅ hook 后端 = SUSFS Inline"
            else
              echo "::warning title=SUSFS Inline 回退::内核缺少内联入口点，保留 Tracepoint 后端"
            fi
```

可行性已验证：`50_add_susfs_in_gki-android12-5.10.patch` 里 12 个被
`check_susfs_inline.sh` 要求的入口点全部存在（`ksu_handle_execveat`、
`ksu_handle_execveat_sucompat`、`ksu_handle_post_execveat_sucompat`、
`ksu_setup_preinit_file`、`ksu_preinit_handle_post_execveat`、`ksu_handle_faccessat`、
`ksu_handle_sys_read`、`ksu_handle_stat`、`ksu_handle_vfs_fstat`、
`ksu_handle_sys_reboot`、`ksu_handle_setresuid`、`ksu_handle_input_handle_event`）。

⚠️ 切后端会改变 syscall 钩子的实现路径，必须实机验证 su/模块/隐藏三项都正常，不建议与
其它变量一起改。

---

## 4. 补丁 D（可选）：第二签名槽

位置：`Pin FinaSU Manager Signature` 步骤读证书后，以及 `MAKE_ARGS`。

```bash
# 官方 release 包证书（v1.5.1）
OFFICIAL_SIZE=0x02cc
OFFICIAL_HASH=2d89b50aaf1db013c2b6738f973f48b62ea21a3a8d7216bfec3521065d448458
echo "KSU_EXPECTED_SIZE2=$OFFICIAL_SIZE" >> "$GITHUB_ENV"
echo "KSU_EXPECTED_HASH2=$OFFICIAL_HASH" >> "$GITHUB_ENV"
```

```yaml
          if [[ -n "${KSU_EXPECTED_SIZE2:-}" && -n "${KSU_EXPECTED_HASH2:-}" ]]; then
            MAKE_ARGS+=(KSU_EXPECTED_SIZE2="$KSU_EXPECTED_SIZE2")
            MAKE_ARGS+=(KSU_EXPECTED_HASH2="$KSU_EXPECTED_HASH2")
          fi
```

`Kbuild:241-255` 支持这对变量（`ifdef KSU_EXPECTED_SIZE2` 且缺 hash 时 `$(error)`），
产物镜像里两份证书都算 trusted，装哪个管理器都能连。

---

## 5. 应用顺序建议

1. **A（pin）+ B（断言）** 先上，零行为变更，只降低"构建成功但隐藏失效"的概率。
2. 实机验证：`ksud feature set selinux_hide 1` → `get` 为 1 → 普通 App 视角
   `cat /sys/fs/selinux/status` 与 `access` 查询不再暴露 KSU 规则。
3. 再考虑 **C（Inline）**，单独一次构建 + 实机验证。
4. **D（第二签名槽）** 只在需要"官方包 + 自签包混用"时加。
