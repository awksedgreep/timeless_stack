defmodule TimelessStack.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      TimelessStack.UIDataSource.Cache
    ]

    opts = [strategy: :one_for_one, name: TimelessStack.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
