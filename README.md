# sfx14-gpu

Put the NVIDIA dGPU in an Optimus laptop into D3cold when nothing uses it, and
wake it for games. Built for the Acer Swift X 14 (SFX14-72G), usable on other
Optimus laptops without a MUX switch.

```console
$ sfx14-gpu status
GPU:            0000:01:00.0 (NVIDIA GeForce RTX 4050 Laptop GPU)
runtime_status: suspended
power/control:  auto
persistence:    unavailable
clocks:         unavailable
Runtime D3:     Enabled (fine-grained)
video memory:   Active
compositor:     Hyprland (pid 2388, AQ_DRM_DEVICES=/dev/dri/card0)
clients:        none
dGPU suspended (D3cold)
```

## This laptop has no MUX switch

A MUX switch is a hardware multiplexer that rewires the internal panel between
the integrated GPU and the discrete GPU. Laptops with one can run "dGPU only":
the iGPU is powered down and the panel is driven by NVIDIA.

The SFX14-72G does not have one. Its internal panel (`eDP-1`) is wired to the
Intel Meteor Lake-P iGPU, and `acer-wmi` exposes no graphics switch. The RTX
4050 Mobile can render offscreen for the iGPU (PRIME render offload) and drive
the HDMI output, but it cannot drive the built-in panel.

That is exactly why D3cold matters: when nothing uses the dGPU it can be fully
powered off, and the iGPU keeps driving the panel. Opening `/dev/nvidia*`
wakes it again automatically.

## Why the dGPU stays awake

Three independent things keep the RTX 4050 out of D3cold. All three must be
gone before `power/runtime_status` reads `suspended`.

| Blocker | What holds it | How to clear it |
| --- | --- | --- |
| Client | A process with `/dev/nvidia0`, `/dev/nvidiactl` or `/dev/nvidia-uvm` open (a CUDA app, a game, sometimes the compositor) | Stop the application. This tool never kills it. |
| Persistence mode | `nvidia-smi -pm 1` keeps the driver and GPU initialized | `nvidia-smi -pm 0` (`sfx14-gpu off`) |
| Compositor DRM enumeration | Hyprland and Xwayland open the NVIDIA DRM nodes at startup even with no game running | Restart the compositor with `AQ_DRM_DEVICES` pointing at the iGPU only |

`sfx14-gpu status` walks `/proc/*/fd` (best effort, root sees more), reads
`nvidia-smi` persistence mode, and maps `/sys/class/drm/card*` back to the
NVIDIA BDF. It prints one verdict line:

- `dGPU suspended (D3cold)`
- `dGPU active — held by <list>`

When the GPU is suspended, `nvidia-smi` cannot talk to it. That error is the
correct idle state, not a fault.

## Power

| State | `nvidia-smi` power.draw | `runtime_status` |
| --- | --- | --- |
| Held awake (idle desktop, persistence on) | ~4.9 W measured | `active` |
| After `sfx14-gpu off` | — (device unreachable) | `suspended` |

Expected after: the dGPU contributes roughly **0 W** at D3cold, so about the
same 4.9 W disappears from idle. D3cold power is not exposed by `nvidia-smi`;
confirm with `runtime_status` and, if you want a number, a wall meter.

## Install

Only two destinations are used: `/usr/local/bin` and `/etc/systemd/system`.

```sh
sudo install -Dm755 bin/sfx14-gpu /usr/local/bin/sfx14-gpu
sudo install -Dm644 systemd/sfx14-gpu-off.service /etc/systemd/system/sfx14-gpu-off.service
sudo install -Dm644 systemd/sfx14-gpu-game.service /etc/systemd/system/sfx14-gpu-game.service
sudo systemctl daemon-reload
sudo systemctl enable --now sfx14-gpu-off.service
```

`sfx14-gpu-off.service` is a oneshot unit that runs `sfx14-gpu off` at boot,
after `multi-user.target` and before a graphical login. If a client already
holds the GPU it refuses, logs the reason and exits non-zero; it does not kill
anything.

