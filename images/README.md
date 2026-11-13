# Images

Each directory here is one standalone container image. There is no shared
Containerfile and no build matrix: an image is its own directory, its own
`Containerfile`, its own package list, its own smoke test and its own
workflow. Building one is just

```bash
podman build images/ticrypt-connect
```

| Image                    | Published as                              | Arch         | What it is |
| ------------------------ | ----------------------------------------- | ------------ | ---------- |
| `developer-platform-dev` | `ghcr.io/dsmk/developer-platform-dev`     | amd64, arm64 | The development environment: toolchain, language runtimes, VS Code, kubectl, argocd, ot. Large on purpose. |
| `ticrypt-connect`        | `ghcr.io/dsmk/ticrypt-connect`            | amd64        | The tiCrypt Connect desktop client and the runtime it needs. Nothing else. |

The published name is the directory name.

## developer-platform-dev

One image for both tools. It carries `com.github.containers.toolbox=true`
and the host-integration utilities distrobox shells out to, so either works:

```bash
toolbox create --container dev --image ghcr.io/dsmk/developer-platform-dev:main
```

```bash
distrobox create --name dev --image ghcr.io/dsmk/developer-platform-dev:main
```

### VS Code extensions

`extensions.txt` lists them, and `dev-install-extensions` installs them:

```bash
dev-install-extensions
```

They are **not** baked into the image, and cannot be: toolbx and distrobox
mount the host's home directory over the image's, so
`$HOME/.vscode/extensions` from the image would be shadowed at runtime. The
command is idempotent, so run it once in each new container.

It downloads from `marketplace.visualstudio.com`, which is a **runtime**
dependency of the container, not of the build — a network policy that blocks
it still builds the image fine, but `dev-install-extensions` then reports
every extension as "not found", which is the marketplace being unreachable
rather than a bad identifier.

## ticrypt-connect

Starts from the minimal Fedora base rather than `fedora-toolbox`, and
installs only the utilities distrobox needs inside a container plus the GTK +
WebKit runtime the application links against.

```bash
distrobox create --name ticrypt --image ghcr.io/dsmk/ticrypt-connect:main
```

```bash
distrobox enter ticrypt -- distrobox-export --app ticrypt-connect
```

The second command puts "tiCrypt Connect" on the host application menu. It
works because the RPM installs
`/usr/share/applications/ticrypt-connect.desktop` and hicolor icons, and the
image adds the icon themes and fonts they need to render. `smoke.sh` asserts
all of that, plus that `ldd` resolves every library the binary needs, because
an image missing any of it would export a launcher that silently fails.

Upstream publishes neither a checksum file nor a signed RPM, so
`TICRYPT_SHA256` in the Containerfile is a digest taken from the downloaded
artefact and is the only thing pinning the build. When bumping
`TICRYPT_VERSION`, download the new RPM over a trusted connection, record its
`sha256sum`, and update both. `scripts/validate.sh` checks the digest is
present and well formed; it cannot check it is the right one.

tiCrypt Connect publishes an x86_64 Linux build only, hence amd64 alone.

## Adding an image

Create `images/<name>/` with a `Containerfile`, a `packages.txt` and an
executable `smoke.sh`, then copy one of the workflows in
`.github/workflows/` and change the paths and `IMAGE_NAME`.
`scripts/validate.sh` discovers the directory by itself and will tell you
what is missing, including if no workflow references it.

Conventions it enforces: an explicit `BASE_IMAGE` tag and no `:latest`, a
pinned `ARG <TOOL>_VERSION` for anything fetched from a URL, a 64-character
`ARG <TOOL>_SHA256` where there is one, the `com.github.containers.toolbox`
label, a sorted duplicate-free `packages.txt`, and no `COPY` from outside the
image's own directory.

## Building

```bash
scripts/build-image.sh developer-platform-dev --smoke
```

```bash
scripts/build-image.sh ticrypt-connect --smoke
```

The helper is optional — plain `podman build images/<name>` works — but it
picks the engine, checks the toolbx label, runs the image's `smoke.sh`, and
carries the two flags a restricted network needs. `--help` lists them.

## Network hosts a build needs

| Host                                   | For                             |
| -------------------------------------- | ------------------------------- |
| `registry.fedoraproject.org`           | the Fedora base images          |
| `mirrors.fedoraproject.org`            | dnf metalink                    |
| Fedora mirrors                         | dnf packages (chosen by metalink, so not a fixed host) |
| `copr.fedorainfracloud.org`            | starship COPR metadata          |
| `download.copr.fedorainfracloud.org`   | starship COPR, redirects to the next row |
| `packages.redhat.com`                  | where COPR content actually lives |
| `packages.microsoft.com`               | VS Code                         |
| `dl.k8s.io`                            | kubectl                         |
| `github.com`                           | argocd, ot                      |
| `release-assets.githubusercontent.com` | GitHub release assets           |
| `storage.googleapis.com`               | tiCrypt Connect                 |
| `galaxy.ansible.com`                   | Ansible collections, for the checks |

`download.copr.fedorainfracloud.org` serves a 301 to `packages.redhat.com`,
so allowing only the first is not enough. `scripts/dev-env-setup.sh` reports
which of these the current session can reach, following redirects so that
trap is caught.

dnf resolves the metalink to arbitrary third-party mirrors, so a named-host
allowlist cannot cover them. For that case pass `--dnf-baseurl`, which pins
dnf to one mirror and disables `fedora-cisco-openh264`, whose RPMs are served
over plain **HTTP** and cannot traverse an HTTPS proxy. A proxy that
re-terminates TLS also needs its CA, or the GitHub downloads fail with
`curl: (60)`:

```bash
EXTRA_BUILD_ARGS="--network=host --build-arg https_proxy=$HTTPS_PROXY --build-arg HTTPS_PROXY=$HTTPS_PROXY" \
scripts/build-image.sh developer-platform-dev --smoke \
  --dnf-baseurl https://dl.fedoraproject.org/pub/fedora/linux \
  --proxy-ca /root/.ccr/agent-proxy-ca.crt
```

Both change what is built, so `DNF_BASEURL` and `PROXY_CA_CERT` default to
empty and `scripts/validate.sh` checks they stay that way.
