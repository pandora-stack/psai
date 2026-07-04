#!/usr/bin/env python3
import curses
import os
import re
import shlex
import subprocess
import sys
import time
from pathlib import Path

os.environ.setdefault("ESCDELAY", "25")


STACK_DIR = Path(sys.argv[1]).expanduser().resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]
BIN_PSAI = STACK_DIR / "bin" / "psai"
COMPOSE_FILE = STACK_DIR / "compose" / "docker-compose.yml"
ENV_FILE = STACK_DIR / ".stack.env"

BASE_ENV = os.environ.copy()
BASE_ENV["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/Applications/Docker.app/Contents/Resources/bin:" + BASE_ENV.get("PATH", "")

SECTION_X = 2
DOT_X = 5
LABEL_X = 8
KEY_TIMEOUT_MS = 100
HOST_REFRESH_SEC = 6
PROXY_REFRESH_SEC = 6
HOST_STATIC_REFRESH_SEC = 60
COMPONENT_REFRESH_SEC = 10
DRAW_REFRESH_SEC = 2.0

BANNER = [
    "                                 ░██",
    "",
    "░████████   ░███████   ░██████   ░██",
    "░██    ░██ ░██              ░██  ░██",
    "░██    ░██  ░███████   ░███████  ░██",
    "░███   ░██        ░██ ░██   ░██  ░██",
    "░██░█████   ░███████   ░█████░██ ░██",
]


def parse_env(path: Path) -> dict:
    data = {}
    if not path.exists():
        return data
    for raw in path.read_text(errors="ignore").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        try:
            value = shlex.split(value, posix=True)[0] if value.strip() else ""
        except Exception:
            value = value.strip().strip("'\"")
        data[key] = value
    return data


CFG = parse_env(ENV_FILE)
LANG = CFG.get("UI_LANG_SAVED") or CFG.get("UI_LANG") or "ru"


def t(ru: str, en: str) -> str:
    return ru if LANG == "ru" else en


def run(cmd, timeout=30, check=False):
    try:
        return subprocess.run(
            cmd,
            cwd=str(STACK_DIR),
            env=BASE_ENV,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
            check=check,
        ).stdout
    except subprocess.CalledProcessError as exc:
        return exc.stdout or str(exc)
    except Exception as exc:
        return str(exc)


def run_result(cmd, timeout=30):
    try:
        proc = subprocess.run(
            cmd,
            cwd=str(STACK_DIR),
            env=BASE_ENV,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
        )
        return proc.returncode, proc.stdout
    except subprocess.TimeoutExpired as exc:
        return 124, exc.stdout or str(exc)
    except Exception as exc:
        return 1, str(exc)


def compose_cmd(*args):
    return ["docker", "compose", "-f", str(COMPOSE_FILE), *args]


def clip(text: str, width: int) -> str:
    if width <= 0:
        return ""
    return text if len(text) <= width else text[: max(0, width - 1)] + "…"


def first(*values, default="-") -> str:
    for value in values:
        if value not in (None, ""):
            return str(value)
    return default


def human_bytes(raw: str) -> str:
    try:
        value = float(raw)
    except Exception:
        return "-"
    units = ["B", "KB", "MB", "GB", "TB"]
    idx = 0
    while value >= 1024 and idx < len(units) - 1:
        value /= 1024
        idx += 1
    return f"{value:.1f}{units[idx]}" if idx else f"{int(value)}{units[idx]}"


def parse_percent(text: str):
    match = re.search(r"([0-9]+(?:\.[0-9]+)?)%", str(text))
    return float(match.group(1)) if match else None


def is_truthy(value) -> bool:
    return str(value).strip().lower() in {"1", "true", "yes", "y", "on", "enabled", "strict", "le", "self", "own"}


def is_falsey(value) -> bool:
    return str(value).strip().lower() in {"0", "false", "no", "n", "off", "disabled", "none", "-", ""}


class Dashboard:
    def __init__(self, stdscr):
        self.stdscr = stdscr
        self.cfg = CFG
        self.components = []
        self.selected = 0
        self.focus_index = 0
        self.mode = "command"
        self.command = ""
        self.message = ""
        self.last_refresh = 0.0
        self.last_draw = 0.0
        self.host_cache = {}
        self.host_last = 0.0
        self.host_static = {}
        self.host_static_last = 0.0
        self.proxy_cache = {}
        self.proxy_last = 0.0
        self.stack_state_cache = "red"
        self.colors = {}
        self.init_curses()

    def init_curses(self):
        curses.curs_set(0)
        curses.raw()
        try:
            subprocess.run(["stty", "-ixon"], stdin=sys.stdin, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:
            pass
        curses.noecho()
        if hasattr(curses, "set_escdelay"):
            curses.set_escdelay(25)
        self.stdscr.keypad(True)
        self.stdscr.timeout(KEY_TIMEOUT_MS)
        if curses.has_colors():
            curses.start_color()
            curses.use_default_colors()
            pairs = {
                "cyan": curses.COLOR_CYAN,
                "green": curses.COLOR_GREEN,
                "yellow": curses.COLOR_YELLOW,
                "red": curses.COLOR_RED,
                "blue": curses.COLOR_BLUE,
                "dim": curses.COLOR_WHITE,
                "white": curses.COLOR_WHITE,
                "magenta": curses.COLOR_MAGENTA,
            }
            for i, (name, color) in enumerate(pairs.items(), 1):
                curses.init_pair(i, color, -1)
                self.colors[name] = curses.color_pair(i) | (curses.A_DIM if name == "dim" else 0)
        self.colors.setdefault("cyan", curses.A_BOLD)
        self.colors.setdefault("green", curses.A_BOLD)
        self.colors.setdefault("yellow", curses.A_BOLD)
        self.colors.setdefault("red", curses.A_BOLD)
        self.colors.setdefault("blue", curses.A_BOLD)
        self.colors.setdefault("dim", curses.A_DIM)
        self.colors.setdefault("white", curses.A_NORMAL)

    def add(self, y, x, text, attr=0):
        h, w = self.stdscr.getmaxyx()
        if y < 0 or y >= h or x >= w:
            return
        s = clip(str(text), w - x - 1)
        if not s:
            return
        try:
            self.stdscr.addstr(y, max(0, x), s, attr)
        except curses.error:
            pass

    def section_header(self, y, title):
        h, w = self.stdscr.getmaxyx()
        self.add(y, SECTION_X, f"▌ {title}", self.colors["cyan"] | curses.A_BOLD)
        self.add(y + 1, SECTION_X, "─" * min(104, w - 4), self.colors["dim"])
        return y + 2

    def kv_row(self, y, dot_x, label_x, value_x, label, value, dot_attr=None, value_attr=0):
        self.add(y, dot_x, "●", dot_attr if dot_attr is not None else self.colors["green"])
        self.add(y, label_x, f"{label}:", self.colors["dim"])
        self.add(y, value_x, value, value_attr)

    def load_components(self):
        out = run(compose_cmd("ps", "-a", "--format", "{{.Service}}|{{.Name}}|{{.Image}}|{{.State}}|{{.Health}}|{{.ExitCode}}"), timeout=8)
        rows = []
        for line in out.splitlines():
            parts = line.split("|")
            if len(parts) < 6:
                continue
            svc, name, img, state, health, code = parts[:6]
            if not health:
                health = "healthy" if state == "running" else ("done" if code in ("", "0") else "failed")
            elif state == "running" and health == "no-check":
                health = "healthy"
            rows.append({"svc": svc, "name": name, "img": img.split("/")[-1], "state": state, "health": health, "code": code})
        self.components = rows
        if self.selected >= len(rows):
            self.selected = max(0, len(rows) - 1)
        targets = self.interactive_targets()
        if targets and self.focus_index >= len(targets):
            self.focus_index = len(targets) - 1
        self.last_refresh = time.time()

    def host_info(self, refresh=True):
        now = time.time()
        if not refresh and self.host_cache:
            return self.host_cache
        if now - self.host_last < HOST_REFRESH_SEC:
            return self.host_cache
        if not self.host_static or now - self.host_static_last > HOST_STATIC_REFRESH_SEC:
            host = run(["hostname"], timeout=2).strip() or "ai-server"
            dver = run(["docker", "version", "--format", "{{.Server.Version}}"], timeout=4).strip() or "-"
            os_arch = run(["uname", "-srm"], timeout=2).strip() or "-"
            cpu = run(["sh", "-c", "sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo -"], timeout=2).strip()
            mem_raw = run(["sh", "-c", "sysctl -n hw.memsize 2>/dev/null || awk '/MemTotal/ {print $2*1024}' /proc/meminfo 2>/dev/null || echo ''"], timeout=2).strip()
            docker_ctx = run(["docker", "context", "show"], timeout=3).strip() or "-"
            self.host_static = {
                "host": host,
                "docker": dver,
                "os_arch": os_arch,
                "cpu": cpu,
                "mem": human_bytes(mem_raw),
                "docker_ctx": docker_ctx,
                "stack_dir": str(STACK_DIR),
            }
            self.host_static_last = now
        disk = run(["sh", "-c", f"df -h {shlex.quote(str(STACK_DIR))} 2>/dev/null | awk 'NR==2{{print $3\"/\"$2\" (\"$5\")\"}}'"], timeout=2).strip() or "-"
        cpu_live = run(
            [
                "sh",
                "-c",
                "n=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 1); "
                "ps -A -o %cpu 2>/dev/null | awk -v n=\"$n\" 'NR>1{s+=$1} END{if(n<1)n=1; v=s/n; if(v>100)v=100; printf \"%.0f%%\", v}'",
            ],
            timeout=3,
        ).strip() or "-"
        ram_live = run(
            [
                "sh",
                "-c",
                "if command -v vm_stat >/dev/null 2>&1; then "
                "page=$(vm_stat | awk '/page size of/ {gsub(\"[^0-9]\", \"\", $8); print $8+0}'); "
                "vm_stat | awk -v p=\"$page\" '/Pages active/ {a=$3} /Pages wired down/ {w=$4} /Pages occupied by compressor/ {c=$5} /Pages free/ {f=$3} /Pages inactive/ {i=$3} /Pages speculative/ {s=$3} END{gsub(\"\\\\.\",\"\",a);gsub(\"\\\\.\",\"\",w);gsub(\"\\\\.\",\"\",c);gsub(\"\\\\.\",\"\",f);gsub(\"\\\\.\",\"\",i);gsub(\"\\\\.\",\"\",s); used=(a+w+c); total=used+f+i+s; if(total>0) printf \"%.0f%%\", used*100/total; else printf \"-\"}'; "
                "elif command -v free >/dev/null 2>&1; then free | awk '/Mem:/ {printf \"%.0f%%\", $3*100/$2}'; else echo -; fi",
            ],
            timeout=3,
        ).strip() or "-"
        self.host_cache = {
            **self.host_static,
            "cpu_live": cpu_live,
            "ram_live": ram_live,
            "disk": disk,
        }
        self.host_last = now
        return self.host_cache

    def proxy_stats(self, refresh=True):
        if not refresh and self.proxy_cache:
            return self.proxy_cache
        if time.time() - self.proxy_last < PROXY_REFRESH_SEC:
            return self.proxy_cache
        names = [c.get("name", "") for c in self.components if c.get("svc") in ("proxy-stack", "proxy-web") and c.get("name")]
        stats = {}
        if names:
            out = run(["docker", "stats", "--no-stream", "--format", "{{.Name}}|{{.NetIO}}", *names], timeout=8)
            for line in out.splitlines():
                name, _, net = line.partition("|")
                stats[name] = net.strip() or "-"
        self.proxy_cache = stats
        self.proxy_last = time.time()
        return stats

    def stack_state(self):
        if self.cfg.get("UPDATE_AVAILABLE", "false") == "true" or os.environ.get("UPDATE_AVAILABLE") == "true":
            return "blue"
        if not self.components:
            return "red"
        running = [c for c in self.components if c.get("state") == "running"]
        if not running:
            return "red"
        for comp in self.components:
            svc = comp.get("svc", "")
            state = comp.get("state", "")
            health = comp.get("health", "")
            code = comp.get("code", "")
            if health in ("unhealthy", "failed") or state in ("dead", "removing"):
                return "red"
            if state != "running":
                if svc.endswith("-pull") and state == "exited" and code in ("", "0"):
                    continue
                return "yellow"
        return "green"

    def dot_attr(self, comp, selected=False):
        if selected:
            return self.colors["cyan"] | curses.A_BOLD
        state = comp.get("state", "")
        health = comp.get("health", "")
        if state == "running" and health in ("healthy", "running"):
            return self.colors["green"]
        if state == "running" and health in ("starting", "created"):
            return self.colors["yellow"]
        if state == "exited" and health == "done":
            return self.colors["yellow"]
        if health in ("unhealthy", "failed") or state in ("dead", "removing"):
            return self.colors["red"]
        if state != "running":
            return self.colors["red"]
        return self.colors["yellow"]

    def health_attr(self, comp):
        return self.dot_attr(comp, False) | curses.A_BOLD

    def percent_attr(self, text):
        pct = parse_percent(text)
        if pct is None:
            return curses.A_BOLD
        if pct <= 80:
            return self.colors["green"] | curses.A_BOLD
        if pct <= 90:
            return self.colors["yellow"] | curses.A_BOLD
        return self.colors["red"] | curses.A_BOLD

    def status_value_attr(self, value):
        sval = str(value).lower()
        if sval == "strict" or sval == "healthy" or is_truthy(sval):
            return self.colors["green"] | curses.A_BOLD
        if sval in ("default", "starting", "created", "done") or sval == "false":
            return self.colors["yellow"] | curses.A_BOLD
        if is_falsey(sval) or sval in ("unhealthy", "failed", "exited", "dead"):
            return self.colors["red"] | curses.A_BOLD
        return curses.A_BOLD

    def interactive_targets(self):
        targets = [("container", idx) for idx in range(len(self.components))]
        targets.extend([("proxy", "stack"), ("proxy", "web")])
        return targets

    def current_target(self):
        targets = self.interactive_targets()
        if not targets:
            return ("none", None)
        self.focus_index %= len(targets)
        target = targets[self.focus_index]
        if target[0] == "container":
            self.selected = target[1]
        return target

    def target_selected(self, kind, value):
        return self.mode == "components" and self.current_target() == (kind, value)

    def draw_component_row(self, y, x, comp, selected, widths):
        name_w, img_w, state_w, health_w = widths
        if selected:
            self.add(y, max(0, x - 2), "›", self.colors["cyan"] | curses.A_BOLD)
        dot = "●"
        self.add(y, x, dot, self.dot_attr(comp, selected))
        name_attr = curses.A_BOLD | (self.colors["cyan"] if selected else self.colors["white"])
        self.add(y, x + 3, clip(comp["svc"], name_w), name_attr)
        self.add(y, x + 3 + name_w + 1, clip(comp["img"], img_w), self.colors["dim"])
        self.add(y, x + 3 + name_w + img_w + 2, clip(comp["state"], state_w), curses.A_BOLD)
        self.add(y, x + 3 + name_w + img_w + state_w + 3, clip(comp["health"], health_w), self.health_attr(comp))

    def draw_components(self, y):
        h, w = self.stdscr.getmaxyx()
        y = self.section_header(y, t("Компоненты", "Components"))
        if not self.components:
            self.add(y, 4, t("(нет контейнеров)", "(no containers)"), self.colors["dim"])
            return y + 2

        two_cols = w >= 120 and len(self.components) > 8
        half = (len(self.components) + 1) // 2 if two_cols else len(self.components)
        col_w = (w - 10) // 2 if two_cols else w - 6
        name_w = 16
        state_w = 8
        health_w = 8
        img_w = max(16, col_w - name_w - state_w - health_w - 10)
        widths = (name_w, img_w, state_w, health_w)

        def header(x):
            self.add(y, x + 3, "NAME", self.colors["dim"])
            self.add(y, x + 3 + name_w + 1, "IMAGE", self.colors["dim"])
            self.add(y, x + 3 + name_w + img_w + 2, "STATE", self.colors["dim"])
            self.add(y, x + 3 + name_w + img_w + state_w + 3, "HEALTH", self.colors["dim"])

        header(DOT_X)
        if two_cols:
            header(DOT_X + col_w)
        for i in range(half):
            row_y = y + 1 + i
            left = i
            if left < len(self.components):
                self.draw_component_row(row_y, DOT_X, self.components[left], self.target_selected("container", left), widths)
            right = i + half
            if two_cols and right < len(self.components):
                self.draw_component_row(row_y, DOT_X + col_w, self.components[right], self.target_selected("container", right), widths)
        return y + half + 1

    def draw_banner(self, y):
        version = self.cfg.get("STACK_VERSION", "1.1.3")
        dot_color = self.stack_state()
        for i, line in enumerate(BANNER):
            attr = curses.A_BOLD
            if i == 0:
                attr = self.colors[dot_color] | curses.A_BOLD | curses.A_BLINK
            self.add(y, 2, line, attr)
            y += 1
        self.add(y, 2, f"░██                version:    {version}", curses.A_BOLD)
        y += 1
        self.add(y, 2, "░██                release:   github", curses.A_BOLD)
        y += 2
        profile = self.cfg.get("DEPLOY_PROFILE", "local")
        domain = self.cfg.get("PUBLIC_DOMAIN") if profile == "public" else self.cfg.get("PSAI_DOMAIN", "psai.lan")
        self.add(y, 2, t("Статус:", "Status:"), self.colors["dim"])
        self.add(y, 12, f"{self.cfg.get('NODE_MODE', 'single')} · {profile} · {domain}", self.colors["blue"] | curses.A_BOLD)
        self.add(y + 1, 2, t("Стек:", "Stack:"), self.colors["dim"])
        self.add(y + 1, 12, self.cfg.get("STACK_NAME", "psai"), curses.A_BOLD)
        return y + 3

    def draw_host(self, y, info):
        h, w = self.stdscr.getmaxyx()
        y = self.section_header(y, t("Хост", "Host"))
        docker_ok = info.get("docker", "-") not in ("", "-") and "Cannot connect" not in info.get("docker", "")
        right_label = max(45, min(61, w // 3 + 11))
        right_value = right_label + 10
        self.kv_row(y, DOT_X, LABEL_X, 18, "HOST", info.get("host", "-"), self.colors["green"], curses.A_BOLD)
        self.add(y, right_label, "OS:", self.colors["dim"])
        self.add(y, right_value, info.get("os_arch", "-"), curses.A_BOLD)
        self.kv_row(y + 1, DOT_X, LABEL_X, 18, "RAM", f"{info.get('ram_live', '-')} live / {info.get('mem', '-')}", self.percent_attr(info.get("ram_live", "-")), self.percent_attr(info.get("ram_live", "-")))
        self.add(y + 1, right_label, "DOCKER:", self.colors["dim"])
        self.add(y + 1, right_value, info.get("docker", "-"), (self.colors["green"] if docker_ok else self.colors["red"]) | curses.A_BOLD)
        self.kv_row(y + 2, DOT_X, LABEL_X, 18, "CPU", f"{info.get('cpu_live', '-')} live / {info.get('cpu', '-')} cores", self.percent_attr(info.get("cpu_live", "-")), self.percent_attr(info.get("cpu_live", "-")))
        self.add(y + 2, right_label, "CTX:", self.colors["dim"])
        self.add(y + 2, right_value, info.get("docker_ctx", "-"), curses.A_BOLD)
        self.kv_row(y + 3, DOT_X, LABEL_X, 18, "DISK", info.get("disk", "-"), self.percent_attr(info.get("disk", "-")), self.percent_attr(info.get("disk", "-")))
        self.add(y + 3, right_label, "DIR:", self.colors["dim"])
        self.add(y + 3, right_value, info.get("stack_dir", "-"), self.colors["dim"])
        return y + 4

    def draw_network(self, y, refresh_live=True):
        h, w = self.stdscr.getmaxyx()
        stats = self.proxy_stats(refresh_live)
        comps = {c.get("svc"): c for c in self.components}
        y = self.section_header(y, t("Сеть", "Network"))
        rows = [
            ("proxy-stack", self.cfg.get("EGRESS_STACK", "none"), t("LLM + обновления компонентов стека", "LLM + stack component updates")),
            ("proxy-web", self.cfg.get("EGRESS_WEB", "none"), "web worker"),
        ]
        for i, (svc, mode, note) in enumerate(rows):
            slot = "stack" if svc == "proxy-stack" else "web"
            selected = self.target_selected("proxy", slot)
            comp = comps.get(svc, {})
            net = stats.get(comp.get("name", ""), "-")
            if selected:
                self.add(y + i, DOT_X - 2, "›", self.colors["cyan"] | curses.A_BOLD)
            self.add(y + i, DOT_X, "●", self.dot_attr(comp, selected) if comp else self.colors["yellow"])
            self.add(y + i, LABEL_X, f"{svc}:", curses.A_BOLD)
            self.add(y + i, 23, first(mode, default="none"), self.colors["cyan"] | curses.A_BOLD)
            self.add(y + i, 36, f"traffic: {net}", curses.A_BOLD)
            self.add(y + i, 66, note, self.colors["dim"])
        return y + len(rows) + 1

    def draw_security(self, y):
        h, w = self.stdscr.getmaxyx()
        y = self.section_header(y, t("Безопасность", "Security"))
        tls_mode = self.cfg.get("TLS_MODE", "-")
        tls_enabled = not is_falsey(tls_mode)
        values = [
            ("profile", self.cfg.get("SECURITY_PROFILE", "default")),
            ("tls", "true" if tls_enabled else "false"),
            ("vault", "true" if is_truthy(first(self.cfg.get("SEC_SEAL"), self.cfg.get("PSAI_SEC_SEAL"), default="-")) else "false"),
            ("firewall", "true" if is_truthy(first(self.cfg.get("SEC_FIREWALL"), self.cfg.get("PSAI_SEC_FIREWALL"), default="-")) else "false"),
            ("watchdog", "true" if is_truthy(first(self.cfg.get("SEC_WATCHDOG"), self.cfg.get("PSAI_SEC_WATCHDOG"), default="-")) else "false"),
        ]
        row = y
        x = DOT_X
        for idx, (key, value) in enumerate(values):
            sval = str(value)
            item_w = 2 + len(key) + 2 + len(sval)
            if idx > 0 and DOT_X + item_w < w and x + item_w >= w - 2:
                row += 1
                x = DOT_X
            attr = self.status_value_attr(sval)
            self.add(row, x, "●", attr)
            self.add(row, x + 2, f"{key}:", self.colors["dim"])
            self.add(row, x + len(key) + 4, sval, attr)
            x += item_w + 3
        return row + 2

    def draw(self, refresh_live=True):
        self.stdscr.erase()
        h, w = self.stdscr.getmaxyx()
        host = self.host_info(refresh_live)
        y = 1
        y = self.draw_banner(y)
        y = self.draw_host(y, host)
        y = self.draw_components(y)
        y = self.draw_network(y, refresh_live)
        y = self.draw_security(y)

        footer_y = max(0, h - 5)
        for row in range(footer_y, h):
            try:
                self.stdscr.move(row, 0)
                self.stdscr.clrtoeol()
            except curses.error:
                pass
        if self.mode == "components":
            target = self.current_target()
            title = t("L - состояние контейнера · R - рестарт контейнера · Ctrl+F - выход из интерактивного режима", "L - container status · R - restart container · Ctrl+F - leave interactive mode")
            if target[0] == "proxy":
                title = t("Enter - режим proxy · Ctrl+F - выход из интерактивного режима", "Enter - proxy mode · Ctrl+F - leave interactive mode")
            self.add(footer_y, 2, title, self.colors["cyan"] | curses.A_BOLD)
            if target[0] == "proxy":
                label = "proxy-stack" if target[1] == "stack" else "proxy-web"
                caption = t("Выбранный proxy:", "Selected proxy:")
            else:
                label = self.components[self.selected]["svc"] if self.components else "-"
                caption = t("Выбранный контейнер:", "Selected container:")
            self.add(footer_y + 2, 2, "➜", self.colors["cyan"] | curses.A_BOLD)
            self.add(footer_y + 2, 5, caption, self.colors["dim"])
            self.add(footer_y + 2, 27, label, curses.A_BOLD)
        else:
            self.add(footer_y, 2, t("Управление стеком", "Manage the stack"), self.colors["cyan"] | curses.A_BOLD)
            hot = t(
                "Ctrl+F интерактивный режим  Ctrl+I настройки  Ctrl+H список команд  Ctrl+Q Выход",
                "Ctrl+F interactive mode  Ctrl+I settings  Ctrl+H command list  Ctrl+Q Exit",
            )
            self.add(footer_y + 1, 2, hot, self.colors["dim"])
            self.add(footer_y + 3, 2, t("Команда:", "Command:"), curses.A_BOLD)
            self.add(footer_y + 3, 12, self.command, curses.A_BOLD)
        if self.message:
            self.add(h - 1, 2, clip(self.message, w - 4), self.colors["yellow"])
        self.stdscr.refresh()
        self.last_draw = time.time()

    def selected_service(self):
        if not self.components:
            return ""
        return self.components[self.selected]["svc"]

    def output_screen(self, title, output):
        lines = output.splitlines() or [""]
        pos = max(0, len(lines) - (self.stdscr.getmaxyx()[0] - 5))
        self.stdscr.timeout(-1)
        try:
            while True:
                self.stdscr.erase()
                h, w = self.stdscr.getmaxyx()
                self.add(1, 2, title, self.colors["cyan"] | curses.A_BOLD)
                self.add(2, 2, t("↑/↓ прокрутка · любая другая клавиша назад", "↑/↓ scroll · any other key back"), self.colors["dim"])
                view_h = h - 5
                for i, line in enumerate(lines[pos : pos + view_h]):
                    self.add(4 + i, 2, line)
                self.stdscr.refresh()
                k = self.stdscr.getch()
                if k == curses.KEY_UP:
                    pos = max(0, pos - 1)
                elif k == curses.KEY_DOWN:
                    pos = min(max(0, len(lines) - view_h), pos + 1)
                else:
                    break
        finally:
            self.stdscr.timeout(KEY_TIMEOUT_MS)

    def run_psai(self, args, title=None, timeout=120):
        self.message = t("выполняю...", "running...")
        self.draw(refresh_live=False)
        out = run([str(BIN_PSAI), *args], timeout=timeout)
        self.load_components()
        self.message = ""
        self.output_screen(title or " ".join(args), out)

    def restart_service(self, svc):
        if not svc:
            return
        self.message = t("рестарт контейнера...", "restarting container...")
        self.draw(refresh_live=False)
        out = run(compose_cmd("restart", svc), timeout=120)
        self.load_components()
        self.message = ""
        self.output_screen(f"restart {svc}", out)

    def set_env_values(self, updates):
        current = {}
        lines = []
        if ENV_FILE.exists():
            for raw in ENV_FILE.read_text(errors="ignore").splitlines():
                if raw.strip() and not raw.lstrip().startswith("#") and "=" in raw:
                    key = raw.split("=", 1)[0].strip()
                    current[key] = True
                    if key in updates:
                        lines.append(f"{key}={shlex.quote(str(updates[key]))}")
                    else:
                        lines.append(raw)
                else:
                    lines.append(raw)
        for key, value in updates.items():
            if key not in current:
                lines.append(f"{key}={shlex.quote(str(value))}")
        ENV_FILE.write_text("\n".join(lines).rstrip() + "\n")
        self.cfg = parse_env(ENV_FILE)

    def set_language(self, lang):
        global LANG
        if lang not in ("ru", "en"):
            return
        LANG = lang
        self.set_env_values({"UI_LANG_SAVED": lang})
        try:
            store = Path.home() / ".config" / "psai" / "lang"
            store.parent.mkdir(parents=True, exist_ok=True)
            store.write_text(lang + "\n")
        except Exception:
            pass
        self.message = t("язык переключен", "language switched")

    def language_screen(self):
        idx = 0 if LANG == "ru" else 1
        items = [("Русский", "ru"), ("English", "en"), (t("Назад", "Back"), "back")]
        self.stdscr.timeout(-1)
        try:
            while True:
                self.stdscr.erase()
                h, w = self.stdscr.getmaxyx()
                self.add(1, 2, t("ЯЗЫК", "LANGUAGE"), self.colors["cyan"] | curses.A_BOLD)
                self.add(2, 2, "═" * min(44, w - 4), self.colors["cyan"])
                for i, (label, lang) in enumerate(items):
                    y = 5 + i
                    selected = i == idx
                    marker = "●" if lang == LANG else " "
                    self.add(y, 4, "›" if selected else " ", self.colors["cyan"] | curses.A_BOLD)
                    self.add(y, 7, marker, self.colors["green"] | curses.A_BOLD if lang == LANG else self.colors["dim"])
                    self.add(y, 10, label, curses.A_BOLD if selected else 0)
                self.add(h - 2, 2, t("↑/↓ выбор · Enter применить · 0/Esc назад · Ctrl+Q выход", "↑/↓ choose · Enter apply · 0/Esc back · Ctrl+Q exit"), self.colors["dim"])
                self.stdscr.refresh()
                k = self.stdscr.getch()
                if k in (17, ord("q"), ord("Q")):
                    raise SystemExit
                if k in (ord("0"), 27, 6):
                    return
                if k == curses.KEY_UP:
                    idx = (idx - 1) % len(items)
                elif k == curses.KEY_DOWN:
                    idx = (idx + 1) % len(items)
                elif k in (10, 13):
                    lang = items[idx][1]
                    if lang == "back":
                        return
                    self.set_language(lang)
                    return
        finally:
            self.stdscr.timeout(KEY_TIMEOUT_MS)

    def notice_screen(self, title, body, ok=True):
        lines = str(body).splitlines() or [""]
        self.stdscr.timeout(-1)
        try:
            self.stdscr.erase()
            h, w = self.stdscr.getmaxyx()
            attr = self.colors["green"] if ok else self.colors["red"]
            self.add(1, 2, title, self.colors["cyan"] | curses.A_BOLD)
            self.add(2, 2, "═" * min(44, w - 4), self.colors["cyan"])
            self.add(4, 2, "●", attr | curses.A_BOLD)
            for i, line in enumerate(lines[: max(1, h - 8)]):
                self.add(4 + i, 5, line, curses.A_BOLD if i == 0 else 0)
            self.add(h - 2, 2, t("любая клавиша назад", "any key back"), self.colors["dim"])
            self.stdscr.refresh()
            self.stdscr.getch()
        finally:
            self.stdscr.timeout(KEY_TIMEOUT_MS)

    def apply_proxy_modes(self, stack_mode=None, web_mode=None):
        updates = {
            "STACK_VIA_PROXY": "true",
            "WEB_VIA_PROXY": "true",
            "ROUTE_LOCAL_LLM": "true",
        }
        if stack_mode is not None:
            updates["EGRESS_STACK"] = stack_mode
        if web_mode is not None:
            updates["EGRESS_WEB"] = web_mode
        self.set_env_values(updates)
        label = f"proxy-stack={updates.get('EGRESS_STACK', self.cfg.get('EGRESS_STACK', 'none'))} proxy-web={updates.get('EGRESS_WEB', self.cfg.get('EGRESS_WEB', 'none'))}"
        self.message = t("применяю proxy...", "applying proxy...")
        self.draw(refresh_live=False)
        args = [str(BIN_PSAI), "proxy-apply"]
        if stack_mode is not None:
            args.extend(["stack", stack_mode])
        if web_mode is not None:
            args.extend(["web", web_mode])
        rc, out = run_result(args, timeout=900)
        self.load_components()
        self.proxy_cache = {}
        self.proxy_last = 0.0
        self.message = ""
        if rc == 0:
            self.notice_screen(t("Proxy применён", "Proxy applied"), label, True)
        else:
            tail = "\n".join(out.splitlines()[-6:]) if out else t("команда завершилась ошибкой", "command failed")
            self.notice_screen(t("Proxy не применён", "Proxy failed"), f"{label}\n\n{tail}", False)

    def toggle_proxy(self, which):
        cur_stack = self.cfg.get("EGRESS_STACK", "none")
        cur_web = self.cfg.get("EGRESS_WEB", "none")
        if which == "stack":
            self.apply_proxy_modes(stack_mode="none" if cur_stack == "tor" else "tor")
        elif which == "web":
            self.apply_proxy_modes(web_mode="none" if cur_web == "tor" else "tor")
        else:
            target = "none" if cur_stack == "tor" and cur_web == "tor" else "tor"
            self.apply_proxy_modes(stack_mode=target, web_mode=target)

    def prompt_line(self, title, label, secret=False):
        self.stdscr.timeout(-1)
        try:
            self.stdscr.erase()
            try:
                curses.curs_set(1)
            except curses.error:
                pass
            curses.noecho() if secret else curses.echo()
            self.add(1, 2, title, self.colors["cyan"] | curses.A_BOLD)
            self.add(3, 2, label, self.colors["dim"])
            self.add(5, 2, "> ", curses.A_BOLD)
            self.stdscr.refresh()
            raw = self.stdscr.getstr(5, 4, 4096)
            return raw.decode("utf-8", "ignore").strip()
        finally:
            curses.noecho()
            try:
                curses.curs_set(0)
            except curses.error:
                pass
            self.stdscr.timeout(KEY_TIMEOUT_MS)

    def configure_proxy_mode(self, slot, mode):
        gateway_dir = STACK_DIR / ("gateway-stack" if slot == "stack" else "gateway-web")
        gateway_dir.mkdir(parents=True, exist_ok=True)
        if mode == "wireguard":
            path = self.prompt_line(
                t("WireGuard", "WireGuard"),
                t("Путь к WireGuard .conf", "Path to WireGuard .conf"),
            )
            if not path:
                return
            src = Path(path).expanduser()
            if not src.exists():
                self.message = t("файл не найден", "file not found")
                return
            (gateway_dir / "wg0.conf").write_bytes(src.read_bytes())
            os.chmod(gateway_dir / "wg0.conf", 0o600)
        elif mode == "vless":
            uri = self.prompt_line("VLESS", "VLESS URI (vless://...)")
            if not uri:
                return
            (gateway_dir / "vless-uri.txt").write_text(uri + "\n")
            os.chmod(gateway_dir / "vless-uri.txt", 0o600)
        elif mode == "tailscale":
            key = self.prompt_line(
                t("Tailscale", "Tailscale"),
                t("Ключ авторизации Tailscale", "Tailscale auth key"),
                secret=True,
            )
            if not key:
                return
            (gateway_dir / "tailscale.env").write_text(f"TS_AUTHKEY={key}\nTS_EXTRA_ARGS=\n")
            os.chmod(gateway_dir / "tailscale.env", 0o600)
        if slot == "stack":
            self.apply_proxy_modes(stack_mode=mode)
        else:
            self.apply_proxy_modes(web_mode=mode)

    def proxy_control_screen(self, slot):
        idx = 0
        title = "proxy-stack" if slot == "stack" else "proxy-web"
        while True:
            cur = self.cfg.get("EGRESS_STACK" if slot == "stack" else "EGRESS_WEB", "none")
            items = [
                (t("Прямой режим", "Direct mode"), lambda: self.configure_proxy_mode(slot, "none")),
                ("Tor", lambda: self.configure_proxy_mode(slot, "tor")),
                (t("WireGuard: указать .conf", "WireGuard: set .conf"), lambda: self.configure_proxy_mode(slot, "wireguard")),
                ("VLESS: URI", lambda: self.configure_proxy_mode(slot, "vless")),
                (t("Tailscale: auth key", "Tailscale: auth key"), lambda: self.configure_proxy_mode(slot, "tailscale")),
                (t("Назад", "Back"), None),
            ]
            self.stdscr.timeout(-1)
            try:
                self.stdscr.erase()
                h, w = self.stdscr.getmaxyx()
                self.add(1, 2, title, self.colors["cyan"] | curses.A_BOLD)
                self.add(2, 2, "═" * min(44, w - 4), self.colors["cyan"])
                self.add(4, 2, t("Текущий режим:", "Current mode:"), self.colors["dim"])
                self.add(4, 18, cur, self.colors["cyan"] | curses.A_BOLD)
                for i, (label, _) in enumerate(items):
                    y = 6 + i
                    self.add(y, 4, "›" if i == idx else " ", self.colors["cyan"] | curses.A_BOLD)
                    self.add(y, 7, label, curses.A_BOLD if i == idx else 0)
                self.add(h - 2, 2, t("↑/↓ выбор · Enter выполнить · 0/Esc назад · Ctrl+Q выход", "↑/↓ choose · Enter run · 0/Esc back · Ctrl+Q exit"), self.colors["dim"])
                self.stdscr.refresh()
                k = self.stdscr.getch()
                if k in (17, ord("q"), ord("Q")):
                    raise SystemExit
                if k in (ord("0"), 27, 6):
                    return
                if k == curses.KEY_UP:
                    idx = (idx - 1) % len(items)
                elif k == curses.KEY_DOWN:
                    idx = (idx + 1) % len(items)
                elif k in (10, 13):
                    action = items[idx][1]
                    if action is None:
                        return
                    action()
                    return
            finally:
                self.stdscr.timeout(KEY_TIMEOUT_MS)

    def container_status(self, svc):
        if not svc:
            return
        cid = run(compose_cmd("ps", "-q", svc), timeout=10).strip()
        parts = [run(compose_cmd("ps", "-a", svc), timeout=10).strip()]
        if cid:
            inspect = run(
                [
                    "docker",
                    "inspect",
                    "--format",
                    "Name: {{.Name}}\nImage: {{.Config.Image}}\nState: {{.State.Status}}\nHealth: {{if .State.Health}}{{.State.Health.Status}}{{else}}no-check{{end}}\nStarted: {{.State.StartedAt}}\nRestartCount: {{.RestartCount}}\nPorts: {{json .NetworkSettings.Ports}}\nNetworks: {{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{$v.IPAddress}}\n{{end}}",
                    cid,
                ],
                timeout=10,
            ).strip()
            stats = run(["docker", "stats", "--no-stream", "--format", "CPU: {{.CPUPerc}}\nMEM: {{.MemUsage}}\nNET: {{.NetIO}}\nBLOCK: {{.BlockIO}}", cid], timeout=8).strip()
            logs = run(compose_cmd("logs", "--tail=20", svc), timeout=30).strip()
            parts.extend(["", inspect, "", stats, "", t("Последние 20 строк docker logs:", "Last 20 docker log lines:"), logs])
        self.output_screen(t(f"Состояние {svc}", f"Status {svc}"), "\n".join(parts))

    def section_menu(self, title, items):
        idx = 0
        while True:
            self.stdscr.erase()
            self.add(1, 2, title, self.colors["cyan"] | curses.A_BOLD)
            for i, (label, _) in enumerate(items, 1):
                self.add(3 + i, 4, f"[{i}] {label}", curses.A_BOLD if i - 1 == idx else 0)
            self.add(5 + len(items), 4, "[0] back", self.colors["dim"])
            self.stdscr.refresh()
            k = self.stdscr.getch()
            if k in (ord("0"), 27, 6):
                return
            if k == curses.KEY_UP:
                idx = (idx - 1) % len(items)
            elif k == curses.KEY_DOWN:
                idx = (idx + 1) % len(items)
            elif ord("1") <= k <= ord(str(min(9, len(items)))):
                items[k - ord("1")][1]()
                return
            elif k in (10, 13):
                items[idx][1]()
                return

    def settings_screen(self):
        while True:
            self.stdscr.timeout(-1)
            try:
                svc = self.selected_service() or "-"
                stack_is_running = any(c.get("state") == "running" for c in self.components)
                items = []
                if not stack_is_running:
                    items.append((t("Управление", "Manage"), "start", lambda: self.run_psai(["start"], "start")))
                items.extend([
                    (t("Управление", "Manage"), "stop", lambda: self.run_psai(["stop"], "stop")),
                    (t("Управление", "Manage"), "restart", lambda: self.run_psai(["restart"], "restart")),
                    (t("Управление", "Manage"), "status", lambda: self.run_psai(["status"], "status")),
                    (t("Данные", "Data"), "backup", lambda: self.run_psai(["backup"], "backup", 300)),
                    (t("Данные", "Data"), "update", lambda: self.run_psai(["update"], "update", 600)),
                    (t("Данные", "Data"), "rebuild", lambda: self.run_psai(["rebuild"], "rebuild", 600)),
                    (t("Сеть", "Network"), f"proxy-stack ({self.cfg.get('EGRESS_STACK', 'none')})", lambda: self.proxy_control_screen("stack")),
                    (t("Сеть", "Network"), f"proxy-web ({self.cfg.get('EGRESS_WEB', 'none')})", lambda: self.proxy_control_screen("web")),
                    (t("Сеть", "Network"), t("оба proxy none/tor", "both proxies none/tor"), lambda: self.toggle_proxy("both")),
                    (t("Безопасность", "Security"), "security", lambda: self.run_psai(["security"], "security")),
                    (t("Безопасность", "Security"), "watchdog", lambda: self.run_psai(["watchdog"], "watchdog")),
                    (t("Безопасность", "Security"), "trust-ca", lambda: self.run_psai(["trust-ca"], "trust-ca")),
                    (t("Безопасность", "Security"), "hosts", lambda: self.run_psai(["hosts"], "hosts")),
                    (t("Безопасность", "Security"), "seal/unseal", lambda: self.run_psai(["seal"], "seal/unseal")),
                    (t("Контейнеры", "Containers"), t(f"состояние {svc}", f"status {svc}"), lambda: self.container_status(self.selected_service())),
                    (t("Контейнеры", "Containers"), t(f"логи {svc}", f"logs {svc}"), lambda: self.output_screen(f"logs {self.selected_service()}", run(compose_cmd("logs", "--tail=220", self.selected_service()), timeout=60))),
                    (t("Контейнеры", "Containers"), t(f"рестарт {svc}", f"restart {svc}"), lambda: self.restart_service(self.selected_service())),
                    (t("Настройки", "Settings"), t("Язык", "Language"), self.language_screen),
                    (t("Настройки", "Settings"), t("список команд", "command list"), self.command_help),
                    (t("Настройки", "Settings"), t("выход", "exit"), lambda: (_ for _ in ()).throw(SystemExit)),
                ])
                idx = 0
                while True:
                    self.stdscr.erase()
                    h, w = self.stdscr.getmaxyx()
                    title = t("НАСТРОЙКИ", "SETTINGS")
                    self.add(1, 2, title, self.colors["cyan"] | curses.A_BOLD)
                    self.add(2, 2, "═" * min(44, w - 4), self.colors["cyan"])
                    y = 5
                    last_group = None
                    visible = max(1, h - 9)
                    start = max(0, min(idx - visible // 2, len(items) - visible))
                    for n, (group, label, _) in enumerate(items[start : start + visible], start + 1):
                        if group != last_group:
                            self.add(y, 2, group, self.colors["cyan"] | curses.A_BOLD)
                            y += 1
                            last_group = group
                        selected = n - 1 == idx
                        self.add(y, 4, "›" if selected else " ", self.colors["cyan"] | curses.A_BOLD)
                        self.add(y, 7, label, curses.A_BOLD if selected else 0)
                        y += 1
                    self.add(h - 2, 2, t("↑/↓ выбор · Enter выполнить · 0/Esc назад · Ctrl+Q выход", "↑/↓ choose · Enter run · 0/Esc back · Ctrl+Q exit"), self.colors["dim"])
                    self.stdscr.refresh()
                    k = self.stdscr.getch()
                    if k in (17, ord("q"), ord("Q")):
                        raise SystemExit
                    if k in (ord("0"), 27, 6):
                        return
                    if k == curses.KEY_UP:
                        idx = (idx - 1) % len(items)
                    elif k == curses.KEY_DOWN:
                        idx = (idx + 1) % len(items)
                    elif k in (10, 13):
                        items[idx][2]()
                        break
            finally:
                self.stdscr.timeout(KEY_TIMEOUT_MS)

    def command_help(self):
        body = "\n".join(
            [
                t("Горячие клавиши", "Hotkeys"),
                "  Ctrl+F  " + t("интерактивный выбор контейнеров", "interactive container selection"),
                "  Ctrl+I  " + t("экран настроек и действий", "settings and actions screen"),
                "  Ctrl+H  " + t("этот список команд", "this command list"),
                "  Ctrl+Q  " + t("выход из дашборда", "exit dashboard"),
                "",
                t("Интерактивный режим", "Interactive mode"),
                "  ↑/↓/←/→ " + t("выбор контейнера или proxy-строки", "select container or proxy row"),
                "  L      " + t("состояние контейнера + последние 20 строк логов", "container status + last 20 log lines"),
                "  R      " + t("рестарт выбранного контейнера", "restart selected container"),
                "  Enter  " + t("режим proxy-stack/proxy-web, если выбрана proxy-строка", "proxy-stack/proxy-web mode when a proxy row is selected"),
                "",
                t("Команды", "Commands"),
                "  start      " + t("запустить стек", "start stack"),
                "  stop       " + t("остановить стек", "stop stack"),
                "  restart    " + t("перезапустить стек", "restart stack"),
                "  status     " + t("вывести статус стека", "print stack status"),
                "  logs [svc] " + t("логи всего стека или сервиса", "logs for stack or service"),
                "  update     " + t("обновить образы и пересобрать", "update images and rebuild"),
                "  rebuild    " + t("перегенерировать конфиг и поднять", "regenerate config and start"),
                "  proxy      " + t("настройки proxy-stack/proxy-web", "proxy-stack/proxy-web settings"),
                "  security   " + t("профиль безопасности", "security profile"),
                "  watchdog   " + t("watchdog сервиса", "service watchdog"),
                "  backup     " + t("зашифрованный backup", "encrypted backup"),
                "  restore    " + t("восстановление из backup", "restore from backup"),
                "  uninstall  " + t("удаление стека", "remove stack"),
                "  lang       " + t("смена языка", "change language"),
                "  quit       " + t("выход", "exit"),
                "",
                t("Ctrl+F интерактивный режим, Ctrl+I настройки, Ctrl+Q выход", "Ctrl+F interactive mode, Ctrl+I settings, Ctrl+Q exit"),
            ]
        )
        self.output_screen(t("Список команд", "Command list"), body)

    def execute_command(self):
        cmd = self.command.strip()
        self.command = ""
        if not cmd:
            return
        if cmd in ("quit", "exit"):
            raise SystemExit
        parts = shlex.split(cmd)
        if parts[0] == "logs":
            svc = parts[1] if len(parts) > 1 else self.selected_service()
            out = run(compose_cmd("logs", "--tail=220", svc), timeout=60)
            self.output_screen(f"logs {svc}", out)
            return
        self.run_psai(parts, cmd)

    def loop(self):
        self.load_components()
        dirty = True
        input_dirty = False
        while True:
            now = time.time()
            refreshed = False
            if now - self.last_refresh > COMPONENT_REFRESH_SEC:
                self.load_components()
                dirty = True
                refreshed = True
            timed_draw = now - self.last_draw > DRAW_REFRESH_SEC
            if dirty or timed_draw:
                self.draw(refresh_live=refreshed or (timed_draw and not input_dirty))
                dirty = False
                input_dirty = False
            k = self.stdscr.getch()
            if k == -1:
                continue
            self.message = ""
            input_dirty = True
            if k in (17,):  # Ctrl+Q
                raise SystemExit
            if k in (3,):  # Ctrl+C, raw mode.
                self.mode = "components"
                dirty = True
                continue
            if k == 6:  # Ctrl+F
                self.mode = "command" if self.mode == "components" else "components"
                dirty = True
                continue
            if k == 8:  # Ctrl+H
                self.command_help()
                dirty = True
                continue
            if k == 18:  # Ctrl+R
                self.settings_screen()
                dirty = True
                continue
            if k == 4:  # Ctrl+D
                self.settings_screen()
                dirty = True
                continue
            if k == 14:  # Ctrl+N
                self.settings_screen()
                dirty = True
                continue
            if k == 9:  # Ctrl+I
                self.settings_screen()
                dirty = True
                continue

            if self.mode == "components":
                targets = self.interactive_targets()
                if k == curses.KEY_UP:
                    self.focus_index = (self.focus_index - 1) % max(1, len(targets))
                    self.current_target()
                    dirty = True
                elif k == curses.KEY_DOWN:
                    self.focus_index = (self.focus_index + 1) % max(1, len(targets))
                    self.current_target()
                    dirty = True
                elif k == curses.KEY_LEFT:
                    half = (len(self.components) + 1) // 2
                    self.focus_index = (self.focus_index - half) % max(1, len(targets))
                    self.current_target()
                    dirty = True
                elif k == curses.KEY_RIGHT:
                    half = (len(self.components) + 1) // 2
                    self.focus_index = (self.focus_index + half) % max(1, len(targets))
                    self.current_target()
                    dirty = True
                elif k in (ord("l"), ord("L")):
                    target = self.current_target()
                    if target[0] == "container":
                        self.container_status(self.selected_service())
                    dirty = True
                elif k in (ord("r"), ord("R")):
                    target = self.current_target()
                    if target[0] == "container":
                        self.restart_service(self.selected_service())
                    elif target[0] == "proxy":
                        self.proxy_control_screen(target[1])
                    dirty = True
                elif k in (10, 13):
                    target = self.current_target()
                    if target[0] == "proxy":
                        self.proxy_control_screen(target[1])
                    dirty = True
                continue

            if k in (10, 13):
                self.execute_command()
                dirty = True
            elif k in (27,):
                self.command = ""
                dirty = True
            elif k in (curses.KEY_BACKSPACE, 127, 8):
                self.command = self.command[:-1]
                dirty = True
            elif 32 <= k <= 126:
                self.command += chr(k)
                dirty = True


def main(stdscr):
    Dashboard(stdscr).loop()


if __name__ == "__main__":
    try:
        curses.wrapper(main)
    except SystemExit:
        pass
