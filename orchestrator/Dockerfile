FROM python:3.14-slim@sha256:cad9a2c871761c413caa6fdd6441c783451e740a48aaeba60ae62a8b53525ef6

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Non-root, minimal, no build tooling left behind.
RUN groupadd --gid 1000 staker \
 && useradd --uid 1000 --gid 1000 --create-home staker
WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir --no-compile -r requirements.txt

COPY staker.py .
COPY healthcheck.py .
# Explicit mode: COPY preserves the host file's perms (may be 0770), which the
# non-root (UID 1000) runtime user could not read.
RUN chmod 0555 /app/staker.py /app/healthcheck.py

USER 1000:1000
HEALTHCHECK --interval=1m --timeout=10s --start-period=5m --retries=3 \
  CMD ["python", "/app/healthcheck.py"]
ENTRYPOINT ["python", "-u", "staker.py"]
