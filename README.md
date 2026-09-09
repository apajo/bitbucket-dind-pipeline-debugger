# Local Bitbucket Pipelines debug harness (dind)

Reproduces a single `bitbucket-pipelines.yml` step from any repo in a local
Docker container, following Atlassian's own recipe for this:
https://support.atlassian.com/bitbucket-cloud/kb/troubleshoot-failed-bitbucket-pipelines-locally-with-docker/

Extended with a `docker:dind` sidecar for any step that declares
`services: [docker]`, so `DOCKER_HOST` points at a *separate* daemon the same
way Bitbucket's own `docker` service does -- not the host's Docker engine --
including the same memory cap (`definitions.services.docker.memory` in the
target repo's yaml, if it declares one). That cap is shared by every
container the step spawns, so OOM-flavored flakiness under that shared budget
has a chance to reproduce locally instead of only in CI.

The step's `script:`/`after-script:` are pulled live out of the real yaml via
`lib/pipeline_step.py` (PyYAML resolves any `&anchor`/`*alias` pairs the file
uses) -- there's no hand-maintained copy of the pipeline to drift out of sync.

## Usage

```shell
./run.sh [--repo <path>] --list             # step names available
./run.sh [--repo <path>] "<step name>"      # run script + after-script
./run.sh [-C <path>] "<step name>" --shell  # drop into the agent container
                                              # instead; /tmp/step-script.sh
                                              # and /tmp/after-script.sh are
                                              # there to run by hand
./run.sh --clean                            # remove the sidecar/network/agent
```

`--repo`/`-C <path>` points at the checkout whose `bitbucket-pipelines.yml`
you want to reproduce a step from. It's shown in brackets above because it's
optional on the command line specifically -- the `REPO_DIR` env var (e.g. set
once in `secrets.env`) works the same way, so you only need one or the other,
not both. One of the two is still required for every mode (including
`--list`, since it needs to know which yaml to read) except `--clean`.

Each run prints where it wrote the extracted script/after-script
(`work/<step>.script.sh` / `.after-script.sh`) -- read or edit those to see
exactly what will execute, or to try a fix before touching the real yaml.

### Secrets

Copy `secrets.env.example` to `secrets.env` (sourced automatically if
present, gitignored) and define whatever repository variables the step you're
running needs -- e.g. registry credentials, deploy keys, database passwords,
API tokens. Every variable you define there that ends up non-empty is
forwarded into the agent container automatically, matching how an unset
Bitbucket repo variable behaves: e.g. a step whose script checks for a
registry key will fail at that same check, not earlier or later, if you leave
it blank or omit it.

### REPO_DIR

`REPO_DIR` is the local checkout whose pipeline you're reproducing -- a path
on disk, not a URL; the tool never clones anything itself. Set it either way:

- `--repo <path>` / `-C <path>` on the command line, or
- the `REPO_DIR` env var (e.g. exported, or set once in `secrets.env`)

If both are given, the flag wins. One of the two is required for every mode
(including `--list`, since it needs to know which yaml to read) except
`--clean`.

It's bind-mounted live into the agent container at `$BITBUCKET_CLONE_DIR`
(`/opt/atlassian/pipelines/agent/build`, matching a real Bitbucket agent's
layout) rather than copied or `git clone`d fresh -- so it's always your
current working tree, uncommitted changes included, letting you edit the repo
and re-run a step without any rebuild/re-clone step in between. If a step
declares `services: [docker]`, the same path is also bind-mounted into the
`docker:dind` sidecar, since some steps (e.g. ones running `docker compose`)
expect the checkout to be visible from both sides of `DOCKER_HOST`.

Several other defaults are derived from `REPO_DIR`'s own git state unless you
override them explicitly:

- `BITBUCKET_COMMIT` defaults to its current `HEAD`
- `BITBUCKET_BRANCH` defaults to its current branch
- `BITBUCKET_REPO_FULL_NAME` defaults to the `owner/repo` parsed out of its
  `origin` remote URL (falling back to the directory's basename if there's no
  parseable remote)
- `YAML_FILE` defaults to `$REPO_DIR/bitbucket-pipelines.yml`

### Config

Env vars (or set them in `secrets.env`):

- `REPO_DIR` -- checkout to bind-mount as `$BITBUCKET_CLONE_DIR` (required;
  or pass `--repo`/`-C <path>` instead -- see REPO_DIR, above)
- `YAML_FILE` -- pipeline file to read steps from (default `$REPO_DIR/bitbucket-pipelines.yml`)
- `BITBUCKET_BRANCH`, `BITBUCKET_COMMIT`, `BITBUCKET_REPO_FULL_NAME` -- default to
  `REPO_DIR`'s current branch/HEAD and the `owner/repo` parsed from its git
  `origin` remote
- `KEEP=1` -- leave the dind sidecar + network running after the agent exits,
  for faster repeat runs (clean up later with `./run.sh --clean`)

### What this does NOT reproduce

- Bitbucket's authz-plugin restrictions (rejecting `--privileged`, non-legacy
  compose mount APIs, `--security-opt`/`--cap-add`). If a step's Docker Compose
  stack relies on Buildx or newer Compose-plugin features that trip these
  restrictions in real CI, a locally-passing run here doesn't prove those
  constraints are still satisfied -- check the target repo's own workarounds
  for this (pinned Compose version, `DOCKER_BUILDKIT=0`, etc.) before trusting
  a local pass over a CI failure.
- The exact size->CPU/memory mapping Bitbucket uses for `1x`/`2x`/`4x`/`8x`
  (undocumented publicly) -- `run.sh` uses plausible caps, not confirmed-identical
  ones.
- Network-level differences (Bitbucket's runner IP ranges, egress rules).

## Repo layout

- `run.sh` -- the orchestrator (see above)
- `lib/pipeline_step.py` -- extracts one step's `image`/`size`/`services`/
  `script`/`after-script` from any bitbucket-pipelines.yml
- `my.dockerfile` -- the plain Atlassian-KB template (`FROM <build image>` +
  `COPY` a repo in at build time). Not used by `run.sh`, which bind-mounts
  `REPO_DIR` live instead so you don't rebuild an image on every edit; kept
  here for the rare case you want a frozen, COPY-baked snapshot instead.
- `.cache/docker-cli/docker` -- a static `docker` CLI binary cached out of
  `docker:dind` (created on first run that needs the `docker` service);
  atlassian/default-image doesn't bundle one itself, Bitbucket injects it for
  steps that declare `services: [docker]` and `run.sh` does the same.
- `work/` -- generated script/after-script files (gitignored scratch output,
  safe to delete)
- `secrets.env.example` / `secrets.env` -- repository variables (see Secrets, above)
