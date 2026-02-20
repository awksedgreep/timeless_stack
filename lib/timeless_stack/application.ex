defmodule TimelessStack.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # The three Timeless services start themselves via their own Application
    # modules during OTP boot. TimelessStack.Application only needs to start
    # stack-level concerns (future: clustering, unified health, etc.).
    children = []

    opts = [strategy: :one_for_one, name: TimelessStack.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
