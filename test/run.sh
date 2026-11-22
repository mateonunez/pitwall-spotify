#!/bin/sh
# Self-check against a fake Spotify and a throwaway tmux server: the view, an action, the status line, the refresh.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
fail=0
eq() { if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1: expected '$3', got '$2'"; fail=1; fi; }

XDG_CONFIG_HOME=$(mktemp -d) LOG=$(mktemp)
PORT=$((20000 + $$ % 20000))
export XDG_CONFIG_HOME XDG_CACHE_HOME="$XDG_CONFIG_HOME/cache" PITWALL_SPOTIFY_API="http://127.0.0.1:$PORT/v1" PITWALL_SPOTIFY_ACCOUNTS="http://127.0.0.1:$PORT"
python3 "$ROOT/test/fake_api.py" "$PORT" "$LOG" & API=$!
L="pitwall-spotify-test-$$"
tmux -L "$L" -f /dev/null new-session -d -s t -x 100 -y 20
TMUX="$(tmux -L "$L" display -p '#{socket_path}'),0,0"
export TMUX
trap 'kill $API 2>/dev/null; wait $API 2>/dev/null; tmux -L "$L" kill-server 2>/dev/null; rm -rf "$XDG_CONFIG_HOME" "$LOG"' EXIT
sleep 0.5
SP="$ROOT/bin/spotify"

eq "not logged in, the view offers the login" "$("$SP" view | grep -c '^act	-	login	l	Log in')" 1
mkdir -p "$XDG_CONFIG_HOME/pitwall"
echo '{"client_id": "cid", "access_token": "old", "refresh_token": "r", "expires_at": 0}' >"$XDG_CONFIG_HOME/pitwall/spotify"
V=$("$SP" view)
eq "an expired token is refreshed before the first call" "$(head -1 "$LOG")" "POST /api/token"
eq "and kept, readable by you alone" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["access_token"])' "$XDG_CONFIG_HOME/pitwall/spotify") $(ls -l "$XDG_CONFIG_HOME/pitwall/spotify" | cut -c1-10)" "fresh -rw-------"
eq "the view: now playing, up next, recently played" "$(printf '%s\n' "$V" | grep '^head' | cut -f2 | tr '\n' '|')" "NOW PLAYING|UP NEXT|RECENTLY PLAYED|YOUR PLAYLISTS|"
eq "the track's row, with where it is" "$(printf '%s\n' "$V" | grep '^row	now:' | cut -f4,5)" "Song #1 with a title long enough to be cut short · The Band	{dim}0:50 / 3:20"
eq "its first action pauses" "$(printf '%s\n' "$V" | grep '^act	now:' | head -1 | cut -f3,4,5)" "toggle	⏎	Pause"
eq "the device and its volume on the right, a ▶ on the tab" "$(printf '%s\n' "$V" | grep '^right' | cut -f2) $(printf '%s\n' "$V" | grep '^badge' | cut -f2)" "MacBook · volume 60% {green}▶"
eq "the status line's piece: cut to 40, # doubled for tmux" "$(tmux show -gqv @pitwall_seg_spotify)" "Song ##1 with a title long enough to be…"
eq "an existing login still shows the player and offers the new permission" "$(printf '%s\n' "$V" | grep -c 'Connect playlists')" 1
python3 - "$XDG_CONFIG_HOME/pitwall/spotify" <<'PYTHON'
import json, sys
path = sys.argv[1]
with open(path) as f:
    conf = json.load(f)
conf["scope"] = "playlist-read-private playlist-read-collaborative"
with open(path, "w") as f:
    json.dump(conf, f)
