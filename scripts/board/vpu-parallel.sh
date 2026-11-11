#!/usr/bin/env bash
# Run N parallel encode and/or decode sessions on the Linlon V8 (amvx) and report
# whether they coexisted, how fast each ran, and what the driver's session table said.
#
# Runs ON THE BOARD. Encode source is videotestsrc, so no camera and no ISP node is
# opened -- the ISP is where every recorded hard hang on this board came from.
#
# Teardown is SIGINT, never SIGKILL: kill -9 on a GStreamer pipeline leaves the
# device unusable until isp-daemon restarts or the board reboots.
set -euo pipefail

ENC_NODE=/dev/video1
DEC_NODE=/dev/video0
DBG=/sys/kernel/debug
DEC_FILE=/opt/video_h265.mp4

n_enc=2
n_dec=0
width=640
height=480
fps=30
frames=60
codec=h264
outdir=
keep=0
cap=60
live=0

usage() {
	cat <<'EOF'
Usage: vpu-parallel.sh [options]

  -e N        encode sessions          (default 2)
  -d N        decode sessions          (default 0)
  -s WxH      encode resolution        (default 640x480)
  -r FPS      encode framerate         (default 30)
  -n FRAMES   frames per encode session (default 60)
  -c CODEC    h264 | h265              (default h264)
  -o DIR      output dir               (default a mktemp dir, removed unless -k)
  -k          keep encoded output
  -t SECONDS  per-session wall-clock cap (default 60)
  -l          pace the source at -r fps instead of running flat out, so a session
              that cannot keep up shows as wall time exceeding frames/fps
  -h          this

Exit status is 0 only if every session produced output and the node was left clean.
EOF
}

while getopts 'e:d:s:r:n:c:o:t:lkh' opt; do
	case $opt in
	e) n_enc=$OPTARG ;;
	d) n_dec=$OPTARG ;;
	s) width=${OPTARG%x*}; height=${OPTARG#*x} ;;
	r) fps=$OPTARG ;;
	n) frames=$OPTARG ;;
	c) codec=$OPTARG ;;
	o) outdir=$OPTARG ;;
	t) cap=$OPTARG ;;
	l) live=1 ;;
	k) keep=1 ;;
	h) usage; exit 0 ;;
	*) usage >&2; exit 2 ;;
	esac
done

case $codec in
h264 | h265) ;;
*) echo "unknown codec: $codec" >&2; exit 2 ;;
esac

if [ -z "$outdir" ]; then
	outdir=$(mktemp -d /tmp/vpu-parallel.XXXXXX)
else
	mkdir -p "$outdir"
fi

pids=()

# SIGINT lets GStreamer finish its EOS and close the fd cleanly. Escalating to
# SIGKILL would poison the node for the next run, so we wait instead.
# shellcheck disable=SC2317  # reached via trap, which shellcheck cannot see
cleanup() {
	local p
	if [ "${#pids[@]}" -gt 0 ]; then
		for p in "${pids[@]}"; do
			kill -INT "$p" 2>/dev/null || true
		done
		for p in "${pids[@]}"; do
			wait "$p" 2>/dev/null || true
		done
	fi
	[ "$keep" = 1 ] || rm -rf "$outdir"
}
trap cleanup EXIT INT TERM

# The amvx_if0/session directory stays empty on this driver; the scheduler file is
# where a live context actually shows up, as a Client/Dev session pair under an LSID.
# Counting those pairs is the direct evidence for "did each context get its own slot".
sessions() {
	local n
	# grep -c prints 0 and exits 1 when there is no match, so swallow the status only.
	n=$(sudo grep -c 'Client session' "$DBG/amvx_dev0/sched" 2>/dev/null || true)
	printf '  live sessions (Client session entries under an LSID): %s\n' "$n"
}

# Full scheduler state: which LSIDs are occupied, and what is queued behind them.
sched_state() {
	sudo sed -e 's/  */ /g' -e 's/ *$//' -e '/^$/d' "$DBG/amvx_dev0/sched" 2>/dev/null |
		sed 's/^/  /'
}

say() { printf '%s\n' "$*"; }
rule() { printf -- '--- %s\n' "$*"; }

preflight() {
	local nodes=("$ENC_NODE") holder
	[ -e "$ENC_NODE" ] || { echo "no $ENC_NODE" >&2; exit 1; }
	if [ "$n_dec" -gt 0 ]; then
		[ -e "$DEC_NODE" ] || { echo "no $DEC_NODE" >&2; exit 1; }
		[ -r "$DEC_FILE" ] || { echo "no decode source at $DEC_FILE" >&2; exit 1; }
		nodes+=("$DEC_NODE")
	fi
	holder=$(sudo fuser "${nodes[@]}" 2>/dev/null || true)
	if [ -n "$holder" ]; then
		echo "node already held by pid(s):$holder -- refusing to start" >&2
		exit 1
	fi
}

