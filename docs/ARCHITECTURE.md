# Architecture

<p align="center">
  <b>English</b> | <a href="ARCHITECTURE.ru.md">Русский</a>
</p>

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
| `mcpo` | MCP-to-OpenAPI bridge for memory and gateway tools in Open WebUI |
| `litellm` | Optional OpenAI compatible gateway for routing, fallback, cache, and budgets |
| `langfuse` | Optional traces, evals, and prompt management |
| `pentest` | Optional isolated PentestGPT |
| `caddy` | Reverse proxy and TLS |
| `proxy-stack` | Egress firewall/router for model APIs, local LLM calls, and stack updates |
| `proxy-web` | Egress firewall/router for search and agent browsing |
| `stack-vault` | Secret store: local vault on one node, KMS vault in multi-node mode |

## Single node

![psai - single-node topology](img/single-node.png)

The local **stack-vault** keeps secrets in memory (`memfd_secret` on Linux 5.14+, older systems fall back to `mlock`) and unlocks with a passphrase. Open WebUI and OpenHands share one tools and memory layer: the memory backend speaks MCP-SSE, Docker MCP Gateway provides verified tools with a vault Bearer token, and `mcpo` turns those MCP sources into OpenAPI tool servers for Open WebUI. Open WebUI indexes RAG documents in Qdrant. Web search goes through the proxy.

**RAG-plus (`PSAI_RAG=plus`)** improves retrieval with platform-aware embeddings. Linux x64 uses the `embed` service by default (Infinity, OpenAI-compatible) plus a CrossEncoder reranker. macOS and Linux ARM use bundled Ollama embeddings (`nomic-embed-text`) by default. The `ingest` layer (Docling -> Markdown/JSON, Apache Tika fallback) parses PDF/DOCX/tables/formulas before chunking. Linux x64 flow: *document -> Docling/Tika -> chunk -> embed (Infinity) -> Qdrant -> recall -> rerank -> answer.* macOS/Linux ARM flow: *document -> Docling/Tika -> chunk -> Ollama embeddings -> Qdrant -> recall -> answer.* Hybrid dense+BM25 is enabled separately.

**Domains are optional on local installs.**

| Service | Port |
|---|---|
| Open WebUI | `8080` |
| OpenHands | `8081` |
| Forgejo | `8082` |
| Qdrant | `8083` |
| Git | `2222` |

## Multi-node - master | KMS | agent worker nodes

![psai - multi-node topology (master node | KMS node | agent worker nodes)](img/architecture.png)

`master_node_0` is the control plane. It runs the stack and manages each `agent_worker_<N>` over an SSH tunnel inside WireGuard. Addressing is fixed: master is WG `.1`, `agent_worker_<N>` is WG `.{2+N}`, and the optional KMS node is `.254`. An agent worker has OpenHands, SearXNG, and `proxy-web`; it is reachable inside WireGuard. Qdrant on the master is shared with agents over the tunnel. State collection currently pulls data and workspaces; per-node health/log snapshots still need to be completed.

`psai agents --host IP` deploys an agent worker. It installs Docker and the OpenHands stack, builds the WireGuard tunnel, hardens the host (CIS sysctls, ufw), and on the strict profile moves public SSH to WireGuard.

**KMS vault.** In multi-node mode, the secrets layer is a KMS vault: a key store and KMS server that unlocks each agent over WireGuard. It runs on the master node or a separate node (`psai kms-node --host IP`). Each agent worker node also runs `stack-vault`. During `agents --host`, KMS vault generates the agent unseal key and auth token. The agent `vault.enc` is encrypted with that key, and only the token is sent to the agent (in `kms.conf`) - the key itself never lands on the agent disk. On each start, the agent fetches the key from KMS vault (`stack-vault kms` serves `agent_unseal_<id>`, gated by `kms_token_<id>`) over WireGuard. If KMS is unavailable, the agent remains sealed.

**Hardware fingerprint binding.** KMS vault additionally binds each agent to a hardware fingerprint. During provisioning it reads the agent fingerprint (`stack-vault fingerprint`) and stores it as `agent_fp_<id>`. The fingerprint is a SHA-256 over IDs not present in a raw disk image: primarily the SMBIOS/DMI **product UUID** assigned by the hypervisor, plus `machine-id` and CPU model. Every unseal request carries `GET <id> <token> <fp>`, and KMS denies it (`ERR denied-hwid`) when the fingerprint differs. A clone booted on different hardware gets a different UUID, a different fingerprint, and is denied. Strong binding requires the agent vault to read `product_uuid`, which is root-only; without it, the fallback is `machine-id`, which binds to the OS install.

## Egress proxies - firewall + router

Two gateways. Each one is a router and a firewall. The router chooses the next hop: direct, Tor, or a VPN/tunnel client. The firewall is the only allowed exit, with DNS pinning, a kill-switch, and an optional allow-list. Both default to direct, and either can be reconfigured from the dashboard while the stack is running.

![psai - egress proxies (firewall + router): proxy-stack and proxy-web](img/egress.png)

