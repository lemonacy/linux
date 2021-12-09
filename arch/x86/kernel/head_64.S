/* SPDX-License-Identifier: GPL-2.0 */
/*
 *  linux/arch/x86/kernel/head_64.S -- start in 32bit and switch to 64bit
 *
 *  Copyright (C) 2000 Andrea Arcangeli <andrea@suse.de> SuSE
 *  Copyright (C) 2000 Pavel Machek <pavel@suse.cz>
 *  Copyright (C) 2000 Karsten Keil <kkeil@suse.de>
 *  Copyright (C) 2001,2002 Andi Kleen <ak@suse.de>
 *  Copyright (C) 2005 Eric Biederman <ebiederm@xmission.com>
 */


#include <linux/linkage.h>
#include <linux/threads.h>
#include <linux/init.h>
#include <linux/pgtable.h>
#include <asm/segment.h>
#include <asm/page.h>
#include <asm/msr.h>
#include <asm/cache.h>
#include <asm/processor-flags.h>
#include <asm/percpu.h>
#include <asm/nops.h>
#include "../entry/calling.h"
#include <asm/export.h>
#include <asm/nospec-branch.h>
#include <asm/fixmap.h>

/*
 * We are not able to switch in one step to the final KERNEL ADDRESS SPACE
 * because we need identity-mapped pages.
 */
#define l4_index(x)	(((x) >> 39) & 511) /* 取L4的index，39~47位 */
#define pud_index(x)	(((x) >> PUD_SHIFT) & (PTRS_PER_PUD-1)) /* 取L3的index，30~38位 */

L4_PAGE_OFFSET = l4_index(__PAGE_OFFSET_BASE_L4)    /* __PAGE_OFFSET_BASE_L4=0xffff888000000000，PAGE_OFFSET内核态地址空间的界限，大约在地址空间的末尾119.5T处，这个空间足够满足内核的运行需要了。 */
L4_START_KERNEL = l4_index(__START_KERNEL_map)  /* __START_KERNEL_map=0xffffffff80000000 内核虚拟地址的起始位置，距离地址空间末尾800M处。L4_START_KERNEL=511  */

L3_START_KERNEL = pud_index(__START_KERNEL_map) /* L3_START_KERNEL=510 */

	.text
	__HEAD
	.code64
SYM_CODE_START_NOALIGN(startup_64)  /* 为什么解压缩后这个函数刚好在16M的位置？这是因为此处的__HEAD宏让这个函数是位于vmlinux代码段的最开始处（readelf vmlinux -s |grep startup_64，结果：ffffffff81000000    60 NOTYPE  GLOBAL DEFAULT    1 startup_64，再通过readelf vmlinux -l，可知代码段起始虚拟地址为0xffffffff81000000），vmlinux将被压缩后放置在bzImage中 */
	UNWIND_HINT_EMPTY
	/*
	 * At this point the CPU runs in 64bit mode CS.L = 1 CS.D = 0,
	 * and someone has loaded an identity mapped page table
	 * for us.  These identity mapped page tables map all of the
	 * kernel pages and possibly all of memory.
	 *
	 * %rsi holds a physical pointer to real_mode_data.
	 *
	 * We come here either directly from a 64bit bootloader, or from
	 * arch/x86/boot/compressed/head_64.S.
	 *
	 * We only come here initially at boot nothing else comes here.
	 *
	 * Since we may be loaded at an address different from what we were
	 * compiled to run at we first fixup the physical addresses in our page
	 * tables and then reload them.
	 */

	/* Set up the stack for verify_cpu(), similar to initial_stack below */
	leaq	(__end_init_task - SIZEOF_PTREGS)(%rip), %rsp   /* debug: __end_init_task - SIZEOF_PTREGS=0x1403f51, SIZEOF_PTREGS=21*8, 21个寄存器需要保存在内核堆栈的顶端pt_regs, rip=0x1000000, rsp=0x2403f58 */

	leaq	_text(%rip), %rdi   /* debug: _text=-0xf, rdi=0x1000000, rid保存startup_64的内存地址（默认16M处）, rdi为下面调用startup_64_setup_env的第一个参数 */
	pushq	%rsi	/* rsi保存的还是boot_params，位置0x139f0 */
	call	startup_64_setup_env
	popq	%rsi

	/* Now switch to __KERNEL_CS so IRET works reliably */
	pushq	$__KERNEL_CS    /* __KERNEL_CS=0x10 */
	leaq	.Lon_kernel_cs(%rip), %rax  /* lea    0x3(%rip),%rax  # rax=0x1000021 */
	pushq	%rax
	lretq   /* debug: 物理地址0x100001f */

