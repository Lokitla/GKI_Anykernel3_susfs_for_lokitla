# 三仓融合说明

本文档说明 `zzh20188`、`coolzyd9107`、`ShirkNeko` 三个 GKI 构建仓库的融合方式与结果。

---

## 一、三个仓库的实际关系

融合前先做了逐文件比对，结论如下：

| 仓库 | 文件数 | 最后提交 | 判定 |
|---|---|---|---|
| **zzh20188/GKI_KernelSU_SUSFS** | 130 | 2026-09-16 | 主干，功能最全 → **选为主项目** |
| coolzyd9107/GKI_SukiSU_Ultra_SUSFS | 120 | 2026-06-28 | zzh20188 的过期副本 |
| ShirkNeko/GKI_KernelSU_SUSFS | 43 | 2026-08-27 | 另一套架构（Python 构建系统），有独有功能 |

### coolzyd：无独有内容，直接丢弃

```
coolzyd 独有文件：0 个
zzh20188 独有文件：12 个（含 security_patch/ 整个 CVE 修复目录）
```

两者同名文件仅有内容差异，且 coolzyd 落后约 2.5 个月。唯一的差异点
`web/js/config.js` 里的 `deprecatedCutoff` 字段，zzh20188 已迁移到 `data/*.json`
的 `deprecated_cutoff` —— 属于更新写法，不是缺失。**没有任何需要合并的内容。**

### ShirkNeko：另一套架构，有 4 项独有能力

ShirkNeko 用 Python 模块化脚本（`kernel_builder.py` 763 行）替代了 YAML 工作流。
值得注意的是，它的 OnePlus 8E 补丁直接引用 zzh20188 的仓库：

```python
OP8E_PATCH_URL = "https://github.com/zzh20188/GKI_KernelSU_SUSFS/raw/refs/heads/dev/hmbird_patch.c"
```

即两者是上下游关系，不是平行关系。

---

## 二、融合策略：抽取公共脚本，双入口共用

zzh20188 的构建逻辑原本以 53 个 step 的形式内嵌在 `build.yml`（1583 行）里，只能跑在
GitHub Actions 上。ShirkNeko 的 Python 版能本地跑，但功能比 zzh20188 少一大截
（无 CVE 补丁、Droidspaces、ReKernel、6.12、5 种 KSU 变体）。

**直接搬运任何一边都是错的**，因此采用第三条路：

```
scripts/build_kernel.sh        ← 单一真相源（完整功能，53 个阶段）
        ├─ .github/workflows/build.yml 调用它 → Actions 构建
        └─ build.py 调用它                   → 本地构建
```

这样既获得本地构建能力，又不存在两套逻辑分叉。

### 架构对比

| | 融合前 | 融合后 |
|---|---|---|
| 构建逻辑位置 | 内嵌在 `build.yml`（1583 行 YAML） | `scripts/build_kernel.sh`（4533 行 shell） |
| `build.yml` 职责 | 全部 | 仅 Actions 编排：缓存、上传、通知（21 步） |
| 本地构建 | 不支持 | `python3 build.py ...` |
| 逻辑份数 | 1（但绑死在 Actions） | 1（两个入口共用） |

---

## 三、从 ShirkNeko 吸收的内容

| 能力 | 落地位置 | 说明 |
|---|---|---|
| **本地 CLI 构建** | `build.py` + `scripts/build_kernel.sh` | 参数对齐 ShirkNeko 的 CLI 习惯（也支持 `--matrix` / `--all` / `--dry-run`） |
| **BBR 拥塞控制** | `scripts/build_kernel.sh` 的 `config_kernel` 阶段 | 写入 `CONFIG_TCP_CONG_BBR=y` 与 `CONFIG_DEFAULT_BBR=y`，幂等处理 |
| **Telegram 通知** | `scripts/telegram_notify.py` | 移植并改进（见下） |
| **Release 缓存** | `.github/actions/cache-restore`、`cache-save` | 默认关闭，与现有 `actions/cache` 共存 |

### 对 ShirkNeko 原实现的三处改进

1. **恢复 TLS 证书校验** —— 原实现设置了 `check_hostname = False` 与
   `verify_mode = CERT_NONE`，存在中间人风险，已改回默认安全上下文。
2. **去掉第三方依赖** —— 原实现的 `import multipart` 包名有误且非标准库，
   改用标准库手写 multipart 上传。
