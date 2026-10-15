/** 
 @file  unix.c
 @brief ENet Unix system specific functions
*/
#ifndef _WIN32

#include <sys/types.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <sys/time.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <time.h>

#define ENET_BUILDING_LIB 1
#include "enet/enet.h"
#include "sockaddr_util.h"

#ifdef __APPLE__
#ifdef HAS_POLL
#undef HAS_POLL
#endif
#ifndef HAS_FCNTL
#define HAS_FCNTL 1
#endif
#ifndef HAS_INET_PTON
#define HAS_INET_PTON 1
#endif
#ifndef HAS_INET_NTOP
#define HAS_INET_NTOP 1
#endif
#ifndef HAS_MSGHDR_FLAGS
#define HAS_MSGHDR_FLAGS 1
#endif
#ifndef HAS_SOCKLEN_T
#define HAS_SOCKLEN_T 1
#endif
#ifndef HAS_GETADDRINFO
#define HAS_GETADDRINFO 1
#endif
#ifndef HAS_GETNAMEINFO
#define HAS_GETNAMEINFO 1
#endif
#endif

#ifdef HAS_FCNTL
#include <fcntl.h>
#endif

#ifdef HAS_POLL
#include <poll.h>
#endif

#if !defined(HAS_SOCKLEN_T) && !defined(__socklen_t_defined)
typedef int socklen_t;
#endif

#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0
#endif

static enet_uint32 timeBase = 0;

int
enet_initialize (void)
{
    return 0;
}

void
enet_deinitialize (void)
{
}

enet_uint32
enet_host_random_seed (void)
{
    return (enet_uint32) time (NULL);
}

enet_uint32
enet_time_get (void)
{
    struct timeval timeVal;

    gettimeofday (& timeVal, NULL);

    return timeVal.tv_sec * 1000 + timeVal.tv_usec / 1000 - timeBase;
}

void
enet_time_set (enet_uint32 newTimeBase)
{
    struct timeval timeVal;

    gettimeofday (& timeVal, NULL);
    
    timeBase = timeVal.tv_sec * 1000 + timeVal.tv_usec / 1000 - newTimeBase;
}

/* Probes (once) whether real dual-stack AF_INET6 sockets work here. */
static void
enet_probe_ipv6 (void)
{
    int off = 0;
    int fd;

    if (enetIPv6Mode != -1)
      return;

    fd = socket (AF_INET6, SOCK_DGRAM, 0);
    if (fd == -1)
    {
        enetIPv6Mode = 0;
        return;
    }
    /* IPV6_V6ONLY must be switchable off, or one socket can't serve IPv4 as well. */
    enetIPv6Mode = setsockopt (fd, IPPROTO_IPV6, IPV6_V6ONLY, (char *) & off, sizeof (off)) == 0 ? 1 : 0;
    close (fd);
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

/* Resolves via getaddrinfo (AF_UNSPEC). On an IPv6-only NAT64 network the system resolver synthesizes a
   64:ff9b::/96 address for IPv4 literals and A-only names; we keep whatever it returns. IPv4 results become
   IPv4-mapped. The first usable result wins, i.e. the system's own RFC 6724 ordering. */
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

    /* Literals that need no resolver (IPv6, loopback, wildcard) are taken as-is. A routable IPv4 literal still goes
       through getaddrinfo so an IPv6-only NAT64 network can synthesize its 64:ff9b:: form. */
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
        if (pass == 0)
        {
#ifdef AI_DEFAULT
            hints.ai_flags = AI_DEFAULT;       /* Apple: AI_V4MAPPED_CFG | AI_ADDRCONFIG (+ DNS64 synthesis) */
#else
            hints.ai_flags = AI_ADDRCONFIG;
#endif
        }

        if (getaddrinfo (name, NULL, & hints, & resultList) != 0)
        {
            resultList = NULL;
            continue;                           /* retry without AI_ADDRCONFIG (offline / no global address) */
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
        if (inet_ntop (AF_INET, & v4, name, (socklen_t) nameLength) == NULL)
          return -1;
        return 0;
    }
    if (inet_ntop (AF_INET6, address -> host, name, (socklen_t) nameLength) == NULL)
      return -1;
    return 0;
}

int
enet_address_get_host (const ENetAddress * address, char * name, size_t nameLength)
{
    struct sockaddr_storage ss;
    int ssLength, err;
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

    err = getnameinfo ((struct sockaddr *) & ss, (socklen_t) ssLength, name, (socklen_t) nameLength, NULL, 0, NI_NAMEREQD);
    if (! err)
    {
        if (name != NULL && nameLength > 0 && ! memchr (name, '\0', nameLength))
          return -1;
        return 0;
    }
    if (err != EAI_NONAME)
      return -1;

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

    return bind (socket, (struct sockaddr *) & ss, (socklen_t) ssLength);
}

