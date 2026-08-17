# configuration_server_ansible

Ansible uruchamiany z kontenera Docker (nie trzeba mieć Ansible zainstalowanego
lokalnie) do zarządzania konfiguracją serwera — sprawdzanie połączenia,
tworzenie użytkowników, hardening SSH.

## Wymagania

- Docker + wtyczka `docker compose`
- `make`

## Struktura

```
.
├── Makefile                       # wszystkie komendy (build/up/down/ping/...)
├── .env                            # sekrety i dane serwera (NIE w git)
├── dockerfiles/
│   ├── ansible.dockerfile          # obraz control-node (ansible-core + ssh + git)
│   └── docker-compose.yml          # serwis `ansible`, mounty repo i kluczy SSH
└── ansible/
    ├── ansible.cfg
    ├── inventory/hosts.yml         # lista serwerów
    └── playbooks/
        ├── ping.yml                # test połączenia
        ├── create_user.yml         # tworzy usera + wgrywa klucz SSH + sudo
        └── harden_ssh.yml          # wyłącza root/hasła w SSH
```

## Krok 1 — `.env` w katalogu głównym

Skopiuj dane dostępowe do świeżego serwera (na start logujemy się przez
usera systemowego i hasło, np. `debian` na obrazach cloud-init):

```env
SERVER_HOST_1=1.2.3.4
SERVER_USER_1=debian
SERVER_PASSWORD_1=haslo-startowe
```

Wartości **bez cudzysłowów** — `docker --env-file` przekazuje je dosłownie,
cudzysłowy trafiłyby do hosta/hasła jako część wartości i popsuły połączenie SSH.

`.env` jest w `.gitignore` — nigdy nie trafia do repo.

## Krok 2 — kontener z Ansible

```
make build   # zbuduj obraz (dockerfiles/ansible.dockerfile)
make up      # postaw kontener w tle (docker compose up -d)
make down    # zdejmij kontener, jak skończysz pracę
```

Kontener stoi w tle (`sleep infinity`), a komendy Ansible odpalane są przez
`docker compose exec` — nie trzeba go za każdym razem stawiać/zabijać.

## Krok 3 — test połączenia

```
make ping
```

Odpala `ansible/playbooks/ping.yml` na hostach z `inventory/hosts.yml`.
Zielony wynik (`unreachable=0 failed=0`) = dane w `.env` są poprawne.

## Krok 4 — nowy użytkownik z kluczem SSH (`artur`)

1. Wygeneruj parę kluczy **lokalnie, na swoim hoście** (nie w kontenerze):

   ```
   mkdir -p ~/.ssh/<jakas-sciezka>/artur
   chmod 700 ~/.ssh/<jakas-sciezka>/artur
   ssh-keygen -t ed25519 -f ~/.ssh/<jakas-sciezka>/artur/id_ed25519 -N "" -C "artur"
   ```

2. Dopisz do `.env`:

   ```env
   ARTUR_SSH_KEY_PATH=/home/<user>/.ssh/<jakas-sciezka>/artur/
   ARTUR_PASSWORD=silne-haslo-dla-artura
   ```

   `ARTUR_SSH_KEY_PATH` to katalog z kluczami — `docker-compose.yml` montuje
   go do kontenera pod stałą ścieżką `/keys/artur:ro` (patrz `${ARTUR_SSH_KEY_PATH}`
   w `dockerfiles/docker-compose.yml`).

3. Zrestartuj kontener, żeby złapał nowy mount i nowe zmienne z `.env`:

   ```
   make down
   make up
   ```

4. Utwórz użytkownika na serwerze (user, grupa `sudo`, `authorized_keys`):

   ```
   make create-user
   ```

5. **Zanim cokolwiek dalej** — sprawdź, że logowanie kluczem faktycznie działa:

   ```
   make verify-artur
   ```

   Powinno pokazać `artur` i `sudo:wymaga_hasla` (sudo pyta o hasło artura —
   to celowe, `NOPASSWD` nie jest tu ustawiane).

   Możesz też przetestować ręcznie z własnego terminala:

   ```
   ssh -i ~/.ssh/<jakas-sciezka>/artur/id_ed25519 artur@<SERVER_HOST_1>
   ```

## Krok 5 — hardening SSH (dopiero po zielonym `verify-artur`!)

```
make harden-ssh
```

Wyłącza w `sshd_config`:
- `PermitRootLogin no`
- `PasswordAuthentication no`

i restartuje `sshd`. Od tego momentu jedyny sposób logowania na serwer to
klucz SSH (usera `artur` lub innego z kluczem w `authorized_keys`) — hasła
i logowanie na `root` przestają działać całkowicie.

**Zanim to odpalisz**, upewnij się, że masz dostęp do konsoli/panelu VPS
u dostawcy na wypadek błędu w konfiguracji — po hardeningu nie da się już
wejść na serwer hasłem, nawet w awaryjnej sytuacji.

## Krok 6 — przełączenie na docelowy dostęp

Po udanym hardeningu `ansible/inventory/hosts.yml` używa już `artur` + klucza
zamiast `debian` + hasła:

```yaml
ansible_user: artur
ansible_ssh_private_key_file: /keys/artur/id_ed25519
ansible_become_password: "{{ lookup('env', 'ARTUR_PASSWORD') }}"
```

Od teraz wszystkie playbooki (np. `make ping`) łączą się już jako `artur`.
`SERVER_USER_1` / `SERVER_PASSWORD_1` w `.env` są od tego momentu martwe dla
SSH (hasła nie działają na serwerze w ogóle) — można je zostawić jako
dokumentację startowego dostępu albo usunąć.

## Zmienne `.env` — podsumowanie

| Zmienna | Do czego służy |
|---|---|
| `SERVER_HOST_1` | adres IP/hostname serwera |
| `SERVER_USER_1` | startowy użytkownik (hasłowy) — martwy po `harden-ssh` |
| `SERVER_PASSWORD_1` | startowe hasło — martwe po `harden-ssh` |
| `ARTUR_SSH_KEY_PATH` | katalog z kluczem SSH artura (host, montowany do kontenera) |
| `ARTUR_PASSWORD` | hasło systemowe artura (do logowania lokalnego / `sudo`) |

## Wszystkie komendy `make`

| Komenda | Co robi |
|---|---|
| `make build` | zbuduj obraz Docker |
| `make up` | postaw kontener z Ansible w tle |
| `make down` | zdejmij kontener |
| `make shell` | wejdź do kontenera (bash) |
| `make ping` | test połączenia (`playbooks/ping.yml`) |
| `make create-user` | utwórz usera `artur` + klucz + sudo (`playbooks/create_user.yml`) |
| `make verify-artur` | sprawdź logowanie kluczem jako `artur` |
| `make harden-ssh` | wyłącz root/hasła w SSH (`playbooks/harden_ssh.yml`) |
