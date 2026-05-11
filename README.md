# hyperv-for-linux

Run Microsoft Hyper-V on a Linux host. Targets **Ubuntu 26.04 LTS**.

This is the *opposite* direction from "Linux as a Hyper-V guest". The
host runs Linux; the Microsoft Hypervisor sits beside the Linux kernel
via the `MSHV` root-partition interface (`/dev/mshv`); guests are
launched with OpenVMM / Cloud Hypervisor.

Motivation and background:
[microsoft/azurelinux#10996](https://github.com/microsoft/azurelinux/issues/10996),
[microsoft/azurelinux#6427](https://github.com/microsoft/azurelinux/issues/6427).

## What you get

A signed Ubuntu apt repository, hosted on this repo's `gh-pages` branch
via GitHub Pages, exposing exactly two packages:

| Package              | Contents                                                  |
| -------------------- | --------------------------------------------------------- |
| `linux-image-hyperv` | Ubuntu's own kernel rebuilt with `MSHV_ROOT` + Hyper-V drivers, plus the mandatory MSHV EFI loader patch. |
| `hyperv`             | Microsoft Hypervisor binaries + firmware, repackaged from `packages.microsoft.com/azurelinux/3.0/prod/non-oss/`. Installs `hvloader.efi` onto the ESP and registers a `systemd-boot` entry. |

## Installing

```bash
# Trust the signing key
sudo install -d /etc/apt/keyrings
curl -fsSL https://<your-pages-host>/public.key \
  | sudo tee /etc/apt/keyrings/hyperv-for-linux.gpg >/dev/null

# Add the repository
echo "deb [signed-by=/etc/apt/keyrings/hyperv-for-linux.gpg] \
  https://<your-pages-host> stable main" \
  | sudo tee /etc/apt/sources.list.d/hyperv-for-linux.list

sudo apt-get update
sudo apt-get install linux-image-hyperv hyperv

# Reboot into the Microsoft Hypervisor entry that systemd-boot now lists.
sudo systemctl reboot
```

Once booted, `/dev/mshv` should be present and consumable by Cloud
Hypervisor / OpenVMM.

## How it works

Two GitHub Actions workflows produce the `.deb`s; a shared composite
action publishes them to the apt repo:

```
.github/workflows/build-kernel.yml ───┐
                                       ├──► .github/actions/publish-apt
.github/workflows/build-packages.yml ──┘            │
                                                    ▼
                                          gh-pages branch
                                          (apt repo, served via Pages)
```

Both workflows share `concurrency: apt-repo-publish` so two runs never
clobber each other; the publish action retries with rebase on conflict.

### Kernel pipeline (`build-kernel.yml`)

- Runs inside an `ubuntu:latest` container (override with the
  `ubuntu_image` input).
- Enables `deb-src`, runs `apt-get source linux`. Ubuntu's quilt
  patches are already applied in the resulting tree.
- Applies every patch under `packaging/kernel/patches/*.patch` with
  `git am --3way` in lexical order. Today that's just
  `0001-efi-Support-Microsoft-Hypervisor-Loader.patch`
  (cherry-picked from `olljanat/linux@4266b001`).
- Seeds config from `debian.master/config/amd64/config.flavour.generic`,
  merges `packaging/kernel/config.fragment`
  (`MSHV_ROOT`, `HYPERV*`, `VFIO`, `INTEL/AMD_IOMMU`, …), runs
  `make olddefconfig`, and aborts loudly if any required symbol isn't
  set.
- Builds with `make bindeb-pkg LOCALVERSION=-hyperv
  KDEB_PKGVERSION=<ubuntu-source-version>+hyperv1` so the deb sorts
  above the stock Ubuntu kernel of the same release.
- Polls every 6 hours. Dedupe is by git tag
  `kernel/<series>/<sanitised-version>`; if the tag already exists, the
  run exits early. One build per new Ubuntu kernel publish, automatic.
- If a vendored patch stops applying against a fresh Ubuntu tree, the
  run opens (or comments on) a GitHub issue titled
  `kernel: patch <name> fails on Ubuntu <series> linux <version>`,
  attaches `git am` logs as an artifact, and tags it
  `kernel-patch-fail` + `automated`.

### Hyper-V binaries pipeline (`build-packages.yml`)

- Scrapes the Azure Linux 3.0 `non-oss` repo for the newest
  `hypervisor` and `hyperv-firmware` RPMs.
- Extracts the payloads with `rpm2cpio | cpio` — never installs.
- Re-emits a single `hyperv` `.deb` containing `/usr/lib/hyperv/`
  (hypervisor + loader scripts) and `/usr/lib/firmware/hyperv/`
  (firmware blobs). `postinst` copies `hvloader.efi` to the ESP and
  writes a `systemd-boot` entry.
- Versioning mirrors the upstream RPM `Version-Release` with a
  `~ms1` suffix so `apt upgrade` picks up new Microsoft drops
  automatically.
- Polls weekly.

## Repository layout

```
.github/
  workflows/
    build-kernel.yml       # Ubuntu-source kernel → linux-image-hyperv.deb
    build-packages.yml     # Azure Linux RPMs → hyperv.deb
  actions/
    publish-apt/           # Sign & publish .debs to gh-pages
packaging/
  kernel/
    config.fragment        # CONFIG_* additions
    patches/               # <NN>-<subject>.patch, applied with git am --3way
  hyperv/
    debian/control.in      # Reference Debian source-package control
    scripts/               # postinst / postrm loader registration
README.md
CLAUDE.md                  # Detailed engineering conventions
```

## Setup (one-time, repo owner)

The build workflows are self-contained, but publishing the apt repo
needs two repository secrets and GitHub Pages enabled:

| Secret                | Purpose                                                  |
| --------------------- | -------------------------------------------------------- |
| `APT_GPG_PRIVATE_KEY` | ASCII-armored GPG private key used to sign `Release`.   |
| `APT_GPG_PASSPHRASE`  | Passphrase for the key (empty string if unprotected).    |

Then in **Settings → Pages**, set the source to branch `gh-pages` /
`/ (root)`. The first successful publish creates the branch.

## Out of scope (today)

- Secure Boot signing — the hypervisor binary is already MS-signed; the
  kernel is unsigned. Users who need Secure Boot must sign with their
  own MOK.
- ARM64 — x86_64 first; ARM64 can follow once x86_64 is stable.
- `linux-headers-hyperv` / `-dbg` in the apt repo. Both are built but
  only ship as workflow artifacts.

## License

The repository itself is MIT-licensed (see `LICENSE`). The repackaged
Microsoft binaries retain their original Microsoft licensing; you are
the one accepting that license when you install the `hyperv` package.
