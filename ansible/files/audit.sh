#!/usr/bin/env bash
# Audyt bezpieczeństwa i konfiguracji serwera - TYLKO ODCZYT (nic nie zmienia).
# Uruchamiany przez playbooks/audit.yml (jako root), da się też ręcznie: sudo bash audit.sh
# Wyjście: jedna linia na sprawdzenie, format: STATUS|KATEGORIA|SPRAWDZENIE|SZCZEGÓŁY
#   OK   - jest tak, jak powinno
#   WARN - działa, ale do poprawy / świadomej decyzji
#   FAIL - brakuje albo jest źle (luka)
#   INFO - informacja bez oceny
# Parametry przez zmienne środowiskowe (z playbooka, wszystkie z wartościami domyślnymi):
#   AUDIT_WG_IP (10.99.0.1), AUDIT_PUBLIC_PORTS ("22 80 443 51820"), AUDIT_DB_NAME (treet),
#   AUDIT_DB_EXTENSIONS ("unaccent uuid-ossp"), AUDIT_SWARM_LABEL (treet.stateful=true),
#   AUDIT_LOCK_USERS (debian)
set -u
export LC_ALL=C

WG_IP="${AUDIT_WG_IP:-10.99.0.1}"
PUBLIC_PORTS="${AUDIT_PUBLIC_PORTS:-22 80 443 51820}"
DB_NAME="${AUDIT_DB_NAME:-treet}"
DB_EXTENSIONS="${AUDIT_DB_EXTENSIONS:-unaccent uuid-ossp}"
SWARM_LABEL="${AUDIT_SWARM_LABEL:-treet.stateful=true}"
LOCK_USERS="${AUDIT_LOCK_USERS:-debian}"

r() { printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "${4:-}"; }
has() { command -v "$1" >/dev/null 2>&1; }
active() { systemctl is-active --quiet "$1"; }

# ============================== SYSTEM ==============================
. /etc/os-release 2>/dev/null
r INFO system "System" "${PRETTY_NAME:-?}, jądro $(uname -r), $(nproc) CPU, RAM $(free -h | awk '/^Mem:/{print $2}')"

running_kernel="$(uname -r)"
newest_kernel="$(ls /boot/vmlinuz-* 2>/dev/null | sed 's#/boot/vmlinuz-##' | sort -V | tail -1)"
if [ -n "$newest_kernel" ] && [ "$newest_kernel" != "$running_kernel" ]; then
  r WARN system "Restart po aktualizacji jądra" "działa $running_kernel, zainstalowane $newest_kernel - zaplanuj restart"
else
  r OK system "Restart po aktualizacji jądra" "niepotrzebny (działa najnowsze jądro)"
fi

if active unattended-upgrades && grep -qs 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades; then
  r OK system "Automatyczne aktualizacje bezpieczeństwa" "unattended-upgrades aktywne"
else
  r FAIL system "Automatyczne aktualizacje bezpieczeństwa" "brak/wyłączone - make system-hardening"
fi

pending="$(apt-get -s upgrade 2>/dev/null | grep -c '^Inst ')"
pending_sec="$(apt-get -s upgrade 2>/dev/null | grep '^Inst ' | grep -ci 'security')"
if [ "${pending_sec:-0}" -gt 0 ]; then
  r WARN system "Oczekujące aktualizacje" "$pending pakietów, w tym $pending_sec bezpieczeństwa (lista z ostatniego apt update)"
else
  r OK system "Oczekujące aktualizacje" "$pending pakietów, 0 bezpieczeństwa"
fi

if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = "yes" ]; then
  r OK system "Synchronizacja czasu" "NTP zsynchronizowany, strefa $(timedatectl show -p Timezone --value)"
else
  r FAIL system "Synchronizacja czasu" "zegar niezsynchronizowany - tokeny JWT (Clerk) mogą być odrzucane"
fi

swap_total="$(free -b | awk '/^Swap:/{print $2}')"
if [ "${swap_total:-0}" -gt 0 ]; then
  r OK system "Swap" "$(free -h | awk '/^Swap:/{print $2}'), swappiness $(cat /proc/sys/vm/swappiness)"
else
  r WARN system "Swap" "brak swapu - przy braku RAM jądro ubija procesy (np. PostgreSQL)"
fi

