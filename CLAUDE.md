# linux-dev-laptop

Configuration for a Fedora Silverblue developer laptop. The part that gets
built and published is a set of container images: **toolbx** and
**distrobox** images holding the development toolchain, and a **ticrypt**
image packaging the tiCrypt Connect desktop client. Ansible then configures
the host and creates containers from those images.

## Repository map

```
containers/           the images. Start here for anything image related.
  flavours.conf       what a flavour is; the single source of truth
  build.sh            the only supported way to build any flavour
  ci-matrix.sh        turns flavours.conf into the CI build matrices
  dev/Containerfile   shared by every flavour, driven by build args
  packages/*.txt      what gets installed; one list per concern
  README.md           flavours, build hosts, how to change what is installed
tests/
  smoke-container.sh  runs inside a built image; checks every tool is present
scripts/
  validate.sh         every check that needs neither network nor a build
  dev-env-setup.sh    prepares a session and reports what it can actually do
ansible/              host configuration (playbooks, group_vars, tasks)
.yamllint             shared yamllint config, also used by ansible-lint
.claude/settings.json permission allowlist + the SessionStart hook
.github/workflows/    dev-image.yml builds+publishes; verify.yml runs validate
*.yaml (repo root)    an older, non-OSTree Fedora playbook (site/target.yaml)
winapp/               Windows VM image definition used by the WinApps work
```

`ansible/` is the current host configuration. The loose `*.yaml` files at the
repository root (`site.yaml`, `target.yaml`, `fedora-rpms.yaml`, …) are the
earlier mutable-Fedora approach and are not wired into the Ansible playbooks;
leave them alone unless asked.

## The image flavours

`containers/flavours.conf` declares them. It is the single source of truth:
`build.sh`, `scripts/validate.sh`, `tests/smoke-container.sh` and
`.github/workflows/dev-image.yml` all read it, so **add a flavour there, not
in four places**.

| Flavour     | Published as                                | Lists                | Kind | Arch         |
| ----------- | ------------------------------------------- | -------------------- | ---- | ------------ |
| `toolbx`    | `ghcr.io/dsmk/developer-platform-dev`       | common + toolbx      | dev  | amd64, arm64 |
| `distrobox` | `ghcr.io/dsmk/developer-platform-distrobox` | common + distrobox   | dev  | amd64, arm64 |
| `ticrypt`   | `ghcr.io/dsmk/developer-platform-ticrypt`   | distrobox + ticrypt  | app  | amd64        |

Every flavour shares `containers/dev/Containerfile`, differing only by build
args. **Do not fork the Containerfile per flavour** — that is exactly the
drift this layout exists to prevent.

`kind` decides whether the URL-installed developer tools go in:

* `dev` — also installs VS Code, kubectl, argocd and ot.
* `app` — the package lists and the flavour's own payload only. `ticrypt` is
  an application container, so it builds on `distrobox.txt` rather than
  `common.txt` and carries no developer toolchain.

The `toolbx` image deliberately keeps the historical name
`developer-platform-dev`, because `ansible/group_vars/all.yml` and existing
laptops already pull it.

On the host side, `ansible/silverblue.yml` always creates the toolbx container
and creates the distrobox one only when `enable_distrobox` is true
(`ansible/group_vars/all.yml`). Both image references live in that same file.
The ticrypt container is not wired into Ansible; `containers/README.md` has
the two `distrobox` commands that create it and export its launcher.

### tiCrypt Connect

`ticrypt` packages the client from <https://ticrypt.com/download>. Upstream
publishes an unsigned x86_64 RPM and **no checksum file**, so
`TICRYPT_SHA256` in the Containerfile is a digest taken from the downloaded
artefact and is the only thing pinning the build. When bumping
`TICRYPT_VERSION`, re-download over a trusted connection, record the new
`sha256sum`, and update both. `validate.sh` checks the digest is present and
well formed; it cannot check it is the right one.

The RPM ships `/usr/share/applications/ticrypt-connect.desktop` and hicolor
icons, which is what makes `distrobox-export --app ticrypt-connect` produce a
working host launcher. `tests/smoke-container.sh` asserts the binary, the
desktop entry, the icon and the entry's `Type`/`Exec`/`Icon` lines, because
an image that lost any of them would export a broken launcher silently.

## Working here

Run this first in a fresh session; it is idempotent and never fails:

```bash
scripts/dev-env-setup.sh
```

It starts a container engine if one can be started, and prints which of the
hosts a build needs are actually reachable.

Then, after any change:

```bash
scripts/validate.sh
```

That is the same command CI runs. It needs no network and no container engine,
and covers: shell syntax and shellcheck, package manifest sorting / duplicates
/ cross-list overlap, Containerfile version pinning and the toolbx label,
YAML and JSON parsing, Ansible syntax-check and ansible-lint. Optional linters
that are not installed are reported as `SKIP` rather than failing;
`scripts/validate.sh --install-tools` installs them.

To build an image:

```bash
containers/build.sh --flavor toolbx --smoke
```

