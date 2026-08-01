package com.gym.infra.service;

public class HealthService {
    private final String serviceName;
    private final String version;

    public HealthService(String serviceName, String version) {
        this.serviceName = serviceName;
        this.version = version;
    }

    public String getInfo() {
        return "Service: " + serviceName + ", Version: " + version;
    }

    public String checkHealth() {
        if (serviceName == null || serviceName.isBlank()) {
            return "UNHEALTHY";
        }
        return "HEALTHY";
    }

    public int computeMetrics(int count, int multiplier) {
        if (multiplier < 0) {
            throw new IllegalArgumentException("Multiplier must be non-negative");
        }
        return count * multiplier;
    }
}
