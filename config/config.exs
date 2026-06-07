# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# Enable the Nerves integration with Mix
Application.start(:nerves_bootstrap)

# Customize non-Elixir parts of the firmware. See
# https://hexdocs.pm/nerves/advanced-configuration.html for details.

config :nerves, :firmware,
  rootfs_overlay: "rootfs_overlay",
  provisioning: "config/provisioning.conf"

# Set the SOURCE_DATE_EPOCH date for reproducible builds.
# See https://reproducible-builds.org/docs/source-date-epoch/ for more information

config :nerves, source_date_epoch: "1780841365"

config :mix_tasks_upload_hotswap,
  app_name: :bar_banker,
  nodes: [:"bar_banker@bar_banker.local"],
  cookie: :nerves_is_awesome

import_config "phoenix/config.exs"

if Mix.target() == :host do
  import_config "host.exs"
else
  import_config "target.exs"
end
