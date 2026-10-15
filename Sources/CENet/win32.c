/** 
 @file  win32.c
 @brief ENet Win32 system specific functions
*/
#ifdef _WIN32

/* getaddrinfo / inet_pton / inet_ntop / IPV6_V6ONLY need Vista or later (MinGW defaults older). */
#if defined(_WIN32_WINNT) && _WIN32_WINNT < 0x0600
#undef _WIN32_WINNT
#endif
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0600
#endif

#define ENET_BUILDING_LIB 1
#include "enet/enet.h"
#include <windows.h>
#include <mmsystem.h>
#include <ws2tcpip.h>
#include "sockaddr_util.h"

static enet_uint32 timeBase = 0;

int
enet_initialize (void)
{
    WORD versionRequested = MAKEWORD (2, 2);
    WSADATA wsaData;
   
    if (WSAStartup (versionRequested, & wsaData))
       return -1;

    if (LOBYTE (wsaData.wVersion) != 2||
        HIBYTE (wsaData.wVersion) != 2)
    {
       WSACleanup ();
       
       return -1;
    }

    timeBeginPeriod (1);

    return 0;
}

void
enet_deinitialize (void)
{
    timeEndPeriod (1);

    WSACleanup ();
}

enet_uint32
enet_host_random_seed (void)
{
    return (enet_uint32) timeGetTime ();
}

enet_uint32
enet_time_get (void)
{
    return (enet_uint32) timeGetTime () - timeBase;
}

void
enet_time_set (enet_uint32 newTimeBase)
{
    timeBase = (enet_uint32) timeGetTime () - newTimeBase;
}

/* Probes (once) whether real dual-stack AF_INET6 sockets work here. enet_initialize () (WSAStartup) must have run. */
static void
enet_probe_ipv6 (void)
{
    DWORD off = 0;
    SOCKET fd;

    if (enetIPv6Mode != -1)
      return;

    fd = socket (AF_INET6, SOCK_DGRAM, 0);
    if (fd == INVALID_SOCKET)
    {
        enetIPv6Mode = 0;
        return;
    }
    /* Windows defaults IPV6_V6ONLY to on; it must be switched off for one socket to serve IPv4 as well. */
    enetIPv6Mode = setsockopt (fd, IPPROTO_IPV6, IPV6_V6ONLY, (char *) & off, sizeof (off)) == 0 ? 1 : 0;
    closesocket (fd);
}

int
enet_socket_ipv6_available (void)
{
    enet_probe_ipv6 ();
    return enetIPv6Mode == 1;
}

int
enet_address_set_host_ip (ENetAddress * address, const char * name)
{
    struct in_addr v4;
    struct in6_addr v6;

    if (inet_pton (AF_INET, name, & v4) == 1)
    {
        enet_address_set_host_ipv4 (address, (enet_uint32) v4.s_addr);
        return 0;
    }
    if (inet_pton (AF_INET6, name, & v6) == 1)
    {
        memcpy (address -> host, & v6, 16);
        address -> scopeID = 0;
        return 0;
    }
    return -1;
}

