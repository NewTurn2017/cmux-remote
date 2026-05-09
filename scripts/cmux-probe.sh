#!/usr/bin/env bash
set -euo pipefail
SOCK="${CMUX_SOCKET_PATH:-$HOME/Library/Application Support/cmux/cmux.sock}"
[ -S "$SOCK" ] || { echo "cmux socket missing: $SOCK"; exit 1; }
SOCK="$SOCK" perl -e '
  $SIG{ALRM}=sub{exit 0}; alarm 3;
  use Socket; socket(my $s,PF_UNIX,SOCK_STREAM,0)or die$!;
  connect($s,sockaddr_un($ENV{SOCK}))or die"connect: $!";
  syswrite($s, qq({"id":"probe-1","method":"workspace.list","params":{}}\n));
  my $b; sysread($s,$b,65536); print substr($b,0,400),"\n";
'
