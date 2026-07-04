# ───────────────────────────── operator dashboard ─────────────────────────────
check_update_status() { UPDATE_AVAILABLE="${UPDATE_AVAILABLE:-false}"; }

# service|image|state|health for every container; cached so render is cheap.
COMP_LIST=""
COMP_SELECTED=1
DASH_FOCUS="${DASH_FOCUS:-command}"
component_health_fallback() {
  local svc="$1" st="${2:-}" code="${3:-}" cname h
  cname="${SAFE_STACK_NAME:-$DEFAULT_STACK_NAME}-$svc"
  h="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cname" 2>/dev/null || true)"
  case "$h" in
    healthy|unhealthy|starting) printf '%s' "$h" ;;
    running) printf 'healthy' ;;
    exited) case "${code:-}" in 0|'') printf 'done' ;; *) printf 'failed' ;; esac ;;
    "") [ "$st" = "exited" ] && [ "${code:-0}" = "0" ] && printf 'done' || printf '-' ;;
    *) printf '%s' "$h" ;;
  esac
}

collect_components() {
  COMP_LIST=""
  command_exists docker || return 0
  [ -f "$STACK_DIR/compose/docker-compose.yml" ] || return 0
  local rows="" svc img st health code out=""
  rows="$( cd "$STACK_DIR/compose" 2>/dev/null && \
    docker compose -f docker-compose.yml ps -a --format '{{.Service}}|{{.Image}}|{{.State}}|{{.Health}}|{{.ExitCode}}' 2>/dev/null )" || rows=""
  while IFS='|' read -r svc img st health code; do
    [ -n "$svc" ] || continue
    [ -n "$health" ] || health="$(component_health_fallback "$svc" "$st" "$code")"
    out="${out}${svc}|${img}|${st}|${health}|${code}
"
  done <<EOF
$rows
EOF
  COMP_LIST="$out"
}

component_count() {
  printf '%s\n' "$COMP_LIST" | awk 'NF{n++} END{print n+0}'
}

component_service_at() {
  local idx="$1"
  printf '%s\n' "$COMP_LIST" | awk -F'|' -v want="$idx" 'NF{n++; if(n==want){print $1; exit}}'
}

shorten() {
  local s="$1" max="$2"
  if [ "$(vwidth "$s")" -le "$max" ]; then printf '%s' "$s"; return 0; fi
  printf '%s…' "$(printf '%s' "$s" | awk -v m=$((max - 1)) '{print substr($0,1,m)}')"
}

component_dot() {
  local st="$1" code="${2:-0}"
  case "$st" in
    running) printf '%s●%s' "$C_GREEN" "$C_RESET" ;;
    exited)  case "$code" in 0|'') printf '%s●%s' "$C_DIM" "$C_RESET" ;; *) printf '%s●%s' "$C_RED" "$C_RESET" ;; esac ;;
    dead)    printf '%s●%s' "$C_RED" "$C_RESET" ;;
    *)       printf '%s●%s' "$C_YELLOW" "$C_RESET" ;;
  esac
}

component_cell() {
  local idx="$1" line svc img st health code sel=" " out
  line="$(printf '%s\n' "$COMP_LIST" | awk -v want="$idx" 'NF{n++; if(n==want){print; exit}}')"
  [ -n "$line" ] || { printf '%*s' 58 ""; return 0; }
  IFS='|' read -r svc img st health code <<EOF
$line
EOF
  img="${img##*/}"
  svc="$(shorten "$svc" 15)"
  img="$(shorten "$img" 18)"
  [ -n "$health" ] || health="$([ "$st" = "running" ] && printf healthy || printf failed)"
  [ "$idx" -eq "${COMP_SELECTED:-1}" ] 2>/dev/null && sel="${C_CYAN}›${C_RESET}"
  out="$(printf '%s %s %s%-15s%s %s%-18s%s %-8s %-9s' \
    "$sel" "$(component_dot "$st" "$code")" "$C_B" "$svc" "$C_RESET" "$C_DIM" "$img" "$C_RESET" "$st" "$health")"
  pad_right "$out" 58
}

