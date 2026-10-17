FROM golang:1.26-alpine AS builder

WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download

COPY . .

RUN CGO_ENABLED=0 GOOS=linux \
    go build -trimpath -ldflags="-s -w" \
    -o /out/server ./cmd/server

FROM alpine:3.20
RUN apk add --no-cache ca-certificates
RUN addgroup -S app && adduser -S app -G app

WORKDIR /app
COPY --from=builder /out/server ./server
COPY --from=builder /src/config.yaml ./config.yaml
ENV EWASTE_CONFIG_FILE=/app/config.yaml
RUN mkdir -p /app/logs && chown -R app:app /app

USER app

EXPOSE 8080

ENTRYPOINT ["/app/server"]
