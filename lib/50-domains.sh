# ───────────────────────────── domains ─────────────────────────────
# No-domain local mode: services answer on http://localhost:PORT instead of vhosts.
no_domain() { [ "$NO_DOMAIN" = "true" ] && [ "$DEPLOY_PROFILE" != "public" ]; }

normalize_zone() {
  local zone="$1"
  zone="$(trim "$zone")"
  zone="$(printf '%s' "$zone" | sed -E 's#^https?://##; s#/$##; s/^[.]+//; s/[.]+$//')"
  [ -z "$zone" ] && zone="local"
  printf '%s' "$zone"
}

set_domain_base_from_zone() {
  DOMAIN_ZONE="$(normalize_zone "${DOMAIN_ZONE:-$DEFAULT_DOMAIN_ZONE}")"
  DOMAIN_BASE="$DOMAIN_ZONE"
}

make_service_domain() {
  local prefix="$1"
  set_domain_base_from_zone
  printf '%s.%s' "$prefix" "$DOMAIN_BASE"
}

set_default_domains() {
  set_domain_base_from_zone
  PSAI_DOMAIN="$(make_service_domain psai)"          # Open WebUI — primary entry
  AGENTS_DOMAIN="$(make_service_domain agents)"  # OpenHands
  GIT_DOMAIN="$(make_service_domain git)"        # Forgejo web
  GIT_SSH_HOST="$GIT_DOMAIN"
  QDRANT_DOMAIN="$(make_service_domain qdrant)"  # Qdrant dashboard
}

# Public domain: edit only the SUBDOMAIN label (base zone is fixed). Local: full host.
dom_edit_default() {
  if [ "$DEPLOY_PROFILE" = "public" ] && [ -n "${PUBLIC_DOMAIN:-}" ]; then printf '%s' "${1%%.*}"; else printf '%s' "$1"; fi
}
resolve_domain_input() {
  local value current
  value="$(printf '%s' "$1" | tr -d '[:space:]')"; current="$2"
  [ -z "$value" ] && { printf '%s' "$current"; return; }
  if [ "$DEPLOY_PROFILE" = "public" ] && [ -n "${PUBLIC_DOMAIN:-}" ]; then
    case "$value" in *.*) : ;; *) value="$value.$PUBLIC_DOMAIN" ;; esac
  fi
  printf '%s' "$value"
}

default_stack_dir_for() { printf '%s/%s' "$HOME" "$1"; }

domain_row() {
  local label="$1" value="$2" idx="${3:-}"
  if [ -n "$idx" ]; then
    printf '  %s[%s]%s ' "$C_CYAN" "$idx" "$C_RESET"
  else
    printf '  '
  fi
  pad_right "$label" 18
  printf ' %s\n' "$value"
}

print_active_domains() {
  printf '\n%s%s%s\n' "$C_B" "$(t dom_header)" "$C_RESET"
  if no_domain; then
    [ "$ENABLE_OPENWEBUI" = "true" ] && domain_row "$(t dom_psai)"   "http://localhost:$PORT_PSAI"
    [ "$ENABLE_AGENTS"   = "true" ] && domain_row "$(t dom_agents)" "http://localhost:$PORT_AGENTS"
    if [ "$ENABLE_GIT" = "true" ]; then
      domain_row "$(t dom_gitweb)" "http://localhost:$PORT_GIT"
      domain_row "$(t dom_gitssh)" "localhost:$GIT_SSH_PORT"
    fi
    [ "$ENABLE_QDRANT" = "true" ] && domain_row "$(t dom_qdrant)" "http://localhost:$PORT_QDRANT"
    return 0
  fi
  [ "$ENABLE_OPENWEBUI" = "true" ] && domain_row "$(t dom_psai)"   "https://$PSAI_DOMAIN" "1"
  [ "$ENABLE_AGENTS"   = "true" ] && domain_row "$(t dom_agents)" "https://$AGENTS_DOMAIN" "2"
  if [ "$ENABLE_GIT" = "true" ]; then
    domain_row "$(t dom_gitweb)"  "https://$GIT_DOMAIN" "3"
    domain_row "$(t dom_gitssh)"  "$GIT_SSH_HOST" "4"
    domain_row "$(t dom_gitport)" "$GIT_SSH_PORT" "5"
  fi
  [ "$ENABLE_QDRANT" = "true" ] && domain_row "$(t dom_qdrant)" "https://$QDRANT_DOMAIN" "6"
  return 0
}

edit_single_domain() {
  local choice="$1" value=""
  choice="$(printf '%s' "$choice" | tr -d '[][:space:]')"
  case "$choice" in
    1) [ "$ENABLE_OPENWEBUI" = "true" ] || return 0; prompt_set value "$(t dom_psai)" "$(dom_edit_default "$PSAI_DOMAIN")"; PSAI_DOMAIN="$(resolve_domain_input "$value" "$PSAI_DOMAIN")" ;;
    2) [ "$ENABLE_AGENTS" = "true" ] || return 0; prompt_set value "$(t dom_agents)" "$(dom_edit_default "$AGENTS_DOMAIN")"; AGENTS_DOMAIN="$(resolve_domain_input "$value" "$AGENTS_DOMAIN")" ;;
    3) [ "$ENABLE_GIT" = "true" ] || return 0; prompt_set value "$(t dom_gitweb)" "$(dom_edit_default "$GIT_DOMAIN")"; GIT_DOMAIN="$(resolve_domain_input "$value" "$GIT_DOMAIN")" ;;
    4) [ "$ENABLE_GIT" = "true" ] || return 0; prompt_set value "$(t dom_gitssh)" "$(dom_edit_default "$GIT_SSH_HOST")"; GIT_SSH_HOST="$(resolve_domain_input "$value" "$GIT_SSH_HOST")" ;;
    5) [ "$ENABLE_GIT" = "true" ] || return 0
       prompt_set value "$(t dom_gitport)" "$GIT_SSH_PORT"
       if printf '%s' "$value" | grep -Eq '^[0-9]{1,5}$' && [ "$value" -ge 1 ] && [ "$value" -le 65535 ]; then GIT_SSH_PORT="$value"; else echo "$(t port_bad)"; fi ;;
    6) [ "$ENABLE_QDRANT" = "true" ] || return 0; prompt_set value "$(t dom_qdrant)" "$(dom_edit_default "$QDRANT_DOMAIN")"; QDRANT_DOMAIN="$(resolve_domain_input "$value" "$QDRANT_DOMAIN")" ;;
    *) echo "$(t no_such_item)" ;;
  esac
}

# Show the list, then: Enter a number to edit, 0 to continue. (Step 5 UX.)
confirm_domains_loop() {
  while true; do
    print_active_domains
    printf '\n%s\n  %s[0]%s %s\n' "$(t dom_edit_hint)" "$C_CYAN" "$C_RESET" "$(t dom_continue)"
    printf '%s: ' "$(t menu_choice)"
    local choice=""; read_user_line choice
    choice="$(printf '%s' "$(trim "$choice")" | tr -d '[][:space:]')"; [ -z "$choice" ] && choice="0"
    [ "$choice" = "0" ] && break
    edit_single_domain "$choice"
  done
}
