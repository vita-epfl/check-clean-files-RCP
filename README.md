# Check Clean Files on RCP / Run:ai

This repository contains the RCP storage scan workflow. The scanner itself runs inside the Docker image through Run:ai, while the local scripts in `scripts/` submit recurring scratch scans, wait for them, validate the outputs, and build a consolidated Markdown report.

## Files

- `check_files.sh`: scans one or more base directories, writes CSV results, and writes a `.summary.txt` sidecar.
- `Dockerfile`: builds the image that contains `check_files.sh`.
- `scripts/rcp_scan_config.sh`: shared configuration for the recurring RCP scratch scans.
- `scripts/submit_rcp_scans.sh`: prints the exact Run:ai commands and, with confirmation, submits the three scan jobs.
- `scripts/wait_rcp_scans.sh`: polls Run:ai until the three jobs complete.
- `scripts/check_rcp_outputs.sh`: checks that expected CSV and summary files exist and have the expected CSV header.
- `scripts/generate_storage_report.py`: generates `storage_report.md` and `storage_report.json` from the three CSV files.
- `scripts/upload_storage_report_to_notion.py`: uploads a generated Markdown report to Notion.
- `scripts/submit_report_upload_job.sh`: submits a small Run:ai job that generates and uploads the report after scans finish.

## Scan Scopes

The recurring pipeline scans these scopes:

| Scope | Base directory | Scanner options | CSV |
| --- | --- | --- | --- |
| datasets | `/mnt/vita/scratch/datasets` | `-m 100 -d 1 --measure-mindepth 1 -t 600` | `files_datasets.csv` |
| vita-staff | `/mnt/vita/scratch/vita-staff/users` | `-m 100 -d 2 --measure-mindepth 2 -t 600` | `files_staff.csv` |
| vita-students | `/mnt/vita/scratch/vita-students/users` | `-m 100 -d 2 --measure-mindepth 2 -t 600` | `files_students.csv` |

Outputs are written under:

```text
/mnt/vita/scratch/vita-staff/users/alefevre/programs/check-clean-files/output/runs/YYYY-MM-DD/
```

Each CSV uses this header:

```text
"Directory","Size","Modified","Accessed","Owner"
```

## Build The Image

Docker is installed on the current host at `/usr/bin/docker`. Rebuild and push the image when `check_files.sh`, `Dockerfile`, or any script used inside Run:ai changes. The report/upload Run:ai job uses scripts copied into the image, so the image must be rebuilt for the Notion upload feature.

```bash
docker login registry.rcp.epfl.ch

docker build . \
  --tag registry.rcp.epfl.ch/vita/check-clean-files:latest \
  --build-arg LDAP_GROUPNAME=vita \
  --build-arg LDAP_GID=<your_gid> \
  --build-arg LDAP_USERNAME=<your_username> \
  --build-arg LDAP_UID=<your_uid>

docker push registry.rcp.epfl.ch/vita/check-clean-files:latest
```

## Submit The Recurring Scan

Run:ai is installed on the current host at `/home/admin-vita7/.runai/bin/runai`.

The submit script is dry-run by default. It prints the exact Run:ai commands without submitting anything:

```bash
scripts/submit_rcp_scans.sh
```

To submit, use `--execute`. The script prints the exact commands again and asks you to type `submit` before it runs them:

```bash
scripts/submit_rcp_scans.sh --execute
```

Useful overrides:

```bash
RCP_SCAN_PROJECT=vita-<username> scripts/submit_rcp_scans.sh
RCP_SCAN_RUN_DATE=2026-07-13 RCP_SCAN_RUN_ID=20260713-090000 scripts/submit_rcp_scans.sh
```

PowerShell examples on Windows:

```powershell
$env:RCP_SCAN_PROJECT = "vita-<username>"
.\scripts\submit_rcp_scans.sh

$env:RCP_SCAN_RUN_DATE = "2026-07-13"
$env:RCP_SCAN_RUN_ID = "20260713-090000"
.\scripts\submit_rcp_scans.sh --execute
```

PowerShell uses backticks for multi-line commands when writing raw Run:ai commands by hand; bash uses backslashes.

## Monitor And Report

Use the same `RCP_SCAN_RUN_ID` that was printed by `submit_rcp_scans.sh` if you monitor from a new shell.

```bash
scripts/wait_rcp_scans.sh
scripts/check_rcp_outputs.sh
scripts/generate_storage_report.sh
```

To run the report generation and Notion upload as a small Run:ai job after scans finish, first dry-run the command:

```bash
scripts/submit_report_upload_job.sh
```

Then submit it after checking the printed command:

```bash
scripts/submit_report_upload_job.sh --execute
```

The report generator writes:

```text
output/runs/YYYY-MM-DD/storage_report.md
output/runs/YYYY-MM-DD/storage_report.json
```

The JSON file is intentionally small and structured so a later Notion uploader can reuse the parsed totals, owner counts, and per-scope metadata without scraping Markdown.

## Notion Upload Setup

The uploader creates a child page under the RCP Storage page:

```text
https://app.notion.com/p/RCP-Storage-39c953b34421805f9b81d664f291f945
```

The default parent page ID is `39c953b3-4421-805f-9b81-d664f291f945`.

For testing with your personal page, create a Notion personal access token in the Notion developer portal, then make sure the token has permission to insert content under the target page. Notion documents this flow as a personal access token for API requests, and the Create page endpoint requires Insert Content capability on the target parent page.

