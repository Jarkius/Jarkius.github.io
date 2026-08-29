#!/bin/bash 
# Claude Code Statusline - Full Dashboard 
# Two-line display: context, cost, duration, turns, git status 
# Uses printf '%b' for reliable escape sequence rendering 

input=$(cat) 

# Extract basic info from statusline input 
model=$(echo "$input" | jq -r '.model.display_name' | sed -E 's/Claude ([0-9.]+) (.*)/\2 \1/')
# Anchor to the session's project root — NOT current_dir, which follows every
# `cd` the Bash tool runs and made git/project info drift mid-session.
dir=$(echo "$input" | jq -r '.workspace.project_dir // .workspace.current_dir // .cwd')
cur_dir=$(echo "$input" | jq -r '.workspace.current_dir // .cwd')
ctx_size=$(echo "$input" | jq -r '.context_window.context_window_size // 200000') 
transcript=$(echo "$input" | jq -r '.transcript_path // empty') 
session_name=$(echo "$input" | jq -r '.session_name // empty') 

# Project (ghq-aware) and branch 
ghq_root=$(ghq root 2>/dev/null) 
if [[ -n "$ghq_root" && "$dir" == "$ghq_root"* ]]; then 
  proj="${dir#$ghq_root/}" 
else 
  proj=$(basename "$dir")
fi 
branch=$(git -C "$dir" -c core.useBuiltinFSMonitor=false -c core.fsmonitor=false branch --show-current 2>/dev/null || echo "") 

# Calculate accurate context from transcript 
used=0 
if [ -n "$transcript" ] && [ -f "$transcript" ]; then 
  usage_line=$(tac "$transcript" 2>/dev/null | grep -m 1 '"input_tokens"' 2>/dev/null) 
  if [ -n "$usage_line" ]; then 
    input_tokens=$(echo "$usage_line" | jq -r '.message.usage.input_tokens // 0') 
    cache_create=$(echo "$usage_line" | jq -r '.message.usage.cache_creation_input_tokens // 0') 
    cache_read=$(echo "$usage_line" | jq -r '.message.usage.cache_read_input_tokens // 0') 
    used=$((input_tokens + cache_create + cache_read)) 
  fi 
fi 

# Fallback to API values if transcript parsing fails 
if [ "$used" -eq 0 ]; then 
  pct=$(echo "$input" | jq -r '.context_window.used_percentage // 0') 
  used=$(echo "scale=0; ($pct * $ctx_size) / 100" | bc) 
fi 

# Token counts for cost estimation 
total_in=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0') 
total_out=$(echo "$input" | jq -r '.context_window.total_output_tokens // 0') 

# Calculate display values 
mk=$(echo "scale=0; $ctx_size / 1000" | bc) 
used_k=$(echo "scale=0; $used / 1000" | bc) 
pct_int=$(echo "scale=0; ($used * 100) / $ctx_size" | bc) 

# Clamp percentage 
[ "$pct_int" -gt 100 ] && pct_int=100 
[ "$pct_int" -lt 0 ] && pct_int=0 

# Warning thresholds (compensate for hidden context ~15-20%) 
WARN_THRESHOLD=50 
CRIT_THRESHOLD=70 

# Color definitions using $'...' for pre-expanded escapes 
RST=$'\e[0m' 
RED=$'\e[31m' 
GRN=$'\e[32m' 
YLW=$'\e[33m' 
BLU=$'\e[34m' 
MAG=$'\e[35m' 
CYN=$'\e[36m' 
DGRN=$'\e[38;2;134;188;37m' 
ORG=$'\e[38;2;255;165;0m' 
LAV=$'\e[38;2;180;120;255m' 

# Build progress bar (20 chars) with color based on usage 
filled=$(echo "scale=0; $pct_int * 20 / 100" | bc) 
[ "$filled" -gt 20 ] && filled=20 
[ "$filled" -lt 0 ] && filled=0 

if [ "$pct_int" -ge "$CRIT_THRESHOLD" ]; then 
  bar_color="$RED"; pct_color="$RED"; warn_icon="⚠️ " 
elif [ "$pct_int" -ge "$WARN_THRESHOLD" ]; then 
  bar_color="$YLW"; pct_color="$YLW"; warn_icon="" 