.Lon_kernel_cs:
	UNWIND_HINT_EMPTY

	/* Sanitize CPU configuration */
	call verify_cpu

	/*
	 * Perform pagetable fixups. Additionally, if SME is active, encrypt
	 * the kernel and retrieve the modifier (SME encryption mask if SME
	 * is active) to be added to the initial pgdir entry that will be
	 * programmed into CR3.
	 */
	leaq	_text(%rip), %rdi /* lea    -0x2d(%rip),%rdi        # 0x1000000 */
	pushq	%rsi
	call	__startup_64    /* 初始化early_top_pgt等，返回rax=0 */
	popq	%rsi

	/* Form the CR3 value being sure to include the CR3 modifier */
	addq	$(early_top_pgt - __START_KERNEL_map), %rax /* add    $0x2a6e000,%rax # rax=0，相加后rax=0x2a6e000 */
	jmp 1f  /* jmp    0x1000052 */
SYM_CODE_END(startup_64)

SYM_CODE_START(secondary_startup_64)
	UNWIND_HINT_EMPTY
	/*
	 * At this point the CPU runs in 64bit mode CS.L = 1 CS.D = 0,
	 * and someone has loaded a mapped page table.
	 *
	 * %rsi holds a physical pointer to real_mode_data.
	 *
	 * We come here either from startup_64 (using physical addresses)
	 * or from trampoline.S (using virtual addresses).
	 *
	 * Using virtual addresses from trampoline.S removes the need
	 * to have any identity mapped pages in the kernel page table
	 * after the boot processor executes this code.
	 */

	/* Sanitize CPU configuration */
	call verify_cpu

	/*
	 * The secondary_startup_64_no_verify entry point is only used by
	 * SEV-ES guests. In those guests the call to verify_cpu() would cause
	 * #VC exceptions which can not be handled at this stage of secondary
	 * CPU bringup.
	 *
	 * All non SEV-ES systems, especially Intel systems, need to execute
	 * verify_cpu() above to make sure NX is enabled.
	 */
SYM_INNER_LABEL(secondary_startup_64_no_verify, SYM_L_GLOBAL)
	UNWIND_HINT_EMPTY

	/*
	 * Retrieve the modifier (SME encryption mask if SME is active) to be
	 * added to the initial pgdir entry that will be programmed into CR3.
	 */
	pushq	%rsi
	call	__startup_secondary_64
	popq	%rsi

	/* Form the CR3 value being sure to include the CR3 modifier */
	addq	$(init_top_pgt - __START_KERNEL_map), %rax
1:

	/* Enable PAE mode, PGE and LA57 */
	movl	$(X86_CR4_PAE | X86_CR4_PGE), %ecx  /* debug: 物理地址0x1000052，movl $0xa0,%ecx*/
#ifdef CONFIG_X86_5LEVEL
	testl	$1, __pgtable_l5_enabled(%rip)  /* debug: testl $0x1,0x12d7f47(%rip) */
	jz	1f  /* 默认没有开启LA57，跳转到下面的1f */
	orl	$X86_CR4_LA57, %ecx
