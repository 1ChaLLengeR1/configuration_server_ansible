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
        ├── add_user.yml            # dodaje kolejnego usera (NEW_USER_*) + weryfikuje logowanie SSH
        ├── firewall.yml            # ufw + fail2ban
        ├── wireguard.yml           # tunel WireGuard wg0 (Swarm między serwerami tylko w tunelu)
        ├── swarm_wireguard.yml     # Docker Swarm na adresie WireGuarda + etykiety węzła
        ├── system_hardening.yml    # aktualizacje bezpieczeństwa, swap, czas, limity SSH, sysctl, konta, locale
        ├── docker_postgres_tuning.yml # limity logów Dockera/journald + strojenie PostgreSQL
        └── audit.yml               # audyt serwera (tylko odczyt) -> raport w ansible/reports/
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

## Krok 8 — zapora, fail2ban, WireGuard i Swarm na adresie WG

Dla serwera, który ma kiedyś dostać kolejny węzeł Swarma (np. VM w innej chmurze). Ruch Swarma między
serwerami (zarządzanie, sieci overlay/VXLAN, baza, broker) idzie wtedy wyłącznie szyfrowanym tunelem
WireGuard. Swarm warto mieć na adresie WG **od początku** — przeniesienie Swarma z działającymi
serwisami wymaga resetu (utrata sieci, sekretów, configów i etykiet).

1. Dopisz do `.env` (wszystko opcjonalne — w nawiasie wartości domyślne):

   ```env
   SSH_ALLOWED_FROM_1=            # IP/podsieci po przecinku, z których wolno SSH (puste = z każdego)
   WG_ADDRESS_1=10.99.0.1/24      # adres tego węzła w tunelu (10.99.0.1/24)
   WG_SUBNET_1=10.99.0.0/24       # podsieć tunelu - porty Swarma tylko z niej (10.99.0.0/24)
   WG_PEER_PUBLIC_IPS_1=          # publiczne IP pozostałych węzłów (WireGuard 51820/udp tylko od nich)
   SWARM_ADDR_POOL_1=10.20.0.0/16 # pula adresów sieci overlay (10.20.0.0/16)
   SWARM_NODE_LABELS_1=           # etykiety węzła po przecinku, np. treet.stateful=true
   ```

   i zrób `make down && make build && make up` (obraz dostał kolekcję `community.general` dla ufw).

2. Kolejność:

   ```
   make harden-ssh          # tylko klucze SSH (także na obrazach z cloud-init)
   make install-firewall    # ufw + fail2ban
   make install-wireguard   # wg0 + Docker startuje po wg0; wypisuje klucz publiczny
   make swarm-wireguard     # Swarm na adresie WG (reset tylko pustego, jednowęzłowego Swarma)
   make install-postgresql  # ponownie: listen na docker_gwbridge + PostgreSQL startuje po Dockerze
   ```

3. Sprawdzenie po **restarcie serwera** (`sudo reboot`): `ip -br addr show wg0`, `sudo docker info`
   (`NodeAddr` = adres WG), `sudo ss -ltnp | grep 5432` (localhost i gateway `docker_gwbridge`),
   `sudo ufw status verbose`, `sudo fail2ban-client status sshd`.

Uwagi:
- **`install-firewall` wymaga wcześniejszego `harden-ssh`** — na starcie sprawdza `sshd -T` i przerywa,
  jeśli da się zalogować hasłem albo na roota (logowanie tylko kluczem ustawia `harden_ssh.yml`).
- **ufw nie filtruje portów publikowanych przez Dockera** (np. 80/443 Traefika) — te ogranicza się
  w łańcuchu `DOCKER-USER`, osobno.
- **`harden_ssh.yml` na obrazach z cloud-init**: `sshd_config.d/50-cloud-init.conf` z
  `PasswordAuthentication yes` wygrywał z `no` w `sshd_config` (sshd bierze pierwszą wartość) —
  playbook zapisuje teraz ustawienia w `00-hardening.conf` i sprawdza wynik przez `sshd -T`.
- Kolejny węzeł: na nim `create-user` … `install-wireguard` z `WG_ADDRESS_1=10.99.0.2/24`, peery po
  obu stronach przez zmienną `wg_peers` (opis w `wireguard.yml`), potem `docker swarm join` po adresach WG.

## Krok 9 — hardening systemu, limity logów i strojenie PostgreSQL

