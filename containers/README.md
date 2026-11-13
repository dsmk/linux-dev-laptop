# Container images

Every image is built from one `Containerfile`. What differs per flavour —
which package lists it installs, what it is published as, which architectures
it is built for, and whether it carries the developer toolchain — is declared
in `flavours.conf`, which `build.sh`, `scripts/validate.sh`,
`tests/smoke-container.sh` and the GitHub workflow all read.

| Flavour     | Published as                                | Kind | Arch         | Entered with                      |
| ----------- | ------------------------------------------- | ---- | ------------ | --------------------------------- |
| `toolbx`    | `ghcr.io/dsmk/developer-platform-dev`       | dev  | amd64, arm64 | `toolbox enter --container dev`   |
| `distrobox` | `ghcr.io/dsmk/developer-platform-distrobox` | dev  | amd64, arm64 | `distrobox enter dev-distrobox`   |
| `ticrypt`   | `ghcr.io/dsmk/developer-platform-ticrypt`   | app  | amd64        | `distrobox enter ticrypt`         |

A `dev` image carries the full toolchain: `packages/common.txt` plus VS Code,
kubectl, argocd and ot. An `app` image carries only what its package lists
name plus its own payload, so the ticrypt image is a fraction of the size of
the development ones.

All images carry `com.github.containers.toolbox=true`, so either tool can use
any of them.

## tiCrypt Connect