/* Same policy as unix.c: getaddrinfo (AF_UNSPEC), first usable result, IPv4 results become IPv4-mapped. */
int
enet_address_set_host (ENetAddress * address, const char * name)
{
    struct addrinfo hints, * resultList = NULL, * result = NULL;
    ENetAddress literal;
    int ipv6Sockets, pass, isLiteral;

    enet_probe_ipv6 ();
    ipv6Sockets = enetIPv6Mode == 1;

    memset (& literal, 0, sizeof (literal));
    isLiteral = enet_address_set_host_ip (& literal, name) == 0;

    if (isLiteral && (! enet_address_is_ipv4_mapped (& literal) || enet_address_is_loopback (& literal) ||
                      enet_address_is_any (& literal)))
    {
        if (! ipv6Sockets && ! enet_address_is_ipv4_mapped (& literal) && ! enet_address_is_any (& literal))
          return -1;
        memcpy (address -> host, literal.host, 16);
        address -> scopeID = 0;
        return 0;
    }

    for (pass = 0; pass < 2; ++ pass)
    {
        memset (& hints, 0, sizeof (hints));
        hints.ai_family = AF_UNSPEC;
        hints.ai_socktype = SOCK_DGRAM;
#ifdef AI_ADDRCONFIG
        if (pass == 0)
          hints.ai_flags = AI_ADDRCONFIG;
#endif

        if (getaddrinfo (name, NULL, & hints, & resultList) != 0)
        {
            resultList = NULL;
            continue;
        }

        for (result = resultList; result != NULL; result = result -> ai_next)
        {
            if (result -> ai_family == AF_INET6 && ipv6Sockets && result -> ai_addr != NULL &&
                result -> ai_addrlen >= sizeof (struct sockaddr_in6))
            {
                struct sockaddr_in6 * sin6 = (struct sockaddr_in6 *) result -> ai_addr;
                memcpy (address -> host, & sin6 -> sin6_addr, 16);
                address -> scopeID = (enet_uint32) sin6 -> sin6_scope_id;
                freeaddrinfo (resultList);
                return 0;
            }
            if (result -> ai_family == AF_INET && result -> ai_addr != NULL &&
                result -> ai_addrlen >= sizeof (struct sockaddr_in))
            {
                struct sockaddr_in * sin = (struct sockaddr_in *) result -> ai_addr;
                enet_address_set_host_ipv4 (address, (enet_uint32) sin -> sin_addr.s_addr);
                freeaddrinfo (resultList);
                return 0;
            }
        }
        freeaddrinfo (resultList);
        resultList = NULL;
    }

    if (isLiteral)
    {
        memcpy (address -> host, literal.host, 16);
        address -> scopeID = 0;
        return 0;
    }
    return -1;
}

int
enet_address_get_host_ip (const ENetAddress * address, char * name, size_t nameLength)
{
    enet_uint32 v4;
    if (enet_address_get_ipv4 (address, & v4) == 0)
    {
        if (inet_ntop (AF_INET, (void *) & v4, name, nameLength) == NULL)
          return -1;
        return 0;
    }
    if (inet_ntop (AF_INET6, (void *) address -> host, name, nameLength) == NULL)
      return -1;
    return 0;
}

int
enet_address_get_host (const ENetAddress * address, char * name, size_t nameLength)
{
    struct sockaddr_storage ss;
    int ssLength;
    enet_uint32 v4;

    /* getnameinfo wants the real family: a sockaddr_in for IPv4-mapped addresses. */
    if (enet_address_get_ipv4 (address, & v4) == 0)
    {
        struct sockaddr_in * sin = (struct sockaddr_in *) & ss;
        memset (& ss, 0, sizeof (ss));
        sin -> sin_family = AF_INET;
        sin -> sin_port = ENET_HOST_TO_NET_16 (address -> port);
        memcpy (& sin -> sin_addr.s_addr, & v4, 4);
        ssLength = (int) sizeof (struct sockaddr_in);
    }
    else if (enet_sockaddr_from_address (address, 1, & ss, & ssLength) < 0)
      return -1;

    if (getnameinfo ((struct sockaddr *) & ss, ssLength, name, (DWORD) nameLength, NULL, 0, NI_NAMEREQD) == 0)
    {
        if (name != NULL && nameLength > 0 && ! memchr (name, '\0', nameLength))
          return -1;
        return 0;
    }

    return enet_address_get_host_ip (address, name, nameLength);
}

int
enet_socket_bind (ENetSocket socket, const ENetAddress * address)
{
    struct sockaddr_storage ss;
    int ssLength;
    ENetAddress any;

    if (address == NULL)
    {
        memset (& any, 0, sizeof (any));
        address = & any;
    }
    if (enet_sockaddr_from_address (address, enetIPv6Mode == 1, & ss, & ssLength) < 0)
      return -1;

    return bind (socket, (struct sockaddr *) & ss, ssLength) == SOCKET_ERROR ? -1 : 0;
}

int
enet_socket_get_address (ENetSocket socket, ENetAddress * address)
{
    struct sockaddr_storage ss;
    int ssLength = (int) sizeof (ss);

    memset (& ss, 0, sizeof (ss));
    if (getsockname (socket, (struct sockaddr *) & ss, & ssLength) == -1)
      return -1;

    enet_address_from_sockaddr (& ss, address);

    return 0;
}

int
enet_socket_listen (ENetSocket socket, int backlog)
{
    return listen (socket, backlog < 0 ? SOMAXCONN : backlog) == SOCKET_ERROR ? -1 : 0;
}

