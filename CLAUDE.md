# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

BarBanker is a Nerves (embedded Elixir) app that turns a Raspberry Pi 4 into a bar/kiosk point-of-sale terminal with **two physical screens**: a staff-facing menu/checkout flow and a customer-facing cart display, each its own Phoenix LiveView shown full-screen via its own Wayland kiosk browser (`cog`) window. Checkout debits the customer by scanning an NFC tag/card and calls out to an external ledger service ("talesbot") to transfer funds; there is no local database or Ecto.

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

`BarBanker.Application` always starts `BarBanker.Shop.Cart`, `BarBanker.PN532.Supervisor`, and the Phoenix stack (`Endpoint`, `PubSub`, `Telemetry`, `DNSCluster`). On every target other than `:host` it also starts `BarBanker.Kiosk.Supervisor`, `BarBanker.Kiosk.InputWatcher`, and a distributed node (`epmd` + `Node.start(:"bar_banker@bar_banker.local")`) used by `mix upload.hotswap`. `BarBanker.Keypad` is still commented out — the GPIO integration exists in code but isn't wired into the supervision tree yet.

`PN532.Supervisor` starts one `PN532.Server` per I2C bus in `config :bar_banker, BarBanker.PN532.Supervisor, buses: [...]` (set to `["i2c-1"]` in `config/target.exs`; empty on `:host`, so there is no reader there). A `Server` connects from `handle_continue` and retries every 5s on failure, so a missing or unresponsive reader never fails the first start. That matters because `Supervisor` treats a child's *first*-start failure as fatal to the whole app, and with `config :nerves_runtime, startup_guard_enabled: true` a failed `:bar_banker` start means the firmware never gets marked valid and the device reboots back to the last-good firmware.

### Kiosk display stack (`lib/bar_banker/kiosk/`)

`Kiosk.Supervisor` is a `:rest_for_one` chain that boots, in order: a session `dbus-daemon`, `weston` (Wayland kiosk compositor, waits for a DRM card device node), and `Kiosk.Browsers`. `Kiosk.Udevd` runs `udevd` and triggers/settles udev events so DRM/input devices exist before weston starts.

`Kiosk.Browsers` is what actually drives the two physical screens: it's its own plain `:one_for_one` supervisor (kept separate from the `:rest_for_one` chain above so a crash in one screen's browser only restarts that window, not the other), starting one `cog` (WPE-based browser) instance per output from its `@screens` list — each with a distinct `--gapplication-app-id` and URL. The customer-facing output loads `http://localhost:4000/customer`, the staff-facing output loads `http://localhost:4000/menu`. Each app id is matched to a physical HDMI output via `app-ids=` in `rootfs_overlay/etc/xdg/weston/weston.ini` — check/edit that file if a screen shows the wrong content or ends up on the wrong port. `Kiosk.Cog` is a D-Bus client (`org.gtk.Actions`) for remote-controlling a running `cog` instance (`open_url/2`, `back/1`, `forward/1`, `reload/1`, `quit/1`) — every function takes that instance's app id (the D-Bus service/object path is derived from it, dots become slashes), since there are now two windows to address instead of one.

### Domain logic (`lib/bar_banker/`)

`BarBanker.Shop` (`lib/bar_banker/shop.ex`) is a Phoenix-context-style module: the public boundary for the cart, the menu, member lookups, and checkout. Its submodules live under `BarBanker.Shop.*` and are treated as private implementation — LiveViews and everything else should call through `Shop`, not `Shop.Cart`/`Shop.Inventory`/`Shop.Sin`/`Finance`/`BotClient` directly.

