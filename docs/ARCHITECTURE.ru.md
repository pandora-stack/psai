# Архитектура

<p align="center">
  <a href="ARCHITECTURE.md">English</a> | <b>Русский</b>
</p>

## Компоненты

| Сервис | Роль |
|---|---|
| `openwebui` | Чат, облачные и локальные модели, RAG поверх Qdrant, веб-поиск через SearXNG |
| `openhands` | ИИ-агенты для кода и автоматизации, sandbox контейнеры опциональны и требуют внимания к безопасности |
| `searxng` | Приватный метапоиск для чата и агентов |
| `forgejo` | Git сервер |
| `qdrant` | Общая векторная память для RAG и агентов |
| `embed` | RAG plus embeddings на Linux x64 через Infinity и  macOS/Linux ARM - по умолчанию используют Ollama embeddings |
| `ingest-docling` / `ingest-tika` | Чтение документов - Docling основной, Tika fallback |
| `mcp` | Встроенный MCP сервер памяти поверх Qdrant |
| `memory` | Cognee или Graphiti как общая память |
| `ollama` | Локальный OpenAI compatible LLM endpoint для  памяти |
| `mcp-gateway` | Authenticated Docker MCP Gateway с  allowlist инструментов |
| `mcpo` | MCP-to-OpenAPI bridge для инструментов памяти и gateway в Open WebUI |
| `litellm` | Опциональный OpenAI compatible gateway для routing, fallback, cache и budgets |
| `langfuse` | Опциональные traces, evals и prompt management |
| `pentest` | Опциональный изолированный PentestGPT |
| `caddy` | Reverse proxy и TLS |
| `proxy-stack` | Egress firewall/router для model API, локальных LLM  и обновлений |
| `proxy-web` | Egress firewall/router для поиска и браузинга агентов |
| `stack-vault` | Хранилище секретов -локальный vault на одном узле и  KMS vault в multi-node |

## Single node

![psai - топология одного узла](img/single-node.png)

Локальный **stack-vault** храниты секреты в памяти (`memfd_secret` на Linux 5.14+, `mlock` старее), разблокировка паролем. Open WebUI и OpenHands - один слой tools и memory - memory backend - MCP-SSE, Docker MCP Gateway - verified tools с bearer токеном из vault, а `mcpo` превращает эти MCP источники в OpenAPI tool servers для  Open WebUI. Open WebUI индексирует RAG-документы в Qdrant. Web поиск через прокси.

**RAG-plus (`PSAI_RAG=plus`)** усиливает retrieval platform-aware эмбеддингами. Linux x64 по умолчанию использует сервис `embed` (Infinity, OpenAI-compatible) плюс CrossEncoder reranker. macOS и Linux ARM по умолчанию используют встроенные Ollama embeddings (`nomic-embed-text`). Слой `ingest` (Docling -> Markdown/JSON, Apache Tika fallback) парсит PDF/DOCX/таблицы/формулы перед chunking. Поток на Linux x64: *document -> Docling/Tika -> chunk -> embed (Infinity) -> Qdrant -> recall -> rerank -> answer.* Поток на macOS/Linux ARM: *document -> Docling/Tika -> chunk -> Ollama embeddings -> Qdrant -> recall -> answer.* Hybrid dense+BM25 включается отдельно.


**Домены на локальной установке опциональны.**
| Сервис | Порт |
|---|---|
|Open WebUI| `8080`
|OpenHands| `8081`
|Forgejo  | `8082`
|Qdrant |`8083`
 |Git| `2222`

## Multi-node - master | KMS | agent worker nodes

![psai - multi-node топология (master node | KMS node | agent worker nodes)](img/architecture.png)

`master_node_0` - control plane. Он запускает стек и управляет каждым `agent_worker_<N>` через SSH-туннель  внутри WireGuard. Адресация фиксированная: master - WG `.1`, `agent_worker_<N>` - WG `.{2+N}`, опциональная KMS-нода - `.254`. Agent worker - OpenHands, SearXNG и `proxy-web`; доступна внутри WireGuard. Qdrant на мастере общий для агентов через туннель. Сейчас state collection забирает данные и workspaces, per-node health/log snapshots ещё надо доделать.

`psai agents --host IP` развертывание воркер агента. Он ставит Docker и OpenHands stack, строит WireGuard-туннель, harden-ит хост (CIS sysctls, ufw), и на strict-профиле переводит публичный SSH в WireGuard.

**KMS vault.** В multi-node слой секретов - это KMS vault: хранилище ключей и KMS-сервер, который делает анлок каждого агента поверх WireGuard. Работает на мастер ноде или на отдельной ноде (`psai kms-node --host IP`). Каждый agent worker node тоже запускает `stack-vault`. Во время `agents --host` KMS vault генерирует unseal key агента и auth token. `vault.enc` агента шифруется этим ключом, а на агента отправляется только token (в `kms.conf`) - сам ключ никогда не попадает на диск агента. При каждом старте агент забирает ключ из KMS vault (`stack-vault kms` отдаёт `agent_unseal_<id>`, gated by `kms_token_<id>`) по WireGuard. Если KMS  недоступен, агент остаётся sealed.

