.PHONY: help up dev prod down logs ps config config-prod build build-base rebuild pull clean backup

BASE := compose.yaml
DEV  := compose.override.yaml
PROD := compose.prod.yaml

help:               ## show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

up: dev             ## alias for `make dev`

build-base:         ## build iris:local base image (parent of iris-bridge)
	docker build -t iris:local hermes-agent

build: build-base   ## build all images (base first, then bridge + claude-cli + honcho)
	docker compose build

dev: build          ## build (if needed) + start dev stack
	docker compose up -d

prod: build         ## build + start prod stack (with hardening)
	docker compose -f $(BASE) -f $(PROD) up -d

down:               ## stop everything (volumes preserved)
	docker compose down

logs:               ## tail logs; pass SERVICE=name to filter
	docker compose logs -f $(SERVICE)

ps:                 ## show running containers
	docker compose ps

config:             ## preview merged dev config
	docker compose config

config-prod:        ## preview merged prod config
	docker compose -f $(BASE) -f $(PROD) config

rebuild:            ## rebuild local images (Iris, Honcho)
	docker compose build --no-cache iris-gateway honcho-api

pull:               ## pull updated upstream images
	docker compose pull litellm litellm-db prometheus honcho-db honcho-redis

backup:             ## dump databases and iris_data to ./backups/
	@bash scripts/backup.sh

clean:              ## stop + remove volumes (DESTROYS data)
	@read -p "Type DELETE to confirm volume deletion: " confirm && [ "$$confirm" = "DELETE" ] && docker compose down -v
