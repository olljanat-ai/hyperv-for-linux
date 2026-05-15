# hyperv-for-linux

This repository produces the artifacts needed to run Microsoft Hyper-V on a
Linux host (not "Linux as a Hyper-V guest" – the opposite direction). The
target host distribution is **Ubuntu 26.04 LTS**.

It exists because the binaries Microsoft publishes for Azure Linux
(`https://packages.microsoft.com/azurelinux/3.0/prod/non-oss/`) are not
directly consumable on Debian/Ubuntu systems, and Ubuntu's stock kernel does
not enable the configuration options that the Microsoft Hypervisor root
partition driver needs. The discussion that motivated this work is in
`microsoft/azurelinux#10996` (binaries to document) and `microsoft/azurelinux#6427`
(documenting `/dev/mshv`).

## End-user deliverable

**A signed Ubuntu apt repository, hosted on this repo's `gh-pages` branch
via GitHub Pages, exposing exactly two packages:**

| Package              | What it ships                                            |
| -------------------- | -------------------------------------------------------- |
| `linux-image-hyperv` | The Hyper-V capable Ubuntu 26.04 kernel (`MSHV_ROOT`+) . |
| `hyperv`             | Microsoft Hypervisor binaries + firmware + boot wiring. |

End users install both with:

```bash
curl -fsSL https://<gh-pages-host>/public.key \
  | sudo tee /etc/apt/keyrings/hyperv-for-linux.gpg >/dev/null
echo "deb [signed-by=/etc/apt/keyrings/hyperv-for-linux.gpg] \
  https://<gh-pages-host> stable main" \
  | sudo tee /etc/apt/sources.list.d/hyperv-for-linux.list
sudo apt-get update
sudo apt-get install linux-image-hyperv hyperv
```

`linux-headers-*-hyperv` and `linux-libc-dev` are built but only published
as workflow artifacts – they aren't part of the two-package end-user
deliverable.

## Architecture

Two build workflows produce `.deb` files; a single composite action
publishes them to the apt repo:

```
.github/workflows/build-kernel.yml ─┐
                                    ├──► .github/actions/publish-apt
.github/workflows/build-packages.yml ┘            │
                                                  ▼
                                         gh-pages branch
                                         (apt repository,
                                          served via GitHub Pages)
```

Both workflows share `concurrency: apt-repo-publish` so two simultaneous
publishes never clobber each other; the action also retries pushes with
rebase on conflict.

### Apt repo layout (on `gh-pages`)

```
public.key                 # GPG public key, ASCII-armored
public.gpg                 # GPG public key, binary form
index.html                 # human-readable landing page with install snippet
dists/
  stable/
    InRelease              # inline-signed
    Release                # detached signed via Release.gpg
    Release.gpg
    main/binary-amd64/
      Packages
      Packages.gz
      Release
pool/main/
  l/linux-image-hyperv/linux-image-*-hyperv_*_amd64.deb
  h/hyperv/hyperv_*_amd64.deb
```

Suite is named `stable` (codename-free) so it doesn't break when the
Ubuntu codename shifts.

### Repository layout (this branch)

```
.github/
  workflows/
    build-kernel.yml     # Builds linux-image-*-hyperv .deb
    build-packages.yml   # Builds hyperv .deb (from Azure Linux non-oss RPMs)
  actions/
    publish-apt/         # Composite action: signs + publishes to gh-pages
packaging/
  kernel/
    config.fragment      # CONFIG_* additions merged into Ubuntu kernel config
    patches/             # <NN>-<subject>.patch files, applied with git am --3way
  hyperv/
    debian/control.in    # reference Debian source-package control file
    scripts/             # postinst / postrm loader registration helpers
README.md
CLAUDE.md                # this file
```

## Required GitHub secrets

| Secret                  | Purpose                                                |
| ----------------------- | ------------------------------------------------------ |
| `APT_GPG_PRIVATE_KEY`   | ASCII-armored private key used to sign `Release`.     |
| `APT_GPG_PASSPHRASE`    | Passphrase for the key, empty if unprotected.          |

The matching public key is exported by the composite action and committed
to the repo root on `gh-pages` as `public.key` / `public.gpg`.

## Workflow conventions

