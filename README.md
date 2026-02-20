# tty-proxy

`tty-proxy` is a Zig 0.15.2 executable that owns terminal handling and forwards
bytes between a terminal and a local Common Lisp peer over a Unix socket.

## Building

This project uses Zig's standard build system (`build.zig`). The build script
installs the executable into `zig-out/bin/tty-proxy`.

```sh
zig build
```

Common build commands:

```sh
zig build                # compile and install tty-proxy
zig build test           # run unit tests
zig build run -- [args]  # run tty-proxy with optional arguments
```

You can also pass Zig's standard build options, for example:

```sh
zig build -Dtarget=x86_64-linux -Doptimize=ReleaseSafe
```

Run `zig build --help` to see the full list of project-specific and standard
options.

## Requirements

- Zig 0.15.2
- A Unix-like system with Unix sockets, `termios`, and `pselect`

## Configuration

At runtime, `tty-proxy` reads a plain-text config file from either:

1. `TTY_PROXY_CONFIG`, or
2. `~/.config/tty-proxy/config`

Entries map an executable name to a peer socket path. Resolution prefers the
exact `argv[0]` key and falls back to the basename of `argv[0]`.

Example:

```text
# comments and blank lines are ignored
tty-proxy = socket:/tmp/tty-proxy.sock
```

Only `socket:` values are used. Other values are ignored.

## Runtime Protocol

On startup, `tty-proxy`:

1. verifies that `stdin` is a tty
2. resolves and connects to the configured Unix socket
3. sets `stdin`, `stdout`, `stderr`, and the peer socket non-blocking
4. queues startup info to the peer as a Lisp plist:

```lisp
(:args (...) :tty "/dev/tty..."
 :env ((NAME VALUE) ...)
 :size (:rows R :cols C :xpixels X :ypixels Y))
```

After reading startup info, the peer sends a single operation-mode byte:

- `R` — `tty-proxy` enables raw mode on `stdin` and restores the
  original terminal settings on exit
- `C` — `tty-proxy` leaves the terminal mode unchanged
- `E` — `tty-proxy` leaves the terminal mode unchanged and treats peer
  output as an error stream

In `C` and `E`, `tty-proxy` does not call `tcsetattr(2)`. The peer still can
change terminal settings itself, for example by opening the reported `:tty`
path and configuring it directly.

`tty-proxy` consumes that first byte, then forwards the remaining peer payload.

## I/O Behavior

`tty-proxy` uses a single-threaded `pselect(2)` loop with two internal buffers:

- `to_lisp` — bytes pending to the peer
- `to_term` — bytes pending to terminal output

Behavior by mode:

- In `R` and `C`, terminal input is read and forwarded to the peer.
- In `R`, `tty-proxy` enables raw mode before forwarding interactive
  input and restores the original terminal settings on exit.
- In `C`, `tty-proxy` leaves the existing terminal mode untouched.
- Peer output is written to `stdout` in `R` and `C`.
- In `E`, no further bytes are sent to the peer.
- In `E`, peer output is written to `stderr`.
- On peer EOF, `tty-proxy` drains buffered output before exiting.
- If the final mode was `E`, `tty-proxy` exits with status `1` after flushing
  the error message.

Signals:

- `SIGINT` and `SIGTERM` are handled
- signal exit status is `128 + signal`
