# syntax=docker/dockerfile:1.7
FROM golang:1.26-bookworm AS build
WORKDIR /src
RUN apt-get update && apt-get install -y --no-install-recommends \
      gcc g++ pkg-config librdkafka-dev git ca-certificates \
  && rm -rf /var/lib/apt/lists/*
ENV GOPRIVATE=github.com/pploc/*
COPY go.mod go.sum ./
RUN --mount=type=secret,id=github_token,required=true \
    sh -ec 'home=$(mktemp -d); export HOME="$home"; git config --global url."https://x-access-token:$(cat /run/secrets/github_token)@github.com/".insteadOf "https://github.com/"; go mod download; rm -rf "$home"'
COPY main.go ./
# confluent-kafka-go schema registry imports kafka.LibraryVersion (needs CGO + librdkafka)
RUN CGO_ENABLED=1 go build -o /out/fake-payment .

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates wget librdkafka1 \
  && rm -rf /var/lib/apt/lists/*
COPY --from=build /out/fake-payment /usr/local/bin/fake-payment
EXPOSE 50051 8080
ENTRYPOINT ["/usr/local/bin/fake-payment"]
