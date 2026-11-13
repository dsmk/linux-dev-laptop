# linux-dev-laptop

Configuration for a Fedora Silverblue developer laptop. What gets built and
published is a **collection of standalone container images**; Ansible then
configures the host and creates containers from them.

## Repository map

```
images/               one directory per image. Start here for anything image related.
  README.md           the images, how to build them, build hosts, adding one
  developer-platform-dev/   the development environment (the large one)
  ticrypt-connect/          the tiCrypt Connect desktop client
scripts/
  build-image.sh      optional helper; plain `podman build` also works
  validate.sh         every check that needs neither network nor a build
  dev-env-setup.sh    prepares a session and reports what it can actually do
ansible/              host configuration (playbooks, group_vars, tasks)
.yamllint             shared yamllint config, also used by ansible-lint
.claude/settings.json permission allowlist + the SessionStart hook
.github/workflows/    one workflow per image, plus verify.yml
*.yaml (repo root)    an older, non-OSTree Fedora playbook (site/target.yaml)
winapp/               Windows VM image definition used by the WinApps work
```

`ansible/` is the current host configuration. The loose `*.yaml` files at the
repository root (`site.yaml`, `target.yaml`, `fedora-rpms.yaml`, …) are the
earlier mutable-Fedora approach and are not wired into the Ansible playbooks;
leave them alone unless asked.

## Images are standalone

Each directory under `images/` is a complete, independent image:

```
images/<name>/
  Containerfile    builds from this directory alone
  packages.txt     what dnf installs
  smoke.sh         run inside the built image; proves it works
```

and one workflow in `.github/workflows/` builds and publishes it. There is
**no shared Containerfile, no flavour registry and no build matrix**. That is
deliberate: an image is meant to be readable and buildable on its own, and
`podman build images/<name>` is the whole story.

So: **do not factor shared pieces back out across images.** If two images
need the same package, both list it. Duplication between images is the price
of each one standing alone, and it is the price this repository has chosen.

| Image                    | Published as                          | Arch         |
| ------------------------ | ------------------------------------- | ------------ |
| `developer-platform-dev` | `ghcr.io/dsmk/developer-platform-dev` | amd64, arm64 |
| `ticrypt-connect`        | `ghcr.io/dsmk/ticrypt-connect`        | amd64        |

The published name is the directory name. `developer-platform-dev` is large
on purpose — toolchain, language runtimes, VS Code, kubectl, argocd, ot — and
serves both `toolbox create` and `distrobox create`, because it carries the
toolbx label and the host-integration utilities distrobox needs.
`ticrypt-connect` is the opposite: a minimal Fedora base plus one application
and its runtime.

`images/README.md` has the details, including the VS Code extension helper
and the tiCrypt checksum pinning.

## Working here

Run this first in a fresh session; it is idempotent and never fails:

```bash
scripts/dev-env-setup.sh
```

It starts a container engine if one can be started, and prints which of the
URLs a build fetches are actually reachable.

Then, after any change:

```bash
scripts/validate.sh
```

That is the same command CI runs. It needs no network and no container
engine, and covers: shell syntax and shellcheck, each image's required files,
package and extension lists sorted and duplicate-free, Containerfile version
and checksum pinning, the toolbx label, that no image copies from outside its
own directory, that every image has a workflow, YAML and JSON parsing, and
Ansible syntax-check plus ansible-lint. Missing optional linters are reported
as `SKIP`; `scripts/validate.sh --install-tools` installs them.

To build:

```bash
scripts/build-image.sh developer-platform-dev --smoke
```

```bash
scripts/build-image.sh ticrypt-connect --smoke
```

### In a Claude Code cloud (web) session

A cloud session ships the `docker` client with no running daemon.
`scripts/dev-env-setup.sh` starts `dockerd` and the build helper picks it up,
so builds work **if** the network policy allows the hosts in
`images/README.md`. Two traps, both documented there:

* dnf resolves the metalink to arbitrary third-party mirrors, so a named-host
  allowlist never covers them. Pass
  `--dnf-baseurl https://dl.fedoraproject.org/pub/fedora/linux`. Local build
  aid only: it also disables `fedora-cisco-openh264`, so it changes image
  contents and must never be used for a published build.
* The build container must reach the proxy, which the default bridge network
  cannot, and must trust its CA:

  ```bash
  EXTRA_BUILD_ARGS="--network=host --build-arg https_proxy=$HTTPS_PROXY --build-arg HTTPS_PROXY=$HTTPS_PROXY" \
  scripts/build-image.sh developer-platform-dev --smoke \
    --dnf-baseurl https://dl.fedoraproject.org/pub/fedora/linux \
    --proxy-ca /root/.ccr/agent-proxy-ca.crt
  ```

When a host is denied: say which one, finish everything that does not depend
on it — `scripts/validate.sh` is fully offline — and let the image's workflow
do the build. Do not fake a build result, and do not disable TLS verification
or unset `HTTPS_PROXY` to get around the proxy.

To widen access the repository owner edits **Network access** in the cloud
environment's settings (title bar → environment menu → Edit):
<https://code.claude.com/docs/en/cloud-environments#network-access>

## Conventions

* **Pin everything.** Base images carry an explicit tag; tools fetched from a
  URL have an `ARG <TOOL>_VERSION`, and a checksum — upstream's where there is
  one, otherwise an `ARG <TOOL>_SHA256` recorded from the artefact. No
  `:latest`. `scripts/validate.sh` enforces this.
* **Package lists are sorted** with `LC_ALL=C sort`, one name per line, no
  duplicates.
* **Nothing that needs a Red Hat subscription**, because the images are
  published publicly to GHCR.
* **No credentials in the images or in git.** toolbx and distrobox do user
  setup at container-creation time; secrets belong in Ansible Vault. The
  `winapps_*_password` variables in `ansible/group_vars/all.yml` are
  intentionally empty.
* **Claude Code is not baked into any image.** It releases far more often
  than they do, so it is installed into the developer's home directory and
  updates itself there. Do not add a `CLAUDE_CODE_VERSION` build arg or an
  `npm install -g @anthropic-ai/claude-code` layer without being asked.
* **Anything in `$HOME` cannot be baked in.** toolbx and distrobox mount the
  host's home directory over the image's, which is why VS Code extensions
  ship as a list plus `dev-install-extensions` rather than as a layer.
* **`ot` is amd64-only upstream.** `developer-platform-dev` installs it on
  amd64 and skips it elsewhere, and its smoke test skips it on non-x86_64.
* **A new tool in an image needs a new check** in that image's `smoke.sh`.
  An image that silently lost a binary should fail CI.

## Common tasks

**Add a tool to an image** → add the package to `images/<name>/packages.txt`
(sorted), add the command to that image's `smoke.sh`, run
`scripts/validate.sh`.

**Bump a pinned version** → edit the `ARG` near the top of that image's
`Containerfile`. Where the checksum is `ARG <TOOL>_SHA256` rather than one
fetched from upstream, re-download over a trusted connection and re-record it.

**Add an image** → create `images/<name>/` with a `Containerfile`,
`packages.txt` and an executable `smoke.sh`, then copy one of the workflows
and change the paths and `IMAGE_NAME`. `scripts/validate.sh` discovers the
directory by itself and reports what is missing.

## CI

* `.github/workflows/verify.yml` — runs `scripts/validate.sh` on every push
  and pull request.
* One workflow per image, named after it, triggered only by changes under
  that image's directory. A pull request builds and smoke tests; a push to
  `main` publishes to GHCR.

## Git

Work on a feature branch; do not commit to `main`. Do not open a pull request
unless asked.
