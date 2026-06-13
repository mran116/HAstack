#!/usr/bin/env bash
# ⚠ VENDORED FROM core — DO NOT EDIT HERE. Change it in the core repo, then run sync-tooling.
# =============================================================================
# stacks.sh — choose which stacks THIS host deploys (a local profile).
#
# Three states per stack:
#   approved — deploys with bulk `hs up` (you've decided to keep it)
#   denied   — EXCLUDED from bulk deploy (still deployable by name: hs up <name>)
#   pending  — new since you last decided; you'll be asked about it ONCE
#
# Deploy rule: everything deploys EXCEPT denied stacks and stacks that declare
# DEPLOY=manual in their stack.conf. "pending" still deploys, but `hs update`
# asks about each new one first. State lives in .stacks.local (gitignored).
#
# Two layers, complementary:
#   - .stacks.local DENIED  = host operator: "not on THIS box"      (per-host)
#   - <stack>/stack.conf DEPLOY=manual = stack author: "opt-in only" (per-stack)
#
# Stacks are DISCOVERED (across STACK_ROOTS) and ordered by their WAVE — no
# hardcoded list — so this works for any repo on any machine.
#
#   hs stacks                  show each stack's state
#   hs stacks disable <s..>    exclude stack(s) from bulk deploy
#   hs stacks enable  <s..>    re-include stack(s)
#   hs stacks reconcile        decide each pending (new) stack  (--yes: skip)
# Flags: --dry-run, --yes.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=scripts/lib/stacks.sh
source "$SCRIPT_DIR/lib/stacks.sh"
cd "$REPO_DIR"

usage() { sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
parse_common_flags "$@"
args=(); for a in "$@"; do [[ "$a" == -* ]] || args+=("$a"); done
set -- "${args[@]+"${args[@]}"}"

PROFILE="$REPO_DIR/.stacks.local"
SEEN=""; DENIED=""
# shellcheck disable=SC1090
[[ -f "$PROFILE" ]] && source "$PROFILE"

add_to() { local v; for v in $2; do in_list "$v" "${!1}" || printf -v "$1" '%s' "${!1:+${!1} }$v"; done; }
rm_from() { local out="" v; for v in ${!1}; do in_list "$v" "$2" || out+="${out:+ }$v"; done; printf -v "$1" '%s' "$out"; }
in_list() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# Every discovered stack, wave-ordered (status shows ALL, incl. manual/denied).
all_stacks() {
  discover_stacks | while read -r s; do printf '%s %s\n' "$(stack_wave "$s")" "$s"; done \
    | sort -k1,1n -k2,2 | awk '{print $2}'
}
state_of() {
  in_list "$1" "$DENIED" && { echo denied;   return; }
  in_list "$1" "$SEEN"   && { echo approved; return; }
  echo pending
}
save() { printf '# hs stack profile (local, gitignored). SEEN = decided about; DENIED = excluded.\nSEEN="%s"\nDENIED="%s"\n' "$SEEN" "$DENIED" > "$PROFILE"; }

cmd="${1:-status}"; [[ $# -gt 0 ]] && shift
case "$cmd" in
  deploy-list)  # stacks to bulk-deploy: wave-ordered, minus DEPLOY=manual, minus DENIED
    while read -r s; do in_list "$s" "$DENIED" || echo "$s"; done < <(deploy_list) ;;

  denied-list)  printf '%s\n' $DENIED ;;

  pending-list)
    while read -r s; do [[ "$(state_of "$s")" == pending ]] && echo "$s"; done < <(all_stacks) ;;

  status)
    say "Stack profile ($([[ -f "$PROFILE" ]] && echo "$PROFILE" || echo 'none yet — everything deploys'))"
    while read -r s; do
      local extra=""; stack_auto "$s" || extra=" [manual]"
      case "$(state_of "$s")" in
        approved) printf '  %s✓%s %-15s deploys (wave %s)%s\n'                   "$c_green"  "$c_reset" "$s" "$(stack_wave "$s")" "$extra" ;;
        denied)   printf '  %s✗%s %-15s excluded (hs stacks enable %s)%s\n'      "$c_red"    "$c_reset" "$s" "$s" "$extra" ;;
        pending)  printf '  %s?%s %-15s new — deploys; decide via hs update%s\n' "$c_yellow" "$c_reset" "$s" "$extra" ;;
      esac
    done < <(all_stacks) ;;

  enable)
    [[ $# -gt 0 ]] || die "usage: hs stacks enable <stack...>"
    for s in "$@"; do stack_dir "$s" >/dev/null || die "No such stack: '$s'"; done
    [[ $DRY_RUN -eq 1 ]] && { say "[dry-run] would enable: $*"; exit 0; }
    rm_from DENIED "$*"; add_to SEEN "$*"; save; say "Enabled: $*" ;;

  disable)
    [[ $# -gt 0 ]] || die "usage: hs stacks disable <stack...>"
    for s in "$@"; do stack_dir "$s" >/dev/null || die "No such stack: '$s'"; done
    [[ $DRY_RUN -eq 1 ]] && { say "[dry-run] would disable: $*"; exit 0; }
    add_to SEEN "$*"; add_to DENIED "$*"; save
    say "Disabled (excluded from bulk deploy): $*"
    say "Already-running ones aren't stopped — 'hs down $*' to stop them." ;;

  reconcile)
    pending=(); while read -r s; do [[ "$(state_of "$s")" == pending ]] && pending+=("$s"); done < <(all_stacks)
    [[ ${#pending[@]} -eq 0 ]] && { say "No new stacks to decide."; exit 0; }
    if [[ $DRY_RUN -eq 1 ]]; then say "[dry-run] pending: ${pending[*]}"; exit 0; fi
    if [[ $ASSUME_YES -eq 1 ]]; then say "New stack(s) left undecided (--yes): ${pending[*]}"; exit 0; fi
    if [[ ! -f "$PROFILE" ]] && ! ask_yn "Choose which stacks to deploy now? (No = enable all; exclude later)" N; then
      for s in "${pending[@]}"; do add_to SEEN "$s"; done; save
      say "All stacks enabled. Exclude any later with 'hs stacks disable <name>'."; exit 0
    fi
    say "New stack(s) since you last looked:"
    for s in "${pending[@]}"; do
      add_to SEEN "$s"
      if ask_yn "Deploy '$s'?" Y; then say "  keep $s"; else add_to DENIED "$s"; say "  exclude $s"; fi
    done
    save; say "Stack profile updated." ;;

  *) die "unknown: hs stacks {status|enable|disable|reconcile}" ;;
esac
