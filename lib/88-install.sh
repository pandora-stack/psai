# ───────────────────────────── install flow (steps 0–5) ─────────────────────────────

# Optional: choose your own admin password. When set it becomes the Caddy/basic-auth gate
# for protected browser UIs (OpenHands/Qdrant, and Open WebUI only on public deployments).
# Open WebUI's own first admin is created by the first browser registration.
ask_admin_password() {
  [ "$NONINTERACTIVE" = "1" ] && return 0
  confirm "$(t admin_pw_q)" 'Y' || return 0
  read_secret_confirmed ADMIN_PASSWORD_PLAIN "$(t pw_label)"
  return 0
}

stack_config_in_dir() {
  local d="${1:-}"
  [ -n "$d" ] || return 1
  if [ -f "$d/.stack.env" ]; then printf '%s/.stack.env' "$d"; return 0; fi
  if [ -f "$d/../.stack.env" ]; then (cd "$d/.." 2>/dev/null && printf '%s/.stack.env' "$(pwd)"); return 0; fi
  return 1
}

detect_installed_stack() {
  local cand link dir cfg
  for cand in "${STACK_DIR:-}" "$HOME/$DEFAULT_STACK_NAME"; do
    cfg="$(stack_config_in_dir "$cand" 2>/dev/null || true)"
    [ -n "$cfg" ] || continue
    STACK_DIR="$(cd "$(dirname "$cfg")" 2>/dev/null && pwd)" || continue
    load_config >/dev/null 2>&1 && return 0
  done
  if command_exists "$MGMT_NAME"; then
    link="$(command -v "$MGMT_NAME" 2>/dev/null || true)"
    [ -n "$link" ] || return 1
    dir="$(_psai_resolve_dir "$link")"
    for cand in "$dir" "$dir/.."; do
      cfg="$(stack_config_in_dir "$cand" 2>/dev/null || true)"
      [ -n "$cfg" ] || continue
      STACK_DIR="$(cd "$(dirname "$cfg")" 2>/dev/null && pwd)" || continue
      load_config >/dev/null 2>&1 && return 0
    done
  fi
  return 1
}

