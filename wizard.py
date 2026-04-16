#!/usr/bin/env python3
"""
OpenClaw Interactive Setup Wizard
Guides you through configuring .env, config.json, and running all setup steps.
Usage: python3 wizard.py  (or: make wizard)
"""

import getpass
import json
import os
import re
import shutil
import subprocess
import sys

# ---------------------------------------------------------------------------
# ANSI colors (disabled when stdout is not a tty or when piped)
# ---------------------------------------------------------------------------
_TTY = sys.stdout.isatty()

def _c(code: str) -> str:
    return code if _TTY else ""

BOLD   = _c("\033[1m")
RESET  = _c("\033[0m")
RED    = _c("\033[31m")
YELLOW = _c("\033[33m")
GREEN  = _c("\033[32m")
CYAN   = _c("\033[36m")
DIM    = _c("\033[2m")

# ---------------------------------------------------------------------------
# Project root detection
# ---------------------------------------------------------------------------
PROJECT_ROOT = os.path.dirname(os.path.abspath(__file__))
STATE_FILE   = os.path.join(PROJECT_ROOT, ".wizard-state.json")
ENV_FILE     = os.path.join(PROJECT_ROOT, ".env")
ENV_EXAMPLE  = os.path.join(PROJECT_ROOT, ".env.example")
CONFIG_FILE  = os.path.join(PROJECT_ROOT, "config.json")
CONFIG_EXAMPLE = os.path.join(PROJECT_ROOT, "config.example.json")
GITIGNORE    = os.path.join(PROJECT_ROOT, ".gitignore")

# ---------------------------------------------------------------------------
# Terminal helpers
# ---------------------------------------------------------------------------
def _cols() -> int:
    return shutil.get_terminal_size(fallback=(72, 24)).columns

def banner(text: str) -> None:
    w = min(_cols(), 72)
    line = "=" * w
    print(f"\n{BOLD}{CYAN}{line}{RESET}")
    print(f"{BOLD}{CYAN}  {text}{RESET}")
    print(f"{BOLD}{CYAN}{line}{RESET}\n")

def section(text: str) -> None:
    print(f"\n{BOLD}{CYAN}--- {text} ---{RESET}")

def info(text: str) -> None:
    print(f"{GREEN}  ✓{RESET} {text}")

def warn(text: str) -> None:
    print(f"{YELLOW}  ⚠{RESET}  {YELLOW}{text}{RESET}")

def error(text: str) -> None:
    print(f"{RED}  ✗{RESET}  {RED}{text}{RESET}")

def step_header(n: int, total: int, text: str) -> None:
    print(f"\n{BOLD}Step {n}/{total}: {text}{RESET}")

def box(lines: list) -> None:
    """Print a highlighted info box."""
    w = max(len(l) for l in lines) + 4
    print(f"{CYAN}┌{'─'*(w-2)}┐{RESET}")
    for l in lines:
        pad = w - 2 - len(l) - 2
        print(f"{CYAN}│{RESET}  {l}{' '*pad}{CYAN}│{RESET}")
    print(f"{CYAN}└{'─'*(w-2)}┘{RESET}")

# ---------------------------------------------------------------------------
# Prompt helpers
# ---------------------------------------------------------------------------
def prompt(label: str, default: str = "", validator=None, password: bool = False) -> str:
    """
    Prompt user for input.
    - Shows [default] hint when default is non-empty.
    - Uses getpass for password fields.
    - Loops until validator passes (or no validator).
    """
    hint = f" [{DIM}{default}{RESET}]" if default else ""
    full_label = f"  {BOLD}{label}{RESET}{hint}: "

    while True:
        if password:
            value = getpass.getpass(prompt=full_label)
        else:
            try:
                value = input(full_label).strip()
            except EOFError:
                value = ""

        if value == "" and default:
            value = default

        if validator is None or validator(value):
            return value

        error(f"Invalid value '{value}'. Please try again.")


