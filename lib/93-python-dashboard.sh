# ───────────────────────────── python dashboard ─────────────────────────────
write_python_dashboard() {
  [ -n "${STACK_DIR:-}" ] || return 0
  mkdir -p "$STACK_DIR/bin" || return 1
  local f="$STACK_DIR/bin/psai-dashboard.py"
  cat > "$f" <<'PY'
__PSAI_DASHBOARD_PY__
PY
  chmod +x "$f" 2>/dev/null || true
}

python_dashboard_available() {
  command_exists python3 || return 1
  python3 - <<'PY' >/dev/null 2>&1
import curses
PY
}

installed_menu_fallback() {
  ensure_lang; check_update_status
  while true; do
    clear_screen
    banner_stack
    render_context
    collect_runtime
    render_runtime
    printf '\n  %s%s%s\n' "$C_B$C_CYAN" "$(t dash_manage)" "$C_RESET"
    printf '  %s%s%s\n\n' "$C_DIM" "$(t dash_hotkeys)" "$C_RESET"
    printf '%s: ' "$(t menu_choice_cmd)"
    local c=""; IFS= read -r c || exit 0
    printf '\n'
    case "$(trim "$c" | tr 'A-Z' 'a-z')" in
      start)              start_stack; pause ;;
      stop)               stop_stack; pause ;;
      restart)            restart_stack; pause ;;
      status)             status_stack; pause ;;
      logs)               logs_stack ;;
      backup)             backup_stack; pause ;;
      restore)            restore_stack; pause ;;
      update)             update_rebuild; pause ;;
      rebuild)            rebuild_only; pause ;;
      components|upgrade) component_manager; pause ;;
      security)           security_menu; pause ;;
      proxy|proxies)      proxy_menu; pause ;;
      watchdog)           watchdog_menu; pause ;;
      seal|unseal)        if vault_enabled; then { vault_up && seal_now || unseal_now; }; elif seal_enabled && ! is_sealed; then seal_now; else unseal_now; fi; pause ;;
      fleet)              iso_active && fleet_menu; pause ;;
      trust-ca|trustca)   trust_ca; pause ;;
      hosts|add-hosts)    add_hosts_entries; pause ;;
      reinstall)          existing_install_flow; pause ;;
      uninstall)          uninstall_stack; exit 0 ;;
      lang|language)      choose_lang ;;
      help|\?)            print_help; pause ;;
      quit|exit)          exit 0 ;;
      "")                 : ;;
      *)                  echo "$(t no_such_item)"; pause ;;
    esac
  done
}

installed_menu() {
  load_config || return 1
  ensure_lang
  check_update_status
  write_python_dashboard >/dev/null 2>&1 || true
  if is_tty && python_dashboard_available && [ -x "$STACK_DIR/bin/psai-dashboard.py" ]; then
    UPDATE_AVAILABLE="$UPDATE_AVAILABLE" python3 "$STACK_DIR/bin/psai-dashboard.py" "$STACK_DIR"
    return $?
  fi
  installed_menu_fallback
}
