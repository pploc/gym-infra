module github.com/pploc/gym-infra/kong/generated-gateway

go 1.26.5

require (
	github.com/grpc-ecosystem/grpc-gateway/v2 v2.18.1
	github.com/pploc/proto-go v0.0.0
	google.golang.org/grpc v1.71.0
)

require (
	buf.build/gen/go/bufbuild/protovalidate/protocolbuffers/go v1.36.12-20260709200747-435963d16310.1 // indirect
	github.com/google/gnostic v0.7.1 // indirect
	github.com/google/gnostic-models v0.7.0 // indirect
	github.com/kr/text v0.2.0 // indirect
	github.com/rogpeppe/go-internal v1.16.0 // indirect
	go.yaml.in/yaml/v3 v3.0.4 // indirect
	golang.org/x/net v0.43.0 // indirect
	golang.org/x/sys v0.35.0 // indirect
	golang.org/x/text v0.28.0 // indirect
	google.golang.org/genproto/googleapis/api v0.0.0-20250811160224-6b04f9b4fc78 // indirect
	google.golang.org/genproto/googleapis/rpc v0.0.0-20250811160224-6b04f9b4fc78 // indirect
	google.golang.org/protobuf v1.36.12 // indirect
)

replace github.com/pploc/proto-go => ./proto-go
