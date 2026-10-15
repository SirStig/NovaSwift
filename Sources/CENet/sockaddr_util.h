/**
 @file  sockaddr_util.h
 @brief Private helper shared by unix.c and win32.c: ENetAddress <-> sockaddr conversion for the dual-stack
        socket layer (NovaSwift IPv6 patch). Include AFTER the platform's socket headers and "enet/enet.h".

 Two socket modes:
   * dual-stack (normal): AF_INET6 sockets with IPV6_V6ONLY = 0. IPv4 peers appear as ::ffff:a.b.c.d.
   * IPv4 fallback: when an AF_INET6 socket can't be created (IPv6 disabled in the kernel, some containers) the
     socket layer uses AF_INET sockets and converts at the bind/send/receive boundary. Only IPv4-mapped (and the
     wildcard) addresses are representable then.
*/
#ifndef __ENET_SOCKADDR_UTIL_H__
#define __ENET_SOCKADDR_UTIL_H__

#include <string.h>

/* -1 = not probed yet, 0 = IPv4 fallback, 1 = dual-stack. */
static int enetIPv6Mode = -1;

/* Fills `out` (a sockaddr_storage) from an ENetAddress for the given socket mode. Returns 0 and sets *outLen, or
   -1 if the address can't be expressed (a real IPv6 address on an IPv4-only socket). */
static int
enet_sockaddr_from_address (const ENetAddress * address, int ipv6, struct sockaddr_storage * out, int * outLen)
{
    memset (out, 0, sizeof (struct sockaddr_storage));

    if (ipv6)
    {
        struct sockaddr_in6 * sin6 = (struct sockaddr_in6 *) out;
        sin6 -> sin6_family = AF_INET6;
        sin6 -> sin6_port = ENET_HOST_TO_NET_16 (address -> port);
        memcpy (& sin6 -> sin6_addr, address -> host, 16);
        sin6 -> sin6_scope_id = address -> scopeID;
#ifdef SIN6_LEN
        sin6 -> sin6_len = sizeof (struct sockaddr_in6);
#endif
        * outLen = (int) sizeof (struct sockaddr_in6);
        return 0;
    }
    else
    {
        struct sockaddr_in * sin = (struct sockaddr_in *) out;
        sin -> sin_family = AF_INET;
        sin -> sin_port = ENET_HOST_TO_NET_16 (address -> port);
#ifdef HAVE_SIN_LEN
        sin -> sin_len = sizeof (struct sockaddr_in);
#endif
        if (enet_address_is_any (address))
          sin -> sin_addr.s_addr = htonl (INADDR_ANY);
        else if (enet_address_is_ipv4_mapped (address))
          memcpy (& sin -> sin_addr.s_addr, address -> host + 12, 4);
        else
          return -1;
        * outLen = (int) sizeof (struct sockaddr_in);
        return 0;
    }
}

/* Converts a received/queried sockaddr (either family) to an ENetAddress. */
static void
enet_address_from_sockaddr (const struct sockaddr_storage * in, ENetAddress * address)
{
    if (in -> ss_family == AF_INET6)
    {
        const struct sockaddr_in6 * sin6 = (const struct sockaddr_in6 *) in;
        memcpy (address -> host, & sin6 -> sin6_addr, 16);
        address -> port = ENET_NET_TO_HOST_16 (sin6 -> sin6_port);
        address -> scopeID = (enet_uint32) sin6 -> sin6_scope_id;
    }
    else
    {
        const struct sockaddr_in * sin = (const struct sockaddr_in *) in;
        enet_address_set_host_ipv4 (address, (enet_uint32) sin -> sin_addr.s_addr);
        address -> port = ENET_NET_TO_HOST_16 (sin -> sin_port);
    }
}

#endif
