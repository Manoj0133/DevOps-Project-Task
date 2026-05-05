COMPOSE ?= docker compose
APP_PORT ?= 8000
SHELL := /bin/bash

.PHONY: bootstrap build up up-prod monitor down logs test clean shell

bootstrap:
	@if [ ! -f .env ]; then cp .env.example .env; echo "Created .env from .env.example"; else echo ".env already exists"; fi
	@python3 -m py_compile app/main.py
	@bash -n scripts/deploy.sh scripts/backup.sh scripts/health-monitor.sh tests/test_integration.sh
	@$(COMPOSE) config --quiet
	@echo "Bootstrap checks passed."
	@echo "Next: cd terraform && terraform init && terraform validate"

build:
	$(COMPOSE) build app

up:
	$(COMPOSE) up -d --build app db redis

up-prod:
	COMPOSE_PROFILES=prod $(COMPOSE) up -d db redis app_blue caddy

monitor:
	COMPOSE_PROFILES=monitoring $(COMPOSE) up -d uptime-kuma

down:
	$(COMPOSE) down

logs:
	$(COMPOSE) logs -f --tail=200

test:
	RESULTS_FILE=/tmp/statuspulse-test-results.txt bash tests/test_integration.sh

clean:
	$(COMPOSE) down -v --rmi all --remove-orphans

shell:
	$(COMPOSE) exec app bash
