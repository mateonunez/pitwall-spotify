#!/bin/sh
# Test the actual dashboard with a synthetic player and a throwaway tmux server.
set -eu
SPOTIFY=$(cd "$(dirname "$0")/.." && pwd)
PITWALL_ROOT=$(cd "${1:-$SPOTIFY/../pitwall}" && pwd)
FIXTURE=$(mktemp -d)
SOCKET=pitwall-spotify-board-$$
PORT=$((30000 + $$ % 22000))
export XDG_CACHE_HOME="$FIXTURE/cache" XDG_CONFIG_HOME="$FIXTURE/config"
export XDG_STATE_HOME="$FIXTURE/state" XDG_DATA_HOME="$FIXTURE/data"
export PITWALL_SPOTIFY_API="http://127.0.0.1:$PORT/v1" PITWALL_SPOTIFY_ACCOUNTS="http://127.0.0.1:$PORT"
mkdir -p "$XDG_CONFIG_HOME/pitwall"
printf '%s\n' '{"access_token":"fresh","refresh_token":"test","expires_at":2000000000,"scope":"playlist-read-private"}' >"$XDG_CONFIG_HOME/pitwall/spotify"
python3 "$SPOTIFY/test/fake_api.py" "$PORT" "$FIXTURE/log" &
api=$!
tm() { tmux -L "$SOCKET" "$@"; }
trap 'tm kill-server 2>/dev/null || :; kill "$api" 2>/dev/null || :; rm -rf "$FIXTURE"' EXIT
tm -f /dev/null new-session -d -s t -x 134 -y 36
TMUX="$(tm display -p '#{socket_path}'),0,0"
export TMUX
"$PITWALL_ROOT/bin/pitwall" plugin add "$SPOTIFY" >/dev/null
tm run-shell "'$PITWALL_ROOT/pitwall.tmux'"

keys() { tm send-keys -t t:ui "$@"; }
screen() { tm capture-pane -t t:ui -p; }
expect() {
    attempt=0
    until screen | grep -Eq -- "$1"; do
        attempt=$((attempt + 1))
        [ "$attempt" -lt "${2:-50}" ] || { echo "Missing $1"; screen | head -18; return 1; }
        sleep .1
    done
    echo "visible: $1"
}
open() {
    tm new-window -d -t '=t:' -n ui "TERM=xterm-256color ${PITWALL_TEST_BASH:-bash} '$PITWALL_ROOT/bin/pitwall-dash'"
    tm resize-window -t t:ui -x 134 -y 36
    expect 'pitwall'
}
close() {
    keys C-c
    while tm list-windows -t t -F '#W' | grep -qx ui; do sleep .05; done
}

open
keys Tab
expect 'NOW PLAYING'
expect '│.*0:5[1-9] / 3:20'
expect '▌.*0:5[1-9] / 3:20.*│'
player_reads=$(grep -c '^GET /v1/me/player$' "$FIXTURE/log")
sleep 2
expect '│.*0:5[3-9] / 3:20'
[ "$(grep -c '^GET /v1/me/player$' "$FIXTURE/log")" = "$player_reads" ]
keys -l 'night drive'
expect '▌.*Night Drive'
keys Enter
expect 'PLAYLIST TRACKS'
keys -l 'last song'
expect '▌.*Last Song'
close
touch "$FIXTURE/log.slow-player"
open
expect '❯ last song▏'
expect '▌.*Last Song'
expect '│.*Last seen · refreshing'
expect '│.*0:50 / 3:20'
sleep 1
expect '│.*0:50 / 3:20'
rm "$FIXTURE/log.slow-player"
expect '│.*0:5[1-9] / 3:20'
"$SPOTIFY/bin/spotify" act toggle now:spotify:track:t1 >/dev/null
expect '│.*⏸ PAUSED' 120
sleep 2
expect '│.*0:50 / 3:20'
keys Escape
expect 'PLAYLIST TRACKS · 2 TRACKS'
keys Escape
expect '❯ night drive▏'
expect '▌.*Night Drive'
close

printf '%s\n' '{"access_token":"fresh","refresh_token":"different","expires_at":2000000000,"scope":"playlist-read-private"}' >"$XDG_CONFIG_HOME/pitwall/spotify"
open
expect '│ ❯ ▏'
sleep 2
if screen | grep -q '❯ night drive'; then echo "The previous login's search was restored"; exit 1; fi
