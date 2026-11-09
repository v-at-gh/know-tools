# scripts/

Cross-repo operational scripts for state validation, repository synchronization, and host networking automation.

## Files

| Script | Purpose | Usage Example | Depends On |
| :--- | :--- | :--- | :--- |
| `validate-userdata.py` | Read-only inventory of `state/*.db` + `output/` | `python scripts/validate-userdata.py <project-root>` | Python 3.10+ stdlib (`sqlite3`, `json`) (`scripts/validate-userdata.py:5`) |
| `validate-userdata.sh` | POSIX bash inventory fallback for server state | `./scripts/validate-userdata.sh <project-root>` | `bash`, `sqlite3` CLI (`scripts/validate-userdata.sh:5`) |
| `validate-userdata.ps1` | PowerShell inventory fallback for server state | `.\scripts\validate-userdata.ps1 -Root <project-root>` | PowerShell 5.1+ (`scripts/validate-userdata.ps1:5`) |
| `port-forward.ps1` | Windows host portproxy and firewall manager | `.\scripts\port-forward.ps1 -Action up` | PowerShell 5.1+, `netsh`, Multipass (`scripts/port-forward.ps1:17-21`) |

### Script Details

- **`validate-userdata.py`**: Inspects SQLite databases using `file:...mode=ro` to prevent WAL checkpoints or journal creation (`scripts/validate-userdata.py:38`). Returns exit code 0 (clean), 1 (warnings), 2 (errors), or 3 (script error) (`scripts/validate-userdata.py:11-14`).
- **`validate-userdata.sh`**: POSIX shell script performing read-only inventory checks using `sqlite3` CLI and standard Unix tools (`scripts/validate-userdata.sh:1-15`).
- **`validate-userdata.ps1`**: Windows PowerShell script performing read-only inventory checks on Windows environments (`scripts/validate-userdata.ps1:1-10`).
- **`port-forward.ps1`**: Configures Windows `netsh portproxy` and Windows Firewall rules scoped to LocalSubnet for the `know-infra` VM (`scripts/port-forward.ps1:10-15`). Supports actions: `up`, `down`, `status`, `cleanup`, `audit`, `refresh` (`scripts/port-forward.ps1:21`).

## Adding a new script

Maintain the following conventions for new scripts:
- **Python scripts**: Include `#!/usr/bin/env python3` and use `argparse` for argument parsing (`scripts/validate-userdata.py:1,228`). Prefer standard library modules.
- **Single responsibility**: Each script should fulfill one clear operational purpose without introducing unnecessary shared internal dependencies.
