.PHONY: test vet build check test-dependencies run-test docker-build docker-run docker-stop

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