component_move() {
  local dir="$1" n half cur
  n="$(component_count)"; [ "$n" -gt 0 ] 2>/dev/null || return 0
  half=$(( (n + 1) / 2 ))
  cur="${COMP_SELECTED:-1}"
  case "$dir" in
    up)    cur=$((cur - 1)) ;;
    down)  cur=$((cur + 1)) ;;
    left)  cur=$((cur - half)) ;;
    right) cur=$((cur + half)) ;;
  esac
  [ "$cur" -lt 1 ] && cur="$n"
  [ "$cur" -gt "$n" ] && cur=1
  COMP_SELECTED="$cur"
}

# Operator table: context line, two component columns, and a selected row for log navigation.
render_components() {
  section_header "$(t sec_components)"
  [ -n "$COMP_LIST" ] || { printf '    %s(%s)%s\n' "$C_DIM" "$(t st_stopped)" "$C_RESET"; return 0; }
  local n half i right
  n="$(component_count)"
  [ "${COMP_SELECTED:-1}" -gt "$n" ] 2>/dev/null && COMP_SELECTED=1
  half=$(( (n + 1) / 2 ))
  printf '    %s  %-15s %-18s %-8s %-9s    %-15s %-18s %-8s %-9s%s\n' \
    "$C_DIM" "NAME" "IMAGE" "STATE" "HEALTH" "NAME" "IMAGE" "STATE" "HEALTH" "$C_RESET"
  i=1
  while [ "$i" -le "$half" ]; do
    right=$((i + half))
    printf '    %s  %s\n' "$(component_cell "$i")" "$(component_cell "$right")"
    i=$((i + 1))
  done
  printf '    %s%s%s\n' "$C_DIM" "$(t comp_nav_hint)" "$C_RESET"
  return 0
}

dashboard_read_choice() {
  local c rest buf=""
  if [ ! -t 0 ]; then IFS= read -r c || return 1; printf '%s' "$c"; return 0; fi
  while true; do
    IFS= read -rsn1 c || return 1
    case "$c" in
      $'\022') printf '__section_run'; return 0 ;;      # Ctrl+R
      $'\004') printf '__section_data'; return 0 ;;     # Ctrl+D
      $'\016') printf '__section_net'; return 0 ;;      # Ctrl+N
      $'\017') printf '__section_settings'; return 0 ;; # Ctrl+O
      $'\013') printf '__focus_toggle'; return 0 ;;     # Ctrl+K
    esac

    if [ "${DASH_FOCUS:-command}" = "components" ]; then
      case "$c" in
        "") printf '__enter'; return 0 ;;
        $'\033')
          IFS= read -rsn2 rest || rest=""
          case "$rest" in
            '[A') printf '__up' ;; '[B') printf '__down' ;; '[C') printf '__right' ;; '[D') printf '__left' ;;
            *) printf '' ;;
          esac
          return 0 ;;
        *) : ;;
      esac
      continue
    fi

    case "$c" in
      "") printf '%s' "$buf"; return 0 ;;
      $'\033') IFS= read -rsn2 rest || true ;; # swallow arrows in command mode
      $'\177'|$'\010')
        if [ -n "$buf" ]; then
          buf="${buf%?}"
          printf '\b \b' >&2
        fi ;;
      *)
        case "$c" in
          [[:print:]])
            buf="$buf$c"
            printf '%s' "$c" >&2 ;;
        esac ;;
    esac
  done
}

dashboard_component_logs() {
  local svc; svc="$(component_service_at "${COMP_SELECTED:-1}")"
  [ -n "$svc" ] || return 0
  sub_header "$svc logs"
  compose logs --tail=220 "$svc" 2>&1 || true
  printf '\n%s ' "$(t logs_back_hint)"
  IFS= read -r _ || true
}