- `Shop.Cart` — an `Agent` holding the in-memory shopping cart as `%{path => {count, item}}`; no persistence, resets on restart. `Shop.add_cart/2`, `remove_cart/1`, and `clear_cart/0` each broadcast on the `"cart"` PubSub topic (`{:cart, :updated}` / `{:cart, :clear}`) after mutating it — that's how the customer-facing screen's LiveView process picks up changes made by the staff screen's LiveView process, since they don't otherwise share any state except through `Shop.Cart` itself.
- `Shop.Inventory` / `Shop.Sin` — read static JSON menu/member data from `priv/data/` via `:code.priv_dir(:bar_banker)` (menu items are nested under `"children"` keys, addressed by a list-of-codes `path`).
- `BotClient` — `Req`-based HTTP client to the external ledger API (`base_url`/`auth` set at compile time in `config/config.exs`). Raises on transport errors/unexpected bodies rather than returning `{:error, _}`.
- `Finance` — point-of-sale charging. `wait_for_card/0` polls the reader (`PN532.Server.scan/1` on `NFC.bus/0`) and decodes the card's NDEF text record into a sincard (`"sin:xxxx"`, balance on the ledger) or credstick (balance stored as an integer on the card); `charge/2` debits it and always pays the fixed receiver `"trinity_taskbar"`. Credsticks are debited by rewriting the card first, then the amount is minted to the receiver on the ledger; if that fails the old balance is written back (or `{:reconciliation_required, _}` is returned). Called via `Shop.wait_for_card/0` and `Shop.checkout/2`.
- `PN532` / `PN532.Server` — native I2C driver for the PN532 reader (`PN532.I2C` is the bus transport, default address `0x24`), and a GenServer per bus that owns the connection and serializes requests. It does **not** poll on its own; callers request each read (`Server.detect/1` for UID only, `Server.scan/1` for UID + NDEF).
- `NFC` — UID-only facade: `read_tag/0` checks once, `wait_for_tag/0` polls until a card shows up and returns its UID as lowercase hex; `bus/0` is the configured reader bus (also used by `Finance`). Checkout no longer uses the UID helpers. There is no NFC PubSub topic.
- `Keypad` — bit-bangs a 4x4 matrix keypad via `Circuits.GPIO` (row/col pin scan loop with a debounce buffer, deduped by `Utils.dedupe_events/1`); broadcasts `{:keypad, :pressed/:release, key}` on the `"keypad"` topic. Still commented out of the supervision tree.
- `NDEF` — NDEF parsing/encoding, used by `PN532.read_ndef/3`/`write_ndef/4`.
- `src/nfc_reader_port/` is an earlier, superseded NFC prototype; treat it as legacy/reference unless told otherwise.

### Web UI (`lib/bar_banker_web/`)

Three separate LiveViews now cover what a single screen used to (see "Kiosk display stack" above for which physical output loads which route):

- `MenuLive` (`/menu/*path`) — category browsing and adding to the cart; the current menu category is encoded as the path segments and resolved via `Shop.Inventory`. Loaded on the staff-facing screen; `Enter` navigates to `/checkout`.
- `CheckoutLive` (`/checkout`) — cart review and payment. On `Enter` it waits for a card with `Shop.wait_for_card/0` (as a `start_async(:wait_for_card, ...)`; clearing the cart cancels it), then runs `Shop.checkout(card, total)` as `start_async(:checkout, ...)` and navigates back to `/menu` on success. Both return `{:ok, _} | {:error, reason}`; errors are shown as a flash.
- `CustomerLive` (`/customer`) — read-only cart display for the customer-facing screen. Subscribes to `Shop.subscribe_cart/0` in `mount/3` so it re-renders when the staff screen's `MenuLive`/`CheckoutLive` process changes the cart, since separate LiveView processes don't otherwise share assigns.

## Notes

- `credo`'s default config only lints `lib/`, excluding the `bar_banker_web` tree entirely — don't expect Credo to flag anything in LiveViews/controllers/components.
- `NDEF`, `Cog`, `Udevd`, and the GPIO-facing modules are hard to exercise on `:host`; when changing them, reason carefully about the target-specific code paths rather than relying on `mix test` (which runs on `:host`).