1:
#endif
	movq	%rcx, %cr4  /* debug: rcx=0xa0 （设置虚拟8086模式等）*/

	/* Setup early boot stage 4-/5-level pagetables. */
	addq	phys_base(%rip), %rax   /* debug: add 0x1415f9d(%rip),%rax, phys_base(%rip)=0(物理基地址为0), rax=0x2a6e000 */

	/*
	 * For SEV guests: Verify that the C-bit is correct. A malicious
	 * hypervisor could lie about the C-bit position to perform a ROP
	 * attack on the guest by writing to the unencrypted stack and wait for
	 * the next RET instruction.
	 * %rsi carries pointer to realmode data and is callee-clobbered. Save
	 * and restore it.
	 */
	pushq	%rsi
	movq	%rax, %rdi
	call	sev_verify_cbit
	popq	%rsi

	/* Switch to new page-table */
	movq	%rax, %cr3  /* rax=0x2a6e000，加载的是early_top_pgt */

	/* Ensure I am executing from virtual addresses */
	movq	$1f, %rax   /* mov $0xffffffff81000089,%rax */
	ANNOTATE_RETPOLINE_SAFE
	jmp	*%rax   /* debug: 物理地址0x1000087。这里不能直接使用jmp 1f，因为这样是一个相对地址调转（编译器就计算好了相对位置）。因为此刻我们要进入0xffffffff81000000后的高地址空间，必须要使用一个绝对的地址跳转。虚拟地址0xffffffff81000089转换为物理地址的步骤为：cr3 -> early_top_pgt[511] -> level3_kernel_pgt[510] -> level2_kernel_pgt[8]，页表项为0x00000000010001e3(2M页大小)，刚好映射到物理内存16M处。*/
1:
	UNWIND_HINT_EMPTY

	/*
	 * We must switch to a new descriptor in kernel space for the GDT
	 * because soon the kernel won't have access anymore to the userspace
	 * addresses where we're currently running on. We have to do that here
	 * because in 32bit we couldn't load a 64bit linear address.
	 */
	lgdt	early_gdt_descr(%rip)   /* debug: 使用了高地址页表(early_top_gpt)映射后，虚拟地址为0xffffffff81000089(lgdt 0x1415f70(%rip), rip=0xffffffff81000089)。物理地址为0x1000089 */

	/* set up data segments */ /* 将数据段寄存器都清0，为什么呢？？难道下面使用的时候再具体赋值？ */
	xorl %eax,%eax
	movl %eax,%ds
	movl %eax,%ss
	movl %eax,%es

	/*
	 * We don't really need to load %fs or %gs, but load them anyway
	 * to kill any stale realmode selectors.  This allows execution
	 * under VT hardware.
	 */
	movl %eax,%fs
	movl %eax,%gs

	/* Set up %gs.
	 *
	 * The base of %gs always points to fixed_percpu_data. If the
	 * stack protector canary is enabled, it is located at %gs:40.
	 * Note that, on SMP, the boot cpu uses init data section until
	 * the per cpu areas are set up.
	 */
	movl	$MSR_GS_BASE,%ecx   /* debug: mov $0xc0000101,%ecx */
	movl	initial_gs(%rip),%eax
	movl	initial_gs+4(%rip),%edx
	wrmsr

	/*
	 * Setup a boot time stack - Any secondary CPU will have lost its stack
	 * by now because the cr3-switch above unmaps the real-mode stack
	 */
	movq initial_stack(%rip), %rsp

	/* Setup and Load IDT */
	pushq	%rsi
	call	early_setup_idt
	popq	%rsi

	/* Check if nx is implemented */
	movl	$0x80000001, %eax
	cpuid
	movl	%edx,%edi

	/* Setup EFER (Extended Feature Enable Register) */
	movl	$MSR_EFER, %ecx
	rdmsr
	btsl	$_EFER_SCE, %eax	/* Enable System Call */
	btl	$20,%edi		/* No Execute supported? */
	jnc     1f
	btsl	$_EFER_NX, %eax
	btsq	$_PAGE_BIT_NX,early_pmd_flags(%rip)
1:	wrmsr				/* Make changes effective */

	/* Setup cr0 */
	movl	$CR0_STATE, %eax    /* debug: CR0_STATE=0x80050033 */
	/* Make changes effective */
	movq	%rax, %cr0

	/* zero EFLAGS after setting rsp */
	pushq $0
	popfq

	/* rsi is pointer to real mode structure with interesting info.
	   pass it to C */
	movq	%rsi, %rdi