ENetSocket
enet_socket_create (ENetSocketType type)
{
    int sockType = type == ENET_SOCKET_TYPE_DATAGRAM ? SOCK_DGRAM : SOCK_STREAM;
    ENetSocket fd;

    enet_probe_ipv6 ();
    if (enetIPv6Mode == 1)
    {
        DWORD off = 0;
        fd = socket (AF_INET6, sockType, 0);
        if (fd != INVALID_SOCKET)
        {
            if (setsockopt (fd, IPPROTO_IPV6, IPV6_V6ONLY, (char *) & off, sizeof (off)) == 0)
              return fd;
            closesocket (fd);
        }
        return INVALID_SOCKET;
    }

    return socket (AF_INET, sockType, 0);
}

int
enet_socket_set_option (ENetSocket socket, ENetSocketOption option, int value)
{
    int result = SOCKET_ERROR;
    switch (option)
    {
        case ENET_SOCKOPT_NONBLOCK:
        {
            u_long nonBlocking = (u_long) value;
            result = ioctlsocket (socket, FIONBIO, & nonBlocking);
            break;
        }

        case ENET_SOCKOPT_BROADCAST:
            result = setsockopt (socket, SOL_SOCKET, SO_BROADCAST, (char *) & value, sizeof (int));
            break;

        case ENET_SOCKOPT_REUSEADDR:
            result = setsockopt (socket, SOL_SOCKET, SO_REUSEADDR, (char *) & value, sizeof (int));
            break;

        case ENET_SOCKOPT_RCVBUF:
            result = setsockopt (socket, SOL_SOCKET, SO_RCVBUF, (char *) & value, sizeof (int));
            break;

        case ENET_SOCKOPT_SNDBUF:
            result = setsockopt (socket, SOL_SOCKET, SO_SNDBUF, (char *) & value, sizeof (int));
            break;

        case ENET_SOCKOPT_RCVTIMEO:
            result = setsockopt (socket, SOL_SOCKET, SO_RCVTIMEO, (char *) & value, sizeof (int));
            break;

        case ENET_SOCKOPT_SNDTIMEO:
            result = setsockopt (socket, SOL_SOCKET, SO_SNDTIMEO, (char *) & value, sizeof (int));
            break;

        case ENET_SOCKOPT_NODELAY:
            result = setsockopt (socket, IPPROTO_TCP, TCP_NODELAY, (char *) & value, sizeof (int));
            break;

        case ENET_SOCKOPT_TTL:
            if (enetIPv6Mode == 1)
            {
                int r6 = setsockopt (socket, IPPROTO_IPV6, IPV6_UNICAST_HOPS, (char *) & value, sizeof (int));
                int r4 = setsockopt (socket, IPPROTO_IP, IP_TTL, (char *) & value, sizeof (int));   /* mapped IPv4 traffic */
                result = (r6 == 0 || r4 == 0) ? 0 : SOCKET_ERROR;
            }
            else
              result = setsockopt (socket, IPPROTO_IP, IP_TTL, (char *) & value, sizeof (int));
            break;

        default:
            break;
    }
    return result == SOCKET_ERROR ? -1 : 0;
}

int
enet_socket_get_option (ENetSocket socket, ENetSocketOption option, int * value)
{
    int result = SOCKET_ERROR, len;
    switch (option)
    {
        case ENET_SOCKOPT_ERROR:
            len = sizeof(int);
            result = getsockopt (socket, SOL_SOCKET, SO_ERROR, (char *) value, & len);
            break;

        case ENET_SOCKOPT_TTL:
            len = sizeof(int);
            if (enetIPv6Mode == 1)
              result = getsockopt (socket, IPPROTO_IPV6, IPV6_UNICAST_HOPS, (char *) value, & len);
            else
              result = getsockopt (socket, IPPROTO_IP, IP_TTL, (char *) value, & len);
            break;

        default:
            break;
    }
    return result == SOCKET_ERROR ? -1 : 0;
}

int
enet_socket_connect (ENetSocket socket, const ENetAddress * address)
{
    struct sockaddr_storage ss;
    int ssLength, result;

    if (enet_sockaddr_from_address (address, enetIPv6Mode == 1, & ss, & ssLength) < 0)
      return -1;

    result = connect (socket, (struct sockaddr *) & ss, ssLength);
    if (result == SOCKET_ERROR && WSAGetLastError () != WSAEWOULDBLOCK)
      return -1;

    return 0;
}

