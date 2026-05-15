# Check Clean Files on RCP / Run:ai

This repository contains the RCP version of the storage scan workflow. It is not tied to Slurm: the scanner runs inside a Docker image and the job is submitted from your laptop with Run:ai.

## Do We Still Need The Shell Files?

Yes, at least `check_files.sh`. It is the actual scanner and the Docker image runs it as the entrypoint.

The `submit_*.sh` files are optional convenience wrappers around `runai submit`. You can use them, or paste the equivalent raw `runai submit ... -- bash /opt/check-clean-files/check_files.sh ...` command yourself.

## Files

- `check_files.sh`: scans one or more base directories, writes CSV results, and prints a summary.
- `Dockerfile`: builds the image that contains `check_files.sh`.
- `submit_check_files_runai.sh`: optional wrapper to submit the scan as a Run:ai job.
- `clean_expired_files.sh`: deletes paths listed in a text file, with optional dry-run mode.
- `submit_clean_expired_files_runai.sh`: optional wrapper for cleanup through Run:ai.

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

## Submit With The Wrapper

```bash
bash submit_check_files_runai.sh \
  -i registry.rcp.epfl.ch/vita/check-clean-files:latest \
  -n check-files-<your_username> \
  -- -b /mnt/vita/scratch/vita-staff/users/<your_username> \
     -O /mnt/vita/scratch/vita-staff/users/<your_username>/check-clean-files-output \
     -m 50 -d 2 -o files_rcp.csv
```

The wrapper mounts the RCP scratch PVC at `/mnt/vita/scratch` and executes `/opt/check-clean-files/check_files.sh` from the image.

## Submit Without The Wrapper

```bash
runai submit --name check-files-<your_username> \
  --image registry.rcp.epfl.ch/vita/check-clean-files:latest \
  --cpu 4 \
  --memory 32G \
  --existing-pvc claimname=vita-scratch,path=/mnt/vita/scratch \
  --command -- bash /opt/check-clean-files/check_files.sh \
    -b /mnt/vita/scratch/vita-staff/users/<your_username> \
    -O /mnt/vita/scratch/vita-staff/users/<your_username>/check-clean-files-output \
    -m 50 -d 2 -o files_rcp.csv
```

## Output

```text
/mnt/vita/scratch/vita-staff/users/<your_username>/check-clean-files-output/files_rcp.csv
/mnt/vita/scratch/vita-staff/users/<your_username>/check-clean-files-output/files_rcp.summary.txt
```

The summary includes the number of matching directories, `TOO_LARGE` entries, total known size, largest entries, and oldest modified entries.
