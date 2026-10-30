#!/usr/bin/env bash
# Runs the Codacy Analysis CLI for the action: resolves the configuration,
# analyzes, writes the report and optionally uploads it.
#
# Issues never fail the step, only a failed analysis or upload does. Counting
# every issue in the analyzed files cannot tell a PR's new issues from old ones;
# gating on new issues is Codacy's pull request quality gate.
#
# Every input arrives as an INPUT_* environment variable (see action.yml).
# Written for bash 3.2, the oldest bash a macOS runner may resolve: no
# ${var,,}, no mapfile, and empty arrays expanded with ${a[@]+"${a[@]}"}.
set -euo pipefail

cli="${CODACY_ANALYSIS_BIN:?CODACY_ANALYSIS_BIN is not set}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Prints an error annotation and exits with the given code. The message often
# quotes an input, so it is escaped as GitHub requires for workflow commands:
# an unescaped newline would let an input value start a command of its own.
die() {
  local message="$2"
  message="${message//%/%25}"
  message="${message//$'\r'/%0D}"
  message="${message//$'\n'/%0A}"
  echo "::error title=Codacy Analysis CLI::$message"
  exit "$1"
}

# True for the spellings of "true" a workflow author is likely to write.
is_true() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    true | yes | 1) return 0 ;;
    *) return 1 ;;
  esac
}

# --- Credentials ---------------------------------------------------------------
# The CLI reads tokens from the environment, which keeps them out of argv (and
# so out of process listings). A token already exported by the job is honored
# when the matching input is empty.
if [ -n "${INPUT_PROJECT_TOKEN:-}" ]; then export CODACY_PROJECT_TOKEN="$INPUT_PROJECT_TOKEN"; fi
if [ -n "${INPUT_API_TOKEN:-}" ]; then export CODACY_API_TOKEN="$INPUT_API_TOKEN"; fi
if [ -n "${INPUT_CODACY_API_BASE_URL:-}" ]; then export CODACY_API_BASE_URL="$INPUT_CODACY_API_BASE_URL"; fi
if [ -n "${INPUT_CODACY_RESULTS_API_BASE_URL:-}" ]; then
  export CODACY_RESULTS_API_BASE_URL="$INPUT_CODACY_RESULTS_API_BASE_URL"
fi

has_project_token=false
has_token=false
if [ -n "${CODACY_PROJECT_TOKEN:-}" ]; then has_project_token=true; has_token=true; fi
if [ -n "${CODACY_API_TOKEN:-}" ]; then has_token=true; fi

# Repository coordinates, needed by `init --remote` in both token modes and by
# `upload` in account-token mode. Default to the repository running the workflow.
provider="${INPUT_PROVIDER:-}"
if [ -z "$provider" ]; then
  if [ "${GITHUB_SERVER_URL:-https://github.com}" = "https://github.com" ]; then provider=gh; else provider=ghe; fi
fi
owner="${INPUT_OWNER:-${GITHUB_REPOSITORY_OWNER:-}}"
repository="${INPUT_REPOSITORY:-${GITHUB_REPOSITORY#*/}}"

# --- Input validation ----------------------------------------------------------
# Everything checkable up front is checked before the analysis, so a typo in the
# workflow fails in seconds rather than after a full run.
format="${INPUT_FORMAT:-sarif}"
case "$format" in
  sarif | json) ;;
  *) die 2 "Unknown format '$format'. Use sarif or json." ;;
esac

if is_true "${INPUT_UPLOAD:-false}" && [ "$has_token" = false ]; then
  die 2 "upload needs project-token (recommended) or api-token."
fi

# --- Configuration -------------------------------------------------------------
config_file="${INPUT_CONFIG_FILE:-.codacy/codacy.config.json}"
config_source="${INPUT_CONFIG_SOURCE:-auto}"
if [ "$config_source" = "auto" ]; then
  if [ -f "$config_file" ]; then
    config_source=local
  elif [ "$has_token" = true ]; then
    config_source=remote
  else
    config_source=discover
  fi
fi