- **`proxy-stack`** - every model API call from apps (cloud and local by default), plus component downloads and updates.
- **`proxy-web`** - search queries and OpenHands sandbox browsing. In multi-node mode it also runs on each agent worker node.

Proxy containers are pinned to the detected host platform (`linux/arm64` on ARM, `linux/amd64` on x64), with `PSAI_PROXY_PLATFORM` available as an override. Tor and VLESS expose an HTTP listener on `:8118`. Tunnel modes (`wireguard` / `adguardvpn` / `tailscale`) run a tinyproxy sidecar on `:8888` sharing the tunnel container network namespace, so the sidecar can only exit through the tunnel. `proxy-web` is also published on host loopback so the OpenHands sandbox (separate network) can reach it through `host.docker.internal`.

## Security

| Capability | Strict | Default | None |
|---|:--:|:--:|:--:|
| Container hardening (`no-new-privileges`, `cap_drop`) | yes | yes | yes |
| Secrets in `stack-vault` (secret memory, manual passphrase) | yes | - | - |
| TPM auto-unseal (hardware-bound, Linux; security setup toggle) | opt | - | - |
| Secrets in plaintext `.env` (disk) | - | yes | yes |
| CIS sysctls + sshd + auto-upgrades | yes | yes | - |
| Host firewall | yes | - | - |
| Watchdog | yes | - | - |
| Disable public SSH (WireGuard-only, multi-node) | yes | - | - |
| fail2ban (public) | yes | - | - |

**OpenHands and Docker socket.** By default (`PSAI_OH_MODE=host`) OpenHands uses the host Docker socket, which effectively gives it host-level control. `PSAI_OH_MODE=dind` runs a nested Docker daemon and is preferred on shared/untrusted hosts. `AGENTS_DOCKER=true` also mounts the host Docker socket into the agent sandbox. Stateless services (Open WebUI / SearXNG / Caddy) stay locked down (`no-new-privileges`, `cap_drop ALL`); the agents component is optional (`PSAI_AGENTS=false`).

### Secrets - `stack-vault`

Two base modes:

1. **Default - plaintext `.env`.** Secrets live in config files on disk and are protected only by host disk encryption. This is fine for a machine you trust.
2. **Vault - `stack-vault` (strict).** Each secret lives only in memory. Consumers read secrets over a Unix socket gated by peer credentials (`SO_PEERCRED` / `getpeereid`, same uid only), and core dumps are disabled. On disk there is only an AES-256-GCM blob, with the key derived from the passphrase through Argon2id. The passphrase is entered on each start and is never stored, so reboot loses the in-RAM key and the vault stays sealed until it is unlocked again. On one host this is local `stack-vault`; in multi-node mode it works as the KMS vault that unseals agents.

On Linux 5.14+ each secret is held in a `memfd_secret` region - pages are removed from the kernel direct map, so `/dev/mem`, `/proc/kcore`, swap, and `ptrace` / `process_vm_readv` (through `get_user_pages`) cannot read them as root. Without secretmem (older Linux, macOS), fallback is `mlock` RAM (no swap, no core dump).

![stack-vault | memfd_secret - secrets in a region the kernel will not map for anyone, even root (fallback: mlock RAM)](img/kms.png)

Runtime secrets needed by containers (session keys) are rendered from the vault into `.runtime.env` and shredded on stop. On Linux this file is backed by tmpfs (`/dev/shm`). SearXNG uses placeholder plus env substitution. A sealed stack leaves only the encrypted blob on disk. Vault can rotate the passphrase in place (`stack-vault reseal`); `psai rekey <idx>` uses this for agent key rotation.

## Module map (`lib/*.sh`)

```text
00-header    globals | names | images | component + proxy + profile vars
05-banner    installer + dashboard banners + context line
10-i18n      colours/tty | t() EN/RU
20-helpers   ask/confirm/prompt | aligned menus | step spinner
30-ui        headers | runtime metrics | language
40-system    sudo/admin | docker socket | colima | compose()
50-domains   zones | service domains | inline editor | no-domain ports
55-deps      environment checks + dependency setup
60-config    .stack.env | secrets | directories
70-profile   strict/default/none | preview | per-toggle tuning (incl. TPM)
72-hardening firewall | CIS | sshd
74-watchdog  health watchdog
76-seal      legacy openssl seal (fallback only)
77-vault     stack-vault - build | unseal | seal | reseal | get/put | KMS | TPM
80-egress    proxy-stack + proxy-web | WireGuard firewall | FQDN allow-list
81-hosts     /etc/hosts + local-CA trust + A-record check
82-caddy     Caddyfile + TLS (local CA / ACME / own / self-signed)
84-compose   docker-compose.yml generator + write_all_configs
85-mcp       qdrant | embed/Ollama embeddings | ingest | memory | MCP gateway | mcpo | LiteLLM | Langfuse | PentestGPT
86-multinode master/agent over WireGuard | KMS | kms-node | rekey | state
88-install   install flow (single + multi)
90-lifecycle start/stop/uninstall/update/rebuild
92-dashboard operator dashboard + management menus
94-backup    encrypted 7z backup/restore
96-cron      docker auto-update | signed self-update | checks
99-main      CLI dispatch + entry
```
