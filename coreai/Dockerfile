# Tragar Core AI sidecar. Add your model + its deps here; weights belong in the
# mounted /models volume (compose), not baked into the image.
FROM python:3.12-slim

# curl is used by the container healthcheck (docker-compose).
RUN apt-get update \
  && apt-get install -y --no-install-recommends curl \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /srv

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

ENV MODEL_DIR=/models
EXPOSE 8080

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080"]