else 
  bar_color="$RST"; pct_color="$YLW"; warn_icon="" 
fi 

bar="" 
for ((i=0; i<filled; i++)); do bar+="█"; done 
for ((i=filled; i<20; i++)); do bar+="░"; done 

# Current time 
current_time=$(date +%H:%M:%S) 

# --- Session duration (real payload path: .cost.total_duration_ms) ---
duration=""
fmt_ms() {  # ms → "XhYm" / "Xm" / "Xs"
  local s=$(( ${1%.*} / 1000 ))
  if [ "$s" -ge 3600 ]; then echo "$(( s / 3600 ))h$(( (s % 3600) / 60 ))m"
  elif [ "$s" -ge 60 ]; then echo "$(( s / 60 ))m"
  else echo "${s}s"; fi
}
dur_ms=$(echo "$input" | jq -r '.cost.total_duration_ms // empty')
[ -n "$dur_ms" ] && duration=$(fmt_ms "$dur_ms")

# Fallback: use transcript first entry timestamp
if [ -z "$duration" ] && [ -n "$transcript" ] && [ -f "$transcript" ]; then
  first_ts=$(head -1 "$transcript" 2>/dev/null | jq -r '.timestamp // empty' 2>/dev/null)
  if [ -n "$first_ts" ]; then
    start_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${first_ts%%.*}" +%s 2>/dev/null)
    [ -z "$start_epoch" ] && start_epoch=$(date -d "${first_ts}" +%s 2>/dev/null)
    if [ -n "$start_epoch" ]; then
      elapsed=$(( $(date +%s) - start_epoch ))
      duration=$(fmt_ms $(( elapsed * 1000 )))
    fi
  fi
fi

# --- Conversation turns --- 
turns=$(echo "$input" | jq -r '.conversation.turns // empty') 
# Fallback: count user messages in transcript 
if [ -z "$turns" ] && [ -n "$transcript" ] && [ -f "$transcript" ]; then 
  turns=$(grep -c '"role":"user"' "$transcript" 2>/dev/null || echo "") 
  [ "$turns" = "0" ] && turns="" 
fi 

# --- Session cost (real payload path: .cost.total_cost_usd) ---
cost=""
cost_raw=$(echo "$input" | jq -r '.cost.total_cost_usd // .session.cost_usd // empty')
if [ -n "$cost_raw" ] && [ "$cost_raw" != "null" ] && [ "$cost_raw" != "0" ]; then
  cost=$(printf '$%.2f' "$cost_raw")
fi

# Fallback: estimate from cumulative tokens (Opus pricing: $15/M in, $75/M out)
if [ -z "$cost" ] && { [ "$total_in" -gt 0 ] || [ "$total_out" -gt 0 ]; } 2>/dev/null; then
  est=$(echo "scale=2; ($total_in * 15 + $total_out * 75) / 1000000" | bc 2>/dev/null)
  if [ -n "$est" ] && [ "$est" != "0" ] && [ "$est" != ".00" ]; then
    cost="~\$${est}"
  fi
fi

# --- Lines changed this session (+added/-removed) ---
lines_str=""
la=$(echo "$input" | jq -r '.cost.total_lines_added // 0')
lr=$(echo "$input" | jq -r '.cost.total_lines_removed // 0')
if [ "$la" -gt 0 ] 2>/dev/null || [ "$lr" -gt 0 ] 2>/dev/null; then
  lines_str="+${la}/-${lr}"
fi

# --- API time share (how much of the session was Claude working) ---
api_str=""
api_ms=$(echo "$input" | jq -r '.cost.total_api_duration_ms // empty')
if [ -n "$api_ms" ] && [ -n "$dur_ms" ] && [ "${dur_ms%.*}" -gt 0 ] 2>/dev/null; then
  api_pct=$(( ${api_ms%.*} * 100 / ${dur_ms%.*} ))
  api_str="⚡ $(fmt_ms "$api_ms") (${api_pct}%)"
fi

# --- Mode flags: effort, fast mode, thinking off, output style, 200k+ ---
flags=""
effort=$(echo "$input" | jq -r '.effort.level // empty')
case "$effort" in
  high|xhigh|max) flags="${flags} 🧠${effort}" ;;
  low)            flags="${flags} 🪶low" ;;
