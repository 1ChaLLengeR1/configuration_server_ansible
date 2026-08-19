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
        ├── create_user.yml         # tworzy usera (SERVER_USER_1) + wgrywa klucz SSH + sudo
        ├── harden_ssh.yml          # wyłącza root/hasła w SSH
        ├── docker_swarm.yml        # instaluje Docker CE + docker swarm init
        ├── postgresql.yml          # instaluje PostgreSQL + rolę deploy (CREATEDB) dla Swarm
        └── add_user.yml            # dodaje kolejnego usera (NEW_USER_*) + weryfikuje logowanie SSH
```

## Krok 1 — `.env` w katalogu głównym

Skopiuj dane dostępowe do świeżego serwera (na start logujemy się przez
usera systemowego i hasło, np. `debian` na obrazach cloud-init):

```env
SERVER_HOST_1=1.2.3.4
BEGIN_USER_1=debian
BEGIN_PASSWORD_1=haslo-startowe
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

## Krok 4 — nowy użytkownik z kluczem SSH (`SERVER_USER_1`)

Nazwa użytkownika docelowego jest konfigurowalna — poniższe przykłady używają
`artur`, ale może to być dowolna nazwa (`SERVER_USER_1` w `.env`).

1. Wygeneruj parę kluczy **lokalnie, na swoim hoście** (nie w kontenerze):

   ```
   mkdir -p ~/.ssh/<jakas-sciezka>/artur
   chmod 700 ~/.ssh/<jakas-sciezka>/artur
   ssh-keygen -t ed25519 -f ~/.ssh/<jakas-sciezka>/artur/id_ed25519 -N "" -C "artur"
   ```

