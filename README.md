# tty-proxy

Connects a Unix terminal to a local Common Lisp peer over a Unix socket.

## Build and configure

Requires Zig 0.15.2 and a Unix-like system with `termios` and Unix sockets.

```sh
zig build
zig-out/bin/tty-proxy [args]
```

Set `TTY_PROXY_CONFIG` to a config file, or use
`~/.config/tty-proxy/config`:

```text
tty-proxy = socket:/tmp/tty-proxy.sock
```

Entries map invocation names to `socket:` targets. Exact invocation names
win over basenames; blank lines and `#` comments are ignored.

**Security:** the peer receives arguments, environment, and terminal input,
and can write arbitrary terminal output. Its identity is not verified. Use
only trusted peers and protected config/socket paths; never run elevated.

## Peer protocol

Stdin must be a tty. The proxy sends a Lisp plist before interactive I/O:

```lisp
(:args ("tty-proxy" ...) :tty "/dev/tty..."
 :env (("NAME" "VALUE") ...) :size (:rows R :cols C :xpixels X :ypixels Y))
```

Environment order is unspecified; zero dimensions mean unknown. The peer
selects a mode with one leading byte:

| Byte | Behavior |
|---|---|
| `R` | Proxy enables raw mode, restores it on exit; socket carries I/O. |
| `C` | Keep terminal settings; socket carries I/O. |
| `E` | Write peer error to stderr; stop sending, then exit 1. |
| `D` | Peer uses the tty directly; socket tracks session lifetime/status. |

For `R`/`C`, use only the socket for interactive I/O. Reads and writes may be
fragmented. Drain the full startup plist before reading terminal input, even
if `R`/`C` arrives early. `E` cancels startup. On completion, flush output
and close the socket write side.

### Direct mode (`D`, local sockets only)

After reading the full plist, open `:tty` and send `D`. The socket carries no
terminal data: proxy write-side EOF requests detachment; the peer may send one
raw status byte (0–255), then must close its write side. EOF completes the
session; no status means exit 0. Extra bytes or socket errors exit 1.

The peer must monitor socket EOF alongside tty I/O, stop tty activity, and
close its tty handle before acknowledging with EOF. Detachment ends the session,
not the Lisp process. In SBCL, use `read-char-no-hang` with a distinct EOF value;
`listen` alone cannot distinguish idle from EOF.

`SIGINT`, `SIGTERM`, or `SIGHUP` half-closes the socket and allows two seconds
for cleanup; a second signal or timeout forces restoration. Cancellation exits
with `128 + signal`. Forced cleanup cannot revoke the peer's tty handle.
The proxy sends no signal or resize messages; job-control ownership is unchanged.
