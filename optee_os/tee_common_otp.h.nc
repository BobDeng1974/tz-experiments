#ifndef TEE_COMMON_OTP_H
#define TEE_COMMON_OTP_H
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <utee_defines.h>
struct tee_hw_unique_key {
	uint8_t data[HW_UNIQUE_KEY_LENGTH];
};
void tee_otp_get_hw_unique_key(struct tee_hw_unique_key *hwkey);
int tee_otp_get_die_id(uint8_t *buffer, size_t len);
#endif 
