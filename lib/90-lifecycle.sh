# ───────────────────────────── lifecycle ─────────────────────────────
# Multi-node helpers (no-ops unless agents are isolated).
iso_active() { [ "${ISOLATE_AGENTS:-false}" = "true" ]; }
iso_vps2_ssh() {
  local k="$STACK_DIR/secrets/wg/mgmt.key"; [ -f "$k" ] || return 1
  # Pin the agent's host key on first contact (persisted known_hosts) rather than
  # StrictHostKeyChecking=no, which trusted any key on every connect.
  ssh -i "$k" -o ConnectTimeout=8 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$(ra_known_hosts)" "${RA_USER:-root}@$(agent_wg_ip)" "$@"
}
iso_wg_up()   { detect_os; [ "$OS_TYPE" = "linux" ] || return 0; local S=""; [ "$(id -u)" = 0 ] || S=sudo; $S wg-quick up wg0 2>/dev/null || true; }
iso_wg_down() { detect_os; [ "$OS_TYPE" = "linux" ] || return 0; local S=""; [ "$(id -u)" = 0 ] || S=sudo; $S wg-quick down wg0 2>/dev/null || true; }

start_stack() {
  load_config || exit 1; ensure_path_brew
  if vault_enabled; then vault_start || return 1; else ensure_unsealed || return 1; fi
  render_runtime_env   # re-render secret env from the vault (shredded on last stop)
  start_colima_if_needed
  iso_active && iso_wg_up
  iso_active && vault_enabled && vault_kms_start   # serve agent unseal keys over WG
  compose up -d
  if iso_active; then iso_vps2_ssh "$MGMT_NAME start" >/dev/null 2>&1 || printf '%sagent worker node unreachable%s\n' "$C_YELLOW" "$C_RESET"; fi
}
stop_stack() {
  load_config || exit 1; ensure_path_brew
  iso_active && { iso_vps2_ssh "$MGMT_NAME stop" >/dev/null 2>&1 || true; }
  compose stop
  shred_runtime_env   # remove the rendered secret env from disk
  if vault_enabled; then vault_kms_stop; vault_seal; elif seal_enabled && ! is_sealed; then seal_wipe; fi
  iso_active && iso_wg_down
}
status_stack()  { load_config || exit 1; ensure_path_brew; compose ps; }
restart_stack() { load_config || exit 1; ensure_path_brew; compose restart; }
logs_stack()    { load_config || exit 1; ensure_path_brew; local svc="${1:-}"; if [ -n "$svc" ]; then compose logs -f --tail=200 "$svc"; else compose logs -f --tail=200; fi; }

stack_running() {
  load_config >/dev/null 2>&1 || return 1
  [ -f "$STACK_DIR/compose/docker-compose.yml" ] || return 1
  command_exists docker || return 1
  local running total
  total="$(cd "$STACK_DIR/compose" 2>/dev/null && docker compose -f docker-compose.yml ps -a --services 2>/dev/null | wc -l | tr -d ' ')" || total=0
  running="$(cd "$STACK_DIR/compose" 2>/dev/null && docker compose -f docker-compose.yml ps --services 2>/dev/null | wc -l | tr -d ' ')" || running=0
  [ "${total:-0}" -gt 0 ] 2>/dev/null && [ "$running" -gt 0 ] 2>/dev/null
}

uninstall_usage() {
  printf '%s\n' "$(t un_usage)"
}

uninstall_note() {
  printf '  %s- %s%s\n' "$C_DIM" "$1" "$C_RESET"
}

uninstall_command_links() {
  local dry="$1" d
  [ "$dry" = "true" ] || remove_legacy_command_links
  for d in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin" "$HOME/bin"; do
    if [ -L "$d/$MGMT_NAME" ]; then
      uninstall_note "$d/$MGMT_NAME"
      [ "$dry" = "true" ] || rm -f "$d/$MGMT_NAME" 2>/dev/null || true
    fi
  done
}

uninstall_compose_down() {
  local dry="$1" volumes="$2" vol_flag=""
  [ "$volumes" = "true" ] && vol_flag="-v"
  if [ ! -f "$STACK_DIR/compose/docker-compose.yml" ]; then return 0; fi
  uninstall_note "docker compose down ${vol_flag:+$vol_flag }--remove-orphans"
  [ "$dry" = "true" ] && return 0
  command_exists docker || return 0
  # shellcheck disable=SC2086
  compose down $vol_flag --remove-orphans >/dev/null 2>&1 || true
}

