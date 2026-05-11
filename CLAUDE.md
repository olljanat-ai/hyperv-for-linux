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

## Two deliverables

1. **A Hyper-V capable Ubuntu 26.04 kernel** (`.deb`) – a custom-built kernel
   with the `MSHV_ROOT` and related driver options enabled so the host can
   open `/dev/mshv` and run guests via OpenVMM / Cloud Hypervisor.
2. **`hyperv-*` install / update `.deb` packages** – wrap the closed-source
   Microsoft Hypervisor binaries (`hypervisor`, `hyperv-firmware`, etc.) from
   the Azure Linux 3.0 `non-oss` repo into Debian packages that drop the
   files into the right place on disk, register an EFI/`systemd-boot` entry,
   and handle upgrades cleanly.

Both deliverables are produced by GitHub Actions workflows under
`.github/workflows/` and published as workflow artifacts and (optionally) as
GitHub Releases.

## Repository layout

```
.github/workflows/
  build-kernel.yml       # Builds the Ubuntu 26.04 Hyper-V kernel .debs
  build-packages.yml     # Builds hyperv-* install/update .debs
packaging/
  kernel/
    config.fragment      # CONFIG_* additions merged into Ubuntu kernel config
  hyperv/
    debian/              # debian/ skeleton for the hyperv meta package
    scripts/             # postinst / postrm / loader registration helpers
README.md
CLAUDE.md                # this file
```

The `packaging/` tree is filled in by the workflows or committed as a
skeleton. Workflows are the source of truth for "how to build"; anything
ad-hoc should land there, not in undocumented local scripts.

## Workflow conventions

- Trigger every workflow on `workflow_dispatch` plus a weekly `schedule` so
  freshly published Microsoft binaries get picked up automatically. Build on
  `push` only when files under `.github/workflows/` or `packaging/` change –
  kernel builds are slow.
- Use `ubuntu-24.04` or `ubuntu-latest` runners with `KVM`/large disk for
  kernel builds (compilation is heavy; the workflow installs `build-essential`,
  `libncurses-dev`, `bison`, `flex`, `libssl-dev`, `libelf-dev`, `dwarves`,
  `rsync`, `kmod`, `cpio`).
- Cache `ccache` between runs (`actions/cache@v4`, key on kernel version +
  config hash) to make iterative builds reasonable.
- Publish every successful build as a workflow artifact. Tagged builds also
  create a GitHub Release with the `.deb` files attached.
- Pin tool versions where possible – Microsoft binary URLs and Ubuntu kernel
  source URLs both move. Failures should be obvious, not silent.

## Kernel build conventions

- Source: Ubuntu 26.04's kernel git (`git://git.launchpad.net/~ubuntu-kernel/...`)
  or `linux-source-*` from the archive. Fall back to upstream stable
  (`linux-stable`) at the same `Major.Minor` if Ubuntu hasn't published yet.
- Apply `packaging/kernel/config.fragment` on top of Ubuntu's default config
  using `scripts/kconfig/merge_config.sh`. Required options at minimum:
  - `CONFIG_HYPERV=y`
  - `CONFIG_HYPERV_VSOCKETS=y`
  - `CONFIG_MSHV_ROOT=m`
  - `CONFIG_HYPERV_VTL_MODE=y` (where applicable)
  - all standard Hyper-V netvsc / storvsc / balloon / utils drivers
- **Mandatory patch**: cherry-pick `olljanat/linux@4266b001` ("efi: Support
  Microsoft Hypervisor Loader") on top of the source tree. Without this the
  EFI stub cannot hand off to / receive control from `hvloader.efi` and the
  resulting kernel will not boot under Microsoft Hypervisor. This must be
  applied **before** `make olddefconfig`; the patch adds new Kconfig symbols
  the merge needs to see.
- Package with `make bindeb-pkg` and rename the package flavour to `hyperv`
  (e.g. `linux-image-6.x.y-hyperv_*.deb`) so it can coexist with the stock
  Ubuntu kernel.
- Strip debug info from the runtime `.deb`; publish the matching
  `linux-image-*-dbg` separately.

## hyperv-* package conventions

- The closed-source bits come from
  `https://packages.microsoft.com/azurelinux/3.0/prod/non-oss/` (RPMs).
  Download, verify the Microsoft repo GPG signature, then extract with
  `rpm2cpio | cpio` – do **not** ship `rpm`-installed payloads.
- Build three Debian packages:
  - `hyperv-hypervisor` – the hypervisor binary itself under
    `/usr/lib/hyperv/`.
  - `hyperv-firmware` – firmware blobs needed at boot.
  - `hyperv` – meta-package that depends on the two above plus the custom
    kernel, and runs `postinst` to register a `systemd-boot` / `grub` entry
    that chainloads the hypervisor.
- Upgrades must not break the running boot entry. `postinst` regenerates the
  loader config; `prerm` removes only the entry it added (track it by name).
- Version each package from the upstream RPM's `Version-Release` so
  `apt upgrade` picks up new Microsoft drops automatically.

## Development branch

All work happens on `claude/hyper-v-kernel-workflows-NmtKT`. Push there;
never push to `main` directly.

## Out of scope (for now)

- A `.deb` repository / `apt` source – consumers download `.deb`s from
  Releases and `dpkg -i` them manually.
- Secure Boot signing – the hypervisor binary is already MS-signed; the
  kernel is unsigned. Users who need Secure Boot must sign with their own MOK.
- Anything ARM64. x86_64 first; ARM64 can follow once the x86_64 pipeline is
  stable.
