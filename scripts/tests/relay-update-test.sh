#!/bin/bash
# Offline tests for scripts/relay-update.sh, install-launchd.sh, and uninstall-launchd.sh.
#
# Everything runs in one new mktemp directory: per-case relay homes and LaunchAgents
# directories, and local bare repositories that stand in for GitHub. launchctl,
# codesign, and the Swift build are stubs; GIT_ALLOW_PROTOCOL=file keeps git off the
# network; the scripts' test mode refuses to run against the real ~/.cmuxremote or
# launchctl. Only the temporary directory this script created is removed.
#
# Usage: bash scripts/tests/relay-update-test.sh   (KEEP_WORK=1 keeps the directory)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
REAL_GIT="$(command -v git || true)"
[ -n "$REAL_GIT" ] || { echo "relay-update-test: git is required" >&2; exit 1; }
ACCOUNT_HOME="$(eval "printf '%s' ~$(id -un)")"
GUI="gui/$(id -u)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/relay-update-test.XXXXXX")" || exit 1
WORK="$(cd "$WORK" && pwd -P)"
export WORK

cleanup() {
  if [ "${KEEP_WORK:-0}" = "1" ]; then
    echo "kept $WORK"
    return
  fi
  case "$(basename "$WORK")" in relay-update-test.??????) rm -rf "$WORK" ;; esac
}
trap cleanup EXIT

unset CMUX_SOCKET_PATH CMUX_RELAY_CODESIGN_IDENTITY CMUX_RELAY_UPDATE_NOW_MS CMUX_RELAY_UPDATE_ORIGIN \
  CMUX_RELAY_CONFIG CMUX_RELAY_LOGDIR
export GIT_ALLOW_PROTOCOL=file GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME=relay-test GIT_AUTHOR_EMAIL=relay-test@example.invalid
export GIT_COMMITTER_NAME=relay-test GIT_COMMITTER_EMAIL=relay-test@example.invalid
export REAL_GIT

STUBS="$WORK/stubs"
mkdir -p "$STUBS"

cat > "$STUBS/launchctl" <<'STUB'
#!/bin/bash
printf 'launchctl %s\n' "$*" >> "$CALLS"
case "$1" in
  kickstart|bootstrap)
    last="${@: -1}"
    case "$last" in
      */com.genie.cmuxremote|*/com.genie.cmuxremote.plist)
        printf '%s\n' "$(/usr/bin/plutil -extract state raw -o - "$CMUX_REMOTE_HOME/update/state.json" 2>/dev/null || echo none)" \
          >> "$RESTART_STATES"
        version="$("$CMUX_REMOTE_HOME/bin/cmux-relay" --version 2>/dev/null)"
        pid="$FAKE_RELAY_PID"
        if [ "${FAKE_RELAY_CRASH:-0}" = "1" ]; then pid="$DEAD_PID"; fi
        mkdir -p "$CMUX_REMOTE_HOME/update"
        printf '{"schema_version":1,"pid":%s,"version":"%s","started_at_ms":1,"active_sessions":0,"zero_since_ms":1}\n' \
          "$pid" "$version" > "$CMUX_REMOTE_HOME/update/relay-runtime.json"
        ;;
    esac
    ;;
esac
exit 0
STUB

cat > "$STUBS/codesign" <<'STUB'
#!/bin/bash
printf 'codesign %s\n' "$*" >> "$CALLS"
if [ "${FAKE_SIGN_FAIL:-0}" = "1" ] && [ "$1" = "--force" ]; then exit 1; fi
exit 0
STUB

cat > "$STUBS/fake-build" <<'STUB'
#!/bin/bash
case "$PWD" in "$WORK"/*) ;; *) echo "fake-build: refusing to build outside $WORK" >&2; exit 1 ;; esac
printf 'build %s\n' "$PWD" >> "$BUILDS"
echo "Compiling cmux-relay in $PWD for $HOME"
if [ "${FAKE_BUILD_FAIL:-0}" = "1" ]; then echo "error: fake build failure" >&2; exit 1; fi
version="$(sed -n 's/.*marketing = "\(.*\)".*/\1/p' Sources/SharedKit/CmuxRemoteVersion.swift)"
mkdir -p .build/release
printf '#!/bin/bash\nif [ "${1:-}" = "--version" ]; then echo %s; fi\nexit 0\n' "$version" > .build/release/cmux-relay
chmod 755 .build/release/cmux-relay
STUB