disk_pct="$(df --output=pcent / | tail -1 | tr -dc '0-9')"
if [ "$disk_pct" -ge 90 ]; then r FAIL system "Dysk /" "zajęte ${disk_pct}%"
elif [ "$disk_pct" -ge 80 ]; then r WARN system "Dysk /" "zajęte ${disk_pct}%"
else r OK system "Dysk /" "zajęte ${disk_pct}% ($(df -h --output=avail / | tail -1 | tr -d ' ') wolne)"; fi

journal_limit="$(grep -hs '^SystemMaxUse=' /etc/systemd/journald.conf /etc/systemd/journald.conf.d/*.conf | tail -1 | cut -d= -f2)"
if [ -n "$journal_limit" ]; then r OK system "Limit logów journald" "SystemMaxUse=$journal_limit, zajęte $(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMGT]')"
else r WARN system "Limit logów journald" "brak jawnego limitu - make tune-docker-postgres"; fi

check_sysctl() { # nazwa oczekiwana opis
  local v; v="$(sysctl -n "$1" 2>/dev/null)"
  if [ "$v" = "$2" ]; then r OK sysctl "$3" "$1=$v"; else r WARN sysctl "$3" "$1=$v (oczekiwane $2)"; fi
}
check_sysctl net.ipv4.tcp_syncookies 1 "Ochrona przed zalewem SYN"
check_sysctl net.ipv4.conf.all.accept_redirects 0 "Bez przekierowań ICMP (IPv4)"
check_sysctl net.ipv6.conf.all.accept_redirects 0 "Bez przekierowań ICMP (IPv6)"
check_sysctl net.ipv4.conf.all.send_redirects 0 "Bez wysyłania przekierowań"
check_sysctl net.ipv4.conf.all.accept_source_route 0 "Bez source routingu"
check_sysctl kernel.kptr_restrict 2 "Ukryte adresy jądra"
check_sysctl net.ipv4.ip_forward 1 "Przekazywanie pakietów (wymagane przez Dockera)"

# ============================== KONTA ==============================
uid0="$(awk -F: '$3==0{print $1}' /etc/passwd | tr '\n' ' ')"
if [ "$(echo $uid0)" = "root" ]; then r OK konta "Tylko root ma UID 0" "$uid0"
else r FAIL konta "Tylko root ma UID 0" "konta z UID 0: $uid0"; fi

empty_pw="$(awk -F: '$2==""{print $1}' /etc/shadow | tr '\n' ' ')"
if [ -z "$empty_pw" ]; then r OK konta "Konta bez hasła" "brak"
else r FAIL konta "Konta bez hasła" "$empty_pw"; fi

sudoers="$(getent group sudo | cut -d: -f4)"
r INFO konta "Członkowie grupy sudo" "${sudoers:-brak}"
nopasswd="$(grep -rhsE '^[^#].*NOPASSWD' /etc/sudoers /etc/sudoers.d/ | tr '\n' ';')"
if [ -z "$nopasswd" ]; then r OK konta "sudo wymaga hasła" "brak reguł NOPASSWD"
else r WARN konta "sudo wymaga hasła" "reguły NOPASSWD: $nopasswd"; fi

docker_members="$(getent group docker | cut -d: -f4)"
r INFO konta "Członkowie grupy docker (dostęp równy rootowi)" "${docker_members:-brak}"

login_users="$(awk -F: '$3>=1000 && $3<65534 && $7!~/(nologin|false)$/{print $1}' /etc/passwd | tr '\n' ' ')"
r INFO konta "Konta z powłoką logowania (UID>=1000)" "$login_users"
for u in $LOCK_USERS; do
  if getent passwd "$u" >/dev/null; then
    st="$(passwd -S "$u" 2>/dev/null | awk '{print $2}')"; sh="$(getent passwd "$u" | cut -d: -f7)"
    if [ "$st" = "L" ] && [[ "$sh" =~ (nologin|false)$ ]]; then r OK konta "Konto $u zablokowane" "hasło L, powłoka $sh"
    else r WARN konta "Konto $u zablokowane" "status hasła $st, powłoka $sh - make system-hardening"; fi
  fi
done

# ============================== SSH ==============================
sshT="$(sshd -T 2>/dev/null)"
sshv() { echo "$sshT" | awk -v k="$1" '$1==k{print $2; exit}'; }
[ "$(sshv permitrootlogin)" = "no" ] && r OK ssh "Logowanie na root wyłączone" "permitrootlogin no" \
  || r FAIL ssh "Logowanie na root wyłączone" "permitrootlogin $(sshv permitrootlogin) - make harden-ssh"
