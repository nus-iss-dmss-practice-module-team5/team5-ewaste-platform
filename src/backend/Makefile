COMPOSE_FILE ?= ../../docker-compose.yml
COMPOSE_ENV_FILE ?= ../../.env

COMPOSE = docker compose -f $(COMPOSE_FILE) --env-file $(COMPOSE_ENV_FILE)

.PHONY: test vet build check test-dependencies run-test docker-build docker-run docker-stop \
	compose-config compose-build compose-up compose-down compose-restart compose-ps compose-logs

test:
	go test ./...

vet:
	go vet ./...

build:
	go build ./cmd/server

check: test vet build

test-dependencies:
	go run ./cmd/server -mode test -check-dependencies

run-test:
	go run ./cmd/server -mode test

docker-build:
	docker build -t ewaste-workflow-api:test .

docker-run: docker-build
	docker run -d --name ewaste-api-test -p 8080:8080 ewaste-workflow-api:test

docker-stop:
	docker stop ewaste-api-test
	docker rm ewaste-api-test

compose-config:
	$(COMPOSE) config

compose-build:
	$(COMPOSE) build

compose-up: compose-config
	$(COMPOSE) up -d --build

compose-down:
	$(COMPOSE) down

compose-restart:
	$(COMPOSE) restart

compose-ps:
	$(COMPOSE) ps

compose-logs:
	$(COMPOSE) logs -f --tail=100
