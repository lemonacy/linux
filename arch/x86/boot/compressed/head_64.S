/* SPDX-License-Identifier: GPL-2.0 */
/*
 *  linux/boot/head.S
 *
 *  Copyright (C) 1991, 1992, 1993  Linus Torvalds
 */

/*
 *  head.S contains the 32-bit startup code.
 *
 * NOTE!!! Startup happens at absolute address 0x00001000, which is also where
 * the page directory will exist. The startup code will be overwritten by
 * the page directory. [According to comments etc elsewhere on a compressed
 * kernel it will end up at 0x1000 + 1Mb I hope so as I assume this. - AC]
 *
 * Page 0 is deliberately kept safe, since System Management Mode code in
 * laptops may need to access the BIOS data stored there.  This is also
 * useful for future device drivers that either access the BIOS via VM86
 * mode.
 */

/*
 * High loaded stuff by Hans Lermen & Werner Almesberger, Feb. 1996
 */
	.code32
	.text

#include <linux/init.h>
#include <linux/linkage.h>
#include <asm/segment.h>
#include <asm/boot.h>
#include <asm/msr.h>
#include <asm/processor-flags.h>
#include <asm/asm-offsets.h>
#include <asm/bootparam.h>
#include <asm/desc_defs.h>
#include <asm/trapnr.h>
#include "pgtable.h"

/*
 * Locally defined symbols should be marked hidden:
 */
	.hidden _bss
	.hidden _ebss
	.hidden _end

	__HEAD

/*
 * This macro gives the relative virtual address of X, i.e. the offset of X
 * from startup_32. This is the same as the link-time virtual address of X,
 * since startup_32 is at 0, but defining it this way tells the
 * assembler/linker that we do not want the actual run-time address of X. This
 * prevents the linker from trying to create unwanted run-time relocation
 * entries for the reference when the compressed kernel is linked as PIE.
 *
 * A reference X(%reg) will result in the link-time VA of X being stored with
 * the instruction, and a run-time R_X86_64_RELATIVE relocation entry that
 * adds the 64-bit base address where the kernel is loaded.
 *
 * Replacing it with (X-startup_32)(%reg) results in the offset being stored,
 * and no run-time relocation.
 *
 * The macro should be used as a displacement with a base register containing
 * the run-time address of startup_32 [i.e. rva(X)(%reg)], or as an immediate
 * [$ rva(X)].
 *
 * This macro can only be used from within the .head.text section, since the
 * expression requires startup_32 to be in the same section as the code being
 * assembled.
 */
#define rva(X) ((X) - startup_32)   // 为什么要定义这种通过相对地址去获取X地址的机制，因为在32位下还没有rip机制，这个rva宏也仅在startup_32中使用，进入到下面的startup_64就可以直接用%rip了

	.code32
    // 默认加载到物理内存1M处, 可以使用qemu来debug完整的内核：qemu-system-x86_64 -smp 1,cores=1,threads=1,sockets=1 -kernel arch/x86/boot/bzImage -initrd initrd.cpio.gz -nographic -append "console=ttyS0 nokaslr" -m 4096 -s -S, GDB：gdb vmlinux -ex 'target remote :1234' -ex 'b *0x100000' -ex 'c', 需要通过物理地址来下断点，不然会跟arch/x86/kernel/head_32.S#startup_32冲突
SYM_FUNC_START(startup_32)
	/*
	 * 32bit entry is 0 and it is ABI so immutable!
	 * If we come here directly from a bootloader,
	 * kernel(text+data+bss+brk) ramdisk, zero_page, command line
	 * all need to be under the 4G limit.
	 */
	cld
	cli

/*
 * Calculate the delta between where we were compiled to run
 * at and where we were actually loaded at.  This can only be done
 * with a short local call on x86.  Nothing  else will tell us what
 * address we are running at.  The reserved chunk of the real-mode
 * data at 0x1e4 (defined as a scratch field) are used as the stack
 * for this calculation. Only 4 bytes are needed.
 */
    // BP_scratch是一个临时的4字节堆栈，用来获取当前代码执行的线性地址（没开启分页之前线性地址就是物理地址，cs,ds段都从0开始）
	leal	(BP_scratch+4)(%esi), %esp  // 此时%esi指向的是boot_params，在pmjump.S#protected_mode_jump中赋的值
	call	1f
1:	popl	%ebp                // 然后从栈上弹出%eip的值到%ebp， debug: %ebp=0x10000d
	subl	$ rva(1b), %ebp     // %ebp减掉label 1:相对startup_32的偏移，则可获取到startup_32的线性地址(因为此时还没有开启分页，所以程序的线性地址即物理地址)。debug: %ebp=0x100000(1M)，和我们理解的32位保护模式从1M开始完全吻合。为什么需要计算startup_32的物理地址呢？因为下面要使用物理地址来操作一些东西，比如下面的lgdt必须要使用物理地址

	/* Load new GDT with the 64bit segments using 32bit descriptor */
    /*
     * gdt内存块就定义在本文件的下面，2(%eax)是把gdt的地址赋值给gdt 6个字节的后面4个字节，
     * 以便lgdt加载6个字节的内容
     */
	leal	rva(gdt)(%ebp), %eax
	movl	%eax, 2(%eax)
	lgdt	(%eax)

	/* Load segment registers with our descriptors */
    /* 因为kernel有可能是被32-bit protocol bootloader加载的，
     * 内核从本文件开始（没有前面的header.S和protected-mode切换），
     * 所有为了安全起见，我们还得把各个段寄存器设置为我们需要的。
     */
	movl	$__BOOT_DS, %eax    // __BOOT_DS=0x18
	movl	%eax, %ds
	movl	%eax, %es
	movl	%eax, %fs
	movl	%eax, %gs
	movl	%eax, %ss

	/* Setup a stack and load CS from current GDT */
	// 因为下面要进行函数调用，所以必须先设置好stack。boot_stack_end就定义在本文件的下面，编译时即分配好了
	leal	rva(boot_stack_end)(%ebp), %esp // boot_stack_end在64位下为16k，32位下为4k

	pushl	$__KERNEL32_CS      // 0x8
	leal	rva(1f)(%ebp), %eax // 取下面129行的label 1:地址
	pushl	%eax
	lretl                       // 上面重新加载了gdt，重新设置了段寄存器，跳一下刷新段寄存器隐藏部分
