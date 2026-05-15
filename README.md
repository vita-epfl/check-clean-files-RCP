# Check Clean Files on RCP / Run:ai

This repository contains the RCP version of the storage scan workflow. It is not tied to Slurm: the scanner runs inside a Docker image and the job is submitted from your laptop with Run:ai.

## Do We Still Need The Shell Files?

Yes: keep `check_files.sh`. It is the actual scanner and the Docker image runs it as the entrypoint.

The old local submit and cleanup wrappers were removed to keep the RCP workflow simple. Use the raw Run:ai v2 command from `build_and_submit.md`.

## Files

- `check_files.sh`: scans one or more base directories, writes CSV results, and prints a summary.
- `Dockerfile`: builds the image that contains `check_files.sh`.

## Build The Image

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

## Submit With Run:ai v2

This example scans all of `/mnt/vita/scratch` and stores the output in your user area.

```powershell
runai training submit check-files-<your_username> `
  -p vita-<your_username> `
  -i registry.rcp.epfl.ch/vita/check-clean-files:latest `
  --image-pull-policy Always `
  --cpu-core-request 4 `
  --cpu-memory-request 32G `
  --existing-pvc claimname=vita-scratch,path=/mnt/vita/scratch `
  --restart-policy Never `
  --command -- bash /opt/check-clean-files/check_files.sh `
    -b /mnt/vita/scratch `
    -O /mnt/vita/scratch/vita-staff/users/<your_username>/check-clean-files/output `
    -m 50 -d 5 -t 1800 -o files_rcp.csv
```

## Output

```text
/mnt/vita/scratch/vita-staff/users/<your_username>/check-clean-files/output/files_rcp.csv
/mnt/vita/scratch/vita-staff/users/<your_username>/check-clean-files/output/files_rcp.summary.txt
```

The summary includes the number of matching directories, `TOO_LARGE` entries, total known size, largest entries, and oldest modified entries.
