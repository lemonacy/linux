/* SPDX-License-Identifier: GPL-2.0 WITH Linux-syscall-note */
#ifndef _UAPI_ASM_X86_VSYSCALL_H
#define _UAPI_ASM_X86_VSYSCALL_H

enum vsyscall_num {
	__NR_vgettimeofday,
	__NR_vtime,
	__NR_vgetcpu,
};

#define VSYSCALL_ADDR (-10UL << 20)     // 0xFFFFFFFFFF600000(将-10用补码表示，然后再左移20位，即得0xFFFFFFFFFF600000)，距离地址空间末尾10M

#endif /* _UAPI_ASM_X86_VSYSCALL_H */