1:

	/* Setup Exception handling for SEV-ES */
	call	startup32_load_idt  // 开启了CONFIG_AMD_MEM_ENCRYPT才会执行，不然直接ret

	/* Make sure cpu supports long mode. */
	call	verify_cpu          // 内部主要使用cpuid指令来检查CPU是否支持长模式
	testl	%eax, %eax	        // verify_cpu的结果通过eax返回，如果不为0则说明不支持longmode，直接挂起CPU（因为当前文件是64位版本head_64.S，必须支持64位）
	jnz	.Lno_longmode

/*
 * Compute the delta between where we were compiled to run at
 * and where the code will actually run at.
 *
 * %ebp contains the address we are loaded at by the boot loader and %ebx
 * contains the address where we should move the kernel image temporarily
 * for safe in-place decompression.
 */

#ifdef CONFIG_RELOCATABLE
	movl	%ebp, %ebx  /* %ebp=0x100000(startup_32的物理地址) */

#ifdef CONFIG_EFI_STUB
/*
 * If we were loaded via the EFI LoadImage service, startup_32 will be at an
 * offset to the start of the space allocated for the image. efi_pe_entry will
 * set up image_offset to tell us where the image actually starts, so that we
 * can use the full available buffer.
 *	image_offset = startup_32 - image_base
 * Otherwise image_offset will be zero and has no effect on the calculations.
 */
	subl    rva(image_offset)(%ebp), %ebx   /* debug: rva(image_offset)(%ebp)为0 */
#endif
    /*
     * BP_kernel_alignment(%esi) 为2M对齐。
     * decl,addl,notl,andl就是一个(m + (n - 1)) && ~(n - 1)的类似于分宿舍算法，目的是让ebx对齐到2M的内存地址。
     * 执行完成后，%ebp包含了加载时的地址，%ebx包含了内核解压缩的目标地址。
     * CONFIG_PHYSICAL_ALIGN = 2M
     * LOAD_PHYSICAL_ADDR为CONFIG_PHYSICAL_START 2M对齐的位置，默认为16M（可在menuconfig里配置）
     */
	movl	BP_kernel_alignment(%esi), %eax // esi保存的是boot_params的地址，BP_kernel_alignment(%esi)是取kernel_alignment的地址，整条指令的作用是取kernel_alignment的值存入eax，kernel_alignment定义在arch/x86/boot/header.S中（kernel_alignment:  .long CONFIG_PHYSICAL_ALIGN），CONFIG_PHYSICAL_ALIGN可以通过make menuconfig修改，默认值0x200000（2M）。 debug: BP_kernel_alignment(%esi) 为2M
	decl	%eax
	addl	%eax, %ebx
	notl	%eax
	andl	%eax, %ebx  // debug: ebx本来为0x100000，2M对齐后其值为0x200000，但还是小于LOAD_PHYSICAL_ADDR(16M)
	cmpl	$LOAD_PHYSICAL_ADDR, %ebx   // LOAD_PHYSICAL_ADDR定义在arch/x86/include/asm/boot.h中，define LOAD_PHYSICAL_ADDR ((CONFIG_PHYSICAL_START + (CONFIG_PHYSICAL_ALIGN - 1)) & ~(CONFIG_PHYSICAL_ALIGN - 1))，这又是个类似分宿舍的对齐算法，CONFIG_PHYSICAL_ALIGN默认为2M，CONFIG_PHYSICAL_START默认为16M，两者都可以在make menuconfig中修改
	jae	1f
#endif
	movl	$LOAD_PHYSICAL_ADDR, %ebx   // debug: 所以ebx最后还是被赋值为了16M，也是内核将要解压到的地方
1:

	/* Target address to relocate to for decompression */
    // init_size为压缩的内核和解压后内核大小取max，init_size定义在arch/x86/boot/header.S中，有比较复杂的一段宏根据编译期间的数值计算出来的
	addl	BP_init_size(%esi), %ebx    // BP_init_size=0x260(位于第2个扇区), debug: BP_init_size(%esi)为0x2510000(37M+64k, 比未压缩内核arch/x86/boot/compressed/vmlinux.bin(size=0x23E0A48)稍大一点)，%ebx=16M，加之后为%ebx=0x3510000（53M+64k）, 注：这个大小为5.19版本编译出来的x86_64内核大小
    /*
     * _end为压缩后内核的大小（.head.text+.rodata..compressed+.text+.data+.bss），%ebx-_end则得到了压缩内核将要移动到的起始地址
     * 此处为什么要减掉_end，其实道理很简单：9+M的内核(中间包含压缩数据)被bootloader加载到1M处，内核规定解压到16M处，未压缩的内核大小有37+M(BP_init_size)，我们准备了16M至43+M的内存为解压缓冲区。然后我们将9+M的压缩内核从1M的地方移动到16M~53M缓冲区的末尾，大约存在在43~53M左右的内存空间，然后再解压到16M的内存处，这样就自然而然实现了原地解压(inplace-decompression)，而不会发生覆盖现象。此处的_end为compressed/vmlinux.lds.S中定义的_end。
     */
	subl	$ rva(_end), %ebx   // _end为压缩内核的末尾位置，rva(_end)为压缩内核加载到1M内存后对于startup_32的偏移，代表的就是压缩内核的大小（即9M多），减完后ebx为39M多，和推断的一致。 debug: rva(_end)为$0xa0f000（大小和arch/x86/boot/compressed/vmlinux差不多），减完后%ebx为0x2b01000(43+M)

/*
 * Prepare for entering 64 bit mode
 */

	// Enable PAE mode, 开启PAE-物理地址增强模式，32根地址线就变48根了，可以映射到大于4G的物理内存（虽然代码逻辑上只能访问4G大小的空间，但PAE机制可以把这个4G的空间映射到大于4G的物理内存上。），在页表项中第7位叫做PS(PageSize)，如果为1表示其对应的是一个2M的页。下面初始化Level2页表项时，0x183中的8即对应PS位。
	movl	%cr4, %eax
	orl	$X86_CR4_PAE, %eax      // X86_CR4_PAE=0x20
	movl	%eax, %cr4

 /*
  * Build early 4G boot pagetable
  */
	/*
	 * If SEV is active then set the encryption mask in the page tables.
	 * This will insure that when the kernel is copied and decompressed
	 * it will be done so encrypted.
	 */
	call	get_sev_encryption_bit
	xorl	%edx, %edx
