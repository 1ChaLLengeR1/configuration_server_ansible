COMPOSE := docker compose -f dockerfiles/docker-compose.yml --env-file .env

.PHONY: build up down shell ping logs

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

## Utwórz użytkownika artur + klucz SSH + sudo (ansible/playbooks/create_user.yml)
create-user:
	$(COMPOSE) exec ansible ansible-playbook playbooks/create_user.yml

## Sprawdź, czy logowanie jako artur kluczem SSH działa (uruchom przed harden-ssh!)
verify-artur:
	$(COMPOSE) exec ansible sh -c '\
		ssh -i /keys/artur/id_ed25519 -o StrictHostKeyChecking=no -o BatchMode=yes artur@$$SERVER_HOST_1 \
		"whoami && (sudo -n true 2>/dev/null && echo sudo:NOPASSWD || echo sudo:wymaga_hasla)"'

## Wyłącz logowanie root i hasłem przez SSH (ansible/playbooks/harden_ssh.yml)
## URUCHAMIAJ TYLKO po udanym `make verify-artur` — patrz komentarz w pliku playbooka.
harden-ssh:
	$(COMPOSE) exec ansible ansible-playbook playbooks/harden_ssh.yml
