FROM python:3.14-slim

ARG TRACY_VERSION=0.0.0.dev0

LABEL org.opencontainers.image.source="https://github.com/Malaber/tracy" \
      org.opencontainers.image.title="Tracy" \
      org.opencontainers.image.description="Self-hostable working-time tracker" \
      org.opencontainers.image.version="${TRACY_VERSION}"

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1
WORKDIR /app

RUN addgroup --system app && adduser --system --ingroup app app \
    && mkdir /data \
    && chown app:app /data

COPY pyproject.toml README.md ./
COPY app ./app
COPY alembic.ini ./
COPY alembic ./alembic

RUN SETUPTOOLS_SCM_PRETEND_VERSION=${TRACY_VERSION} pip install . \
    && printf '%s\n' "${TRACY_VERSION}" > VERSION \
    && chown -R app:app /app

USER app

EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=5 CMD python -c "from urllib.request import urlopen; urlopen('http://127.0.0.1:8000/health')"

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