The `ticrypt` flavour packages the [tiCrypt Connect](https://ticrypt.com/download)
desktop client. It builds on `packages/distrobox.txt` rather than
`common.txt`: it is an application container, not a development one.

```bash
distrobox create --name ticrypt \
  --image ghcr.io/dsmk/developer-platform-ticrypt:main
distrobox enter ticrypt -- distrobox-export --app ticrypt-connect
```

The second command puts "tiCrypt Connect" on the host application menu; it
works because the RPM installs `/usr/share/applications/ticrypt-connect.desktop`
and hicolor icons, and the image adds the icon themes and fonts a GTK/WebKit
application needs to render correctly.

Upstream publishes neither a checksum file nor a signed RPM, so
`TICRYPT_SHA256` in the Containerfile is the pin: it is a digest taken from
the downloaded artefact. When bumping `TICRYPT_VERSION`, download the new RPM
over a trusted connection, record its `sha256sum`, and update both.
`scripts/validate.sh` checks the digest is present and well formed; it cannot
check it is the right one.

tiCrypt Connect publishes an x86_64 Linux build only, which is why
`flavours.conf` lists `amd64` alone for this flavour.

## Layout

```
containers/
├── flavours.conf            what a flavour is; the single source of truth
├── build.sh                 the only supported way to build
├── ci-matrix.sh             turns flavours.conf into the CI build matrices
├── dev/
│   ├── Containerfile        shared by every flavour, driven by build args
│   └── podman.sh            /etc/profile.d snippet for the host podman socket
└── packages/
    ├── common.txt           the developer toolchain
    ├── toolbx.txt           extra packages for toolbx
    ├── distrobox.txt        distrobox host integration
    └── ticrypt.txt          tiCrypt Connect runtime dependencies
```

The build context is `containers/`, not `containers/dev/`, because the package
manifests are shared. `build.sh` handles this; a bare
`podman build containers/dev` will not work.

## Building

```bash
containers/build.sh --flavor toolbx --smoke
```

```bash
containers/build.sh --flavor distrobox --smoke
```

```bash
containers/build.sh --flavor ticrypt --smoke
```

`--smoke` runs `tests/smoke-container.sh` inside the result, which checks that
every tool the flavour promises is present and starts. `build.sh --help` lists
the remaining options (`--arch`, `--tag`, `--base`, `--engine`, `--push`,
`--dry-run`).

Podman is used when installed, otherwise Docker. CI uses Podman.

## Changing what is installed

* A package from Fedora, COPR or the VS Code repository: add it to
  `packages/common.txt` (every development flavour) or to the flavour's own
  list. Keep each
  list sorted with `LC_ALL=C sort` and do not repeat a name that is already in
  `common.txt`.
* Anything installed from a URL: add a `RUN` to `dev/Containerfile` with a
  pinned `ARG <TOOL>_VERSION` and a checksum verification. Unpinned downloads
  make a rebuild of an old commit produce a different image.
* A new command the image must provide: add it to the matching `require` list
  in `tests/smoke-container.sh`, otherwise nothing proves it is there.

Then run `scripts/validate.sh`, which enforces the sorting, the absence of
duplicates across lists and the presence of the version pins.

## Network hosts a build needs

A build reaches out to these; a restricted network policy that blocks any one
of them fails the build partway through:

| Host                                   | For                             |
| -------------------------------------- | ------------------------------- |
| `registry.fedoraproject.org`           | the `fedora-toolbox` base image |
| `mirrors.fedoraproject.org`            | dnf metalink                    |
| Fedora mirrors                         | dnf packages (chosen by metalink, so not a fixed host) |
| `copr.fedorainfracloud.org`            | starship COPR metadata          |
| `download.copr.fedorainfracloud.org`   | starship COPR, redirects to the next row |
| `packages.redhat.com`                  | where COPR content actually lives |
| `packages.microsoft.com`               | VS Code                         |
| `dl.k8s.io`                            | kubectl                         |
| `github.com`                           | argocd, ot                      |
| `release-assets.githubusercontent.com` | GitHub release assets           |
| `galaxy.ansible.com`                   | Ansible collections, for the checks |

`download.copr.fedorainfracloud.org` serves a 301 to `packages.redhat.com`
for the actual repository metadata, so allowing only the first of the two is
not enough: the build gets as far as `No match for argument: starship` and
stops. `starship` is not in the Fedora repositories, so the COPR is required.

Worse, dnf resolves `mirrors.fedoraproject.org` to arbitrary third-party
mirrors, so a named-host allowlist cannot cover them. For that case pass
`--dnf-baseurl`, which pins dnf to one mirror:

```bash
containers/build.sh --flavor toolbx \
  --dnf-baseurl https://dl.fedoraproject.org/pub/fedora/linux
```

That also disables `fedora-cisco-openh264`, whose RPMs are served over plain
**HTTP** from `ciscobinary.openh264.org` and so cannot traverse an HTTPS
proxy at all; Fedora's own `noopenh264` satisfies the dependency instead.
Because that changes what ends up in the image, published builds leave
`DNF_BASEURL` unset — `scripts/validate.sh` checks the default stays empty.

Two more things a proxied environment needs. The build container has to be
able to reach the proxy, which the default bridge network cannot, and it has
to trust the proxy's CA if that proxy re-terminates TLS — without which the
GitHub downloads fail with `curl: (60)`:

```bash
EXTRA_BUILD_ARGS="--network=host --build-arg https_proxy=$HTTPS_PROXY --build-arg HTTPS_PROXY=$HTTPS_PROXY" \
containers/build.sh --flavor toolbx --smoke \
  --dnf-baseurl https://dl.fedoraproject.org/pub/fedora/linux \
  --proxy-ca /root/.ccr/agent-proxy-ca.crt
```

`--proxy-ca` takes the proxy's own CA certificate, not a system trust bundle:
the value travels as a build argument, and a full bundle overflows the
engine's argument list. `build.sh` rejects a file that is too large, that
holds a private key, or that it cannot read. `PROXY_CA_CERT` defaults to
empty, so published images trust nothing extra.

`scripts/dev-env-setup.sh` reports which of these the current session can
reach, following redirects so that this particular trap is caught.

When `registry.fedoraproject.org` is unreachable but Docker Hub is,
`--base docker.io/library/fedora:44` gets a build started, at the cost of
losing the toolbox base layer — use it for experiments, not for anything
published.

## Adding a flavour

Add a line to `flavours.conf` and a `packages/<name>.txt` to match. The build
script, the validator, the smoke test and the CI matrices all read that file,
so nothing else needs editing unless the flavour installs something from a
URL, which goes in `dev/Containerfile` with a pinned version and a checksum.

## Publishing

`.github/workflows/dev-image.yml` reads the matrices from `ci-matrix.sh`, so
it builds whatever `flavours.conf` declares — today five images (two flavours
on two architectures, plus ticrypt on amd64). Each is built on a native
runner and smoke tested. On `main` it pushes `<image>:<sha>-<arch>` and then
assembles and pushes a manifest as `<image>:<sha>` and `<image>:main`. Pull
requests build and smoke test every image but publish nothing.