- Triggers: `workflow_dispatch` + weekly `schedule` (so new Microsoft
  drops are picked up) + `push` filtered to `.github/workflows/**` and
  `packaging/**` (so config / script changes get rebuilt).
- Runners: `ubuntu-24.04` (large disk; kernel builds need ~30 GB free).
- Cache `ccache` keyed on kernel version + config-fragment hash; full
  kernel build is otherwise unreasonably slow.
- Every successful run uploads `.deb`s as workflow artifacts before
  publishing, so a failed publish step still leaves a debuggable build.
- Failure must be loud: missing patch, missing RPM, or missing config
  symbol all `exit 1` with `::error::` output rather than silently
  continuing.

## Kernel build conventions

- **Source: Ubuntu archive, not upstream kernel.org.** The workflow runs
  inside an `ubuntu:latest` container (override with the `ubuntu_image`
  input — e.g. `ubuntu:rolling`, `ubuntu:questing`), enables `deb-src`,
  runs `apt-get source linux`, and builds from the resulting tree which
  already has all Ubuntu quilt patches applied. This means our kernel
  tracks Ubuntu's CVE/HWE revisions instead of plain mainline.
- Container codename is read at runtime from `/etc/os-release`
  (`UBUNTU_CODENAME`) and used as the series identifier in tags and
  artifact names. There is no hard-coded codename anywhere — switching
  to a future Ubuntu release is just `ubuntu_image: ubuntu:<codename>`.
- Seed config from the Ubuntu source tree itself
  (`debian.master/config/amd64/config.flavour.generic`, falling back to
  `debian/config/...` or `x86_64_defconfig`). Strip module signing /
  trusted-keys / revocation-keys options — we don't have those keys in
  CI.
- Apply `packaging/kernel/config.fragment` on top using
  `scripts/kconfig/merge_config.sh`, then `make olddefconfig`. Required
  symbols (verified to be set after merge, build aborts if not):
  - `CONFIG_HYPERV=y`
  - `CONFIG_HYPERV_VSOCKETS=y`
  - `CONFIG_MSHV_ROOT=m`
  - all standard Hyper-V netvsc / storvsc / balloon / utils drivers
  - VFIO + intel/amd IOMMU on by default
- `CONFIG_HYPERV_VTL_MODE` must stay **off**. Upstream's Kconfig marks
  `MSHV_ROOT` as `depends on !HYPERV_VTL_MODE`, so flipping VTL_MODE on
  silently drops MSHV_ROOT during `make olddefconfig`. VTL_MODE is for
  booting Linux as the OpenHCL paravisor (the *guest* side under VTL2),
  which is the opposite of what this repo ships.
- **Vendored patches**: every file under `packaging/kernel/patches/`
  matching `*.patch` is applied on top of the Ubuntu tree with
  `git am --3way`, in lexical order, **before** the config seed/merge.
  Today that's just `0001-efi-Support-Microsoft-Hypervisor-Loader.patch`
  (cherry-picked from `olljanat/linux@4266b001`); without it the EFI
  stub cannot hand off to `hvloader.efi`, so the resulting kernel can't
  actually boot under Microsoft Hypervisor. New patches go in the same
  directory using the `<NN>-<subject>.patch` naming convention; the
  workflow auto-discovers them.
- Build with `make bindeb-pkg LOCALVERSION=-hyperv KDEB_PKGVERSION=
  <ubuntu-source-version>+hyperv1` so the `.deb` is named
  `linux-image-X.Y.Z-hyperv` and its version sorts above the stock
  Ubuntu kernel of the same release.

## Auto-rebuild on new Ubuntu kernel

- The kernel workflow runs on `schedule: 0 */6 * * *` (every 6 hours).
- Each run runs `apt-cache showsrc linux` to find the current version of
  the `linux` source package in the container's series and computes a
  dedupe tag `kernel/<series>/<sanitised-version>`.
- If the tag already exists (locally or on the remote) the run exits
  early without building. Otherwise it builds, publishes to the apt
  repo, then pushes the tag — so the *next* scheduled run will see the
  tag and skip again. Net effect: one build per new Ubuntu kernel
  publish, automatically.
- `workflow_dispatch` accepts a `force: true` input to override the
  dedupe check (useful when iterating on the patch or config fragment).