.Ljump_to_C_code:
	/*
	 * Jump to run C code and to be on a real kernel address.
	 * Since we are running on identity-mapped space we have to jump
	 * to the full 64bit address, this is only possible as indirect
	 * jump.  In addition we need to ensure %cs is set so we make this
	 * a far return.
	 *
	 * Note: do not change to far jump indirect with 64bit offset.
	 *
	 * AMD does not support far jump indirect with 64bit offset.
	 * AMD64 Architecture Programmer's Manual, Volume 3: states only
	 *	JMP FAR mem16:16 FF /5 Far jump indirect,
	 *		with the target specified by a far pointer in memory.
	 *	JMP FAR mem16:32 FF /5 Far jump indirect,
	 *		with the target specified by a far pointer in memory.
	 *
	 * Intel64 does support 64bit offset.
	 * Software Developer Manual Vol 2: states:
	 *	FF /5 JMP m16:16 Jump far, absolute indirect,
	 *		address given in m16:16
	 *	FF /5 JMP m16:32 Jump far, absolute indirect,
	 *		address given in m16:32.
	 *	REX.W + FF /5 JMP m16:64 Jump far, absolute indirect,
	 *		address given in m16:64.
	 */
	pushq	$.Lafter_lret	# put return address on stack for unwinder
	xorl	%ebp, %ebp	# clear frame pointer
	movq	initial_code(%rip), %rax    /* debug=> 0xffffffff810000fb:  mov    0x1640c16(%rip),%rax        # 0xffffffff82640d18为initial_code的地址, rax=0xffffffff82a134c4(inital_code就在本文件的头部定义，其值为：x86_64_start_kernel) */
	pushq	$__KERNEL_CS	# set correct cs    debug=> 0xffffffff81000102:  pushq  $0x10
	pushq	%rax		# target address in negative space
	lretq   # debug=> 0xffffffff81000105:  lretq，跳转到arch/x86/kernel/head64.c的x86_64_start_kernel()去执行。
.Lafter_lret:
SYM_CODE_END(secondary_startup_64)

#include "verify_cpu.S"
#include "sev_verify_cbit.S"

#ifdef CONFIG_HOTPLUG_CPU
/*
 * Boot CPU0 entry point. It's called from play_dead(). Everything has been set
 * up already except stack. We just set up stack here. Then call
 * start_secondary() via .Ljump_to_C_code.
 */
SYM_CODE_START(start_cpu0)
	UNWIND_HINT_EMPTY
	movq	initial_stack(%rip), %rsp
	jmp	.Ljump_to_C_code
SYM_CODE_END(start_cpu0)
#endif

#ifdef CONFIG_AMD_MEM_ENCRYPT
/*
 * VC Exception handler used during early boot when running on kernel
 * addresses, but before the switch to the idt_table can be made.
 * The early_idt_handler_array can't be used here because it calls into a lot
 * of __init code and this handler is also used during CPU offlining/onlining.
 * Therefore this handler ends up in the .text section so that it stays around
 * when .init.text is freed.
 */
SYM_CODE_START_NOALIGN(vc_boot_ghcb)
	UNWIND_HINT_IRET_REGS offset=8

	/* Build pt_regs */
	PUSH_AND_CLEAR_REGS

	/* Call C handler */
	movq    %rsp, %rdi
	movq	ORIG_RAX(%rsp), %rsi
	movq	initial_vc_handler(%rip), %rax
	ANNOTATE_RETPOLINE_SAFE
	call	*%rax

	/* Unwind pt_regs */
	POP_REGS

	/* Remove Error Code */
	addq    $8, %rsp

	/* Pure iret required here - don't use INTERRUPT_RETURN */
	iretq
SYM_CODE_END(vc_boot_ghcb)
#endif

	/* Both SMP bootup and ACPI suspend change these variables */
	__REFDATA
	.balign	8
SYM_DATA(initial_code,	.quad x86_64_start_kernel)
SYM_DATA(initial_gs,	.quad INIT_PER_CPU_VAR(fixed_percpu_data))
#ifdef CONFIG_AMD_MEM_ENCRYPT
SYM_DATA(initial_vc_handler,	.quad handle_vc_boot_ghcb)
#endif

