FROM golang:1.22-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY main.go ./
RUN CGO_ENABLED=0 go build -o /mock-upstream .

FROM alpine:3.20
RUN apk add --no-cache wget
COPY --from=build /mock-upstream /usr/local/bin/mock-upstream
EXPOSE 8080
HEALTHCHECK --interval=2s --timeout=2s --retries=10 \
  CMD wget -q --spider http://127.0.0.1:8080/health || exit 1
ENTRYPOINT ["/usr/local/bin/mock-upstream"]
