package com.gym.infra.integration;

import com.gym.infra.Application;
import com.gym.infra.service.HealthService;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;

public class ApplicationIntegrationTest {

    @Test
    public void testFullApplicationFlow() {
        assertDoesNotThrow(() -> Application.main(new String[]{}));
        Application app = new Application();
        assertNotNull(app);
    }

    @Test
    public void testIntegrationServiceCalculation() {
        HealthService service = new HealthService("ms-gym-java-infra", "1.0.0");
        String info = service.getInfo();
        String health = service.checkHealth();
        int metrics = service.computeMetrics(10, 10);

        assertEquals("Service: ms-gym-java-infra, Version: 1.0.0", info);
        assertEquals("HEALTHY", health);
        assertEquals(100, metrics);
    }
}
