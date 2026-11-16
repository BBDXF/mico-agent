#!/bin/sh
# Read-only preflight for an Open-XiaoAI rooted OH2P. Does not print log lines
# or alter the speaker; only event counts are shown.
set -u

LOG_PATH=${MICO_INSTRUCTION_LOG:-/tmp/mico_aivs_lab/instruction.log}

printf '%s\n' '== OH2P / mico-agent preflight (read-only) =='
printf 'kernel architecture: '
uname -m 2>/dev/null || printf '%s\n' 'unavailable'

if [ -e /lib/ld-linux-armhf.so.3 ]; then
  printf '%s\n' 'armhf loader: present (/lib/ld-linux-armhf.so.3)'
else
  printf '%s\n' 'armhf loader: missing'
fi

printf '%s\n' 'shared libraries:'
for pattern in /usr/lib/libcurl.so* /lib/libcurl.so* /usr/lib/libstdc++.so* /lib/libstdc++.so*; do
  # Expand each glob without making an unmatched pattern look like a file.
  for path in $pattern; do
    [ -e "$path" ] && ls -l "$path" 2>/dev/null
  done
done

for command_name in ubus mphelper curl; do
  if [ "$command_name" = "mphelper" ] && [ -x /usr/bin/mphelper ]; then
    command_path=/usr/bin/mphelper
  else
    command_path=$(command -v "$command_name" 2>/dev/null || true)
  fi
  if [ -n "$command_path" ]; then
    printf '%s: %s\n' "$command_name" "$command_path"
  else
    printf '%s: missing\n' "$command_name"
  fi
done

if [ -x /usr/sbin/tts_play.sh ]; then
  printf '%s\n' 'TTS script: present (/usr/sbin/tts_play.sh)'
else
  printf '%s\n' 'TTS script: missing (/usr/sbin/tts_play.sh)'
fi

if command -v ubus >/dev/null 2>&1; then
  printf '%s\n' 'mediaplayer playback methods:'
  ubus -v list mediaplayer 2>/dev/null | grep -E 'player_play_url|player_play_operation' || true
fi

if [ -r "$LOG_PATH" ]; then
  printf 'instruction log: readable (%s)\n' "$LOG_PATH"
  count=$(grep -c 'SpeechRecognizer' "$LOG_PATH" 2>/dev/null || true)
  printf 'SpeechRecognizer records: '
  printf '%s\n' "${count:-0}"
  count=$(grep -c 'RecognizeResult' "$LOG_PATH" 2>/dev/null || true)
  printf 'RecognizeResult records: '
  printf '%s\n' "${count:-0}"
else
  printf 'instruction log: missing or unreadable (%s)\n' "$LOG_PATH"
fi

printf '%s\n' 'data volume:'
df -h /data 2>/dev/null || df /data 2>/dev/null || true
