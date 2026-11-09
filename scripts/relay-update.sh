#!/bin/bash
# cmux Remote relay updater: the launchd agent com.genie.cmuxremote.updater.
#
# Follows only the release tags vX.Y.Z of the origin recorded in update/config.json.
# When a newer release exists it fetches it into a managed clone under the relay home
# (never the checkout the relay was installed from), builds and signs it, stages it,
# and installs it with that release's own install-launchd.sh --apply-staged.
# Automatic updates restart the relay only after no phone has been connected for
# idle_restart_seconds; a user's relay.update.start (update/request.json) applies at once.
# A new relay that does not stay up is rolled back and its tag is not retried
# automatically.
#
# INTERNAL STABLE INTERFACE. Every future release keeps these, because the updater of
# an older release installs a newer one and reads that relay's runtime file:
#   install-launchd.sh --apply-staged <dir>
#   <dir>/cmux-relay, <dir>/manifest.json, and <dir>/scripts/ with install-launchd.sh,
#     relay-update.sh, relay.plist.tmpl, relay-updater.plist.tmpl
#   update/relay-runtime.json  schema_version, pid, version, started_at_ms,
#                              active_sessions, zero_since_ms (written by the relay)
#   update/state.json          schema_version, state, pid, latest_version,
#                              last_checked_at_ms, last_error_code, signing (this updater)
#   update/request.json        schema_version, source, requested_at_ms (written by the relay)
#   update/config.json         schema_version, auto_update, origin, check_interval_seconds,
#                              idle_restart_seconds, installed_version (install-launchd.sh)
#
# Written for macOS /bin/bash 3.2: no associative arrays, mapfile, or ${var,,}.

set -u
umask 022

LABEL="com.genie.cmuxremote"
DEST="${CMUX_REMOTE_HOME:-$HOME/.cmuxremote}"
UPDATE_DIR="$DEST/update"
CONFIG="$UPDATE_DIR/config.json"
STATE="$UPDATE_DIR/state.json"
REQUEST="$UPDATE_DIR/request.json"
RUNTIME="$UPDATE_DIR/relay-runtime.json"
FAILED_TAGS="$UPDATE_DIR/failed-tags"
SEEN_TAGS="$UPDATE_DIR/seen-tags"
STAGED="$UPDATE_DIR/staged"
ROLLBACK="$UPDATE_DIR/rollback"
LOCK="$UPDATE_DIR/updater.lock"
GIT_LOG="$UPDATE_DIR/last-git.log"
SRC="$DEST/src/cmux-remote"
BIN="$DEST/bin/cmux-relay"
UPDATER_SCRIPT="$DEST/libexec/relay-update.sh"
LOGDIR="${CMUX_RELAY_LOGDIR:-$DEST/log}"
LOG="$LOGDIR/update.log"
LAUNCH_AGENTS_DIR="${CMUX_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
RELAY_PLIST="$LAUNCH_AGENTS_DIR/$LABEL.plist"
GUI="gui/$(id -u)"
LAUNCHCTL="${CMUX_RELAY_LAUNCHCTL:-/bin/launchctl}"
CODESIGN="${CMUX_RELAY_CODESIGN:-/usr/bin/codesign}"
GIT="${CMUX_RELAY_GIT:-git}"
BUILD_CMD="${CMUX_RELAY_UPDATE_BUILD_CMD:-swift build -c release --product cmux-relay}"
TEST_MODE="${CMUX_RELAY_UPDATE_TEST:-0}"
HEALTH_TIMEOUT="${CMUX_RELAY_UPDATE_HEALTH_TIMEOUT:-60}"
STABLE_SECONDS="${CMUX_RELAY_UPDATE_STABLE_SECONDS:-15}"
BUILD_TIMEOUT="${CMUX_RELAY_UPDATE_BUILD_TIMEOUT:-1800}"
SIGN_TIMEOUT="${CMUX_RELAY_UPDATE_SIGN_TIMEOUT:-120}"
FIRST_CHECK_DELAY_MS=600000
MAX_BACKOFF_MS=86400000
MIN_FREE_KB=2097152
TAG_RE='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
VERSION_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
TILDE='~'

S_STATE=""
S_CURRENT=""
S_LATEST=""
S_TAG=""
S_COMMIT=""
S_CHECKED=""
S_NEXT=""
S_FAILURES=0
S_ERROR=""
S_SIGNING=""
USER_REQUEST=0
FIRST_RUN=0
TOOLCHAIN=""
SKIP_CODE=""

usage() {
  cat <<USAGE
Usage: relay-update.sh [tick]

Runs one updater pass. launchd starts it every 300 seconds and when the relay
receives relay.update.start. Logs go to $LOGDIR/update.log.
USAGE
}

