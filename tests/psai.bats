#!/usr/bin/env bats
# Tests that need no Docker/cargo — safe for CI. Run: bats tests/
# (compose-config, vault round-trip and live install are covered by the host e2e.)

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "build assembles a syntactically valid installer" {
  run bash "$REPO/build.sh"
  [ "$status" -eq 0 ]
  run bash -n "$REPO/psai.sh"
  [ "$status" -eq 0 ]
}

@test "shellcheck is clean (warning level)" {
  if ! command -v shellcheck >/dev/null 2>&1; then skip "shellcheck not installed"; fi
  run shellcheck -S warning -e SC2034 "$REPO/psai.sh"
  [ "$status" -eq 0 ]
}

@test "i18n: every referenced t-key is defined" {
  # shellcheck disable=SC1090
  UI_LANG=en; source "$REPO/psai.sh"
  local missing=""
  for k in $(grep -rhoE '\$\(t [a-z0-9_]+\)' "$REPO/lib" | sed -E 's/\$\(t ([a-z0-9_]+)\)/\1/' | sort -u); do
    [ -z "$(UI_LANG=en t "$k")" ] && [ -z "$(UI_LANG=ru t "$k")" ] && missing="$missing $k"
  done
  [ -z "$missing" ] || { echo "undefined keys:$missing"; false; }
}

@test "i18n: RU and EN key sets match (each key defined twice)" {
  run bash -c "grep -oE '(^|;; )[a-z0-9_]+\)' '$REPO/lib/10-i18n.sh' | sed -E 's/^;; //; s/\)//' | sort | uniq -c | awk '\$1!=2{print}'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "helpers: safe_name / trim / normalize_zone" {
  # shellcheck disable=SC1090
  source "$REPO/psai.sh"
  [ "$(safe_name 'My Stack!')" = "my_stack" ]
  [ "$(trim '  x  ')" = "x" ]
  [ "$(normalize_zone 'https://Foo.Bar/')" = "Foo.Bar" ]
}

@test "egress: mode->port mapping" {
  # shellcheck disable=SC1090
  source "$REPO/psai.sh"
  [ "$(eg_mode_port none)" = "8888" ]
  [ "$(eg_mode_port tor)" = "8118" ]
  [ "$(eg_mode_port vless)" = "8118" ]
  [ "$(eg_mode_port wireguard)" = "8888" ]
}

@test "install defaults: direct proxy containers and advanced gateways default on" {
  # shellcheck disable=SC1090
  source "$REPO/psai.sh"
  NONINTERACTIVE=1; NODE_MODE=single; STACK_NAME=""; STACK_DIR=""; SAFE_STACK_NAME=""
  apply_defaults_noninteractive
  [ "$ENABLE_QDRANT" = "true" ]
  [ "$MEMORY_MODE" = "cognee" ]
  [ "$ROUTE_LOCAL_LLM" = "true" ]
  [ "$MCP_GATEWAY" = "true" ]
  [ "$LLM_GATEWAY" = "true" ]
  [ "$ENABLE_EVAL" = "true" ]
  EGRESS_STACK=none; EGRESS_WEB=none; EG_HOST_WEB_PORT=18188
  ask_proxies
  [ "$EGRESS_STACK_HTTP" = "http://proxy-stack:8888" ]
  [ "$EGRESS_WEB_HTTP" = "http://proxy-web:8888" ]
  [ "$ROUTE_LOCAL_LLM" = "true" ]
}

@test "install: detects an existing default stack directory" {
  # shellcheck disable=SC1090
  source "$REPO/psai.sh"
  tmp="$(mktemp -d)"
  HOME="$tmp/home"; mkdir -p "$HOME/psai"
  cat > "$HOME/psai/.stack.env" <<EOF
STACK_NAME='psai'
SAFE_STACK_NAME='psai'
STACK_DIR='$HOME/psai'
DEPLOY_PROFILE='local'
NO_DOMAIN='true'
SEC_SEAL='false'
SEAL_ENABLED='false'
EOF
  STACK_DIR=""
  detect_installed_stack
  [ "$STACK_DIR" = "$HOME/psai" ]
  rm -rf "$tmp"
}

