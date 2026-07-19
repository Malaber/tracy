# Tracy Webhooker bundle

This directory contains the Tracy-specific deployment files consumed by the external
[`malaber.webhooker`](https://github.com/Malaber/webhooker) Ansible collection.

The bundle provides:

- immutable `sha-<commit>` production deployments from `main`
- isolated `pr-<number>-<sha7>` review deployments
- SQLite persistence in a separate directory for each environment
- hostname-bound passkeys with secure session cookies
- Traefik routing for `tracy.malaber.de` and `pr-<number>.pr.tracy.malaber.de`

The hostnames are working defaults following Planini's deployment convention. Change them in the
project YAML and GitHub PR workflow if the final DNS names differ.

The consuming infrastructure repository should copy `compose.*.yml` and `env/*.env` to
`/srv/tracy/deploy`, render the two files under `config/` as Webhooker projects, and mount
`/srv/tracy` into the Webhooker worker container. See
[`docs/deployment/webhooker.md`](../../docs/deployment/webhooker.md) for the complete setup.
The worker environment must provide a stable `TRACY_SECRET_KEY` used by both Compose templates.