[ "$(sshv passwordauthentication)" = "no" ] && r OK ssh "Logowanie hasłem wyłączone" "passwordauthentication no" \
  || r FAIL ssh "Logowanie hasłem wyłączone" "passwordauthentication $(sshv passwordauthentication) - make harden-ssh"
[ "$(sshv kbdinteractiveauthentication)" = "no" ] && r OK ssh "Logowanie interaktywne wyłączone" "kbdinteractiveauthentication no" \
  || r FAIL ssh "Logowanie interaktywne wyłączone" "kbdinteractiveauthentication $(sshv kbdinteractiveauthentication)"
[ "$(sshv pubkeyauthentication)" = "yes" ] && r OK ssh "Logowanie kluczem włączone" "pubkeyauthentication yes" \
  || r FAIL ssh "Logowanie kluczem włączone" "pubkeyauthentication $(sshv pubkeyauthentication)"
mat="$(sshv maxauthtries)"
[ "${mat:-6}" -le 3 ] && r OK ssh "Limit prób logowania" "maxauthtries $mat" \
  || r WARN ssh "Limit prób logowania" "maxauthtries $mat (zalecane 3) - make system-hardening"
allow="$(echo "$sshT" | awk '$1=="allowusers"{print $2}' | tr '\n' ' ')"
[ -n "$allow" ] && r OK ssh "Lista kont z dostępem SSH (AllowUsers)" "$allow" \
  || r WARN ssh "Lista kont z dostępem SSH (AllowUsers)" "brak - każde konto z kluczem może się logować (SSH_ALLOW_USERS_1)"
[ "$(sshv x11forwarding)" = "no" ] && r OK ssh "X11 forwarding wyłączony" "" || r WARN ssh "X11 forwarding wyłączony" "x11forwarding $(sshv x11forwarding)"
keys_info=""
for h in /root /home/*; do
  f="$h/.ssh/authorized_keys"
  [ -s "$f" ] && keys_info="$keys_info $(basename "$h"):$(grep -cvE '^\s*(#|$)' "$f")"
done
r INFO ssh "Klucze w authorized_keys (konto:liczba)" "${keys_info:- brak}"
[ -s /root/.ssh/authorized_keys ] && r WARN ssh "Klucze roota" "/root/.ssh/authorized_keys niepusty (root i tak bez logowania - do usunięcia)"

# ============================== ZAPORA ==============================
if has ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
  defin="$(ufw status verbose | awk -F'[:,]' '/^Default:/{print $2}' | xargs)"
  if [[ "$defin" == deny* || "$defin" == reject* ]]; then r OK zapora "ufw aktywny, domyślnie blokuje ruch przychodzący" "$defin"
  else r FAIL zapora "ufw aktywny, domyślnie blokuje ruch przychodzący" "domyślnie: $defin"; fi
else
  r FAIL zapora "ufw aktywny" "nieaktywny/brak - make install-firewall"
fi

if active fail2ban && fail2ban-client status sshd >/dev/null 2>&1; then
  banned="$(fail2ban-client status sshd | awk -F: '/Total banned/{gsub(/ /,"",$2);print $2}')"
  r OK zapora "fail2ban (jail sshd)" "aktywny, zbanowanych łącznie: $banned"
else
  r FAIL zapora "fail2ban (jail sshd)" "nieaktywny albo brak jaila sshd - make install-firewall"
fi

# Porty nasłuchujące poza localhostem, WG i siecią Dockera (192.168/172.x/10.x) = widoczne z internetu,
# o ile nie blokuje ich ufw. Porty publikowane przez Dockera (docker-proxy) ufw NIE filtruje.
public_listen="$(ss -H -tulpn 2>/dev/null | awk '{print $1, $5, $7}' \
  | grep -vE ' (127\.|\[::1\]|::1|10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|\[?fe80)' )"
# Oczekiwane porty systemowe: udp/68 = klient DHCP (adres serwera od dostawcy).
# Porty Swarma (2377/tcp, 7946/tcp+udp, 4789/udp - VXLAN jądro otwiera na wszystkich adresach) są OK,
# jeśli ufw wpuszcza je tylko z podsieci WireGuarda.
SYSTEM_PORTS="udp/68"
SWARM_PORTS="tcp/2377 tcp/7946 udp/7946 udp/4789"
ufw_rules="$(ufw status 2>/dev/null)"
unexpected=""; swarm_open=""; swarm_wg=""
while read -r proto addr proc; do
  [ -z "$addr" ] && continue
  port="${addr##*:}"; key="${proto}/${port}"
  ok=0; for p in $PUBLIC_PORTS; do [ "$port" = "$p" ] && ok=1; done
  for p in $SYSTEM_PORTS; do [ "$key" = "$p" ] && ok=1; done
  if echo " $SWARM_PORTS " | grep -q " $key "; then
    ok=1
    # `ufw status` ma "ALLOW", `ufw status verbose` - "ALLOW IN"; reguła ograniczona = źródło inne niż Anywhere
    if echo "$ufw_rules" | grep -E "^${port}/${proto}[[:space:]]+ALLOW( IN)?[[:space:]]+" | grep -qv "Anywhere"; then swarm_wg="$swarm_wg $key"
    else swarm_open="$swarm_open $key"; fi
  fi
  name="$(echo "$proc" | sed -nE 's/^users:\(\("([^"]+)".*/\1/p')"
  [ "$ok" = 0 ] && unexpected="$unexpected $key:${name:-?}"
