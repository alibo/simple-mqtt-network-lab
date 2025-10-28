FROM gradle:8.10-jdk17 AS build
WORKDIR /src
COPY build.gradle settings.gradle ./
RUN gradle --no-daemon dependencies
COPY src ./src
RUN gradle --no-daemon installDist

FROM openjdk:17-jdk-slim
WORKDIR /app
COPY --from=build /src/build/install/java-client/ /app/
ENV CLIENT_CONFIG=/app/configs/client.yaml
EXPOSE 6061
CMD ["/app/bin/java-client"]