`sfx14-gpu-game.service` applies the clock cap. It has no `[Install]` section
on purpose: enabling it would pin clocks all the time. Start and stop it around
a gaming session:

```sh
sudo systemctl start sfx14-gpu-game.service
sudo systemctl stop sfx14-gpu-game.service
```

## Commands

```sh
sfx14-gpu status                 # read-only state and verdict
sfx14-gpu status --json          # machine-readable form
sudo sfx14-gpu off               # disable persistence, wait for D3cold
sudo sfx14-gpu off --force       # skip only the "already off" check
sudo sfx14-gpu on                # load modules if needed, nvidia-smi -pm 1
sudo sfx14-gpu on --no-persist   # wake without enabling persistence
sudo sfx14-gpu game on           # -pm 1, clocks 210-1540 MHz, +200 MHz VF offset
sudo sfx14-gpu game off          # -rgc, -pm 0
sfx14-gpu --dry-run off          # print planned commands, run nothing
```

`off` refuses if a client or the compositor holds the GPU, then disables
persistence and polls `runtime_status` for up to 10 seconds. If it does not
reach `suspended`, it prints the remaining holders and the exact next step
(stop the app, restart the compositor).

`game on` also applies a +200 MHz GPC VF offset when `python-nvidia-ml-py` is
importable. Without that package it skips the offset quietly and still sets the
clock cap.

`--dry-run` may appear anywhere and affects `off`, `on` and `game`. `off
--dry-run` still runs the safety checks first, so it refuses while a client or
compositor holds the GPU.

## Compositor note

Hyprland reads `AQ_DRM_DEVICES` once, at startup, and then opens only the
listed DRM cards. Put the **iGPU** card there and restart the compositor
(log out and back in; `hyprctl reload` is not enough):

```sh
export AQ_DRM_DEVICES=/dev/dri/card0
Hyprland
```

or in `hyprland.conf`:

```ini
env = AQ_DRM_DEVICES,/dev/dri/card0
```

DRM card numbers are assigned at probe time and are **not stable across
boots**. On the reference machine the iGPU has been both `card0` and `card1`.
Pick the card whose `device` link resolves to the Intel BDF:

```sh
for c in /sys/class/drm/card*/device; do
  printf '%s -> %s\n' "$c" "$(basename "$(readlink -f "$c")")"
done
lspci -Dn | grep 8086
```

`sfx14-gpu` derives this itself and prints the right path in its refusals.

## Safety

- `status` is read-only.
- `off` never kills processes. It refuses while a client or an unconfigured
  compositor holds the GPU.
- `--force` skips only the "already suspended" shortcut, never the client or
  compositor safety checks.
- The tool never unloads kernel modules and never writes to sysfs
  `power/control`. It only toggles persistence and clocks through
  `nvidia-smi`.
- `/proc/*/fd` is world-readable only for your own processes. Run `status`
  with `sudo` to see every holder.
- Do not install the `off` unit together with a service that keeps a CUDA
  client running at boot; the unit will refuse and report why.

## Tested on

- Acer Swift X 14 `SFX14-72G`: Intel Meteor Lake-P iGPU + NVIDIA GeForce RTX
  4050 Laptop GPU, `nvidia-open-dkms` 615.78, Hyprland.
- The approach applies to other Optimus laptops without a MUX switch. BDF and
  iGPU card are detected automatically; the compositor override name
  (`AQ_DRM_DEVICES`) is Hyprland-specific, and the holder checks still work
  for other compositors.

## Development

The suite runs without a GPU by replacing sysfs, `/proc` and the binaries:

```sh
test/run.sh
shellcheck -x bin/sfx14-gpu test/*.sh
bash -n bin/sfx14-gpu test/*.sh
```

`SFX14_SYSFS`, `SFX14_PROC`, `SFX14_NVIDIA_SMI`, `SFX14_LSPCI`,
`SFX14_MODPROBE`, `SFX14_PYTHON`, `SFX14_POLL_TIMEOUT` and
`SFX14_POLL_INTERVAL` exist for that purpose. CI runs the same commands on
Ubuntu with no NVIDIA hardware.

## License

MIT. See [LICENSE](LICENSE).