@test "install defaults: stack name and directory env overrides are honored" {
  tmp="$(mktemp -d)"
  PSAI_STACK_NAME=demo_stack
  PSAI_STACK_DIR="$tmp/demo"
  source "$REPO/psai.sh"
  NONINTERACTIVE=1; NODE_MODE=single
  apply_defaults_noninteractive
  [ "$STACK_NAME" = "demo_stack" ]
  [ "$SAFE_STACK_NAME" = "demo_stack" ]
  [ "$STACK_DIR" = "$tmp/demo" ]
  rm -rf "$tmp"
}

@test "compose: pentest proxy env is under environment" {
  # shellcheck disable=SC1090
  source "$REPO/psai.sh"
  tmp="$(mktemp -d)"
  STACK_DIR="$tmp"; SAFE_STACK_NAME=psai_test; ENABLE_PENTEST=true
  EGRESS_STACK=none; STACK_VIA_PROXY=true; DOMAIN_BASE=lan; ROUTE_LOCAL_LLM=false
  mkdir -p "$STACK_DIR/compose"
  compose_header
  append_pentest_service
  run awk '
    /^  pentest:/ {svc=1}
    svc && /^    environment:/ {env=1}
    svc && /^      - HTTP_PROXY=/ {if (!env) exit 3; found=1}
    END {exit found ? 0 : 4}
  ' "$STACK_DIR/compose/docker-compose.yml"
  [ "$status" -eq 0 ]
  rm -rf "$tmp"
}

@test "compose: numeric stack names stay YAML strings" {
  # shellcheck disable=SC1090
  source "$REPO/psai.sh"
  tmp="$(mktemp -d)"
  STACK_DIR="$tmp"; SAFE_STACK_NAME=13
  mkdir -p "$STACK_DIR/compose"
  compose_header
  printf '  noop:\n    image: alpine:3.20\n' >> "$STACK_DIR/compose/docker-compose.yml"
  run grep -Fx 'name: "13"' "$STACK_DIR/compose/docker-compose.yml"
  [ "$status" -eq 0 ]
  if command -v docker >/dev/null 2>&1; then
    run docker compose -f "$STACK_DIR/compose/docker-compose.yml" config
    [ "$status" -eq 0 ]
  fi
  rm -rf "$tmp"
}

@test "egress: proxy platform follows detected host architecture" {
  # shellcheck disable=SC1090
  source "$REPO/psai.sh"
  uname() {
    if [ "$1" = "-m" ]; then printf '%s\n' "$FAKE_UNAME_M"; return 0; fi
    /usr/bin/uname "$@"
  }
  PROXY_PLATFORM=""
  FAKE_UNAME_M=aarch64
  [ "$(docker_proxy_platform)" = "linux/arm64" ]
  FAKE_UNAME_M=x86_64
  [ "$(docker_proxy_platform)" = "linux/amd64" ]
  unset -f uname
}

@test "rag-plus: small disks use Ollama embeddings instead of Infinity" {
  # shellcheck disable=SC1090
  source "$REPO/psai.sh"
  disk_free_gb() { printf '34'; }
  LOCAL_LLM=ollama; RAG_MODE=plus; ENABLE_QDRANT=false; ENABLE_INGEST=false; ENABLE_EMBED_SVC=false
  EMBED_URL=""; EMBED_MODEL=""; RERANK_MODEL=""; OLLAMA_EMBED_MODEL=nomic-embed-text
  resolve_rag_mode
  [ "$ENABLE_QDRANT" = "true" ]
  [ "$ENABLE_INGEST" = "false" ]
  [ "$ENABLE_EMBED_SVC" = "false" ]
  [ "$EMBED_URL" = "http://ollama:11434/v1" ]
  [ "$EMBED_MODEL" = "nomic-embed-text" ]
  unset -f disk_free_gb
}