#ifdef	CONFIG_AMD_MEM_ENCRYPT
	testl	%eax, %eax
	jz	1f
	subl	$32, %eax	/* Encryption bit is always above bit 31 */
	bts	%eax, %edx	/* Set encryption mask for page tables */
	/*
	 * Set MSR_AMD64_SEV_ENABLED_BIT in sev_status so that
	 * startup32_check_sev_cbit() will do a check. sev_enable() will
	 * initialize sev_status with all the bits reported by
	 * MSR_AMD_SEV_STATUS later, but only MSR_AMD64_SEV_ENABLED_BIT
	 * needs to be set for now.
	 */
	movl	$1, rva(sev_status)(%ebp)
1:
#endif

	/* Initialize Page tables to 0 */
	leal	rva(pgtable)(%ebx), %edi        // %ebx=43+M，pgtable定义在本文件的最后面（6个4k页），在压缩的内核中是占空间的(编译时分配空间)，执行结果是%edi=0x34fc000(52+M)（这个pgtable设置完后立马启用）
	xorl	%eax, %eax
	movl	$(BOOT_INIT_PGT_SIZE/4), %ecx   // BOOT_INIT_PGT_SIZE=6*4096，即6个页表大小
	rep	stosl                               // 此处清空的是未来压缩内核要移动到的大于43M的内存，猜测pgtable位于bzImage的最后面，而且此部分代码也是非压缩的，这样下面建立的页表将来解压缩的时候也不会被覆盖

	/* Build Level 4, 对应48位地址线的47-39位（这里只设置了PLM4中的第0项，够用了） */
	leal	rva(pgtable + 0)(%ebx), %edi    // %ebx=43+M，%edi=53+M
	leal	0x1007 (%edi), %eax	            // 此处%edi偏移0x1007，其中0x1000是PML4自身的大小4k，因为PML4位于pgtable的第一个4k，PML3位于pgtable的第二个4k，PML4中存的PML3页表的地址，所以这里要加0x1000得PLM3的页表位置。0x7是页表的falgs，表示PRESENT+RW+USER
	movl	%eax, 0(%edi)	                // 由于目前初始化的4G地址空间的early page table，所以页表项中的低32位就可以表达
	addl	%edx, 4(%edi)	                // 默认不会开启CONFIG_AMD_MEM_ENCRYPT，%edx=0，无作用

	/* Build Level 3, 对应48位地址线的38-30（这里只设置了PLM3页表中的4项，够用了） */
	leal	rva(pgtable + 0x1000)(%ebx), %edi   // 加0x1000时因为pgtable的第一页被PML4使用了
	leal	0x1007(%edi), %eax                  // 与上面同理，0x1000表示PML2在PML3的后一页
	movl	$4, %ecx	                        // 只设置PML3页表中的4项
1:	movl	%eax, 0x00(%edi)                    // 填充页表项的低32位
	addl	%edx, 0x04(%edi)	                // 默认不会开启CONFIG_AMD_MEM_ENCRYPT，%edx=0，无作用
	addl	$0x00001000, %eax	                // 每个PML2页表也占4k，填完一个要加0x1000才是下一个PML2页表的地址
	addl	$8, %edi                            // 移到下一个PML3中的项，继续填充（64位下一个页表项占8字节）
	decl	%ecx
	jnz	1b

	/* Build Level 2, 对应48位地址线的29-21位（这里设置了2048个2M的PTE，需要4个页面存储）。由于2048个PTE够将低4G空间平铺映射了，所以开启分页后的线性地址和没分页的物理地址一一对应，在下面启动分页机制后，代码的地址无需做任何调整即可继续执行 */
	leal	rva(pgtable + 0x2000)(%ebx), %edi	// 4个PML2页表位于pgtable+(2*0x1000)处
	movl	$0x00000183, %eax	                // flags: 3 - present和write；8 - 页大小是4k还是2M（此处为1，表示2M）；1 - G位(Global)表示全局页，该页将在高速缓冲器TLB中一直保存
	movl	$2048, %ecx	                        // 2048个PTE，2048*2M=4G
1:	movl	%eax, 0(%edi)	                    // PTE从地址0开始映射，所以eax的地址从$0x0000000开始，每次递增0x00200000(2M)
	addl	%edx, 4(%edi)                       // 默认不会开启CONFIG_AMD_MEM_ENCRYPT，%edx=0，无作用
	addl	$0x00200000, %eax                   // 下一个2M页
	addl	$8, %edi                            // 64位下每个PTE占8字节
	decl	%ecx
	jnz	1b

	/* Enable the boot page tables, 上面我们把1个PML4、1个PML3、4个PML2都填充好，接下来就可以更新%cr3了 */
	leal	rva(pgtable)(%ebx), %eax            // %ebx=0x2b01000, %eax=0x34fc000
	movl	%eax, %cr3                          // cr3中存的即为PML4页表的地址(52+M)

	/* Enable Long mode in EFER (Extended Feature Enable Register), MSR是CPU的一组64位寄存器，可以分别通过rdmsr和wrmsr两条指令进行读和写的操作，%ecx指定端口 */
    movl    $MSR_EFER, %ecx                     // MSR_EFER=0xc0000080（MSR寄存器端口）
    rdmsr                                       // rdmsr会根据%ecx的值去读取MSR的内容到%eax
    btsl    $_EFER_LME, %eax                    // _EFER_LME=0x8
    wrmsr                                       // wrmsr会把%eax内容写入%ecx指定的MSR

	/* After ldt is loaded, 这里加载ldt和tr不知道起什么作用？ */
	xorl	%eax, %eax
	lldt	%ax
	movl    $__BOOT_TSS, %eax                   /* __BOOT_TSS = 0x20 */
	ltr	    %ax

	/*
	 * Setup for the jump to 64bit mode
	 *
	 * When the jump is performed we will be in long mode but
	 * in 32bit compatibility mode with EFER.LME = 1, CS.L = 0, CS.D = 1
	 * (and in turn EFER.LMA = 1).	To jump into 64bit mode we use
	 * the new gdt/idt that has __KERNEL_CS with CS.L = 1.
	 * We place all of the values on our mini stack so lret can
	 * used to perform that far jump.
	 */
	leal	rva(startup_64)(%ebp), %eax // %ebp=0x100000, rva(startup_64)(%ebp)=0x100200
