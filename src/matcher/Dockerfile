# Build stage: compile confluent-kafka against Alpine's librdkafka (no musl wheel is published).
FROM python:3.12-alpine AS build
RUN apk add --no-cache build-base librdkafka-dev
COPY src/matcher/requirements.txt /tmp/requirements.txt
RUN python -m venv /opt/venv && \
    /opt/venv/bin/pip install --no-cache-dir --upgrade pip && \
    /opt/venv/bin/pip install --no-cache-dir -r /tmp/requirements.txt

# Runtime stage: Alpine instead of Debian slim keeps the OS package set (and its CVEs) small.
FROM python:3.12-alpine
LABEL ewaste.component="matcher"
WORKDIR /app
RUN apk upgrade --no-cache && apk add --no-cache librdkafka && \
    pip uninstall -y pip setuptools wheel 2>/dev/null; true
COPY --from=build /opt/venv /opt/venv
COPY contracts/matching /app/contracts/matching
COPY src/matcher /app/src/matcher
ENV PATH=/opt/venv/bin:$PATH PYTHONPATH=/app/src/matcher PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
USER 65532:65532
CMD ["python", "-m", "matcher", "run"]