@test "compose: direct proxy image is arch-pinned multi-arch tinyproxy without legacy ANY command" {
  # shellcheck disable=SC1090
  source "$REPO/psai.sh"
  tmp="$(mktemp -d)"
  STACK_DIR="$tmp"; SAFE_STACK_NAME=psai_test; EGRESS_STACK=none; EGRESS_WEB=none; EG_HOST_WEB_PORT=18188; PROXY_PLATFORM=linux/arm64
  mkdir -p "$STACK_DIR/compose"
  compose_header
  append_proxy_service stack
  append_proxy_service web
  run grep -F "image: kalaksi/tinyproxy:latest" "$STACK_DIR/compose/docker-compose.yml"
  [ "$status" -eq 0 ]
  run grep -c "platform: linux/arm64" "$STACK_DIR/compose/docker-compose.yml"
  [ "$status" -eq 0 ]
  [ "$output" -ge 2 ]
  run grep -F 'command: ["ANY"]' "$STACK_DIR/compose/docker-compose.yml"
  [ "$status" -ne 0 ]
  rm -rf "$tmp"
}

@test "sandbox: default runtime image stays lightweight, full flavor is opt-in" {
  # shellcheck disable=SC1090
  source "$REPO/psai.sh"
  tmp="$(mktemp -d)"
  STACK_DIR="$tmp"; EGRESS_WEB=none; EGRESS_STACK=none; PROXY_WEB_ENABLED=false
  mkdir -p "$STACK_DIR/openhands-sandbox"
  write_openhands_sandbox_dockerfile
  run grep -F "playwright install" "$STACK_DIR/openhands-sandbox/Dockerfile"
  [ "$status" -ne 0 ]
  PSAI_OPENHANDS_SANDBOX_FLAVOR=full write_openhands_sandbox_dockerfile
  run grep -F "playwright install" "$STACK_DIR/openhands-sandbox/Dockerfile"
  [ "$status" -eq 0 ]
  rm -rf "$tmp"
}

@test "secrets: one admin password fans out to protected browser UIs" {
  # shellcheck disable=SC1090
  source "$REPO/psai.sh"
  tmp="$(mktemp -d)"
  STACK_DIR="$tmp"; ADMIN_USER="alice"; ADMIN_PASSWORD_PLAIN="SharedAdminPass123"
  ENABLE_OPENWEBUI=true; ENABLE_AGENTS=true; ENABLE_QDRANT=true
  ENABLE_GIT=false; LOCAL_LLM=none; SEC_SEAL=false; DOMAIN_BASE=example.test
  prepare_dirs_and_secrets
  secrets="$STACK_DIR/secrets/passwords.txt"
  grep -qx "admin_basic_auth=SharedAdminPass123" "$secrets"
  grep -qx "agents_basic_auth=SharedAdminPass123" "$secrets"
  grep -qx "qdrant_basic_auth=SharedAdminPass123" "$secrets"
  ! grep -q "webui_basic_auth=SharedAdminPass123" "$secrets"
  ! grep -q "^openwebui_admin_email=" "$secrets"
  rm -rf "$tmp"
}