#ifdef CONFIG_EFI_MIXED
	movl	rva(efi32_boot_args)(%ebp), %edi
	testl	%edi, %edi
	jz	1f
	leal	rva(efi64_stub_entry)(%ebp), %eax
	movl	rva(efi32_boot_args+4)(%ebp), %esi
	movl	rva(efi32_boot_args+8)(%ebp), %edx	// saved bootparams pointer
	testl	%edx, %edx
	jnz	1f
	/*
	 * efi_pe_entry uses MS calling convention, which requires 32 bytes of
	 * shadow space on the stack even if all arguments are passed in
	 * registers. We also need an additional 8 bytes for the space that
	 * would be occupied by the return address, and this also results in
	 * the correct stack alignment for entry.
	 */
	subl	$40, %esp
	leal	rva(efi_pe_entry)(%ebp), %eax
	movl	%edi, %ecx			// MS calling convention
	movl	%esi, %edx
1:
#endif
	/* Check if the C-bit position is correct when SEV is active */
	call	startup32_check_sev_cbit    // 默认CONFIG_AMD_MEM_ENCRYPT=n，无作用

	pushl	$__KERNEL_CS        // __KERNEL_CS=0x10
	pushl	%eax	            // %eax=startup_64，在栈中压入CS和IP，为下面的lret进入64位长模式做最后的准备

	/* Enter paged protected Mode, activating Long Mode */
	movl	$CR0_STATE, %eax    // CR0_STATE=X86_CR0_PE | X86_CR0_MP | X86_CR0_ET | X86_CR0_NE | X86_CR0_WP | X86_CR0_AM | X86_CR0_PG
	movl	%eax, %cr0

	/* Jump from 32bit compatibility mode into 64bit mode. */
	lret
SYM_FUNC_END(startup_32)

#ifdef CONFIG_EFI_MIXED
	.org 0x190
SYM_FUNC_START(efi32_stub_entry)
	add	$0x4, %esp		/* Discard return address */
	popl	%ecx
	popl	%edx
	popl	%esi

	call	1f
1:	pop	%ebp
	subl	$ rva(1b), %ebp

	movl	%esi, rva(efi32_boot_args+8)(%ebp)
SYM_INNER_LABEL(efi32_pe_stub_entry, SYM_L_LOCAL)
	movl	%ecx, rva(efi32_boot_args)(%ebp)
	movl	%edx, rva(efi32_boot_args+4)(%ebp)
	movb	$0, rva(efi_is64)(%ebp)

	/* Save firmware GDTR and code/data selectors */
	sgdtl	rva(efi32_boot_gdt)(%ebp)
	movw	%cs, rva(efi32_boot_cs)(%ebp)
	movw	%ds, rva(efi32_boot_ds)(%ebp)

	/* Store firmware IDT descriptor */
	sidtl	rva(efi32_boot_idt)(%ebp)

	/* Disable paging */
	movl	%cr0, %eax
	btrl	$X86_CR0_PG_BIT, %eax
	movl	%eax, %cr0

	jmp	startup_32
SYM_FUNC_END(efi32_stub_entry)
#endif

	.code64
	.org 0x200
SYM_CODE_START(startup_64)  // debug: 物理内存地址为0x100200 (gdb中下断点时需要用物理地址b *0x100000，不然会跟arch/x86/kernel/head_64.S#startup_64冲突)
	/*
	 * 64bit entry is 0x200 and it is ABI so immutable!
	 * We come here either from startup_32 or directly from a
	 * 64bit bootloader.
	 * If we come here from a bootloader, kernel(text+data+bss+brk),
	 * ramdisk, zero_page, command line could be above 4G.
	 * We depend on an identity mapped page table being provided
	 * that maps our entire kernel(text+data+bss+brk), zero page
	 * and command line.
	 */

	cld
	cli

	/* Setup data segments. 因为有可能内核是被64位的bootloader加载的，直接就从这里执行，所以还需要重新设置下段寄存器，确保无误 */
	xorl	%eax, %eax
	movl	%eax, %ds
	movl	%eax, %es
	movl	%eax, %ss
	movl	%eax, %fs
	movl	%eax, %gs

	/*
	 * Compute the decompressed kernel start address.  It is where
	 * we were loaded at aligned to a 2M boundary. %rbp contains the
	 * decompressed kernel start address.
	 *
	 * If it is a relocatable kernel then decompress and run the kernel
	 * from load address aligned to 2MB addr, otherwise decompress and
	 * run the kernel from LOAD_PHYSICAL_ADDR
	 *
	 * We cannot rely on the calculation done in 32-bit mode, since we
	 * may have been invoked via the 64-bit entry point.
	 */

	/* Start with the delta to where the kernel will run at. */
#ifdef CONFIG_RELOCATABLE
	leaq	startup_32(%rip) /* - $startup_32 */, %rbp  // %rbp=0x100000

#ifdef CONFIG_EFI_STUB
/*
 * If we were loaded via the EFI LoadImage service, startup_32 will be at an
 * offset to the start of the space allocated for the image. efi_pe_entry will
 * set up image_offset to tell us where the image actually starts, so that we
 * can use the full available buffer.
 *	image_offset = startup_32 - image_base
 * Otherwise image_offset will be zero and has no effect on the calculations.
 */
	movl    image_offset(%rip), %eax
	subq	%rax, %rbp
#endif

	movl	BP_kernel_alignment(%rsi), %eax // %rsi=0x13dd0(boot_params)
	decl	%eax
	addq	%rax, %rbp
	notq	%rax
	andq	%rax, %rbp
	cmpq	$LOAD_PHYSICAL_ADDR, %rbp
	jae	1f
#endif
	movq	$LOAD_PHYSICAL_ADDR, %rbp	// %rbp=0x1000000 (由于内核有可能由64bit bootloader加载，所以这里再次计算内核要解压到的位置16M)