# Network map: the two egress proxies + their routes.
proxy_label() {
  case "$1" in
    none) printf '%s' "$(t px_direct)" ;; tor) printf 'Tor' ;; wireguard) printf 'WireGuard' ;;
    vless) printf 'VLESS' ;; adguardvpn) printf 'AdGuard VPN' ;; tailscale) printf 'Tailscale' ;;
    *) printf '%s' "$1" ;;
  esac
}
render_netmap() {
  section_header "$(t sec_netmap)"
  printf '    %s%-13s%s %s%s%s  %s(LLM + %s)%s\n' "$C_DIM" "proxy-stack:" "$C_RESET" "$C_CYAN" "$(proxy_label "$EGRESS_STACK")" "$C_RESET" \
    "$C_DIM" "$(t stack_updates_label)" "$C_RESET"
  printf '    %s%-13s%s %s%s%s  %s(web worker)%s\n' "$C_DIM" "proxy-web:" "$C_RESET" "$C_CYAN" "$(proxy_label "$EGRESS_WEB")" "$C_RESET" "$C_DIM" "$C_RESET"
  if iso_active; then
    printf '    %s%-13s%s ⇄ WG ⇄  %s%s%s  %s(%s)%s\n' "$C_DIM" "agents:" "$C_RESET" "$C_B" "${AGENT_WG_IP:-?}" "$C_RESET" "$C_DIM" "${AGENT_PUBLIC_IP:-?}" "$C_RESET"
  fi
}

render_secrets() {
  section_header "$(t sec_secrets)"
  local sc="$C_DIM" label store="seal"
  if vault_enabled; then
    store="$(vault_role_label)"; label="$(vault_status_label)"; vault_up && sc="$C_GREEN" || sc="$C_YELLOW"
  else
    label="$(seal_status_label)"
    if seal_enabled; then if is_sealed; then sc="$C_GREEN"; else sc="$C_YELLOW"; fi; fi
  fi
  printf '    %sadmin:%s %s%s%s    %s %s%s:%s %s%s%s\n' "$C_DIM" "$C_RESET" "$C_B" "${ADMIN_USER:-admin}" "$C_RESET" \
    "$(status_dot "$sc")" "$C_DIM" "$store" "$C_RESET" "$sc" "$label" "$C_RESET"
}

header_stack() {
  clear_screen
  banner_stack
  render_context
  collect_runtime; collect_components
  render_runtime
  render_components
  render_netmap
  render_secrets
  printf '\n'
}

render_dashboard_commands() {
  printf '  %s%s%s\n' "$C_DIM" "$(t dash_commands)" "$C_RESET"
  printf '  %s%s%s\n' "$C_DIM" "$(t dash_hotkeys)" "$C_RESET"
}

dashboard_section_menu() {
  local title="$1"; shift
  DASH_SECTION_CHOICE=""
  clear_screen
  sub_header "$title"
  local i=1
  while [ $# -gt 0 ]; do
    printf '  %s[%s]%s %s\n' "$C_CYAN" "$i" "$C_RESET" "$1"
    shift; i=$((i + 1))
  done
  printf '  %s[0]%s %s\n\n%s: ' "$C_CYAN" "$C_RESET" "$(t m_back)" "$(t menu_choice)"
  local c; read_user_line c; DASH_SECTION_CHOICE="$(trim "$c")"
}

dashboard_run_section() {
  local c
  if stack_running; then
    dashboard_section_menu "$(t dash_run)" "$(t d_stop)" "$(t d_restart)" "$(t d_status)" "$(t d_logs)"
    c="$DASH_SECTION_CHOICE"
    case "$c" in 1) stop_stack; pause ;; 2) restart_stack; pause ;; 3) status_stack; pause ;; 4) logs_stack ;; esac
  else
    dashboard_section_menu "$(t dash_run)" "$(t d_start)" "$(t d_restart)" "$(t d_status)" "$(t d_logs)"
    c="$DASH_SECTION_CHOICE"
    case "$c" in 1) start_stack; pause ;; 2) restart_stack; pause ;; 3) status_stack; pause ;; 4) logs_stack ;; esac
  fi
}

