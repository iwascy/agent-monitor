#!/bin/sh
# Agent Monitor: append one Claude Code hook event per line. Must print nothing.
dir="$HOME/Library/Application Support/AgentMonitor/events"
mkdir -p "$dir" 2>/dev/null
{ printf '%s\t' "$(date +%s)"; tr -d '\n'; printf '\n'; } >> "$dir/claude.tsv" 2>/dev/null
exit 0