**Привязка к hardware fingerprint.**  KMS vault дополнительно привязывает каждого агента к hardware fingerprint. При provisioning он читает fingerprint агента (`stack-vault fingerprint`) и сохраняет его как `agent_fp_<id>`. Fingerprint - SHA-256 по ID, которых нет в raw disk image: прежде всего SMBIOS/DMI **product UUID**, который hypervisor выдаёт каждой VM, плюс `machine-id` и CPU model. Каждый unseal request несёт `GET <id> <token> <fp>`, и KMS отказывает (`ERR denied-hwid`), если fingerprint не совпадает. Clone, запущенный на другом железе, получает другой UUID, другой fingerprint и получает отказ. Ограничение: сильная привязка требует, чтобы vault агента мог прочитать `product_uuid`, а он root-only; без этого fallback - `machine-id`, который привязывает к OS install.


## Egress proxies - firewall + router

Два шлюза. Каждый - router и firewall. Router выбирает next hop: direct, Tor или VPN/tunnel client. Firewall - единственный разрешённый выход, с DNS pinning, kill-switch и опциональным allow-list. Оба по умолчанию direct, и любой можно перенастроить из dashboard на лету.

![psai - egress proxies (firewall + router): proxy-stack and proxy-web](img/egress.png)

- **`proxy-stack`** - каждый model API call от приложений (cloud и local по умолчанию), плюс component downloads и updates.
- **`proxy-web`** - search queries и browsing sandbox-а OpenHands. В multi-node он также работает на каждой agent worker node.

Proxy-контейнеры закрепляются за detected host platform (`linux/arm64` на ARM, `linux/amd64` на x64), override доступен через `PSAI_PROXY_PLATFORM`. Tor и VLESS поднимают HTTP listener на `:8118`. Tunnel modes (`wireguard` / `adguardvpn` / `tailscale`) запускают tinyproxy sidecar на `:8888`, который делит network namespace tunnel-контейнера, поэтому sidecar может выйти наружу только через tunnel. `proxy-web` также публикуется на loopback хоста, чтобы OpenHands sandbox (отдельная сеть) мог дотянуться до него через `host.docker.internal`.

## Безопасность

| Capability | Strict | Default | None |
|---|:--:|:--:|:--:|
| Container hardening (`no-new-privileges`, `cap_drop`) | да | да | да |
| Secrets in `stack-vault` (secret memory, manual passphrase) | да | - | - |
| TPM auto-unseal (hardware-bound, Linux; toggle в security setup) | опц | - | - |
| Secrets in plaintext `.env` (disk) | - | да | да |
| CIS sysctls + sshd + auto-upgrades | да | да | - |
| Host firewall | да | - | - |
| Watchdog | да | - | - |
| Disable public SSH (WireGuard-only, multi-node) | да | - | - |
| fail2ban (public) | да | - | - |


**OpenHands и Docker socket.**  По умолчанию (`PSAI_OH_MODE=host`) через Docker socket хоста, что фактически даёт контроль уровня хоста. `PSAI_OH_MODE=dind` запускает вложенный Docker daemon на shared/untrusted host -  лучше использовать его. `AGENTS_DOCKER=true` также монтирует host Docker socket внутрь agent sandbox.  Stateless services (Open WebUI / SearXNG / Caddy) остаются locked down (`no-new-privileges`, `cap_drop ALL`); Компонент agents опционален (`PSAI_AGENTS=false`).

### Секреты - `stack-vault`

Два базовых режима:

1. **Default - plaintext `.env`.** Секреты лежат в config files на диске и защищены только disk encryption хоста. Нормально для машины, которой ты доверяешь.
2. **Vault - `stack-vault` (strict).** Каждый секрет живёт только в памяти. Чтение их через Unix socket с peer-credentials gate (`SO_PEERCRED` / `getpeereid`, только same uid), core dumps выключены. На диске только AES-256-GCM blob, ключ от пароля через Argon2id. Пароль вводится при каждом старте и никогда не хранится, reboot теряет in-RAM key и vault остаётся sealed до повторного ввода. На одном хосте это локальный `stack-vault`; в multi-node работает как KMS vault, который unseal-ит agents.

На Linux 5.14+ каждый секрет содержится в `memfd_secret` region - pages удалены из kernel direct map, поэтому `/dev/mem`, `/proc/kcore`, swap и `ptrace` / `process_vm_readv` (через `get_user_pages`) не могут их прочитать из под root. Без secretmem (старое ядро, macOS) fallback - `mlock` RAM (без swap, без core dump).

![stack-vault | memfd_secret - секреты в region, который kernel не мапит никому, даже root (fallback: mlock RAM)](img/kms.png)


Runtime secrets, которые нужны контейнерам (session keys), рендерятся из vault в `.runtime.env` и shredded на stop. На Linux этот файл backed by tmpfs (`/dev/shm`). SearXNG использует placeholder plus env substitution. Sealed stack оставляет на диске только encrypted blob. Vault может rotate passphrase in place (`stack-vault reseal`); `psai rekey <idx>` использует это для rotation agent key.


## Карта модулей (`lib/*.sh`)

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