def prompt_yn(label: str, default: bool = True) -> bool:
    """Yes/no prompt. Returns bool."""
    hint = "[Y/n]" if default else "[y/N]"
    full_label = f"  {BOLD}{label}{RESET} {hint}: "
    while True:
        try:
            value = input(full_label).strip().lower()
        except EOFError:
            value = ""
        if value in ("", "y", "yes", "n", "no"):
            if value == "":
                return default
            return value in ("y", "yes")
        error("Please type y or n.")


def prompt_choice(label: str, options: list, default: int = 1) -> int:
    """Numbered choice menu. Returns 1-based selection index."""
    print(f"\n  {BOLD}{label}{RESET}")
    for i, opt in enumerate(options, 1):
        marker = f"{GREEN}▶{RESET} " if i == default else "  "
        print(f"  {marker}{i}) {opt}")
    while True:
        try:
            raw = input(f"  Select [{default}]: ").strip()
        except EOFError:
            raw = ""
        if raw == "":
            return default
        if raw.isdigit() and 1 <= int(raw) <= len(options):
            return int(raw)
        error(f"Enter a number between 1 and {len(options)}.")


# ---------------------------------------------------------------------------
# Validators
# ---------------------------------------------------------------------------
def valid_port(s: str) -> bool:
    return s.isdigit() and 1 <= int(s) <= 65535

