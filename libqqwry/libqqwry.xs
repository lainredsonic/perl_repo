#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "ppport.h"

#include <qqwry.h>

#include "const-c.inc"

MODULE = libqqwry		PACKAGE = libqqwry		

INCLUDE: const-xs.inc

int
_qqwry_get(char *addr_1, char *addr_2, char *ip, char *qqwry_file_name)
	CODE:
		char addr1[1024]={0};
		char addr2[1024]={0};
		RETVAL = qqwry_get(addr1, addr2, ip, qqwry_file_name);
		addr_1 = addr1;
		addr_2 = addr2;
	OUTPUT:
		RETVAL
		addr_1
		addr_2
