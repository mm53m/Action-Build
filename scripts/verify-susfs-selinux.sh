#!/usr/bin/env bash
# 校验「FinaSU selinux_hide × SUSFS」共存契约是否同时成立。
#
# 用法（在 kernel_workspace 目录执行，且 SUSFS 主补丁已 patch 完成）：
#   bash verify-susfs-selinux.sh <kernel_root> <finasu_dir>
#     <kernel_root>  repo 根，内部含 common/（= $KERNEL_ROOT）
#     <finasu_dir>   FinaSU 源码目录（含 kernel/）
#
# 退出码 0 = 契约完整；非 0 = 打印 ::error:: 并失败，避免"静默退化"。
set -uo pipefail

KROOT=${1:-$PWD}
FINASU=${2:-$(dirname "$KROOT")/FinaSU}
# 兼容两种传参：$KROOT 直接指向内核根（含 security/selinux 的那个目录），
# 或指向 kernel_platform（内部还有一层 common/）。
if [ -d "$KROOT/security/selinux" ] && [ ! -d "$KROOT/common" ]; then
  COMMON="$KROOT"
else
  COMMON="$KROOT/common"
fi
fail=0

err() { echo "::error::$*" >&2; fail=1; }
ok()  { echo "  ok  $*"; }

echo "== 1. SUSFS 内核侧（50_add 主补丁）SELinux 钩子 =="
[ -d "$COMMON" ] || { echo "::error::找不到 $COMMON（传参应为内核根或 kernel_platform）"; exit 1; }

need_grep() { # file pattern desc
  if grep -qE "$2" "$1" 2>/dev/null; then ok "$3"; else err "$3 缺失（$1 未匹配 /$2/）"; fi
}

# —— 两代补丁共同契约 ——
need_grep "$COMMON/security/selinux/hooks.c" \
  'LSM_HOOK_INIT\(setprocattr, *handle_selinux_setprocattr\)' \
  "hooks.c: setprocattr 已切到 handle_selinux_setprocattr"

need_grep "$COMMON/security/selinux/hooks.c" \
  'static int handle_selinux_setprocattr' \
  "hooks.c: handle_selinux_setprocattr 已内联"

need_grep "$COMMON/security/selinux/selinuxfs.c" \
  'handle_sel_write_context' \
  "selinuxfs.c: write_op[context] 已被接管"

need_grep "$COMMON/security/selinux/selinuxfs.c" \
  'handle_sel_write_access' \
  "selinuxfs.c: write_op[access] 已被接管"

need_grep "$COMMON/security/selinux/selinuxfs.c" \
  'extern struct page \*fake_status' \
  "selinuxfs.c: 引用 FinaSU 的 fake_status（伪 status 页）"

need_grep "$COMMON/security/selinux/selinuxfs.c" \
  'fake_status_initialize_key' \
  "selinuxfs.c: 引用 fake_status_initialize_key"

need_grep "$COMMON/security/selinux/selinuxfs.c" \
  'ksu_selinux_hide_running' \
  "selinuxfs.c: 以 ksu_selinux_hide_running 门控"

need_grep "$COMMON/security/selinux/status.c" \
  'susfs_is_current_ksu_domain' \
  "status.c: ksud setenforce/policyload 不推进可见 sequence"

need_grep "$COMMON/security/selinux/avc.c" \
  'susfs_is_avc_log_spoofing_enabled' \
  "avc.c: avc 日志 tsid 可伪装"

# —— 老补丁（2026-10-29 之前形态）专用：setprocattr 走 my_setprocattr ——
if grep -q 'my_setprocattr' "$COMMON/security/selinux/hooks.c" 2>/dev/null; then
  need_grep "$COMMON/security/selinux/hooks.c" 'my_setprocattr' "hooks.c: my_setprocattr 形态（老补丁）"
  need_grep "$COMMON/security/selinux/selinuxfs.c" 'fake_state' \
    "selinuxfs.c: 引用 fake_state（老补丁伪策略）"
else
  # —— 新补丁（2026-10-31 61fc8b78 起）专用：backup_sepolicy + access 回填 ——
  need_grep "$COMMON/security/selinux/ss/services.c" \
    'susfs_security_context_to_sid' \
    "services.c: susfs_security_context_to_sid 已内联（按 backup_sepolicy 解析）"
  need_grep "$COMMON/security/selinux/ss/services.c" \
    'susfs_spoof_avd_allowed_rcu|susfs_is_sus_type_rcu' \
    "services.c: access 查询按原策略回填（隐藏 KSU 注入规则）"
fi