def valid_ip(s: str) -> bool:
    return bool(re.match(r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$', s))

def valid_cidr(s: str) -> bool:
    return bool(re.match(r'^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$', s))

def valid_abspath(s: str) -> bool:
    bad = ('/', '/usr', '/bin', '/etc', '/lib', '/lib64', '/sbin', '/proc', '/sys', '/dev')
    return s.startswith('/') and s not in bad

# ---------------------------------------------------------------------------
# State file
# ---------------------------------------------------------------------------
def load_state() -> dict:
    if os.path.exists(STATE_FILE):
        try:
            with open(STATE_FILE) as f:
                return json.load(f)
        except (json.JSONDecodeError, OSError):
            pass
    return {"wizard_version": 1, "agent_mode": None, "completed_steps": [], "host_setup": {}}

def save_state(state: dict) -> None:
    with open(STATE_FILE, "w") as f:
        json.dump(state, f, indent=2)
    # Ensure .wizard-state.json is in .gitignore
    _ensure_gitignore(".wizard-state.json")

def mark_done(state: dict, step: str) -> None:
    if step not in state["completed_steps"]:
        state["completed_steps"].append(step)
    save_state(state)

def is_done(state: dict, step: str) -> bool:
    return step in state["completed_steps"]

# ---------------------------------------------------------------------------
# .gitignore helper
# ---------------------------------------------------------------------------
def _ensure_gitignore(entry: str) -> None:
    if not os.path.exists(GITIGNORE):
        return
    with open(GITIGNORE) as f:
        content = f.read()
    if entry not in content.splitlines():
        with open(GITIGNORE, "a") as f:
            f.write(f"\n{entry}\n")

# ---------------------------------------------------------------------------
# .env reader / writer
# ---------------------------------------------------------------------------
ENV_DEFAULTS = {
    "NGINX_HTTP_PORT": "8090",
    "DASHBOARD_USER": "agent-dev",
    "DASHBOARD_PASSWORD": "",
    "AGENT_USER": "dev-bot",
    "CHROOT_BASE": "/srv/chroot/dev-bot",
    "AGENT_CONTAINER_NAME": "agent-dev",
    "NGINX_CONTAINER_NAME": "agent-dev-nginx",
    "AGENT_NETWORK_NAME": "agent-dev-net",
    "EXPECTED_AGENT_IP": "172.28.0.10",
    "EXPECTED_NGINX_IP": "172.28.0.20",
    "AGENT_SUBNET": "",
    "AGENT_GATEWAY": "",
}

def read_env(path: str) -> dict:
    """Parse KEY=value pairs from an env file, stripping inline comments."""
    result = {}
    if not os.path.exists(path):
        return result
    with open(path) as f:
        for line in f:
            line = line.rstrip("\n")
            if line.startswith("#") or "=" not in line:
                continue
            key, rest = line.split("=", 1)
            key = key.strip()
            # Strip inline comment
            value = re.sub(r'\s+#.*$', '', rest).strip()
            result[key] = value
    return result

def write_env(path: str, values: dict) -> None:
    """
    Write .env by templating .env.example, substituting collected values.
    Preserves comment structure. Optional fields left as commented-out lines.
    """
    optional = {"AGENT_SUBNET", "AGENT_GATEWAY"}

    with open(ENV_EXAMPLE) as f:
        template_lines = f.readlines()

    out_lines = []
    for line in template_lines:
        stripped = line.rstrip("\n")
        # Match KEY=value lines (possibly with trailing comment)
        m = re.match(r'^([A-Z_]+)=([^#\n]*)(#.*)?$', stripped)
        if m:
            key = m.group(1)
            comment = (" " + m.group(3)) if m.group(3) else ""
            if key in values:
                val = values[key]
                if key in optional and not val:
                    # Write as commented-out example
                    out_lines.append(f"# {key}=\n")
                else:
                    out_lines.append(f"{key}={val}{comment}\n")
            else:
                out_lines.append(line if line.endswith("\n") else line + "\n")
        else:
            out_lines.append(line if line.endswith("\n") else line + "\n")

    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.writelines(out_lines)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)

# ---------------------------------------------------------------------------
# config.json helpers
# ---------------------------------------------------------------------------
def read_config() -> dict:
    if not os.path.exists(CONFIG_FILE):
        return {"ssh_hosts": []}
    try:
        with open(CONFIG_FILE) as f:
            return json.load(f)
    except json.JSONDecodeError as e:
        error(f"config.json is malformed: {e}")
        print("  Fix it manually or delete it to start over, then re-run the wizard.")
        sys.exit(1)

def write_config(data: dict) -> None:
    tmp = CONFIG_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(tmp, CONFIG_FILE)

# ---------------------------------------------------------------------------
# Subprocess runner
# ---------------------------------------------------------------------------
def run_cmd(cmd: str, capture: bool = False):
    """
    Run a shell command in PROJECT_ROOT.
    Streams output live when capture=False.
    Returns (returncode, stdout_text) when capture=True.
    """
    kwargs = dict(shell=True, cwd=PROJECT_ROOT)
    if capture:
        kwargs["capture_output"] = True
        kwargs["text"] = True
    result = subprocess.run(cmd, **kwargs)
    if capture:
        return result.returncode, result.stdout
    return result.returncode, None


def run_step_with_retry(cmd: str, capture: bool = False):
    """
    Run a command with Retry/skip/abort prompt on failure.
    Returns (success, stdout).
    """
    while True:
        rc, stdout = run_cmd(cmd, capture=capture)
        if rc == 0:
            return True, stdout
        error(f"Command failed (exit {rc}): {cmd}")
        print()
        options = ["Retry", "Skip this step", "Abort wizard"]
        choice = prompt_choice("What would you like to do?", options, default=1)
        if choice == 1:
            continue
        if choice == 2:
            warn("Skipping this step.")
            return False, None
        # Abort
        print(f"\n{BOLD}Wizard aborted.{RESET} Re-run 'make wizard' to resume.\n")
        sys.exit(1)

# ---------------------------------------------------------------------------
# PHASE 0: Prerequisites
# ---------------------------------------------------------------------------
def phase_prerequisites() -> None:
    banner("OpenClaw Setup Wizard")
    print("  This wizard will guide you through configuring and starting OpenClaw.")
    print("  Press Ctrl-C at any time to exit. Re-run to resume where you left off.\n")

    # Verify CWD is project root
    if not (os.path.exists(os.path.join(PROJECT_ROOT, "Makefile")) and
            os.path.exists(CONFIG_EXAMPLE)):
        error("Run this wizard from the OpenClaw project root directory.")
        sys.exit(1)

    # Python version
    if sys.version_info < (3, 6):
        error(f"Python 3.6+ required (you have {sys.version}).")
        sys.exit(1)

    # Docker
    rc, _ = run_cmd("docker info > /dev/null 2>&1")
    if rc != 0:
        error("Docker is not running or not installed.")
        print("  Install Docker: https://docs.docker.com/engine/install/")
        sys.exit(1)

    info("Docker is running.")
    info(f"Python {sys.version.split()[0]} detected.")

# ---------------------------------------------------------------------------
# PHASE 1: .env configuration
# ---------------------------------------------------------------------------
def phase_env(state: dict) -> dict:
    section("Phase 1 — Environment Configuration (.env)")

    existing = read_env(ENV_FILE) if os.path.exists(ENV_FILE) else {}

    if existing:
        print(f"  {YELLOW}.env already exists.{RESET}")
        print("  Existing values will be used as defaults.")
        print("  Type 'skip' at the first prompt to keep .env unchanged.\n")
        skip_hint = True
    else:
        skip_hint = False

    # Merge: defaults → existing file values
    defaults = dict(ENV_DEFAULTS)
    defaults.update(existing)

    # Collect values
    values = {}

    # NGINX_HTTP_PORT
    raw = prompt("NGINX_HTTP_PORT", default=defaults["NGINX_HTTP_PORT"],
                 validator=valid_port)
    if skip_hint and raw.lower() == "skip":
        info("Keeping existing .env unchanged.")
        return read_env(ENV_FILE)
    values["NGINX_HTTP_PORT"] = raw

    values["DASHBOARD_USER"] = prompt(
        "DASHBOARD_USER", default=defaults["DASHBOARD_USER"])

    print(f"  {BOLD}DASHBOARD_PASSWORD{RESET} [{DIM}leave blank to auto-generate{RESET}]:")
    pwd = getpass.getpass(prompt="  Password (hidden): ")
    values["DASHBOARD_PASSWORD"] = pwd

    values["AGENT_USER"] = prompt(
        "AGENT_USER", default=defaults["AGENT_USER"])

    values["CHROOT_BASE"] = prompt(
        "CHROOT_BASE", default=defaults["CHROOT_BASE"],
        validator=valid_abspath)

    values["AGENT_CONTAINER_NAME"] = prompt(
        "AGENT_CONTAINER_NAME", default=defaults["AGENT_CONTAINER_NAME"])

    values["NGINX_CONTAINER_NAME"] = prompt(
        "NGINX_CONTAINER_NAME", default=defaults["NGINX_CONTAINER_NAME"])

    values["AGENT_NETWORK_NAME"] = prompt(
        "AGENT_NETWORK_NAME", default=defaults["AGENT_NETWORK_NAME"])

    values["EXPECTED_AGENT_IP"] = prompt(
        "EXPECTED_AGENT_IP", default=defaults["EXPECTED_AGENT_IP"],
        validator=valid_ip)

    values["EXPECTED_NGINX_IP"] = prompt(
        "EXPECTED_NGINX_IP", default=defaults["EXPECTED_NGINX_IP"],
        validator=valid_ip)

    print(f"\n  {DIM}Advanced network overrides (press Enter to skip):{RESET}")
    subnet = prompt("AGENT_SUBNET (optional)", default=defaults.get("AGENT_SUBNET", ""),
                    validator=lambda s: s == "" or valid_cidr(s))
    values["AGENT_SUBNET"] = subnet

    gateway = prompt("AGENT_GATEWAY (optional)", default=defaults.get("AGENT_GATEWAY", ""),
                     validator=lambda s: s == "" or valid_ip(s))
    values["AGENT_GATEWAY"] = gateway

    write_env(ENV_FILE, values)
    info(f".env written to {ENV_FILE}")
    return values

# ---------------------------------------------------------------------------
# PHASE 2: config.json — SSH hosts
# ---------------------------------------------------------------------------
def collect_host(agent_user: str) -> dict:
    """Interactively collect one SSH host config. Returns a dict."""
    section("Add SSH Host")

    name = prompt("Host alias (name)", validator=lambda s: bool(s))
    hostname = prompt("Hostname or IP", validator=lambda s: bool(s))
    port = int(prompt("Port", default="22", validator=valid_port))
    user = prompt("SSH user", default=agent_user)

    strict = prompt_yn("Strict host key checking?", default=True)
    if not strict:
        print()
        warn("SECURITY WARNING: Disabling strict host key checking removes MITM protection.")
        warn("Only use this for ephemeral hosts (e.g. RunPod) where the IP changes each session.")
        print()

    isolation_choice = prompt_choice(
        "Isolation mode:",
        ["chroot  – standard VMs/bare-metal with sudo (recommended)",
         "restricted_key  – managed environments (RunPod, shared containers)"],
        default=1)
    isolation = "chroot" if isolation_choice == 1 else "restricted_key"

    print(f"\n  {BOLD}Project paths{RESET} (absolute paths the agent may access)")
    print("  Enter one path per line. Type '.' when done.")
    project_paths = []
    idx = 1
    while True:
        p = prompt(f"Path {idx}", validator=lambda s: s == "." or valid_abspath(s))
        if p == ".":
            break
        project_paths.append(p)
        idx += 1

    print(f"\n  {BOLD}Port forwarding{RESET} (ports agent may tunnel back to itself)")
    raw_ports = prompt("Ports (space-separated, or Enter to skip)", default="")
    forward_ports = []
    if raw_ports:
        for tok in raw_ports.split():
            if tok.isdigit() and 1 <= int(tok) <= 65535:
                forward_ports.append(int(tok))
            else:
                warn(f"Ignoring invalid port: {tok}")

    print(f"\n  {DIM}Advanced options:{RESET}")
    egress = prompt_yn("Chroot egress filter?", default=False)
    docker = prompt_yn("Docker access?", default=False)

    host = {
        "name": name,
        "hostname": hostname,
        "port": port,
        "user": user,
        "strict_host_key_checking": strict,
        "isolation": isolation,
        "project_paths": project_paths,
        "forward_ports": forward_ports,
        "chroot_egress_filter": egress,
        "docker_access": docker,
    }

    # Summary
    print(f"\n  {BOLD}Host summary:{RESET}")
    for k, v in host.items():
        print(f"    {DIM}{k}:{RESET} {v}")

    if not prompt_yn("\n  Add this host?", default=True):
        return None

    return host


def phase_config(env_values: dict, state: dict) -> list:
    section("Phase 2 — SSH Host Configuration (config.json)")

    cfg = read_config()
    hosts = cfg.get("ssh_hosts", [])
    agent_user = env_values.get("AGENT_USER", "dev-bot")

    if hosts:
        print(f"  {YELLOW}config.json already has {len(hosts)} host(s):{RESET}")
        for i, h in enumerate(hosts, 1):
            print(f"    {i}. {h['name']}  ({h['hostname']}:{h['port']}, {h['isolation']})")
        print()
        print("  Options:")
        print("    a) Add another host")
        print("    s) Skip (keep existing config.json as-is)")
        print("    r) Replace all hosts (start over)")
        while True:
            try:
                choice = input("  Select [s]: ").strip().lower() or "s"
            except EOFError:
                choice = "s"
            if choice in ("a", "s", "r"):
                break
            error("Type a, s, or r.")

        if choice == "s":
            info("Keeping existing config.json unchanged.")
            return hosts
        if choice == "r":
            hosts = []
    else:
        print("  No SSH hosts configured yet.")
        print("  You need at least one host for the agent to connect to.\n")

    # Add hosts loop
    while True:
        host = collect_host(agent_user)
        if host is not None:
            # Duplicate name check
            existing_names = {h["name"] for h in hosts}
            if host["name"] in existing_names:
                warn(f"A host named '{host['name']}' already exists. Skipping duplicate.")
            else:
                hosts.append(host)
                info(f"Host '{host['name']}' added.")

        if not prompt_yn("\n  Add another host?", default=False):
            break

    write_config({"ssh_hosts": hosts})
    info(f"config.json written ({len(hosts)} host(s)).")
    return hosts

# ---------------------------------------------------------------------------
# PHASE 3: Agent mode
# ---------------------------------------------------------------------------
def phase_agent_mode(state: dict) -> str:
    section("Phase 3 — Agent Mode")

    if state.get("agent_mode"):
        prev = state["agent_mode"]
        print(f"  Previously selected: {BOLD}{prev}{RESET}")
        if prompt_yn("  Keep this selection?", default=True):
            return prev

    choice = prompt_choice(
        "Which agent will you run?",
        ["openclaw   – OpenClaw gateway + nginx dashboard",
         "claudecode – Claude Code CLI (headless, no dashboard)"],
        default=1)
    mode = "openclaw" if choice == 1 else "claudecode"
    state["agent_mode"] = mode
    save_state(state)
    info(f"Agent mode: {BOLD}{mode}{RESET}")
    return mode

# ---------------------------------------------------------------------------
# PHASE 4: Execution steps
# ---------------------------------------------------------------------------
def _fingerprint_present(hostname: str) -> bool:
    known = os.path.join(PROJECT_ROOT, ".ssh", "known_hosts")
    if not os.path.exists(known):
        return False
    rc, _ = run_cmd(f"grep -q '{hostname}' '{known}'")
    return rc == 0

def _container_running(container_name: str) -> bool:
    rc, _ = run_cmd(
        f"docker ps --filter name={container_name} --filter status=running --format '{{{{.Names}}}}' | grep -q {container_name}")
    return rc == 0

def _container_exists(container_name: str) -> bool:
    """True if a container with this name exists in any state (running, exited, created, etc.)."""
    rc, _ = run_cmd(
        f"docker ps -a --filter name={container_name} --format '{{{{.Names}}}}' | grep -q {container_name}")
    return rc == 0

def _image_exists(pattern: str) -> bool:
    rc, _ = run_cmd(
        f"docker images --format '{{{{.Repository}}}}' | grep -q '{pattern}'")
    return rc == 0

def phase_execute(hosts: list, agent_mode: str, env_values: dict, state: dict) -> dict:
    section("Phase 4 — Execution")
    TOTAL = 8
    results = {}

    container_name = env_values.get("AGENT_CONTAINER_NAME", "agent-dev")

    # ---- Step 1: Generate SSH keys ----
    step_header(1, TOTAL, "Generate SSH keys")
    key_path = os.path.join(PROJECT_ROOT, ".ssh", "id_agent")
    if os.path.exists(key_path):
        info("SSH keys already exist. Skipping.")
        mark_done(state, "keys")
    elif is_done(state, "keys"):
        info("Already completed. Skipping.")
    else:
        ok, _ = run_step_with_retry("make keys")
        if ok:
            mark_done(state, "keys")

    # ---- Step 2: Dashboard credentials ----
    step_header(2, TOTAL, "Initialize dashboard credentials (make auth)")
    htpasswd = os.path.join(PROJECT_ROOT, "nginx", ".htpasswd")
    if os.path.exists(htpasswd):
        info("nginx/.htpasswd already exists. Skipping.")
        info("Run 'make auth' to regenerate credentials if needed.")
        mark_done(state, "auth")
    elif is_done(state, "auth"):
        info("Already completed. Skipping.")
    else:
        ok, stdout = run_step_with_retry("make auth", capture=True)
        if ok:
            mark_done(state, "auth")
            # Extract and display the credential block
            if stdout:
                in_block = False
                for line in stdout.splitlines():
                    if "Dashboard Credentials" in line or "=======" in line:
                        in_block = True
                    if in_block:
                        print(f"  {line}")
                    if in_block and line.startswith("====") and "Credentials" not in line:
                        break
            results["credentials_shown"] = True

    # ---- Step 3: Pre-seed known_hosts ----
    step_header(3, TOTAL, "Pre-seed SSH known_hosts")
    for host in hosts:
        hname = host["hostname"]
        hport = host.get("port", 22)
        alias = host["name"]
        strict = host.get("strict_host_key_checking", True)

        if not strict:
            warn(f"Skipping keyscan for '{alias}' (strict_host_key_checking=false — ephemeral host).")
            continue

        if _fingerprint_present(hname):
            info(f"Fingerprint for '{hname}' already in known_hosts. Skipping.")
            continue

        ssh_dir = os.path.join(PROJECT_ROOT, ".ssh")
        os.makedirs(ssh_dir, mode=0o700, exist_ok=True)
        known_path = os.path.join(ssh_dir, "known_hosts")
        port_args = f"-p {hport} " if hport != 22 else ""
        # Run ssh-keyscan without stderr suppression so any error is visible.
        # A non-zero exit is non-fatal: the host may not be reachable yet (e.g.
        # the Docker gateway only exists after 'make up'), and the entrypoint
        # will auto-seed on first connect as a fallback.
        cmd = f"ssh-keyscan -H {port_args}{hname} >> '{known_path}'"
        print(f"  Running: {DIM}{cmd}{RESET}")
        rc, _ = run_cmd(cmd)
        if rc == 0:
            info(f"Fingerprint for '{hname}' saved.")
        else:
            warn(f"Could not reach '{hname}' (exit {rc}) — skipping keyscan.")
            warn("The container entrypoint will auto-seed on first connect.")
            warn("Or pre-seed manually after 'make up':")
            print(f"    ssh-keyscan -H {port_args}{hname} >> .ssh/known_hosts")
    mark_done(state, "known_hosts")

    # ---- Step 4: Build image (claudecode only) ----
    step_header(4, TOTAL, "Build agent image")
    if agent_mode == "openclaw":
        info("openclaw uses a pre-built image. Skipping build.")
        mark_done(state, "build")
    elif is_done(state, "build"):
        info("Already completed. Skipping.")
    elif _image_exists("agent-dev"):
        info("Agent image already present in Docker. Skipping.")
        mark_done(state, "build")
    else:
        ok, _ = run_step_with_retry("make build AGENT=claudecode")
        if ok:
            mark_done(state, "build")

    # ---- Step 5: Start containers ----
    step_header(5, TOTAL, f"Start containers (make up AGENT={agent_mode})")
    if is_done(state, "up") and _container_running(container_name):
        info(f"Container '{container_name}' is already running. Skipping.")
    else:
        # docker-compose bind-mounts these directories — they must exist before 'up'.
        for data_dir in (".openclaw-data", ".claudecode-data", ".ssh"):
            d = os.path.join(PROJECT_ROOT, data_dir)
            if not os.path.exists(d):
                os.makedirs(d, mode=0o700, exist_ok=True)
                info(f"Created {data_dir}/")

        # A stopped/exited container with the same name causes a Docker conflict.
        # Remove it so 'make up' can recreate it cleanly.
        if _container_exists(container_name) and not _container_running(container_name):
            warn(f"Container '{container_name}' exists but is not running. Removing it first...")
            run_cmd(f"docker compose --profile {agent_mode} down 2>/dev/null || docker rm {container_name} 2>/dev/null || true")
        print(f"  {DIM}Note: This step calls sudo internally for firewall rules.{RESET}")
        ok, _ = run_step_with_retry(f"make up AGENT={agent_mode}")
        if ok:
            mark_done(state, "up")

    # ---- Step 6: Host setup ----
    step_header(6, TOTAL, "Set up SSH hosts")
    for host in hosts:
        alias = host["name"]
        if state["host_setup"].get(alias, {}).get("setup"):
            info(f"'{alias}' already set up. Skipping.")
            continue

        print(f"\n  Configuring host: {BOLD}{alias}{RESET} ({host['hostname']}:{host['port']})")
        choice = prompt_choice(
            f"Is '{alias}' local (same machine as Docker host) or remote?",
            [f"Local  – make setup HOST={alias}",
             f"Remote – make remote-setup HOST={alias} REMOTE_KEY=... REMOTE_USER=..."],
            default=1)

        if choice == 1:
            cmd = f"make setup HOST={alias}"
        else:
            default_key = os.path.expanduser("~/.ssh/id_rsa")
            remote_key = prompt("Path to your admin SSH key for the remote host",
                                default=default_key,
                                validator=lambda s: bool(s))
            remote_user = prompt("Remote admin user", default="ubuntu")
            cmd = f"make remote-setup HOST={alias} REMOTE_KEY={remote_key} REMOTE_USER={remote_user}"

        print(f"  {DIM}Running: {cmd}{RESET}")
        ok, _ = run_step_with_retry(cmd)
        if alias not in state["host_setup"]:
            state["host_setup"][alias] = {}
        state["host_setup"][alias]["setup"] = ok
        save_state(state)

    # ---- Step 7: Test SSH connections ----
    step_header(7, TOTAL, "Test SSH connections")
    for host in hosts:
        alias = host["name"]
        print(f"\n  Testing '{alias}'...")
        rc, _ = run_cmd(f"make test HOST={alias}")
        if alias not in state["host_setup"]:
            state["host_setup"][alias] = {}
        state["host_setup"][alias]["test"] = (rc == 0)
        save_state(state)
        if rc == 0:
            info(f"'{alias}' — connection OK")
        else:
            warn(f"'{alias}' — connection FAILED (run 'make test HOST={alias}' to retry)")
    results["host_tests"] = state["host_setup"]

    # ---- Step 8: Security preflight ----
    step_header(8, TOTAL, "Security preflight check (make preflight)")
    rc, _ = run_cmd("make preflight")
    results["preflight_ok"] = (rc == 0)
    if rc == 0:
        info("All security layers active.")
    else:
        warn("Preflight check reported issues. Review output above.")

    return results

# ---------------------------------------------------------------------------
# PHASE 5: Summary
# ---------------------------------------------------------------------------
def phase_summary(hosts: list, agent_mode: str, env_values: dict, results: dict) -> None:
    banner("Setup Complete")

    port = env_values.get("NGINX_HTTP_PORT", "8090")
    user = env_values.get("DASHBOARD_USER", "agent-dev")
    container = env_values.get("AGENT_CONTAINER_NAME", "agent-dev")

    print(f"  {BOLD}Configuration:{RESET}")
    print(f"    .env          written")
    print(f"    config.json   written ({len(hosts)} host(s))")
    print(f"    .ssh/id_agent generated\n")

    if agent_mode == "openclaw":
        print(f"  {BOLD}Dashboard:{RESET}  http://localhost:{port}")
        print(f"    User:       {user}")
        print(f"    Password:   (check output of 'make auth' above, or run it again)\n")

    print(f"  {BOLD}Hosts:{RESET}")
    for h in hosts:
        alias = h["name"]
        test_ok = results.get("host_tests", {}).get(alias, {}).get("test")
        if test_ok is True:
            status = f"{GREEN}PASS{RESET}"
        elif test_ok is False:
            status = f"{RED}FAIL{RESET}"
        else:
            status = f"{YELLOW}NOT TESTED{RESET}"
        print(f"    {alias:<20} {status}")

    print()
    preflight = results.get("preflight_ok")
    if preflight:
        print(f"  {BOLD}Security:{RESET}  {GREEN}All layers active{RESET}")
    else:
        print(f"  {BOLD}Security:{RESET}  {YELLOW}Some checks failed — review preflight output{RESET}")
    print()

    if agent_mode == "openclaw":
        box([
            "MANUAL STEP REQUIRED (openclaw only):",
            "",
            f"  docker exec -it {container} bash",
            "  > openclaw onboard",
            "      Set gateway port to 18789",
            "      Set bind mode to LAN",
            "      Copy the token → paste in the dashboard",
            "  > openclaw devices list",
            "  > openclaw devices approve <device-id>",
        ])

    print(f"\n  {DIM}Re-run 'make wizard' at any time to update config or add hosts.{RESET}\n")

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main() -> None:
    try:
        phase_prerequisites()
        state = load_state()

        env_values  = phase_env(state)
        hosts       = phase_config(env_values, state)
        agent_mode  = phase_agent_mode(state)
        results     = phase_execute(hosts, agent_mode, env_values, state)

        phase_summary(hosts, agent_mode, env_values, results)

    except KeyboardInterrupt:
        print(f"\n\n{BOLD}Wizard interrupted.{RESET} Re-run 'make wizard' to resume.\n")
        sys.exit(1)


if __name__ == "__main__":
    main()