uninstall_disable_watchdog() {
  local dry="$1"
  uninstall_note "$(t un_watchdog)"
  if [ "$dry" != "true" ]; then
    WATCHDOG_SKIP_SAVE=true watchdog_disable >/dev/null 2>&1 || true
  fi
}

uninstall_purge_stack_dir() {
  case "${STACK_DIR:-}" in ""|"/"|"$HOME") return 1 ;; esac
  rm -rf "$STACK_DIR" 2>/dev/null || true
  sleep 1
  [ -e "$STACK_DIR" ] && rm -rf "$STACK_DIR" 2>/dev/null || true
}

uninstall_stack() {
  local yes="false" remove_data="false" remove_volumes="false" dry="false" arg
  while [ $# -gt 0 ]; do
    arg="$1"; shift || true
    case "$arg" in
      --yes|-y) yes="true" ;;
      --data|--purge) remove_data="true" ;;
      --keep-data) remove_data="false" ;;
      --volumes|-v) remove_volumes="true" ;;
      --dry-run|--dry) dry="true" ;;
      --dir)
        [ $# -gt 0 ] || { uninstall_usage; return 1; }
        STACK_DIR="${1/#\~/$HOME}"; shift || true ;;
      --help|-h) uninstall_usage; return 0 ;;
      *) printf '%s: %s\n' "$(t un_unknown)" "$arg"; uninstall_usage; return 1 ;;
    esac
  done

  load_config || { echo "$(t no_env)"; return 1; }
  ensure_path_brew
  printf '\n%s%s%s\n  %s\n' "$C_RED$C_B" "$(t un_warn)" "$C_RESET" "$STACK_DIR"
  if [ "$yes" != "true" ]; then
    confirm "$(t un_confirm)" 'N' || { echo "$(t cancelled)"; return 0; }
    [ "$remove_volumes" = "true" ] || { confirm "$(t q_rm_volumes)" 'N' && remove_volumes="true"; }
    [ "$remove_data" = "true" ] || { confirm "$(t un_data)" 'N' && remove_data="true"; }
  fi

  [ "$dry" = "true" ] && printf '  %s%s%s\n' "$C_YELLOW" "$(t un_dry)" "$C_RESET"
  uninstall_disable_watchdog "$dry"
  uninstall_note "$(t un_cron)"
  [ "$dry" = "true" ] || cron_remove >/dev/null 2>&1 || true
  uninstall_compose_down "$dry" "$remove_volumes"
  uninstall_note "$(t un_runtime)"
  if [ "$dry" != "true" ]; then
    shred_runtime_env
    vault_seal   # stop the secrets daemon (wipes its RAM)
    docker rm -f "${SAFE_STACK_NAME}-wg-bridge" >/dev/null 2>&1 || true
    iso_active && iso_wg_down
  fi

  uninstall_note "$(t un_hosts)"
  [ "$dry" = "true" ] || remove_hosts_entries
  uninstall_note "$(t un_links)"
  uninstall_command_links "$dry"
  uninstall_note "$(t un_seal)"
  [ "$dry" = "true" ] || rm -f "$(seal_keyfile)" 2>/dev/null || true

  if [ "$remove_data" = "true" ]; then
    uninstall_note "$(t un_data_rm)"
    [ "$dry" = "true" ] || uninstall_purge_stack_dir || true
    printf '%s%s%s\n' "$C_GREEN" "$(t un_done)" "$C_RESET"
  else
    printf '%s %s%s%s\n' "$(t un_kept)" "$C_B" "$STACK_DIR" "$C_RESET"
  fi
}

update_rebuild() {
  load_config || exit 1; ensure_path_brew; start_colima_if_needed
  check_dependencies || return 1
  select_openhands_image
  write_all_configs
  build_openhands_sandbox
  compose_up_core
  if ingest_enabled; then compose_up_ingest || printf '%s%s%s\n' "$C_YELLOW" "$(t ingest_deferred)" "$C_RESET" >&2; fi
  prune_disabled_services
}
rebuild_only() {
  load_config || exit 1; ensure_path_brew; start_colima_if_needed
  select_openhands_image
  write_all_configs
  build_openhands_sandbox
  compose_up_core
  if ingest_enabled; then compose_up_ingest || printf '%s%s%s\n' "$C_YELLOW" "$(t ingest_deferred)" "$C_RESET" >&2; fi
  prune_disabled_services
}
