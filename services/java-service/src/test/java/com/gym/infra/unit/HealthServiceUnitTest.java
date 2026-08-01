package com.gym.infra.unit;

import com.gym.infra.service.HealthService;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

public class HealthServiceUnitTest {

    @Test
    public void testGetInfo() {
        HealthService service = new HealthService("ms-gym-java-infra", "1.0.0");
        assertEquals("Service: ms-gym-java-infra, Version: 1.0.0", service.getInfo());
    }

    @Test
    public void testCheckHealthHealthy() {
        HealthService service = new HealthService("ms-gym-java-infra", "1.0.0");
        assertEquals("HEALTHY", service.checkHealth());
    }

    @Test
    public void testCheckHealthUnhealthy() {
        HealthService service = new HealthService("", "1.0.0");
        assertEquals("UNHEALTHY", service.checkHealth());

        HealthService nullService = new HealthService(null, "1.0.0");
        assertEquals("UNHEALTHY", nullService.checkHealth());
    }

    @Test
    public void testComputeMetricsSuccess() {
        HealthService service = new HealthService("ms-gym-java-infra", "1.0.0");
        assertEquals(20, service.computeMetrics(5, 4));
    }

    @Test
    public void testComputeMetricsException() {
        HealthService service = new HealthService("ms-gym-java-infra", "1.0.0");
        assertThrows(IllegalArgumentException.class, () -> service.computeMetrics(5, -1));
    }
}
