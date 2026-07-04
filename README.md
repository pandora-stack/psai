<p align="center">
  <img src="docs/img/logo.png" alt="Pandora AI Stack" width="130" height="130">
</p>

<h1 align="center">Pandora AI Stack</h1>

<p align="center">
  <img alt="version" src="https://img.shields.io/badge/version-v1.1.3-0969da">
  <img alt="channel" src="https://img.shields.io/badge/channel-beta-0969da">
  <img alt="release" src="https://img.shields.io/badge/release-github-0969da">
</p>

<p align="center">
  <b>English</b> | <a href="README.ru.md">Русский</a>
</p>

> Stack in development

**Self hosted AI stack for macOS and Linux. Local or public install profile, Docker runtime, local models, agents, RAG, memory, egress routing, and a hardened secret store.**

<p align="center">
  <img src="docs/img/dashboard-status.svg" alt="psai dashboard - maximal stack on Linux" width="760">
</p>

## Quick Start

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/pandora-stack/psai/main/psai.sh)
```

```bash
git clone https://github.com/pandora-stack/psai.git
cd psai && ./psai.sh install
```

## Fast Commands

```bash
psai start              # start the stack
psai stop               # stop the stack
psai restart            # restart containers
psai status             # component health
psai logs openwebui     # service logs
psai update             # pull and rebuild
psai proxy              # switch proxy-stack/proxy-web
psai security           # security profile
psai backup             # encrypted backup
psai uninstall --data   # remove stack and data
```

## Components

| Service | Role |
|---|---|
| `openwebui` | Chat, cloud and local models, RAG over Qdrant, web search through SearXNG |
| `openhands` | AI agents for code and automation, optional sandbox containers that need security attention |
| `searxng` | Private metasearch for chat and agents |
| `forgejo` | Git server |
| `qdrant` | Shared vector memory for RAG and agents |
| `embed` | RAG plus embeddings on Linux x64 through Infinity; macOS/Linux ARM use Ollama embeddings by default |
| `ingest-docling` / `ingest-tika` | Document reading: Docling primary, Tika fallback |
| `mcp` | Built-in MCP memory server over Qdrant |
| `memory` | Cognee or Graphiti as shared memory |
| `ollama` | Local OpenAI compatible LLM endpoint for memory |
| `mcp-gateway` | Authenticated Docker MCP Gateway with a tool allowlist |
| `mcpo` | MCP-to-OpenAPI bridge for exposing memory and gateway tools in Open WebUI |
| `litellm` | Optional OpenAI compatible model gateway with routing, fallback, cache, and budgets |
| `langfuse` | Optional traces, evals, and prompt management |
| `pentest` | Optional isolated PentestGPT container |
| `caddy` | Reverse proxy and TLS |
| `proxy-stack` | Egress firewall/router for model APIs, local LLM calls, and stack updates |
| `proxy-web` | Egress firewall/router for search and agent browsing |
| `stack-vault` | Secret store: local vault on one node, KMS vault in multi-node mode |

When `PSAI_MEMORY=cognee|graphiti` or `PSAI_MCP_GATEWAY=true` is enabled, `mcpo` registers those MCP sources as OpenAPI tool servers in Open WebUI. Chat and agents can then use the same memory and tools. Gateway clients use Bearer tokens stored in `stack-vault`.

## Work Scenarios

### Single Node

![psai - single-node topology](docs/img/single-node.png)

Single-host install. Open WebUI and agents use shared tools and memory. Qdrant stores shared vector state. Outbound web traffic goes through `proxy-web`.

### Multi Nodes

![psai - master node, KMS node, and agent worker nodes over WireGuard](docs/img/architecture.png)

Multi-host install. The master node manages isolated worker nodes inside WireGuard. KMS vault can run on the master or on a separate KMS node. Agent workers are reachable inside WireGuard and can have their own OpenHands, SearXNG, and `proxy-web`.

## Install

| Step | Description |
|---|---|
| **0 - Environment** | Check system state and install dependencies. |
| **1 - Nodes** | Choose the `single` or `multi` install scenario. |
| **2 - Profile** | Choose the `local` or `public` install scenario. |
| **3 - Components** | Enable or disable stack components. |
| **4 - Security** | Choose security profile: `strict`, `default`, or `none`. |
| **5 - Zone and domains** | Configure access domains for selected components. |

> After install, open the dashboard with `psai`.

## Egress Proxy

Two egress gateways are available:

- `proxy-stack` routes model APIs, local LLM calls, downloads, and stack updates.
- `proxy-web` routes search and agent browsing.

Each gateway can use direct egress, Tor, WireGuard, VLESS, AdGuard VPN, or Tailscale. WireGuard adds DNS pinning, a kill-switch, optional CIDR allow-lists, and optional FQDN-to-IP allow-listing.

![egress proxies - firewall and router](docs/img/egress.png)

## Security

| Capability | Strict | Default | None |
|---|:--:|:--:|:--:|
| Container hardening (`no-new-privileges`, `cap_drop`) | yes | yes | yes |
| Secrets in `stack-vault` | yes | no | no |
| TPM auto-unseal on Linux | optional | no | no |
| Secrets in plaintext `.env` | no | yes | yes |
| CIS sysctls, sshd hardening, auto-upgrades | yes | yes | no |
| Host firewall | yes | no | no |
| Watchdog | yes | no | no |
| WireGuard-only SSH for multi-node agents | yes | no | no |
| fail2ban on public installs | yes | no | no |

OpenHands can use the host Docker socket (`PSAI_OH_MODE=host`). That is host-level control. Prefer `PSAI_OH_MODE=dind` on untrusted hosts.

Ollama is exposed through an auth proxy; raw `ollama-raw:11434` stays on a private Docker network.

Strict mode stores runtime secrets in `stack-vault`. On Linux 5.14+ it uses `memfd_secret`; on older Linux and macOS it falls back to locked memory. KMS, fingerprint binding, TPM, and secret-memory details are documented in [Architecture](docs/ARCHITECTURE.md).

![stack-vault secret memory](docs/img/kms.png)

## Dashboard and Commands

```bash
psai install [--defaults]    start | stop | restart | status | logs [svc]
psai update | rebuild        upgrade            (install/remove components)
psai backup | restore        proxy | security   (egress / profile)
psai seal | unseal           watchdog | trust-ca | add-hosts
psai agents --host IP        uninstall          (data is preserved)
psai --lang ru|en            --version | help
```

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `PSAI_STACK_NAME`, `PSAI_STACK_DIR` | `psai`, `~/psai` | non-interactive stack name and install directory |
| `PSAI_NODE_MODE` | `single` | `single` or `multi` |
| `PSAI_DEPLOY` | `local` | `local` or `public` |
| `PSAI_PROFILE` | `default` | `strict`, `default`, or `none` |
| `PSAI_NO_DOMAIN` | `false` | local only: publish services on localhost ports without domains |
| `PSAI_RAG` | `off` | `off`, `basic`, or `plus` |
| `PSAI_OLLAMA_MODEL`, `PSAI_OLLAMA_EMBED_MODEL` | platform-aware, `nomic-embed-text` | local chat and embedding models |
| `PSAI_OLLAMA_PULL_VIA_PROXY` | `false` | force Ollama model pulls through `proxy-stack` |
| `PSAI_MCP_GATEWAY` | `true` in prompts/defaults | enable Docker MCP Gateway and `mcpo` wiring |
| `PSAI_LLM_GATEWAY` | `true` in prompts/defaults | enable LiteLLM at `litellm:4000` |
| `PSAI_AGENTS`, `PSAI_OH_MODE` | `true`, `host` | enable agents and choose Docker mode: `host`, `rootless`, or `dind` |
| `PSAI_EGRESS_STACK`, `PSAI_EGRESS_WEB` | `none` | `tor`, `wireguard`, `vless`, `adguardvpn`, or `tailscale` |
| `PSAI_PROXY_PLATFORM` | auto | override proxy container platform: `linux/amd64` or `linux/arm64` |
| `PSAI_VAULT_PASS` | - | vault passphrase for non-interactive strict installs |
| `PSAI_ADMIN_PASSWORD` | - | custom Caddy basic-auth password |
| `PSAI_VAULT_TPM` | `false` | seal the vault passphrase to TPM on Linux |
| `PSAI_PTRACE_LOCKDOWN` | `false` | set Yama `ptrace_scope=3` until reboot |
| `PSAI_KMS_HOST` | - | external KMS node WireGuard IP |
| `PSAI_PROXY_KILLSWITCH`, `PSAI_PROXY_DNS`, `PSAI_PROXY_ALLOW_CIDR`, `PSAI_PROXY_ALLOW_FQDN` | `true`, `1.1.1.1`, -, - | WireGuard firewall controls |

The image manifest (default tags, not digest pins) lives in `versions.json`. Self-update applies only when the signed manifest verifies and the installer sha256 matches.

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) - topology, egress, multi-node, vault

## License

[MIT](LICENSE) (c) 2026 psai contributors.

<p align="right"><img alt="status ok" src="docs/img/status-dot.svg" width="14"></p>