cleanup_invoked_installer() {
  [ -n "${STACK_DIR:-}" ] || return 0
  local p="$SCRIPT_PATH" installed="$STACK_DIR/bin/$MGMT_NAME"
  [ -n "$p" ] || return 0
  [ -f "$p" ] || return 0
  [ -f "$installed" ] && [ "$p" -ef "$installed" ] 2>/dev/null && return 0
  case "$p" in
    /tmp/*|/private/tmp/*|/var/folders/*/T/*) rm -f "$p" 2>/dev/null || true ;;
  esac
}

handoff_to_installed_dashboard() {
  cleanup_invoked_installer
  is_interactive || return 0
  printf '\n  %s%s%s\n' "$C_DIM" "$(t fin_dashboard)" "$C_RESET"
  exec "$STACK_DIR/bin/$MGMT_NAME"
}

post_install_handoff() {
  if [ "$ENABLE_OPENWEBUI" = "true" ]; then
    printf '  %s%s%s\n' "$C_YELLOW" "$(t fin_openwebui_register)" "$C_RESET"
  fi
  if [ "$ENABLE_GIT" = "true" ]; then
    printf '  %s%s%s\n' "$C_YELLOW" "$(t fin_git_register)" "$C_RESET"
  fi
  if ! is_interactive; then return 0; fi
  confirm "$(t q_open_dashboard)" 'Y' || return 0
  handoff_to_installed_dashboard
}

reinstall_keep_data() {
  printf '\n%s%s%s\n' "$C_B" "$(t reinstall_start)" "$C_RESET"
  update_rebuild || return 1
  finish_message
  post_install_handoff
}

reinstall_purge_data() {
  local old="$STACK_DIR"
  uninstall_stack --yes --data --dir "$old" || return 1
  INSTALL_SKIP_EXISTING_CHECK=true perform_install
}

existing_install_flow() {
  [ "${INSTALL_SKIP_EXISTING_CHECK:-false}" = "true" ] && return 1
  detect_installed_stack || return 1
  if [ "$NONINTERACTIVE" = "1" ]; then
    case "${PSAI_REINSTALL:-}" in
      keep|yes|true|1) reinstall_keep_data; return 0 ;;
      purge|clean|data|reset) reinstall_purge_data; return 0 ;;
      *) printf '%s%s%s\n' "$C_YELLOW" "$(t reinstall_noninteractive)" "$C_RESET" >&2; return 1 ;;
    esac
  fi
  sub_header "$(t reinstall_found)"
  printf '  %s%s%s\n\n' "$C_DIM" "$STACK_DIR" "$C_RESET"
  printf '  %s[1]%s %s\n' "$C_CYAN" "$C_RESET" "$(t reinstall_keep)"
  printf '  %s[2]%s %s\n' "$C_CYAN" "$C_RESET" "$(t reinstall_purge)"
  printf '  %s[3]%s %s\n' "$C_CYAN" "$C_RESET" "$(t reinstall_open)"
  printf '  %s[0]%s %s\n\n' "$C_CYAN" "$C_RESET" "$(t reinstall_cancel)"
  printf '%s: ' "$(t menu_choice)"
  local c=""; read_user_line c; c="$(trim "$c")"
  case "$c" in
    1) reinstall_keep_data ;;
    2) reinstall_purge_data ;;
    3) installed_menu ;;
    0|"") echo "$(t cancelled)" ;;
    *) echo "$(t cancelled)" ;;
  esac
  return 0
}

ensure_install_vault_pass() {
  vault_enabled || return 0
  [ -f "$STACK_DIR/secrets/kms.conf" ] && return 0
  [ -n "${SEAL_PASS_PLAIN:-${PSAI_VAULT_PASS:-}}" ] && return 0
  if [ "$NONINTERACTIVE" = "1" ]; then
    printf '%s%s%s\n' "$C_RED" "$(t vault_need_pass)" "$C_RESET" >&2
    return 1
  fi
  printf '  %s%s%s\n' "$C_DIM" "$(t vault_passhint)" "$C_RESET"
  read_secret_confirmed SEAL_PASS_PLAIN "$(t vault_pass)"
}

print_vault_log_tail() {
  local log; log="$(vault_log)"
  [ -s "$log" ] || return 0
  printf '%s--- vault log: %s ---%s\n' "$C_DIM" "$log" "$C_RESET" >&2
  tail -n 20 "$log" >&2 || true
}

# STEP 1 — node.
choose_node() {
  printf '\n%s%s%s\n' "$C_B" "$(t step1_title)" "$C_RESET"
  menu_line "$(t node_q)" 1 "$(t node_single)" 2 "$(t node_multi)"
  local c; c="$(ask "$(t node_q)" '1')"
  case "$(printf '%s' "$c" | tr -d '[][:space:]' | tr 'A-Z' 'a-z')" in
    2|multi|multiple) NODE_MODE="multi" ;;
    *)                NODE_MODE="single" ;;
  esac
  if [ "$NODE_MODE" = "multi" ]; then
    printf '  %s%s%s\n' "$C_DIM" "$(t node_multi_note)" "$C_RESET"
    printf '  %s%s%s\n' "$C_DIM" "$(t node_multi_pub)" "$C_RESET"
    DEPLOY_PROFILE="public"; ENABLE_AGENTS="true"
  fi
  prompt_set STACK_NAME "$(t q_stack_name)" "$DEFAULT_STACK_NAME"
  SAFE_STACK_NAME="$(safe_name "$STACK_NAME")"; [ -z "$SAFE_STACK_NAME" ] && SAFE_STACK_NAME="$DEFAULT_STACK_NAME"
  prompt_set STACK_DIR "$(t q_stack_dir)" "$(default_stack_dir_for "$SAFE_STACK_NAME")"
  STACK_DIR="${STACK_DIR/#\~/$HOME}"
  prompt_set ADMIN_USER "$(t q_admin_user)" "$DEFAULT_ADMIN_USER"
  ask_admin_password
  return 0   # never let a trailing non-zero abort the installer under set -e
}

# STEP 2 — deployment profile.
choose_deploy_profile() {
  if [ "$NODE_MODE" = "multi" ]; then DEPLOY_PROFILE="public"; else
    printf '\n%s%s%s\n' "$C_B" "$(t step2_title)" "$C_RESET"
    menu_line "$(t prof_q)" 1 "$(t prof_local)" 2 "$(t prof_public)"
    local c; c="$(ask "$(t prof_q)" '1')"
    case "$(printf '%s' "$c" | tr -d '[][:space:]' | tr 'A-Z' 'a-z')" in
      2|public|pub) DEPLOY_PROFILE="public" ;;
      *)            DEPLOY_PROFILE="local" ;;
    esac
  fi
  if [ "$DEPLOY_PROFILE" = "public" ]; then ask_public_domain; fi
  return 0   # MUST end 0: under `set -e` a non-zero return here (e.g. the local-profile
             # case where the public check is false) aborts the whole installer.
}

ask_public_domain() {
  prompt_set PUBLIC_DOMAIN "$(t pub_domain_q)" ""
  if [ -z "$PUBLIC_DOMAIN" ]; then
    TLS_MODE="self"; printf '  %s%s%s\n' "$C_YELLOW" "$(t pub_noip)" "$C_RESET"; return 0
  fi
  PUBLIC_DOMAIN="$(normalize_zone "$PUBLIC_DOMAIN")"; TLS_MODE="le"
  prompt_set ACME_EMAIL "$(t pub_email)" "$ACME_EMAIL"
  # A-record reminder + best-effort check against the host IP.
  printf '  %s%s%s\n    %sai.%s  A  →  %s%s\n' "$C_DIM" "$(t pub_arecord)" "$C_RESET" "$C_DIM" "$PUBLIC_DOMAIN" "$(host_ip)" "$C_RESET"
  local got; got="$(check_arecord "psai.$PUBLIC_DOMAIN")"
  if [ -n "$got" ]; then printf '  %s%s (%s)%s\n' "$C_GREEN" "$(t pub_arecord_ok)" "$got" "$C_RESET"
  else printf '  %s%s%s\n' "$C_YELLOW" "$(t pub_arecord_no)" "$C_RESET"; fi
}

# AI section: check the hardware, then offer a bundled local LLM (Ollama) + a model that fits.
# Sets LOCAL_LLM (ollama/none) + OLLAMA_MODEL + GPU_MODE so the memory backend and chat use it.
choose_local_ai() {
  GPU_MODE="$(gpu_runtime)"
  printf '\n  %s%s%s\n' "$C_B$C_CYAN" "$(t ai_title)" "$C_RESET"
  if [ "$GPU_MODE" = "nvidia" ]; then printf '  %s%s%s\n' "$C_GREEN" "$(t ai_gpu_nvidia)" "$C_RESET"
  else
    detect_os
    [ "$OS_TYPE" = "macos" ] && printf '  %s%s%s\n' "$C_YELLOW" "$(t ai_cpu_mac)" "$C_RESET" \
                              || printf '  %s%s%s\n' "$C_YELLOW" "$(t ai_cpu_linux)" "$C_RESET"
  fi
  if ! confirm "$(t q_local_ai)" 'Y'; then LOCAL_LLM="none"; return 0; fi
  LOCAL_LLM="ollama"
  local def; def="$(gpu_default_model)"
  if confirm "$(t q_ai_model_def) $def?" 'Y'; then OLLAMA_MODEL="$def"
  else OLLAMA_MODEL="$(ask "$(t q_ai_model)" "$def")"; [ -z "$OLLAMA_MODEL" ] && OLLAMA_MODEL="$def"; fi
  printf '  %s%s%s\n' "$C_DIM" "$(t ai_pull_note)" "$C_RESET"
  return 0
}

# Force every additional/advanced component off — the answer when the operator declines extras.
extras_default_off() {
  ENABLE_QDRANT="false"; RAG_MODE="off"; ENABLE_EMBEDDINGS="false"; SHARED_MEMORY="false"
  MEMORY_MODE="none"; ENABLE_MCP="false"; LOCAL_LLM="none"
  MCP_GATEWAY="false"; LLM_GATEWAY="false"; ENABLE_EVAL="false"; ENABLE_PENTEST="false"
  return 0
}

# STEP 3 — components. Core (chat/agents/search/git) default yes; everything else lives behind
# the "additional components?" gate (default no).
choose_components() {
  printf '\n%s%s%s\n' "$C_B" "$(t step3_title)" "$C_RESET"
  confirm "$(t q_openwebui)" 'Y' && ENABLE_OPENWEBUI="true" || ENABLE_OPENWEBUI="false"
  if [ "$NODE_MODE" = "multi" ]; then ENABLE_AGENTS="true"   # agents are the point of multi-node
  else confirm "$(t q_agents)" 'Y' && ENABLE_AGENTS="true" || ENABLE_AGENTS="false"; fi
  if [ "$ENABLE_AGENTS" = "true" ]; then
    confirm "$(t q_web_oh)" 'Y' && AGENT_WEB="true" || AGENT_WEB="false"
    [ "$NODE_MODE" = "multi" ] && prompt_set OPENHANDS_LLM_MODEL "$(t q_oh_model)" "$OPENHANDS_LLM_MODEL"
  fi
  confirm "$(t q_search)" 'Y' && ENABLE_SEARCH="true" || ENABLE_SEARCH="false"
  if confirm "$(t q_git)" 'Y'; then
    ENABLE_GIT="true"; prompt_set GIT_SSH_PORT "$(t q_git_ssh_port)" "$DEFAULT_GIT_SSH_PORT"
    # multi: git lives on master OR moves to the agent worker node (one git either way).
    [ "$NODE_MODE" = "multi" ] && { confirm "$(t q_git_on_agent)" 'N' && ISOLATE_GIT="true" || ISOLATE_GIT="false"; }
  else ENABLE_GIT="false"; GIT_SSH_PORT="$DEFAULT_GIT_SSH_PORT"; fi

  # ── Additional / advanced components ──────────────────────────────────────────────
  # One gate, default OFF, so a plain install stays simple (chat + agents + search + git).
  # Yes → vector memory / RAG-plus, a memory backend + local LLM, MCP/LLM gateways, eval.
  if ! confirm "$(t q_extras)" 'Y'; then extras_default_off; return 0; fi
  printf '  %s%s%s\n' "$C_B$C_CYAN" "$(t q_extras_title)" "$C_RESET"
  choose_local_ai   # AI section: hardware check → bundle Ollama + a fitting model (memory reuses it)
  # Shared vector memory.
  if [ "$NODE_MODE" = "multi" ]; then
    confirm "$(t ra_shared_q)" 'N' && { SHARED_MEMORY="true"; ENABLE_QDRANT="true"; } || SHARED_MEMORY="false"
  else
    if confirm "$(t q_qdrant)" 'Y'; then
      ENABLE_QDRANT="true"
      printf '  %s%s%s\n' "$C_DIM" "$(rag_plus_hint_text)" "$C_RESET"
      confirm "$(t q_rag_plus)" "$(rag_plus_default_answer)" && RAG_MODE="plus" || RAG_MODE="basic"
    else ENABLE_QDRANT="false"; RAG_MODE="off"; fi
  fi
  if [ "$ENABLE_QDRANT" = "true" ]; then
    # In rag-plus the local embed service handles embeddings — don't also ask for the built-in.
    [ "$RAG_MODE" = "plus" ] || { confirm "$(t q_embeddings)" 'N' && ENABLE_EMBEDDINGS="true" || ENABLE_EMBEDDINGS="false"; }
  else ENABLE_EMBEDDINGS="false"; fi
  # Memory backend (shared by chat + agents). One selector replaces the old MCP-stub toggle.
  if [ "$ENABLE_AGENTS" = "true" ] || [ "$ENABLE_OPENWEBUI" = "true" ]; then
    printf '  %s%s%s\n' "$C_DIM" "$(t q_memory_hint)" "$C_RESET"
    local mc; mc="$(ask "$(t q_memory)" "$([ "$ENABLE_QDRANT" = "true" ] && printf cognee || printf none)")"
    case "$(printf '%s' "$mc" | tr -d '[:space:]' | tr 'A-Z' 'a-z')" in
      cognee)   MEMORY_MODE="cognee"; ENABLE_MCP="false" ;;
      graphiti) MEMORY_MODE="graphiti"; ENABLE_MCP="false" ;;
      mem0)     MEMORY_MODE="mem0"; ENABLE_MCP="false" ;;
      stub)     if [ "$ENABLE_QDRANT" = "true" ]; then MEMORY_MODE="stub"; ENABLE_MCP="true"
                else printf '  %s%s%s\n' "$C_YELLOW" "$(t q_memory_stub_needs_qdrant)" "$C_RESET"; MEMORY_MODE="none"; ENABLE_MCP="false"; fi ;;
      *)        MEMORY_MODE="none"; ENABLE_MCP="false" ;;
    esac
    case "$MEMORY_MODE" in
      cognee|graphiti)
        # Bundle a local LLM (Ollama, no cloud key) or point at an external endpoint (LM Studio/cloud).
        if [ "$LOCAL_LLM" = "ollama" ] || confirm "$(t q_bundle_ollama)" 'Y'; then LOCAL_LLM="ollama"
        else
          printf '  %s%s%s\n' "$C_DIM" "$(t q_ext_llm_hint)" "$C_RESET"
          [ -n "$MEMORY_LLM_URL" ] || MEMORY_LLM_URL="$(ask "$(t q_memory_llm_url)" '')"
          [ -n "$MEMORY_LLM_KEY" ] || MEMORY_LLM_KEY="$(ask "$(t q_memory_llm_key)" '')"
        fi ;;
      mem0) [ -n "$MEM0_MCP_URL" ] || MEM0_MCP_URL="$(ask "$(t q_mem0_url)" '')" ;;
    esac
  else ENABLE_MCP="false"; MEMORY_MODE="none"; fi
  # Verified tool servers for the agents (Docker MCP Gateway). Needs the host socket.
  if [ "$ENABLE_AGENTS" = "true" ]; then
    printf '  %s%s%s\n' "$C_DIM" "$(t q_gateway_hint)" "$C_RESET"
    confirm "$(t q_gateway)" 'Y' && MCP_GATEWAY="true" || MCP_GATEWAY="false"
    confirm "$(t q_litellm)" 'Y' && LLM_GATEWAY="true" || LLM_GATEWAY="false"
    confirm "$(t q_eval)" 'Y' && ENABLE_EVAL="true" || ENABLE_EVAL="false"
  else MCP_GATEWAY="false"; LLM_GATEWAY="false"; ENABLE_EVAL="false"; fi
  if confirm "$(t q_pentest)" 'N'; then printf '  %s%s%s\n' "$C_RED" "$(t pentest_warn)" "$C_RESET"; ENABLE_PENTEST="true"; else ENABLE_PENTEST="false"; fi
  return 0   # never let a trailing non-zero abort the installer under set -e
}

# STEP 5 — zone & domains. Local zone stays the default (lan); a public domain fixes the
# zone. Local deployments may skip domains entirely → services on localhost ports.
choose_zone() {
  printf '\n%s%s%s\n' "$C_B" "$(t step5_title)" "$C_RESET"
  if [ "$DEPLOY_PROFILE" = "public" ] && [ -n "${PUBLIC_DOMAIN:-}" ]; then
    NO_DOMAIN="false"; DOMAIN_ZONE="$PUBLIC_DOMAIN"
  else
    # Local: domains are optional. Decline → reach services on http://localhost:PORT.
    if ! confirm "$(t q_use_domains)" 'Y'; then
      NO_DOMAIN="true"; DOMAIN_ZONE="localhost"
      printf '  %s%s%s\n' "$C_DIM" "$(t dom_localhost_note)" "$C_RESET"
      set_default_domains
      print_active_domains
      return 0
    fi
    NO_DOMAIN="false"; DOMAIN_ZONE="$DEFAULT_DOMAIN_ZONE"
  fi
  printf '  %s: %s%s%s\n' "$(t q_zone_def)" "$C_B" "$DOMAIN_ZONE" "$C_RESET"
  set_default_domains
  confirm_domains_loop
  if ! caddy_use_acme && [ "${TLS_MODE:-}" != "own" ]; then
    prompt_set CERT_YEARS "$(t cert_lifetime)" "$DEFAULT_CERT_YEARS"
    printf '%s' "$CERT_YEARS" | grep -Eq '^[0-9]+$' || CERT_YEARS="$DEFAULT_CERT_YEARS"
  else CERT_YEARS="$DEFAULT_CERT_YEARS"; fi
  return 0   # never let a trailing non-zero abort the installer under set -e
}

show_summary() {
  local ops=""
  summary_csv() { printf '%s' "$1" | sed 's/, */, /g'; }
  summary_row() {
    local label="$1" value="$2"
    printf '  '
    pad_right "$label:" 14
    printf ' %s\n' "$value"
  }
  printf '\n%s%s%s\n' "$C_B" "$(t sum_header)" "$C_RESET"
  summary_row "$(t sum_name)" "$STACK_NAME"
  summary_row "$(t sum_dir)" "$STACK_DIR"
  summary_row "$(t sum_node)" "$NODE_MODE"
  summary_row "$(t sum_profile)" "$DEPLOY_PROFILE"
  summary_row "$(t sec_q)" "$SECURITY_PROFILE"
  summary_row "$(t sum_zone)" "$DOMAIN_ZONE"
  summary_row "$(t sum_components)" "OpenWebUI: $(bool_label "$ENABLE_OPENWEBUI"), OpenHands: $(bool_label "$ENABLE_AGENTS"), Search: $(bool_label "$ENABLE_SEARCH"), Git: $(bool_label "$ENABLE_GIT"), Qdrant: $(bool_label "$ENABLE_QDRANT"), MCP: $(bool_label "$ENABLE_MCP")"
  [ "${RAG_MODE:-off}" != "off" ] && summary_row "RAG" "$RAG_MODE"
  case "${MEMORY_MODE:-stub}" in stub|none) : ;; *) summary_row "$(t sum_memory)" "$MEMORY_MODE" ;; esac
  [ "${LOCAL_LLM:-none}" = "ollama" ] && summary_row "LLM" "ollama: $OLLAMA_MODEL"
  [ "${MCP_GATEWAY:-false}" = "true" ] && summary_row "$(t sum_mcp_gateway)" "$(summary_csv "$MCP_GATEWAY_SERVERS")"
  [ "${LLM_GATEWAY:-false}" = "true" ] && ops="LiteLLM"
  [ "${ENABLE_EVAL:-false}" = "true" ] && ops="${ops:+$ops, }Langfuse"
  [ -n "$ops" ] && summary_row "$(t sum_ops)" "$ops"
  summary_row "$(t sum_proxies)" "stack: $EGRESS_STACK, web: $EGRESS_WEB"
  print_active_domains
  printf '\n'
}