@test "openwebui: backend URL and first-admin secrets stay out of compose" {
  # shellcheck disable=SC1090
  source "$REPO/psai.sh"
  tmp="$(mktemp -d)"
  STACK_DIR="$tmp"; SAFE_STACK_NAME=psai_test; STACK_NAME=psai
  ADMIN_USER="admin"; ADMIN_PASSWORD_PLAIN="SharedAdminPass123"
  ENABLE_OPENWEBUI=true; ENABLE_AGENTS=false; ENABLE_SEARCH=false; ENABLE_GIT=false
  ENABLE_QDRANT=false; ENABLE_MCP=false; ENABLE_EMBEDDINGS=false; ENABLE_INGEST=false
  RAG_MODE=off; MEMORY_MODE=none; LOCAL_LLM=none; MCP_GATEWAY=false; LLM_GATEWAY=false
  ENABLE_EVAL=false; ENABLE_PENTEST=false; NO_DOMAIN=true; DEPLOY_PROFILE=local
  PORT_PSAI=18080; SEC_SEAL=false; RUNTIME_TMPFS=false; DOMAIN_BASE=localhost
  mkdir -p "$STACK_DIR/compose"
  prepare_dirs_and_secrets
  write_caddyfile
  compose_header
  compose_caddy
  compose_openwebui
  render_runtime_env
  run grep -F "WEBUI_URL=http://localhost:18080" "$STACK_DIR/compose/docker-compose.yml"
  [ "$status" -eq 0 ]
  run grep -F "CORS_ALLOW_ORIGIN=http://localhost:18080;http://127.0.0.1:18080" "$STACK_DIR/compose/docker-compose.yml"
  [ "$status" -eq 0 ]
  run grep -F "WEBUI_SESSION_COOKIE_SECURE=false" "$STACK_DIR/compose/docker-compose.yml"
  [ "$status" -eq 0 ]
  run grep -F "RAG_EMBEDDING_MODEL_AUTO_UPDATE=False" "$STACK_DIR/compose/docker-compose.yml"
  [ "$status" -eq 0 ]
  run grep -F "start_period: 300s" "$STACK_DIR/compose/docker-compose.yml"
  [ "$status" -eq 0 ]
  run grep -F "http://localhost:8080/api/config" "$STACK_DIR/compose/docker-compose.yml"
  [ "$status" -eq 0 ]
  run grep -F "lb_try_duration 120s" "$STACK_DIR/compose/Caddyfile"
  [ "$status" -eq 0 ]
  run grep -F "WEBUI_ADMIN_PASSWORD" "$STACK_DIR/compose/docker-compose.yml"
  [ "$status" -ne 0 ]
  run grep -F "WEBUI_ADMIN_" "$STACK_DIR/compose/.runtime.env"
  [ "$status" -ne 0 ]
  rm -rf "$tmp"
}

@test "install: choosing local domains clears stale no-domain mode" {
  # shellcheck disable=SC1090
  source "$REPO/psai.sh"
  confirm() { return 0; }
  confirm_domains_loop() { :; }
  prompt_set() { :; }
  DEPLOY_PROFILE=local; NO_DOMAIN=true; DOMAIN_ZONE=localhost
  ENABLE_OPENWEBUI=true; ENABLE_AGENTS=true; ENABLE_GIT=true; ENABLE_QDRANT=true
  TLS_MODE=self; CERT_YEARS=3; DEFAULT_DOMAIN_ZONE=lan
  choose_zone
  [ "$NO_DOMAIN" = "false" ]
  [ "$DOMAIN_ZONE" = "lan" ]
  [ "$PSAI_DOMAIN" = "psai.lan" ]
  unset -f confirm confirm_domains_loop prompt_set
}

@test "config: custom no-domain ports persist for installed dashboard" {
  # shellcheck disable=SC1090
  source "$REPO/psai.sh"
  tmp="$(mktemp -d)"
  STACK_DIR="$tmp"; STACK_NAME=psai; SAFE_STACK_NAME=psai; ADMIN_USER=admin
  PORT_PSAI=19080; PORT_AGENTS=19081; PORT_GIT=19082; PORT_QDRANT=19083
  save_config
  PORT_PSAI=8080; PORT_AGENTS=8081; PORT_GIT=8082; PORT_QDRANT=8083
  load_config
  [ "$PORT_PSAI" = "19080" ]
  [ "$PORT_AGENTS" = "19081" ]
  [ "$PORT_GIT" = "19082" ]
  [ "$PORT_QDRANT" = "19083" ]
  rm -rf "$tmp"
}

@test "install: busy localhost ports move no-domain services to free ports" {
  # shellcheck disable=SC1090
  source "$REPO/psai.sh"
  host_port_busy() {
    case "$1" in 8080|18081) return 0 ;; *) return 1 ;; esac
  }
  DEPLOY_PROFILE=local; NO_DOMAIN=true; DUAL_ACCESS=false
  PORT_PSAI=8080; PORT_AGENTS=8081; PORT_GIT=8082; PORT_QDRANT=8083
  avoid_local_loopback_port_conflicts
  [ "$PORT_PSAI" = "18080" ]
  [ "$PORT_AGENTS" = "8081" ]
  [ "$PORT_GIT" = "8082" ]
  [ "$PORT_QDRANT" = "8083" ]
  unset -f host_port_busy
}

