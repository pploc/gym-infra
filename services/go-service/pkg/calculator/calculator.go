// Package calculator is a tiny domain sample for gym-infra Go CI smoke tests.
package calculator

import (
	"errors"
	"fmt"
)

// Service provides mathematical and status operations for gym infrastructure services.
type Service struct {
	Name    string
	Version string
}

// NewService creates a new calculator Service.
func NewService(name, version string) *Service {
	return &Service{
		Name:    name,
		Version: version,
	}
}

// Add calculates the sum of two integers.
func (s *Service) Add(a, b int) int {
	return a + b
}

// Subtract calculates the difference of two integers.
func (s *Service) Subtract(a, b int) int {
	return a - b
}

// Multiply calculates the product of two integers.
func (s *Service) Multiply(a, b int) int {
	return a * b
}

// Divide calculates the quotient of two float64 numbers and handles division by zero.
func (s *Service) Divide(a, b float64) (float64, error) {
	if b == 0 {
		return 0, errors.New("cannot divide by zero")
	}
	return a / b, nil
}

// GetInfo returns service description string.
func (s *Service) GetInfo() string {
	return fmt.Sprintf("Service: %s, Version: %s", s.Name, s.Version)
}

// HealthCheck checks operational status.
func (s *Service) HealthCheck() (string, bool) {
	if s.Name == "" {
		return "unhealthy: missing name", false
	}
	return "healthy", true
}
