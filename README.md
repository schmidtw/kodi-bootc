# kodi-bootc

A [bootc](https://bootc-dev.github.io/bootc/) image that turns a PC into a
single-purpose Kodi appliance: power it on and it boots **straight into Kodi**
— no desktop, no display manager, no manual launch. Updates are atomic container
images you pull from a registry, and a broken update is one `bootc rollback`
away from the previous working OS.

Built for: **AMD Ryzen 5 5600G (Cezanne / Vega iGPU), x86_64.**

## Why this pattern

The old box was "always out of date and nearly always broken" because it was a
mutable Fedora install — every `dnf update` was a roll of the dice and there was
no clean undo. bootc flips that around:

- **The OS is an image**, built in CI and tested the same way every time. The box
  is never in a hand-mutated state.
- **Updates are atomic.** You boot into a new image or you don't; there's no
  half-applied update.
- **Rollback is free.** The previous image stays on disk; `bootc rollback` +
  reboot returns you to exactly what worked yesterday.
- **It's always current.** CI rebuilds weekly on the latest `fedora-bootc`
  base, so kernel/Mesa/codec/Kodi fixes flow out automatically.
- **Same mental model as your Rocky 10 + bootc work setup** — only the base
  layer differs (Fedora, for a fresh media stack).

## What's in the image

| Piece | Choice | Why |
|-------|--------|-----|
| Base | `quay.io/fedora/fedora-bootc` | Newest Kodi/Mesa; matches Fedora muscle memory |
| GPU | `amdgpu` + Mesa (in-tree) | AMD is fully open-source — no proprietary driver layering |
| Video decode | `mesa-va-drivers-freeworld` (RPMFusion) | Real HW VA-API decode: H.264/HEVC/VP9/AV1 |
| Kodi | RPMFusion `kodi`, GBM standalone | Boots direct to GUI, no X/Wayland desktop |
| Audio | ALSA (direct) | Most reliable for HDMI bitstream passthrough to an AVR |
| Launch | `kodi.service` on tty1 | systemd owns it: autostart, autorestart, no login |
| Updates | `bootc-fetch-apply-updates.timer` | Pull + stage new image, apply on next boot |

## Repository layout

```
Containerfile                         # the image definition
files/                                # overlaid onto the OS rootfs verbatim
  usr/lib/systemd/system/kodi.service #   the boot-to-Kodi service
  usr/lib/sysusers.d/kodi.conf        #   creates the unprivileged kodi user
  usr/lib/tmpfiles.d/kodi.conf        #   persistent /var/lib/kodi home
  etc/polkit-1/rules.d/10-kodi-power.rules  # reboot/shutdown from Kodi menu
  etc/yum.repos.d/tailscale.repo      #   Tailscale package repo
install/config.toml.example           # template; copy to install/config.toml (gitignored)
.github/workflows/build.yml           # CI: build + push to ghcr.io weekly
```

## Open source & secrets

This repo is meant to be **public**: public GitHub repos get free Actions and
free ghcr.io hosting, and a public image lets the box pull updates with **no
credentials**. The catch — and the rule — is that **a public image is
world-readable, so no secret may ever be baked into it or committed.**

Where secrets actually live:

| Secret | Lives in | In git? |
|--------|----------|---------|
| Console/sudo password, install user | `install/config.toml` (local install media) | **No** — gitignored |
| Tailscale auth | `/var/lib/tailscale` on the box (auth once interactively) | **No** — never leaves the box |
| ghcr.io push | GitHub's built-in `GITHUB_TOKEN` in CI | **No** — auto-provided |

So nothing sensitive is ever in the image layers or the repo.

## 1. Build & publish (CI)

Push this repo to GitHub. The workflow builds the image and pushes it to
`ghcr.io/<you>/kodi-bootc:latest` on every push to `main`, weekly, and on
manual dispatch. Make the package **public** (or configure a pull secret on the
box) so the appliance can pull without auth.

Build locally to test first:

```bash
podman build -t ghcr.io/<you>/kodi-bootc:latest .
```

## 2. First install (one time)

Generate install media from the image with **bootc-image-builder**. First copy
the template and set your console/sudo password:

```bash
cp install/config.toml.example install/config.toml
# edit install/config.toml — it's gitignored, so your secret stays local
```

Build a raw disk you can `dd` to the SSD, or swap `type=raw` for `iso` for a USB
installer:

```bash
sudo podman run --rm -it --privileged \
  --security-opt label=disable \
  -v ./install/config.toml:/config.toml:ro \
  -v ./output:/output \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type raw --config /config.toml \
  ghcr.io/<you>/kodi-bootc:latest

# then write output/image/disk.raw to the Kodi box's disk
```

> **Note:** you can't cleanly convert the in-place Fedora 41 install to bootc;
> a fresh install is the right move for a box that's "always broken." Back up
> `~/.kodi` first (next section).

## 3. Migrate your existing Kodi config

On the **old Fedora 41 box**, before wiping it:

```bash
sudo systemctl stop kodi 2>/dev/null
tar czf ~/kodi-backup.tar.gz -C ~ .kodi
# copy kodi-backup.tar.gz somewhere safe (NAS, USB, your workstation)
```

On the **new bootc box**, after first boot:

```bash
sudo systemctl stop kodi
sudo tar xzf /path/to/kodi-backup.tar.gz -C /var/lib/kodi --strip-components=0
sudo chown -R kodi:kodi /var/lib/kodi/.kodi
sudo systemctl start kodi
```

Your library, sources (NAS shares), add-ons, and settings carry straight over.

## 4. Remote access (Tailscale only)

There is **no openssh and nothing listening on port 22** — the only way in is
your tailnet. One-time setup, run from the **physical console** at the TV
(keyboard attached once):

```bash
sudo tailscale up --ssh
# follow the printed URL to authenticate the box into your tailnet
```

After that, from any device on your tailnet:

```bash
ssh schmidtw@kodi          # Tailscale serves SSH; auth via your tailnet ACLs
```

Tailscale's state lives in `/var/lib/tailscale`, which bootc keeps persistent —
so you authenticate once and it survives every image update and rollback.

## 5. Day-2 operations

```bash
bootc status            # what image am I on, is an update staged?
bootc upgrade           # pull latest now (or let the box's timer do it)
systemctl reboot        # apply a staged update
bootc rollback          # an update broke something? go back, then reboot
journalctl -u kodi -b   # Kodi logs this boot
```

Auto-updates are enabled (`bootc-fetch-apply-updates.timer`): the box pulls and
stages new images on a timer and applies them on the next reboot. Pair with a
scheduled weekly reboot if you want fully hands-off updates.

## Customization cheatsheet

- **NAS shares** — Kodi can mount SMB/NFS itself (recommended). For OS-level
  mounts, add `.mount` units under `files/etc/systemd/system/`.
- **CEC (TV remote control)** — `libcec` is installed; it needs CEC-capable
  hardware (most PCs need a Pulse-Eight USB-CEC adapter). Plug it in and enable
  the CEC peripheral in Kodi.
- **HDMI audio passthrough** — in Kodi: Settings → System → Audio, pick the
  HDMI ALSA device and enable passthrough for your AVR's codecs.
- **PVR / Jellyfin / Plex** — add `kodi-pvr-*` packages to the `Containerfile`,
  or install client add-ons from inside Kodi.
- **Bump Fedora** — change `FEDORA_VERSION` in the `Containerfile`; CI rebuilds,
  box upgrades on next pull. If it misbehaves, `bootc rollback`.
