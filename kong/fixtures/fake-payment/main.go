package main

import (
	"context"
	"encoding/json"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	commonkafka "github.com/pploc/common-go/kafka"
	eventsv1 "github.com/pploc/proto-go/events/v1"
	paymentv1 "github.com/pploc/proto-go/v3/payment/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// Phase-8-only fake Payment: InitiatePayment + correlated completion publish/replay.
// Not a production payment service.

type paymentRecord struct {
	PaymentID   string
	UserID      string
	GymID       string
	ReferenceID string
	AmountVnd   int64
	Provider    string
	PaymentType string
	EventID     string
}

type server struct {
	paymentv1.UnimplementedPaymentServiceServer
	mu       sync.Mutex
	byID     map[string]*paymentRecord
	byRef    map[string]*paymentRecord
	seq      int
	producer commonkafka.Producer
}

func main() {
	brokers := env("KAFKA_BROKERS", "kafka:29092")
	schemaURL := env("SCHEMA_REGISTRY_URL", "http://schema-registry:8081")
	grpcAddr := env("GRPC_ADDR", ":50051")
	httpAddr := env("HTTP_ADDR", ":8080")

	registry, err := commonkafka.NewConfluentProtobufRegistry(commonkafka.RegistryConfig{URL: schemaURL})
	if err != nil {
		log.Fatalf("schema registry: %v", err)
	}
	producer, err := commonkafka.NewFranzProducer(commonkafka.TransportConfig{
		Brokers:        strings.Split(brokers, ","),
		PublishTimeout: 5 * time.Second,
	}, registry)
	if err != nil {
		log.Fatalf("kafka producer: %v", err)
	}
	defer producer.Close()

	svc := &server{
		byID:     map[string]*paymentRecord{},
		byRef:    map[string]*paymentRecord{},
		producer: producer,
	}

	lis, err := net.Listen("tcp", grpcAddr)
	if err != nil {
		log.Fatalf("listen grpc: %v", err)
	}
	grpcServer := grpc.NewServer()
	paymentv1.RegisterPaymentServiceServer(grpcServer, svc)
	go func() {
		log.Printf("fake-payment gRPC on %s", grpcAddr)
		if err := grpcServer.Serve(lis); err != nil {
			log.Fatalf("grpc serve: %v", err)
		}
	}()

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})
	mux.HandleFunc("/complete", svc.handleComplete)
	mux.HandleFunc("/replay", svc.handleComplete) // same path semantics: republish stable event-id
	log.Printf("fake-payment HTTP on %s", httpAddr)
	log.Fatal(http.ListenAndServe(httpAddr, mux))
}

func (s *server) InitiatePayment(_ context.Context, req *paymentv1.InitiatePaymentRequest) (*paymentv1.InitiatePaymentResponse, error) {
	if strings.TrimSpace(req.GetReferenceId()) == "" {
		return nil, status.Error(codes.InvalidArgument, "reference_id required")
	}
	if strings.TrimSpace(req.GetUserId()) == "" {
		return nil, status.Error(codes.InvalidArgument, "user_id required")
	}
	if req.GetAmountVnd() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "amount_vnd required")
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	if existing := s.byRef[req.GetReferenceId()]; existing != nil {
		return &paymentv1.InitiatePaymentResponse{
			PaymentId:  existing.PaymentID,
			PaymentUrl: "http://fake-payment/pay/" + existing.PaymentID,
		}, nil
	}
	s.seq++
	id := "pay-g8-" + itoa(s.seq)
	rec := &paymentRecord{
		PaymentID:   id,
		UserID:      req.GetUserId(),
		GymID:       req.GetGymId(),
		ReferenceID: req.GetReferenceId(),
		AmountVnd:   req.GetAmountVnd(),
		Provider:    req.GetProvider(),
		PaymentType: req.GetPaymentType(),
		EventID:     "evt-" + id,
	}
	s.byID[id] = rec
	s.byRef[rec.ReferenceID] = rec
	return &paymentv1.InitiatePaymentResponse{
		PaymentId:  id,
		PaymentUrl: "http://fake-payment/pay/" + id,
	}, nil
}

type completeBody struct {
	PaymentID   string `json:"payment_id"`
	ReferenceID string `json:"reference_id"`
}

func (s *server) handleComplete(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST required", http.StatusMethodNotAllowed)
		return
	}
	var body completeBody
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "invalid json", http.StatusBadRequest)
		return
	}
	s.mu.Lock()
	var rec *paymentRecord
	if body.PaymentID != "" {
		rec = s.byID[body.PaymentID]
	} else if body.ReferenceID != "" {
		rec = s.byRef[body.ReferenceID]
	}
	s.mu.Unlock()
	if rec == nil {
		http.Error(w, "payment not found", http.StatusNotFound)
		return
	}
	if err := s.publish(r.Context(), rec); err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]string{
		"payment_id":   rec.PaymentID,
		"reference_id": rec.ReferenceID,
		"event_id":     rec.EventID,
		"status":       "published",
	})
}

func (s *server) publish(ctx context.Context, rec *paymentRecord) error {
	payload := &eventsv1.PaymentCompletedEvent{
		PaymentId:   rec.PaymentID,
		UserId:      rec.UserID,
		Type:        firstNonEmpty(rec.PaymentType, "MEMBERSHIP"),
		ReferenceId: rec.ReferenceID,
		AmountVnd:   rec.AmountVnd,
		Provider:    rec.Provider,
		GymId:       rec.GymID,
		Timestamp:   time.Now().UTC().UnixMilli(),
	}
	return s.producer.Publish(ctx, commonkafka.Event{
		Topic:   "payment.completed.v1",
		Key:     []byte(rec.UserID),
		Payload: payload,
		EventID: rec.EventID,
		Source:  "fake-payment",
	})
}

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func firstNonEmpty(v, def string) string {
	if strings.TrimSpace(v) == "" {
		return def
	}
	return v
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b [12]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	return string(b[i:])
}
