# Docker Compose deployment

The root [`docker-compose.yml`](../../docker-compose.yml) deploys the latest released multi-arch
image by default:

```bash
docker compose pull
docker compose up -d
```

Persistent data is stored in `./data`. Override the image when pinning a release or digest:

```bash
TRACY_IMAGE=ghcr.io/malaber/tracy:0.1.1 docker compose up -d
```

For reproducible production rollouts, prefer a version or digest. The `latest` default is intended
to make initial deployment and routine updates straightforward.