account_home() {
  local name
  name="$(id -un)"
  eval "printf '%s' ~$name"
}
REAL_HOME="$(account_home)"

resolve_dir() {
  (cd "$1" 2>/dev/null && pwd -P)
}

# Test mode must never reach the real relay home, LaunchAgents, launchd, or keychain.
test_mode_guard() {
  [ "$TEST_MODE" = "1" ] || return 0
  local tmp dest agents found
  tmp="$(resolve_dir "${TMPDIR:-/tmp}")" || return 1
  dest="$(resolve_dir "$DEST")" || { echo "test mode: relay home must exist under TMPDIR: $DEST" >&2; return 1; }
  agents="$(resolve_dir "$LAUNCH_AGENTS_DIR")" || { echo "test mode: LaunchAgents must exist under TMPDIR" >&2; return 1; }
  case "$dest/" in "$tmp"/*) ;; *) echo "test mode: relay home is not under TMPDIR: $DEST" >&2; return 1 ;; esac
  case "$agents/" in "$tmp"/*) ;; *) echo "test mode: LaunchAgents is not under TMPDIR" >&2; return 1 ;; esac
  if [ "$dest" = "$(resolve_dir "$REAL_HOME/.cmuxremote")" ]; then
    echo "test mode: relay home resolves to the real ~/.cmuxremote" >&2
    return 1
  fi
  case "$LAUNCHCTL" in launchctl|/bin/launchctl) echo "test mode: real launchctl" >&2; return 1 ;; esac
  found="$(command -v launchctl 2>/dev/null || true)"
  [ "$found" != "/bin/launchctl" ] || { echo "test mode: /bin/launchctl is first on PATH" >&2; return 1; }
  case "$CODESIGN" in codesign|/usr/bin/codesign) echo "test mode: real codesign" >&2; return 1 ;; esac
  return 0
}

now_ms() {
  if [ -n "${CMUX_RELAY_UPDATE_NOW_MS:-}" ]; then
    printf '%s' "$CMUX_RELAY_UPDATE_NOW_MS"
  else
    printf '%s' "$(( $(date +%s) * 1000 ))"
  fi
}

redact() {
  local s="$1"
  if [ -n "${HOME:-}" ]; then s="${s//"$HOME"/$TILDE}"; fi
  if [ -n "$REAL_HOME" ]; then s="${s//"$REAL_HOME"/$TILDE}"; fi
  printf '%s' "$s"
}

redact_stream() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    printf '%s\n' "$(redact "$line")"
  done
}

log() {
  mkdir -p "$LOGDIR" 2>/dev/null || return 0
  if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 1048576 ]; then
    mv -f "$LOG" "$LOG.1"
  fi
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(redact "$*")" >> "$LOG"
}

json_get() {
  /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null
}

is_count() {
  case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac
}

remove_tree() {
  case "$1" in
    "$DEST"/?*) [ -n "$DEST" ] && [ "$DEST" != "/" ] && rm -rf "$1" ;;
    *) log "refusing to remove a path outside the relay home" ;;
  esac
}

acquire_lock() {
  /usr/bin/shlock -p $$ -f "$LOCK"
}

release_lock() {
  if [ "$(cat "$LOCK" 2>/dev/null)" = "$$" ]; then
    rm -f "$LOCK"
  fi
}

load_config() {
  AUTO_UPDATE="$(json_get "$CONFIG" auto_update)"
  ORIGIN="$(json_get "$CONFIG" origin)"
  INTERVAL_S="$(json_get "$CONFIG" check_interval_seconds)"
  IDLE_S="$(json_get "$CONFIG" idle_restart_seconds)"
  is_count "$INTERVAL_S" || INTERVAL_S=3600
  is_count "$IDLE_S" || IDLE_S=120
  if [ "$TEST_MODE" != "1" ] && [ "$INTERVAL_S" -lt 3600 ]; then
    INTERVAL_S=3600
  fi
}

origin_allowed() {
  case "$ORIGIN" in *'"'*|*\\*|*' '*|'') return 1 ;; esac
  case "$ORIGIN" in
    https://*) return 0 ;;
    file://*|/*) [ "$TEST_MODE" = "1" ] ;;
    *) return 1 ;;
  esac
}

origin_label() {
  local o="${ORIGIN#*://}"
  o="${o#*@}"
  printf '%s' "${o%.git}"
}

configure_git() {
  export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
  if [ "$TEST_MODE" = "1" ]; then
    export GIT_ALLOW_PROTOCOL=file
  else
    export GIT_ALLOW_PROTOCOL=https
  fi
}

run_git() {
  "$GIT" "$@" 2>&1 | redact_stream >> "$GIT_LOG"
  return "${PIPESTATUS[0]}"
}

# Runs a command in its own process group and ends the whole group after $1 seconds
# (exit 124), so a codesign waiting on a keychain prompt or a stuck build cannot hold
# the updater lock forever. A TERM to the updater is passed on to the group.
run_with_timeout() {
  local limit="$1"
  shift
  [ -x /usr/bin/perl ] || { "$@"; return; }
  /usr/bin/perl -MPOSIX=:sys_wait_h -e '
    my $limit = shift @ARGV;
    my $pid = fork();
    exit 127 unless defined $pid;
    if ($pid == 0) { setpgrp(0, 0); exec { $ARGV[0] } @ARGV; exit 127; }
    my $stop = sub {
      kill "TERM", -$pid;
      for (1 .. 20) { last if waitpid($pid, WNOHANG) > 0; select(undef, undef, undef, 0.1); }
      kill "KILL", -$pid;
      waitpid($pid, 0);
    };
    $SIG{$_} = sub { $stop->(); exit 143; } for qw(TERM INT HUP);
    $SIG{ALRM} = sub { $stop->(); exit 124; };
    alarm $limit;
    waitpid($pid, 0);
    alarm 0;
    exit(($? & 127) ? 128 + ($? & 127) : $? >> 8);
  ' "$limit" "$@"
}

# launchctl bootout can return before launchd has dropped the job, and a bootstrap in
# that window fails (5: Input/output error). Waits up to 10s for the job to go, then
# bootstraps with a few retries. install-launchd.sh carries the same helper.
bootstrap_job() {
  local plist="$1" service="$GUI/$2" waited=0 tries=0
  while "$LAUNCHCTL" print "$service" >/dev/null 2>&1; do
    [ "$waited" -lt 50 ] || break
    sleep 0.2
    waited=$(( waited + 1 ))
  done
  until "$LAUNCHCTL" bootstrap "$GUI" "$plist" >/dev/null 2>&1; do
    tries=$(( tries + 1 ))
    [ "$tries" -lt 5 ] || return 1
    sleep 1
  done
}

load_state() {
  [ -f "$STATE" ] || return 1
  S_STATE="$(json_get "$STATE" state)"
  S_CURRENT="$(json_get "$STATE" current_version)"
  S_LATEST="$(json_get "$STATE" latest_version)"
  S_TAG="$(json_get "$STATE" latest_tag)"
  S_COMMIT="$(json_get "$STATE" latest_commit)"
  S_CHECKED="$(json_get "$STATE" last_checked_at_ms)"
  S_NEXT="$(json_get "$STATE" next_check_at_ms)"
  S_FAILURES="$(json_get "$STATE" consecutive_failures)"
  S_ERROR="$(json_get "$STATE" last_error_code)"
  S_SIGNING="$(json_get "$STATE" signing)"
  is_count "$S_FAILURES" || S_FAILURES=0
  is_count "$S_NEXT" || S_NEXT=""
  return 0
}

save_state() {
  local tmp="$STATE.tmp.$$"
  {
    printf '{"schema_version":1,"state":"%s","pid":%s' "$S_STATE" "$$"
    [ -z "$S_CURRENT" ] || printf ',"current_version":"%s"' "$S_CURRENT"
    [ -z "$S_LATEST" ] || printf ',"latest_version":"%s"' "$S_LATEST"
    [ -z "$S_TAG" ] || printf ',"latest_tag":"%s"' "$S_TAG"
    [ -z "$S_COMMIT" ] || printf ',"latest_commit":"%s"' "$S_COMMIT"
    [ -z "$S_CHECKED" ] || printf ',"last_checked_at_ms":%s' "$S_CHECKED"
    [ -z "$S_NEXT" ] || printf ',"next_check_at_ms":%s' "$S_NEXT"
    printf ',"consecutive_failures":%s' "${S_FAILURES:-0}"
    [ -z "$S_ERROR" ] || printf ',"last_error_code":"%s"' "$S_ERROR"
    [ -z "$S_SIGNING" ] || printf ',"signing":"%s"' "$S_SIGNING"
    printf ',"updated_at_ms":%s}\n' "$(now_ms)"
  } > "$tmp" && mv -f "$tmp" "$STATE"
}

installed_version() {
  local v
  v="$("$BIN" --version 2>/dev/null | head -n 1)"
  [[ $v =~ $VERSION_RE ]] || return 1
  printf '%s' "$v"
}

toolchain_ready() {
  if [ "$TEST_MODE" != "1" ]; then
    /usr/bin/xcode-select -p >/dev/null 2>&1 || return 1
  fi
  command -v "$GIT" >/dev/null 2>&1
}

toolchain_id() {
  if [ -n "${CMUX_RELAY_UPDATE_TOOLCHAIN_ID:-}" ]; then
    printf '%s' "$CMUX_RELAY_UPDATE_TOOLCHAIN_ID"
  else
    swift --version 2>/dev/null | /usr/bin/shasum -a 256 | cut -c1-12
  fi
}

ver_gt() {
  local a1 a2 a3 b1 b2 b3
  IFS=. read -r a1 a2 a3 <<< "$1"
  IFS=. read -r b1 b2 b3 <<< "$2"
  if [ "$a1" -ne "$b1" ]; then [ "$a1" -gt "$b1" ]; return; fi
  if [ "$a2" -ne "$b2" ]; then [ "$a2" -gt "$b2" ]; return; fi
  [ "$a3" -gt "$b3" ]
}

# Prints "tag commit" for every release tag newer than $2, newest first. $1 holds
# `git ls-remote --tags` output; annotated tags resolve to their peeled commit.
release_candidates() {
  local tag commit major minor patch
  awk '{
      ref = $2; sub(/^refs\/tags\//, "", ref)
      if (ref ~ /\^\{\}$/) { sub(/\^\{\}$/, "", ref); peeled[ref] = $1 } else { direct[ref] = $1 }
    }
    END { for (t in direct) print t, ((t in peeled) ? peeled[t] : direct[t]) }' "$1" |
  while read -r tag commit; do
    [[ $tag =~ $TAG_RE ]] || continue
    major="${BASH_REMATCH[1]}"; minor="${BASH_REMATCH[2]}"; patch="${BASH_REMATCH[3]}"
    ver_gt "$major.$minor.$patch" "$2" || continue
    printf '%s %s %s %s %s\n' "$major" "$minor" "$patch" "$tag" "$commit"
  done | sort -k1,1nr -k2,2nr -k3,3nr | awk '{ print $4, $5 }'
}

# Sets SKIP_CODE to the failure that skips the tag: tag_verification_failed always,
# otherwise the latest failure with this toolchain unless the user asked for the update.
tag_is_skipped() {
  SKIP_CODE=""
  [ -f "$FAILED_TAGS" ] || return 1
  local t c code tc skipped=1
  while read -r t c code tc; do
    [ "$t" = "$1" ] && [ "$c" = "$2" ] || continue
    if [ "$code" = "tag_verification_failed" ]; then
      SKIP_CODE="$code"
      return 0
    fi
    [ "$USER_REQUEST" = "1" ] && continue
    if [ "$tc" = "$TOOLCHAIN" ]; then
      SKIP_CODE="$code"
      skipped=0
    fi
  done < "$FAILED_TAGS"
  return "$skipped"
}

tag_moved() {
  [ -f "$SEEN_TAGS" ] || return 1
  local t c
  while read -r t c; do
    [ "$t" = "$1" ] && [ "$c" != "$2" ] && return 0
  done < "$SEEN_TAGS"
  return 1
}

remember_tag() {
  if [ -f "$SEEN_TAGS" ] && grep -qx "$1 $2" "$SEEN_TAGS"; then
    return 0
  fi
  printf '%s %s\n' "$1" "$2" >> "$SEEN_TAGS"
}

mark_failed() {
  printf '%s %s %s %s\n' "$1" "$2" "$3" "$TOOLCHAIN" >> "$FAILED_TAGS"
}

# Network, signing, disk, and toolchain trouble: retry later with exponential backoff.
fail_retry() {
  local exp delay
  S_FAILURES=$(( ${S_FAILURES:-0} + 1 ))
  exp=$(( S_FAILURES - 1 ))
  [ "$exp" -le 5 ] || exp=5
  delay=$(( INTERVAL_S * 1000 * (1 << exp) ))
  [ "$delay" -le "$MAX_BACKOFF_MS" ] || delay=$MAX_BACKOFF_MS
  S_NEXT=$(( $(now_ms) + delay ))
  S_STATE=failed
  S_ERROR="$1"
  save_state
  rm -f "$REQUEST"
  remove_tree "$STAGED.tmp"
  log "state=failed reason=$1 failures=$S_FAILURES retry_in_s=$(( delay / 1000 ))"
}

# A failure tied to one release: remember the tag so it is not retried automatically.
fail_tag() {
  mark_failed "$2" "$3" "$1"
  S_NEXT=$(( $(now_ms) + INTERVAL_S * 1000 ))
  S_STATE=failed
  S_ERROR="$1"
  S_FAILURES=0
  save_state
  rm -f "$REQUEST"
  remove_tree "$STAGED.tmp"
  log "state=failed reason=$1 tag=$2 commit=${3:0:12}"
}

# Returns 0 when the tag's commit is checked out, 1 on network trouble, 2 when the tag
# does not match its advertised commit or is not on origin/main.
fetch_source() {
  local tag="$1" commit="$2" got
  if [ ! -d "$SRC/.git" ]; then
    remove_tree "$SRC.tmp"
    mkdir -p "$(dirname "$SRC")" || return 1
    run_git clone --quiet --filter=blob:none --no-checkout --no-tags "$ORIGIN" "$SRC.tmp" || return 1
    mv "$SRC.tmp" "$SRC" || return 1
  fi
  run_git -C "$SRC" remote set-url origin "$ORIGIN" || return 1
  run_git -C "$SRC" fetch --quiet --no-tags --filter=blob:none origin \
    "+refs/heads/main:refs/remotes/origin/main" "+refs/tags/$tag:refs/tags/$tag" || return 1
  got="$("$GIT" -C "$SRC" rev-parse --verify --quiet "refs/tags/$tag^{commit}" 2>/dev/null)" || return 2
  [ "$got" = "$commit" ] || return 2
  "$GIT" -C "$SRC" merge-base --is-ancestor "$commit" refs/remotes/origin/main 2>/dev/null || return 2
  run_git -C "$SRC" -c advice.detachedHead=false checkout --quiet --force --detach "$commit" || return 1
  run_git -C "$SRC" clean -ffdxq -e .build -e Package.resolved || return 1
  return 0
}

disk_ready() {
  local avail
  avail="$(df -Pk "$DEST" 2>/dev/null | awk 'NR == 2 { print $4 }')"
  is_count "$avail" || return 0
  [ "$avail" -ge "$MIN_FREE_KB" ]
}

# Returns 0 when the release binary was built, 2 when the build ran out of time, 1 otherwise.
build_release() {
  local raw="$UPDATE_DIR/build.tmp.$$" rc
  (cd "$SRC" && run_with_timeout "$BUILD_TIMEOUT" /bin/bash -c "$BUILD_CMD") > "$raw" 2>&1
  rc=$?
  tail -n 200 "$raw" | redact_stream > "$UPDATE_DIR/last-build.log"
  rm -f "$raw"
  [ "$rc" -ne 124 ] || return 2
  [ "$rc" -eq 0 ] && [ -x "$SRC/.build/release/cmux-relay" ]
}

stage_release() {
  local tag="$1" commit="$2" version="$3" identity="" file digest rc
  remove_tree "$STAGED.tmp"
  mkdir -p "$STAGED.tmp/scripts" || { fail_retry insufficient_disk; return 1; }
  cp "$SRC/.build/release/cmux-relay" "$STAGED.tmp/cmux-relay" && chmod 755 "$STAGED.tmp/cmux-relay" \
    || { fail_retry insufficient_disk; return 1; }
  for file in install-launchd.sh relay-update.sh relay.plist.tmpl relay-updater.plist.tmpl; do
    cp "$SRC/scripts/$file" "$STAGED.tmp/scripts/$file" || { fail_tag install_failed "$tag" "$commit"; return 1; }
  done
  if [ -f "$DEST/codesign-identity" ]; then
    identity="$(head -n 1 "$DEST/codesign-identity")"
  fi
  if [ -n "$identity" ] && [ "$identity" != "adhoc" ]; then
    run_with_timeout "$SIGN_TIMEOUT" "$CODESIGN" --force --timestamp=none --identifier "$LABEL.relay" \
      --sign "$identity" "$STAGED.tmp/cmux-relay" >/dev/null 2>&1
    rc=$?
    if [ "$rc" -eq 0 ]; then
      run_with_timeout "$SIGN_TIMEOUT" "$CODESIGN" --verify --strict "$STAGED.tmp/cmux-relay" >/dev/null 2>&1
      rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
      [ "$rc" -ne 124 ] || log "codesign timed out after ${SIGN_TIMEOUT}s tag=$tag"
      fail_retry sign_failed
      return 1
    fi
    S_SIGNING=identity
  else
    S_SIGNING=adhoc
    log "warning=adhoc_signature downloads_permission_may_reprompt tag=$tag"
  fi
  digest="$(/usr/bin/shasum -a 256 "$STAGED.tmp/cmux-relay" | cut -d ' ' -f 1)"
  printf '{"schema_version":1,"tag":"%s","version":"%s","commit":"%s","built_at_ms":%s,"binary_sha256":"%s","signing":"%s","toolchain":"%s"}\n' \
    "$tag" "$version" "$commit" "$(now_ms)" "$digest" "$S_SIGNING" "$TOOLCHAIN" > "$STAGED.tmp/manifest.json"
  remove_tree "$STAGED"
  mv "$STAGED.tmp" "$STAGED"
}

phones_idle() {
  [ -f "$RUNTIME" ] || return 0
  local pid active zero
  pid="$(json_get "$RUNTIME" pid)"
  active="$(json_get "$RUNTIME" active_sessions)"
  zero="$(json_get "$RUNTIME" zero_since_ms)"
  is_count "$pid" || return 0
  kill -0 "$pid" 2>/dev/null || return 0
  [ "$active" = "0" ] || return 1
  is_count "$zero" || return 1
  [ $(( $(now_ms) - zero )) -ge $(( IDLE_S * 1000 )) ]
}

backup_current() {
  remove_tree "$ROLLBACK"
  mkdir -p "$ROLLBACK" || return 1
  if [ -f "$BIN" ]; then cp -p "$BIN" "$ROLLBACK/cmux-relay" || return 1; fi
  if [ -f "$RELAY_PLIST" ]; then cp -p "$RELAY_PLIST" "$ROLLBACK/relay.plist" || return 1; fi
  if [ -f "$UPDATER_SCRIPT" ]; then cp -p "$UPDATER_SCRIPT" "$ROLLBACK/relay-update.sh" || return 1; fi
  return 0
}

wait_healthy() {
  local version="$1" old_pid="$2" waited=0 pid ver
  while :; do
    pid="$(json_get "$RUNTIME" pid)"
    ver="$(json_get "$RUNTIME" version)"
    if is_count "$pid" && [ "$pid" != "$old_pid" ] && [ "$ver" = "$version" ] && kill -0 "$pid" 2>/dev/null; then
      break
    fi
    [ "$waited" -lt "$HEALTH_TIMEOUT" ] || return 1
    sleep 1
    waited=$(( waited + 1 ))
  done
  if [ "$STABLE_SECONDS" -gt 0 ]; then
    sleep "$STABLE_SECONDS"
  fi
  kill -0 "$pid" 2>/dev/null && [ "$(json_get "$RUNTIME" pid)" = "$pid" ]
}

rollback() {
  local code="$1" tag="$2" commit="$3"
  log "rollback tag=$tag reason=$code"
  if [ -f "$ROLLBACK/cmux-relay" ]; then
    cp -p "$ROLLBACK/cmux-relay" "$BIN.new" && mv -f "$BIN.new" "$BIN"
  fi
  if [ -f "$ROLLBACK/relay-update.sh" ]; then
    cp -p "$ROLLBACK/relay-update.sh" "$UPDATER_SCRIPT.new" && mv -f "$UPDATER_SCRIPT.new" "$UPDATER_SCRIPT"
  fi
  if [ -f "$ROLLBACK/relay.plist" ] && ! cmp -s "$ROLLBACK/relay.plist" "$RELAY_PLIST"; then
    cp -p "$ROLLBACK/relay.plist" "$RELAY_PLIST.new" && mv -f "$RELAY_PLIST.new" "$RELAY_PLIST"
    "$LAUNCHCTL" bootout "$GUI/$LABEL" >/dev/null 2>&1 || true
    bootstrap_job "$RELAY_PLIST" "$LABEL" || log "rollback bootstrap failed"
  else
    "$LAUNCHCTL" kickstart -k "$GUI/$LABEL" >/dev/null 2>&1 || log "rollback kickstart failed"
  fi
  remove_tree "$STAGED"
  fail_tag "$code" "$tag" "$commit"
}

apply_staged() {
  local version tag commit signing old_pid rc
  version="$(json_get "$STAGED/manifest.json" version)"
  tag="$(json_get "$STAGED/manifest.json" tag)"
  commit="$(json_get "$STAGED/manifest.json" commit)"
  signing="$(json_get "$STAGED/manifest.json" signing)"
  # A failure here is remembered under the toolchain that built this release, also when
  # the release is applied on a later pass that never ran run_check.
  [ -n "$TOOLCHAIN" ] || TOOLCHAIN="$(json_get "$STAGED/manifest.json" toolchain)"
  [ -n "$TOOLCHAIN" ] || TOOLCHAIN="$(toolchain_id)"
  if ! [[ $version =~ $VERSION_RE ]]; then
    remove_tree "$STAGED"
    fail_retry version_unknown
    return 0
  fi
  S_STATE=applying
  S_LATEST="$version"
  S_TAG="$tag"
  S_COMMIT="$commit"
  [ -z "$signing" ] || S_SIGNING="$signing"
  save_state
  rm -f "$REQUEST"
  old_pid="$(json_get "$RUNTIME" pid)"
  log "applying tag=$tag commit=${commit:0:12} user_request=$USER_REQUEST"
  if ! backup_current; then
    remove_tree "$STAGED"
    fail_tag install_failed "$tag" "$commit"
    return 0
  fi
  CMUX_RELAY_UPDATER_CONTEXT=1 /bin/bash "$STAGED/scripts/install-launchd.sh" --apply-staged "$STAGED" 2>&1 \
    | redact_stream >> "$LOG"
  rc="${PIPESTATUS[0]}"
  if [ "$rc" -ne 0 ]; then
    rollback install_failed "$tag" "$commit"
    return 0
  fi
  if ! wait_healthy "$version" "$old_pid"; then
    rollback start_failed "$tag" "$commit"
    return 0
  fi
  S_STATE=idle
  S_CURRENT="$version"
  S_ERROR=""
  S_FAILURES=0
  save_state
  remove_tree "$STAGED"
  log "applied tag=$tag version=$version"
}

# A release staged before someone installed the same or a newer relay by hand must never
# be applied over it. Returns 0 after dropping such a release and recording idle.
discard_staged_if_not_newer() {
  local version installed
  version="$(json_get "$STAGED/manifest.json" version)"
  installed="$(installed_version)" || return 1
  [[ $version =~ $VERSION_RE ]] || return 1
  ! ver_gt "$version" "$installed" || return 1
  log "discarded staged tag=$(json_get "$STAGED/manifest.json" tag) version=$version installed=$installed reason=not_newer"
  remove_tree "$STAGED"
  S_STATE=idle
  S_CURRENT="$installed"
  S_LATEST="$installed"
  S_TAG=""
  S_COMMIT=""
  S_ERROR=""
  S_FAILURES=0
  save_state
  return 0
}

# Returns 2 when the staged release was dropped as not newer, so the caller can go on
# to a normal check; 0 otherwise.
maybe_apply() {
  [ -f "$REQUEST" ] && USER_REQUEST=1
  if discard_staged_if_not_newer; then
    return 2
  fi
  if [ "$USER_REQUEST" != "1" ] && ! phones_idle; then
    log "staged tag=$S_TAG waiting until no phone is connected for ${IDLE_S}s"
    return 0
  fi
  apply_staged
}

run_check() {
  local current listing tag commit rc chosen_tag="" chosen_commit="" built
  local skipped_tag="" skipped_commit="" skipped_code=""
  S_STATE=checking
  S_ERROR=""
  save_state
  log "state=checking current=${S_CURRENT:-unknown} origin=$(origin_label) user_request=$USER_REQUEST"
  if ! toolchain_ready; then fail_retry toolchain_missing; return; fi
  TOOLCHAIN="$(toolchain_id)"
  if ! current="$(installed_version)"; then fail_retry version_unknown; return; fi
  S_CURRENT="$current"

  listing="$UPDATE_DIR/ls-remote.tmp.$$"
  if ! "$GIT" ls-remote --tags "$ORIGIN" 'refs/tags/v*' > "$listing" 2> "$listing.err"; then
    redact_stream < "$listing.err" >> "$GIT_LOG"
    rm -f "$listing" "$listing.err"
    fail_retry network_failed
    return
  fi
  rm -f "$listing.err"
  S_CHECKED="$(now_ms)"

  while read -r tag commit <&3; do
    if tag_is_skipped "$tag" "$commit"; then
      # Remember the newest release skipped for its own failure (not a rejected tag).
      if [ -z "$skipped_tag" ] && [ "$SKIP_CODE" != "tag_verification_failed" ]; then
        skipped_tag="$tag"
        skipped_commit="$commit"
        skipped_code="$SKIP_CODE"
      fi
      continue
    fi
    if tag_moved "$tag" "$commit"; then
      log "rejected tag=$tag commit=${commit:0:12} reason=tag_moved"
      mark_failed "$tag" "$commit" tag_verification_failed
      continue
    fi
    S_STATE=downloading
    S_TAG="$tag"
    S_COMMIT="$commit"
    save_state
    fetch_source "$tag" "$commit"
    rc=$?
    if [ "$rc" -eq 0 ]; then
      chosen_tag="$tag"
      chosen_commit="$commit"
      break
    fi
    if [ "$rc" -eq 1 ]; then
      exec 3<&-
      rm -f "$listing"
      fail_retry network_failed
      return
    fi
    log "rejected tag=$tag commit=${commit:0:12} reason=not_on_main_or_commit_mismatch"
    mark_failed "$tag" "$commit" tag_verification_failed
  done 3< <(release_candidates "$listing" "$current")
  rm -f "$listing"

  if [ -z "$chosen_tag" ] && [ -n "$skipped_tag" ]; then
    # A newer release exists but failed before: keep reporting it and why, so the app
    # does not say "up to date" and the user can still ask for a retry.
    S_STATE=failed
    S_LATEST="${skipped_tag#v}"
    S_TAG="$skipped_tag"
    S_COMMIT="$skipped_commit"
    S_ERROR="$skipped_code"
    S_FAILURES=0
    S_NEXT=$(( $(now_ms) + INTERVAL_S * 1000 ))
    save_state
    rm -f "$REQUEST"
    log "state=failed reason=$skipped_code tag=$skipped_tag skipped=failed_before current=$current"
    return
  fi

  if [ -z "$chosen_tag" ]; then
    S_STATE=idle
    S_LATEST="$current"
    S_TAG=""
    S_COMMIT=""
    S_ERROR=""
    S_FAILURES=0
    S_NEXT=$(( $(now_ms) + INTERVAL_S * 1000 ))
    save_state
    rm -f "$REQUEST"
    log "state=idle current=$current"
    return
  fi

  remember_tag "$chosen_tag" "$chosen_commit"
  S_LATEST="${chosen_tag#v}"
  if ! disk_ready; then fail_retry insufficient_disk; return; fi
  S_STATE=building
  save_state
  log "found tag=$chosen_tag commit=${chosen_commit:0:12}; building"
  build_release
  rc=$?
  if [ "$rc" -eq 2 ]; then
    # Running out of time says nothing about the release; retry later with backoff.
    log "build timed out after ${BUILD_TIMEOUT}s tag=$chosen_tag"
    fail_retry build_failed
    return
  fi
  if [ "$rc" -ne 0 ]; then fail_tag build_failed "$chosen_tag" "$chosen_commit"; return; fi
  built="$("$SRC/.build/release/cmux-relay" --version 2>/dev/null | head -n 1)"
  if [ "$built" != "${chosen_tag#v}" ]; then fail_tag version_mismatch "$chosen_tag" "$chosen_commit"; return; fi
  stage_release "$chosen_tag" "$chosen_commit" "$built" || return
  S_STATE=staged
  S_ERROR=""
  S_FAILURES=0
  S_NEXT=$(( $(now_ms) + INTERVAL_S * 1000 ))
  save_state
  log "staged tag=$chosen_tag signing=$S_SIGNING"
  maybe_apply
}

cleanup_leftovers() {
  remove_tree "$STAGED.tmp"
  remove_tree "$SRC.tmp"
  rm -f "$UPDATE_DIR"/*.tmp.*
}

main() {
  case "${1:-tick}" in
    tick) ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  test_mode_guard || exit 3
  [ -f "$CONFIG" ] || exit 0
  mkdir -p "$UPDATE_DIR" "$LOGDIR" || exit 1
  acquire_lock || exit 0
  trap release_lock EXIT
  load_config
  load_state || FIRST_RUN=1
  cleanup_leftovers
  [ -f "$REQUEST" ] && USER_REQUEST=1

  if [ "$AUTO_UPDATE" != "true" ]; then
    if [ "$S_STATE" != "disabled" ]; then
      S_STATE=disabled
      save_state
      log "state=disabled"
    fi
    rm -f "$REQUEST"
    exit 0
  fi
  if ! origin_allowed; then
    log "origin is not an https:// URL; not checking"
    fail_retry network_failed
    exit 0
  fi
  configure_git

  case "$S_STATE" in
    checking|downloading|building|applying)
      log "previous pass stopped in state=$S_STATE"
      S_STATE=failed
      S_ERROR=interrupted
      remove_tree "$STAGED"
      save_state
      ;;
  esac

  if [ "$S_STATE" = "staged" ]; then
    if [ -f "$STAGED/manifest.json" ]; then
      maybe_apply
      [ "$?" -eq 2 ] || exit 0
    else
      S_STATE=idle
      save_state
    fi
  fi

  if [ "$FIRST_RUN" = "1" ] && [ "$USER_REQUEST" != "1" ]; then
    S_STATE=idle
    S_NEXT=$(( $(now_ms) + FIRST_CHECK_DELAY_MS ))
    save_state
    log "first pass; first release check in $(( FIRST_CHECK_DELAY_MS / 1000 ))s"
    exit 0
  fi
  if [ "$USER_REQUEST" != "1" ] && [ -n "$S_NEXT" ] && [ "$(now_ms)" -lt "$S_NEXT" ]; then
    exit 0
  fi
  run_check
}

main "$@"