1:

	/* Target address to relocate to for decompression */
	movl	BP_init_size(%rsi), %ebx    // %rsi=0x13dd0(boot_params), %ebx=0x2510000
	subl	$ rva(_end), %ebx           // %ebx=0x1b01000
	addq	%rbp, %rbx	                // %rbp=0x1000000, %rbx=0x2b01000 (计算要将压缩内核移动到的位置(43+M))

	/* Set up the stack */
	leaq	rva(boot_stack_end)(%rbx), %rsp // %rbp=0x1000000, %rbx=0x2b01000, rsp=0x34f7500, boot_stack_end位于压缩内核的尾部(52+M)

	/*
	 * At this point we are in long mode with 4-level paging enabled,
	 * but we might want to enable 5-level paging or vice versa.
	 *
	 * The problem is that we cannot do it directly. Setting or clearing
	 * CR4.LA57 in long mode would trigger #GP. So we need to switch off
	 * long mode and paging first.
	 *
	 * We also need a trampoline in lower memory to switch over from
	 * 4- to 5-level paging for cases when the bootloader puts the kernel
	 * above 4G, but didn't enable 5-level paging for us.
	 *
	 * The same trampoline can be used to switch from 5- to 4-level paging
	 * mode, like when starting 4-level paging kernel via kexec() when
	 * original kernel worked in 5-level paging mode.
	 *
	 * For the trampoline, we need the top page table to reside in lower
	 * memory as we don't have a way to load 64-bit values into CR3 in
	 * 32-bit mode.
	 *
	 * We go though the trampoline even if we don't have to: if we're
	 * already in a desired paging mode. This way the trampoline code gets
	 * tested on every boot.
	 */

	/* Make sure we have GDT with 32-bit code segment */
	leaq	gdt64(%rip), %rax	// %rax=0xae2210(10+M), 在长模式下，可以通过rip+偏移取到数据变量的地址，很方便
	addq	%rax, 2(%rax)	    // gdt64的首2个字节存放的是limit，编译的时候已经计算好。2(%rax)是存储4个字节的gdt地址
	lgdt	(%rax)

	/* Reload CS so IRET returns to a CS actually in the GDT */
	pushq	$__KERNEL_CS                // __KERNEL_CS=0x10
	leaq	.Lon_kernel_cs(%rip), %rax  // %rax=0x10026f
	pushq	%rax
	lretq

.Lon_kernel_cs:                         // 0x10026f

	pushq	%rsi
	call	load_stage1_idt
	popq	%rsi

#ifdef CONFIG_AMD_MEM_ENCRYPT
	/*
	 * Now that the stage1 interrupt handlers are set up, #VC exceptions from
	 * CPUID instructions can be properly handled for SEV-ES guests.
	 *
	 * For SEV-SNP, the CPUID table also needs to be set up in advance of any
	 * CPUID instructions being issued, so go ahead and do that now via
	 * sev_enable(), which will also handle the rest of the SEV-related
	 * detection/setup to ensure that has been done in advance of any dependent
	 * code.
	 */
	pushq	%rsi
	movq	%rsi, %rdi		/* real mode address, %rsi=0x13dd0(boot_params) */
	call	sev_enable
	popq	%rsi
#endif

	/*
	 * paging_prepare() sets up the trampoline and checks if we need to
	 * enable 5-level paging.
	 *
	 * paging_prepare() returns a two-quadword structure which lands
	 * into RDX:RAX:
	 *   - Address of the trampoline is returned in RAX.
	 *   - Non zero RDX means trampoline needs to enable 5-level
	 *     paging.
	 *
	 * RSI holds real mode data and needs to be preserved across
	 * this function call.
	 */
	pushq	%rsi            // %rsi=0x13dd0(boot_params)
	movq	%rsi, %rdi		/* real mode address */
	call	paging_prepare
	popq	%rsi

	/* Save the trampoline address in RCX */
	movq	%rax, %rcx      // %rax=0x9d000, %rcx=0x9d000

	/*
	 * Load the address of trampoline_return() into RDI.
	 * It will be used by the trampoline to return to the main code.
	 */
	leaq	trampoline_return(%rip), %rdi   // %rdi=0x100296(trampoline_return)

	/* Switch to compatibility mode (CS.L = 0 CS.D = 1) via far return */
	pushq	$__KERNEL32_CS                              // __KERNEL32_CS=0x8
	leaq	TRAMPOLINE_32BIT_CODE_OFFSET(%rax), %rax    // %rax=0x9d000, TRAMPOLINE_32BIT_CODE_OFFSET=PAGE_SIZE, %rax=0x9e000
	pushq	%rax
	lretq                                               // 这里会跳转到trampoline_32bit_src去执行，再jmp *%rdi回到trampoline_return:来执行
trampoline_return:
	/* Restore the stack, the 32-bit trampoline uses its own stack */
	leaq	rva(boot_stack_end)(%rbx), %rsp             // %rbx=0x2b01000,rva(boot_stack_end)=0x9F6500, %rsp=0x34f7500(52+M)

	/*
	 * cleanup_trampoline() would restore trampoline memory.
	 *
	 * RDI is address of the page table to use instead of page table
	 * in trampoline memory (if required).
	 *
	 * RSI holds real mode data and needs to be preserved across
	 * this function call.
	 */
	pushq	%rsi                            // %rsi=0x13dd0(boot_params)
	leaq	rva(top_pgtable)(%rbx), %rdi    // %rbx=0x2b01000, 0xa0e000, %rdi=0x350f000(解压缩空间的最后4k)
	call	cleanup_trampoline
	popq	%rsi

	/* Zero EFLAGS */
	pushq	$0
	popfq

/*
 * Copy the compressed kernel to the end of our buffer
 * where decompression in place becomes safe. 移动压缩内核到buffer的末尾
 */
	pushq	%rsi                        // %rsi=0x13dd0(boot_params)
	leaq	(_bss-8)(%rip), %rsi        // _bss-8=0x9e2242, rip=0x1002af, rsi=0xae24f8
	leaq	rva(_bss-8)(%rbx), %rdi     // rva(_bss-8)=0x9e24f8, rbx=0x2b01000, rdi=0x34e34f8 */
	movl	$(_bss - startup_32), %ecx  // %ecx=0x9e2500 (内核大小为9+M，符合我们的预期)
	shrl	$3, %ecx
	std                                 // 从后往前每次移动8字节（当前正在执行的此文件代码也会移动到43+M去）
	rep	movsq
	cld
	popq	%rsi

	/*
	 * The GDT may get overwritten either during the copy we just did or
	 * during extract_kernel below. To avoid any issues, repoint the GDTR
	 * to the new copy of the GDT.
	 */
	leaq	rva(gdt64)(%rbx), %rax  // %rbx=0x2b01000, rva(gdt64)=0x9e2210, %rax=0x34e3210 (gdt64只定义了limit和address，共享了gdt的内容)
	leaq	rva(gdt)(%rbx), %rdx
	movq	%rdx, 2(%rax)           // 这里为什么要偏移2个字节的位置，因为gdt中的前2个字节定义了gdt的limit
	lgdt	(%rax)                  // 加载52+M处的gdt64

