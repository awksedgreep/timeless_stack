defmodule TimelessStack.Application do
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    children =
      [
        TimelessStack.UIDataSource.Cache
      ] ++ alerting_children()

    opts = [strategy: :one_for_one, name: TimelessStack.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Alert rules are stored and evaluated by timeless_metrics, whose supervisor
  # starts neither under `owner: :external` — configured_children/1 returns []
  # there, because the metrics themselves live in the Rust data plane. Without
  # these two children a rule can be written and displayed and is never
  # evaluated: nothing fires, no history is recorded, and the UI shows a rule
  # that looks configured. Alerting that has never run is indistinguishable
  # from alerting with nothing to report, which is the failure this whole
  # deployment exists to stop having.
  #
  # The rules database is deliberately NOT the metrics directory. TimelessMetrics.DB
  # opens `<data_dir>/metrics.db`, and that file in the metrics directory belongs
  # to the Rust data plane (it holds an exclusive lock beside it); pointing this
  # at the same directory would put two writers and two migration histories on
  # one database.
  @doc false
  # Public for tests: whether these children exist decides whether alerting
  # runs at all, and its absence is silent.
  def alerting_children do
    config = Application.get_env(:timeless_stack, :alerting, [])

    if Keyword.get(config, :enabled, false) do
      data_dir = Keyword.fetch!(config, :data_dir)
      store = Keyword.get(config, :store, :timeless_metrics)
      interval = Keyword.get(config, :interval, :timer.seconds(60))

      Logger.info(
        "alert evaluation enabled: store=#{store} interval=#{interval}ms rules=#{Path.join(data_dir, "metrics.db")}"
      )

      [
        {TimelessMetrics.DB, name: :"#{store}_db", data_dir: data_dir},
        {TimelessMetrics.AlertEvaluator,
         name: :"#{store}_alert_evaluator", store: store, interval: interval}
      ]
    else
      []
    end
  end
end