```bash
containers/build.sh --flavor distrobox --smoke
```

```bash
containers/build.sh --flavor ticrypt --smoke
```

### In a Claude Code cloud (web) session

A cloud session ships the `docker` client with no running daemon.
`scripts/dev-env-setup.sh` starts `dockerd` and `containers/build.sh` picks it
up, so builds work **if** the environment's network policy allows the hosts
listed in `containers/README.md`.

A restricted policy typically blocks `*.fedoraproject.org`,
`*.fedorainfracloud.org`, `packages.redhat.com` and `galaxy.ansible.com`,
which means:

* image builds fail partway through `dnf`,
* `ansible-galaxy collection install` fails, so the `community.general`
  modules do not resolve and `ansible/silverblue.yml` cannot be
  syntax-checked locally.

Two further traps, both documented in `containers/README.md`:

* dnf resolves the metalink to arbitrary third-party mirrors, so a named-host
  allowlist never covers them. Pass
  `--dnf-baseurl https://dl.fedoraproject.org/pub/fedora/linux` to pin dnf to
  one host. This is a local build aid only: it also disables
  `fedora-cisco-openh264`, so it changes image contents and must never be used
  for a published build.
* The build needs the container to reach the proxy, which the default bridge
  network cannot do. Pass the proxy through:

  ```bash
  EXTRA_BUILD_ARGS="--network=host --build-arg https_proxy=$HTTPS_PROXY --build-arg HTTPS_PROXY=$HTTPS_PROXY" \
    containers/build.sh --flavor toolbx --dnf-baseurl https://dl.fedoraproject.org/pub/fedora/linux --smoke
  ```

Neither is a problem with this repository. When a host is denied: say which
one, finish everything that does not depend on it — `scripts/validate.sh` is
fully offline — and let `.github/workflows/dev-image.yml` do the build. Do not
fake a build result, and do not disable TLS verification or unset
`HTTPS_PROXY` to get around the proxy.

To widen access the repository owner edits **Network access** in the cloud
environment's settings (title bar → environment menu → Edit) and adds those
hosts under **Allowed domains**:
<https://code.claude.com/docs/en/cloud-environments#network-access>

## Conventions

* **Pin everything.** Base images carry an explicit tag; tools fetched from a
  URL have an `ARG <TOOL>_VERSION` and a checksum check. No `:latest`.
  `scripts/validate.sh` enforces this.
* **Package lists are sorted** with `LC_ALL=C sort`, one name per line, no
  duplicates, and nothing in a flavour list that is already in `common.txt`.
* **Nothing that needs a Red Hat subscription**, because the images are
  published publicly to GHCR.
* **No credentials in the images or in git.** toolbx and distrobox do user
  setup at container-creation time; secrets belong in Ansible Vault. The
  `winapps_*_password` variables in `ansible/group_vars/all.yml` are
  intentionally empty.
* **Claude Code is not baked into the image.** It releases far more often than
  the image, so it is installed into the developer's home directory and
  updates itself there. Do not add a `CLAUDE_CODE_VERSION` build arg or an
  `npm install -g @anthropic-ai/claude-code` layer back without being asked;
  the comment in `containers/dev/Containerfile` records the decision.
* **`ot` is amd64-only upstream.** The Containerfile installs it on `amd64`
  and skips it elsewhere, and the smoke test skips it on non-x86_64. If
  upstream starts publishing arm64 builds, drop both conditionals.
* **A new tool in the image needs a new check** in `tests/smoke-container.sh`.
  An image that silently lost a binary should fail CI.

## Common tasks

**Add a tool to both flavours** → add the package to
`containers/packages/common.txt` (sorted), add the command to the shared
`require` list in `tests/smoke-container.sh`, run `scripts/validate.sh`.

**Add a tool to one flavour only** → same, but use
`containers/packages/<flavour>.txt` and the flavour's `case` branch in the
smoke test.

**Bump a pinned version** → edit the `ARG` at the top of
`containers/dev/Containerfile`. The checksum logic downloads the matching
checksum file, so nothing else needs updating.

**Add a flavour** → add a line to `containers/flavours.conf` and a matching
`containers/packages/<name>.txt`. Everything else reads that file, so nothing
else needs editing unless the flavour installs something from a URL, which
goes in `containers/dev/Containerfile` with a pinned `ARG <TOOL>_VERSION` and
a checksum, plus a check in `tests/smoke-container.sh`.

## CI

* `.github/workflows/verify.yml` — runs `scripts/validate.sh` on every push
  and pull request.
* `.github/workflows/dev-image.yml` — a `matrix` job runs
  `containers/ci-matrix.sh`, so the workflow builds whatever `flavours.conf`
  declares without listing the flavours itself. Each image is built on a
  native runner and smoke tested; on `main` it publishes per-arch tags plus a
  multi-arch manifest per flavour. Pull requests build and smoke test
  everything and publish nothing.

## Git

Work on a feature branch; do not commit to `main`. Do not open a pull request
unless asked.
