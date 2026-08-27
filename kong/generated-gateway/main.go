package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/grpc-ecosystem/grpc-gateway/v2/runtime"
	checkinv1 "github.com/pploc/proto-go/checkin/v1"
	memberv1 "github.com/pploc/proto-go/member/v1"
	plansv1 "github.com/pploc/proto-go/plans/v1"
	trainerv1 "github.com/pploc/proto-go/trainer/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
)

const (
	headerUserID    = "x-user-id"
	headerUserRole  = "x-user-role"
	headerError     = "x-error-code"
	upstreamTimeout = 5 * time.Second
)

var kongSANs = map[string]struct{}{
	"kong": {},
	"spiffe://gym.cluster.local/ns/default/sa/kong":    {},
	"spiffe://gym.cluster.local/ns/gym-system/sa/kong": {},
}

type config struct {
	httpsAddr   string
	serverCert  string
	serverKey   string
	clientCA    string
	gatewayCert string
	gatewayKey  string
	memberAddr  string
	memberCA    string
	plansAddr   string
	plansCA     string
	checkinAddr string
	checkinCA   string
	trainerAddr string
	trainerCA   string
}

func main() {
	cfg, err := loadConfig()
	if err != nil {
		log.Fatal(err)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	handler, closeConnections, err := newHandler(ctx, cfg)
	if err != nil {
		log.Fatal(err)
	}
	defer closeConnections()

	tlsConfig, err := inboundTLSConfig(cfg)
	if err != nil {
		log.Fatal(err)
	}
	server := &http.Server{
		Addr:              cfg.httpsAddr,
		Handler:           http.TimeoutHandler(handler, 5*time.Second, "Upstream service unavailable\n"),
		TLSConfig:         tlsConfig,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      upstreamTimeout,
		IdleTimeout:       60 * time.Second,
	}
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = server.Shutdown(shutdownCtx)
	}()

	log.Printf("generated grpc-gateway listening on %s", cfg.httpsAddr)
	if err := server.ListenAndServeTLS("", ""); !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}

func newHandler(ctx context.Context, cfg config) (http.Handler, func(), error) {
	memberConn, err := dial(ctx, cfg.memberAddr, "ms-gym-member", cfg.memberCA, cfg.gatewayCert, cfg.gatewayKey)
	if err != nil {
		return nil, nil, fmt.Errorf("dial Member: %w", err)
	}
	plansConn, err := dial(ctx, cfg.plansAddr, "ms-gym-plans", cfg.plansCA, cfg.gatewayCert, cfg.gatewayKey)
	if err != nil {
		_ = memberConn.Close()
		return nil, nil, fmt.Errorf("dial Plans: %w", err)
	}
	checkinConn, err := dial(ctx, cfg.checkinAddr, "ms-gym-checkin", cfg.checkinCA, cfg.gatewayCert, cfg.gatewayKey)
	if err != nil {
		_ = memberConn.Close()
		_ = plansConn.Close()
		return nil, nil, fmt.Errorf("dial Check-in: %w", err)
	}
	trainerConn, err := dial(ctx, cfg.trainerAddr, "ms-gym-trainer", cfg.trainerCA, cfg.gatewayCert, cfg.gatewayKey)
	if err != nil {
		_ = memberConn.Close()
		_ = plansConn.Close()
		_ = checkinConn.Close()
		return nil, nil, fmt.Errorf("dial Trainer: %w", err)
	}
	closeConnections := func() {
		_ = memberConn.Close()
		_ = plansConn.Close()
		_ = checkinConn.Close()
		_ = trainerConn.Close()
	}
	mux := runtime.NewServeMux(
		runtime.WithIncomingHeaderMatcher(rejectIncomingHeader),
		runtime.WithMetadata(outgoingMetadata),
		runtime.WithErrorHandler(promoteErrorCode),
	)
	if err := memberv1.RegisterMemberServiceHandler(ctx, mux, memberConn); err != nil {
		closeConnections()
		return nil, nil, fmt.Errorf("register Member: %w", err)
	}
	if err := plansv1.RegisterPlansServiceHandler(ctx, mux, plansConn); err != nil {
		closeConnections()
		return nil, nil, fmt.Errorf("register Plans: %w", err)
	}
	if err := checkinv1.RegisterCheckInServiceHandler(ctx, mux, checkinConn); err != nil {
		closeConnections()
		return nil, nil, fmt.Errorf("register Check-in: %w", err)
	}
	if err := trainerv1.RegisterTrainerServiceHandler(ctx, mux, trainerConn); err != nil {
		closeConnections()
		return nil, nil, fmt.Errorf("register Trainer: %w", err)
	}
	return mux, closeConnections, nil
}