install_prompt_flow() {
  # The prompt phase is pure UI — it collects input and sets variables, it does not write
  # files or touch docker. `set -Eeuo pipefail` (armed globally) is unforgiving here: any
  # menu/preview helper whose last statement is a `cond && cmd` (false on the common path)
  # returns non-zero and, called as a bare command, aborts the whole installer mid-prompt.
  # Disable errexit for the collection, re-arm it before the real install work begins.
  set +e
  header_install
  step0_env || { printf '%s\n' "$(t install_cancel)"; set -e; exit 1; }   # STEP 0
  choose_node                 # STEP 1
  choose_deploy_profile       # STEP 2
  choose_components           # STEP 3
  choose_security_profile     # STEP 4
  choose_zone                 # STEP 5
  ask_proxies                 # two egress proxies (default direct)
  show_summary
  set -e                      # re-arm before perform_install does the real work
  confirm "$(t q_start_install)" 'Y' || { echo "$(t install_cancel)"; exit 0; }
}

apply_defaults_noninteractive() {
  STACK_NAME="${STACK_NAME:-$DEFAULT_STACK_NAME}"
  SAFE_STACK_NAME="$(safe_name "$STACK_NAME")"; [ -z "$SAFE_STACK_NAME" ] && SAFE_STACK_NAME="$DEFAULT_STACK_NAME"
  STACK_DIR="${STACK_DIR:-$(default_stack_dir_for "$SAFE_STACK_NAME")}"; STACK_DIR="${STACK_DIR/#\~/$HOME}"
  ADMIN_USER="${ADMIN_USER:-$DEFAULT_ADMIN_USER}"
  # `install --defaults` = a COMPLETE LOCAL stack: NO security profile, EVERY component on,
  # reachable both by the .lan domains AND on localhost ports. Each value still honours an
  # explicit PSAI_* override (so the multi-node agent install, which sets them, is unaffected).
  if [ "$NODE_MODE" != "multi" ]; then
    DEPLOY_PROFILE="${PSAI_DEPLOY:-local}"
    SECURITY_PROFILE="${PSAI_PROFILE:-none}"
    ENABLE_OPENWEBUI="${PSAI_OPENWEBUI:-true}"; ENABLE_AGENTS="${PSAI_AGENTS:-true}"
    ENABLE_SEARCH="${PSAI_SEARCH:-true}"; ENABLE_GIT="${PSAI_GIT:-true}"
    ENABLE_QDRANT="${PSAI_QDRANT:-true}"
    RAG_MODE="${PSAI_RAG:-plus}"; MEMORY_MODE="${PSAI_MEMORY:-cognee}"; LOCAL_LLM="${PSAI_LLM:-ollama}"
    ROUTE_LOCAL_LLM="${PSAI_ROUTE_LOCAL_LLM:-true}"
    OLLAMA_MODEL="${PSAI_OLLAMA_MODEL:-$(gpu_default_model)}"   # platform-aware local default
    MCP_GATEWAY="${PSAI_MCP_GATEWAY:-true}"; LLM_GATEWAY="${PSAI_LLM_GATEWAY:-true}"; ENABLE_EVAL="${PSAI_EVAL:-true}"
    NO_DOMAIN="${PSAI_NO_DOMAIN:-false}"
    [ "$DEPLOY_PROFILE" = "local" ] && DUAL_ACCESS="${PSAI_DUAL:-true}"
  fi
  [ "$NODE_MODE" = "multi" ] && { DEPLOY_PROFILE="public"; ENABLE_AGENTS="true"; }
  resolve_security_profile
  GIT_SSH_PORT="${GIT_SSH_PORT:-$DEFAULT_GIT_SSH_PORT}"
  if [ "$DEPLOY_PROFILE" = "public" ] && [ -n "${PUBLIC_DOMAIN:-}" ]; then DOMAIN_ZONE="$PUBLIC_DOMAIN"; else DOMAIN_ZONE="${DOMAIN_ZONE:-$DEFAULT_DOMAIN_ZONE}"; fi
  [ -z "${PUBLIC_DOMAIN:-}" ] && [ "$DEPLOY_PROFILE" = "public" ] && TLS_MODE="self"
  set_default_domains
  CERT_YEARS="${CERT_YEARS:-$DEFAULT_CERT_YEARS}"
  compute_egress_endpoints
}

