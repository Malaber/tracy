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

## Passkey configuration

WebAuthn binds passkeys to an exact HTTPS origin and relying-party domain. For any deployment other
than local `localhost`, create a `.env` file next to the Compose file:

```dotenv
APP_BASE_URL=https://tracy.example.com
WEBAUTHN_RP_ID=tracy.example.com
SECRET_KEY=<at-least-32-random-bytes>
SECURE_COOKIES=true
```

Generate a secret with `openssl rand -hex 32`. Keep `SECRET_KEY` stable across restarts: changing it
signs everyone out. Keep `WEBAUTHN_RP_ID` stable after account creation: changing it prevents
existing passkeys from authenticating. HTTPS is required by WebAuthn outside `localhost`.

When upgrading an installation with existing unowned records, Tracy assigns those records to the
first passkey account created. Later accounts receive isolated preferences and work entries.
