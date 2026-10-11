#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# 应用 SUSFS 补丁及各内核版本所需的上下文修复
#
# 依赖环境变量：
#   ANDROID_VERSION KERNEL_VERSION KSU_VARIANT OS_PATCH_LEVEL SUB_LEVEL
#   KERNEL_ROOT SUSFS4KSU KERNEL_PATCHES LEGACY_SUKISU_CONFIG
#   SUSFS_RAW_PROBE  原始补丁探测：只把上游补丁原样打进去，不做任何适配修复
#   SUSFS_SIDE_FIXES 探测时保留与子版本无关的 SUSFS 侧修复（5.10 侧两处编译缺陷）
#   SUSFS_PROBE_DIR  探测结论写出目录（apply.json），默认当前目录
# 调用前必须将工作目录设为 $KERNEL_ROOT
set -eo pipefail

# 列出当前目录下不属于上游的 .rej（相对路径，已排序）。
# 上游分支可能自带已提交的 .rej（如 android15-6.6-2026-04 的 mm/rmap.c.rej，
# 是上游解决合并冲突时的残留），那不是本补丁的冲突；但 patch 失败时会覆盖同名文件，
# 所以只有「被 git 跟踪且未改动」的才视为上游自带。
# 不在 git 仓库里（本地 verify_context.sh）时 git 命令为空，退回全部 .rej
list_upstream_rej() {
  git ls-files -- '*.rej' 2>/dev/null | while IFS= read -r f; do
    git diff --quiet -- "$f" 2>/dev/null && echo "$f"
  done
}
list_untracked_rej() {
  comm -23 \
    <(find . -type f -name '*.rej' | sed 's|^\./||' | sort) \
    <(list_upstream_rej | sort)
}

# patch 退出码：0=全部应用，1=部分/全部 hunk 被跳过（--forward 下表示已应用过），
# >=2=真正的失败。把「已应用过」当成成功，其余一律终止构建。
apply_patch_checked() {
  local desc="$1" patch_file="$2"
  shift 2
  local rc=0
  patch -p1 --forward "$@" < "$patch_file" || rc=$?
  if [ "$rc" -ge 2 ]; then
    echo "::error title=$desc::补丁 $patch_file 应用失败（patch 退出码 $rc），构建终止"
    exit 1
  fi
  return 0
}

echo "应用 SUSFS 补丁..."

SUSFS_PATCH="50_add_susfs_in_gki-$ANDROID_VERSION-$KERNEL_VERSION.patch"
# SUSFS 上游按内核版本分分支，分支名对不上时补丁文件根本不存在。
# 直接 cp 只会丢一句 "No such file"，看不出是"分支名错了"还是"这个内核版本没有 SUSFS"，
# 而这两者的排查方向完全不同，所以先显式判一次。
if [ ! -f "$SUSFS4KSU/kernel_patches/$SUSFS_PATCH" ]; then
  echo "::error::SUSFS 补丁不存在: $SUSFS4KSU/kernel_patches/$SUSFS_PATCH"
  echo "::error::SUSFS 源（$(git -C "$SUSFS4KSU" remote get-url origin 2>/dev/null || echo 未知)）的 gki-$ANDROID_VERSION-$KERNEL_VERSION 分支未提供该内核版本的补丁"
  echo "::error::请确认该内核版本是否有 SUSFS 支持，或改用 simonpunk/ShirkNeko 中有对应分支的源"
  exit 1
