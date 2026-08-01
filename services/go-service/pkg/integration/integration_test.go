package integration

import (
	"testing"

	"github.com/pploc/gym-infra/services/go-service/pkg/calculator"
)

func TestComponentIntegration(t *testing.T) {
	svc := calculator.NewService("ms-gym-go-infra", "1.0.0")

	// Integration test logic simulating workflow
	status, healthy := svc.HealthCheck()
	if !healthy || status != "healthy" {
		t.Fatalf("Component integration healthcheck failed: status=%s", status)
	}

	sum := svc.Add(100, 200)
	if sum != 300 {
		t.Fatalf("Component integration add failed: got %d", sum)
	}

	sub := svc.Subtract(sum, 50)
	if sub != 250 {
		t.Fatalf("Component integration subtract failed: got %d", sub)
	}

	mult := svc.Multiply(sub, 2)
	if mult != 500 {
		t.Fatalf("Component integration multiply failed: got %d", mult)
	}

	div, err := svc.Divide(float64(mult), 5)
	if err != nil || div != 100 {
		t.Fatalf("Component integration divide failed: got %f, err=%v", div, err)
	}
}
