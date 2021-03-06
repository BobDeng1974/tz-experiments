#ifndef __KERNEL_CACHE_HELPERS_H
#define __KERNEL_CACHE_HELPERS_H
#ifndef ASM
#include <types_ext.h>
#endif
#define DCACHE_OP_INV		0x0
#define DCACHE_OP_CLEAN_INV	0x1
#define DCACHE_OP_CLEAN		0x2
#ifndef ASM
void dcache_cleaninv_range(void *addr, size_t size);
void dcache_clean_range(void *addr, size_t size);
void dcache_inv_range(void *addr, size_t size);
void icache_inv_all(void);
void icache_inv_range(void *addr, size_t size);
void dcache_op_louis(unsigned long op_type);
void dcache_op_all(unsigned long op_type);
void dcache_op_level1(unsigned long op_type);
void dcache_op_level2(unsigned long op_type);
void dcache_op_level3(unsigned long op_type);
#endif 
#endif 