/*
 * Jump to the relocated address.
 */
	leaq	rva(.Lrelocated)(%rbx), %rax    // %rbx=0x2b01000, rva(.Lrelocated)=0x9d3bc0, rax=0x34d4bc0
	jmp	*%rax                               // debug: 物理地址0x1002e7, %rax=0x34d4bc0，这条指令是在1M多地址上执行的最后一条指令，马上就要跳转到移动后的未解压内核去执行了(52+M)
SYM_CODE_END(startup_64)

#ifdef CONFIG_EFI_STUB
	.org 0x390
SYM_FUNC_START(efi64_stub_entry)
	and	$~0xf, %rsp			/* realign the stack */
	movq	%rdx, %rbx			/* save boot_params pointer */
	call	efi_main
	movq	%rbx,%rsi
	leaq	rva(startup_64)(%rax), %rax
	jmp	*%rax
SYM_FUNC_END(efi64_stub_entry)
SYM_FUNC_ALIAS(efi_stub_entry, efi64_stub_entry)
#endif

	.text
SYM_FUNC_START_LOCAL_NOALIGN(.Lrelocated)
/* debug: 已经将内核从原来1M开始的9+M位置复制到了43+M处，并跳转到移动后的内核代码中继续执行（此时尚未解压） */
/*
 * Clear BSS (stack is currently empty)
 */
	xorl	%eax, %eax  // debug: 物理地址0x34d4bc0。为什么这块的地址一下跳到了52+M处，因为从vmlinux.lds.S中可看到，.text的section是放到了压缩内核(.rodata..compressed)的后面，所以此处的.text代码差不多位于内核文件的最末端了
	leaq    _bss(%rip), %rdi    // _bss=0xe937, %rip=0x34d4bc2, %rdi=0x34e3500, bss段和.text段挨得比较近（都在9+M压缩内核的末端）
	leaq    _ebss(%rip), %rcx   // _ebss=0x269c8, %rcx=0x34fb598
	subq	%rdi, %rcx          // _ebss-_bss=0x18098, 有96k的bss空间
	shrq	$3, %rcx
	rep	stosq                   // 清空bss

	pushq	%rsi                // %rsi=0x13dd0(boot_params)
	call	load_stage2_idt

	/* Pass boot_params to initialize_identity_maps() */
	movq	(%rsp), %rdi        // %rdi是函数调用的第一个参数
	call	initialize_identity_maps
	popq	%rsi

/*
 * Do the extraction, and jump to the new kernel..
 */
	pushq	%rsi			/* Save the real mode argument, %rsi=0x13dd0(boot_params) */
	movq	%rsi, %rdi		/* real mode address */ // %rdi=0x13dd0, 接下来为extract_kernel()准备6个参数：%rdi, %rsi, %rdx, %ecx, %r8, %r9d (r9d表示r9的低32位)
	leaq	boot_heap(%rip), %rsi	/* malloc area for uncompression, %rsi=0x34e3500 */
	leaq	input_data(%rip), %rdx  /* %rdx=0x2b0140d. input_data, input_len, output_len都是由arch/x86/boot/compressed/mkpiggy.c动态生成一个piggy.S汇编文件生成的，可通过piggy.S来查看。5.19版本debug模式下input_len=0x9D37B0, output_len=0x248EF48 */
	movl	input_len(%rip), %ecx	/* input_len, %ecx=0x9d37b0(9+M) */
	movq	%rbp, %r8		        /* output target address, %r8=0x1000000. rbp在上面的423行被赋值为LOAD_PHYSICAL_ADDR，而LOAD_PHYSICAL_ADDR又是在boot.h中根据CONFIG_PHYSICAL_START配置按2M取整计算出来的（#define LOAD_PHYSICAL_ADDR ((CONFIG_PHYSICAL_START + (CONFIG_PHYSICAL_ALIGN - 1)) & ~(CONFIG_PHYSICAL_ALIGN - 1))），CONFIG_PHYSICAL_START默认被定位为了0x1000000(16M) */
	movl	output_len(%rip), %r9d	/* %r9d=0x248ef48. decompressed length, end of relocs*/
	call	extract_kernel		    /* returns kernel location in %rax, extract_kernel方法执行完后将解压内核的起始地址通过rax返回，接下来就调整到这个位置去继续执行代码。%rax=0x1000000 */

	popq	%rsi                    /* %rsi=0x13dd0(boot_params) */

/*
 * Jump to the decompressed kernel.
 */
	jmp	*%rax                       /* debug: 物理地址0x34d4c12，%rax=0x1000000 (如果启动命令行参数带nokaslr则rax=0x1000000(16M)，否则位置就随机了)，下面就跳转到arch/x86/kernel/head_64.S去执行了。 */
SYM_FUNC_END(.Lrelocated)

	.code32
/*
 * This is the 32-bit trampoline that will be copied over to low memory.
 *
 * RDI contains the return address (might be above 4G).
 * ECX contains the base address of the trampoline memory.
 * Non zero RDX means trampoline needs to enable 5-level paging.
 */
SYM_CODE_START(trampoline_32bit_src)
	/* Set up data and stack segments */
	movl	$__KERNEL_DS, %eax      // __KERNEL_DS=0x18
	movl	%eax, %ds
	movl	%eax, %ss

	/* Set up new stack */
	leal	TRAMPOLINE_32BIT_STACK_END(%ecx), %esp

	/* Disable paging */
	movl	%cr0, %eax
	btrl	$X86_CR0_PG_BIT, %eax
	movl	%eax, %cr0

	/* Check what paging mode we want to be in after the trampoline */
	testl	%edx, %edx
	jz	1f

	/* We want 5-level paging: don't touch CR3 if it already points to 5-level page tables */
	movl	%cr4, %eax
	testl	$X86_CR4_LA57, %eax
	jnz	3f
	jmp	2f
1:
	/* We want 4-level paging: don't touch CR3 if it already points to 4-level page tables */
	movl	%cr4, %eax
	testl	$X86_CR4_LA57, %eax
	jz	3f
2:
	/* Point CR3 to the trampoline's new top level page table */
	leal	TRAMPOLINE_32BIT_PGTABLE_OFFSET(%ecx), %eax
	movl	%eax, %cr3
3:
	/* Set EFER.LME=1 as a precaution in case hypervsior pulls the rug */
	pushl	%ecx
	pushl	%edx
	movl	$MSR_EFER, %ecx
	rdmsr
	btsl	$_EFER_LME, %eax
	/* Avoid writing EFER if no change was made (for TDX guest) */
	jc	1f
	wrmsr
