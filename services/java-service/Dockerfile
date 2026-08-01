FROM eclipse-temurin:26-jdk-alpine AS builder

WORKDIR /app
COPY build.gradle settings.gradle gradlew ./
COPY gradle/ gradle/
COPY src/ src/

RUN ./gradlew build --no-daemon -x test

FROM eclipse-temurin:26-jre-alpine
WORKDIR /app
COPY --from=builder /app/build/libs/*.jar app.jar

EXPOSE 8080 50051
ENTRYPOINT ["java", "-jar", "app.jar"]
