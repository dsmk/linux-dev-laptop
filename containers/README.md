# Container images

Two images are built from one `Containerfile`, differing only in which package
list they layer on top of the shared one:

| Flavour     | Published as                                    | Entered with                              |
| ----------- | ----------------------------------------------- | ----------------------------------------- |
| `toolbx`    | `ghcr.io/dsmk/developer-platform-dev`           | `toolbox enter --container dev`           |
| `distrobox` | `ghcr.io/dsmk/developer-platform-distrobox`     | `distrobox enter dev-distrobox`           |

Both are multi-arch (`amd64`, `arm64`) and carry
`com.github.containers.toolbox=true`, so either one can also be used by the
other tool if needed.

## Layout

```
containers/
├── build.sh                 the only supported way to build
├── dev/
│   ├── Containerfile        shared by both flavours, selected by FLAVOR
│   └── podman.sh            /etc/profile.d snippet for the host podman socket
└── packages/
    ├── common.txt           installed in every flavour
    ├── toolbx.txt           extra packages for toolbx
    └── distrobox.txt        extra packages for distrobox
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

`--smoke` runs `tests/smoke-container.sh` inside the result, which checks that
every tool the flavour promises is present and starts. `build.sh --help` lists
the remaining options (`--arch`, `--tag`, `--base`, `--engine`, `--push`,
`--dry-run`).

Podman is used when installed, otherwise Docker. CI uses Podman.

## Changing what is installed

* A package from Fedora, COPR or the VS Code repository: add it to
  `packages/common.txt` (both flavours) or to the flavour's own list. Keep each
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

| Host                                 | For                            |
| ------------------------------------ | ------------------------------ |
| `registry.fedoraproject.org`         | the `fedora-toolbox` base image |
| `mirrors.fedoraproject.org`          | dnf metalink                   |
| `download.fedoraproject.org`         | dnf packages                   |
| `copr.fedorainfracloud.org`          | starship COPR metadata         |
| `download.copr.fedorainfracloud.org` | starship COPR packages         |
| `packages.microsoft.com`             | VS Code                        |
| `dl.k8s.io`                          | kubectl                        |
| `github.com`                         | argocd, ot                     |
| `objects.githubusercontent.com`      | GitHub release assets          |

`scripts/dev-env-setup.sh` reports which of these the current session can
reach. When `registry.fedoraproject.org` is unreachable but Docker Hub is,
`--base docker.io/library/fedora:44` gets a build started, at the cost of
losing the toolbox base layer — use it for experiments, not for anything
published.

## Publishing

`.github/workflows/dev-image.yml` builds all four combinations
(2 flavours × 2 architectures) on native runners, smoke tests each one, pushes
`<image>:<sha>-<arch>`, then assembles and pushes a multi-arch manifest as
`<image>:<sha>` and `<image>:main`. Pull requests build and test but do not
push.
