COMPOSE := docker compose -f dockerfiles/docker-compose.yml --env-file .env

.PHONY: build up down shell ping logs create-user verify-user harden-ssh install-docker-swarm install-postgresql add-user install-firewall install-wireguard swarm-wireguard

## Zbuduj obraz Docker z Ansible (dockerfiles/ansible.dockerfile)
build:
	$(COMPOSE) build

## Wstaw kontener z Ansible w tle (docker compose up -d)
up:
	$(COMPOSE) up -d --build

## Ubij kontener z Ansible (docker compose down)
down:
	$(COMPOSE) down

## Wejdź do działającego kontenera z shellem (przydatne do debugowania)
shell:
	$(COMPOSE) exec ansible bash

## Sprawdź połączenie z serwerem (ansible/playbooks/ping.yml)
ping:
	$(COMPOSE) exec ansible ansible-playbook playbooks/ping.yml

## Utwórz docelowego użytkownika (SERVER_USER_1) + klucz SSH + sudo (ansible/playbooks/create_user.yml)
create-user:
	$(COMPOSE) exec ansible ansible-playbook playbooks/create_user.yml

## Sprawdź, czy logowanie jako docelowy użytkownik (SERVER_USER_1) kluczem SSH działa (uruchom przed harden-ssh!)
verify-user:
	$(COMPOSE) exec ansible sh -c '\
		ssh -i /keys/$$SERVER_USER_1/id_ed25519 -o StrictHostKeyChecking=no -o BatchMode=yes $$SERVER_USER_1@$$SERVER_HOST_1 \
		"whoami && (sudo -n true 2>/dev/null && echo sudo:NOPASSWD || echo sudo:wymaga_hasla)"'

## Wyłącz logowanie root i hasłem przez SSH (ansible/playbooks/harden_ssh.yml)
## URUCHAMIAJ TYLKO po udanym `make verify-user` — patrz komentarz w pliku playbooka.
harden-ssh:
	$(COMPOSE) exec ansible ansible-playbook playbooks/harden_ssh.yml

## Zainstaluj Docker CE + zainicjuj Docker Swarm (ansible/playbooks/docker_swarm.yml)
## URUCHAMIAJ PRZED `make install-postgresql` (patrz komentarz w pliku playbooka).
install-docker-swarm:
	$(COMPOSE) exec ansible ansible-playbook playbooks/docker_swarm.yml

## Zainstaluj PostgreSQL natywnie + skonfiguruj dostęp dla Dockera/Swarm + user deploy (ansible/playbooks/postgresql.yml)
## WYMAGA wcześniejszego `make install-docker-swarm`.
install-postgresql:
	$(COMPOSE) exec ansible ansible-playbook playbooks/postgresql.yml

## Zapora ufw (SSH, 80/443, Swarm tylko z WG, WireGuard tylko od peerów, PostgreSQL z docker_gwbridge)
## + fail2ban na SSH (ansible/playbooks/firewall.yml). Najpierw reguła SSH, potem włączenie ufw.
install-firewall:
	$(COMPOSE) exec ansible ansible-playbook playbooks/firewall.yml

## Zainstaluj i skonfiguruj WireGuard wg0 (WG_ADDRESS_1 w .env), Docker startuje po wg0
## (ansible/playbooks/wireguard.yml). Wypisuje klucz publiczny węzła - potrzebny drugiej stronie tunelu.
install-wireguard:
	$(COMPOSE) exec ansible ansible-playbook playbooks/wireguard.yml

## Przenieś Docker Swarm na adres WireGuarda + etykiety węzła (SWARM_* w .env)
## (ansible/playbooks/swarm_wireguard.yml). Reset Swarma tylko na pustym, jednowęzłowym Swarmie.
## WYMAGA wcześniej `make install-wireguard`; po nim odpal ponownie `make install-postgresql`.
swarm-wireguard:
	$(COMPOSE) exec ansible ansible-playbook playbooks/swarm_wireguard.yml

## Dodaj nowego użytkownika (NEW_USER_* w .env) + zaimportuj klucz + zweryfikuj logowanie SSH (ansible/playbooks/add_user.yml)
## Przed uruchomieniem uzupełnij NEW_USER_* w .env i zrób `make up`, żeby domontować katalog z kluczem.
add-user:
	$(COMPOSE) exec ansible ansible-playbook playbooks/add_user.yml
