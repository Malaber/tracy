# Webhooker deployment

Tracy follows Planini's integration with the external
[`malaber.webhooker`](https://github.com/Malaber/webhooker) Ansible collection.

## Included application bundle

[`deploy/webhooker/`](../../deploy/webhooker/README.md) contains the application-owned files:

- production and review Compose templates
- non-secret environment defaults
- production and review Webhooker project definitions

The Webhooker repository owns the generic API, worker, and Ansible role. A consuming infrastructure
repository copies Tracy's bundle to the server and renders the project definitions.

## Image and wake flow

1. CI tests a commit and publishes `ghcr.io/malaber/tracy:sha-<full-sha>` for amd64 and arm64.
2. A successful `main` CI run promotes that manifest to a version and `latest`, then creates the
   matching Git tag and GitHub Release.
3. The release sends a signed push payload to the production Webhooker endpoint.
4. Pull requests retag the tested commit as `pr-<number>-<sha7>` and send a signed pull-request
   payload to the review endpoint.

Wake steps safely skip when the repository settings are absent.

## GitHub repository settings

Configure these Actions variables:

- `WEBHOOKER_PRODUCTION_WAKE_URL`, for example `https://wake.example.com/github/tracy-production/wake`
- `WEBHOOKER_REVIEW_WAKE_URL`, for example `https://wake.example.com/github/tracy-pr-review/wake`

Configure this Actions secret:

- `WEBHOOKER_WEBHOOK_SECRET`, matching `GITHUB_WEBHOOK_SECRET` on the Webhooker host

## Host-side role shape

The infrastructure repository should use `malaber.webhooker.webhooker` with the following core
settings (paths can be adjusted to its inventory):

```yaml
webhooker_env:
  GITHUB_TOKEN: "{{ webhooker_github_token }}"
  GITHUB_WEBHOOK_SECRET: "{{ webhooker_github_webhook_secret }}"

webhooker_worker_extra_mounts:
  - /srv/tracy:/srv/tracy

webhooker_managed_directories:
  - path: /srv/tracy/data/production
    owner: "{{ webhooker_container_uid }}"
    group: "{{ webhooker_container_gid }}"
    mode: "0775"
  - path: /srv/tracy/data/reviews
    owner: "{{ webhooker_container_uid }}"
    group: "{{ webhooker_container_gid }}"
    mode: "0775"
```

Copy the Compose and common environment files into `/srv/tracy/deploy`, and render the contents of
`config/tracy-production.yaml` and `config/tracy-review.yaml` through `webhooker_projects`.

Production defaults to `tracy.malaber.de`; review deployments use
`pr-<number>.pr.tracy.malaber.de`. Update the project files and PR workflow together if DNS differs.

Authentication is not present in Tracy yet. Do not expose a production or review deployment to an
untrusted network until the shared authentication layer is integrated.
