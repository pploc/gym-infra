// Package main is the sample Go service entrypoint used by gym-infra CI.
package main

import (
	"fmt"

	"github.com/pploc/gym-infra/services/go-service/pkg/calculator"
)

func main() {
	svc := calculator.NewService("ms-gym-go-infra", "1.0.0")
	fmt.Println(svc.GetInfo())
	status, healthy := svc.HealthCheck()
	fmt.Printf("Status: %s (healthy: %v)\n", status, healthy)
}