done <<< "$public_listen"
unexpected="$(echo "$unexpected" | xargs -n1 2>/dev/null | sort -u | xargs)"
if [ -z "$unexpected" ]; then r OK zapora "Usługi nasłuchujące publicznie" "tylko oczekiwane: $PUBLIC_PORTS (+ DHCP udp/68)"
else r WARN zapora "Usługi nasłuchujące publicznie (poza $PUBLIC_PORTS)" "$unexpected - zablokowane przez ufw, o ile nie są portami Dockera"; fi
swarm_open="$(echo "$swarm_open" | xargs -n1 2>/dev/null | sort -u | xargs)"
swarm_wg="$(echo "$swarm_wg" | xargs -n1 2>/dev/null | sort -u | xargs)"
[ -n "$swarm_open" ] && r FAIL zapora "Porty Swarma tylko z WireGuarda" "$swarm_open bez reguły ufw ograniczonej do WG - make install-firewall"
[ -z "$swarm_open" ] && [ -n "$swarm_wg" ] && r OK zapora "Porty Swarma tylko z WireGuarda" "$swarm_wg - ufw wpuszcza tylko z podsieci WG"

if has iptables && iptables -S DOCKER-USER 2>/dev/null | grep -qvE '^-N|-j RETURN$'; then
  r OK zapora "Filtr portów Dockera (DOCKER-USER)" "są reguły w DOCKER-USER"
else
  r WARN zapora "Filtr portów Dockera (DOCKER-USER)" "brak reguł - porty publikowane przez kontenery (np. 80/443) otwarte dla całego internetu (TreeT: faza E, tylko Cloudflare)"
fi

# ============================== WIREGUARD ==============================
if ip -4 -br addr show wg0 2>/dev/null | grep -q "$WG_IP"; then
  r OK wireguard "Interfejs wg0" "$(ip -4 -br addr show wg0 | awk '{print $3}'), MTU $(cat /sys/class/net/wg0/mtu)"
else
  r FAIL wireguard "Interfejs wg0" "brak wg0 z adresem $WG_IP - make install-wireguard"
fi
systemctl is-enabled --quiet wg-quick@wg0 2>/dev/null && r OK wireguard "wg0 włączony na starcie" "" \
  || r FAIL wireguard "wg0 włączony na starcie" "wg-quick@wg0 nie jest enabled"
if [ -f /etc/wireguard/wg0.key ]; then
  perm="$(stat -c '%a %U' /etc/wireguard/wg0.key)"
  [ "$perm" = "600 root" ] && r OK wireguard "Klucz prywatny chroniony" "$perm" || r FAIL wireguard "Klucz prywatny chroniony" "uprawnienia $perm (oczekiwane 600 root)"
fi
if has wg && ip link show wg0 >/dev/null 2>&1; then
  peers="$(wg show wg0 peers 2>/dev/null | wc -l)"
  hs="$(wg show wg0 latest-handshakes 2>/dev/null | awk -v now="$(date +%s)" '$2>0 && now-$2<180{c++} END{print c+0}')"
  r INFO wireguard "Peery" "$peers skonfigurowanych, $hs z handshake < 3 min"
