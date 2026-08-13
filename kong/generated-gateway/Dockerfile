FROM golang:1.26.5-alpine AS build
WORKDIR /src
COPY proto-go ./proto-go
RUN cd proto-go && go mod tidy
COPY go.mod ./
COPY main.go ./
RUN go mod tidy && CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /out/ms-gym-api-gateway ./main.go

FROM alpine:3.21
RUN adduser -D -u 65532 gateway
COPY --from=build /out/ms-gym-api-gateway /ms-gym-api-gateway
USER gateway
ENTRYPOINT ["/ms-gym-api-gateway"]