/*
 * The SIZEOF_PTREGS gap is a convention which helps the in-kernel unwinder
 * reliably detect the end of the stack.
 */
SYM_DATA(initial_stack, .quad init_thread_union + THREAD_SIZE - SIZEOF_PTREGS) /* initial_stack:计算init_task的内核栈顶地址 */
	__FINITDATA

	__INIT
SYM_CODE_START(early_idt_handler_array)
	i = 0
	.rept NUM_EXCEPTION_VECTORS
	.if ((EXCEPTION_ERRCODE_MASK >> i) & 1) == 0
		UNWIND_HINT_IRET_REGS
		pushq $0	# Dummy error code, to make stack frame uniform
	.else
		UNWIND_HINT_IRET_REGS offset=8
	.endif
	pushq $i		# 72(%rsp) Vector number
	jmp early_idt_handler_common
	UNWIND_HINT_IRET_REGS
	i = i + 1
	.fill early_idt_handler_array + i*EARLY_IDT_HANDLER_SIZE - ., 1, 0xcc
	.endr
	UNWIND_HINT_IRET_REGS offset=16
SYM_CODE_END(early_idt_handler_array)

SYM_CODE_START_LOCAL(early_idt_handler_common)
	/*
	 * The stack is the hardware frame, an error code or zero, and the
	 * vector number.
	 */
	cld

	incl early_recursion_flag(%rip)

	/* The vector number is currently in the pt_regs->di slot. */
	pushq %rsi				/* pt_regs->si */
	movq 8(%rsp), %rsi			/* RSI = vector number */
	movq %rdi, 8(%rsp)			/* pt_regs->di = RDI */
	pushq %rdx				/* pt_regs->dx */
	pushq %rcx				/* pt_regs->cx */
	pushq %rax				/* pt_regs->ax */
	pushq %r8				/* pt_regs->r8 */
	pushq %r9				/* pt_regs->r9 */
	pushq %r10				/* pt_regs->r10 */
	pushq %r11				/* pt_regs->r11 */
	pushq %rbx				/* pt_regs->bx */
	pushq %rbp				/* pt_regs->bp */
	pushq %r12				/* pt_regs->r12 */
	pushq %r13				/* pt_regs->r13 */
	pushq %r14				/* pt_regs->r14 */
	pushq %r15				/* pt_regs->r15 */
	UNWIND_HINT_REGS

	movq %rsp,%rdi		/* RDI = pt_regs; RSI is already trapnr */
	call do_early_exception

	decl early_recursion_flag(%rip)
	jmp restore_regs_and_return_to_kernel
SYM_CODE_END(early_idt_handler_common)

#ifdef CONFIG_AMD_MEM_ENCRYPT
/*
 * VC Exception handler used during very early boot. The
 * early_idt_handler_array can't be used because it returns via the
 * paravirtualized INTERRUPT_RETURN and pv-ops don't work that early.
 *
 * This handler will end up in the .init.text section and not be
 * available to boot secondary CPUs.
 */
SYM_CODE_START_NOALIGN(vc_no_ghcb)
	UNWIND_HINT_IRET_REGS offset=8

	/* Build pt_regs */
	PUSH_AND_CLEAR_REGS

	/* Call C handler */
	movq    %rsp, %rdi
	movq	ORIG_RAX(%rsp), %rsi
	call    do_vc_no_ghcb

	/* Unwind pt_regs */
	POP_REGS

	/* Remove Error Code */
	addq    $8, %rsp

	/* Pure iret required here - don't use INTERRUPT_RETURN */
	iretq
SYM_CODE_END(vc_no_ghcb)
#endif

#define SYM_DATA_START_PAGE_ALIGNED(name)			\
	SYM_START(name, SYM_L_GLOBAL, .balign PAGE_SIZE)

