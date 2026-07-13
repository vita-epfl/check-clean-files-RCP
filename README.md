# Check Clean Files on RCP / Run:ai

This repository contains the RCP version of the storage scan workflow. It is not tied to Slurm: the scanner runs inside a Docker image and the job is submitted with Run:ai.

## Do We Still Need The Shell Files?

Yes: keep `check_files.sh`. It is the actual scanner and the Docker image runs it as the entrypoint.

The old local submit and cleanup wrappers were removed to keep the RCP workflow simple. Use the raw Run:ai commands below.

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

## Submit With Run:ai

This example scans staff user scratch folders and measures only one folder inside each user directory, e.g. `/mnt/vita/scratch/vita-staff/users/<person>/<top-folder>`.

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
    -b /mnt/vita/scratch/vita-staff/users `
    -O /mnt/vita/scratch/vita-staff/users/<your_username>/programs/check-clean-files/output `
    -m 50 -d 2 --measure-mindepth 2 -t 600 -o files_rcp.csv
```

To scan student scratch folders, use `/mnt/vita/scratch/vita-students/users` as the base directory and write to a separate CSV:

```powershell
runai training submit check-files-<your_username>-students `
  -p vita-<your_username> `
  -i registry.rcp.epfl.ch/vita/check-clean-files:latest `
  --image-pull-policy Always `
  --cpu-core-request 4 `
  --cpu-memory-request 32G `
  --existing-pvc claimname=vita-scratch,path=/mnt/vita/scratch `
  --restart-policy Never `
  --command -- bash /opt/check-clean-files/check_files.sh `
    -b /mnt/vita/scratch/vita-students/users `
    -O /mnt/vita/scratch/vita-staff/users/<your_username>/programs/check-clean-files/output `
    -m 50 -d 2 --measure-mindepth 2 -t 600 -o files_students.csv
```

## Output

```text
/mnt/vita/scratch/vita-staff/users/<your_username>/programs/check-clean-files/output/files_rcp.csv
/mnt/vita/scratch/vita-staff/users/<your_username>/programs/check-clean-files/output/files_rcp.summary.txt
/mnt/vita/scratch/vita-staff/users/<your_username>/programs/check-clean-files/output/files_students.csv
/mnt/vita/scratch/vita-staff/users/<your_username>/programs/check-clean-files/output/files_students.summary.txt
```

If `-O` is omitted, the script writes to `output/` next to `check_files.sh`.

PowerShell uses backticks for line continuation. Do not use bash backslashes in PowerShell.

The CSV includes `Directory`, `Size`, `Modified`, `Accessed`, and `Owner`. The summary includes the number of matching directories, `TOO_LARGE` entries, total known size, largest entries, and oldest modified entries.