func loadConfig() (config, error) {
	cfg := config{
		httpsAddr:   requiredEnv("HTTPS_ADDR"),
		serverCert:  requiredEnv("TLS_SERVER_CERT"),
		serverKey:   requiredEnv("TLS_SERVER_KEY"),
		clientCA:    requiredEnv("TLS_CLIENT_CA"),
		gatewayCert: requiredEnv("TLS_CLIENT_CERT"),
		gatewayKey:  requiredEnv("TLS_CLIENT_KEY"),
		memberAddr:  requiredEnv("MEMBER_GRPC_ADDR"),
		memberCA:    requiredEnv("MEMBER_GRPC_SERVER_CA"),
		plansAddr:   requiredEnv("PLANS_GRPC_ADDR"),
		plansCA:     requiredEnv("PLANS_GRPC_SERVER_CA"),
		checkinAddr: requiredEnv("CHECKIN_GRPC_ADDR"),
		checkinCA:   requiredEnv("CHECKIN_GRPC_SERVER_CA"),
	}
	if cfg.httpsAddr == "" {
		cfg.httpsAddr = ":8443"
	}
	for name, value := range map[string]string{
		"TLS_SERVER_CERT": cfg.serverCert, "TLS_SERVER_KEY": cfg.serverKey,
		"TLS_CLIENT_CA": cfg.clientCA, "TLS_CLIENT_CERT": cfg.gatewayCert,
		"TLS_CLIENT_KEY": cfg.gatewayKey, "MEMBER_GRPC_ADDR": cfg.memberAddr,
		"MEMBER_GRPC_SERVER_CA": cfg.memberCA, "PLANS_GRPC_ADDR": cfg.plansAddr,
		"PLANS_GRPC_SERVER_CA": cfg.plansCA, "CHECKIN_GRPC_ADDR": cfg.checkinAddr,
		"CHECKIN_GRPC_SERVER_CA": cfg.checkinCA, "TRAINER_GRPC_ADDR": cfg.trainerAddr,
		"TRAINER_GRPC_SERVER_CA": cfg.trainerCA,
	} {
		if value == "" {
			return config{}, fmt.Errorf("%s is required", name)
		}
	}
	return cfg, nil
}

func requiredEnv(name string) string { return os.Getenv(name) }

func dial(ctx context.Context, address, serverName, caPath, certPath, keyPath string) (*grpc.ClientConn, error) {
	tlsConfig, err := clientTLSConfig(serverName, caPath, certPath, keyPath)
	if err != nil {
		return nil, err
	}
	dialCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	return grpc.DialContext(dialCtx, address, grpc.WithBlock(), grpc.WithTransportCredentials(credentials.NewTLS(tlsConfig)))
}

func inboundTLSConfig(cfg config) (*tls.Config, error) {
	certificate, err := tls.LoadX509KeyPair(cfg.serverCert, cfg.serverKey)
	if err != nil {
		return nil, fmt.Errorf("load gateway server certificate: %w", err)
	}
	pool, err := certPool(cfg.clientCA)
	if err != nil {
		return nil, err
	}
	return &tls.Config{
		MinVersion:   tls.VersionTLS12,
		Certificates: []tls.Certificate{certificate},
		ClientAuth:   tls.RequireAndVerifyClientCert,
		ClientCAs:    pool,
		VerifyConnection: func(state tls.ConnectionState) error {
			if len(state.PeerCertificates) == 0 || !hasAllowedSAN(state.PeerCertificates[0], kongSANs) {
				return errors.New("Kong client certificate is required")
			}
			return nil
		},
	}, nil
}

func clientTLSConfig(serverName, caPath, certPath, keyPath string) (*tls.Config, error) {
	certificate, err := tls.LoadX509KeyPair(certPath, keyPath)
	if err != nil {
		return nil, fmt.Errorf("load gateway client certificate: %w", err)
	}
	pool, err := certPool(caPath)
	if err != nil {
		return nil, err
	}
	return &tls.Config{
		MinVersion:   tls.VersionTLS12,
		ServerName:   serverName,
		RootCAs:      pool,
		Certificates: []tls.Certificate{certificate},
	}, nil
}

func certPool(path string) (*x509.CertPool, error) {
	pem, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read certificate authority %s: %w", path, err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(pem) {
		return nil, fmt.Errorf("parse certificate authority %s", path)
	}
	return pool, nil
}

func hasAllowedSAN(cert *x509.Certificate, allowed map[string]struct{}) bool {
	for _, name := range cert.DNSNames {
		if _, ok := allowed[name]; ok {
			return true
		}
	}
	for _, uri := range cert.URIs {
		if _, ok := allowed[uri.String()]; ok {
			return true
		}
	}
	return false
}

func rejectIncomingHeader(string) (string, bool) { return "", false }

func outgoingMetadata(_ context.Context, request *http.Request) metadata.MD {
	md := metadata.MD{}
	for _, header := range []string{headerUserID, headerUserRole, "traceparent", "tracestate"} {
		if value, ok := oneHeaderValue(request, header); ok {
			md.Set(header, value)
		}
	}
	return md
}

func oneHeaderValue(request *http.Request, name string) (string, bool) {
	values := request.Header.Values(name)
	if len(values) != 1 {
		return "", false
	}
	value := strings.TrimSpace(values[0])
	return value, value != ""
}

func promoteErrorCode(ctx context.Context, mux *runtime.ServeMux, marshaler runtime.Marshaler, writer http.ResponseWriter, request *http.Request, err error) {
	if serverMetadata, ok := runtime.ServerMetadataFromContext(ctx); ok {
		if values := serverMetadata.TrailerMD.Get(headerError); len(values) == 1 && validHeaderValue(values[0]) {
			writer.Header().Set(headerError, values[0])
		}
	}
	if status.Code(err) == codes.DeadlineExceeded || status.Code(err) == codes.Unavailable {
		err = status.Error(codes.Unavailable, "Upstream service unavailable")
	}
	runtime.DefaultHTTPErrorHandler(ctx, mux, marshaler, writer, request, err)
}

func validHeaderValue(value string) bool {
	return value != "" && !strings.ContainsAny(value, "\r\n")
}
