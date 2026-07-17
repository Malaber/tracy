#!/bin/sh
set -eu

if [ ! -x .venv/bin/python ]; then
  python3.14 -m venv .venv
fi

if [ ! -x .venv/bin/inv ]; then
  env -u SSL_CERT_FILE -u REQUESTS_CA_BUNDLE .venv/bin/pip install invoke
fi

.venv/bin/inv install-deps
