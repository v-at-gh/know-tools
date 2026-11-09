# know-tools

Cross-repository operational scripts, state validators, repository publishing tools, and host network automation for the Know project ecosystem.

`know-tools` houses tooling that operates across multiple repositories (such as sync scripts reading from private sources and writing to public targets) or runs on external host hypervisors (such as Windows host port forwarding for Linux guest virtual machines).

---

## Prerequisites & Installation

### System Requirements
- **Python 3.10+**: Required for `scripts/validate-userdata.py` ([`pyproject.toml:5`](pyproject.toml#L5)).
- **Bash & rsync**: Required on macOS and Linux systems for `scripts/validate-userdata.sh` ([`scripts/validate-userdata.sh:1`](scripts/validate-userdata.sh#L1)).
- **PowerShell 5.1+ / 7+**: Required on Windows systems for `scripts/port-forward.ps1` ([`scripts/port-forward.ps1:1`](scripts/port-forward.ps1#L1)) and `scripts/validate-userdata.ps1` ([`scripts/validate-userdata.ps1:1`](scripts/validate-userdata.ps1#L1)). Administrator elevation is required for network proxy and firewall configuration ([`scripts/port-forward.ps1:2`](scripts/port-forward.ps1#L2)).
- **SQLite3**: SQLite command-line interface or Python `sqlite3` module for database inventory and integrity validation ([`scripts/validate-userdata.py:38`](scripts/validate-userdata.py#L38), [`scripts/validate-userdata.sh:31`](scripts/validate-userdata.sh#L31)).
- **Multipass CLI** *(Optional)*: Required on Windows host for dynamic VM IP lookup in `scripts/port-forward.ps1` ([`scripts/port-forward.ps1:87`](scripts/port-forward.ps1#L87)). Defaults to fallback IP `172.26.60.57` if unavailable ([`scripts/port-forward.ps1:35`](scripts/port-forward.ps1#L35)).

### Environment Setup
No external Python package dependencies are required. `pyproject.toml` configures Python requirements without installing runtime wheel packages ([`pyproject.toml:13`](pyproject.toml#L13)).

Optional environment variables:
```bash
# Override target Multipass VM name for Windows port forwarding (default: know-infra)
export MULTIPASS_VM_NAME="know-infra"
```

---

## Quick Start & Usage

### 1. Runtime User Data State Inventory (`scripts/validate-userdata.*`)
Inspect `know-server` runtime databases (`state/*.db`), log files (`state/logs/*.jsonl`), output directories (`output/`), and QAP manifests (`state/manifest.json`). Database checks run strictly read-only (`mode=ro`) without creating WAL checkpoints or temporary files.

#### Python Implementation (Cross-platform)
```bash
python scripts/validate-userdata.py /path/to/know-server
```
*Verbatim CLI help output* (`python scripts/validate-userdata.py --help`):
```text
usage: validate-userdata [-h] root

Read-only inventory of know-server runtime data.

positional arguments:
  root        Project root (e.g. ~/data/src/github.com/v-at-gh/know-server)

optional arguments:
  -h, --help  show this help message and exit
```

#### Bash Implementation (macOS / Linux)
```bash
./scripts/validate-userdata.sh /path/to/know-server
```
*Verbatim usage output*:
```text
Usage: ./scripts/validate-userdata.sh <project-root>
  e.g. ./scripts/validate-userdata.sh ~/data/src/github.com/v-at-gh/know-server
```

#### PowerShell Implementation (Windows)
```powershell
.\scripts\validate-userdata.ps1 -Root \path\to\know-server
```

**Exit Codes** ([`scripts/validate-userdata.py:11-14`](scripts/validate-userdata.py#L11-L14)):
- `0`: Clean execution, no warnings or errors.
- `1`: Clean execution, warnings present (e.g., missing non-critical logs or disk space > 90%).
- `2`: Integrity errors found (e.g., SQLite corrupted or unreadable database).
- `3`: Script error (invalid arguments or missing required tools).

### 3. Windows Host Port Forwarding (`scripts/port-forward.ps1`)
Manage Windows `netsh interface portproxy` rules and Windows Firewall rules scoped to `LocalSubnet` for forwarding host ports to the `know-infra` VM. Requires Administrator elevation.

```powershell
# View current portproxy mapping and firewall status
.\scripts\port-forward.ps1 -Action status

# Apply portproxy forwards and firewall rules
.\scripts\port-forward.ps1 -Action up

# Remove managed portproxy forwards and firewall rules
.\scripts\port-forward.ps1 -Action down

# Re-evaluate VM IP address via Multipass and update forwards if IP changed
.\scripts\port-forward.ps1 -Action refresh

# Audit for unmanaged portproxy entries or orphaned firewall rules
.\scripts\port-forward.ps1 -Action audit

# Clean up managed rules
.\scripts\port-forward.ps1 -Action cleanup
```

**Managed Ports** ([`scripts/port-forward.ps1:41-47`](scripts/port-forward.ps1#L41-L47)):
- `3001` → Gitea HTTP/UI
- `2222` → Gitea SSH
- `4317` → OTLP gRPC (Mac telemetry)
- `4318` → OTLP HTTP (Mac telemetry)
- `3000` → Grafana UI

---

## Configuration

### Python Package Configuration (`pyproject.toml`)
`pyproject.toml` configures the repository build system using Hatchling ([`pyproject.toml:10`](pyproject.toml#L10)) and specifies Python 3.10+ requirement ([`pyproject.toml:5`](pyproject.toml#L5)). Package building is disabled via `packages = []` ([`pyproject.toml:13`](pyproject.toml#L13)).

---

## High-Level Architecture

`know-tools` provides standalone operational scripts structured across two primary directories:

```text
know-tools/
└── scripts/
    ├── README.md             # Subdirectory reference guide
    ├── validate-userdata.py  # Read-only Python inventory validator for know-server
    ├── validate-userdata.sh  # POSIX bash fallback inventory validator
    ├── validate-userdata.ps1 # PowerShell fallback inventory validator
    └── port-forward.ps1      # Windows host netsh portproxy & firewall manager
```

For detailed architectural flowcharts, data pipelines, and module specifications, see [ARCHITECTURE.md](ARCHITECTURE.md).

---

## Development & Verification

### Code Guidelines
- **Zero-Dependency Scripts**: Python scripts use standard library modules exclusively (`sqlite3`, `json`, `shutil`, `argparse`, `socket`).
- **Read-Only Database Connections**: All database validation uses URI connections with `mode=ro` to guarantee zero side-effects ([`scripts/validate-userdata.py:38`](scripts/validate-userdata.py#L38)).
- **Idempotent Network Forwarding**: PowerShell port-forwarding scripts verify service prerequisites (e.g., `iphlpsvc`) and update rules atomically ([`scripts/port-forward.ps1:60-75`](scripts/port-forward.ps1#L60-L75)).

### Verification Commands
Validate local scripts using system interpreters:

```bash
# Validate Python syntax and execution
python3 scripts/validate-userdata.py --help

# Validate POSIX script syntax
bash -n scripts/validate-userdata.sh
```
