#include <arm.h>
#include <arm32_macros.S>
#include <asm.S>
#include <kernel/cache_helpers.h>
#include <kernel/unwind.h>
FUNC psci_disable_smp, :
UNWIND(	.fnstart)
	read_actlr r0
	bic	r0, r0, #ACTLR_SMP
	write_actlr r0
	isb
	bx	lr
UNWIND(	.fnend)
END_FUNC psci_disable_smp
FUNC psci_enable_smp, :
UNWIND(	.fnstart)
	read_actlr r0
	orr	r0, r0, #ACTLR_SMP
	write_actlr r0
	isb
	bx	lr
UNWIND(	.fnend)
END_FUNC psci_enable_smp
FUNC psci_armv7_cpu_off, :
UNWIND(	.fnstart)
	push	{r12, lr}
UNWIND(	.save	{r12, lr})
	mov     r0, #DCACHE_OP_CLEAN_INV
	bl	dcache_op_all
	read_sctlr r0
	bic	r0, r0, #SCTLR_C
	write_sctlr r0
	isb
	dsb
	mov	r0, #DCACHE_OP_CLEAN_INV
	bl	dcache_op_all
	clrex
	bl	psci_disable_smp
	pop	{r12, pc}
UNWIND(	.fnend)
END_FUNC psci_armv7_cpu_off