@test "profile: strict enables the vault, default uses .env" {
  # shellcheck disable=SC1090
  source "$REPO/psai.sh"
  NODE_MODE=single DEPLOY_PROFILE=local SECURITY_PROFILE=strict resolve_security_profile
  [ "$SEC_SEAL" = "true" ]
  SECURITY_PROFILE=default resolve_security_profile
  [ "$SEC_SEAL" = "false" ]
}

@test "memory: cognee falls back on small disks unless explicitly allowed" {
  # shellcheck disable=SC1090
  source "$REPO/psai.sh"
  disk_free_gb() { printf '34'; }
  MEMORY_MODE=cognee; ENABLE_MCP=false; PSAI_COGNEE_MIN_FREE_GB=45
  resolve_memory_mode
  [ "$MEMORY_MODE" = "stub" ]
  [ "$ENABLE_MCP" = "true" ]
  PSAI_COGNEE_ALLOW_HUGE=true; MEMORY_MODE=cognee; ENABLE_MCP=true
  resolve_memory_mode
  [ "$MEMORY_MODE" = "cognee" ]
  [ "$ENABLE_MCP" = "false" ]
  unset -f disk_free_gb
}

@test "versions.json is valid and carries an installer hash field" {
  run grep -q '"installer_sha256"' "$REPO/versions.json"
  [ "$status" -eq 0 ]
}

@test "banner: install header omits metadata row" {
  # shellcheck disable=SC1090
  source "$REPO/psai.sh"
  run banner_install
  [ "$status" -eq 0 ]
  [[ "$output" != *"title Pandora AI Stack"* ]]
  [[ "$output" != *"channel beta"* ]]
  [[ "$output" != *"command psai"* ]]
}

@test "installer copy: no macOS admin warning" {
  run grep -F "macOS: admin is needed to trust the CA" "$REPO/psai.sh"
  [ "$status" -ne 0 ]
  run grep -F "macOS: для доверия CA" "$REPO/psai.sh"
  [ "$status" -ne 0 ]
}

@test "dashboard: context is compact and security is separate" {
  # shellcheck disable=SC1090
  UI_LANG=en; source "$REPO/psai.sh"
  STACK_NAME=psai NODE_MODE=single DEPLOY_PROFILE=local PSAI_DOMAIN=psai.lan SECURITY_PROFILE=default
  run render_context
  [ "$status" -eq 0 ]
  [[ "$output" == *"Status: single · local · psai.lan"* ]]
  [[ "$output" == *"Security profile: default"* ]]
  [[ "$output" != *"v$STACK_VERSION"* ]]
  [[ "$output" != *"domain:"* ]]
}

@test "dashboard: status label is localized in Russian" {
  # shellcheck disable=SC1090
  source "$REPO/psai.sh"; UI_LANG=ru
  NODE_MODE=single DEPLOY_PROFILE=local PSAI_DOMAIN=psai.lan SECURITY_PROFILE=default
  run render_context
  [ "$status" -eq 0 ]
  [[ "$output" == *"Статус: single · local · psai.lan"* ]]
}

@test "dashboard: components render in two columns and arrow selection moves" {
  # shellcheck disable=SC1090
  UI_LANG=en; source "$REPO/psai.sh"
  COMP_LIST=""
  for n in $(seq 1 20); do COMP_LIST="${COMP_LIST}svc${n}|repo/image${n}:latest|running|healthy|0
"; done
  COMP_SELECTED=1
  run render_components
  [ "$status" -eq 0 ]
  [[ "$output" == *"svc1"* ]]
  [[ "$output" == *"svc11"* ]]
  [[ "$output" == *"Ctrl+F interactive mode"* ]]
  component_move right
  [ "$COMP_SELECTED" -eq 11 ]
  [ "$(component_service_at "$COMP_SELECTED")" = "svc11" ]
}