ENetSocket
enet_socket_accept (ENetSocket socket, ENetAddress * address)
{
    SOCKET result;
    struct sockaddr_storage ss;
    int ssLength = (int) sizeof (ss);

    memset (& ss, 0, sizeof (ss));
    result = accept (socket, 
                     address != NULL ? (struct sockaddr *) & ss : NULL, 
                     address != NULL ? & ssLength : NULL);

    if (result == INVALID_SOCKET)
      return ENET_SOCKET_NULL;

    if (address != NULL)
      enet_address_from_sockaddr (& ss, address);

    return result;
}

int
enet_socket_shutdown (ENetSocket socket, ENetSocketShutdown how)
{
    return shutdown (socket, (int) how) == SOCKET_ERROR ? -1 : 0;
}

void
enet_socket_destroy (ENetSocket socket)
{
    if (socket != INVALID_SOCKET)
      closesocket (socket);
}

int
enet_socket_send (ENetSocket socket,
                  const ENetAddress * address,
                  const ENetBuffer * buffers,
                  size_t bufferCount)
{
    struct sockaddr_storage ss;
    int ssLength = 0;
    DWORD sentLength = 0;

    if (address != NULL)
    {
        if (enet_sockaddr_from_address (address, enetIPv6Mode == 1, & ss, & ssLength) < 0)
          return -1;
    }

    if (WSASendTo (socket, 
                   (LPWSABUF) buffers,
                   (DWORD) bufferCount,
                   & sentLength,
                   0,
                   address != NULL ? (struct sockaddr *) & ss : NULL,
                   address != NULL ? ssLength : 0,
                   NULL,
                   NULL) == SOCKET_ERROR)
    {
       if (WSAGetLastError () == WSAEWOULDBLOCK)
         return 0;

       return -1;
    }

    return (int) sentLength;
}

int
enet_socket_receive (ENetSocket socket,
                     ENetAddress * address,
                     ENetBuffer * buffers,
                     size_t bufferCount)
{
    INT ssLength = (INT) sizeof (struct sockaddr_storage);
    DWORD flags = 0,
          recvLength = 0;
    struct sockaddr_storage ss;

    memset (& ss, 0, sizeof (ss));

    if (WSARecvFrom (socket,
                     (LPWSABUF) buffers,
                     (DWORD) bufferCount,
                     & recvLength,
                     & flags,
                     address != NULL ? (struct sockaddr *) & ss : NULL,
                     address != NULL ? & ssLength : NULL,
                     NULL,
                     NULL) == SOCKET_ERROR)
    {
       switch (WSAGetLastError ())
       {
       case WSAEWOULDBLOCK:
       case WSAECONNRESET:
          return 0;
       case WSAEMSGSIZE:
          return -2;
       }

       return -1;
    }

    if (flags & MSG_PARTIAL)
      return -2;

    if (address != NULL)
      enet_address_from_sockaddr (& ss, address);

    return (int) recvLength;
}

int
enet_socketset_select (ENetSocket maxSocket, ENetSocketSet * readSet, ENetSocketSet * writeSet, enet_uint32 timeout)
{
    struct timeval timeVal;

    timeVal.tv_sec = timeout / 1000;
    timeVal.tv_usec = (timeout % 1000) * 1000;

    return select (maxSocket + 1, readSet, writeSet, NULL, & timeVal);
}

int
enet_socket_wait (ENetSocket socket, enet_uint32 * condition, enet_uint32 timeout)
{
    fd_set readSet, writeSet;
    struct timeval timeVal;
    int selectCount;
    
    timeVal.tv_sec = timeout / 1000;
    timeVal.tv_usec = (timeout % 1000) * 1000;
    
    FD_ZERO (& readSet);
    FD_ZERO (& writeSet);

    if (* condition & ENET_SOCKET_WAIT_SEND)
      FD_SET (socket, & writeSet);

    if (* condition & ENET_SOCKET_WAIT_RECEIVE)
      FD_SET (socket, & readSet);

    selectCount = select (socket + 1, & readSet, & writeSet, NULL, & timeVal);

    if (selectCount < 0)
      return -1;

    * condition = ENET_SOCKET_WAIT_NONE;

    if (selectCount == 0)
      return 0;

    if (FD_ISSET (socket, & writeSet))
      * condition |= ENET_SOCKET_WAIT_SEND;
    
    if (FD_ISSET (socket, & readSet))
      * condition |= ENET_SOCKET_WAIT_RECEIVE;

    return 0;
} 

#endif

