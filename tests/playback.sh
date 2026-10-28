#!/usr/bin/env bash
# Check playback selection and launch arguments through the real CLI.
# Fake curl/Streamlink keep tests offline; temporary XDG directories protect settings.
set -Eeuo pipefail
trap 'echo "Failed at line ${LINENO}" >&2' ERR

repo="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "${test_dir}"' EXIT
export XDG_CONFIG_HOME="${test_dir}/config" XDG_CACHE_HOME="${test_dir}/cache"
export TERM=xterm LANG=en_US.UTF-8
export TEST_ARGS="${test_dir}/args" TEST_VIDEOS="${test_dir}/videos.json"
mkdir -p "${test_dir}/bin" "${XDG_CONFIG_HOME}/wtwitch"
export PATH="${test_dir}/bin:${PATH}"

cat > "${test_dir}/bin/curl" <<'EOF'
#!/usr/bin/env bash
case "${!#}" in
  */users\?*) printf '%s' '{"data":[{"id":"123","login":"example"}]}' ;;
  */videos\?*) cat "${TEST_VIDEOS}" ;;
  */streams\?*) printf '%s' "${TEST_STREAMS:-{\"data\":[{\"type\":\"live\"}]}}" ;;
  *) exit 1 ;;
esac
EOF
cat > "${test_dir}/bin/streamlink" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then echo 'streamlink test'; exit; fi
jq -n --args '$ARGS.positional' -- "$@" > "${TEST_ARGS}"
exit "${TEST_PLAYER_STATUS:-0}"
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "${test_dir}/bin/mpv"
cp "${test_dir}/bin/mpv" "${test_dir}/bin/vlc"
printf '#!/usr/bin/env bash\nexit 1\n' > "${test_dir}/bin/pgrep"
cp "${test_dir}/bin/pgrep" "${test_dir}/bin/notify-send"
chmod +x "${test_dir}/bin/"*
printf '%s' '{"apiToken":"test-token","apiTokenExpiry":9999999999}' > "${XDG_CONFIG_HOME}/wtwitch/api.json"
jq -n --arg title $'A "quoted" {title} / } \\ $HOME\nsecond line' \
  '{data:[{url:"https://www.twitch.tv/videos/123", title:$title},
    {url:"https://www.twitch.tv/videos/456", title:"Second VOD"}]}' > "${TEST_VIDEOS}"

settings() {
  jq -n --arg player "$1" --arg quality "$2" \
    '{player:$player, quality:$quality, colors:"false", printOfflineSubscriptions:"true", subscriptions:[]}' \
    > "${XDG_CONFIG_HOME}/wtwitch/config.json"
}
run_cli() {
  rm -f "${TEST_ARGS}"
  bash "${repo}/src/wtwitch" "$@" > "${test_dir}/output" 2>&1
}
has_arg() {
  jq -e --arg arg "$1" 'index($arg) != null' "${TEST_ARGS}" > /dev/null
}
no_arg() {
  ! has_arg "$1"
}
reject_vod() {
  if run_cli v example "$1"; then
    echo "Accepted invalid VOD number: $1" >&2
    exit 1
  fi
  [[ ! -f "${TEST_ARGS}" ]]
  grep -q 'No VOD number' "${test_dir}/output"
}

settings mpv audio_only
run_cli v example 1
has_arg --player-passthrough
has_arg hls
has_arg '--hwdec=auto --force-window=yes'
has_arg audio_only
has_arg $'A "quoted" {{title}} / }} \\ $HOME\nsecond line'

run_cli v example 2
has_arg https://www.twitch.tv/videos/456
has_arg 'Second VOD'

for number in 0 -1 abc 08 1+1 '' 3 999999999999999999999999999999; do
  reject_vod "${number}"
done

settings "${test_dir}/bin/mpv" audio_only
run_cli v example 1
has_arg --player-passthrough
has_arg '--hwdec=auto --force-window=yes'
run_cli w example
has_arg '--hwdec=auto --force-window=yes'
no_arg --player-passthrough
has_arg --twitch-disable-ads

# Neither an explicit VLC nor the VLC fallback should receive mpv-only options.
for player in vlc missing-player; do
  settings "${player}" audio_only
  run_cli v example 1
  has_arg vlc
  no_arg --player-passthrough
  no_arg -a
done

# Debug mode keeps video/fallback playback in the foreground for assertions.
export WTWITCH_DEBUG=on
settings mpv 480p30,best
run_cli v example 1
has_arg 480p30,best
has_arg --hwdec=auto
run_cli q 480p30,best
jq -e '.quality == "480p30,best"' "${XDG_CONFIG_HOME}/wtwitch/config.json" > /dev/null

settings mpv best,audio_only
run_cli v example 1
has_arg '--hwdec=auto --force-window=yes'
has_arg best,audio_only

export TEST_PLAYER_STATUS=1
if run_cli v example 1; then echo 'Ignored Streamlink failure' >&2; exit 1; fi
unset TEST_PLAYER_STATUS
export TEST_STREAMS='{"data":[]}'
if run_cli w example; then echo 'Tried offline stream' >&2; exit 1; fi
[[ ! -f "${TEST_ARGS}" ]]
grep -q 'offline' "${test_dir}/output"
unset TEST_STREAMS

printf '%s' '{"data":[]}' > "${TEST_VIDEOS}"
reject_vod 1

printf 'Passed playback selection, VOD input, titles, qualities, player fallback, and failure checks.\n'
