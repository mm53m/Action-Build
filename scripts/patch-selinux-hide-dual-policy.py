#!/usr/bin/env python3
"""把 SUSFS 的 SELinux 查询钩子接到 KernelSU(FinaSU) 的双策略实现上。

背景
----
FinaSU 在 CONFIG_KSU_SUSFS=y 时, ksu_selinux_hide_enable() 里直接
``#ifdef CONFIG_KSU_SUSFS return 0;`` 早退, 把三条「策略 oracle」的处理
权让给 SUSFS 的静态钩子:

  * security/selinux/selinuxfs.c : susfs_sel_write_context / susfs_sel_write_access
  * security/selinux/hooks.c     : susfs_selinux_setprocattr

SUSFS 这三个函数都用 **live policy**(``state->policy``) 回答, 而 live policy
里已经注入了 KernelSU 的 ksu_file / su 规则, 所以 App Zygote 域(DirtySepolicy /
Duck Detector 之类)通过 security:check_context / security:compute_av /
process:setcurrent 就能看到这些特征。

FinaSU 自己保留了双策略实现 my_write_context / my_write_access / my_setprocattr
(用备份策略 backup_sepolicy 回答, 即注入前的原始策略), 但在 SUSFS 模式下被
编译成「无 uid 门控、无 orig 回退」的导出函数, 既没人调用、也没有声明。

本脚本只改三处函数体, 让 SUSFS 的门控外壳直接委托给 FinaSU 的双策略实现:

  susfs_sel_write_context()      -> return my_write_context(file, buf, size);
  susfs_sel_write_access()       -> return my_write_access(file, buf, size);
  susfs_selinux_setprocattr()    -> return my_setprocattr(name, value, size);

门控仍在外壳里(uid >= 10000 && ksu_selinux_hide_running), 因此行为等价于
LKM 模式下的 KernelSU: 应用侧查询由 backup_sepolicy 回答, ksu 规则不可见;
SUSFS 的其它功能(sus_path/sus_mount/sus_kstat/avc log 伪装)不受影响。

用法: patch-selinux-hide-dual-policy.py <common 目录> [FinaSU 目录]
失败时以非 0 退出并在 stderr 说明原因(上游改形态后必须人工确认, 不能静默通过)。
"""

import pathlib
import sys

EXTERN_DECLS = {
    "my_write_context": "extern ssize_t my_write_context(struct file *file, char *buf, size_t size);\n",
    "my_write_access": "extern ssize_t my_write_access(struct file *file, char *buf, size_t size);\n",
    "my_setprocattr": "extern int my_setprocattr(const char *name, void *value, size_t size);\n",
}

TARGETS = [
    {
        "file": "security/selinux/selinuxfs.c",
        "func": "susfs_sel_write_context",
        "signature_hint": "susfs_sel_write_context(struct file *file, char *buf, size_t size)",
        "extern": "my_write_context",
        "call": "return my_write_context(file, buf, size);",
        "stale_markers": ["susfs_security_context_to_sid(", "security_sid_to_context("],
    },
    {
        "file": "security/selinux/selinuxfs.c",
        "func": "susfs_sel_write_access",
        "signature_hint": "susfs_sel_write_access(struct file *file, char *buf, size_t size)",
        "extern": "my_write_access",
        "call": "return my_write_access(file, buf, size);",
        "stale_markers": ["susfs_security_context_str_to_sid(", "susfs_security_compute_av_user("],
    },
    {
        "file": "security/selinux/hooks.c",
        "func": "susfs_selinux_setprocattr",
        "signature_hint": "susfs_selinux_setprocattr(const char *name, void *value, size_t size)",
        "extern": "my_setprocattr",
        "call": "return my_setprocattr(name, value, size);",
        "stale_markers": ["susfs_security_context_to_sid(", "security_context_str_to_sid("],
    },
]


def fail(msg):
    sys.stderr.write("::error title=双策略钩子接入失败::%s\n" % msg)
    sys.exit(1)


def find_function(lines, hint):
    """返回 (signature_index, body_start_index, body_end_index)。"""
    sig = None
    for i, line in enumerate(lines):
        if hint in line and line.lstrip().startswith(("static ", "int ", "ssize_t ", "asmlinkage")):
            sig = i
            break
    if sig is None:
        return None
    brace = None
    for i in range(sig, min(sig + 6, len(lines))):
        if lines[i].strip().startswith("{"):
            brace = i
            break
    if brace is None:
        return None
    end = None
    for i in range(brace + 1, len(lines)):
        if lines[i].startswith("}"):
            end = i
            break
    if end is None:
        return None
    return sig, brace, end


