COMPOSE_FILE ?= ../../docker-compose.yml
COMPOSE_ENV_FILE ?= ../../.env

COMPOSE = docker compose -f $(COMPOSE_FILE) --env-file $(COMPOSE_ENV_FILE)

.PHONY: test vet build check test-dependencies run-test docker-build docker-run docker-stop \
	compose-config compose-build compose-up compose-down compose-restart compose-ps compose-logs compose-seed-users

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

compose-init-test-schema: compose-up
	sed '/^[[:space:]]*--/d' ../../database/test/mysql/001-auth-schema.sql | \
		$(COMPOSE) exec -T mysql sh -c 'mysql -u"$$MYSQL_USER" -p"$$MYSQL_PASSWORD" "$$MYSQL_DATABASE"'

compose-seed-users: compose-init-test-schema
	sed -E '/^--(liquibase|changeset|comment|rollback)/d; s/^INSERT INTO users/INSERT IGNORE INTO users/' ../../database/liquibase/seed/103-seed-users.sql | \
		$(COMPOSE) exec -T mysql sh -c 'mysql -u"$$MYSQL_USER" -p"$$MYSQL_PASSWORD" "$$MYSQL_DATABASE"'
