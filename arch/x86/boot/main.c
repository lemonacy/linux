// SPDX-License-Identifier: GPL-2.0-only
/* -*- linux-c -*- ------------------------------------------------------- *
 *
 *   Copyright (C) 1991, 1992 Linus Torvalds
 *   Copyright 2007 rPath, Inc. - All Rights Reserved
 *   Copyright 2009 Intel Corporation; author H. Peter Anvin
 *
 * ----------------------------------------------------------------------- */

/*
 * Main module for the real-mode kernel code
 */
#include <linux/build_bug.h>

#include "boot.h"
#include "string.h"

struct boot_params boot_params __attribute__((aligned(16)));    // boot_params变量定义在arch/x86/boot/main.c#18

struct port_io_ops pio_ops;

char *HEAP = _end;
char *heap_end = _end;		/* Default end of heap = no heap */

/*
 * Copy the header into the boot parameter block.  Since this
 * screws up the old-style command line protocol, adjust by
 * filling in the new-style command line pointer instead.
 */

static void copy_boot_params(void)
{
	struct old_cmdline {
		u16 cl_magic;
		u16 cl_offset;
	};
	const struct old_cmdline * const oldcmd =
		absolute_pointer(OLD_CL_ADDRESS);

	BUILD_BUG_ON(sizeof(boot_params) != 4096);
	memcpy(&boot_params.hdr, &hdr, sizeof(hdr));    // hdr定义在header.S中：.globl  hdr，一些内容是build时填充的，一些是bootloader加载时填充的

	if (!boot_params.hdr.cmd_line_ptr &&
	    oldcmd->cl_magic == OLD_CL_MAGIC) {
		/* Old-style command line protocol. */
		u16 cmdline_seg;

		/* Figure out if the command line falls in the region
		   of memory that an old kernel would have copied up
		   to 0x90000... */
		if (oldcmd->cl_offset < boot_params.hdr.setup_move_size)
			cmdline_seg = ds();
		else
			cmdline_seg = 0x9000;

		boot_params.hdr.cmd_line_ptr =
			(cmdline_seg << 4) + oldcmd->cl_offset;
	}
}

/*
 * Query the keyboard lock status as given by the BIOS, and
 * set the keyboard repeat rate to maximum.  Unclear why the latter
 * is done here; this might be possible to kill off as stale code.
 */
static void keyboard_init(void)
{
	struct biosregs ireg, oreg;
	initregs(&ireg);

	ireg.ah = 0x02;		/* Get keyboard status */
	intcall(0x16, &ireg, &oreg);    // 0x16号BIOS中断用来操作PC键盘
	boot_params.kbd_status = oreg.al;

	ireg.ax = 0x0305;	/* Set keyboard repeat rate */
	intcall(0x16, &ireg, NULL);
}

/*
 * Get Intel SpeedStep (IST) information.
 */
static void query_ist(void)
{
	struct biosregs ireg, oreg;

	/* Some older BIOSes apparently crash on this call, so filter
	   it from machines too old to have SpeedStep at all. */
	if (cpu.level < 6)
		return;

	initregs(&ireg);
	ireg.ax  = 0xe980;	 /* IST Support */
	ireg.edx = 0x47534943;	 /* Request value */
	intcall(0x15, &ireg, &oreg);

	boot_params.ist_info.signature  = oreg.eax;
	boot_params.ist_info.command    = oreg.ebx;
	boot_params.ist_info.event      = oreg.ecx;
	boot_params.ist_info.perf_level = oreg.edx;
}

/*
 * Tell the BIOS what CPU mode we intend to run in.
 */
static void set_bios_mode(void)
{
#ifdef CONFIG_X86_64
	struct biosregs ireg;

	initregs(&ireg);
	ireg.ax = 0xec00;
	ireg.bx = 2;
	intcall(0x15, &ireg, NULL);
#endif
}

static void init_heap(void)
{
	char *stack_end;

	if (boot_params.hdr.loadflags & CAN_USE_HEAP) {
		asm("leal %P1(%%esp),%0"
		    : "=r" (stack_end) : "i" (-STACK_SIZE));

		heap_end = (char *)
			((size_t)boot_params.hdr.heap_end_ptr + 0x200);
		if (heap_end > stack_end)
			heap_end = stack_end;
	} else {
		/* Boot protocol 2.00 only, no heap available */
		puts("WARNING: Ancient bootloader, some functionality "
		     "may be limited!\n");
	}
}

void main(void)
{
	puts("enter C-code main in 16-bit\n");	/* puts()通过bios int 0x10中断输出到屏幕上，无需console_init()即可使用。在syslinux-fdimage.img下可成功打印出来 */
	init_default_io_ops();
	/* First, copy the boot header into the "zeropage" */
	copy_boot_params(); // 做的事情很简单，就是从bootsec中把那一堆参数赋值到C语言的变量boot_params中，方便后面的引用

	/* Initialize the early-boot console */
	console_init();

	/* asran debug info: early_serial_base即为串口的port。如果在cmd_line中定义了serial,0x3f8,115200，则puts()除输出一份到console外，还会输出一份到串口终端上。比如在机房里启动linux时，如果想看boot早期的输出，则需要定义此参数。 */
	if(early_serial_base == 0x3f8)
		puts("early_serial_base=0x3f8\n");
	else if (early_serial_base == 0x2f8)
		puts("early_serial_base=0x2f8\n");
	else if (early_serial_base == 0)
		puts("early_serial_base=0\n");
	else
		puts("early_serial_base=else\n");

	if (cmdline_find_option_bool("debug"))
		puts("early console in setup code\n");

	/* End of heap check */
	init_heap();

	/* Make sure we have all the proper CPU support */
	if (validate_cpu()) {
		puts("Unable to boot - please use a kernel appropriate "
		     "for your CPU.\n");
		die();
	}

	/* Tell the BIOS what CPU mode we intend to run in. */
	set_bios_mode();

	/* Detect memory layout */
	detect_memory();

	/* Set keyboard repeat rate (why?) and query the lock flags */
	keyboard_init();

	/* Query Intel SpeedStep (IST) information */
	query_ist();

	/* Query APM information */
#if defined(CONFIG_APM) || defined(CONFIG_APM_MODULE)
	query_apm_bios();
#endif

	/* Query EDD information */
#if defined(CONFIG_EDD) || defined(CONFIG_EDD_MODULE)
	query_edd();
#endif

	/* Set the video mode */
	set_video(); /* 设置显示器text display mode，同时进行清屏操作。如果要看早期的puts()内容，则需要在此设置一个断点 */

	/* Do the last things and invoke protected mode */
	go_to_protected_mode(); // 跳转到16位的C代码中去执行main()函数
}