def old_form_patch(root):
    """老形态（<=8930474a）的 50_add 补丁自带 my_setprocattr 调用，已经走双策略。"""
    hooks = root / "security/selinux/hooks.c"
    fs = root / "security/selinux/selinuxfs.c"
    if not hooks.exists() or not fs.exists():
        return False
    hook_text = hooks.read_text()
    return ("fake_state" in fs.read_text()) or ("susfs_sel_write_context" not in fs.read_text()
                                               and "my_setprocattr(" in hook_text)


def patch_file(root, spec):
    path = root / spec["file"]
    if not path.exists():
        fail("%s 不存在（SUSFS 补丁未应用或路径变化）" % path)
    text = path.read_text()
    lines = text.splitlines(keepends=True)

    found = find_function(lines, spec["signature_hint"])
    if found is None:
        if old_form_patch(root):
            print("  = 老形态补丁（my_setprocattr/&fake_state）：外壳已直接调用 KSU 双策略，跳过 %s"
                  % spec["func"])
            return False
        fail("%s: 找不到函数 %s 的定义，上游形态已变更，需人工确认"
             % (spec["file"], spec["func"]))
    sig, brace, end = found

    body = "".join(lines[brace:end + 1])
    if spec["call"] in body and not any(m in body for m in spec["stale_markers"]):
        print("  = %s 已委托给 %s，跳过" % (spec["func"], spec["extern"]))
        return False

    new_body = [
        "{\n",
        "\t/* 交给 KernelSU 双策略实现：用注入前的 backup_sepolicy 回答，\n",
        "\t * 使 app_zygote 的 check_context / compute_av / setcurrent 查询\n",
        "\t * 看不到 ksu_file / su 等注入规则。门控在本函数的外层调用点。 */\n",
        "\t%s\n" % spec["call"],
        "}\n",
    ]

    before = "".join(lines[:sig])
    decl = EXTERN_DECLS[spec["extern"]]
    # 声明必须放在签名行之前：`static ssize_t f(...)` 与 `{` 之间不能插语句
    extra = "" if decl in before else decl + "\n"

    # 保留原签名行（可能带 static / __nocfi 等修饰符），只替换函数体
    patched = before + extra + lines[sig] + "".join(new_body) + "".join(lines[end + 1:])
    # 自检：委托调用必须在函数体内，旧实现的特征必须消失
    chunk = patched[patched.index(spec["signature_hint"]):]
    chunk = chunk[:chunk.index("\n}") + 2]
    if spec["call"] not in chunk:
        fail("%s: 补丁后函数体未包含委托调用" % spec["func"])
    leftover = [m for m in spec["stale_markers"] if m in chunk]
    if leftover:
        fail("%s: 补丁后仍残留 live-policy 调用 %s" % (spec["func"], leftover))

    path.write_text(patched)
    print("  + %s -> %s" % (spec["func"], spec["extern"]))
    return True


def check_finasu_side(finasu):
    """确认 FinaSU 侧确实导出了双策略实现（SUSFS 模式下必须是非 static）。"""
    src = finasu / "kernel" / "feature" / "selinux_hide.c"
    if not src.exists():
        fail("找不到 %s（FinaSU 源码目录不对）" % src)
    text = src.read_text()
    need = {
        "my_write_context": "ssize_t my_write_context(struct file *file, char *buf, size_t size)",
        "my_write_access": "ssize_t my_write_access(struct file *file, char *buf, size_t size)",
        "my_setprocattr": "int my_setprocattr(const char *name, void *value, size_t size)",
    }
    for name, sig in need.items():
        # 允许 __nocfi 等修饰符，但必须不是 static
        ok = any(sig in line and "static" not in line for line in text.splitlines())
        if not ok:
            fail("FinaSU %s 未以非 static 形式导出 %s（SUSFS 模式下双策略实现不可链接）"
                 % (src.name, name))
    if "security_context_to_sid_with_policy(backup_sepolicy" not in text:
        fail("FinaSU selinux_hide.c 里没有 backup_sepolicy 双策略解析，形态已变更")
    print("  = FinaSU 侧双策略符号齐备（my_write_context / my_write_access / my_setprocattr）")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    common = pathlib.Path(sys.argv[1]).resolve()
    finasu = pathlib.Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else common.parent / "FinaSU"

    print("接入双策略 SELinux 隐藏：common=%s finasu=%s" % (common, finasu))
    check_finasu_side(finasu)
    changed = 0
    for spec in TARGETS:
        if patch_file(common, spec):
            changed += 1
    print("完成：%d 处函数体已改写（其余为幂等跳过）" % changed)
    return 0


if __name__ == "__main__":
    sys.exit(main())
