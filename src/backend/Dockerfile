FROM golang:1.26-alpine AS builder

WORKDIR /src

COPY go.mod ./
RUN go mod download

COPY . .

RUN CGO_ENABLED=0 GOOS=linux \
    go build -trimpath -ldflags="-s -w" \
    -o /out/server ./cmd/server

FROM alpine:3.20
RUN addgroup -S app && adduser -S app -G app

WORKDIR /app
COPY --from=builder /out/server ./server

USER app

EXPOSE 8080

ENTRYPOINT ["/app/server"]