1. Opcjonalnie w `.env` (w nawiasie wartości domyślne):

   ```env
   SSH_ALLOW_USERS_1=artur deploy   # konta z dostępem SSH, po spacji (puste = bez AllowUsers);
                                    # SERVER_USER_1 musi być na liście
   LOCK_USERS_1=debian              # konta do zablokowania (debian)
   SWAP_SIZE_1=4G                   # plik swap (4G); istniejący swap zostaje
   DOCKER_LOG_MAX_SIZE_1=20m        # limit pliku logu kontenera (20m)
   DOCKER_LOG_MAX_FILE_1=5          # liczba plików logu na kontener (5)
   JOURNALD_MAX_USE_1=1G            # limit logów systemowych (1G)
   PG_SHARED_BUFFERS_1=2GB          # strojenie PostgreSQL pod 12 GB RAM z kontenerami obok (2GB,
   PG_EFFECTIVE_CACHE_SIZE_1=6GB    #   6GB, 512MB, 16MB, 100) - przy innym serwerze dostosuj
   PG_MAINTENANCE_WORK_MEM_1=512MB
   PG_WORK_MEM_1=16MB
   PG_MAX_CONNECTIONS_1=100
   ```

   i `make down && make up`.

2. Uruchom:

   ```
   make system-hardening       # bez przerwy w działaniu (restart sshd tylko przy zmianie limitów)
   make tune-docker-postgres   # przy zmianie: restart Dockera (wszystkie kontenery) i PostgreSQL
   ```

Uwagi:
- Automatyczne aktualizacje obejmują źródła Debiana (m.in. bezpieczeństwo), **nie** repo Dockera
  i **nie** restartują serwera — po aktualizacji jądra restart robisz sam, w dogodnym momencie.
- Limit logów Dockera działa dla kontenerów tworzonych po zmianie (kolejny deploy stacka).
- Po `SSH_ALLOW_USERS_1` sprawdź w nowym terminalu, że logowanie dalej działa (jak po `harden-ssh`).

## Krok 10 — audyt serwera (tylko odczyt)

```
make audit
```

Uruchamia `ansible/files/audit.sh` na serwerze (nic nie zmienia) i zapisuje raport
`ansible/reports/audit_<host>_<data>.md` (katalog w `.gitignore`) z sekcjami **❌ Brakuje / luki**,
**⚠️ Do poprawy**, **✅ Mamy**, **ℹ️ Informacje** i listą tego, czego audyt z serwera sprawdzić nie może
(kopie zapasowe robione przez aplikację, Cloudflare, 2FA na kontach, klucze na Twoim komputerze, aplikacja,
alerty). Playbook kończy się błędem, jeśli jest choć jedna luka (FAIL) — przy każdym FAIL w raporcie jest
podpowiedź, którym `make` to naprawić.

Co sprawdza:

| Obszar | Sprawdzenia |
|---|---|
| system | restart po aktualizacji jądra, automatyczne aktualizacje, oczekujące łatki bezpieczeństwa, NTP, swap, dysk, limit journald |
| sysctl | SYN cookies, przekierowania ICMP, source routing, `kptr_restrict`, `ip_forward` (Docker) |
| konta | tylko root z UID 0, konta bez hasła, `sudo` bez `NOPASSWD`, grupy `sudo`/`docker`, zablokowane konta (`LOCK_USERS_1`) |
| ssh | root i hasła wyłączone (wynikowa konfiguracja `sshd -T`), `MaxAuthTries`, `AllowUsers`, X11, klucze w `authorized_keys` |
| zapora | ufw aktywny z domyślną blokadą, fail2ban z jailem sshd, usługi nasłuchujące publicznie poza `AUDIT_PUBLIC_PORTS_1`, reguły `DOCKER-USER` (porty kontenerów omijają ufw) |
| wireguard | `wg0` z adresem `WG_ADDRESS_1`, start z systemem, uprawnienia klucza, peery i handshake, Docker po `wg0` |
| docker | działa, limit logów kontenerów, Swarm na adresie WG, węzły, etykieta (`SWARM_NODE_LABELS_1`), MTU sieci overlay, porty publikowane |
| postgres | nie słucha publicznie, słucha na `docker_gwbridge`, start po Dockerze, `pg_hba` bez `trust` i bez `0.0.0.0/0`, `scram-sha-256`, superuserzy, strojenie, baza `AUDIT_DB_NAME_1` i rozszerzenia, kopia na hoście |

Skrypt da się też odpalić ręcznie na serwerze: `sudo bash audit.sh` (wynik linia po linii:
`STATUS|OBSZAR|SPRAWDZENIE|SZCZEGÓŁY`).