cat > "$STUBS/git-count" <<'STUB'
#!/bin/bash
printf 'git %s\n' "$*" >> "$GITCALLS"
exec "$REAL_GIT" "$@"
STUB
chmod 755 "$STUBS"/*

export PATH="$STUBS:$PATH"
export CMUX_RELAY_UPDATE_TEST=1
export CMUX_RELAY_LAUNCHCTL="$STUBS/launchctl" CMUX_RELAY_CODESIGN="$STUBS/codesign" CMUX_RELAY_GIT="$STUBS/git-count"
export CMUX_RELAY_BUILD_CMD="$STUBS/fake-build" CMUX_RELAY_UPDATE_BUILD_CMD="$STUBS/fake-build"
export CMUX_RELAY_UPDATE_HEALTH_TIMEOUT=0 CMUX_RELAY_UPDATE_STABLE_SECONDS=0
export CMUX_RELAY_UPDATE_TOOLCHAIN_ID=test-toolchain
export FAKE_RELAY_PID="$PPID"
( exit 0 ) &
DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null
export DEAD_PID
OLD_RELAY_PID=$$

# Fixture origin: main has v2.0.0 (annotated) and v2.0.1 plus v2.1.0-rc1; v10.0.0 sits
# on a side branch that main does not contain. ORIGIN2 adds v2.0.2 with changed templates.
ORIGIN="$WORK/origin.git"
ORIGIN2="$WORK/origin2.git"
SEED="$WORK/seed"
git_seed() { "$REAL_GIT" -C "$SEED" "$@"; }
set_version() {
  printf 'public enum CmuxRemoteVersion { public static let marketing = "%s" }\n' "$1" \
    > "$SEED/Sources/SharedKit/CmuxRemoteVersion.swift"
}
commit_seed() { git_seed add -A && git_seed commit -q -m "$1"; }

"$REAL_GIT" init -q --bare -b main "$ORIGIN"
"$REAL_GIT" -C "$ORIGIN" config uploadpack.allowFilter true
"$REAL_GIT" init -q -b main "$SEED"
mkdir -p "$SEED/scripts" "$SEED/Sources/SharedKit"
printf '.build/\n' > "$SEED/.gitignore"
for f in install-launchd.sh relay-update.sh relay.plist.tmpl relay-updater.plist.tmpl; do
  cp "$REPO_ROOT/scripts/$f" "$SEED/scripts/$f"
done
set_version 2.0.0; commit_seed "2.0.0"; git_seed tag -a v2.0.0 -m v2.0.0
set_version 2.0.1; commit_seed "2.0.1"; git_seed tag v2.0.1; git_seed tag v2.1.0-rc1
git_seed checkout -q -b side
set_version 10.0.0; commit_seed "side"; git_seed tag v10.0.0
git_seed checkout -q main
git_seed push -q "$ORIGIN" main side --tags
"$REAL_GIT" clone -q --bare "$ORIGIN" "$ORIGIN2"
"$REAL_GIT" -C "$ORIGIN2" config uploadpack.allowFilter true
set_version 2.0.2
perl -0pi -e 's|    <key>PATH</key>|    <key>CMUX_TEST_NEW_KEY</key>\n    <string>1</string>\n    <key>PATH</key>|' "$SEED/scripts/relay.plist.tmpl"
perl -0pi -e 's|<integer>5</integer>|<integer>6</integer>|' "$SEED/scripts/relay-updater.plist.tmpl"
commit_seed "2.0.2"; git_seed tag v2.0.2
git_seed push -q "$ORIGIN2" main v2.0.2

T0=1794218400000
T1=$(( T0 + 600001 ))
HOUR=3600000

TOTAL=0
PASSED=0
FAILED_NAMES=""
CASE=""
CASE_DIR=""
CASE_FAILS=0
CASE_ORIGIN=""

begin() {
  CASE="$1"
  CASE_DIR="$WORK/cases/$1"
  CASE_FAILS=0
  CASE_ORIGIN="$ORIGIN"
  CASE_ORIGIN_URL=""
  mkdir -p "$CASE_DIR/home/.cmuxremote" "$CASE_DIR/agents"
  export HOME="$CASE_DIR/home"
  export CMUX_REMOTE_HOME="$HOME/.cmuxremote"
  export CMUX_LAUNCH_AGENTS_DIR="$CASE_DIR/agents"
  export CALLS="$CASE_DIR/calls.log" BUILDS="$CASE_DIR/builds.log" GITCALLS="$CASE_DIR/git.log"
  export RESTART_STATES="$CASE_DIR/restart-states.log"
  : > "$CALLS"; : > "$BUILDS"; : > "$GITCALLS"; : > "$RESTART_STATES"
  unset FAKE_BUILD_FAIL FAKE_SIGN_FAIL FAKE_RELAY_CRASH
}

check() {
  local what="$1"
  shift
  if ! "$@"; then
    CASE_FAILS=$(( CASE_FAILS + 1 ))
    echo "  [$CASE] failed: $what"
  fi
}

finish() {
  TOTAL=$(( TOTAL + 1 ))
  if [ "$CASE_FAILS" -eq 0 ]; then
    PASSED=$(( PASSED + 1 ))
    echo "PASS $CASE"
  else
    FAILED_NAMES="$FAILED_NAMES $CASE"
    echo "FAIL $CASE"
    if [ -f "$CMUX_REMOTE_HOME/log/update.log" ]; then
      tail -n 20 "$CMUX_REMOTE_HOME/log/update.log" | sed 's/^/    update.log: /'
    fi
  fi
}

is() { [ "$1" = "$2" ]; }
has() { grep -qF -- "$2" "$1" 2>/dev/null; }
lacks() { ! grep -qF -- "$2" "$1" 2>/dev/null; }
exists() { [ -e "$1" ]; }
missing() { [ ! -e "$1" ]; }
count_lines() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }
count_matches() { grep -cF -- "$2" "$1" 2>/dev/null || true; }
# Builds the updater ran in its managed clone (install-launchd.sh builds in the seed checkout).
clone_builds() { count_matches "$BUILDS" "/.cmuxremote/src/cmux-remote"; }
state() { /usr/bin/plutil -extract "$1" raw -o - "$CMUX_REMOTE_HOME/update/state.json" 2>/dev/null; }
config() { /usr/bin/plutil -extract "$1" raw -o - "$CMUX_REMOTE_HOME/update/config.json" 2>/dev/null; }
installed() { "$CMUX_REMOTE_HOME/bin/cmux-relay" --version 2>/dev/null; }
digest() { /usr/bin/shasum -a 256 "$1" | cut -d ' ' -f 1; }

install_relay() {
  local version="$1"
  shift
  "$REAL_GIT" -C "$SEED" checkout -q "v$version" || return 1
  CMUX_RELAY_UPDATE_ORIGIN="${CASE_ORIGIN_URL:-file://$CASE_ORIGIN}" /bin/bash "$SEED/scripts/install-launchd.sh" "$@" \
    > "$CASE_DIR/install.out" 2>&1
}

tick() {
  CMUX_RELAY_UPDATE_NOW_MS="$1" /bin/bash "$CMUX_REMOTE_HOME/libexec/relay-update.sh" tick \
    >> "$CASE_DIR/tick.out" 2>&1
}

runtime() {
  local zero=""
  [ -z "${3:-}" ] || zero=",\"zero_since_ms\":$3"
  printf '{"schema_version":1,"pid":%s,"version":"%s","started_at_ms":1,"active_sessions":%s%s}\n' \
    "$1" "$(installed)" "$2" "$zero" > "$CMUX_REMOTE_HOME/update/relay-runtime.json"
}

request_update() {
  printf '{"schema_version":1,"source":"user","requested_at_ms":%s}\n' "$1" > "$CMUX_REMOTE_HOME/update/request.json"
}

logs_are_clean() {
  local f
  for f in "$CMUX_REMOTE_HOME/log/update.log" "$CMUX_REMOTE_HOME/update/last-build.log" \
           "$CMUX_REMOTE_HOME/update/last-git.log" "$CMUX_REMOTE_HOME/update/state.json"; do
    [ -f "$f" ] || continue
    if grep -qF -- "$HOME" "$f" || grep -qF -- "$ACCOUNT_HOME" "$f" || grep -qF -- "Test Identity" "$f"; then
      return 1
    fi
  done
  return 0
}

move_tag() {
  local mover="$CASE_DIR/mover"
  "$REAL_GIT" clone -q "$CASE_ORIGIN" "$mover"
  "$REAL_GIT" -C "$mover" checkout -q main
  printf 'moved\n' > "$mover/MOVED"
  "$REAL_GIT" -C "$mover" add -A
  "$REAL_GIT" -C "$mover" commit -q -m "move $1"
  "$REAL_GIT" -C "$mover" tag -f "$1" >/dev/null
  "$REAL_GIT" -C "$mover" push -q --force origin main "refs/tags/$1"
}

begin fresh_install_enables_updater
install_relay 2.0.0
check "install exit 0" is "$?" 0
check "relay 2.0.0 installed" is "$(installed)" 2.0.0
check "config auto_update true" is "$(config auto_update)" true
check "config origin recorded" is "$(config origin)" "file://$ORIGIN"
check "config schema_version" is "$(config schema_version)" 1
check "updater script installed" cmp -s "$CMUX_REMOTE_HOME/libexec/relay-update.sh" "$REPO_ROOT/scripts/relay-update.sh"
check "updater plist valid" /usr/bin/plutil -lint -s "$CMUX_LAUNCH_AGENTS_DIR/com.genie.cmuxremote.updater.plist"
check "relay plist has CMUX_REMOTE_HOME" has "$CMUX_LAUNCH_AGENTS_DIR/com.genie.cmuxremote.plist" "<string>$CMUX_REMOTE_HOME</string>"
check "updater stopped first" has "$CALLS" "launchctl bootout $GUI/com.genie.cmuxremote.updater"
check "relay bootstrapped" has "$CALLS" "launchctl bootstrap $GUI $CMUX_LAUNCH_AGENTS_DIR/com.genie.cmuxremote.plist"
check "relay kickstarted" has "$CALLS" "launchctl kickstart -k $GUI/com.genie.cmuxremote"
check "updater bootstrapped" has "$CALLS" "launchctl bootstrap $GUI $CMUX_LAUNCH_AGENTS_DIR/com.genie.cmuxremote.updater.plist"
check "updater never kickstarted" lacks "$CALLS" "kickstart $GUI/com.genie.cmuxremote.updater"
finish

begin no_auto_update_installs_no_updater
install_relay 2.0.0 --no-auto-update
check "install exit 0" is "$?" 0
check "config auto_update false" is "$(config auto_update)" false
check "no updater plist" missing "$CMUX_LAUNCH_AGENTS_DIR/com.genie.cmuxremote.updater.plist"
check "no updater script" missing "$CMUX_REMOTE_HOME/libexec/relay-update.sh"
check "updater booted out" has "$CALLS" "launchctl bootout $GUI/com.genie.cmuxremote.updater"
check "updater not bootstrapped" lacks "$CALLS" "com.genie.cmuxremote.updater.plist"
/bin/bash "$REPO_ROOT/scripts/relay-update.sh" tick > "$CASE_DIR/tick.out" 2>&1
check "disabled tick exit 0" is "$?" 0
check "state disabled" is "$(state state)" disabled
check "no git while disabled" is "$(count_lines "$GITCALLS")" 0
install_relay 2.0.0
check "opt-out remembered" is "$(config auto_update)" false
install_relay 2.0.0 --auto-update
check "--auto-update turns it back on" is "$(config auto_update)" true
check "updater plist back" exists "$CMUX_LAUNCH_AGENTS_DIR/com.genie.cmuxremote.updater.plist"
finish

begin first_pass_waits_ten_minutes
install_relay 2.0.0
tick "$T0"
check "state idle" is "$(state state)" idle
check "first check scheduled" is "$(state next_check_at_ms)" "$(( T0 + 600000 ))"
tick "$(( T0 + 599999 ))"
check "no git before the first check" is "$(count_lines "$GITCALLS")" 0
check "no managed clone yet" missing "$CMUX_REMOTE_HOME/src/cmux-remote"
finish

begin up_to_date_stays_idle_without_clone
# Without the off-main v10.0.0: a newer tag of any kind needs the clone to check it.
cp -R "$ORIGIN" "$CASE_DIR/origin.git"
CASE_ORIGIN="$CASE_DIR/origin.git"
"$REAL_GIT" -C "$CASE_ORIGIN" tag -d v10.0.0 >/dev/null
install_relay 2.0.1
tick "$T0"
tick "$T1"
check "state idle" is "$(state state)" idle
check "latest is installed" is "$(state latest_version)" 2.0.1
check "last check recorded" is "$(state last_checked_at_ms)" "$T1"
check "ls-remote used" has "$GITCALLS" "ls-remote --tags file://$CASE_ORIGIN"
check "no clone when nothing is newer" missing "$CMUX_REMOTE_HOME/src/cmux-remote"
check "next check in an hour" is "$(state next_check_at_ms)" "$(( T1 + HOUR ))"
finish

begin new_tag_staged_while_connected_then_applied_after_idle
install_relay 2.0.0
before="$(digest "$CMUX_REMOTE_HOME/bin/cmux-relay")"
tick "$T0"
runtime "$OLD_RELAY_PID" 1
: > "$CALLS"
tick "$T1"
check "state staged" is "$(state state)" staged
check "staged v2.0.1" is "$(state latest_tag)" v2.0.1
check "built once" is "$(clone_builds)" 1
check "rc tag ignored" lacks "$CMUX_REMOTE_HOME/log/update.log" "v2.1.0-rc1"
check "off-main tag rejected" has "$CMUX_REMOTE_HOME/log/update.log" "rejected tag=v10.0.0"
check "off-main tag remembered" has "$CMUX_REMOTE_HOME/update/failed-tags" "v10.0.0"
check "relay untouched while a phone is connected" is "$(digest "$CMUX_REMOTE_HOME/bin/cmux-relay")" "$before"
check "no launchctl while connected" is "$(count_lines "$CALLS")" 0
check "managed clone origin" is "$("$REAL_GIT" -C "$CMUX_REMOTE_HOME/src/cmux-remote" remote get-url origin)" "file://$ORIGIN"
check "clone checked out at v2.0.1" is "$("$REAL_GIT" -C "$CMUX_REMOTE_HOME/src/cmux-remote" rev-parse HEAD)" "$("$REAL_GIT" -C "$SEED" rev-parse 'v2.0.1^{commit}')"
staged_digest="$(/usr/bin/plutil -extract binary_sha256 raw -o - "$CMUX_REMOTE_HOME/update/staged/manifest.json")"
runtime "$OLD_RELAY_PID" 0 "$(( T1 + 1000 ))"
tick "$(( T1 + 61000 ))"
check "still staged 60s after the last phone left" is "$(state state)" staged
check "no restart before 120s" is "$(count_lines "$CALLS")" 0
tick "$(( T1 + 1000 + 120000 ))"
check "applied" is "$(state state)" idle
check "current version" is "$(state current_version)" 2.0.1
check "relay 2.0.1 installed" is "$(installed)" 2.0.1
check "installed the staged binary" is "$(digest "$CMUX_REMOTE_HOME/bin/cmux-relay")" "$staged_digest"
check "relay restarted with kickstart -k" has "$CALLS" "launchctl kickstart -k $GUI/com.genie.cmuxremote"
check "state was applying when the relay restarted" grep -qx applying "$RESTART_STATES"
check "updater job untouched" lacks "$CALLS" "com.genie.cmuxremote.updater"
check "rollback copy kept" is "$(digest "$CMUX_REMOTE_HOME/update/rollback/cmux-relay")" "$before"
check "staged removed" missing "$CMUX_REMOTE_HOME/update/staged"
check "adhoc signing recorded" is "$(state signing)" adhoc
check "adhoc warning logged" has "$CMUX_REMOTE_HOME/log/update.log" "warning=adhoc_signature"
check "build output kept" has "$CMUX_REMOTE_HOME/update/last-build.log" "Compiling cmux-relay in ~/.cmuxremote/src/cmux-remote"
check "logs carry no home path or identity" logs_are_clean
finish

begin user_request_applies_while_connected
install_relay 2.0.0
tick "$T0"
runtime "$OLD_RELAY_PID" 1
request_update "$(( T0 + 5 ))"
tick "$(( T0 + 10 ))"
check "applied" is "$(state state)" idle
check "relay 2.0.1 installed" is "$(installed)" 2.0.1
check "request consumed" missing "$CMUX_REMOTE_HOME/update/request.json"
check "relay restarted" has "$CALLS" "launchctl kickstart -k $GUI/com.genie.cmuxremote"
check "state was applying when the relay restarted" grep -qx applying "$RESTART_STATES"
check "logs carry no home path" logs_are_clean
finish

begin build_failure_is_not_retried_automatically
install_relay 2.0.0
before="$(digest "$CMUX_REMOTE_HOME/bin/cmux-relay")"
tick "$T0"
runtime "$OLD_RELAY_PID" 0 1
FAKE_BUILD_FAIL=1 tick "$T1"
check "state failed" is "$(state state)" failed
check "build_failed" is "$(state last_error_code)" build_failed
check "tag remembered" has "$CMUX_REMOTE_HOME/update/failed-tags" "build_failed test-toolchain"
check "relay untouched" is "$(digest "$CMUX_REMOTE_HOME/bin/cmux-relay")" "$before"
tick "$(( T1 + HOUR + 1 ))"
check "no automatic rebuild of the failed tag" is "$(clone_builds)" 1
check "idle after skipping" is "$(state state)" idle
"$REAL_GIT" -C "$CMUX_REMOTE_HOME/src/cmux-remote" remote set-url origin "file:///nonexistent/elsewhere.git"
request_update "$(( T1 + HOUR + 2 ))"
tick "$(( T1 + HOUR + 3 ))"
check "user request retries the tag" is "$(clone_builds)" 2
check "origin restored from config" is "$("$REAL_GIT" -C "$CMUX_REMOTE_HOME/src/cmux-remote" remote get-url origin)" "file://$ORIGIN"
check "relay 2.0.1 installed" is "$(installed)" 2.0.1
finish

begin moved_tag_is_rejected
cp -R "$ORIGIN" "$CASE_DIR/origin.git"
CASE_ORIGIN="$CASE_DIR/origin.git"
install_relay 2.0.0
tick "$T0"
runtime "$OLD_RELAY_PID" 0 1
FAKE_BUILD_FAIL=1 tick "$T1"
check "first attempt built once" is "$(clone_builds)" 1
move_tag v2.0.1
request_update "$(( T1 + 10 ))"
tick "$(( T1 + 20 ))"
check "moved tag not built" is "$(clone_builds)" 1
check "moved tag logged" has "$CMUX_REMOTE_HOME/log/update.log" "reason=tag_moved"
check "moved tag remembered" has "$CMUX_REMOTE_HOME/update/failed-tags" "tag_verification_failed"
check "relay still 2.0.0" is "$(installed)" 2.0.0
finish

begin start_failure_rolls_back
install_relay 2.0.0
before="$(digest "$CMUX_REMOTE_HOME/bin/cmux-relay")"
tick "$T0"
runtime "$OLD_RELAY_PID" 0 1
: > "$CALLS"
FAKE_RELAY_CRASH=1 tick "$T1"
check "state failed" is "$(state state)" failed
check "start_failed" is "$(state last_error_code)" start_failed
check "previous relay restored" is "$(digest "$CMUX_REMOTE_HOME/bin/cmux-relay")" "$before"
check "rollback logged" has "$CMUX_REMOTE_HOME/log/update.log" "rollback tag=v2.0.1 reason=start_failed"
check "restart and rollback restart" is "$(count_matches "$CALLS" "kickstart -k $GUI/com.genie.cmuxremote")" 2
check "tag remembered" has "$CMUX_REMOTE_HOME/update/failed-tags" "start_failed"
tick "$(( T1 + HOUR + 1 ))"
check "no automatic retry" is "$(clone_builds)" 1
finish

begin sign_failure_backs_off_without_adhoc_fallback
install_relay 2.0.0
printf 'Test Identity (TEAM123)\n' > "$CMUX_REMOTE_HOME/codesign-identity"
before="$(digest "$CMUX_REMOTE_HOME/bin/cmux-relay")"
tick "$T0"
FAKE_SIGN_FAIL=1 tick "$T1"
check "state failed" is "$(state state)" failed
check "sign_failed" is "$(state last_error_code)" sign_failed
check "one failure" is "$(state consecutive_failures)" 1
check "retry in one hour" is "$(state next_check_at_ms)" "$(( T1 + HOUR ))"
check "nothing staged" missing "$CMUX_REMOTE_HOME/update/staged"
check "relay untouched" is "$(digest "$CMUX_REMOTE_HOME/bin/cmux-relay")" "$before"
FAKE_SIGN_FAIL=1 tick "$(( T1 + HOUR ))"
check "two failures" is "$(state consecutive_failures)" 2
check "retry in two hours" is "$(state next_check_at_ms)" "$(( T1 + HOUR + 2 * HOUR ))"
check "signed with the remembered identity" has "$CALLS" "--identifier com.genie.cmuxremote.relay --sign Test Identity (TEAM123)"
check "identity not in logs" logs_are_clean
finish

begin changed_templates_reload_relay_but_not_updater
CASE_ORIGIN="$ORIGIN2"
install_relay 2.0.1 --socket /tmp/cmux-pinned.sock
tick "$T0"
runtime "$OLD_RELAY_PID" 0 1
: > "$CALLS"
tick "$T1"
check "applied v2.0.2" is "$(installed)" 2.0.2
check "new plist key present" has "$CMUX_LAUNCH_AGENTS_DIR/com.genie.cmuxremote.plist" "CMUX_TEST_NEW_KEY"
check "pinned socket kept" has "$CMUX_LAUNCH_AGENTS_DIR/com.genie.cmuxremote.plist" "<string>/tmp/cmux-pinned.sock</string>"
check "relay booted out" has "$CALLS" "launchctl bootout $GUI $CMUX_LAUNCH_AGENTS_DIR/com.genie.cmuxremote.plist"
check "relay bootstrapped" has "$CALLS" "launchctl bootstrap $GUI $CMUX_LAUNCH_AGENTS_DIR/com.genie.cmuxremote.plist"
check "no kickstart when the plist changed" lacks "$CALLS" "kickstart -k"
check "updater job untouched" lacks "$CALLS" "com.genie.cmuxremote.updater"
check "updater plist file updated" has "$CMUX_LAUNCH_AGENTS_DIR/com.genie.cmuxremote.updater.plist" "<integer>6</integer>"
check "updater plist change logged" has "$CMUX_REMOTE_HOME/log/update.log" "updater plist changed"
finish

begin https_origin_is_refused_offline
CASE_ORIGIN_URL="https://example.invalid/cmux-remote.git"
install_relay 2.0.0
check "install exit 0" is "$?" 0
check "config origin recorded" is "$(config origin)" "$CASE_ORIGIN_URL"
tick "$T0"
request_update "$(( T0 + 1 ))"
tick "$(( T0 + 2 ))"
check "network_failed" is "$(state last_error_code)" network_failed
check "git refused https" has "$CMUX_REMOTE_HOME/update/last-git.log" "transport 'https' not allowed"
finish

begin uninstall_removes_updater_and_cache
install_relay 2.0.0
tick "$T0"
request_update "$(( T0 + 1 ))"
tick "$(( T0 + 2 ))"
check "clone exists before uninstall" exists "$CMUX_REMOTE_HOME/src/cmux-remote"
: > "$CALLS"
/bin/bash "$REPO_ROOT/scripts/uninstall-launchd.sh" > "$CASE_DIR/uninstall.out" 2>&1
check "uninstall exit 0" is "$?" 0
check "updater booted out" has "$CALLS" "launchctl bootout $GUI/com.genie.cmuxremote.updater"
check "relay booted out" has "$CALLS" "launchctl bootout $GUI $CMUX_LAUNCH_AGENTS_DIR/com.genie.cmuxremote.plist"
check "updater plist removed" missing "$CMUX_LAUNCH_AGENTS_DIR/com.genie.cmuxremote.updater.plist"
check "relay plist removed" missing "$CMUX_LAUNCH_AGENTS_DIR/com.genie.cmuxremote.plist"
check "updater script removed" missing "$CMUX_REMOTE_HOME/libexec"
check "update state removed" missing "$CMUX_REMOTE_HOME/update"
check "managed clone removed" missing "$CMUX_REMOTE_HOME/src"
check "relay config kept" exists "$CMUX_REMOTE_HOME/relay.json"
check "relay binary kept" exists "$CMUX_REMOTE_HOME/bin/cmux-relay"
finish

begin uninstall_keep_update_cache
install_relay 2.0.0
tick "$T0"
request_update "$(( T0 + 1 ))"
tick "$(( T0 + 2 ))"
/bin/bash "$REPO_ROOT/scripts/uninstall-launchd.sh" --keep-update-cache > "$CASE_DIR/uninstall.out" 2>&1
check "uninstall exit 0" is "$?" 0
check "managed clone kept" exists "$CMUX_REMOTE_HOME/src/cmux-remote/.git"
check "update state removed" missing "$CMUX_REMOTE_HOME/update"
check "updater plist removed" missing "$CMUX_LAUNCH_AGENTS_DIR/com.genie.cmuxremote.updater.plist"
finish

begin test_mode_guards_refuse_real_targets
CMUX_REMOTE_HOME=/nonexistent-cmux-relay-test/.cmuxremote /bin/bash "$REPO_ROOT/scripts/relay-update.sh" tick \
  > "$CASE_DIR/guard-home.out" 2>&1
check "updater: home outside TMPDIR exits 3" is "$?" 3
check "updater: nothing created outside TMPDIR" missing /nonexistent-cmux-relay-test
CMUX_RELAY_LAUNCHCTL=/bin/launchctl /bin/bash "$REPO_ROOT/scripts/relay-update.sh" tick > "$CASE_DIR/guard-launchctl.out" 2>&1
check "updater: real launchctl exits 3" is "$?" 3
PATH="/usr/bin:/bin:/usr/sbin:/sbin" /bin/bash "$REPO_ROOT/scripts/relay-update.sh" tick > "$CASE_DIR/guard-path.out" 2>&1
check "updater: launchctl on PATH exits 3" is "$?" 3
CMUX_RELAY_LAUNCHCTL=/bin/launchctl /bin/bash "$REPO_ROOT/scripts/install-launchd.sh" --dry-run > "$CASE_DIR/guard-install.out" 2>&1
check "installer: real launchctl exits 3" is "$?" 3
PATH="/usr/bin:/bin:/usr/sbin:/sbin" /bin/bash "$REPO_ROOT/scripts/install-launchd.sh" --dry-run > "$CASE_DIR/guard-install-path.out" 2>&1
check "installer: launchctl on PATH exits 3" is "$?" 3
CMUX_REMOTE_HOME=/nonexistent-cmux-relay-test/.cmuxremote /bin/bash "$REPO_ROOT/scripts/uninstall-launchd.sh" --dry-run \
  > "$CASE_DIR/guard-uninstall.out" 2>&1
check "uninstaller: home outside TMPDIR exits 3" is "$?" 3
check "no stub calls from refused runs" is "$(count_lines "$CALLS")" 0
check "relay home untouched" missing "$CMUX_REMOTE_HOME/update"
finish

if [ "$PASSED" -eq "$TOTAL" ]; then
  echo "relay-update-test: PASS $PASSED/$TOTAL"
  exit 0
fi
echo "relay-update-test: FAIL $(( TOTAL - PASSED ))/$TOTAL:$FAILED_NAMES"
exit 1