host_port_busy() {
  local port="$1"
  if command_exists lsof && lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    return 0
  fi
  if command_exists ss && ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"; then
    return 0
  fi
  if command_exists netstat && netstat -an 2>/dev/null | grep -E "[.:]${port}[[:space:]].*LISTEN" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

pick_free_port() {
  local port="$1" reserved="${2:-}"
  while host_port_busy "$port" || printf '%s' " $reserved " | grep -Fq " $port "; do
    port=$((port + 1))
  done
  printf '%s' "$port"
}

avoid_local_loopback_port_conflicts() {
  [ "${DEPLOY_PROFILE:-local}" != "public" ] || return 0
  { no_domain || dual_access; } || return 0
  local changed="false" reserved="" current="" next=""

  current="$PORT_PSAI"
  if host_port_busy "$current"; then
    next="$(pick_free_port 18080 "$reserved")"; PORT_PSAI="$next"; changed="true"
  fi
  reserved="$reserved $PORT_PSAI"

  current="$PORT_AGENTS"
  if host_port_busy "$current"; then
    next="$(pick_free_port 18081 "$reserved")"; PORT_AGENTS="$next"; changed="true"
  fi
  reserved="$reserved $PORT_AGENTS"

  current="$PORT_GIT"
  if host_port_busy "$current"; then
    next="$(pick_free_port 18082 "$reserved")"; PORT_GIT="$next"; changed="true"
  fi
  reserved="$reserved $PORT_GIT"

  current="$PORT_QDRANT"
  if host_port_busy "$current"; then
    next="$(pick_free_port 18083 "$reserved")"; PORT_QDRANT="$next"; changed="true"
  fi

  if [ "$changed" = "true" ]; then
    printf '%s%s: Open WebUI=%s OpenHands=%s Git=%s Qdrant=%s%s\n' \
      "$C_YELLOW" "$(t port_loopback_busy)" "$PORT_PSAI" "$PORT_AGENTS" "$PORT_GIT" "$PORT_QDRANT" "$C_RESET" >&2
  fi
}

avoid_local_caddy_port_conflict() {
  [ "${DEPLOY_PROFILE:-local}" != "public" ] || return 0
  if command_exists docker && docker ps --format '{{.Names}}' 2>/dev/null | grep -Fxq "${SAFE_STACK_NAME}-caddy"; then
    return 0
  fi
  if ! no_domain && { host_port_busy 80 || host_port_busy 443; }; then
    if [ "${NONINTERACTIVE:-0}" = "1" ] || [ "${ASSUME_DEFAULTS:-0}" = "1" ]; then
      NO_DOMAIN="true"
      DUAL_ACCESS="false"
      DOMAIN_ZONE="localhost"
      set_default_domains
      printf '%s%s%s\n' "$C_YELLOW" "$(t port_web_busy)" "$C_RESET" >&2
    else
      printf '%s%s%s\n' "$C_RED" "$(t port_web_busy_domains)" "$C_RESET" >&2
      return 1
    fi
  fi
  avoid_local_loopback_port_conflicts
}

perform_install() {
  if [ "${INSTALL_SKIP_EXISTING_CHECK:-false}" != "true" ] && detect_installed_stack; then
    existing_install_flow
    return $?
  fi

  if [ "$NONINTERACTIVE" = "1" ] || [ "$ASSUME_DEFAULTS" = "1" ]; then
    NONINTERACTIVE="1"; apply_defaults_noninteractive
    check_dependencies || return 1
  else
    install_prompt_flow
  fi

  resolve_oh_mode   # public/multi → dind unless PSAI_OH_MODE pinned (persisted by write_all_configs)
  resolve_rag_mode  # PSAI_RAG=plus → Qdrant + local embeddings/reranker + Docling/Tika ingest
  resolve_local_llm    # PSAI_LLM=ollama → bundle a local LLM; point memory at it
  resolve_memory_mode  # PSAI_MEMORY=cognee/graphiti/mem0 → real memory backend (replaces the stub)
  if [ "${MCP_GATEWAY:-false}" = "true" ] && [ "$DEPLOY_PROFILE" = "public" ]; then
    printf '%s%s%s\n' "$C_YELLOW" "$(t gateway_public_warn)" "$C_RESET"
  fi
  if [ "${ENABLE_AGENTS:-false}" = "true" ] && [ "${AGENTS_DOCKER:-false}" = "true" ] && [ "$DEPLOY_PROFILE" = "public" ]; then
    printf '%s%s%s\n' "$C_YELLOW" "$(t agents_docker_public_warn)" "$C_RESET"
  fi
  if ollama_enabled && [ "$DEPLOY_PROFILE" = "public" ]; then
    printf '%s%s%s\n' "$C_YELLOW" "$(t ollama_auth_proxy_warn)" "$C_RESET"
  fi
  capture_docker_context   # pin the docker daemon (Colima vs Docker Desktop) for later runs

  if [ -f "$STACK_DIR/.stack.env" ] && [ "$NONINTERACTIVE" != "1" ]; then
    printf '\n'; confirm "$(t q_overwrite)" 'Y' || exit 0
  fi

  # Unseal stack-vault BEFORE any secret is generated, so nothing plaintext hits disk.
  # Run in the foreground (it may prompt for the passphrase) — not inside run_step.
  if vault_enabled; then
    mkdir -p "$STACK_DIR/bin" "$STACK_DIR/data/logs"
    vault_present || build_vault || true
    ensure_install_vault_pass || return 1
    vault_start || { print_vault_log_tail; printf '%svault required but not unsealed — aborting%s\n' "$C_RED" "$C_RESET"; return 1; }
  fi

  if ingest_enabled; then STEP_TOTAL=7; else STEP_TOTAL=6; fi
  STEP_NUM=0
  run_step "$(t step_dirs)"     prepare_dirs_and_secrets
  run_step "$(t step_configs)"  write_all_configs
  run_step "$(t step_sandbox)"  build_openhands_sandbox
  run_step "$(t step_compose)"  validate_compose
  run_pull_step || return 1

  # /etc/hosts (local profile with domains). No-domain installs use localhost ports only.
  if [ "$DEPLOY_PROFILE" != "public" ] && ! no_domain; then
    if can_use_sudo; then
      if [ "$NONINTERACTIVE" = "1" ] || confirm "$(t q_add_hosts)" 'Y'; then
        add_hosts_entries
      fi
    else print_hosts_command; fi
  fi

  run_step "$(t step_up)" compose_up_core
  if ingest_enabled; then
    if ! run_step "$(t step_ingest)" compose_up_ingest; then
      printf '%s%s%s\n' "$C_YELLOW" "$(t ingest_deferred)" "$C_RESET" >&2
    fi
  fi
  prune_disabled_services

  # Apply the security profile to the host. Firewall + CIS hardening need admin. If we don't
  # have it, say so loudly instead of leaving the saved profile (SEC_FIREWALL=true) claiming a
  # firewall that was never enabled — and verify it actually came up when we did try.
  if [ "$SEC_CIS" = "true" ] || [ "$SEC_FIREWALL" = "true" ]; then
    if can_use_sudo; then
      harden_host
      if [ "$SEC_FIREWALL" = "true" ] && [ "$(firewall_status)" != "on" ]; then
        printf '%s%s sudo %s harden%s\n' "$C_YELLOW" "$(t harden_fw_pending)" "$MGMT_NAME" "$C_RESET"
      fi
    else
      printf '%s%s sudo %s harden%s\n' "$C_YELLOW" "$(t harden_no_admin)" "$MGMT_NAME" "$C_RESET"
    fi
  fi
  [ "$SEC_WATCHDOG" = "true" ] && watchdog_enable >/dev/null 2>&1

  # Trust the local CA when we can (so HTTPS just works).
  CA_TRUSTED="false"
  if ! caddy_use_acme && ! no_domain && can_use_sudo; then
    if [ "$NONINTERACTIVE" != "1" ] && confirm "$(t q_trust_ca)" 'N'; then
      do_trust_ca >/dev/null 2>&1 && CA_TRUSTED="true"
    fi
  fi

  # Multi-node: provision the agent worker node(s) now that the master is up.
  if [ "$NODE_MODE" = "multi" ] && [ "$NONINTERACTIVE" != "1" ] && type remote_agents >/dev/null 2>&1; then
    remote_agents || true
  fi

  finish_message
  post_install_handoff
}

finish_message() {
  local mgmt="$STACK_DIR/bin/$MGMT_NAME"
  printf '\n'; banner_stack
  printf '\n%s%s %s%s\n' "$C_B" "$C_GREEN" "$(t fin_done)" "$C_RESET"
  line
  printf '  %s:\n    %s%s%s %s\n    %s%s%s\n' "$(t fin_manage)" \
    "$C_B" "$MGMT_NAME" "$C_RESET" "$(t fin_cmd_hint)" "$C_DIM" "$mgmt" "$C_RESET"
  printf '%s' "$MGMT_NAME" | copy_to_clipboard 2>/dev/null && printf '    %s↑ copied%s\n' "$C_DIM" "$C_RESET"
  printf '  %s:\n    %s/secrets/passwords.txt\n' "$(t fin_secrets)" "$STACK_DIR"
  if ! caddy_use_acme && ! no_domain; then printf '  %s:\n    %s/secrets/certificates/root.crt\n' "$(t fin_ca)" "$STACK_DIR"; fi
  if [ "${SEAL_ENABLED:-false}" = "true" ]; then
    printf '  %s: %s%s%s (%s)\n' "$(t d_seal)" "$C_GREEN" "$(seal_status_label)" "$C_RESET" "$SEAL_MODE"
  fi
  line
  printf '  %s:\n' "$(t fin_next)"
  if no_domain; then
    printf '    1. %s%s%s\n' "$C_GREEN" "$(t dom_localhost_note)" "$C_RESET"
    print_active_domains
    return 0
  fi
  if [ "$CA_TRUSTED" = "true" ] || caddy_use_acme; then printf '    1. %sroot CA ok%s\n' "$C_GREEN" "$C_RESET"
  else printf '    1. trust root.crt:\n'; print_trust_ca_command; fi
  printf '    2. %s  →  https://%s\n' "$(t fin_open)" "$(main_host)"
  [ "$ENABLE_GIT" = "true" ] && printf '    3. %s%s%s  →  https://%s\n' "$C_YELLOW" "$(t fin_git_note)" "$C_RESET" "$GIT_DOMAIN"
  return 0   # never let a trailing false test make a successful install report failure
}