dashboard_data_section() {
  local c
  dashboard_section_menu "$(t dash_data)" "$(t d_backup)" "$(t d_restore)" "$(t d_update)" "$(t d_rebuild)" "$(t d_components)"
  c="$DASH_SECTION_CHOICE"
  case "$c" in
    1) backup_stack; pause ;; 2) restore_stack; pause ;; 3) update_rebuild; pause ;;
    4) rebuild_only; pause ;; 5) component_manager; pause ;;
  esac
}

dashboard_net_section() {
  local c
  dashboard_section_menu "$(t dash_net)" "$(t d_security)" "$(t d_proxy)" "$(t d_watchdog)" "$(t d_seal)" "trust-ca" "hosts"
  c="$DASH_SECTION_CHOICE"
  case "$c" in
    1) security_menu; pause ;; 2) proxy_menu; pause ;; 3) watchdog_menu; pause ;;
    4) if vault_enabled; then { vault_up && seal_now || unseal_now; }; elif seal_enabled && ! is_sealed; then seal_now; else unseal_now; fi; pause ;;
    5) trust_ca; pause ;; 6) add_hosts_entries; pause ;;
  esac
}

dashboard_settings_section() {
  local c
  dashboard_section_menu "$(t dash_settings)" "$(t d_reinstall)" "$(t d_uninstall)" "$(t d_lang)" "$(t d_help)" "$(t quit)"
  c="$DASH_SECTION_CHOICE"
  case "$c" in
    1) existing_install_flow; pause ;; 2) uninstall_stack; exit 0 ;; 3) choose_lang ;;
    4) print_help; pause ;; 5) exit 0 ;;
  esac
}

installed_menu() {
  load_config || return 1
  ensure_lang; check_update_status
  while true; do
    header_stack
    printf '  %s%s%s\n\n' "$C_B$C_CYAN" "$(t dash_manage)" "$C_RESET"
    render_dashboard_commands
    if [ "${DASH_FOCUS:-command}" = "components" ]; then
      printf '\n%s: ' "$(t dash_component_focus)"
    else
      printf '\n%s: ' "$(t menu_choice_cmd)"
    fi
    local c=""; c="$(dashboard_read_choice)" || exit 0
    printf '\n'
    case "$(trim "$c" | tr 'A-Z' 'a-z')" in
      __section_run)      dashboard_run_section ;;
      __section_data)     dashboard_data_section ;;
      __section_net)      dashboard_net_section ;;
      __section_settings) dashboard_settings_section ;;
      __focus_toggle)     [ "${DASH_FOCUS:-command}" = "components" ] && DASH_FOCUS="command" || DASH_FOCUS="components" ;;
      __up)              component_move up ;;
      __down)            component_move down ;;
      __left)            component_move left ;;
      __right)           component_move right ;;
      __enter)           dashboard_component_logs ;;
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

bootstrap_menu() {
  ensure_lang; check_update_status
  while true; do
    header_install
    printf '  %s%s%s\n\n' "$C_DIM" "$(t bm_hint)" "$C_RESET"
    printf '  %s[1]%s %s\n' "$C_CYAN" "$C_RESET" "$(t bm_new)"
    printf '  %s[2]%s %s\n' "$C_CYAN" "$C_RESET" "$(t bm_restore)"
    printf '  %s[3]%s %s\n' "$C_CYAN" "$C_RESET" "$(t bm_upgrade)"
    printf '  %s[4]%s %s\n' "$C_CYAN" "$C_RESET" "$(t bm_selfupdate)"
    printf '  %s[5]%s %s\n\n' "$C_CYAN" "$C_RESET" "$(t bm_lang)"
    printf '  %s[0]%s %s\n\n' "$C_CYAN" "$C_RESET" "$(t quit)"
    printf '%s: ' "$(t menu_choice)"
    local c=""; IFS= read -r c || exit 0
    case "$(trim "$c")" in
      1) perform_install; pause ;;
      2) restore_stack; pause ;;
      3) component_manager; pause ;;
      4) self_update; pause ;;
      5) choose_lang ;;
      0) exit 0 ;;
      *) echo "$(t no_such_item)"; pause ;;
    esac
  done
}

