# ───────────────────────────── banners ─────────────────────────────
# Banner art comes from the release banner template. In TTY mode the dot above
# the final "i" blinks; non-TTY output stays plain for logs/tests.

_psai_banner_dot() {
  if is_tty; then
    printf '                                 %s%s░██%s%s%s\n' "$C_B" "$C_BLINK" "$C_RESET" "$C_B" "$C_MAGENTA"
  else
    printf '                                 ░██\n'
  fi
}

_psai_banner_art() {
  _psai_banner_dot
  cat <<EOF

░████████   ░███████   ░██████   ░██
░██    ░██ ░██              ░██  ░██
░██    ░██  ░███████   ░███████  ░██
░███   ░██        ░██ ░██   ░██  ░██
░██░█████   ░███████   ░█████░██ ░██
░██                version:    $STACK_VERSION
░██                release:   github
EOF
}

banner_install() {
  is_tty && printf '%s%s' "$C_B" "$C_MAGENTA"
  _psai_banner_art
  is_tty && printf '%s' "$C_RESET"
  return 0
}

banner_stack() {
  is_tty && printf '%s%s' "$C_B" "$C_MAGENTA"
  _psai_banner_art
  is_tty && printf '%s' "$C_RESET"
  return 0
}

# Dashboard context: labeled status and security lines.
render_context() {
  local prof="${DEPLOY_PROFILE:-local}" dom security="${SECURITY_PROFILE:-default}"
  if [ "$prof" = "public" ] && [ -n "${PUBLIC_DOMAIN:-}" ]; then dom="$PUBLIC_DOMAIN"; else dom="${PSAI_DOMAIN:-${DOMAIN_ZONE:-lan}}"; fi
  printf '  %sStatus:%s %s%s · %s · %s%s\n' \
    "$C_DIM" "$C_RESET" "$C_B" "${NODE_MODE:-single}" "$prof" "$dom" "$C_RESET"
  printf '  %s%s:%s %s%s%s\n' "$C_DIM" "$(t sec_profile_label)" "$C_RESET" "$C_B" "$security" "$C_RESET"
  return 0
}