fi
cp "$SUSFS4KSU/kernel_patches/$SUSFS_PATCH" ./common/
cp "$SUSFS4KSU"/kernel_patches/fs/* ./common/fs/
cp "$SUSFS4KSU"/kernel_patches/include/linux/* ./common/include/linux/

case "$KSU_VARIANT" in
  "Official")
    cd ./KernelSU
    cp "$SUSFS4KSU"/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch ./
    # 官方 KernelSU 需要这个补丁才有 SUSFS 支持，没打上等于 SUSFS 全程缺席，
    # 但构建仍会跑完并产出能开机的内核，属于必须当场发现的静默降级
    apply_patch_checked "KernelSU Official 的 SUSFS 启用补丁" 10_enable_susfs_for_ksu.patch

    cd ..
    ;;
  "Next"|"SukiSU"|"SukiSU(40726)"|"SukiSU(40548)"|"BakaSU"|"FinaSU")
    echo "$KSU_VARIANT 的 SUSFS KernelSU 侧适配已由上游集成补丁提供"
    ;;
esac

cd "$KERNEL_ROOT/common"
CURRENT_SUB="$SUB_LEVEL"
if [[ ! "$CURRENT_SUB" =~ ^[0-9]+$ ]]; then
  CURRENT_SUB=99999
fi

# ---------------------------------------------------------------- 原始补丁探测
# 探测要回答的是「上游 SUSFS 补丁原样打到未经改动的内核上能不能落地」。
# 本脚本同时负责「应用补丁」和「适配修复」，走常规路径的话测出来的会是
# 「修过之后的补丁能不能编译」，而不是原始兼容线。所以探测模式在这里就短路：
# 只应用原始补丁（外加可选的侧修复），随即写出 apply.json 并结束。
#
# 判定口径：一切由 apply.json 记录，交给 scripts/susfs_probe/write_result.py 汇总。
# 这里刻意不做 verify_susfs_landing / 不因失配而 exit —— 补丁没打上本身就是结论。

# 侧修复之一：针对上游 5.10 补丁自身的编译缺陷（extern 声明晚于使用），
# 与具体子版本无关，所以探测模式下也应用，保证不同分支之间口径可比。
fix_statfs_susfs_decl() {
  # 上游 5.10 补丁把 susfs_sus_kstat_spoof_vfs_statfs 的 extern 声明放在了
  # susfs_statfs_by_dentry 之后，clang -Werror 会报隐式声明；声明晚于使用时前移
  if [[ -f fs/statfs.c ]] && grep -qF 'susfs_sus_kstat_spoof_vfs_statfs(' fs/statfs.c; then
    local statfs_use statfs_decl
    statfs_use=$(grep -n 'if (!susfs_sus_kstat_spoof_vfs_statfs(' fs/statfs.c | head -1 | cut -d: -f1)
    statfs_decl=$(grep -n '^extern int susfs_sus_kstat_spoof_vfs_statfs(' fs/statfs.c | head -1 | cut -d: -f1)
    if [[ -n "$statfs_use" && -n "$statfs_decl" && "$statfs_decl" -gt "$statfs_use" ]] \
      && grep -q '^static int susfs_statfs_by_dentry(' fs/statfs.c; then
      echo "前移 statfs.c 中 susfs_sus_kstat_spoof_vfs_statfs 的声明"
      sed -i '/^static int susfs_statfs_by_dentry(/i extern int susfs_sus_kstat_spoof_vfs_statfs(struct inode *inode, struct kstatfs *buf, bool *is_fuse);' fs/statfs.c
    fi
  fi
}

# 侧修复之二：6.12.69+ 的 show_smap 上下文漂移（vma_pages → vma_data_pages）。
# 同样是上游补丁自身的缺陷，非本仓库的适配调整，故探测模式下同样应用。
# 定位思路参考 LingLuo17/AnyKernel3（GPL-3.0）对同一问题的排查结论，
# 本实现按本仓库的失败处理约定重写，未复制其代码。
fix_show_smap_sus_map() {
  local f="fs/proc/task_mmu.c"

  [ -f "$f.rej" ] || return 0
  grep -qF 'static int show_smap(struct seq_file *m, void *v)' "$f" || return 0

  # 幂等：函数体里已有该检查就不重复插入（重跑 / 断点续建时会再次进入本阶段）
  local body
  body=$(sed -n '/^static int show_smap(struct seq_file \*m, void \*v)/,/^}/p' "$f")
  [ -n "$body" ] || return 0
  case "$body" in
    *SUSFS_IS_INODE_SUS_MAP*) return 0 ;;
  esac

  echo "为 show_smap 手工补入 SUS_MAP 检查（vma_pages → vma_data_pages 上下文漂移）"

  # 只依赖函数签名与 vma 定义两行做锚点，不写死后续的 mem_size_stats 等声明，
  # 免得上游再动函数体就整段失配。插入点必须在 vma 赋值之后：检查要用到 vma->vm_file。
  perl -0pi -e 's/(static int show_smap\(struct seq_file \*m, void \*v\)\n\{\n\tstruct vm_area_struct \*vma = v;\n)/$1\n#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n\tif (vma->vm_file) {\n\t\tif (SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))\n\t\t\treturn 0;\n\t}\n#endif\n/' "$f"

  if ! grep -qF 'SUSFS_IS_INODE_SUS_MAP' "$f"; then
    # 保留 .rej：交由下方的冲突检查处理
    echo "::error::show_smap SUS_MAP 检查手工补入失败，保留 $f.rej 交由冲突检查处理"
    return 0
  fi

  rm -f "$f.rej"
  echo "已补入 show_smap SUS_MAP 检查并清除预期冲突文件"
}

if [ "${SUSFS_RAW_PROBE:-false}" = "true" ]; then
  PROBE_DIR="${SUSFS_PROBE_DIR:-.}"
  mkdir -p "$PROBE_DIR"

  _side_applied=""
  if [ "${SUSFS_SIDE_FIXES:-false}" = "true" ]; then
    fix_statfs_susfs_decl
    fix_show_smap_sus_map
    _side_applied="statfs_decl,show_smap_sus_map"
    echo "原始补丁探测 + 侧修复（SUSFS_SIDE_FIXES=true）：$_side_applied"
  else
    echo "原始补丁探测（SUSFS_RAW_PROBE=true）：不做任何适配修复"
  fi

  # --forward 下 rc=1 表示有 hunk 被跳过，正是要测的东西；rc>=2 才是真失败。
  # 与常规路径（apply_patch_checked）不同，这里不因失配而终止构建：
  # 补丁没打上来本身就是这次探测的结论，终止就什么结论都拿不到了。
  _patch_log=""
  _patch_out=$(patch -p1 --forward < "$SUSFS_PATCH" 2>&1) && _rc=0 || _rc=$?
  _patch_log="$_patch_out"

  _rej_files=()
  mapfile -t _rej_files < <(list_untracked_rej)
  _rej_count=${#_rej_files[@]}
  _hunks_failed=$(printf '%s\n' "$_patch_log" | grep -c '^Hunk #[0-9]* FAILED' || true)
  _hunks_ignored=$(printf '%s\n' "$_patch_log" | grep -c 'previously applied, skipping' || true)

  printf '%s\n' "$_patch_log" > "$PROBE_DIR/patch.log"

  cat > "$PROBE_DIR/apply.json" <<EOF
{
  "raw_probe": true,
  "susfs_side_fixes": ${SUSFS_SIDE_FIXES:-false},
  "susfs_side_fixes_applied": "$_side_applied",
  "patch_exit": $_rc,
  "rej": $_rej_count,
  "rej_files": [$(printf '"%s",' "${_rej_files[@]}" | sed 's/,$//')],
  "hunks_failed": $_hunks_failed,
  "hunks_ignored": $_hunks_ignored,
  "hunks_offset": null,
  "hunks_fuzz": null
}
EOF

  echo "原始补丁探测结论：rej=$_rej_count，failed=$_hunks_failed，ignored=$_hunks_ignored，patch 退出码=$_rc"
  echo "结论已写入 $PROBE_DIR/apply.json（构建继续，编译结果由依次的写结果步骤记录）"
  exit 0
fi

# 兼容缺少 VMA padding 接口的 5.10.66～209、5.15.74～144 和 6.1.25～68
if grep -qF 'VMA_PAD_START(vma)' "$SUSFS_PATCH" \
  && ! grep -Rqs 'VMA_PAD_START' ./include/linux; then
  echo "目标内核未提供 VMA_PAD_START，使用 vma->vm_end 兼容 SUSFS OPEN_REDIRECT"
  sed -i 's/VMA_PAD_START(vma)/vma->vm_end/g' "$SUSFS_PATCH"
fi

# Android 12 / 5.10 的 set_nameidata 只有三个参数；SUSFS 上游补丁在
# 兼容修复合入前可能仍带四参数调用。仅在目标 API 与补丁内容同时匹配时改写，
# 上游修复后或其他内核版本均保持原补丁不变。
if [[ "$ANDROID_VERSION" == "android12" && "$KERNEL_VERSION" == "5.10" ]] \
  && grep -qF 'static void set_nameidata(struct nameidata *p, int dfd, struct filename *name)' fs/namei.c \
  && grep -qF 'set_nameidata(nd, old_dfd, fake_filename, NULL);' "$SUSFS_PATCH"; then
  echo "检测到 Android 12 / 5.10 的三参数 set_nameidata API，修正 SUSFS 补丁调用"
  sed -i 's/set_nameidata(nd, old_dfd, fake_filename, NULL);/set_nameidata(nd, old_dfd, fake_filename);/g' "$SUSFS_PATCH"
fi

adjust_legacy_fdinfo_context() {
  sed -i '/^[[:space:]]*\/\*$/,/^[[:space:]]*u32 mask = mark->mask & IN_ALL_EVENTS;$/d' fs/notify/fdinfo.c
  perl -i -pe 's/\bmask,\s*mark->ignored_mask/inotify_mark_user_mask(mark)/g' fs/notify/fdinfo.c
  perl -i -pe 's/ignored_mask:%x/ignored_mask:0/g' fs/notify/fdinfo.c
}

restore_legacy_fdinfo_context() {
  perl -i -pe 's/^(\s+if \(inode\) \{)/$1\n\t\t\/\*\n\t\t * IN_ALL_EVENTS represents all of the mask bits\n\t\t * that we expose to userspace.  There is at\n\t\t * least one bit (FS_EVENT_ON_CHILD) which is\n\t\t * used only internally to the kernel.\n\t\t *\/\n\t\tu32 mask = mark->mask & IN_ALL_EVENTS;/m' fs/notify/fdinfo.c
  perl -i -pe 's/\binotify_mark_user_mask\(mark\)/mask, mark->ignored_mask/g' fs/notify/fdinfo.c
  perl -i -pe 's/ignored_mask:0/ignored_mask:%x/g' fs/notify/fdinfo.c
}

# 临时调整旧内核源码上下文，使 SUSFS 主补丁可以匹配
if [[ "$ANDROID_VERSION" == "android12" && "$KERNEL_VERSION" == "5.10" ]]; then
  if [[ -n "$LEGACY_SUKISU_CONFIG" && "$CURRENT_SUB" -le 43 ]]; then
    echo "临时调整 Android 12 5.10 base.c 上下文"
    perl -i -pe 's/(int|size_t)\s+this_len\s*=\s*min_t\s*\(\s*\1\s*,/size_t this_len = min_t(size_t,/;' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 117 ]]; then
    echo "临时调整 Android 12 5.10 fdinfo.c 上下文"
    adjust_legacy_fdinfo_context
  fi
fi

if [[ "$ANDROID_VERSION" == "android13" && "$KERNEL_VERSION" == "5.15" ]]; then
  if [[ "$CURRENT_SUB" -le 41 ]]; then
    echo "临时调整 Android 13 5.15 namespace.c/open.c/fdinfo.c 上下文"
    if ! grep -qF '#include <linux/mnt_idmapping.h>' fs/namespace.c; then
      sed -i '/^#include <linux\/shmem_fs.h>$/a #include <linux/mnt_idmapping.h>' fs/namespace.c
    fi
    if ! grep -qF '#include <linux/mnt_idmapping.h>' fs/open.c; then
      sed -i '/^#include <linux\/compat.h>$/a #include <linux/mnt_idmapping.h>' fs/open.c
    fi
    adjust_legacy_fdinfo_context
  fi
  if [[ "$OS_PATCH_LEVEL" == "lts" ]]; then
    echo "临时调整 Android 13 5.15 LTS 头文件上下文"
    sed -i '/^#include <trace\/hooks\/blk.h>$/d' fs/namespace.c
    sed -i '/^#include <trace\/hooks\/mm.h>$/d' fs/proc/task_mmu.c
  fi
fi

if [[ "$ANDROID_VERSION" == "android14" && "$KERNEL_VERSION" == "6.1" ]]; then
  if [[ "$CURRENT_SUB" -le 25 ]] && ! grep -qF '#include <trace/hooks/sched.h>' fs/proc/base.c; then
    echo "临时调整 Android 14 6.1 sched.h 上下文"
    sed -i '/^#include <trace\/events\/oom.h>$/a #include <trace/hooks/sched.h>' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 141 ]] && ! grep -qF '#include <linux/dma-buf.h>' fs/proc/base.c; then
    echo "临时调整 Android 14 6.1 dma-buf.h 上下文"
    sed -i '/^#include <linux\/cpufreq_times.h>$/a #include <linux/dma-buf.h>' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -ge 157 ]]; then
    echo "临时调整 Android 14 6.1 namespace.c 上下文"
    sed -i '/^#include <trace\/hooks\/blk.h>$/d' fs/namespace.c
  fi
fi

if [[ "$ANDROID_VERSION" == "android15" && "$KERNEL_VERSION" == "6.6" ]]; then
  if [[ "$CURRENT_SUB" -le 92 ]] && ! grep -qF '#include <linux/dma-buf.h>' fs/proc/base.c; then
    echo "临时调整 Android 15 6.6 base.c 上下文"
    sed -i '/^#include <linux\/cpufreq_times.h>$/a #include <linux/dma-buf.h>' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 57 ]] && ! grep -qF '#include <linux/zswap.h>' mm/memory.c; then
    echo "临时调整 Android 15 6.6 memory.c 上下文"
    sed -i '/^#include <linux\/sched\/sysctl.h>$/a #include <linux/zswap.h>' mm/memory.c
  fi
fi

if [[ "$ANDROID_VERSION" == "android16" && "$KERNEL_VERSION" == "6.12" ]]; then
  if [[ "$CURRENT_SUB" -ge 58 ]]; then
    echo "临时调整 Android 16 6.12 exec.c 上下文"
    sed -i '/^#include <linux\/dma-buf.h>$/d' fs/exec.c
  fi
fi

# 新版内核在 super.c 的 internal.h 之后新增了 trace/hooks/fs.h，
# 旧版 SUSFS 主补丁以 thaw_super_locked 为上下文插入 extern 声明，会整段被拒绝；
# 上游 2026-09-15 起已把声明挪到 unnamed_dev_ida 之后，不再依赖这段上下文，
# 但 ShirkNeko fork 尚未同步（固定提交的旧版补丁不改 super.c），只对旧版补丁做临时调整
SUPER_FS_H_REMOVED=""
if grep -q '^ static int thaw_super_locked' "$SUSFS_PATCH" \
  && grep -qF '#include <trace/hooks/fs.h>' fs/super.c; then
  echo "临时调整 super.c 上下文"
  sed -i '/^#include <trace\/hooks\/fs.h>$/,+1d' fs/super.c
  SUPER_FS_H_REMOVED=1
fi

# SUSFS 主补丁必须完整应用。默认遇到补丁拒绝即终止构建；只有显式设置
# ALLOW_SUSFS_REJ=1 时才允许保留 .rej 并继续。
apply_patch_checked "SUSFS 主补丁" "$SUSFS_PATCH"

# 为尚未提供 SU 会话 FD 接口的 SukiSU/BakaSU 恢复旧版 exec hook 行为
EXEC_HELPER=""
if [[ "$KSU_VARIANT" == SukiSU* || "$KSU_VARIANT" == "BakaSU" ]]; then
  if grep -qF 'ksu_install_su_fd();' fs/exec.c; then
    EXEC_HELPER="ksu_install_su_fd"
  elif grep -qF 'ksu_handle_post_execveat_sucompat(' fs/exec.c; then
    EXEC_HELPER="ksu_handle_post_execveat_sucompat"
  fi
fi
if [[ -n "$EXEC_HELPER" ]] \
  && ! grep -RqsE --include='*.c' "^[[:space:]]*int[[:space:]]+${EXEC_HELPER}[[:space:]]*\(" "$KERNEL_ROOT/KernelSU/kernel"; then
  echo "$KSU_VARIANT 尚未提供 $EXEC_HELPER，恢复旧版 exec hook"
  sed -i '/^extern int ksu_install_su_fd(void);$/d' fs/exec.c
  sed -i '/^extern int ksu_handle_post_execveat_sucompat(/,+1d' fs/exec.c
  sed -i 's/is_su_session = !\(ksu_handle_execveat[^;]*;\)/\1/' fs/exec.c
  sed -i '/^[[:space:]]*bool is_su_session = false;$/d' fs/exec.c
  sed -i '/^[[:space:]]*if (unlikely(is_su_session && retval >= 0))$/,+1d' fs/exec.c
  sed -i '/^[[:space:]]*if (unlikely(is_su_session))$/,+1d' fs/exec.c
  sed -i '/^#ifdef CONFIG_KSU_SUSFS$/N;/^#ifdef CONFIG_KSU_SUSFS\n#endif \/\/ #ifdef CONFIG_KSU_SUSFS$/d' fs/exec.c
  if grep -qE 'ksu_install_su_fd|ksu_handle_post_execveat_sucompat|is_su_session' fs/exec.c; then
    echo "::error::$KSU_VARIANT exec hook 结构已变化，无法完成兼容修复"
    exit 1
  fi
fi

# 上游 5.10 补丁把 susfs_sus_kstat_spoof_vfs_statfs 的 extern 声明放在了
# susfs_statfs_by_dentry 之后，clang -Werror 会报隐式声明；声明晚于使用时前移。
# 实现已提升为顶层函数（见上方「原始补丁探测」段）：探测模式也要用它做侧修复，
# 放在这里复用同一份，免得这段逻辑存在两份、日后各自漂移。
fix_statfs_susfs_decl

# 原此处有一段「给 fs/susfs.c 补 #include <linux/security.h>」的兜底，可追溯为
# 三仓融合时从 zzh20188 继承的原样代码（zzh20188 已在 613a8f0 删除同款实现）。当时保留它
# 是因为上游 susfs.c 未包含该头文件、5.10 上会 clang -Werror 报隐式声明；而
# 实测 kernel_patches/fs/susfs.c 的两个分支现已自带该 include，判断恒为假、属
# 死代码，故此处一并移除。

# 6.12.69+ 的 show_smap 上下文漂移：上游把 show_smap 里的 vma_pages() 换成了
# vma_data_pages()，SUSFS 补丁中「smaps 隐藏 sus_map 文件」的那段 hunk 因此失配被拒，
# 留下 fs/proc/task_mmu.c.rej。
#
# 这与「上游已含同款修改」那类可忽略冲突**性质相反**：不补回来的话，
# 被标记 sus_map 的文件会从 /proc/<pid>/smaps 里暴露出来，而构建看起来是成功的。
# 所以这里手工补入检查，并且补入失败就**不删 .rej** —— 交由下方的冲突检查照常终止，
# 与全脚本的 fail-closed 约定保持一致。
#
# 定位思路参考 LingLuo17/AnyKernel3（GPL-3.0）对同一问题的排查结论，
# 本实现按本仓库的失败处理约定重写，未复制其代码。
# 同 fix_statfs_susfs_decl：实现已提升到「原始补丁探测」段，这里只调用。
fix_show_smap_sus_map

# patch 退出码 1 也可能只是「部分 hunk 被跳过」而不留 .rej，所以不能只看返回值，
# 必须核对产物：SUSFS 是否真的进了编译、SELinux 钩子是否真的注入
verify_susfs_landing() {
  local missing=()

  grep -q 'susfs' fs/Makefile 2>/dev/null \
    || missing+=("fs/Makefile 没有引入 susfs.o，SUSFS 不会被编译")
  [ -f fs/susfs.c ] \
    || missing+=("fs/susfs.c 不存在，SUSFS 源文件未落地")

  # 只在补丁确实要改这些文件时校验，避免补丁改版后误报
  if grep -q 'b/security/selinux/hooks\.c' "$SUSFS_PATCH" 2>/dev/null \
    && ! grep -q 'my_setprocattr' security/selinux/hooks.c 2>/dev/null; then
    missing+=("security/selinux/hooks.c 未注入 my_setprocattr，SELinux 隐藏不会生效")
  fi
  if grep -q 'b/security/selinux/selinuxfs\.c' "$SUSFS_PATCH" 2>/dev/null \
    && ! grep -qE 'my_sel_open_handle_status|my_write_access|my_write_context' security/selinux/selinuxfs.c 2>/dev/null; then
    missing+=("security/selinux/selinuxfs.c 未注入 status/access/context 钩子，/sys/fs/selinux 会泄漏真实上下文")
  fi

  if [ "${#missing[@]}" -gt 0 ]; then
    echo "::error title=SUSFS 未完整落地::检测到 ${#missing[@]} 处缺失，内核会假装正常但 SUSFS 实际不生效"
    printf '  - %s\n' "${missing[@]}"
    exit 1
  fi
  echo "SUSFS 落地校验通过：susfs.o 已进编译、SELinux 钩子已注入"
}

# 在编译前核对 SUSFS 主补丁的冲突文件，上游自带的 .rej 不计入
mapfile -t SUSFS_REJ_FILES < <(list_untracked_rej)
SUSFS_REJ_COUNT=${#SUSFS_REJ_FILES[@]}
if [ "$SUSFS_REJ_COUNT" -gt 0 ]; then
  if [ "${ALLOW_SUSFS_REJ:-0}" = "1" ]; then
    echo "::warning title=SUSFS 补丁冲突::产生了 ${SUSFS_REJ_COUNT} 个 .rej（ALLOW_SUSFS_REJ=1，继续构建；详见 Rejects 产物）"
    printf '%s\n' "${SUSFS_REJ_FILES[@]}"
  else
    echo "::error title=SUSFS 补丁冲突::有 ${SUSFS_REJ_COUNT} 处 hunk 未应用（列出如下）。确认可忽略时设 ALLOW_SUSFS_REJ=1"
    printf '%s\n' "${SUSFS_REJ_FILES[@]}"
    exit 1
  fi
fi

verify_susfs_landing

# 还原仅用于补丁匹配的临时源码调整
if [[ "$ANDROID_VERSION" == "android12" && "$KERNEL_VERSION" == "5.10" ]]; then
  if [[ -n "$LEGACY_SUKISU_CONFIG" && "$CURRENT_SUB" -le 43 ]]; then
    echo "还原 Android 12 5.10 base.c 临时调整"
    sed -i 's/^size_t this_len = min_t(size_t, count, PAGE_SIZE);$/int this_len = min_t(int, count, PAGE_SIZE);/' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 117 ]]; then
    echo "还原 Android 12 5.10 fdinfo.c 临时调整"
    restore_legacy_fdinfo_context
  fi
fi

if [[ "$ANDROID_VERSION" == "android13" && "$KERNEL_VERSION" == "5.15" ]]; then
  if [[ "$CURRENT_SUB" -le 41 ]]; then
    echo "还原 Android 13 5.15 临时调整"
    sed -i '/#include <linux\/mnt_idmapping.h>$/d' fs/namespace.c
    sed -i '/#include <linux\/mnt_idmapping.h>$/d' fs/open.c
    restore_legacy_fdinfo_context
    sed -i 's|i_uid_into_mnt(i_user_ns(&fi->inode), &fi->inode).val|i_uid_into_mnt(\&init_user_ns, \&fi->inode).val|g' fs/susfs.c
    sed -i 's|i_uid_into_mnt(i_user_ns(inode), inode).val|i_uid_into_mnt(\&init_user_ns, inode).val|g' fs/susfs.c
  fi
  if [[ "$OS_PATCH_LEVEL" == "lts" ]]; then
    echo "还原 Android 13 5.15 LTS 头文件上下文"
    if ! grep -qF '#include <trace/hooks/blk.h>' fs/namespace.c; then
      sed -i '/^#include "internal.h"$/a #include <trace/hooks/blk.h>' fs/namespace.c
    fi
    if ! grep -qF '#include <trace/hooks/mm.h>' fs/proc/task_mmu.c; then
      sed -i '/^#include <linux\/pkeys.h>$/a #include <trace/hooks/mm.h>' fs/proc/task_mmu.c
    fi
  fi
fi

if [[ "$ANDROID_VERSION" == "android14" && "$KERNEL_VERSION" == "6.1" ]]; then
  if [[ "$CURRENT_SUB" -le 25 ]]; then
    sed -i '/^#include <trace\/hooks\/sched.h>$/d' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 141 ]]; then
    echo "还原 Android 14 6.1 base.c 临时调整"
    sed -i '/^#include <linux\/dma-buf.h>$/d' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -ge 157 ]] && ! grep -qF '#include <trace/hooks/blk.h>' fs/namespace.c; then
    echo "还原 Android 14 6.1 namespace.c 临时调整"
    sed -i '/^#include "internal.h"$/a #include <trace/hooks/blk.h>' fs/namespace.c
  fi
fi

if [[ "$ANDROID_VERSION" == "android15" && "$KERNEL_VERSION" == "6.6" ]]; then
  if [[ "$CURRENT_SUB" -le 92 ]]; then
    echo "还原 Android 15 6.6 base.c 临时调整"
    sed -i '/^#include <linux\/dma-buf.h>$/d' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 57 ]]; then
    echo "还原 Android 15 6.6 memory.c 临时调整"
    sed -i '/^#include <linux\/zswap.h>$/d' mm/memory.c
  fi
fi

if [[ "$ANDROID_VERSION" == "android16" && "$KERNEL_VERSION" == "6.12" ]]; then
  if [[ "$CURRENT_SUB" -ge 58 ]] && ! grep -qF '#include <linux/dma-buf.h>' fs/exec.c; then
    echo "还原 Android 16 6.12 exec.c 临时调整"
    sed -i '0,/^#include /s//#include <linux\/dma-buf.h>\n&/' fs/exec.c
  fi
fi

if [[ -n "$SUPER_FS_H_REMOVED" ]] \
  && ! grep -qF '#include <trace/hooks/fs.h>' fs/super.c; then
  echo "还原 super.c 临时调整"
  sed -i '/^#include "internal.h"$/a #include <trace/hooks/fs.h>' fs/super.c
fi

fix_missing_vm_flags_clear() {
  if [[ "$OS_PATCH_LEVEL" == "2024-11" ]] && grep -qF 'vm_flags_clear(new_vma, VM_PAD_MASK);' ./mm/mmap.c; then
    sed -i 's/vm_flags_clear(new_vma, VM_PAD_MASK);/new_vma->vm_flags \&= ~VM_PAD_MASK;/' ./mm/mmap.c
  fi
}

fix_task_mmu_show_pad() {
  local max_sub="$1"
  local excluded_patch_level="${2:-}"

  # 仅固定旧版 SUSFS 补丁会引入 goto show_pad，最新版已不再包含该代码
  if [[ -n "$LEGACY_SUKISU_CONFIG" && "$CURRENT_SUB" -le "$max_sub" ]] \
    && { [[ -z "$excluded_patch_level" ]] || [[ "$OS_PATCH_LEVEL" != "$excluded_patch_level" ]]; }; then
    sed -i -e 's/goto show_pad;/return 0;/' ./fs/proc/task_mmu.c
  fi
}

# Android 12 - 5.10 修复
if [[ "$ANDROID_VERSION" == "android12" && "$KERNEL_VERSION" == "5.10" ]]; then
  # 修复 2024-11 分支: mmap.c 调用了 vm_flags_clear()，但同分支 mm.h 未提供 helper
  fix_missing_vm_flags_clear
  fix_task_mmu_show_pad 209
fi

# Android 13 - 5.15 修复
  if [[ "$ANDROID_VERSION" == "android13" && "$KERNEL_VERSION" == "5.15" ]]; then
  # 修复 2024-11 分支: mmap.c 调用了 vm_flags_clear()，但同分支 mm.h 未提供 helper
  fix_missing_vm_flags_clear
  fix_task_mmu_show_pad 148 "2024-05"
fi

# Android 14 - 6.1 修复
if [[ "$ANDROID_VERSION" == "android14" && "$KERNEL_VERSION" == "6.1" ]]; then
  fix_task_mmu_show_pad 75 "2024-05"
fi

# Android 15 - 6.6 修复
if [[ "$ANDROID_VERSION" == "android15" && "$KERNEL_VERSION" == "6.6" ]]; then
  # 修复老版 SukiSU 6.6.50~6.6.58: task_mmu.c 打入 SUSFS 后使用 vma，但旧源码没有对应声明
  if [[ -n "$LEGACY_SUKISU_CONFIG" && "$CURRENT_SUB" -ge 50 && "$CURRENT_SUB" -le 58 ]] \
    && grep -qF 'vma = find_vma(mm, start_vaddr);' ./fs/proc/task_mmu.c; then
    TASK_MMU_PATCH="$KERNEL_PATCHES/wild/archived/susfs_fix_patches/v2.1.0/a15-6.6/task_mmu.c.patch"
    if [ ! -f "$TASK_MMU_PATCH" ]; then
      echo "::error::补丁不存在: $TASK_MMU_PATCH"
      exit 1
    fi
    cp "$TASK_MMU_PATCH" ./
    if patch -p1 --dry-run < task_mmu.c.patch >/dev/null 2>&1; then
      patch -p1 --no-backup-if-mismatch < task_mmu.c.patch
      echo "已应用 Android 15 6.6.50~6.6.58 task_mmu.c 归档修复补丁"
    else
      echo "Android 15 6.6.50~6.6.58 task_mmu.c 归档修复补丁已应用或当前上下文不匹配，跳过"
    fi
  fi
fi

# Android 16 - 6.12 修复
if [[ "$ANDROID_VERSION" == "android16" && "$KERNEL_VERSION" == "6.12" ]]; then
  # 固定旧版 SukiSU 在 6.12 上会重复定义 setresuid hook
  SETUID_HOOK="$KERNEL_ROOT/common/drivers/kernelsu/setuid_hook.c"
  if [[ -n "$LEGACY_SUKISU_CONFIG" && -f "$SETUID_HOOK" ]] \
    && grep -qF 'defined(CONFIG_KSU_MANUAL_HOOK))' "$SETUID_HOOK"; then
    sed -i 's/defined(CONFIG_KSU_MANUAL_HOOK))/!defined(CONFIG_KSU_SUSFS) \&\& defined(CONFIG_KSU_MANUAL_HOOK))/' "$SETUID_HOOK"
    echo "已修复 setuid_hook.c 重复定义问题"
  fi

  # 移植自 LingLuo17/GKI_KernelSU_SUSFS patch-1 73fe0336c（GPL-2.0）：
  # 修复 6.12 getname_flags 三参数调用（ACK 6.12 声明为 2 参数，do_faccessat 传了 3 参数导致编译失败）
  if grep -qF 'getname_flags(filename, lookup_flags, NULL)' fs/open.c; then
    sed -i 's/getname_flags(filename, lookup_flags, NULL)/getname_flags(filename, lookup_flags)/' fs/open.c
    echo "已修复 fs/open.c getname_flags 三参数问题"
  fi
fi
