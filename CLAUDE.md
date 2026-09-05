# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

BarBanker is a Nerves (embedded Elixir) app that turns a Raspberry Pi 4 into a bar/kiosk point-of-sale terminal. A Phoenix LiveView UI (menu → cart → checkout) runs on the device and is displayed full-screen via a Wayland kiosk browser. Checkout debits the customer by scanning an NFC tag/card and calls out to an external ledger service ("talesbot") to transfer funds; there is no local database or Ecto.

The same codebase runs in two very different contexts, selected by `Mix.target()`:
- `:host` — plain Phoenix dev/test, no hardware, used for iterating on the LiveView UI and business logic.
- `:rpi4` — the real Nerves firmware target, with GPIO, I2C/NFC, and the on-device kiosk browser.

## Commands

Host development (default target):
- `mix setup` — deps.get + assets setup/build
- `mix phx.server` or `iex -S mix phx.server` — run the app at http://localhost:4000
- `mix test` — run the test suite; single file with `mix test test/path/to/file_test.exs`, single test by appending `:LINE`
- `mix format` — format `.ex`/`.exs`/`.heex` (formatter plugin handles HEEx)
- `mix credo` — strict lint, scoped to `lib/` only (see `.credo.exs`); `lib/bar_banker_web*` is excluded
- `mix dialyzer` — static analysis (PLT cached at `_build/plts/dialyzer.plt`)
- `mix precommit` — the alias to run before committing: `compile --warning-as-errors`, `deps.unlock --unused`, `format`, `test`

Nerves firmware (target: `rpi4`), run with `MIX_TARGET=rpi4` (mise pins the Elixir/Erlang/fwup versions in `mise.toml`):
- `MIX_TARGET=rpi4 mix deps.get` then `MIX_TARGET=rpi4 mix firmware` — cross-compile firmware for the device
- `./upload.sh [host] [path/to/*.fw]` — push a `.fw` bundle over SSH to a device running `ssh_subsystem_fwup` (defaults to `nerves.local` and the newest build in `_build/rpi4_dev/nerves/images`)
- `mix upload.hotswap` — push updated BEAM code straight to the running device node (`bar_banker@bar_banker.local`, cookie configured in `config/config.exs` under `:mix_tasks_upload_hotswap`) instead of rebuilding/reflashing firmware — the fast loop for iterating on-device
- `iex` on the device or over the hotswap node lets you use `toolshed`/`ring_logger` helpers already wired in

## Architecture

### Target-dependent supervision tree

`BarBanker.Application` always starts `BarBanker.Cart` and the Phoenix stack (`Endpoint`, `PubSub`, `Telemetry`, `DNSCluster`). What else starts depends on `Mix.target()`:
- On `:host`, nothing extra runs — good for UI/logic work without hardware.
- On every other target it also starts `BarBanker.Kiosk.Udevd`, `BarBanker.Kiosk.Supervisor`, and a distributed node (`epmd` + `Node.start(:"bar_banker@bar_banker.local")`) used by `mix upload.hotswap`. `BarBanker.NFC` and `BarBanker.Keypad` are currently commented out in the children list — the GPIO/NFC hardware integration exists in code but isn't wired into the supervision tree yet, so don't assume it's live without checking `lib/bar_banker/application.ex`.

### Kiosk display stack (`lib/bar_banker/kiosk/`)

`Kiosk.Supervisor` is a `:rest_for_one` chain that boots, in order: a session `dbus-daemon`, `weston` (Wayland kiosk compositor, waits for a DRM card device node), and `cog` (a WPE-based browser, waits for the D-Bus socket and Wayland socket) pointed at `http://localhost:4000/` — i.e. the browser loads the app's own LiveView UI. `Kiosk.Udevd` runs `udevd` and triggers/settles udev events so DRM/input devices exist before weston starts. `Kiosk.Cog` is a D-Bus client (`org.gtk.Actions` on `com.igalia.Cog`) for remote-controlling the running browser (`open_url/1`, `back/0`, `forward/0`, `reload/0`, `quit/0`) — this is how the app could, e.g., navigate the kiosk browser from Elixir.

### Domain logic (`lib/bar_banker/`)

- `Cart` — an `Agent` holding the in-memory shopping cart as `%{path => {count, item}}`; no persistence, resets on restart.
- `Inventory` / `Sin` — read static JSON menu/data files from `priv/data/` via `:code.priv_dir(:bar_banker)` (menu items are nested under `"children"` keys, addressed by a list-of-codes `path`).
- `Client` — `Req`-based HTTP client to the external ledger API (`base_url`/`auth` set at compile time in `config/config.exs`); `transfer/4` is what checkout calls to move funds from the scanned tag's handle to the shop's handle.
- `NFC` — a `LibNFC.Presence` server talking to a PN532 reader over I2C (`pn532_i2c:/dev/i2c-1`); broadcasts `{:nfc, :in/:out, uid}` on the `"nfc"` PubSub topic.
- `Keypad` — bit-bangs a 4x4 matrix keypad via `Circuits.GPIO` (row/col pin scan loop with a debounce buffer, deduped by `Utils.dedupe_events/1`); broadcasts `{:keypad, :pressed/:release, key}` on the `"keypad"` topic.
- `NDEF` — standalone binary parser for short NDEF records (e.g. NFC tag text records); not wired into `NFC` yet.
- `src/nfc_reader_port/` is an earlier, now-superseded prototype: a `uv`-managed Python port meant to talk to the NFC reader/keypad over a port process. The native Elixir path (`libnfc_ex` + `Circuits.GPIO` above) replaced it; treat this directory as legacy/reference unless told otherwise.

### Web UI (`lib/bar_banker_web/`)

There is a single catch-all route, `live "/*path", RegisterLive` — the whole kiosk UI (menu browsing, cart, checkout) is one LiveView (`RegisterLive`) that switches views via an assign (`:menu`/`:cart`) and encodes the current menu category as the path segments, backed by `Inventory`/`Cart`. Checkout waits for an NFC tag-in event (subscribed via `NFC.subscribe_nfc/0`) if none is present yet, then runs the transfer as a LiveView async operation (`start_async(:checkout, ...)`).

## Notes

- `credo`'s default config only lints `lib/`, excluding the `bar_banker_web` tree entirely — don't expect Credo to flag anything in LiveViews/controllers/components.
- `NDEF`, `Cog`, `Udevd`, and the GPIO-facing modules are hard to exercise on `:host`; when changing them, reason carefully about the target-specific code paths rather than relying on `mix test` (which runs on `:host`).
