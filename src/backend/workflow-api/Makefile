.PHONY: test vet build check docker-build docker-run docker-test

test:
	go test ./...

vet:
	go vet ./...

build:
	go build ./cmd/server

check: test vet build

docker-build:
	docker build -t ewaste-workflow-api:test .

docker-run: docker-build
	docker run -d --name ewaste-api-test -p 8080:8080 ewaste-workflow-api:test

docker-stop:
	docker stop ewaste-api-test
	docker rm ewaste-api-test