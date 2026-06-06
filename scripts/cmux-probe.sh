#!/usr/bin/env bash
set -euo pipefail

# Resolve the cmux socket the same way cmux-relay's cmuxSocketPath() does:
# explicit override first, then cmux's markers newest-convention first, then the
# modern XDG state-dir fallback. Older cmux only wrote the Application Support
# marker; 1.0.5+ moved state to ~/.local/state/cmux and also publishes a fixed
# /tmp/cmux-last-socket-path pointer.
resolve_sock() {
  if [ -n "${CMUX_SOCKET_PATH:-}" ]; then printf '%s' "$CMUX_SOCKET_PATH"; return; fi
  local state_dir="${XDG_STATE_HOME:-$HOME/.local/state}"
  local marker target
  for marker in \
    /tmp/cmux-last-socket-path \
    "$state_dir/cmux/last-socket-path" \
    "$HOME/Library/Application Support/cmux/last-socket-path"; do
    [ -r "$marker" ] || continue
    target="$(tr -d '\n' < "$marker")"
    [ -n "$target" ] && [ -S "$target" ] && { printf '%s' "$target"; return; }
  done
  printf '%s' "$state_dir/cmux/cmux.sock"
}

SOCK="$(resolve_sock)"
[ -S "$SOCK" ] || { echo "cmux socket missing: $SOCK"; exit 1; }
SOCK="$SOCK" perl -e '
  $SIG{ALRM}=sub{exit 0}; alarm 3;
  use Socket; socket(my $s,PF_UNIX,SOCK_STREAM,0)or die$!;
  connect($s,sockaddr_un($ENV{SOCK}))or die"connect: $!";
  syswrite($s, qq({"id":"probe-1","method":"workspace.list","params":{}}\n));
  my $b; sysread($s,$b,65536); print substr($b,0,400),"\n";
'
