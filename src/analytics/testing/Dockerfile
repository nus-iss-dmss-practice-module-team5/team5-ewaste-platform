FROM python:3.12.12-slim
WORKDIR /app
COPY src/analytics/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt PyMySQL==1.1.2
COPY contracts/matching /app/contracts/matching
COPY src/analytics /app/src/analytics
ENV PYTHONPATH=/app/src/analytics PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
USER 65532:65532
CMD ["python", "-m", "unittest", "discover", "-s", "src/analytics/tests", "-v"]
