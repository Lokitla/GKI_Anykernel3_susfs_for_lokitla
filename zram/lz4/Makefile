# SPDX-License-Identifier: BSD-2-Clause
#
# lz4.c / lz4hc.c / lz4.h / lz4hc.h 来自 LZ4 (Yann Collet)，按 BSD-2-Clause 分发。
# 注意：BSD-2-Clause 与 GPL-2.0-only 兼容 —— BSD 许可允许被并入 GPL 作品并以 GPL
# 分发（Linux 内核树内即有多处同例，如 crypto/lz4.c）。lz4armv8/ 三个文件单独声明
# 为 GPL-2.0-only（源自 Huawei EROFS），所以本 Makefile 自身的许可只覆盖构建规则，
# 不改变各源文件各自的许可声明。详见 NOTICE 中 "zram/lz4" 与 "zram/lz4/lz4armv8" 两条。
ccflags-y += -O3 \
    -DLZ4_FREESTANDING=1 \
    -DLZ4_FAST_DEC_LOOP=1

obj-y += lz4.o lz4hc.o

obj-$(CONFIG_ARM64) += $(addprefix lz4armv8/, lz4accel.o lz4armv8.o)