# ── component manager: toggle install/remove ──
cm_row() {
  local box="[ ]" tag=""
  [ "$2" = "true" ] && box="[x]"
  if [ "$2" != "$3" ]; then [ "$2" = "true" ] && tag="${C_GREEN}$(t cm_add)${C_RESET}" || tag="${C_RED}$(t cm_del)${C_RESET}"
  elif [ "$3" = "true" ]; then tag="${C_DIM}$(t cm_have)${C_RESET}"; fi
  printf '  %s %s[%s]%s %-22s %s\n' "$box" "$C_CYAN" "$1" "$C_RESET" "$4" "$tag"
}
component_manager() {
  load_config || { header_install; STACK_DIR="$(ask "Stack path" "$(default_stack_dir_for "$DEFAULT_STACK_NAME")")"; load_config || { echo "$(t no_env)"; return 1; }; }
  local t_owui="$ENABLE_OPENWEBUI" t_oh="$ENABLE_AGENTS" t_sx="$ENABLE_SEARCH" t_git="$ENABLE_GIT" t_qd="$ENABLE_QDRANT" t_mcp="$ENABLE_MCP"
  local o_owui="$t_owui" o_oh="$t_oh" o_sx="$t_sx" o_git="$t_git" o_qd="$t_qd" o_mcp="$t_mcp"
  while true; do
    sub_header "$(t cm_title)"
    cm_row 1 "$t_owui" "$o_owui" "Open WebUI"
    cm_row 2 "$t_oh"   "$o_oh"   "OpenHands"
    cm_row 3 "$t_sx"   "$o_sx"   "SearXNG"
    cm_row 4 "$t_git"  "$o_git"  "Forgejo (git)"
    cm_row 5 "$t_qd"   "$o_qd"   "Qdrant"
    cm_row 6 "$t_mcp"  "$o_mcp"  "MCP server"
    printf '\n%s\n%s: ' "$(t cm_hint)" "$(t menu_choice)"
    local line n; read_user_line line; line="$(trim "$line")"
    case "$line" in
      0) return 0 ;; "") break ;;
      *) for n in $line; do case "$n" in
           1) [ "$t_owui" = true ] && t_owui=false || t_owui=true ;;
           2) [ "$t_oh" = true ] && t_oh=false || t_oh=true ;;
           3) [ "$t_sx" = true ] && t_sx=false || t_sx=true ;;
           4) [ "$t_git" = true ] && t_git=false || t_git=true ;;
           5) [ "$t_qd" = true ] && t_qd=false || t_qd=true ;;
           6) [ "$t_mcp" = true ] && t_mcp=false || t_mcp=true ;;
         esac; done ;;
    esac
  done
  if [ "$t_owui$t_oh$t_sx$t_git$t_qd$t_mcp" = "$o_owui$o_oh$o_sx$o_git$o_qd$o_mcp" ]; then echo "$(t cm_nochange)"; return 0; fi
  ENABLE_OPENWEBUI="$t_owui"; ENABLE_AGENTS="$t_oh"; ENABLE_SEARCH="$t_sx"; ENABLE_GIT="$t_git"; ENABLE_QDRANT="$t_qd"; ENABLE_MCP="$t_mcp"
  [ "$ENABLE_QDRANT" = "true" ] || ENABLE_MCP="false"
  set_default_domains
  confirm "$(t q_start_install)" 'Y' || return 0
  check_dependencies || return 1
  write_all_configs; build_openhands_sandbox
  compose up -d --build --remove-orphans
  prune_disabled_services; reload_caddy
}

