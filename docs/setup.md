# Plan i architektura — configuration_server_ansible

> Ten dokument to notatka robocza: jak widzę architekturę tego repozytorium
> zanim zaczniemy budować konkretne pliki. Struktura poniżej to propozycja do
> dyskusji — zmienimy ją w miarę ustalania szczegółów (jakie serwery, jaka
> aplikacja, jakie usługi).

## Cel projektu

Repozytorium ma zawierać zestaw mechanizmów Ansible do:
- zarządzania konfiguracją serwerów (bazowy hardening, pakiety, użytkownicy),
- deployu aplikacji (checkout z gita, restart usług),
- instalacji i konfiguracji Dockera na serwerach docelowych,
- instalacji i konfiguracji PostgreSQL,
- zmian konfiguracyjnych ad-hoc na serwerach.

Całość ma być uruchamiana z kontenera Docker (Ansible zainstalowany w
obrazie, połączenie z serwerami po SSH z wnętrza kontenera — nie musimy mieć
Ansible zainstalowanego lokalnie). Do tego Makefile ze standardowymi
komendami (build obrazu, shell, deploy, lint, itd.).

## Referencje / dokumentacja Ansible (do pracy)

- Oficjalna struktura katalogów projektu Ansible:
  https://docs.ansible.com/ansible/latest/tips_tricks/sample_setup.html
- Dobre praktyki (Red Hat CoP):
  https://redhat-cop.github.io/automation-good-practices/
- Wzorce uruchamiania Ansible w Dockerze (mount kluczy SSH, wolumen na
  playbooki): `philm/ansible_playbook`, `kartoza/docker-ansible` na Docker Hub / GitHub

Skrót najważniejszych pojęć:
- **inventory** — lista hostów/grup, na których Ansible wykonuje zadania (plik
  `hosts.yml`/`hosts.ini` lub inventory dynamiczne).
- **playbook** — plik YAML opisujący, jakie role/taski wykonać na jakich hostach.
- **role** — samodzielny, wielokrotnego użytku pakiet tasków/handlerów/zmiennych
  (standardowa struktura: `tasks/`, `handlers/`, `defaults/`, `vars/`, `templates/`,
  `files/`, `meta/`).
- **group_vars / host_vars** — zmienne przypisane do grupy hostów lub
  konkretnego hosta, trzymane osobno od inventory.
- **Ansible Vault** — szyfrowanie sekretów (hasła, klucze) trzymanych w repo.
- **tagi** — pozwalają uruchamiać tylko wybrane fragmenty playbooka
  (`--tags docker`, `--skip-tags postgresql`).

## Proponowana struktura katalogów (do ustalenia)

```
configuration_server_ansible/
├── README.md                    # opis projektu, jak z nim pracować
├── docs/
│   └── setup.md                 # ten dokument
├── Makefile                     # komendy: build, shell, ping, deploy-*, lint, vault-*
├── ansible.cfg                  # konfiguracja Ansible (inventory, roles_path, itp.)
├── requirements.yml             # kolekcje Ansible Galaxy (community.docker, community.postgresql, ...)
├── docker/
│   ├── Dockerfile               # obraz control-node: ansible-core + ssh client + git
│   └── docker-compose.yml       # serwis `ansible` z mountem repo i kluczy SSH
├── inventories/
│   ├── staging/
│   │   ├── hosts.yml
│   │   └── group_vars/all.yml
│   └── production/
│       ├── hosts.yml
│       └── group_vars/all.yml
├── playbooks/
│   ├── site.yml                 # główny playbook zbierający wszystko
│   ├── deploy.yml               # checkout aplikacji + deploy
│   ├── docker.yml               # instalacja/konfiguracja Dockera na serwerach
│   └── postgresql.yml           # instalacja/konfiguracja PostgreSQL
└── roles/
    ├── common/                  # bazowa konfiguracja serwera
    ├── docker/                  # Docker Engine na serwerach docelowych
    ├── postgresql/              # PostgreSQL
    └── deploy_app/              # checkout z gita + restart usług
```

## Otwarte pytania / do ustalenia z użytkownikiem

- Jakie konkretnie serwery/hosty wchodzą w grę (nazwy, IP, dostęp SSH)?
- Jaka aplikacja ma być deployowana (repo, branch, sposób restartu usługi)?
- Wersja PostgreSQL i czy działa w Dockerze czy natywnie na hoście?
- Czy potrzebujemy więcej środowisk niż staging/production?
- Sposób zarządzania sekretami: Ansible Vault w repo czy zewnętrzny secret
  manager?

## Status

To jest wyłącznie dokument planistyczny — żadne katalogi/pliki z sekcji
"Proponowana struktura" nie zostały jeszcze utworzone. Czekam na wytyczne, co
i jak budować dalej.