PYTHON
export PITWALL_VIEW_CACHE="$XDG_CONFIG_HOME/catalogue"
V=$("$SP" view)
eq "both pages of playlists are searchable by name or owner" "$(printf '%s\n' "$V" | grep '^row	list:' | cut -f6 | tr '\n' '|')" "spotify playlist Night Drive DJ|spotify playlist Lazy Sunday|"
"$SP" view >/dev/null
eq "a player refresh reuses the popup catalogue" "$(grep -c 'GET /v1/me/playlists' "$LOG")" 2
eq "Enter browses a playlist by id" "$(printf '%s\n' "$V" | grep '^act	list:spotify:playlist:listA' | head -1 | cut -f7,8)" "page	listA"
P=$("$SP" view listA)
eq "all pages of playable items are listed, including repeated tracks" "$(printf '%s\n' "$P" | grep '^row' | cut -f2 | tr '\n' '|')" "pl0:spotify:track:t1|pl1:spotify:track:t1|"
eq "a followed playlist with restricted tracks opens in Spotify" "$("$SP" view listB | grep -c 'open	spotify:playlist:listB')" 1
eq "an empty playlist explains itself" "$("$SP" view empty | grep -c '^head	NO PLAYABLE TRACKS')" 1
tmux set -g @pitwall-spotify-format '{artist}'
"$SP" act toggle "now:spotify:track:t1" >"$LOG.act"
eq "⏎ pauses through the API, says so, and asks the view to look again" "$(grep -c 'PUT /v1/me/player/pause' "$LOG") $(tr '\n' '|' <"$LOG.act")" "1 notice	paused «Song #1 with a title long enough to be cut short»|refresh|"
eq "paused, the piece dims, in the format you set" "$(tmux show -gqv @pitwall_seg_spotify)" "#[fg=#6b7280]The Band"
"$SP" act play "r:spotify:track:r1" >/dev/null
eq "a recent track plays on ⏎" "$(grep -c 'PUT /v1/me/player/play' "$LOG")" 1
eq "pitwall spotify status says who and what" "$("$SP" cmd status)" "spotify: Tester (premium), playing «Song #1 with a title long enough to be cut short» by The Band on MacBook"
"$SP" act save "now:spotify:track:t1" >"$LOG.act"
eq "s saves to your Liked Songs, through the library" "$(grep -c 'PUT /v1/me/library' "$LOG") $(head -1 "$LOG.act")" "1 notice	saved to your Liked Songs"
tmux set -g @pitwall-spotify-segment off
"$SP" cmd next >/dev/null
eq "@pitwall-spotify-segment off keeps the status line clear" "$(tmux show -gqv @pitwall_seg_spotify)" ""
"$SP" act play "list:spotify:playlist:listA" >/dev/null
eq "play a playlist uses its Spotify context" "$(grep -c '^play {"context_uri": "spotify:playlist:listA"}' "$LOG")" 1
"$SP" act shuffle-on "now:spotify:track:t1" >/dev/null
eq "shuffle shows its new state and offers to switch it off" "$("$SP" view | grep -c 'shuffle-off	z	Turn shuffle off')" 1
for pair in 'context track' 'track off' 'off context'; do
    set -- $pair
    "$SP" act "repeat-$1" "now:spotify:track:t1" >/dev/null
    eq "repeat $1 offers $2 next" "$("$SP" view | grep -c "repeat-$2	r	Repeat $2")" 1
done
"$SP" cmd volume 0 >/dev/null
"$SP" act volup "now:spotify:track:t1" >/dev/null
eq "volume up from mute starts at ten" "$("$SP" view | grep -c '^right.*volume 10%')" 1
# Each view runs in a fresh process, just as it does after closing and reopening the popup.
export PITWALL_VIEW_PREVIEW="$XDG_CONFIG_HOME/preview"
"$SP" view >/dev/null
eq "a reopened panel publishes the previous view before its live result" "$(grep -c '^row	list:' "$PITWALL_VIEW_PREVIEW") $(grep -c 'Last seen · refreshing' "$PITWALL_VIEW_PREVIEW")" "2 1"
rm "$PITWALL_VIEW_PREVIEW"
"$SP" view listA >/dev/null
eq "a playlist page restores its own last tracks" "$(grep -c '^row	pl' "$PITWALL_VIEW_PREVIEW")" 2
rm "$PITWALL_VIEW_PREVIEW"
"$SP" view empty >/dev/null
eq "a different playlist cannot restore those tracks" "$(grep -c '^row	pl' "$PITWALL_VIEW_PREVIEW")" 0
kill "$API"; wait "$API" 2>/dev/null || :
V=$("$SP" view)
eq "an offline refresh keeps the last rows and labels them stale" "$(printf '%s\n' "$V" | grep -c '^row	list:') $(printf '%s\n' "$V" | grep -c 'Last seen · refresh failed')" "2 1"
rm -f "$PITWALL_VIEW_PREVIEW"
python3 - "$XDG_CONFIG_HOME/pitwall/spotify" <<'PYTHON'
import json, sys
path = sys.argv[1]
with open(path) as f:
    conf = json.load(f)
conf["panel_session"] = "second-login"
with open(path, "w") as f:
    json.dump(conf, f)
PYTHON
V=$("$SP" view)
eq "another login cannot replay the first account's playlists while offline" "$(printf '%s\n' "$V" | grep -c '^row	list:') $([ -e "$PITWALL_VIEW_PREVIEW" ] && echo restored || echo cold)" "0 cold"
eq "logout forgets the tokens" "$("$SP" cmd logout) $([ -f "$XDG_CONFIG_HOME/pitwall/spotify" ] && echo kept || echo gone)" "spotify: logged out gone"
eq "logout removes the persisted panels" "$([ -e "$XDG_CACHE_HOME/pitwall/spotify/panels.sqlite" ] && echo kept || echo gone)" gone
rm -f "$LOG.act"
exit $fail
