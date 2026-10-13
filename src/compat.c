//
// Keep platform-dependent macros and ioctl request constants in C.
//

#include <signal.h>
#include <stddef.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <termios.h>
#include <time.h>

// Must match FdSet in main.zig. Fail at build time on unsupported layouts
// rather than allowing FD_ZERO/FD_SET to corrupt Zig's stack storage.
_Static_assert(sizeof(fd_set) <= 128, "fd_set exceeds Zig storage");

_Static_assert(_Alignof(fd_set) <= 8, "fd_set alignment exceeds Zig storage");

int tty_proxy_get_winsize(int fd, struct winsize *size) {
    return ioctl(fd, TIOCGWINSZ, size);
}

void tty_proxy_fd_zero(void *set) {
  FD_ZERO((fd_set *)set);
}

int tty_proxy_fd_in_range(int fd) {
    return fd >= 0 && fd < FD_SETSIZE;
}

// Callers validate dynamic descriptors once before entering the readiness loop.
void tty_proxy_fd_set(int fd, void *set) {
    FD_SET(fd, (fd_set *)set);
}

int tty_proxy_fd_isset(int fd, const void *set) {
    return FD_ISSET(fd, (const fd_set *)set);
}

int tty_proxy_pselect(int nfds, void *readfds, void *writefds, void *exceptfds,
                      const struct timespec *timeout, const sigset_t *mask) {
    return pselect(nfds, (fd_set *)readfds, (fd_set *)writefds,
                   (fd_set *)exceptfds, timeout, mask);
}
