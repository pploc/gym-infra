# syntax=docker/dockerfile:1.7
FROM golang:1.26.5-alpine AS build
WORKDIR /src
RUN apk add --no-cache git ca-certificates
ENV GOPRIVATE=github.com/pploc/*
COPY go.mod go.sum ./
RUN --mount=type=secret,id=github_token,required=true \
    sh -ec 'home=$(mktemp -d); export HOME="$home"; git config --global url."https://x-access-token:$(cat /run/secrets/github_token)@github.com/".insteadOf "https://github.com/"; go mod download; rm -rf "$home"'
COPY main.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /out/ms-gym-api-gateway ./main.go

FROM alpine:3.21
RUN adduser -D -u 65532 gateway
COPY --from=build /out/ms-gym-api-gateway /ms-gym-api-gateway
USER gateway
ENTRYPOINT ["/ms-gym-api-gateway"]