@test "dashboard: run section is numeric and hides start while running" {
  # shellcheck disable=SC1090
  UI_LANG=en; source "$REPO/psai.sh"
  stack_running() { return 0; }
  stop_stack() { echo stop_called; }
  pause() { :; }
  run dashboard_run_section <<< "1"
  [ "$status" -eq 0 ]
  [[ "$output" != *" start"* ]]
  [[ "$output" == *" stop"* ]]
  [[ "$output" == *"stop_called"* ]]
}

@test "dashboard: command prompt advertises ctrl section hotkeys" {
  # shellcheck disable=SC1090
  UI_LANG=en; source "$REPO/psai.sh"
  run render_dashboard_commands
  [ "$status" -eq 0 ]
  [[ "$output" == *"Commands: start stop restart"* ]]
  [[ "$output" == *"Ctrl+F interactive mode"* ]]
}

@test "python dashboard asset compiles and is embedded by build" {
  if ! command -v python3 >/dev/null 2>&1; then skip "python3 not installed"; fi
  run python3 -m py_compile "$REPO/assets/psai-dashboard.py"
  [ "$status" -eq 0 ]
  run grep -F "def settings_screen" "$REPO/psai.sh"
  [ "$status" -eq 0 ]
  run grep -F "__PSAI_DASHBOARD_PY__" "$REPO/psai.sh"
  [ "$status" -ne 0 ]
}

@test "readme: build and tests section is not published" {
  run grep -F "## Build and Tests" "$REPO/README.md" "$REPO/README.ru.md"
  [ "$status" -ne 0 ]
  run grep -F "cargo clippy --all-targets" "$REPO/README.md" "$REPO/README.ru.md"
  [ "$status" -ne 0 ]
}

@test "uninstall: help lists non-interactive safety flags" {
  run bash "$REPO/psai.sh" uninstall --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--yes"* ]]
  [[ "$output" == *"--dry-run"* ]]
}

@test "uninstall: dry-run keeps an explicit stack dir" {
  tmp="$(mktemp -d)"
  stack="$tmp/stack"
  mkdir -p "$stack/compose" "$stack/data" "$stack/secrets"
  cat > "$stack/.stack.env" <<EOF
STACK_NAME='psai test'
SAFE_STACK_NAME='psai_test'
STACK_DIR='$stack'
DEPLOY_PROFILE='local'
NO_DOMAIN='true'
SEC_SEAL='false'
SEAL_ENABLED='false'
EOF
  run bash "$REPO/psai.sh" uninstall --yes --dry-run --dir "$stack"
  [ "$status" -eq 0 ]
  [ -d "$stack" ]
  [[ "$output" == *"Dry run"* || "$output" == *"Пробный режим"* ]]
  rm -rf "$tmp"
}

@test "uninstall: --data removes an explicit stack dir" {
  tmp="$(mktemp -d)"
  stack="$tmp/stack"
  mkdir -p "$stack/compose" "$stack/data" "$stack/secrets"
  cat > "$stack/.stack.env" <<EOF
STACK_NAME='psai test'
SAFE_STACK_NAME='psai_test'
STACK_DIR='$stack'
DEPLOY_PROFILE='local'
NO_DOMAIN='true'
SEC_SEAL='false'
SEAL_ENABLED='false'
EOF
  run bash "$REPO/psai.sh" uninstall --yes --data --dir "$stack"
  [ "$status" -eq 0 ]
  [ ! -e "$stack" ]
  rm -rf "$tmp"
}

@test "watchdog: uninstall skip-save does not rewrite config" {
  tmp="$(mktemp -d)"
  stack="$tmp/stack"
  mkdir -p "$stack"
  cat > "$stack/.stack.env" <<EOF
STACK_NAME='psai test'
SAFE_STACK_NAME='psai_test'
STACK_DIR='$stack'
DEPLOY_PROFILE='local'
NO_DOMAIN='true'
SEC_WATCHDOG='true'
EOF
  # shellcheck disable=SC1090
  source "$REPO/psai.sh"
  STACK_DIR="$stack"; load_config
  before="$(cat "$stack/.stack.env")"
  WATCHDOG_SKIP_SAVE=true watchdog_disable >/dev/null
  after="$(cat "$stack/.stack.env")"
  [ "$after" = "$before" ]
  rm -rf "$tmp"
}