3. **参数统一** —— 通知内容改为从与 `build_kernel.sh` 相同的环境变量读取，
   并补充了 zzh20188 特有开关（BBR / BBG / ReKernel / Droidspaces / CVE 补丁）的展示。

---

## 四、新增的文件

```
build.py                                  # 本地构建 CLI 入口
scripts/build_kernel.sh                   # 构建核心（单一真相源）
scripts/telegram_notify.py                # Telegram 通知
.github/actions/cache-restore/action.yml  # Release 缓存（可选）
.github/actions/cache-save/action.yml
tools/migration/                          # 一次性迁移工具与原始输入，仅供追溯
FUSION.md                                 # 本文档
```

新增的构建选项（Actions 与 CLI 同名能力）：

| Actions 输入 | CLI 参数 | 默认 |
|---|---|---|
| `use_bbr` | `--bbr` | 关闭 |
| `send_telegram` | — | 关闭 |
| `use_release_cache` | — | 关闭 |

三个选项都已贯通 `main.yml` → `kernel-aXX.yml` → `build.yml` 整条调用链。

---

## 五、本地构建的安全保护

原工作流的「清理磁盘空间」步骤会执行：

```bash
sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc \
            /usr/local/lib/node_modules /opt/hostedtoolcache/...
```

这在 Actions runner 上是必要的（腾出空间），但在个人机器上**会破坏系统环境**。
因此脚本中这一步被加上了环境判断：

```bash
run_cleanup_disk() {
  if [ "${GITHUB_ACTIONS:-false}" = "true" ]; then
    stage_cleanup_disk "$@"
  else
    echo "跳过阶段: cleanup_disk（仅 GitHub Actions runner 执行）"
  fi
}
```

---

## 六、验证状态与已知限制

### 已完成的验证

| 项目 | 结果 |
|---|---|
| `build_kernel.sh` shell 语法（`bash -n`） | 通过 |
| `build.py` / `telegram_notify.py` 语法 | 通过 |
| 全部 15 个 workflow 的 YAML 解析 | 通过 |
| 环境变量传递端到端（模拟 Actions 注入） | 通过 |
| 调用链参数匹配（`main.yml` → `build.yml`） | 全部匹配 |
| GitHub 表达式残留检查（`${{ }}` / `$GITHUB_ENV`） | 无残留 |
| CLI `--list-configs` / `--dry-run` / 错误处理 | 正常 |

### 未能验证的部分（请注意）

**沙箱内无法真实执行一次完整的 GKI 内核构建** —— 这需要拉取数十 GB 的 AOSP
内核源码、数小时编译时间，以及 `android.googlesource.com` 的稳定访问。

因此以下方面是**静态推导等价**，尚未经过真实构建验证：

- 53 个阶段在独立 shell 进程中串接后，个别依赖子 shell 行为的语句
- `compile_kernel` 的重试包装（原为 `nick-fields/retry@v4` action）
- 各补丁步骤在真实源码上的实际效果

**建议首次使用时**：先在 Actions 上跑一个已知可构建的版本（例如
`android14 / 6.1 / 124`），与融合前的产物对比确认无误后，再全量使用。
若某个阶段有问题，可用 `--only <阶段>` 单独重跑定位，改动直接落在
`scripts/build_kernel.sh` 里。

### 维护说明

`scripts/build_kernel.sh` 现在是构建逻辑的**唯一真相源**。
后续要修改构建行为，直接改这个脚本即可，`build.yml` 与 `build.py` 都会自动受益。

`tools/migration/` 里的脚本只用于追溯本次迁移是如何从原 1583 行 YAML 提取出
shell 逻辑的，日常维护不需要再运行它。

---

## LingLuo17/AnyKernel3 移植记录

> **前提澄清**：`LingLuo17/AnyKernel3` 虽然叫这个名字，但**不是 AnyKernel3 刷机包
> 模板**，而是另一套完整的 GKI 构建工程（dev 分支 `ba3c27c`，结构与本仓库高度相似）。
> 本仓库真正使用的 AnyKernel3 刷机包来自 `WildKernels/AnyKernel3`
> （`scripts/build_kernel.sh` 的 `clone_deps` 阶段），那条链路不受本次移植影响。

本仓库的上游移植分支即该工程的移植分支，已合并进 `main`。

### 已移植