2. Dopisz do `.env`:

   ```env
   SERVER_USER_1=artur
   SERVER_SSH_KEY_PATH_1=/home/<user>/.ssh/<jakas-sciezka>/artur/
   SERVER_PASSWORD_1=silne-haslo-dla-uzytkownika
   ```

   `SERVER_SSH_KEY_PATH_1` to katalog z kluczami — `docker-compose.yml` montuje
   go do kontenera pod ścieżką `/keys/${SERVER_USER_1}:ro` (patrz `${SERVER_SSH_KEY_PATH_1}`
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
   make verify-user
   ```

   Powinno pokazać nazwę z `SERVER_USER_1` i `sudo:wymaga_hasla` (sudo pyta
   o hasło użytkownika — to celowe, `NOPASSWD` nie jest tu ustawiane).

   Możesz też przetestować ręcznie z własnego terminala:

   ```
   ssh -i ~/.ssh/<jakas-sciezka>/artur/id_ed25519 artur@<SERVER_HOST_1>
   ```

## Krok 5 — hardening SSH (dopiero po zielonym `verify-user`!)

```
make harden-ssh
```

Wyłącza w `sshd_config`:
- `PermitRootLogin no`
- `PasswordAuthentication no`

i restartuje `sshd`. Od tego momentu jedyny sposób logowania na serwer to
klucz SSH (usera z `SERVER_USER_1` lub innego z kluczem w `authorized_keys`)
— hasła i logowanie na `root` przestają działać całkowicie.

**Zanim to odpalisz**, upewnij się, że masz dostęp do konsoli/panelu VPS
u dostawcy na wypadek błędu w konfiguracji — po hardeningu nie da się już
wejść na serwer hasłem, nawet w awaryjnej sytuacji.

## Krok 6 — przełączenie na docelowy dostęp

Po udanym hardeningu `ansible/inventory/hosts.yml` używa już użytkownika
z `SERVER_USER_1` + klucza zamiast `debian` + hasła:

```yaml
ansible_user: "{{ lookup('env', 'SERVER_USER_1') }}"
ansible_ssh_private_key_file: "/keys/{{ lookup('env', 'SERVER_USER_1') }}/id_ed25519"
ansible_become_password: "{{ lookup('env', 'SERVER_PASSWORD_1') }}"
```

Od teraz wszystkie playbooki (np. `make ping`) łączą się już jako `SERVER_USER_1`.
`BEGIN_USER_1` / `BEGIN_PASSWORD_1` w `.env` są od tego momentu martwe dla
SSH (hasła nie działają na serwerze w ogóle) — można je zostawić jako
dokumentację startowego dostępu albo usunąć.

## Krok 7 — Docker + Swarm, potem PostgreSQL

Te dwa playbooki działają niezależnie od Kroków 4–6 (można je odpalić od razu
po `make ping`, jako `debian`, albo później jako `SERVER_USER_1` — nie ma to
znaczenia). **Kolejność jest jednak istotna i odwrotna niż numeracja plików
mogłaby sugerować**: usługi wdrożone w Swarmie (`docker service` /
`docker stack deploy`) siedzą na sieciach typu *overlay* i łączą się z hostem
przez sieć `docker_gwbridge` — a tę Docker tworzy dopiero przy `docker swarm
init`. (To **nie** jest to samo co zwykły mostek `docker0`/`172.17.0.1` używany
przez samodzielne kontenery spoza Swarma — `docker_gwbridge` dostaje zwykle
podsieć `172.18.0.0/16`, ale dokładny gateway/podsieć bywają inne zależnie od
środowiska, więc playbook `postgresql.yml` wykrywa je w locie przez `docker
network inspect docker_gwbridge`, zamiast zakładać stały adres). Więc najpierw
Docker + Swarm, potem PostgreSQL — `postgresql.yml` i tak to sprawdzi i przerwie
z czytelnym komunikatem, jeśli kolejność będzie odwrotna (sieć `docker_gwbridge`
po prostu jeszcze nie będzie istnieć).

1. Zainstaluj Docker CE (oficjalne repo apt.docker.com) i zainicjuj Swarm
   (`docker swarm init --advertise-addr $SERVER_HOST_1`, pomijane, jeśli węzeł
   już jest w swarmie) — to przy okazji tworzy sieć `docker_gwbridge`:

   ```
   make install-docker-swarm
   ```

2. Dopisz do `.env` hasło CI dla użytkownika `deploy` w PostgreSQL:

   ```env
   PG_DEPLOY_PASSWORD_1=silne-haslo-dla-deploy
   ```

3. Zainstaluj PostgreSQL, ustaw `listen_addresses = 'localhost,<gateway
   docker_gwbridge>'`, dodaj wpisy w `pg_hba.conf` dla roli `deploy` (z
   `127.0.0.1/32` i z podsieci `docker_gwbridge`, żeby łączyły się usługi
   Swarm) i utwórz/zaktualizuj rolę `deploy` z hasłem z `PG_DEPLOY_PASSWORD_1`:

   ```
   make install-postgresql
   ```

   Playbook tworzy tylko rolę `deploy` (`LOGIN`, `CREATEDB`, bez `SUPERUSER`) —
   sam nie zakłada żadnej bazy. Dzięki `CREATEDB` rola `deploy` może sama
   tworzyć bazy (np. z poziomu pgAdmin4 po tunelu SSH) i jako właściciel
   utworzonej bazy ma automatycznie pełne prawa (CREATE/SELECT/UPDATE/DELETE)
   do wszystkich tabel, które w niej stworzy — bez dodatkowych `GRANT`-ów.

**Uwaga bezpieczeństwa:** `listen_addresses` celowo nie zawiera `*`/`0.0.0.0`
— PostgreSQL nie nasłuchuje na publicznym interfejsie serwera, tylko na
loopbacku i mostku Dockera, więc port 5432 nie jest wystawiony na świat.

**Dlaczego `scram-sha-256`, a nie `md5`:** wpisy w `pg_hba.conf` dla roli
`deploy` używają metody `scram-sha-256` — to nowoczesny, odporny na ataki
offline mechanizm challenge-response (SCRAM, RFC 5802), domyślny w PostgreSQL
od wersji 10. `md5` jest starsze i słabsze — hash łatwiej złamać offline, a
sam sposób jego liczenia (z hasła + nazwy użytkownika) ułatwia pewne ataki
w obrębie tej samej bazy. Rola `deploy` jest też tworzona z `encrypted: true`
w module `community.postgresql.postgresql_user`, więc jej hasło w bazie jest
przechowywane jako hash `scram-sha-256`, nie w postaci jawnej ani jako `md5`.

## Krok 8 — kolejny użytkownik (np. `deploy`) przez `add_user.yml`

Playbook `create_user.yml` (Krok 4) jest przywiązany na sztywno do `SERVER_USER_1`.
Do dodawania **kolejnych** userów (np. systemowego `deploy` do logowania z
GitHub Actions) służy generyczny `add_user.yml` — łączy się jako już istniejący
sudo-user (`SERVER_USER_1`), tworzy nowego usera, wgrywa jego klucz publiczny
i na końcu **sam** otwiera nowe, niezależne połączenie SSH kluczem prywatnym
nowego usera, żeby sprawdzić, że logowanie faktycznie działa (playbook faili
się, jeśli nie).

