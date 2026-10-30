# Codacy Analysis CLI GitHub Action

GitHub Action for running [Codacy](https://www.codacy.com/) static analysis with the
[Codacy Analysis CLI](https://www.npmjs.com/package/@codacy/analysis-cli) (`@codacy/analysis-cli`),
and optionally uploading the results to Codacy.

## Table of contents

- [Quick start](#quick-start)
- [Authentication](#authentication)
  - [Project token (recommended)](#project-token-recommended)
  - [Account token](#account-token)
- [Where the configuration comes from](#where-the-configuration-comes-from)
- [Scenarios](#scenarios)
  - [Upload results to Codacy](#upload-results-to-codacy)
  - [GitHub code scanning](#github-code-scanning)
  - [Block pull requests that add issues](#block-pull-requests-that-add-issues)
  - [Analyze without a Codacy account](#analyze-without-a-codacy-account)
- [Inputs](#inputs)
- [Outputs](#outputs)
- [When the step fails](#when-the-step-fails)
- [Migrating from other Codacy actions](#migrating-from-other-codacy-actions)
  - [From codacy-cli-v2-action](#from-codacy-cli-v2-action)
  - [From codacy-analysis-cli-action](#from-codacy-analysis-cli-action)
- [Contributing](#contributing)

## Quick start

```yaml
name: Codacy

on:
  push:
    branches: [main]
  pull_request:

jobs:
  codacy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          # Analyze the PR head, which is the commit the results are attached to
          ref: ${{ github.event.pull_request.head.sha || github.sha }}

      - uses: codacy/analysis-cli-action@v1
        with:
          project-token: ${{ secrets.CODACY_PROJECT_TOKEN }}
          upload: true
```

This fetches the repository's configuration from Codacy, installs the tools it needs, analyzes
the repository, writes `codacy-results.sarif`, and uploads the results to Codacy for the commit.

The action runs on Linux, macOS and Windows runners. It needs Node.js 20 or later, and sets it
up only when the runner does not already have it.

## Authentication

### Project token (recommended)

A project token belongs to one repository, so it is all the action needs: there is no provider,
organization or repository name to keep in sync, and a leaked token exposes only that repository.

1. On Codacy, [create a project API token](https://docs.codacy.com/codacy-api/api-tokens/#project-api-tokens)
   for the repository.
2. Store it as a [repository secret](https://docs.github.com/actions/security-guides/using-secrets-in-github-actions#creating-secrets-for-a-repository)
   named `CODACY_PROJECT_TOKEN`.
3. Pass it as `project-token: ${{ secrets.CODACY_PROJECT_TOKEN }}`.

### Account token

An [account API token](https://docs.codacy.com/codacy-api/api-tokens/#account-api-tokens) is
supported for organizations that share one token across many repositories, typically as an
[organization secret](https://docs.github.com/actions/security-guides/using-secrets-in-github-actions#creating-secrets-for-an-organization).
It grants access to every repository its owner can reach, so prefer a project token where you can.

```yaml
- uses: codacy/analysis-cli-action@v1
  with:
    api-token: ${{ secrets.CODACY_API_TOKEN }}
    upload: true
```

With an account token the action identifies the repository from the workflow's context: `gh` on
github.com or `ghe` on GitHub Enterprise Server, and the current owner and repository. Set
`provider`, `owner` and `repository` when the repository is registered on Codacy under different
coordinates. If both tokens are given, the project token is used.

> ⚠️ Never write tokens into workflow files. Always pass them from secrets.

## Where the configuration comes from

`config-source` decides which tools and patterns run:

| Value            | Configuration used                                                                                                                         |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| `auto` (default) | `local` if `config-file` exists in the repository, else `remote` if a token is set, else `discover`.                                       |
| `local`          | The committed `.codacy/codacy.config.json` (or `config-file`), as created by `codacy-analysis init` and kept current with `update-config`. |
| `remote`         | The repository's current configuration on Codacy, fetched on every run. Needs a token.                                                     |
| `discover`       | A configuration generated from the repository's detected languages and frameworks (`codacy-analysis init --auto`). No token needed.        |

A configuration the action generates (`remote`, `discover`) is written under `RUNNER_TEMP`, never
into your checkout.

## Scenarios

### Upload results to Codacy

Shown in the [quick start](#quick-start). On Codacy, also enable **Run analysis through build
server** in the repository's **Settings**, tab **General**, so Codacy waits for the uploaded
results instead of finishing the analysis without them.

On `pull_request` events the results are attached to the PR head commit. GitHub checks out a merge
commit by default, so check out the head with `ref:` as in the quick start; otherwise line numbers
can point at the wrong lines.

### GitHub code scanning

```yaml
permissions:
  contents: read
  security-events: write

steps:
  - uses: actions/checkout@v4

  - uses: codacy/analysis-cli-action@v1
    id: codacy
    with:
      project-token: ${{ secrets.CODACY_PROJECT_TOKEN }}

  - uses: github/codeql-action/upload-sarif@v3
    if: always()
    with:
      sarif_file: ${{ steps.codacy.outputs.report }}
```

### Block pull requests that add issues

The step does not fail because of the issues it finds: a count of every issue in the analyzed
files cannot tell the issues a pull request adds from the ones already there. Upload the results
and use Codacy's [pull request quality gate](https://docs.codacy.com/repositories-configure/adjusting-quality-gates/),
which compares the pull request with its base and reports a status check you can make required.

The `issues` output is still available if a later step needs the count.

### Analyze without a Codacy account

With no token and no committed configuration, the action generates a configuration from the
repository's stack and analyzes with it. Restrict the run with `tool` and `path`:

```yaml
- uses: codacy/analysis-cli-action@v1
  with:
    tool: ESLint9, Stylelint
    path: frontend
```

## Inputs

| Input                         | Default                      | Description                                                                                                 |
| ----------------------------- | ---------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `project-token`               |                              | Recommended. Codacy project API token.                                                                      |
| `api-token`                   |                              | Codacy account API token. Ignored when `project-token` is set.                                              |
| `provider`                    | `gh` / `ghe`                 | Account-token mode: Git provider of the repository on Codacy.                                               |
| `owner`                       | current owner                | Account-token mode: organization on Codacy.                                                                 |
| `repository`                  | current repository           | Account-token mode: repository name on Codacy.                                                              |
| `config-source`               | `auto`                       | `auto`, `local`, `remote` or `discover`. See [above](#where-the-configuration-comes-from).                  |
| `config-file`                 | `.codacy/codacy.config.json` | Committed configuration file, relative to the repository root.                                              |
| `tool`                        | all configured tools         | Tool IDs to run, comma- or newline-separated (e.g. `ESLint9, Ruff`). `codacy-analysis info` lists the IDs. |
| `path`                        | `.`                          | File, directory or quoted glob to analyze.                                                                  |
| `format`                      | `sarif`                      | Report format: `sarif` or `json`. Both can be uploaded.                                                     |
| `output`                      | `codacy-results.<format>`    | Report file path.                                                                                           |
| `upload`                      | `false`                      | Upload the results to Codacy. Needs a token.                                                                |
| `install-dependencies`        | `true`                       | Install the tools the configuration needs. When `false`, unavailable tools are skipped.                     |
| `parallel-tools`              | `1`                          | Maximum number of tools running at the same time.                                                           |
| `tool-timeout`                |                              | Per-tool timeout, in milliseconds.                                                                          |
| `verbose`                     | `false`                      | Log at debug level.                                                                                         |
| `cli-version`                 | `latest`                     | `@codacy/analysis-cli` version to install from npm. Pin it for reproducible runs.                           |
| `codacy-api-base-url`         | `https://app.codacy.com`     | Codacy API URL, for self-hosted Codacy.                                                                     |
| `codacy-results-api-base-url` | `https://api.codacy.com/2.0` | Codacy results API URL used for uploads, for self-hosted Codacy.                                            |

## Outputs

| Output   | Description                               |
| -------- | ----------------------------------------- |
| `report` | Path of the report file the action wrote. |
| `issues` | Number of issues the analysis found.      |

## When the step fails

- **The analysis did not complete** (for example a tool crashed or timed out): the step fails and
  **nothing is uploaded**, since Codacy would otherwise read the missing tools' results as "no
  issues" for that commit.
- **Invalid inputs, or a missing token** for `upload` or `config-source: remote`: the step fails
  before anything is analyzed.

Each failure is reported as an annotation on the workflow run. Issues found by the analysis never
fail the step; see [Block pull requests that add issues](#block-pull-requests-that-add-issues).

## Migrating from other Codacy actions

### From codacy-cli-v2-action

| `codacy/codacy-cli-v2-action`     | `codacy/analysis-cli-action`                                  |
| --------------------------------- | ------------------------------------------------------------- |
| `project_token`                   | `project-token`                                               |
| `api_token`                       | `api-token`                                                   |
| `provider`, `owner`, `repository` | Same names, now optional (taken from the workflow by default) |
| `tool: eslint`                    | `tool: ESLint9` (or `ESLint8`); omit it to run every tool     |
| `sarif_file_path`                 | `output`                                                      |
| `upload_report`                   | `upload`                                                      |
| `registry`                        | No equivalent yet                                             |

The CLI v2 configuration in `.codacy/codacy.yaml` is not read. Use `config-source: remote` (the
default when you pass a token and have no committed configuration), or commit a configuration
created with `codacy-analysis init`.

### From codacy-analysis-cli-action

`codacy/codacy-analysis-cli-action` runs Codacy's Docker tool images. Keep using it if you need
something this action does not do yet:

- the standalone tools `run-gosec` and `run-staticcheck`, or uploading `clang-tidy-output` or
  `faux-pas-output`;
- `gh-code-scanning-compat` (lowering the severity of non-security issues for code scanning);
- a tool the Analysis CLI cannot run locally (`codacy-analysis info` lists those as unsupported).

Otherwise the inputs map directly: `project-token`, `api-token`, `tool`, `output`, `format`,
`upload`, `codacy-api-base-url` and `verbose` keep their names; `parallel` is now
`parallel-tools`, and `tool-timeout` is now in milliseconds. `max-allowed-issues` has no
equivalent: use Codacy's [pull request quality gate](#block-pull-requests-that-add-issues) instead.

## Contributing

Bug reports and contributions are welcome:
[open an issue](https://github.com/codacy/analysis-cli-action/issues).