# ── security: switch profile (within the current deploy profile) + per-toggle ──
security_menu() {
  load_config || { echo "$(t no_env)"; return 1; }
  sub_header "$(t d_security)"
  printf '  %s: %s%s%s\n' "$(t sec_q)" "$C_B" "$SECURITY_PROFILE" "$C_RESET"
  choose_security_profile
  apply_security_to_host
  save_config
}
apply_security_to_host() {
  { [ "$SEC_CIS" = "true" ] || [ "$SEC_FIREWALL" = "true" ]; } && can_use_sudo && harden_host
  [ "$SEC_CIS" = "false" ] && [ "$SEC_FIREWALL" = "false" ] && can_use_sudo && harden_host --off
  if [ "$SEC_WATCHDOG" = "true" ]; then watchdog_enable >/dev/null 2>&1; else watchdog_disable >/dev/null 2>&1; fi
  write_all_configs >/dev/null 2>&1 || true
}

proxy_apply_quiet() {
  load_config || { echo "$(t no_env)"; return 1; }
  ensure_path_brew
  start_colima_if_needed

  local apply_stack="false" apply_web="false" explicit="false"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      stack) EGRESS_STACK="${2:-$EGRESS_STACK}"; apply_stack="true"; explicit="true"; shift 2 ;;
      web) EGRESS_WEB="${2:-$EGRESS_WEB}"; apply_web="true"; explicit="true"; shift 2 ;;
      route-local-llm) ROUTE_LOCAL_LLM="${2:-$ROUTE_LOCAL_LLM}"; shift 2 ;;
      *) shift ;;
    esac
  done
  if [ "$explicit" = "false" ]; then apply_stack="true"; apply_web="true"; fi

  compute_egress_endpoints
  write_all_configs >/dev/null || return 1
  build_openhands_sandbox >/dev/null 2>&1 || true

  local up_services="" app_services=""
  [ "$apply_stack" = "true" ] && egress_stack_enabled && up_services="$up_services proxy-stack"
  [ "$apply_web" = "true" ] && egress_web_enabled && up_services="$up_services proxy-web"
  if [ -n "$up_services" ]; then
    # shellcheck disable=SC2086
    compose up -d --build --remove-orphans $up_services >/dev/null 2>&1 || return 1
  fi

  if [ "$apply_stack" = "true" ] && stack_via_proxy && egress_stack_enabled; then
    [ "$ENABLE_OPENWEBUI" = "true" ] && app_services="$app_services openwebui"
    [ "$OPENHANDS_DOCKER_MODE" = "dind" ] && app_services="$app_services dind"
    [ "$ENABLE_AGENTS" = "true" ] && app_services="$app_services openhands"
  fi
  if [ "$apply_web" = "true" ] && web_via_proxy && egress_web_enabled; then
    [ "$ENABLE_SEARCH" = "true" ] && app_services="$app_services searxng"
  fi

  if [ -n "$app_services" ]; then
    local recreate_openhands="false"
    if printf '%s\n' "$app_services" | grep -qw openhands; then
      recreate_openhands="true"
      app_services="$(printf '%s\n' "$app_services" | tr ' ' '\n' | grep -v '^openhands$' | xargs || true)"
      compose rm -sf openhands >/dev/null 2>&1 || true
    fi
    # shellcheck disable=SC2086
    if [ -n "$app_services" ]; then
      compose up -d --no-deps --force-recreate $app_services >/dev/null 2>&1 || return 1
    fi
    if [ "$recreate_openhands" = "true" ]; then
      compose up -d --no-deps openhands >/dev/null 2>&1 || return 1
    fi
  fi

  prune_disabled_services >/dev/null 2>&1 || true
  printf 'proxy-stack=%s proxy-web=%s\n' "$EGRESS_STACK" "$EGRESS_WEB"
}