- 6.10+ 的 `security_add_hooks` 新签名兼容补丁（`const struct lsm_id *`）；
- 严格补丁校验与 6.12 的 `show_smap` 修复（本仓库 `susfs_fixes/apply.sh` 442 行，
  比上游 zzh20188 的 328 行更完整）；
- NoMount 挂载元模块、网络增强等（与上游 zzh20188 同代，非 LingLuo 独有）。

### 已解决

1. **6.12 的 ZRAM 补丁资源**：上游 `SukiSU_patch` 的 `other/zram/zram_patch/` 只有
   `5.10 / 5.15 / 6.1 / 6.6` 四个目录，没有 6.12。LingLuo 为此补了 6.12 补丁
   （commit `94fd545`、`ba3c27c`）。
   → **已解决**：本仓库 `zram_patch/6.12/` 已包含 `lz4kd.patch` 与 `lz4k_oplus.patch`，
   `scripts/build_kernel.sh:2779-2793` 的 `zram_patch_file()` 优先取用本仓库版本（优先于上游
   `SukiSU_patch`），`:2796` 的 `zram_lz4k_available()` 在校验齐全后才放行。
   6.12 入口的 `use_zram` 仍默认 `false`（默认关闭），需要时可显式启用。

### 确定遗漏（合并上游移植分支时漏掉）

1. **6.12 的 KPM**：脚本在内核 ≥ 6.10 时强制 `KPM_SUPPORTED=0`，与 LingLuo 无关，
   属上游限制。6.12 入口的 `use_kpm` 默认已改为 `disabled (关闭)`。
2. **UAPI 同步**：已移植（beta 分支），但实现方式与上游不同 —— 不用上游那个会腐烂的静态
   `builtin-uapi4.patch`，改为 `scripts/ksu_uapi_sync/align.sh` 在构建时读内核侧
   `KERNEL_SU_UAPI_VERSION`，与上游 `main` 的实际取值动态对齐（并补 `KSU_GET_INFO_FLAG_BUNDLED`），
   由 `build_kernel.sh` 的 `sync_ksu_uapi` 阶段在编译前调用。
   原因：上游同一个补丁一个多月内改了两版（`1bb9d909` 重生成、`b2f2598c` 把 4 改 5），
   且 `1bb9d909` 的提交说明本身就是「上游 builtin 合并 su-session 后各 hunk 被判为
   reversed/previously-applied，导致每个 SukiSU 矩阵构建中止」——静态 patch 会随上游漂移而腐烂，
   本仓库要跟随上游更新，因此选择动态对齐。
   → 后果：SukiSU 走 `builtin` 分支时内核 UAPI 落后于 `main` 构建的管理器 APK，
   管理器首页会误报「需要更新内核」；本机制消除该误报。

### 强烈建议不要移植的一项

**`scripts/ksu_post_setup.sh`（51 行）——品牌署名篡改脚本。**

把脚本里的 base64 常量解出来，实际行为是：

```
UkVQT19OQU1FIDo9IEJha2FTVQ==  →  REPO_NAME := BakaSU
QCQoY2FsbCBnaXRfYnJhbmNoKQ==  →  @$(call git_branch)
TGluZ0x1bw==                  →  LingLuo
```

即：把 `KernelSU/kernel/Kbuild` 里的 `REPO_NAME := BakaSU` 改成
`REPO_NAME := LingLuo`，把版本字符串里的 `@$(call git_branch)` 改成 `@LingLuo`，
然后用 `git update-index --skip-worktree` 把这次改动从 git 状态里藏起来
（`git status` / `git diff` 都看不到）。

这等于把上游 KernelSU 变体的品牌标识替换成自己的，并让替换行为不可见，与本仓库
`NOTICE` / `THIRD_PARTY_NOTICES.md` 的归属声明要求**直接冲突**——GPL-2.0 要求保留
原作者署名，本仓库自己的许可证文件也写明"构建期拉取的各组件保留其原有许可，不因
被本仓库引用而改变"。

**不要移植这一项。** 记录在此，避免日后有人又把它捡回来。

## LingLuo17/GKI_KernelSU_SUSFS 移植记录

- `patch-1` 分支 `73fe0336c`（GPL-2.0）：Android 16 6.12 `getname_flags`
  三参数调用编译修复，已移植进 `scripts/susfs_fixes/apply.sh` 的
  Android 16 - 6.12 修复块（带 `grep -qF` guard，不匹配时跳过）。