1:	popl	%edx
	popl	%ecx

#ifdef CONFIG_X86_MCE
	/*
	 * Preserve CR4.MCE if the kernel will enable #MC support.
	 * Clearing MCE may fault in some environments (that also force #MC
	 * support). Any machine check that occurs before #MC support is fully
	 * configured will crash the system regardless of the CR4.MCE value set
	 * here.
	 */
	movl	%cr4, %eax
	andl	$X86_CR4_MCE, %eax
#else
	movl	$0, %eax
#endif

	/* Enable PAE and LA57 (if required) paging modes */
	orl	$X86_CR4_PAE, %eax
	testl	%edx, %edx
	jz	1f
	orl	$X86_CR4_LA57, %eax
1:
	movl	%eax, %cr4

	/* Calculate address of paging_enabled() once we are executing in the trampoline */
	leal	.Lpaging_enabled - trampoline_32bit_src + TRAMPOLINE_32BIT_CODE_OFFSET(%ecx), %eax

	/* Prepare the stack for far return to Long Mode */
	pushl	$__KERNEL_CS
	pushl	%eax

	/* Enable paging again. */
	movl	%cr0, %eax
	btsl	$X86_CR0_PG_BIT, %eax
	movl	%eax, %cr0

	lret
SYM_CODE_END(trampoline_32bit_src)

	.code64
SYM_FUNC_START_LOCAL_NOALIGN(.Lpaging_enabled)
	/* Return from the trampoline */
	jmp	*%rdi                   // %rdi中存的是trampoline_return: label的地址
SYM_FUNC_END(.Lpaging_enabled)

	/*
         * The trampoline code has a size limit.
         * Make sure we fail to compile if the trampoline code grows
         * beyond TRAMPOLINE_32BIT_CODE_SIZE bytes.
	 */
	.org	trampoline_32bit_src + TRAMPOLINE_32BIT_CODE_SIZE

	.code32
SYM_FUNC_START_LOCAL_NOALIGN(.Lno_longmode)
	/* This isn't an x86-64 CPU, so hang intentionally, we cannot continue */
1:
	hlt
	jmp     1b
SYM_FUNC_END(.Lno_longmode)

#include "../../kernel/verify_cpu.S"

	.data
SYM_DATA_START_LOCAL(gdt64)
	.word	gdt_end - gdt - 1
	.quad   gdt - gdt64
SYM_DATA_END(gdt64)
	.balign	8
SYM_DATA_START_LOCAL(gdt)
	.word	gdt_end - gdt - 1
	.long	0
	.word	0
	.quad	0x00cf9a000000ffff	/* __KERNEL32_CS */
	.quad	0x00af9a000000ffff	/* __KERNEL_CS */
	.quad	0x00cf92000000ffff	/* __KERNEL_DS */
	.quad	0x0080890000000000	/* TS descriptor */
	.quad   0x0000000000000000	/* TS continued */
SYM_DATA_END_LABEL(gdt, SYM_L_LOCAL, gdt_end)

SYM_DATA_START(boot_idt_desc)
	.word	boot_idt_end - boot_idt - 1
	.quad	0
SYM_DATA_END(boot_idt_desc)
	.balign 8
SYM_DATA_START(boot_idt)
	.rept	BOOT_IDT_ENTRIES
	.quad	0
	.quad	0
	.endr
SYM_DATA_END_LABEL(boot_idt, SYM_L_GLOBAL, boot_idt_end)

#ifdef CONFIG_AMD_MEM_ENCRYPT
SYM_DATA_START(boot32_idt_desc)
	.word   boot32_idt_end - boot32_idt - 1
	.long   0
SYM_DATA_END(boot32_idt_desc)
	.balign 8
SYM_DATA_START(boot32_idt)
	.rept 32
	.quad 0
	.endr
SYM_DATA_END_LABEL(boot32_idt, SYM_L_GLOBAL, boot32_idt_end)
#endif

#ifdef CONFIG_EFI_STUB
SYM_DATA(image_offset, .long 0)
#endif
#ifdef CONFIG_EFI_MIXED
SYM_DATA_LOCAL(efi32_boot_args, .long 0, 0, 0)
SYM_DATA(efi_is64, .byte 1)

#define ST32_boottime		60 // offsetof(efi_system_table_32_t, boottime)
#define BS32_handle_protocol	88 // offsetof(efi_boot_services_32_t, handle_protocol)
#define LI32_image_base		32 // offsetof(efi_loaded_image_32_t, image_base)

	__HEAD
	.code32
SYM_FUNC_START(efi32_pe_entry)
/*
 * efi_status_t efi32_pe_entry(efi_handle_t image_handle,
 *			       efi_system_table_32_t *sys_table)
 */

	pushl	%ebp
	movl	%esp, %ebp
	pushl	%eax				// dummy push to allocate loaded_image

	pushl	%ebx				// save callee-save registers
	pushl	%edi

	call	verify_cpu			// check for long mode support
	testl	%eax, %eax
	movl	$0x80000003, %eax		// EFI_UNSUPPORTED
	jnz	2f

	call	1f
1:	pop	%ebx
	subl	$ rva(1b), %ebx

	/* Get the loaded image protocol pointer from the image handle */
	leal	-4(%ebp), %eax
	pushl	%eax				// &loaded_image
	leal	rva(loaded_image_proto)(%ebx), %eax
	pushl	%eax				// pass the GUID address
	pushl	8(%ebp)				// pass the image handle

	/*
	 * Note the alignment of the stack frame.
	 *   sys_table
	 *   handle             <-- 16-byte aligned on entry by ABI
	 *   return address
	 *   frame pointer
	 *   loaded_image       <-- local variable
	 *   saved %ebx		<-- 16-byte aligned here
	 *   saved %edi
	 *   &loaded_image
	 *   &loaded_image_proto
	 *   handle             <-- 16-byte aligned for call to handle_protocol
	 */

	movl	12(%ebp), %eax			// sys_table
	movl	ST32_boottime(%eax), %eax	// sys_table->boottime
	call	*BS32_handle_protocol(%eax)	// sys_table->boottime->handle_protocol
	addl	$12, %esp			// restore argument space
	testl	%eax, %eax
	jnz	2f

	movl	8(%ebp), %ecx			// image_handle
	movl	12(%ebp), %edx			// sys_table
	movl	-4(%ebp), %esi			// loaded_image
	movl	LI32_image_base(%esi), %esi	// loaded_image->image_base
	movl	%ebx, %ebp			// startup_32 for efi32_pe_stub_entry
	/*
	 * We need to set the image_offset variable here since startup_32() will
	 * use it before we get to the 64-bit efi_pe_entry() in C code.
	 */
	subl	%esi, %ebx
	movl	%ebx, rva(image_offset)(%ebp)	// save image_offset
	jmp	efi32_pe_stub_entry

