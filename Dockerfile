FROM --platform=linux/amd64 nvcr.io/nvidia/pytorch:23.11-py3

ARG LDAP_USERNAME
ARG LDAP_UID
ARG LDAP_GROUPNAME
ARG LDAP_GID

RUN groupadd --gid "${LDAP_GID}" "${LDAP_GROUPNAME}" \
    && useradd -m -s /bin/bash -g "${LDAP_GROUPNAME}" -u "${LDAP_UID}" "${LDAP_USERNAME}"

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        coreutils \
        findutils \
        gawk \
        procps \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/check-clean-files
COPY check_files.sh ./

USER ${LDAP_USERNAME}

ENTRYPOINT ["bash", "/opt/check-clean-files/check_files.sh"]
