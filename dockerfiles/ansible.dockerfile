FROM python:3.12-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends openssh-client sshpass git \
    && rm -rf /var/lib/apt/lists/* \
    && pip install --no-cache-dir ansible-core passlib \
    && ansible-galaxy collection install community.postgresql

WORKDIR /ansible