For Run:ai, do not put the token directly in the command. Store it as a Kubernetes secret that the job can expose as `NOTION_API_KEY`:

```bash
kubectl create secret generic notion-api-key \
  --from-literal=token='ntn_***'
```

If the secret has a different name or key, override it:

```bash
NOTION_SECRET_NAME=<secret-name> NOTION_SECRET_KEY=<secret-key> scripts/submit_report_upload_job.sh
```

Local dry-run of the upload payload, without calling Notion:

```bash
python3 scripts/upload_storage_report_to_notion.py output_copy/storage_report.md --dry-run
```

Local real upload, if `NOTION_API_KEY` is set in your shell:

```bash
export NOTION_API_KEY=ntn_***
python3 scripts/upload_storage_report_to_notion.py output_copy/storage_report.md
```


## Scheduling Every 2 Weeks

Yes. Run the scheduler on a machine that has the Run:ai CLI installed and authenticated. The scans and report generation run on RCP through Run:ai; the scheduler only submits jobs and polls their status.

Use the pipeline wrapper for manual full runs:

```bash
RCP_RUNAI_BIN=/home/alefevre/.runai/bin/runai \
RCP_SCAN_OUTPUT_ROOT=/mnt/vita/scratch/vita-staff/users/alefevre/programs/check-clean-files/output \
scripts/run_recurring_pipeline.sh
```

For cron, use the biweekly guard. It can be checked every Monday but only launches the full pipeline when the last successful run is at least 13 days old:

```bash
RCP_RUNAI_BIN=/home/alefevre/.runai/bin/runai \
RCP_SCAN_OUTPUT_ROOT=/mnt/vita/scratch/vita-staff/users/alefevre/programs/check-clean-files/output \
RCP_BIWEEKLY_STAMP_FILE=/home/alefevre/programs/check-clean-files-RCP/output/last_successful_recurring_scan.txt \
scripts/run_biweekly_if_due.sh
```

For a host where `/mnt/vita/scratch` is not mounted, local CSV validation is skipped automatically and the report/upload job validates the inputs inside the mounted PVC. To force or disable that behavior explicitly:

```bash
RCP_RUN_LOCAL_OUTPUT_CHECK=always scripts/run_recurring_pipeline.sh
RCP_RUN_LOCAL_OUTPUT_CHECK=never scripts/run_recurring_pipeline.sh
```

Cron is simple and works well if the submitting host is always on. Edit with `crontab -e`:

```cron
0 6 * * 1 cd /home/alefevre/programs/check-clean-files-RCP && RCP_RUNAI_BIN=/home/alefevre/.runai/bin/runai RCP_SCAN_OUTPUT_ROOT=/mnt/vita/scratch/vita-staff/users/alefevre/programs/check-clean-files/output RCP_BIWEEKLY_STAMP_FILE=/home/alefevre/programs/check-clean-files-RCP/output/last_successful_recurring_scan.txt /usr/bin/env bash scripts/run_biweekly_if_due.sh >> /home/alefevre/programs/check-clean-files-RCP/output/scan_scheduler.log 2>&1
```

A systemd timer is better when you want missed runs to start after reboot.

`~/.config/systemd/user/check-clean-files-rcp.service`:

```ini
[Unit]
Description=Submit and report RCP scratch storage scan

[Service]
Type=oneshot
WorkingDirectory=/home/alefevre/programs/check-clean-files-RCP
Environment=RCP_RUNAI_BIN=/home/alefevre/.runai/bin/runai
Environment=RCP_SCAN_OUTPUT_ROOT=/mnt/vita/scratch/vita-staff/users/alefevre/programs/check-clean-files/output
Environment=RCP_BIWEEKLY_STAMP_FILE=/home/alefevre/programs/check-clean-files-RCP/output/last_successful_recurring_scan.txt
ExecStart=/usr/bin/env bash -lc 'scripts/run_biweekly_if_due.sh'
```

`~/.config/systemd/user/check-clean-files-rcp.timer`:

```ini
[Unit]
Description=Check whether the RCP scratch storage scan is due

[Timer]
OnCalendar=Mon *-*-* 06:00:00
Persistent=true
Unit=check-clean-files-rcp.service

[Install]
WantedBy=timers.target
```

Enable it:

```bash
systemctl --user daemon-reload
systemctl --user enable --now check-clean-files-rcp.timer
systemctl --user list-timers check-clean-files-rcp.timer
```

## Raw Run:ai Command Shape

The scripts generate commands like this, with unique job names from `RCP_SCAN_RUN_ID`:

```bash
runai training submit check-files-staff-20260713-090000 \
  -p vita-<username> \
  -i registry.rcp.epfl.ch/vita/check-clean-files:latest \
  --image-pull-policy Always \
  --cpu-core-request 4 \
  --cpu-memory-request 32G \
  --existing-pvc claimname=vita-scratch,path=/mnt/vita/scratch \
  --restart-policy Never \
  --command -- bash /opt/check-clean-files/check_files.sh \
    -b /mnt/vita/scratch/vita-staff/users \
    -O /mnt/vita/scratch/vita-staff/users/alefevre/programs/check-clean-files/output/runs/2026-07-13 \
    -m 100 -d 2 --measure-mindepth 2 -t 600 -o files_staff.csv
```