2:	popl	%edi				// restore callee-save registers
	popl	%ebx
	leave
	RET
SYM_FUNC_END(efi32_pe_entry)

	.section ".rodata"
	/* EFI loaded image protocol GUID */
	.balign 4
SYM_DATA_START_LOCAL(loaded_image_proto)
	.long	0x5b1b31a1
	.word	0x9562, 0x11d2
	.byte	0x8e, 0x3f, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b
SYM_DATA_END(loaded_image_proto)
#endif

#ifdef CONFIG_AMD_MEM_ENCRYPT
	__HEAD
	.code32
/*
 * Write an IDT entry into boot32_idt
 *
 * Parameters:
 *
 * %eax:	Handler address
 * %edx:	Vector number
 *
 * Physical offset is expected in %ebp
 */
SYM_FUNC_START(startup32_set_idt_entry)
	push    %ebx
	push    %ecx

	/* IDT entry address to %ebx */
	leal    rva(boot32_idt)(%ebp), %ebx
	shl	$3, %edx
	addl    %edx, %ebx

	/* Build IDT entry, lower 4 bytes */
	movl    %eax, %edx
	andl    $0x0000ffff, %edx	    # Target code segment offset [15:0]
	movl    $__KERNEL32_CS, %ecx	# Target code segment selector
	shl     $16, %ecx
	orl     %ecx, %edx

	/* Store lower 4 bytes to IDT */
	movl    %edx, (%ebx)

	/* Build IDT entry, upper 4 bytes */
	movl    %eax, %edx
	andl    $0xffff0000, %edx	# Target code segment offset [31:16]
	orl     $0x00008e00, %edx	# Present, Type 32-bit Interrupt Gate

	/* Store upper 4 bytes to IDT */
	movl    %edx, 4(%ebx)

	pop     %ecx
	pop     %ebx
	RET
SYM_FUNC_END(startup32_set_idt_entry)
#endif

SYM_FUNC_START(startup32_load_idt)
#ifdef CONFIG_AMD_MEM_ENCRYPT
	/* #VC handler */
	leal    rva(startup32_vc_handler)(%ebp), %eax
	movl    $X86_TRAP_VC, %edx
	call    startup32_set_idt_entry

	/* Load IDT */
	leal	rva(boot32_idt)(%ebp), %eax
	movl	%eax, rva(boot32_idt_desc+2)(%ebp)
	lidt    rva(boot32_idt_desc)(%ebp)
#endif
	RET
SYM_FUNC_END(startup32_load_idt)

/*
 * Check for the correct C-bit position when the startup_32 boot-path is used.
 *
 * The check makes use of the fact that all memory is encrypted when paging is
 * disabled. The function creates 64 bits of random data using the RDRAND
 * instruction. RDRAND is mandatory for SEV guests, so always available. If the
 * hypervisor violates that the kernel will crash right here.
 *
 * The 64 bits of random data are stored to a memory location and at the same
 * time kept in the %eax and %ebx registers. Since encryption is always active
 * when paging is off the random data will be stored encrypted in main memory.
 *
 * Then paging is enabled. When the C-bit position is correct all memory is
 * still mapped encrypted and comparing the register values with memory will
 * succeed. An incorrect C-bit position will map all memory unencrypted, so that
 * the compare will use the encrypted random data and fail.
 */
SYM_FUNC_START(startup32_check_sev_cbit)
#ifdef CONFIG_AMD_MEM_ENCRYPT
	pushl	%eax
	pushl	%ebx
	pushl	%ecx
	pushl	%edx

	/* Check for non-zero sev_status */
	movl	rva(sev_status)(%ebp), %eax
	testl	%eax, %eax
	jz	4f

	/*
	 * Get two 32-bit random values - Don't bail out if RDRAND fails
	 * because it is better to prevent forward progress if no random value
	 * can be gathered.
	 */
1:	rdrand	%eax
	jnc	1b
2:	rdrand	%ebx
	jnc	2b

	/* Store to memory and keep it in the registers */
	movl	%eax, rva(sev_check_data)(%ebp)
	movl	%ebx, rva(sev_check_data+4)(%ebp)

	/* Enable paging to see if encryption is active */
	movl	%cr0, %edx			 /* Backup %cr0 in %edx */
	movl	$(X86_CR0_PG | X86_CR0_PE), %ecx /* Enable Paging and Protected mode */
	movl	%ecx, %cr0

	cmpl	%eax, rva(sev_check_data)(%ebp)
	jne	3f
	cmpl	%ebx, rva(sev_check_data+4)(%ebp)
	jne	3f

	movl	%edx, %cr0	/* Restore previous %cr0 */

	jmp	4f

3:	/* Check failed - hlt the machine */
	hlt
	jmp	3b

4:
	popl	%edx
	popl	%ecx
	popl	%ebx
	popl	%eax
#endif
	RET
SYM_FUNC_END(startup32_check_sev_cbit)

/*
 * Stack and heap for uncompression
 */
	.bss
	.balign 4
SYM_DATA_LOCAL(boot_heap,	.fill BOOT_HEAP_SIZE, 1, 0)

SYM_DATA_START_LOCAL(boot_stack)
	.fill BOOT_STACK_SIZE, 1, 0
	.balign 16
SYM_DATA_END_LABEL(boot_stack, SYM_L_LOCAL, boot_stack_end)

/*
 * Space for page tables (not in .bss so not zeroed)
 */
	.section ".pgtable","aw",@nobits
	.balign 4096
SYM_DATA_LOCAL(pgtable,		.fill BOOT_PGT_SIZE, 1, 0)  /* BOOT_PGT_SIZE定义在arch/x86/include/asm/boot.h中，默认6*4096。检查到CONFIG_RANDOMIZE_BASE和CONFIG_X86_VERBOSE_BOOTUP在编译的时候默认都是y，所以这块的BOOT_PGT_SIZE其实有19*4096大小 *

/*
 * The page table is going to be used instead of page table in the trampoline
 * memory.
 */
SYM_DATA_LOCAL(top_pgtable,	.fill PAGE_SIZE, 1, 0)