fi
grep -qs 'After=wg-quick@wg0.service' /etc/systemd/system/docker.service.d/*.conf \
  && r OK wireguard "Docker startuje po wg0" "" \
  || r WARN wireguard "Docker startuje po wg0" "brak drop-inu - po restarcie Swarm może nie znaleźć adresu WG"

# ============================== DOCKER / SWARM ==============================
if active docker; then
  r OK docker "Docker działa" "$(docker version --format '{{.Server.Version}}' 2>/dev/null)"
  logdrv="$(docker info --format '{{.LoggingDriver}}' 2>/dev/null)"
  if grep -qs '"max-size"' /etc/docker/daemon.json; then
    r OK docker "Limit logów kontenerów" "$logdrv, $(grep -oE '"max-(size|file)": *"[^"]+"' /etc/docker/daemon.json | tr '\n' ' ')"
  else
    r FAIL docker "Limit logów kontenerów" "brak max-size - logi mogą zapełnić dysk (make tune-docker-postgres)"
  fi
  sw_state="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null)"
  sw_addr="$(docker info --format '{{.Swarm.NodeAddr}}' 2>/dev/null)"
  if [ "$sw_state" = "active" ]; then
    if [ "$sw_addr" = "$WG_IP" ]; then r OK docker "Swarm na adresie WireGuarda" "active, NodeAddr $sw_addr"
    else r FAIL docker "Swarm na adresie WireGuarda" "NodeAddr $sw_addr (oczekiwane $WG_IP) - make swarm-wireguard"; fi
    r INFO docker "Węzły Swarma" "$(docker node ls --format '{{.Hostname}} {{.Status}} {{.ManagerStatus}}' 2>/dev/null | tr '\n' ';')"
    labels="$(docker node inspect self --format '{{range $k,$v := .Spec.Labels}}{{$k}}={{$v}} {{end}}' 2>/dev/null)"
    if [ -n "$SWARM_LABEL" ]; then
      echo "$labels" | grep -qw -- "$SWARM_LABEL" && r OK docker "Etykieta węzła" "$labels" \
        || r FAIL docker "Etykieta węzła" "brak $SWARM_LABEL (są: ${labels:-brak}) - make swarm-wireguard"
    fi
    r INFO docker "Stacki / serwisy" "$(docker stack ls --format '{{.Name}}' 2>/dev/null | tr '\n' ' ') / $(docker service ls -q 2>/dev/null | wc -l) serwisów"
    nets="$(docker network ls --filter driver=overlay --format '{{.Name}}' | grep -v '^ingress$')"
    for n in $nets; do
      mtu="$(docker network inspect "$n" --format '{{index .Options "com.docker.network.driver.mtu"}}' 2>/dev/null)"
      [ "$mtu" = "1330" ] && r OK docker "MTU sieci overlay $n" "1330" || r WARN docker "MTU sieci overlay $n" "${mtu:-domyślne 1500} (oczekiwane 1330 pod WireGuard)"
    done
  else
    r FAIL docker "Swarm" "nieaktywny - make swarm-wireguard"
  fi
  pub_ports="$(docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | grep -E '0\.0\.0\.0|:::' | tr '\n' ';')"
  r INFO docker "Porty publikowane przez kontenery (omijają ufw)" "${pub_ports:-brak}"
else
  r FAIL docker "Docker działa" "usługa docker nieaktywna"
fi

# ============================== POSTGRESQL ==============================
if active postgresql || systemctl list-units --type=service --state=running 2>/dev/null | grep -q 'postgresql@'; then
  pgv="$(sudo -u postgres psql -XAtc 'show server_version' 2>/dev/null)"
  r OK postgres "PostgreSQL działa" "$pgv"
  gw="$(docker network inspect docker_gwbridge --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null)"
  listen="$(ss -H -ltn 'sport = :5432' | awk '{print $4}' | tr '\n' ' ')"
  if echo "$listen" | grep -qE '(^| )(0\.0\.0\.0|\[::\]|\*):5432'; then
    r FAIL postgres "PostgreSQL nie słucha publicznie" "słucha na wszystkich adresach: $listen"
  else
    r OK postgres "PostgreSQL nie słucha publicznie" "$listen"
  fi
  if [ -n "$gw" ]; then
    echo "$listen" | grep -q "$gw:5432" && r OK postgres "Dostęp dla kontenerów Swarma" "słucha na $gw (docker_gwbridge)" \
      || r FAIL postgres "Dostęp dla kontenerów Swarma" "nie słucha na $gw - make install-postgresql"
  fi
  grep -qs 'After=docker.service' /etc/systemd/system/postgresql@.service.d/*.conf \
    && r OK postgres "PostgreSQL startuje po Dockerze" "" \
    || r WARN postgres "PostgreSQL startuje po Dockerze" "brak drop-inu - po restarcie może słuchać tylko na localhost"
  hba="$(sudo -u postgres psql -XAtc 'show hba_file' 2>/dev/null)"
  trust="$(grep -E '^\s*host' "$hba" 2>/dev/null | awk '$NF=="trust"' | tr -s ' ' | tr '\n' ';')"
  wide="$(grep -E '^\s*host' "$hba" 2>/dev/null | grep -E '0\.0\.0\.0/0|::/0|\sall\s+all\s+all\s' | tr -s ' ' | tr '\n' ';')"
  [ -z "$trust" ] && r OK postgres "pg_hba bez 'trust' dla połączeń sieciowych" "" || r FAIL postgres "pg_hba bez 'trust' dla połączeń sieciowych" "$trust"
  [ -z "$wide" ] && r OK postgres "pg_hba bez dostępu z dowolnego adresu" "" || r FAIL postgres "pg_hba bez dostępu z dowolnego adresu" "$wide"
  enc="$(sudo -u postgres psql -XAtc 'show password_encryption' 2>/dev/null)"
  [ "$enc" = "scram-sha-256" ] && r OK postgres "Szyfrowanie haseł" "$enc" || r WARN postgres "Szyfrowanie haseł" "$enc (zalecane scram-sha-256)"
  supers="$(sudo -u postgres psql -XAtc "select string_agg(rolname, ' ') from pg_roles where rolsuper" 2>/dev/null)"
  [ "$supers" = "postgres" ] && r OK postgres "Superuser tylko postgres" "" || r WARN postgres "Superuser tylko postgres" "superuserzy: $supers"
  r INFO postgres "Role z logowaniem" "$(sudo -u postgres psql -XAtc "select string_agg(rolname || case when rolcreatedb then '(createdb)' else '' end, ' ') from pg_roles where rolcanlogin" 2>/dev/null)"
  sb="$(sudo -u postgres psql -XAtc 'show shared_buffers' 2>/dev/null)"
  if [ -z "$sb" ]; then r WARN postgres "Strojenie pamięci" "nie udało się odczytać (brak dostępu do psql jako postgres)"
  elif [ "$sb" = "128MB" ]; then r WARN postgres "Strojenie pamięci" "shared_buffers 128MB (domyślne) - make tune-docker-postgres"
  else r OK postgres "Strojenie pamięci" "shared_buffers $sb, effective_cache_size $(sudo -u postgres psql -XAtc 'show effective_cache_size' 2>/dev/null)"; fi
  if sudo -u postgres psql -XAtc "select 1 from pg_database where datname='$DB_NAME'" 2>/dev/null | grep -q 1; then
    owner="$(sudo -u postgres psql -XAtc "select pg_get_userbyid(datdba) from pg_database where datname='$DB_NAME'" 2>/dev/null)"
    r OK postgres "Baza $DB_NAME" "właściciel $owner, rozmiar $(sudo -u postgres psql -XAtc "select pg_size_pretty(pg_database_size('$DB_NAME'))" 2>/dev/null)"
    have_ext="$(sudo -u postgres psql -d "$DB_NAME" -XAtc 'select extname from pg_extension' 2>/dev/null | tr '\n' ' ')"
    for e in $DB_EXTENSIONS; do
      echo " $have_ext " | grep -q " $e " && r OK postgres "Rozszerzenie $e w $DB_NAME" "" \
        || r FAIL postgres "Rozszerzenie $e w $DB_NAME" "brak - sudo -u postgres psql -d $DB_NAME -c 'CREATE EXTENSION \"$e\";'"
    done
  else
    r WARN postgres "Baza $DB_NAME" "nie istnieje"
  fi
  if grep -lsE 'pg_dump|pgbackrest|wal-g' /etc/cron.d/* /var/spool/cron/crontabs/* >/dev/null 2>&1 \
     || systemctl list-timers --all 2>/dev/null | grep -qiE 'pg_dump|pgbackrest|wal-g|postgres[^ ]*backup'; then
    r OK postgres "Kopia zapasowa bazy (na hoście)" "wykryto zadanie kopii"
  else
    r WARN postgres "Kopia zapasowa bazy (na hoście)" "nie wykryto na hoście - jeśli kopię robi aplikacja (np. Celery -> GCS), sprawdź ją osobno"
  fi
else
  r INFO postgres "PostgreSQL" "nie działa / brak na tym serwerze"
fi
