#!/usr/bin/env bash
# Resolve the default-off world treatments the opt-in frame-evidence pass turns on.
#
# The opt-in capture exists because the ordinary capture photographs the DEFAULT
# path, so an artifact reviewing a default-off treatment structurally cannot
# contain the change under review (#528). Which treatments it enables is data —
# `tools/preview-flags.txt` — rather than text inside a workflow step, so adding
# a preview is one line and cannot drift between the jobs that consume it.
#
# FAILS CLOSED, and that is the whole point. Every failure mode here — a missing
# list, a malformed name, an empty list — would otherwise let the capture run
# with no flags exported, photograph the default surface, print `CAPTURE PASS`
# and publish frames that look like evidence for a treatment they do not show.
# A silent fallback to the default path is precisely the failure this pass was
# built to prevent, so it is an error rather than a warning.
#
# Names are validated against a strict pattern rather than trusted, because the
# caller SOURCES this output with `set -a` to export it. Only `WAR_[A-Z0-9_]+`
# can be emitted, so a line in the list cannot become a command substitution, a
# second assignment, or a shell operator.
set -euo pipefail

PREVIEW_FLAGS_FILE_DEFAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preview-flags.txt"

# read_preview_flags <file>
#
# Prints one validated flag NAME per line. Returns non-zero, with the reason on
# stderr, when the list cannot be trusted to configure a capture.
read_preview_flags() {
	local file="$1"
	local line flag seen=' ' count=0

	if [ ! -f "$file" ]; then
		printf 'preview-flags: no flag list at %s — the opt-in capture would photograph the default path\n' "$file" >&2
		return 1
	fi

	# `|| [ -n "$line" ]` so a final line with no trailing newline is still read
	# rather than silently dropped — a truncated list is a silent capture of the
	# default path, which is the failure mode this guard exists for.
	while IFS= read -r line || [ -n "$line" ]; do
		# Strip a trailing carriage return so a CRLF-edited list does not turn
		# every name into `WAR_FOO\r`, which fails the pattern below for a reason
		# nobody can see in a diff.
		line="${line%$'\r'}"
		# Trim surrounding whitespace; an indented entry is a formatting choice,
		# not a different flag.
		line="${line#"${line%%[![:space:]]*}"}"
		line="${line%"${line##*[![:space:]]}"}"

		case "$line" in
		'' | '#'*) continue ;;
		esac

		flag="$line"
		if ! [[ $flag =~ ^WAR_[A-Z0-9_]+$ ]]; then
			printf 'preview-flags: %s: not a valid flag name: %s\n' "$file" "$flag" >&2
			printf 'preview-flags: entries must match WAR_[A-Z0-9_]+ — one bare environment variable name per line\n' >&2
			return 1
		fi

		# Duplicates are rejected rather than de-duplicated: the same flag listed
		# twice means two edits disagreed about the set, and quietly collapsing
		# them hides that.
		case "$seen" in
		*" $flag "*)
			printf 'preview-flags: %s: %s listed more than once\n' "$file" "$flag" >&2
			return 1
			;;
		esac
		seen="$seen$flag "

		printf '%s\n' "$flag"
		count=$((count + 1))
	done <"$file"

	if [ "$count" -eq 0 ]; then
		printf 'preview-flags: %s lists no flags — the opt-in capture would photograph the default path and report success\n' "$file" >&2
		return 1
	fi
}

# check_preview_flag_consumers <client_dir> <flag>...
#
# Every listed flag must be READ by the client, not merely well-formed.
#
# Shape validation alone accepts `WAR_GROUND_PLATE` — a plausible typo for a
# real flag. Nothing consumes it, so the capture exports it, renders the
# DEFAULT world, and still satisfies CAPTURE PASS, BOOT_OK and the error sweep:
# a PR would publish frames that do not contain the treatment it just enabled,
# with every check green. That is the failure this whole pass exists to
# prevent, so a flag with no consumer is an error.
#
# Matched against the exact `OS.get_environment("FLAG")` call because that is
# how the client reads these, and a bare name search would be satisfied by a
# dev-log entry or a comment mentioning the flag.
#
# COMMENTS ARE STRIPPED FIRST. A raw search also succeeds on
# `# OS.get_environment("WAR_FOO")`, so a consumer commented out during a
# refactor — with its list entry left behind — would keep this gate green while
# the client ignores the exported flag, which is the very state the gate exists
# to catch. Everything from the first `#` on a line is dropped before matching.
# A `#` inside a string literal earlier on the same line could hide a real call,
# but that fails CLOSED (a rejection naming the flag), which is the safe
# direction for a guard whose whole job is refusing what it cannot confirm.
#
# Held in a VARIABLE and matched with a here-string, never piped into `grep -q`:
# under `pipefail` the early exit SIGPIPEs the upstream and the pipeline reports
# failure, which would read here as "no consumer found" and reject every flag. A
# here-string is a redirect rather than a pipeline, so it sidesteps that without
# a temp file to leak if `find` aborts under `errexit`.
check_preview_flag_consumers() {
	local client_dir="$1"
	shift
	local flag missing=0 executable_src

	if [ ! -d "$client_dir" ]; then
		printf 'preview-flags: no client tree at %s — cannot confirm any flag is consumed\n' "$client_dir" >&2
		return 1
	fi

	executable_src="$(find "$client_dir" -name '*.gd' -type f -exec awk '{sub(/#.*/, ""); print}' {} +)"

	for flag in "$@"; do
		if ! grep -qF "OS.get_environment(\"$flag\")" <<<"$executable_src"; then
			printf 'preview-flags: %s is listed but no client script reads it\n' "$flag" >&2
			printf 'preview-flags: expected an executable OS.get_environment("%s") under %s — a flag nothing consumes captures the DEFAULT world and still passes every check\n' "$flag" "$client_dir" >&2
			missing=$((missing + 1))
		fi
	done

	[ "$missing" -eq 0 ]
}

# Executed rather than sourced: emit the set in the requested shape.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	mode="${1---env}"
	file="${WAR_PREVIEW_FLAGS_FILE:-$PREVIEW_FLAGS_FILE_DEFAULT}"

	# Resolved in FULL before anything is printed. The caller redirects this into
	# the file it then sources and ships in the artifact, so a rejection halfway
	# down the list must leave no output at all — a truncated set would export
	# some treatments, photograph the rest on their default path, and look like a
	# complete capture.
	case "$mode" in
	--names | --check | --check-consumers | --env) ;;
	*)
		printf 'usage: preview-flags.sh [--env|--names|--check|--check-consumers]\n' >&2
		exit 2
		;;
	esac

	flags="$(read_preview_flags "$file")"

	case "$mode" in
	--check) ;;
	# Deliberately NOT folded into --env, which the capture calls. The capture
	# job is path-gated and can legitimately be skipped, whereas the test that
	# calls this runs on every PR — so the earlier, cheaper job is the one that
	# should catch a flag nothing reads. It also keeps the GPU step from
	# depending on the client tree's layout.
	--check-consumers)
		# shellcheck disable=SC2086 # deliberate split: one argument per flag
		check_preview_flag_consumers "$(dirname "$PREVIEW_FLAGS_FILE_DEFAULT")/../client" $flags
		;;
	--names) printf '%s\n' "$flags" ;;
	# `NAME=1` lines, for a caller that sources this under `set -a`. The capture
	# writes this straight into the artifact, so the record a reviewer opens is
	# the same bytes that configured the run rather than a second description of
	# it that can disagree.
	--env) printf '%s\n' "$flags" | sed 's/$/=1/' ;;
	esac
fi
