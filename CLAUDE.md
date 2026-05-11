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

- Source: upstream stable from `cdn.kernel.org` (latest `stable` moniker
  from `releases.json`). Switching to Ubuntu's questing tree is an open
  item – the EFI loader patch hunks would need re-validating.
- Seed config from
  `kernel.ubuntu.com/~kernel-ppa/configs/questing/linux/amd64-config.flavour.generic`
  with module signing, trusted keys, and revocation keys stripped (we
  don't have those keys in CI).
- Apply `packaging/kernel/config.fragment` on top using
  `scripts/kconfig/merge_config.sh`, then `make olddefconfig`. Required
  symbols (verified to be set after merge):
  - `CONFIG_HYPERV=y`
  - `CONFIG_HYPERV_VSOCKETS=y`
  - `CONFIG_MSHV_ROOT=m`
  - `CONFIG_HYPERV_VTL_MODE=y` (where the tree exposes it)
  - all standard Hyper-V netvsc / storvsc / balloon / utils drivers
  - VFIO + intel/amd IOMMU on by default
- **Mandatory patch**: `git am` `olljanat/linux@4266b001` ("efi: Support
  Microsoft Hypervisor Loader") on top of the source tree, applied
  **before** `make olddefconfig`. Without it the EFI stub cannot hand off
  to `hvloader.efi`, so the resulting kernel can't actually boot under
  Microsoft Hypervisor. This is required, not optional.
- Build with `make bindeb-pkg KDEB_PKGVERSION=...` and
  `LOCALVERSION=-hyperv` so the `.deb` is named `linux-image-X.Y.Z-hyperv`
  and coexists cleanly with the stock Ubuntu kernel.

## `hyperv` package conventions

- Source RPMs come from
  `https://packages.microsoft.com/azurelinux/3.0/prod/non-oss/x86_64/`.
  Repo is scraped (no real index); newest RPM by `sort -V` wins. The
  current list is `hypervisor` and `hyperv-firmware`; if Microsoft adds
  more, extend `MS_RPMS` in `build-packages.yml`.
- Extract with `rpm2cpio | cpio` – never `rpm -i`; we want the raw
  payload, not a system-level install.
- Single `.deb` named `hyperv`. Payload:
  - `/usr/lib/hyperv/`              – hypervisor binaries (`hvloader.efi`)
  - `/usr/lib/firmware/hyperv/`     – firmware blobs
  - `/usr/lib/hyperv/{register,unregister}-loader.sh` – boot hooks
- `postinst` runs `register-loader.sh`: copies `hvloader.efi` to
  `<ESP>/EFI/hyperv/` and writes a systemd-boot entry. `prerm` runs
  `unregister-loader.sh` and removes only what we wrote.
- Package version mirrors the upstream RPM `Version-Release` with a
  `~ms1` suffix so `apt upgrade` picks up new drops automatically.

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
