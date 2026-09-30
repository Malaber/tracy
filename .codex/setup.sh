#!/bin/sh
set -eu

# Native checks need only the task runner, not the web application's dependency graph.
case "${1:-}" in
  ""|--ios) ;;
  *) echo "Usage: $0 [--ios]" >&2; exit 2 ;;
esac

if [ ! -x .venv/bin/python ]; then
  python3.14 -m venv .venv
fi

if [ ! -x .venv/bin/inv ]; then
  env -u SSL_CERT_FILE -u REQUESTS_CA_BUNDLE .venv/bin/pip install --retries 0 invoke==3.0.3
fi

if [ "${1:-}" != "--ios" ]; then
  .venv/bin/inv install-deps
fi
