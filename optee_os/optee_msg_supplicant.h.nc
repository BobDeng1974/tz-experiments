#ifndef __OPTEE_MSG_SUPPLICANT_H
#define __OPTEE_MSG_SUPPLICANT_H
#define OPTEE_MSG_RPC_CMD_LOAD_TA	0
#define OPTEE_MSG_RPC_CMD_RPMB		1
#define OPTEE_MSG_RPC_CMD_FS		2
#define OPTEE_MSG_RPC_CMD_SQL_FS_RESERVED	8
#define OPTEE_MRF_OPEN			0
#define OPTEE_MRF_CREATE		1
#define OPTEE_MRF_CLOSE			2
#define OPTEE_MRF_READ			3
#define OPTEE_MRF_WRITE			4
#define OPTEE_MRF_TRUNCATE		5
#define OPTEE_MRF_REMOVE		6
#define OPTEE_MRF_RENAME		7
#define OPTEE_MRF_OPENDIR		8
#define OPTEE_MRF_CLOSEDIR		9
#define OPTEE_MRF_READDIR		10
#define OPTEE_MSG_RPC_CMD_GPROF		9
#define OPTEE_MSG_RPC_CMD_SOCKET	10
#define OPTEE_MRC_SOCKET_TIMEOUT_NONBLOCKING	0
#define OPTEE_MRC_SOCKET_TIMEOUT_BLOCKING	0xffffffff
#define OPTEE_MRC_SOCKET_OPEN	0
#define OPTEE_MRC_SOCKET_CLOSE	1
#define OPTEE_MRC_SOCKET_CLOSE_ALL 2
#define OPTEE_MRC_SOCKET_SEND	3
#define OPTEE_MRC_SOCKET_RECV	4
#define OPTEE_MRC_SOCKET_IOCTL	5
#define OCALL_TEST 20
#define OCALL_READ 21
#define OCALL_FILE_BENCH 22
#define OCALL_TAP_OPEN 23
#define OCALL_GET_MAC 24
#define OCALL_CLOSE 25
#define OCALL_WRITE 26
#define OCALL_POLL 27
#define OCALL_OPEN 28
#endif 