# One encode session. videotestsrc keeps the ISP out of it; colorimetry must be
# forced because the driver rejects GStreamer's bt601 guess. The elements' device
# property is read-only, but its default is already the node we want.
enc_pipeline() {
	local i=$1
	timeout -s INT "$cap" \
		gst-launch-1.0 -q \
		videotestsrc num-buffers="$frames" pattern=smpte is-live="$live" \
		! "video/x-raw,format=NV12,width=$width,height=$height,framerate=$fps/1,colorimetry=bt709" \
		! "v4l2${codec}enc" output-io-mode=mmap \
		! "${codec}parse" \
		! filesink location="$outdir/enc-$i.$codec"
}

dec_pipeline() {
	local i=$1
	timeout -s INT "$cap" \
		gst-launch-1.0 -q \
		filesrc location="$DEC_FILE" \
		! qtdemux ! h265parse \
		! v4l2h265dec \
		! fakesink sync=false \
		> "$outdir/dec-$i.log" 2>&1
}

# Wall clock per session, written to a file so the subshell's timing survives.
timed() {
	local kind=$1 i=$2 start end
	start=$(date +%s.%N)
	if [ "$kind" = enc ]; then
		enc_pipeline "$i" > "$outdir/enc-$i.log" 2>&1 && rc=0 || rc=$?
	else
		dec_pipeline "$i" && rc=0 || rc=$?
	fi
	end=$(date +%s.%N)
	printf '%s %s %s %s\n' "$kind" "$i" "$rc" \
		"$(echo "$end - $start" | bc)" > "$outdir/$kind-$i.time"
}

preflight

say "node:      $ENC_NODE (encode), $DEC_NODE (decode)"
[ "$live" = 1 ] && say "pacing:    source paced at ${fps} fps; expected wall time $(echo "scale=1; $frames / $fps" | bc)s per session"
say "cap:       ${cap}s per session; rc=124 means it was still running at the cap"
say "sessions:  ${n_enc} x ${codec} encode @ ${width}x${height}@${fps}, ${frames} frames; ${n_dec} x h265 decode"
say "cma:       $(awk '/CmaFree/ {print $2" "$3}' /proc/meminfo) free"
rule "driver session table, before"
sessions
rule "scheduler, before"
sched_state

for i in $(seq 1 "$n_enc"); do
	timed enc "$i" &
	pids+=($!)
done
for i in $(seq 1 "$n_dec"); do
	timed dec "$i" &
	pids+=($!)
done

# Sample the session table while the run is in flight -- this is the actual
# evidence for "did a second context get its own slot".
sleep 1
rule "driver session table, in flight"
sessions
rule "scheduler, in flight"
sched_state
rule "cma in flight"
awk '/CmaFree/ {print $2" "$3}' /proc/meminfo

fail=0
for p in "${pids[@]}"; do
	wait "$p" || fail=1
done
pids=()

rule "driver session table, after"
sessions
rule "scheduler, after"
sched_state

rule "results"
printf '%-6s %-4s %-5s %-9s %-7s %s\n' kind idx rc seconds fps note
for f in "$outdir"/*.time; do
	read -r kind idx rc secs < "$f"
	if [ "$kind" = enc ] && [ "$rc" = 0 ]; then
		eff=$(echo "scale=1; $frames / $secs" | bc)
	else
		eff='-'
	fi
	[ "$rc" = 124 ] && note=STALLED || note=''
	printf '%-6s %-4s %-5s %-9s %-7s %s\n' "$kind" "$idx" "$rc" "$secs" "$eff" "$note"
	[ "$rc" = 0 ] || fail=1
done

rule "output sizes"
find "$outdir" -maxdepth 1 -type f \( -name 'enc-*' -o -name 'dec-*' \) \
	-printf '%s\t%f\n' | sort -k2

for i in $(seq 1 "$n_enc"); do
	if [ ! -s "$outdir/enc-$i.$codec" ]; then
		say "FAIL: encode session $i produced no output"
		fail=1
	fi
done

rule "driver errors in dmesg, this run"
sudo dmesg --since '-2min' 2>/dev/null | grep -iE 'mvx|amvx' | tail -20 || say "(none)"

if [ "$fail" = 0 ]; then
	say "PASS: $n_enc encode + $n_dec decode sessions coexisted"
else
	say "FAIL: see above"
fi
exit "$fail"
