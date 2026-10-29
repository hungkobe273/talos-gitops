# Keycloak with the Quarkus build step done at image build time ("optimized" image).
# Without it, every container start runs `kc.sh build` again because the runtime config
# differs from the stock image: 5-12 min of CPU and HDD reads on this cluster, and on
# 29/10 the startup probe killed Keycloak before it finished.
#
# The build-time options below MUST match what platform/keycloak/values.yaml sets at
# runtime (KC_DB, KC_CACHE*, KC_HEALTH/METRICS*, KC_HTTP_RELATIVE_PATH). If they differ,
# `start --optimized` refuses to start and names the option, so a mismatch is loud.
# Bump the version in both FROM lines and in values.yaml together.
FROM quay.io/keycloak/keycloak:26.8.1 AS builder

ENV KC_DB=postgres \
    KC_CACHE=ispn \
    KC_CACHE_STACK=jdbc-ping \
    KC_HEALTH_ENABLED=true \
    KC_METRICS_ENABLED=true \
    KC_HTTP_METRICS_HISTOGRAMS_ENABLED=true \
    KC_HTTP_RELATIVE_PATH=/

RUN /opt/keycloak/bin/kc.sh build

FROM quay.io/keycloak/keycloak:26.8.1
COPY --from=builder /opt/keycloak/ /opt/keycloak/
