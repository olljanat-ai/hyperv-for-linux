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

**A signed Ubuntu apt repository, hosted entirely on GitHub** — the
repo's `gh-pages` branch is served by GitHub Pages at
`https://<owner>.github.io/<repo>/`. Source, build pipelines, signing
key (private half as a secret, public half published alongside the
metadata), and the apt indexes all live in this same GitHub repository.

For `olljanat-ai/hyperv-for-linux` the public URL is
**`https://olljanat-ai.github.io/hyperv-for-linux/`**. Substitute your
own fork's owner/name below if you re-host.

Two packages:

| Package              | Contents                                                  |
| -------------------- | --------------------------------------------------------- |
| `linux-image-hyperv` | Ubuntu's own kernel rebuilt with `MSHV_ROOT` + Hyper-V drivers, plus the mandatory MSHV EFI loader patch. |
| `hyperv`             | Meta-package whose `postinst` downloads Microsoft Hypervisor + firmware from `packages.microsoft.com/azurelinux/3.0/prod/` on the target machine, extracts them locally, and registers a `systemd-boot` entry. Ships no Microsoft binaries itself. |

## Installing

```bash
REPO_URL="https://olljanat-ai.github.io/hyperv-for-linux"   # change for your fork

# Trust the signing key
sudo install -d /etc/apt/keyrings
curl -fsSL "$REPO_URL/public.key" \
  | sudo tee /etc/apt/keyrings/hyperv-for-linux.gpg >/dev/null

# Add the repository
echo "deb [signed-by=/etc/apt/keyrings/hyperv-for-linux.gpg] $REPO_URL stable main" \
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

### Hyper-V meta-package pipeline (`build-packages.yml`)

- Scrapes the Azure Linux 3.0 `base/` and `ms-non-oss/` repos for the
  newest `hvloader`, `mshv-bootloader-lx`, and `mshv` RPMs — but only
  to **resolve their URLs**, never to download or repackage the
  payloads. Doing so on our infrastructure would violate Microsoft's
  redistribution terms (see issue #6).
- Emits a single `hyperv` `.deb` that ships only the maintainer
  scripts (`download-binaries.sh`, `register-loader.sh`,
  `unregister-loader.sh`) and the resolved URLs in `sources.conf`.
  A CI guard fails the build if a `.efi` / `.bin` / `.so` file
  somehow appears inside the `.deb`.
- On the target machine, `postinst` runs `download-binaries.sh`
  (which `curl`s the pinned RPMs and extracts them with `bsdtar`
  straight onto `/`), then `register-loader.sh` to copy
  `HvLoader.efi` onto the ESP and write a `systemd-boot` entry.
- `postrm` scrubs the downloaded binaries on `remove` / `purge`.
- Versioning mirrors the upstream `mshv` RPM `Version-Release` with a
  `~ms1` suffix; a weekly workflow run regenerates `sources.conf` and
  the `.deb` version, so `apt upgrade` picks up new Microsoft drops
  automatically.

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
    debian/                # control.in + postinst / prerm / postrm
    scripts/               # download-binaries + boot-loader register/unregister
scripts/
  generate-signing-key.sh  # One-shot apt-repo signing-key generator
README.md
CLAUDE.md                  # Detailed engineering conventions
```

The published apt repo lives on the `gh-pages` branch with this layout:

```
public.key, public.gpg     # apt-repo signing key (public half)
index.html                 # human-readable landing page (auto-generated)
.nojekyll                  # tell Pages not to mangle the tree
dists/stable/
  InRelease                # inline-signed
  Release, Release.gpg     # detached-signed
  main/binary-amd64/{Packages,Packages.gz,Release}
pool/main/
  l/linux-image-hyperv/*.deb
  h/hyperv/*.deb
```

## Setup (one-time, repo owner)

Everything is hosted on GitHub; you just need to (a) give the workflows
a signing key and (b) point GitHub Pages at the branch the workflows
write to.

### 1. Generate the signing key

A helper script is included:

```bash
# Make sure you've authenticated gh against this repo first.
gh auth status
gh repo set-default

# Generate a fresh key and upload it to repository secrets in one shot.
./scripts/generate-signing-key.sh
```

This:

- Creates an RSA-4096 key in a throwaway `GNUPGHOME` (no passphrase, no
  pollution of your real keyring).
- Uploads the ASCII-armored private half to the
  `APT_GPG_PRIVATE_KEY` repository secret via `gh secret set`.
- Sets `APT_GPG_PASSPHRASE` to the empty string.
- Prints the public key. You can ignore it — the publish workflow
  re-exports it to `<pages-url>/public.key` on every run.

If you'd rather do it manually:

```bash
# Generate the key (interactive prompts)
gpg --full-generate-key            # pick RSA 4096, never expires, no passphrase

KEY_ID=<the_id_gpg_printed>
gpg --armor --export-secret-keys "$KEY_ID" > private.asc

# Push to repo secrets
gh secret set APT_GPG_PRIVATE_KEY < private.asc
gh secret set APT_GPG_PASSPHRASE  --body ""

# Wipe the private key from disk
shred -u private.asc
```

If your key has a passphrase, put it in `APT_GPG_PASSPHRASE` instead of
the empty string and the workflow will pass it through to `gpg --batch
--passphrase`.

The two secrets the workflows read:

| Secret                | Purpose                                                |
| --------------------- | ------------------------------------------------------ |
| `APT_GPG_PRIVATE_KEY` | ASCII-armored GPG private key used to sign `Release`. |
| `APT_GPG_PASSPHRASE`  | Passphrase, empty string if unprotected.               |

### 2. Enable GitHub Pages

In **Settings → Pages**, set the source to branch `gh-pages` /
`/ (root)`. The branch doesn't exist yet — the first successful run of
either build workflow creates it. After that the apt repo is live at
`https://<owner>.github.io/<repo>/`.

(If you want a custom domain, drop a `CNAME` file into the `gh-pages`
branch root. The publish action detects it and uses it in the
generated `index.html` install snippet.)

### 3. Trigger the first build

Either wait up to 6 hours for the kernel workflow's schedule, or push
the green button manually from **Actions → Build Hyper-V kernel
(Ubuntu) → Run workflow**. Same for the hyperv package workflow.

## Out of scope (today)

- Secure Boot signing — the hypervisor binary is already MS-signed; the
  kernel is unsigned. Users who need Secure Boot must sign with their
  own MOK.
- ARM64 — x86_64 first; ARM64 can follow once x86_64 is stable.
- `linux-headers-hyperv` / `-dbg` in the apt repo. Both are built but
  only ship as workflow artifacts.

## License

The repository itself is MIT-licensed (see `LICENSE`). No Microsoft
binaries are redistributed by this repo or by the `hyperv` `.deb` it
publishes; the `.deb` is a meta-package whose `postinst` downloads the
binaries from `packages.microsoft.com` directly onto your machine, so
the Microsoft license is the one you accept at install time, not via
us.
