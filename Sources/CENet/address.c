/**
 @file  address.c
 @brief ENet portable (non-socket) address helpers for the dual-stack ENetAddress.
        NovaSwift patch: ENetAddress.host is a 16 byte IPv6 address; IPv4 is stored IPv4-mapped.
*/
#define ENET_BUILDING_LIB 1
#include <string.h>
#include "enet/enet.h"

static const enet_uint8 enetV4MappedPrefix [12] = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF };

void
enet_address_set_host_any (ENetAddress * address)
{
    memset (address -> host, 0, sizeof (address -> host));
    address -> scopeID = 0;
}

void
enet_address_set_host_broadcast (ENetAddress * address)
{
    enet_address_set_host_ipv4 (address, 0xFFFFFFFFU);
}

void
enet_address_set_host_ipv4 (ENetAddress * address, enet_uint32 ipv4NetworkOrder)
{
    memcpy (address -> host, enetV4MappedPrefix, 12);
    memcpy (address -> host + 12, & ipv4NetworkOrder, 4);   /* already network order: copy the bytes as-is */
    address -> scopeID = 0;
}

void
enet_address_set_host_ipv6 (ENetAddress * address, const enet_uint8 bytes [16])
{
    memcpy (address -> host, bytes, 16);
    address -> scopeID = 0;
}

int
enet_address_is_ipv4_mapped (const ENetAddress * address)
{
    return memcmp (address -> host, enetV4MappedPrefix, 12) == 0;
}

int
enet_address_is_any (const ENetAddress * address)
{
    static const enet_uint8 zero [16] = { 0 };
    return memcmp (address -> host, zero, 16) == 0;
}

int
enet_address_is_broadcast (const ENetAddress * address)
{
    return enet_address_is_ipv4_mapped (address) &&
           address -> host [12] == 0xFF && address -> host [13] == 0xFF &&
           address -> host [14] == 0xFF && address -> host [15] == 0xFF;
}

int
enet_address_is_loopback (const ENetAddress * address)
{
    static const enet_uint8 loop6 [16] = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    if (enet_address_is_ipv4_mapped (address))
      return address -> host [12] == 127;
    return memcmp (address -> host, loop6, 16) == 0;
}

int
enet_address_get_ipv4 (const ENetAddress * address, enet_uint32 * ipv4NetworkOrder)
{
    if (! enet_address_is_ipv4_mapped (address))
      return -1;
    memcpy (ipv4NetworkOrder, address -> host + 12, 4);
    return 0;
}

int
enet_address_hosts_equal (const ENetAddress * a, const ENetAddress * b)
{
    return memcmp (a -> host, b -> host, 16) == 0;
}