#ifdef CONFIG_PAGE_TABLE_ISOLATION
/*
 * Each PGD needs to be 8k long and 8k aligned.  We do not
 * ever go out to userspace with these, so we do not
 * strictly *need* the second page, but this allows us to
 * have a single set_pgd() implementation that does not
 * need to worry about whether it has 4k or 8k to work
 * with.
 *
 * This ensures PGDs are 8k long:
 */
#define PTI_USER_PGD_FILL	512
/* This ensures they are 8k-aligned: */
#define SYM_DATA_START_PTI_ALIGNED(name) \
	SYM_START(name, SYM_L_GLOBAL, .balign 2 * PAGE_SIZE)
#else
#define SYM_DATA_START_PTI_ALIGNED(name) \
	SYM_DATA_START_PAGE_ALIGNED(name)
#define PTI_USER_PGD_FILL	0
#endif

/* Automate the creation of 1 to 1 mapping pmd entries */
#define PMDS(START, PERM, COUNT)			\
	i = 0 ;						\
	.rept (COUNT) ;					\
	.quad	(START) + (i << PMD_SHIFT) + (PERM) ;	\
	i = i + 1 ;					\
	.endr

	__INITDATA
	.balign 4

SYM_DATA_START_PTI_ALIGNED(early_top_pgt)   /* 8k对齐，early_top_pgt[511]在arch/x86/kernel/head64.c#__startup_64()中被赋值(*p = (unsigned long)level3_kernel_pgt;) */
	.fill	512,8,0
	.fill	PTI_USER_PGD_FILL,8,0 /* PTI_USER_PGD_FILL=512 */
SYM_DATA_END(early_top_pgt)

SYM_DATA_START_PAGE_ALIGNED(early_dynamic_pgts) /* 4k对齐，共64页 */
	.fill	512*EARLY_DYNAMIC_PAGE_TABLES,8,0 /* EARLY_DYNAMIC_PAGE_TABLES=64 */
SYM_DATA_END(early_dynamic_pgts)

SYM_DATA(early_recursion_flag, .long 0)

	.data

#if defined(CONFIG_XEN_PV) || defined(CONFIG_PVH)
SYM_DATA_START_PTI_ALIGNED(init_top_pgt)
	.quad   level3_ident_pgt - __START_KERNEL_map + _KERNPG_TABLE_NOENC /* 第0项 */
	.org    init_top_pgt + L4_PAGE_OFFSET*8, 0
	.quad   level3_ident_pgt - __START_KERNEL_map + _KERNPG_TABLE_NOENC /* 第273项，映射到内核态地址空间开始处0xffff888000000000 */
	.org    init_top_pgt + L4_START_KERNEL*8, 0
	/* (2^48-(2*1024*1024*1024))/(2^39) = 511 */
	.quad   level3_kernel_pgt - __START_KERNEL_map + _PAGE_TABLE_NOENC /* 第511项，映射到0xffffffff80000000处 */
	.fill	PTI_USER_PGD_FILL,8,0
SYM_DATA_END(init_top_pgt)

SYM_DATA_START_PAGE_ALIGNED(level3_ident_pgt)
	.quad	level2_ident_pgt - __START_KERNEL_map + _KERNPG_TABLE_NOENC
	.fill	511, 8, 0
SYM_DATA_END(level3_ident_pgt)
SYM_DATA_START_PAGE_ALIGNED(level2_ident_pgt) /* init_top_pgt的第0项和273项都映射到物理地址的首1G */
	/*
	 * Since I easily can, map the first 1G.
	 * Don't set NX because code runs from these pages.
	 *
	 * Note: This sets _PAGE_GLOBAL despite whether
	 * the CPU supports it or it is enabled.  But,
	 * the CPU should ignore the bit.
	 */
	PMDS(0, __PAGE_KERNEL_IDENT_LARGE_EXEC, PTRS_PER_PMD) /* PTRS_PER_PMD=512 */
SYM_DATA_END(level2_ident_pgt)
#else
SYM_DATA_START_PTI_ALIGNED(init_top_pgt)
	.fill	512,8,0
	.fill	PTI_USER_PGD_FILL,8,0
SYM_DATA_END(init_top_pgt)
#endif

