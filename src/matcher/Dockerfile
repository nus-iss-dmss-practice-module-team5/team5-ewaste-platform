FROM python:3.12.12-slim
LABEL ewaste.component="matcher"
WORKDIR /app
COPY src/matcher/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt
COPY contracts/matching /app/contracts/matching
COPY src/matcher /app/src/matcher
ENV PYTHONPATH=/app/src/matcher PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
USER 65532:65532
CMD ["python", "-m", "matcher", "run"]
