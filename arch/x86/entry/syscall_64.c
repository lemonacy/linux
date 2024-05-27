// SPDX-License-Identifier: GPL-2.0
/* System call table for x86-64. */

#include <linux/linkage.h>
#include <linux/sys.h>
#include <linux/cache.h>
#include <linux/syscalls.h>
#include <asm/syscall.h>

#define __SYSCALL(nr, sym) extern long __x64_##sym(const struct pt_regs *);
#include <asm/syscalls_64.h>    // 这个文件是编译时生成的arch/x86/include/generated/asm/syscalls_64.h，内容为__SYSCALL(0, sys_read)等
#undef __SYSCALL                // 清楚第10行定义的__SYSCALL宏，下面14行要重新定义其作用

#define __SYSCALL(nr, sym) __x64_##sym, // 重新定义__SYSCALL宏，给下面数组中包含函数用

asmlinkage const sys_call_ptr_t sys_call_table[] = {
#include <asm/syscalls_64.h>    // 上面是通过extern的方式定义分散在各个模块的系统调用函数，此处就把上面声明的那些函数定义到sys_call_table数组中来
};
