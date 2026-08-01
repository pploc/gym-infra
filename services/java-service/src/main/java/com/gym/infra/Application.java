package com.gym.infra;

import com.gym.infra.service.HealthService;

public class Application {
    public static void main(String[] args) {
        HealthService service = new HealthService("ms-gym-java-infra", "1.0.0");
        System.out.println(service.getInfo());
        System.out.println("Health status: " + service.checkHealth());
    }
}
