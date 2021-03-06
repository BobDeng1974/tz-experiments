global-incdirs-y += include
global-incdirs-y += modules 
global-incdirs-y += extera_include 

srcs-y += net_enclave.c
srcs-y += ocalls_compat.c
srcs-y += unsupported-libc.c



DEBUG?=0
PROFILE?=0
PERF?=0
ENDIAN?=little
STRIP?=0
RTOS?=0
GENERIC?=0
PTHREAD?=0
ADDRESS_SANITIZER?=1
GCOV?=0

# Default compiled-in protocols
#
TCP?=1
UDP?=1
ETH?=1
IPV4?=1
IPV4FRAG?=1
IPV6FRAG?=0
NAT?=1
ICMP4?=1
MCAST?=1
DEVLOOP?=1
PING?=1
DHCP_CLIENT?=1
DHCP_SERVER?=1
DNS_CLIENT?=1
MDNS?=1
DNS_SD?=1
SNTP_CLIENT?=1
IPFILTER?=1
CRC?=1
OLSR?=0
SLAACV4?=1
TFTP?=1
AODV?=1
MEMORY_MANAGER?=0
MEMORY_MANAGER_PROFILING?=0
TUN?=0
TAP?=1
PCAP?=0
PPP?=1
6LOWPAN?=0
IEEE802154?=0
IPC?=0
CYASSL?=0
WOLFSSL?=0
POLARSSL?=0

#IPv6 related
IPV6?=1

TEST?=0
ifeq ($(TEST),1)
	6LOWPAN=1
	IEEE802154=1
endif

UNITS?=0
ifeq ($(UNITS),1)
	6LOWPAN=1
	IEEE802154=1
	ARCH=faulty
endif

UNITS_MM?=0
ifeq ($(UNITS_MM),1)
	6LOWPAN=1
	IEEE802154=1
	MEMORY_MANAGER=1
endif



# options for adding warnings
cflags-lib-y += -Wall -W -Wextra -Wshadow -Wcast-qual -Wwrite-strings -Wundef -Wdeclaration-after-statement
cflags-lib-y += -Wconversion -Wcast-align -Wmissing-prototypes
# options for supressing warnings
cflags-lib-y += -Wno-missing-field-initializers

cflags-lib-y +=-DARCHNONE



ifeq ($(PROFILE),1)
  cflags-lib-y +=-pg
endif

ifeq ($(TFTP),1)
  MOD_OBJ+=$(LIBBASE)modules/pico_strings.o $(LIBBASE)modules/pico_tftp.o
  OPTIONS+=-DPICO_SUPPORT_TFTP
endif

ifeq ($(AODV),1)
  MOD_OBJ+=$(LIBBASE)modules/pico_aodv.o
  OPTIONS+=-DPICO_SUPPORT_AODV
endif

ifeq ($(GENERIC),1)
  cflags-lib-y +=-DGENERIC
endif

ifeq ($(PTHREAD),1)
  cflags-lib-y +=-DPICO_SUPPORT_PTHREAD
endif


ifneq ($(ENDIAN),little)
  cflags-lib-y +=-DPICO_BIGENDIAN
endif


subdirs-y += stack
subdirs-y += modules


# To remove a certain compiler flag, add a line like this
#cflags-template_ta.c-y += -Wno-strict-prototypes