echo "== 2. FinaSU 驱动侧符号导出（CONFIG_KSU_SUSFS 分支） =="
SH="$FINASU/kernel/feature/selinux_hide.c"
if [ -f "$SH" ]; then
  # 这三个必须是「非 static」的全局符号，SUSFS 补丁才能 extern 到
  for s in 'struct page \*fake_status = NULL;' 'DEFINE_STATIC_KEY_FALSE\(fake_status_initialize_key\);' \
           '^void initialize_fake_status\(void\)'; do
    if grep -qE "^$s" "$SH"; then
      ok "selinux_hide.c: /$s/ 为全局定义"
    else
      err "selinux_hide.c: /$s/ 不是全局定义（SUSFS 补丁会 undefined symbol）"
    fi
  done
  # 这两个一直是全局（补丁按名字 extern，不看 #ifdef）
  for s in 'bool ksu_selinux_hide_running' 'bool ksu_selinux_hide_enabled'; do
    if grep -qE "^$s" "$SH"; then
      ok "selinux_hide.c: $s 全局可见"
    else
      err "selinux_hide.c: $s 被 static 化（SUSFS 补丁 extern 会失败）"
    fi
  done
  # CONFIG_KSU_SUSFS 下 fake_status 那一组必须是全局版（另一份 static 版在 #else 里）
  if grep -qE 'static (DEFINE_STATIC_KEY_FALSE|struct page \*fake_status)' "$SH"; then
    ok "selinux_hide.c: 存在 #else 的 static 版本（非 SUSFS 形态）"
  fi
  # enable() 在 SUSFS 下必须直接返回 0（钩子由补丁完成），否则会二次 patch
  if awk '/static int ksu_selinux_hide_enable\(\)/,/^}/' "$SH" | grep -q '#ifdef CONFIG_KSU_SUSFS'; then
    ok "selinux_hide.c: enable() 有 CONFIG_KSU_SUSFS 早退分支"
  else
    err "selinux_hide.c: enable() 缺少 CONFIG_KSU_SUSFS 早退分支（会与补丁钩子冲突）"
  fi
  # backup_sepolicy 是 enables「原始策略解析」的根：没有它，enable() 会 -EAGAIN
  if grep -qE '^struct selinux_policy \*backup_sepolicy;' "$FINASU/kernel/selinux/rules.c" 2>/dev/null; then
    ok "rules.c: backup_sepolicy 全局定义（可带 SUSFS 新形态补丁）"
  else
    err "rules.c: 未找到 backup_sepolicy 定义（SUSFS 新形态补丁无处挂载）"
  fi
  if grep -q 'build_feature_handlers()' "$SH" || grep -q 'KSU_FEATURE_SELINUX_HIDE' "$SH"; then
    ok "selinux_hide.c: 注册了 KSU_FEATURE_SELINUX_HIDE"
  else
    err "selinux_hide.c: 未注册 KSU_FEATURE_SELINUX_HIDE"
  fi
else
  err "缺 $SH"
fi

echo "== 3. Kbuild / Kconfig 接线 =="
grep -q 'feature/selinux_hide.o' "$FINASU/kernel/Kbuild" && ok "Kbuild: feature/selinux_hide.o 已编入" \
  || err "Kbuild: feature/selinux_hide.o 未编入"
grep -q 'susfs_init();' "$FINASU/kernel/core/init.c" && ok "init.c: 调用 susfs_init()" \
  || err "init.c: 未调用 susfs_init()"
grep -q '^config KSU_SUSFS$' "$FINASU/kernel/Kconfig" && ok "Kconfig: 有 KSU_SUSFS 菜单" \
  || err "Kconfig: 缺 KSU_SUSFS"

echo "== 4. 本次构建 .config（若已生成） =="
CFG="$KROOT/common/out/.config"
[ -f "$CFG" ] || CFG="$KROOT/out/.config"
if [ -f "$CFG" ]; then
  for k in CONFIG_KSU=y CONFIG_KSU_SUSFS=y CONFIG_SECURITY_SELINUX=y \
           CONFIG_SECURITY_SELINUX_DEVELOP=y CONFIG_KPROBES=y CONFIG_KALLSYMS_ALL=y; do
    grep -qx "$k" "$CFG" && ok "$k" || err "$k 未生效"
  done
  for k in KSU_SUSFS_SUS_PATH KSU_SUSFS_SUS_MAP KSU_SUSFS_SUS_MOUNT KSU_SUSFS_SUS_KSTAT \
           KSU_SUSFS_SPOOF_UNAME KSU_SUSFS_ENABLE_LOG KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
           KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG KSU_SUSFS_OPEN_REDIRECT; do
    grep -qx "CONFIG_$k=y" "$CFG" && ok "CONFIG_$k=y" || err "CONFIG_$k 未生效（olddefconfig 丢弃？）"
  done
  if grep -qx 'CONFIG_KSU_HOOK_SUSFS_INLINE=y' "$CFG"; then
    ok "hook 后端 = SUSFS Inline"
  elif grep -qx 'CONFIG_KSU_HOOK_TRACEPOINT=y' "$CFG"; then
    echo "  warn hook 后端 = Tracepoint（可用但不如 Inline 干净）"
  fi
else
  echo "  skip .config 尚未生成"
fi

echo
if [ "$fail" -ne 0 ]; then
  echo "::error::SELinux×SUSFS 共存契约校验失败，请勿发布该产物" >&2
  exit 1
fi
echo "SELinux×SUSFS 共存契约校验通过"