#ifdef CONFIG_X86_5LEVEL
SYM_DATA_START_PAGE_ALIGNED(level4_kernel_pgt)
	.fill	511,8,0
	.quad	level3_kernel_pgt - __START_KERNEL_map + _PAGE_TABLE_NOENC
SYM_DATA_END(level4_kernel_pgt)
#endif

SYM_DATA_START_PAGE_ALIGNED(level3_kernel_pgt)
	.fill	L3_START_KERNEL,8,0
	/* (2^48-(2*1024*1024*1024)-((2^39)*511))/(2^30) = 510 */
	.quad	level2_kernel_pgt - __START_KERNEL_map + _KERNPG_TABLE_NOENC
	.quad	level2_fixmap_pgt - __START_KERNEL_map + _PAGE_TABLE_NOENC
SYM_DATA_END(level3_kernel_pgt)

SYM_DATA_START_PAGE_ALIGNED(level2_kernel_pgt)
	/*
	 * Kernel high mapping.
	 *
	 * The kernel code+data+bss must be located below KERNEL_IMAGE_SIZE in
	 * virtual address space, which is 1 GiB if RANDOMIZE_BASE is enabled,
	 * 512 MiB otherwise.
	 *
	 * (NOTE: after that starts the module area, see MODULES_VADDR.)
	 *
	 * This table is eventually used by the kernel during normal runtime.
	 * Care must be taken to clear out undesired bits later, like _PAGE_RW
	 * or _PAGE_GLOBAL in some cases.
	 */
	PMDS(0, __PAGE_KERNEL_LARGE_EXEC, KERNEL_IMAGE_SIZE/PMD_SIZE)   /* KERNEL_IMAGE_SIZE=1G, PMD_SIZE=21(2M), KERNEL_IMAGE_SIZE/PMD_SIZE=512*/
SYM_DATA_END(level2_kernel_pgt)

SYM_DATA_START_PAGE_ALIGNED(level2_fixmap_pgt)
	.fill	(512 - 4 - FIXMAP_PMD_NUM),8,0
	pgtno = 0
	.rept (FIXMAP_PMD_NUM)
	.quad level1_fixmap_pgt + (pgtno << PAGE_SHIFT) - __START_KERNEL_map \
		+ _PAGE_TABLE_NOENC;
	pgtno = pgtno + 1
	.endr
	/* 6 MB reserved space + a 2MB hole */
	.fill	4,8,0
SYM_DATA_END(level2_fixmap_pgt)

SYM_DATA_START_PAGE_ALIGNED(level1_fixmap_pgt)
	.rept (FIXMAP_PMD_NUM)  /* FIXMAP_PMD_NUM=2 */
	.fill	512,8,0
	.endr
SYM_DATA_END(level1_fixmap_pgt)

#undef PMDS

	.data
	.align 16
/*
 * gdt_page内存块在arch/x86/include/asm/desc.h中定义：
 * struct gdt_page {
 *	struct desc_struct gdt[GDT_ENTRIES];
 * } __attribute__((aligned(PAGE_SIZE)));

 * DECLARE_PER_CPU_PAGE_ALIGNED(struct gdt_page, gdt_page);
 */
SYM_DATA(early_gdt_descr,		.word GDT_ENTRIES*8-1)  /* gdt_page length，early_gdt_descr会被上面lgdt使用来初始化，作为kernel init早期使用。 */
SYM_DATA_LOCAL(early_gdt_descr_base,	.quad INIT_PER_CPU_VAR(gdt_page))   /* gdt_page base address, INIT_PER_CPU_VAR(gdt_page)展开为init_per_cpu__gdt_page, 虚拟地址为0xffffffff829f3000 */

	.align 16
/* This must match the first entry in level2_kernel_pgt */
SYM_DATA(phys_base, .quad 0x0)
EXPORT_SYMBOL(phys_base)

#include "../../x86/xen/xen-head.S"

	__PAGE_ALIGNED_BSS
SYM_DATA_START_PAGE_ALIGNED(empty_zero_page)
	.skip PAGE_SIZE
SYM_DATA_END(empty_zero_page)
EXPORT_SYMBOL(empty_zero_page)

