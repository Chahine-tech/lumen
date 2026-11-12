#!/bin/sh
# GIT_ASKPASS helper: git calls it with its prompt as $1 ("Username for ..."
# or "Password for ..."). Credentials come from the environment, so they
# never appear in a URL, in .git/config or in a command line.
case "$1" in
  Username*) printf '%s\n' "$GITEA_USER" ;;
  *) printf '%s\n' "$GITEA_PASSWORD" ;;
esac