esac
[ "$(echo "$input" | jq -r '.fast_mode // false')" = "true" ] && flags="${flags} 🚀fast"
[ "$(echo "$input" | jq -r '.thinking.enabled // true')" = "false" ] && flags="${flags} 💭off"
ostyle=$(echo "$input" | jq -r '.output_style.name // empty')
[ -n "$ostyle" ] && [ "$ostyle" != "default" ] && flags="${flags} 🎨${ostyle}"
[ "$(echo "$input" | jq -r '.exceeds_200k_tokens // false')" = "true" ] && flags="${flags} 📚1M"

# --- Rate-limit reset countdown (appended to rate_str below) ---
fmt_reset() {  # epoch-or-ISO → "2h13m"
  local raw="$1" epoch=""
  case "$raw" in
    (*[!0-9.]*) epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${raw%%.*}" +%s 2>/dev/null) ;;
    (*) epoch="${raw%.*}" ;;
  esac
  [ -z "$epoch" ] && return
  local left=$(( epoch - $(date +%s) ))
  [ "$left" -le 0 ] && return
  if [ "$left" -ge 3600 ]; then echo "$(( left / 3600 ))h$(( (left % 3600) / 60 ))m"
  else echo "$(( left / 60 ))m"; fi
}

# --- Git status --- 
git_dirty="" 
ab_str="" 
if [ -n "$branch" ]; then 
  git_status=$(git -C "$dir" -c core.useBuiltinFSMonitor=false -c core.fsmonitor=false status --porcelain 2>/dev/null | head -1) 
  if [ -n "$git_status" ]; then 
    git_dirty="${RED}●${RST}" 
  else 
    git_dirty="${GRN}✓${RST}" 
  fi 
  ahead_behind=$(git -C "$dir" -c core.useBuiltinFSMonitor=false -c core.fsmonitor=false rev-list --left-right --count HEAD...@{upstream} 2>/dev/null) 
  if [ -n "$ahead_behind" ]; then 
    ahead=$(echo "$ahead_behind" | awk '{print $1}') 
    behind=$(echo "$ahead_behind" | awk '{print $2}') 
    [ "$ahead" -gt 0 ] 2>/dev/null && ab_str="↑${ahead}" 
    [ "$behind" -gt 0 ] 2>/dev/null && ab_str="${ab_str}↓${behind}" 
  fi 
fi 

# --- Rate limits (with reset countdown) ---
five_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
five_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
week_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
rate_str=""
if [ -n "$five_pct" ]; then
  rate_str="5h:$(printf '%.0f' "$five_pct")%"
  reset_in=$(fmt_reset "$five_reset")
  [ -n "$reset_in" ] && rate_str="${rate_str}(↻${reset_in})"
fi
if [ -n "$week_pct" ]; then
  [ -n "$rate_str" ] && rate_str="${rate_str} "
  rate_str="${rate_str}7d:$(printf '%.0f' "$week_pct")%"
fi

# --- Vim mode ---
vim_mode=$(echo "$input" | jq -r '.vim.mode // empty')
vim_str=""
if [ -n "$vim_mode" ]; then
  [ "$vim_mode" = "INSERT" ] && vim_str="${GRN}-- INSERT --${RST}" || vim_str="${YLW}-- NORMAL --${RST}"
fi

# --- Subagent name (only present when Claude was started with --agent) ---
agent_name=$(echo "$input" | jq -r '.agent.name // empty')

# --- Worktree info (only present in a --worktree session) ---
worktree_name=$(echo "$input" | jq -r '.worktree.name // empty')
worktree_branch=$(echo "$input" | jq -r '.worktree.branch // empty')
worktree_str=""
if [ -n "$worktree_name" ]; then
  worktree_str="🗂 ${worktree_name}"
  [ -n "$worktree_branch" ] && worktree_str="${worktree_str}(${worktree_branch})"
fi