1. Wygeneruj klucz **lokalnie**, tak jak w Kroku 4 (bez `-N`/z pustym hasłem,
   jeśli klucz ma trafić np. do sekretu w GitHub Actions):

   ```
   ssh-keygen -t ed25519 -f ~/.ssh/<jakas-sciezka>/deploy/id_ed25519 -N "" -C "deploy"
   ```

2. Uzupełnij w `.env`:

   ```env
   NEW_USER_NAME=deploy
   NEW_USER_SSH_KEY_PATH=/home/<user>/.ssh/<jakas-sciezka>/deploy/
   NEW_USER_PASSWORD=silne-haslo-dla-uzytkownika
   NEW_USER_SUDO=true
   ```

   `NEW_USER_SSH_KEY_PATH` montuje się do kontenera pod `/keys/${NEW_USER_NAME}`
   (patrz drugi wpis `volumes` w `dockerfiles/docker-compose.yml`).

3. `make up` (złapać nowy mount), potem:

   ```
   make add-user
   ```

   Playbook tworzy usera, wgrywa klucz i od razu weryfikuje logowanie —
   wynik widać w outpucie (`whoami` + status `sudo`), bez osobnego kroku
   w stylu `verify-user`.

Uwaga: `deploy` z tego kroku to **osobny byt** od roli `deploy` w PostgreSQL
z Kroku 7 — jeden to user systemowy (SSH na serwer), drugi to rola w bazie
danych. Mogą mieć tę samą nazwę i różne hasła, nie mają ze sobą nic wspólnego.

## Zmienne `.env` — podsumowanie

| Zmienna | Do czego służy |
|---|---|
| `SERVER_HOST_1` | adres IP/hostname serwera (używany zawsze — i na starcie, i po hardeningu) |
| `BEGIN_USER_1` | startowy użytkownik (hasłowy, tylko do pierwszego logowania) — martwy po `harden-ssh` |
| `BEGIN_PASSWORD_1` | startowe hasło — martwe po `harden-ssh` |
| `SERVER_USER_1` | nazwa docelowego użytkownika (tworzony przez `create-user`, używany po hardeningu) |
| `SERVER_SSH_KEY_PATH_1` | katalog z kluczem SSH docelowego użytkownika (host, montowany do kontenera) |
| `SERVER_PASSWORD_1` | hasło systemowe docelowego użytkownika (do logowania lokalnego / `sudo`) |
| `PG_DEPLOY_PASSWORD_1` | hasło CI dla roli `deploy` w PostgreSQL (`playbooks/postgresql.yml`) |
| `NEW_USER_NAME` | nazwa kolejnego usera do dodania (`playbooks/add_user.yml`) |
| `NEW_USER_SSH_KEY_PATH` | katalog z kluczem SSH tego usera (host, montowany do kontenera) |
| `NEW_USER_PASSWORD` | hasło systemowe tego usera (do `sudo`, nie do logowania SSH) |
| `NEW_USER_SUDO` | `true`/`false` — czy dodać usera do grupy `sudo` (domyślnie `true`) |

## Wszystkie komendy `make`

| Komenda | Co robi |
|---|---|
| `make build` | zbuduj obraz Docker |
| `make up` | postaw kontener z Ansible w tle |
| `make down` | zdejmij kontener |
| `make shell` | wejdź do kontenera (bash) |
| `make ping` | test połączenia (`playbooks/ping.yml`) |
| `make create-user` | utwórz usera z `SERVER_USER_1` + klucz + sudo (`playbooks/create_user.yml`) |
| `make verify-user` | sprawdź logowanie kluczem jako `SERVER_USER_1` |
| `make harden-ssh` | wyłącz root/hasła w SSH (`playbooks/harden_ssh.yml`) |
| `make install-docker-swarm` | zainstaluj Docker CE + `docker swarm init` (`playbooks/docker_swarm.yml`) |
| `make install-postgresql` | zainstaluj PostgreSQL + skonfiguruj dostęp dla Swarm + rolę `deploy` z `CREATEDB` (`playbooks/postgresql.yml`) |
| `make add-user` | dodaj kolejnego usera z `NEW_USER_*` + klucz + weryfikacja logowania SSH (`playbooks/add_user.yml`) |