## When a vendored patch stops applying

Ubuntu's tree drifts. When `git am --3way` of a `packaging/kernel/
patches/*.patch` fails against a freshly-published Ubuntu kernel, the
workflow:

1. Captures the `git am` output, every `.rej` file, and the conflicting
   patch under `patch-logs/git-am.log`, uploaded as the
   `patch-logs-<series>-<version>` workflow artifact.
2. Opens a GitHub issue titled `kernel: patch <name> fails on Ubuntu
   <series> linux <version>` with the tail of the log inline. The issue
   is labelled `kernel-patch-fail` and `automated`.
3. On subsequent scheduled runs that hit the same failure, it finds the
   existing open issue by exact title match and adds a comment with the
   new run URL instead of opening a duplicate.

Resolving the failure is manual: pull down the source as the workflow
sees it, refresh the offending patch with `git am --reject` +
`wiggle` / hand-edit, replace the file under `packaging/kernel/patches/`,
and close the issue. The next scheduled run will pick up the new patch
and (if it applies) tag + publish a fresh `linux-image-hyperv` deb.

## `hyperv` package conventions

**The `.deb` ships NO Microsoft binaries** — it is a *meta-package*.
Redistributing the closed-source Hyper-V bits inside our own apt repo
would violate Microsoft's license (issue #6), so the binaries are
fetched by the end-user at install time, on their own machine, where
they implicitly accept the Microsoft license.

- The workflow only *scrapes* upstream feeds to learn the latest RPM
  URLs:
  - `https://packages.microsoft.com/azurelinux/3.0/prod/base/x86_64/Packages/h/`
    for `hvloader`
  - `https://packages.microsoft.com/azurelinux/3.0/prod/ms-non-oss/x86_64/Packages/m/`
    for `mshv-bootloader-lx` and `mshv`
- It pins the resolved URLs into `urls/sources.conf` and ships only
  that manifest plus the maintainer scripts. If Microsoft adds more
  RPMs, extend `MS_BASE_RPMS` / `MS_NON_OSS_RPMS` in
  `build-packages.yml`.
- A CI guard fails the build if a `.efi`, `.bin`, or `.so` file ever
  appears inside the resulting `.deb`.
- Payload (entirely scripts + config, no upstream binaries):
  - `/usr/lib/hyperv/download-binaries.sh`     – postinst-time fetcher
  - `/usr/lib/hyperv/register-loader.sh`       – boot hook
  - `/usr/lib/hyperv/unregister-loader.sh`     – boot hook
  - `/usr/lib/hyperv/sources.conf`             – pinned RPM URLs
- Maintainer scripts:
  - `postinst configure`: `download-binaries.sh` (curl + bsdtar to
    extract RPMs straight onto `/`) then `register-loader.sh`.
  - `prerm remove`: `unregister-loader.sh`.
  - `postrm remove|purge`: scrubs the non-dpkg-owned files the
    postinst pulled down (`HvLoader.efi`, `/usr/lib/firmware/hyperv/`,
    …).
- Runtime dependencies: `systemd, curl, ca-certificates,
  libarchive-tools` — `bsdtar` (from `libarchive-tools`) handles the
  RPM extraction so we don't need to pull in `rpm`.
- Package version mirrors the upstream `mshv` RPM `Version-Release`
  with a `~ms1` suffix so `apt upgrade` picks up new drops
  automatically: each weekly workflow run regenerates `sources.conf`
  with whatever's newest upstream, and the resulting `.deb` version
  bumps in lockstep.

## Development branch

All work happens on `claude/hyper-v-kernel-workflows-NmtKT`. Push there;
never push to `main` directly. The published apt repo lives on
`gh-pages`, which is managed only by the publish-apt action – don't
hand-edit it.

## Out of scope (for now)

- Secure Boot signing – the hypervisor binary is already MS-signed; the
  kernel is unsigned. Users who need Secure Boot must sign with their own
  MOK.
- Anything ARM64. x86_64 first; ARM64 can follow once the x86_64 pipeline
  is stable.
- A `linux-headers-hyperv` or `-dbg` package in the apt repo. Both build
  but only ship as workflow artifacts.
