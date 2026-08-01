package calculator

import (
	"testing"
)

func TestNewService(t *testing.T) {
	svc := NewService("GymGoService", "1.0.0")
	if svc.Name != "GymGoService" || svc.Version != "1.0.0" {
		t.Fatalf("expected GymGoService 1.0.0, got %s %s", svc.Name, svc.Version)
	}
}

func TestAdd(t *testing.T) {
	svc := NewService("GymGoService", "1.0.0")
	result := svc.Add(10, 5)
	if result != 15 {
		t.Errorf("expected 15, got %d", result)
	}
}

func TestSubtract(t *testing.T) {
	svc := NewService("GymGoService", "1.0.0")
	result := svc.Subtract(10, 4)
	if result != 6 {
		t.Errorf("expected 6, got %d", result)
	}
}

func TestMultiply(t *testing.T) {
	svc := NewService("GymGoService", "1.0.0")
	result := svc.Multiply(3, 4)
	if result != 12 {
		t.Errorf("expected 12, got %d", result)
	}
}

func TestDivide(t *testing.T) {
	svc := NewService("GymGoService", "1.0.0")

	val, err := svc.Divide(10.0, 2.0)
	if err != nil || val != 5.0 {
		t.Errorf("expected 5.0, got %f with err %v", val, err)
	}

	_, errZero := svc.Divide(10.0, 0)
	if errZero == nil {
		t.Errorf("expected division by zero error")
	}
}

func TestGetInfo(t *testing.T) {
	svc := NewService("GymGoService", "1.0.0")
	info := svc.GetInfo()
	expected := "Service: GymGoService, Version: 1.0.0"
	if info != expected {
		t.Errorf("expected %s, got %s", expected, info)
	}
}

func TestHealthCheck(t *testing.T) {
	svc := NewService("GymGoService", "1.0.0")
	status, ok := svc.HealthCheck()
	if !ok || status != "healthy" {
		t.Errorf("expected healthy, got %s (%v)", status, ok)
	}

	emptySvc := NewService("", "1.0.0")
	unhealthyStatus, healthyOk := emptySvc.HealthCheck()
	if healthyOk || unhealthyStatus != "unhealthy: missing name" {
		t.Errorf("expected unhealthy: missing name, got %s (%v)", unhealthyStatus, healthyOk)
	}
}