# ── proxy management: enable/disable + configure each, then apply ──
proxy_menu() {
  load_config || { echo "$(t no_env)"; return 1; }
  while true; do
    sub_header "$(t px_title)"
    printf '  %s[1]%s proxy-stack  %s%s%s  %s(%s)%s\n' "$C_CYAN" "$C_RESET" "$C_B" "$(proxy_label "$EGRESS_STACK")" "$C_RESET" "$C_DIM" "$(t px_stack)" "$C_RESET"
    printf '  %s[2]%s proxy-web    %s%s%s  %s(%s)%s\n' "$C_CYAN" "$C_RESET" "$C_B" "$(proxy_label "$EGRESS_WEB")" "$C_RESET" "$C_DIM" "$(t px_web)" "$C_RESET"
    printf '  %s[3]%s %s: %s\n' "$C_CYAN" "$C_RESET" "$(t px_local_q)" "$(bool_label "$ROUTE_LOCAL_LLM")"
    printf '  %s[4]%s apply   %s[0]%s %s\n\n%s: ' "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" "$(t m_back)" "$(t menu_choice)"
    local c; IFS= read -r c || return 0
    case "$(trim "$c")" in
      1) choose_egress_slot stack '0'; configure_egress_secrets stack ;;
      2) choose_egress_slot web '0'; configure_egress_secrets web ;;
      3) [ "$ROUTE_LOCAL_LLM" = "true" ] && ROUTE_LOCAL_LLM="false" || ROUTE_LOCAL_LLM="true" ;;
      4) compute_egress_endpoints; write_all_configs; build_openhands_sandbox; compose up -d --build --remove-orphans; prune_disabled_services; reload_caddy; return 0 ;;
      0|"") return 0 ;;
      *) : ;;
    esac
  done
}

watchdog_menu() {
  load_config || { echo "$(t no_env)"; return 1; }
  sub_header "$(t d_watchdog)"
  printf '  %s: %s%s%s\n\n' "$(t sec_wd_l)" "$C_B" "$(watchdog_state)" "$C_RESET"
  menu_line "" 1 "$(t on)" 2 "$(t off)" 0 "$(t m_back)"
  printf '%s: ' "$(t menu_choice)"
  local c; IFS= read -r c || return 0
  case "$(trim "$c")" in 1) watchdog_enable ;; 2) watchdog_disable ;; *) : ;; esac
}

print_help() {
  local cmd="$MGMT_NAME" w=40
  printf '%s%s%s v%s %s\n\n' "$C_B" "$PRODUCT_NAME" "$C_RESET" "$STACK_VERSION" "$STACK_CHANNEL"
  printf '  Usage: %s%s%s [command]\n  No command — interactive menu.\n\n' "$C_B" "$cmd" "$C_RESET"
  printf "    %-${w}s install (interactive)\n"  "$cmd install"
  printf "    %-${w}s install with defaults\n"  "$cmd install --defaults"
  printf "    %-${w}s start / stop / restart\n" "$cmd start|stop|restart"
  printf "    %-${w}s container status / logs\n" "$cmd status|logs [svc]"
  printf "    %-${w}s update images and rebuild\n" "$cmd update"
  printf "    %-${w}s install/remove components\n" "$cmd upgrade"
  printf "    %-${w}s backup / restore (7z)\n" "$cmd backup|restore"
  printf "    %-${w}s egress proxies\n"        "$cmd proxy"
  printf "    %-${w}s security profile\n"      "$cmd security"
  printf "    %-${w}s secrets seal / unseal\n" "$cmd seal|unseal"
  printf "    %-${w}s isolate agents on a VPS (WireGuard)\n" "$cmd agents --host IP"
  printf "    %-${w}s uninstall stack (data kept)\n" "$cmd uninstall [--data|--dry-run]"
  printf "    %-${w}s language ru|en\n"        '--lang ru|en'
  printf '\n'
}
usage() { print_help; }