# --- PR/MR badge for the current branch ---
pr_num=$(echo "$input" | jq -r '.pr.number // empty')
pr_state=$(echo "$input" | jq -r '.pr.review_state // empty')
pr_kind=$(echo "$input" | jq -r '.pr.kind // empty')
pr_str=""
if [ -n "$pr_num" ]; then
  pr_prefix="#"
  [ "$pr_kind" = "mr" ] && pr_prefix="!"
  case "$pr_state" in
    approved)          pr_icon="✅" ;;
    changes_requested) pr_icon="❗" ;;
    draft)             pr_icon="📝" ;;
    pending)           pr_icon="🕒" ;;
    *)                 pr_icon="🔀" ;;
  esac
  pr_str="${pr_icon} ${pr_prefix}${pr_num}"
fi

# === LINE 1: project name, remote repo (clickable), directory (clickable) ===
remote_url=$(git -C "$dir" remote get-url origin 2>/dev/null | sed -E 's|.*github\.com[:/]||; s|\.git$||')
remote_http=""
[ -n "$remote_url" ] && remote_http="https://github.com/${remote_url}"

# OSC 8 hyperlink helpers using $'...' syntax
link_start=$'\e]8;;'
link_end=$'\e]8;;\a'
bell=$'\a'

out="${BLU}📁 ${proj}${RST}"
# Truncate long session names so the line doesn't wrap in split panes
if [ -n "$session_name" ] && [ "${#session_name}" -gt 24 ]; then
  session_name="${session_name:0:22}.."
fi
[ -n "$session_name" ] && out="${out} ${LAV}📝 ${session_name}${RST}"

# === LINE 2: git branch, status, ahead/behind, PR badge, worktree, remote repo (clickable), directory (clickable) ===
out2=""
if [ -n "$branch" ]; then
  out2="${GRN}🌿 ${branch}${RST} ${git_dirty}"
  [ -n "$ab_str" ] && out2="${out2} ${YLW}${ab_str}${RST}"
else
  out2="${GRN}🌿 ${RST}"
fi
[ -n "$pr_str" ] && out2="${out2} ${pr_str}"
if [ -n "$remote_url" ]; then
  out2="${out2} ${YLW}${link_start}${remote_http}${bell}📦 ${remote_url}${link_end}${RST}"
fi
out2="${out2} ${BLU}${link_start}file://${dir}${bell}📂 ${dir}${link_end}${RST}"
[ -n "$worktree_str" ] && out2="${out2} ${LAV}${worktree_str}${RST}"

# === LINE 3: time, duration, model, flags, subagent, vim mode ===
out3="${DGRN}🕐 ${current_time}${RST}"
[ -n "$duration" ] && out3="${out3} ${CYN}⏱ ${duration}${RST}"
out3="${out3} ${warn_icon}${MAG}🤖 ${model}${RST}"
[ -n "$flags" ] && out3="${out3}${LAV}${flags}${RST}"
[ -n "$agent_name" ] && out3="${out3} ${LAV}🧩 ${agent_name}${RST}"
[ -n "$vim_str" ] && out3="${out3} ${vim_str}"

# === LINE 4: context bar, pct, tokens ===
out4="${MAG}📊${RST} ${CYN}[${RST}${bar_color}${bar}${RST}${CYN}]${RST} ${pct_color}${pct_int}%${RST} ${MAG}${used_k}k/${mk}k${RST}"

# === LINE 5: rate limits ===
out5="${ORG}🔥${RST}"
[ -n "$rate_str" ] && out5="${out5} ${ORG}${rate_str}${RST}"

# === LINE 6: cost, turns, lines changed, API-time share, session name ===
out6="${GRN}📈${RST}"
[ -n "$cost" ] && out6="${out6} ${GRN}💰 ${cost}${RST}"
[ -n "$turns" ] && out6="${out6} ${CYN}💬 ${turns}${RST}"
[ -n "$lines_str" ] && out6="${out6} ${GRN}✏ ${lines_str}${RST}"
[ -n "$api_str" ] && out6="${out6} ${CYN}${api_str}${RST}"

# Print line 1
echo "$out"

# Print line 2
echo "$out2"

# Print line 3
echo "$out3"

# Print line 4
echo "$out4"

# Print line 5 (only when rate-limit data is present, e.g. Claude.ai subscription)
[ -n "$rate_str" ] && echo "$out5"

# Print line 6
echo "$out6"
