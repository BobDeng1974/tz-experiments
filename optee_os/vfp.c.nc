#include <arm.h>
#include <assert.h>
#include <kernel/vfp.h>
#include "vfp_private.h"
#ifdef ARM32
bool vfp_is_enabled(void)
{
	return !!(vfp_read_fpexc() & FPEXC_EN);
}
void vfp_enable(void)
{
	vfp_write_fpexc(vfp_read_fpexc() | FPEXC_EN);
}
void vfp_disable(void)
{
	vfp_write_fpexc(vfp_read_fpexc() & ~FPEXC_EN);
}
void vfp_lazy_save_state_init(struct vfp_state *state)
{
	uint32_t fpexc = vfp_read_fpexc();
	state->fpexc = fpexc;
	vfp_write_fpexc(fpexc & ~FPEXC_EN);
}
void vfp_lazy_save_state_final(struct vfp_state *state)
{
	if (state->fpexc & FPEXC_EN) {
		uint32_t fpexc = vfp_read_fpexc();
		assert(!(fpexc & FPEXC_EN));
		vfp_write_fpexc(fpexc | FPEXC_EN);
		state->fpscr = vfp_read_fpscr();
		vfp_save_extension_regs(state->reg);
		vfp_write_fpexc(fpexc);
	}
}
void vfp_lazy_restore_state(struct vfp_state *state, bool full_state)
{
	if (full_state) {
		vfp_write_fpexc(vfp_read_fpexc() | FPEXC_EN);
		vfp_write_fpscr(state->fpscr);
		vfp_restore_extension_regs(state->reg);
	}
	vfp_write_fpexc(state->fpexc);
}
#endif 
#ifdef ARM64
bool vfp_is_enabled(void)
{
	return (CPACR_EL1_FPEN(read_cpacr_el1()) & CPACR_EL1_FPEN_EL0EL1);
}
void vfp_enable(void)
{
	uint32_t val = read_cpacr_el1();
	val |= (CPACR_EL1_FPEN_EL0EL1 << CPACR_EL1_FPEN_SHIFT);
	write_cpacr_el1(val);
	isb();
}
void vfp_disable(void)
{
	uint32_t val = read_cpacr_el1();
	val &= ~(CPACR_EL1_FPEN_MASK << CPACR_EL1_FPEN_SHIFT);
	write_cpacr_el1(val);
	isb();
}
void vfp_lazy_save_state_init(struct vfp_state *state)
{
	state->cpacr_el1 = read_cpacr_el1();
	vfp_disable();
}
void vfp_lazy_save_state_final(struct vfp_state *state)
{
	if ((CPACR_EL1_FPEN(state->cpacr_el1) & CPACR_EL1_FPEN_EL0EL1) ||
	    state->force_save) {
		assert(!vfp_is_enabled());
		vfp_enable();
		state->fpcr = read_fpcr();
		state->fpsr = read_fpsr();
		vfp_save_extension_regs(state->reg);
		vfp_disable();
	}
}
void vfp_lazy_restore_state(struct vfp_state *state, bool full_state)
{
	if (full_state) {
		vfp_enable();
		write_fpcr(state->fpcr);
		write_fpsr(state->fpsr);
		vfp_restore_extension_regs(state->reg);
	}
	write_cpacr_el1(state->cpacr_el1);
	isb();
}
#endif 
