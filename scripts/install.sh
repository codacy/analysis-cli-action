#!/usr/bin/env bash
# Installs @codacy/analysis-cli into a private prefix under RUNNER_TEMP and
# publishes the path of its executable as the `bin` step output.
#
# A prefix instead of `npm install -g`: a global install needs root on many
# self-hosted runners, and would leave the CLI on the caller's PATH for every
# later step of the job.
set -euo pipefail

version="${INPUT_CLI_VERSION:-latest}"
prefix="${RUNNER_TEMP:?RUNNER_TEMP is not set}/codacy-analysis-cli"

echo "::group::Installing @codacy/analysis-cli@${version}"
mkdir -p "$prefix"
npm install --prefix "$prefix" --no-audit --no-fund --loglevel=error "@codacy/analysis-cli@${version}"
bin="$prefix/node_modules/.bin/codacy-analysis"
"$bin" --version
echo "::endgroup::"

echo "bin=$bin" >> "$GITHUB_OUTPUT"