int
enet_socket_get_address (ENetSocket socket, ENetAddress * address)
{
    struct sockaddr_storage ss;
    socklen_t ssLength = sizeof (ss);

    memset (& ss, 0, sizeof (ss));
    if (getsockname (socket, (struct sockaddr *) & ss, & ssLength) == -1)
      return -1;

    enet_address_from_sockaddr (& ss, address);

    return 0;
}

int 
enet_socket_listen (ENetSocket socket, int backlog)
{
    return listen (socket, backlog < 0 ? SOMAXCONN : backlog);
}

ENetSocket
enet_socket_create (ENetSocketType type)
{
    int sockType = type == ENET_SOCKET_TYPE_DATAGRAM ? SOCK_DGRAM : SOCK_STREAM;
    ENetSocket fd;

    enet_probe_ipv6 ();
    if (enetIPv6Mode == 1)
    {
        int off = 0;
        fd = socket (AF_INET6, sockType, 0);
        if (fd != -1)
        {
            if (setsockopt (fd, IPPROTO_IPV6, IPV6_V6ONLY, (char *) & off, sizeof (off)) == 0)
              return fd;
            close (fd);
        }
        return -1;
    }

    return socket (AF_INET, sockType, 0);
}

int
enet_socket_set_option (ENetSocket socket, ENetSocketOption option, int value)
{
    int result = -1;
    switch (option)
    {
        case ENET_SOCKOPT_NONBLOCK:
#ifdef HAS_FCNTL
            result = fcntl (socket, F_SETFL, (value ? O_NONBLOCK : 0) | (fcntl (socket, F_GETFL) & ~O_NONBLOCK));
#else
            result = ioctl (socket, FIONBIO, & value);
#endif
            break;

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
        {
            struct timeval timeVal;
            timeVal.tv_sec = value / 1000;
            timeVal.tv_usec = (value % 1000) * 1000;
            result = setsockopt (socket, SOL_SOCKET, SO_RCVTIMEO, (char *) & timeVal, sizeof (struct timeval));
            break;
        }

        case ENET_SOCKOPT_SNDTIMEO:
        {
            struct timeval timeVal;
            timeVal.tv_sec = value / 1000;
            timeVal.tv_usec = (value % 1000) * 1000;
            result = setsockopt (socket, SOL_SOCKET, SO_SNDTIMEO, (char *) & timeVal, sizeof (struct timeval));
            break;
        }

        case ENET_SOCKOPT_NODELAY:
            result = setsockopt (socket, IPPROTO_TCP, TCP_NODELAY, (char *) & value, sizeof (int));
            break;

        case ENET_SOCKOPT_TTL:
            if (enetIPv6Mode == 1)
            {
                int r6 = setsockopt (socket, IPPROTO_IPV6, IPV6_UNICAST_HOPS, (char *) & value, sizeof (int));
                int r4 = setsockopt (socket, IPPROTO_IP, IP_TTL, (char *) & value, sizeof (int));   /* mapped IPv4 traffic */
                result = (r6 == 0 || r4 == 0) ? 0 : -1;
            }
            else
              result = setsockopt (socket, IPPROTO_IP, IP_TTL, (char *) & value, sizeof (int));
            break;

        default:
            break;
    }
    return result == -1 ? -1 : 0;
}

int
enet_socket_get_option (ENetSocket socket, ENetSocketOption option, int * value)
{
    int result = -1;
    socklen_t len;
    switch (option)
    {
        case ENET_SOCKOPT_ERROR:
            len = sizeof (int);
            result = getsockopt (socket, SOL_SOCKET, SO_ERROR, value, & len);
            break;

        case ENET_SOCKOPT_TTL:
            len = sizeof (int);
            if (enetIPv6Mode == 1)
              result = getsockopt (socket, IPPROTO_IPV6, IPV6_UNICAST_HOPS, (char *) value, & len);
            else
              result = getsockopt (socket, IPPROTO_IP, IP_TTL, (char *) value, & len);
            break;

        default:
            break;
    }
    return result == -1 ? -1 : 0;
}

int
enet_socket_connect (ENetSocket socket, const ENetAddress * address)
{
    struct sockaddr_storage ss;
    int ssLength, result;

    if (enet_sockaddr_from_address (address, enetIPv6Mode == 1, & ss, & ssLength) < 0)
      return -1;

    result = connect (socket, (struct sockaddr *) & ss, (socklen_t) ssLength);
    if (result == -1 && errno == EINPROGRESS)
      return 0;

    return result;
}

