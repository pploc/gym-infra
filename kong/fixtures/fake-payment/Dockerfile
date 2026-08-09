FROM golang:1.26-bookworm AS build
WORKDIR /src
RUN apt-get update && apt-get install -y --no-install-recommends \
      gcc g++ pkg-config librdkafka-dev \
  && rm -rf /var/lib/apt/lists/*
COPY go.mod go.sum ./
COPY vendor/ vendor/
COPY main.go ./
# confluent-kafka-go schema registry imports kafka.LibraryVersion (needs CGO + librdkafka)
RUN CGO_ENABLED=1 go build -mod=vendor -o /out/fake-payment .

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates wget librdkafka1 \
  && rm -rf /var/lib/apt/lists/*
COPY --from=build /out/fake-payment /usr/local/bin/fake-payment
EXPOSE 50051 8080
ENTRYPOINT ["/usr/local/bin/fake-payment"]