# Generated configurations go under RUNNER_TEMP, never into the checkout, so a
# later step that commits or diffs the workspace does not pick them up.
generated_dir="${RUNNER_TEMP:?RUNNER_TEMP is not set}/codacy-analysis-config"
generated_config="$generated_dir/codacy.config.json"

case "$config_source" in
  local)
    [ -f "$config_file" ] || die 2 "config-source is 'local' but $config_file does not exist. Commit one (codacy-analysis init) or use config-source 'remote' or 'discover'."
    echo "Using the committed configuration $config_file"
    ;;
  remote)
    [ "$has_token" = true ] || die 2 "config-source 'remote' needs project-token (recommended) or api-token."
    rm -rf "$generated_dir" && mkdir -p "$generated_dir"
    echo "::group::Fetching the Codacy configuration for $provider/$owner/$repository"
    "$cli" init --remote "$provider" "$owner" "$repository" --config-file "$generated_config" ||
      die 2 "Could not fetch the configuration of $provider/$owner/$repository from Codacy. Check that the token is valid and belongs to this repository."
    echo "::endgroup::"
    config_file="$generated_config"
    ;;
  discover)
    rm -rf "$generated_dir" && mkdir -p "$generated_dir"
    echo "::group::Generating a configuration from the detected stack"
    "$cli" init --auto --config-file "$generated_config" ||
      die 2 "Could not generate a configuration from the repository's stack; see the log above."
    echo "::endgroup::"
    config_file="$generated_config"
    ;;
  *)
    die 2 "Unknown config-source '$config_source'. Use auto, local, remote or discover."
    ;;
esac

# --- Analysis ------------------------------------------------------------------
output="${INPUT_OUTPUT:-codacy-results.$format}"
mkdir -p "$(dirname "$output")"

args=(analyze "${INPUT_PATH:-.}" --output-format "$format" --output "$output" --config-file "$config_file")
if is_true "${INPUT_INSTALL_DEPENDENCIES:-true}"; then args+=(--install-dependencies); fi
if [ -n "${INPUT_PARALLEL_TOOLS:-}" ]; then args+=(--parallel-tools "$INPUT_PARALLEL_TOOLS"); fi
if [ -n "${INPUT_TOOL_TIMEOUT:-}" ]; then args+=(--tool-timeout "$INPUT_TOOL_TIMEOUT"); fi
if is_true "${INPUT_VERBOSE:-false}"; then args+=(--log-level debug); fi
# Tools may be separated by commas, newlines or spaces. Globbing is off while
# the list is word-split, so a stray '*' stays literal.
set -f
for tool in $(printf '%s' "${INPUT_TOOL:-}" | tr ',\n' '  '); do
  args+=(--tool "$tool")
done
set +f

echo "::group::Analyzing"
set +e
"$cli" "${args[@]}"
analyze_exit=$?
set -e
echo "::endgroup::"

# The CLI exits 0 when clean, 1 when it found issues, 2 when the run failed.
# A failed run is not uploaded: Codacy would record the missing tools' results
# as "no issues" for this commit.
if [ "$analyze_exit" -ge 2 ]; then
  die "$analyze_exit" "The analysis did not complete (exit code $analyze_exit); see the log above. Nothing was uploaded."
fi
[ -f "$output" ] || die 2 "The analysis finished but wrote no report to $output."

issues="$(node "$script_dir/count-issues.cjs" "$output" "$format")"
echo "Found $issues issue(s). Report: $output"
{
  echo "report=$output"
  echo "issues=$issues"
} >> "$GITHUB_OUTPUT"

# --- Upload --------------------------------------------------------------------
if is_true "${INPUT_UPLOAD:-false}"; then
  upload_args=(upload "$output" --commit "${COMMIT_SHA:?COMMIT_SHA is not set}")
  # The project token identifies the repository by itself; an account token
  # needs to be told which one.
  if [ "$has_project_token" = false ]; then
    upload_args+=(--repository "$provider" "$owner" "$repository")
  fi
  echo "::group::Uploading results for commit $COMMIT_SHA"
  "$cli" "${upload_args[@]}" ||
    die 2 "Could not upload the results to Codacy; see the log above. Check the token, and that \"Run analysis through build server\" is enabled for the repository."
  echo "::endgroup::"
fi