ENetSocket
enet_socket_accept (ENetSocket socket, ENetAddress * address)
{
    int result;
    struct sockaddr_storage ss;
    socklen_t ssLength = sizeof (ss);

    memset (& ss, 0, sizeof (ss));
    result = accept (socket, 
                     address != NULL ? (struct sockaddr *) & ss : NULL, 
                     address != NULL ? & ssLength : NULL);
    
    if (result == -1)
      return ENET_SOCKET_NULL;

    if (address != NULL)
      enet_address_from_sockaddr (& ss, address);

    return result;
} 
    
int
enet_socket_shutdown (ENetSocket socket, ENetSocketShutdown how)
{
    return shutdown (socket, (int) how);
}

void
enet_socket_destroy (ENetSocket socket)
{
    if (socket != -1)
      close (socket);
}

int
enet_socket_send (ENetSocket socket,
                  const ENetAddress * address,
                  const ENetBuffer * buffers,
                  size_t bufferCount)
{
    struct msghdr msgHdr;
    struct sockaddr_storage ss;
    int ssLength;
    int sentLength;

    memset (& msgHdr, 0, sizeof (struct msghdr));

    if (address != NULL)
    {
        if (enet_sockaddr_from_address (address, enetIPv6Mode == 1, & ss, & ssLength) < 0)
          return -1;

        msgHdr.msg_name = & ss;
        msgHdr.msg_namelen = (socklen_t) ssLength;
    }

    msgHdr.msg_iov = (struct iovec *) buffers;
    msgHdr.msg_iovlen = bufferCount;

    sentLength = sendmsg (socket, & msgHdr, MSG_NOSIGNAL);
    
    if (sentLength == -1)
    {
       if (errno == EWOULDBLOCK)
         return 0;

       return -1;
    }

    return sentLength;
}

int
enet_socket_receive (ENetSocket socket,
                     ENetAddress * address,
                     ENetBuffer * buffers,
                     size_t bufferCount)
{
    struct msghdr msgHdr;
    struct sockaddr_storage ss;
    int recvLength;

    memset (& msgHdr, 0, sizeof (struct msghdr));
    memset (& ss, 0, sizeof (ss));

    if (address != NULL)
    {
        msgHdr.msg_name = & ss;
        msgHdr.msg_namelen = sizeof (ss);
    }

    msgHdr.msg_iov = (struct iovec *) buffers;
    msgHdr.msg_iovlen = bufferCount;

    recvLength = recvmsg (socket, & msgHdr, MSG_NOSIGNAL);

    if (recvLength == -1)
    {
       if (errno == EWOULDBLOCK)
         return 0;

       return -1;
    }

#ifdef HAS_MSGHDR_FLAGS
    if (msgHdr.msg_flags & MSG_TRUNC)
      return -2;
#endif

    if (address != NULL)
      enet_address_from_sockaddr (& ss, address);

    return recvLength;
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
#ifdef HAS_POLL
    struct pollfd pollSocket;
    int pollCount;
    
    pollSocket.fd = socket;
    pollSocket.events = 0;

    if (* condition & ENET_SOCKET_WAIT_SEND)
      pollSocket.events |= POLLOUT;

    if (* condition & ENET_SOCKET_WAIT_RECEIVE)
      pollSocket.events |= POLLIN;

    pollCount = poll (& pollSocket, 1, timeout);

    if (pollCount < 0)
    {
        if (errno == EINTR && * condition & ENET_SOCKET_WAIT_INTERRUPT)
        {
            * condition = ENET_SOCKET_WAIT_INTERRUPT;

            return 0;
        }

        return -1;
    }

    * condition = ENET_SOCKET_WAIT_NONE;

    if (pollCount == 0)
      return 0;

    if (pollSocket.revents & POLLOUT)
      * condition |= ENET_SOCKET_WAIT_SEND;
    
    if (pollSocket.revents & POLLIN)
      * condition |= ENET_SOCKET_WAIT_RECEIVE;

    return 0;
#else
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
    {
        if (errno == EINTR && * condition & ENET_SOCKET_WAIT_INTERRUPT)
        {
            * condition = ENET_SOCKET_WAIT_INTERRUPT;

            return 0;
        }
      
        return -1;
    }

    * condition = ENET_SOCKET_WAIT_NONE;

    if (selectCount == 0)
      return 0;

    if (FD_ISSET (socket, & writeSet))
      * condition |= ENET_SOCKET_WAIT_SEND;

    if (FD_ISSET (socket, & readSet))
      * condition |= ENET_SOCKET_WAIT_RECEIVE;

    return 0;
#endif
}

#endif

