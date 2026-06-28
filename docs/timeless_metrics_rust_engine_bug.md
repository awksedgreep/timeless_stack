# timeless_metrics RustEngine NIF Return Shape Regression

## Summary

`timeless_metrics` `v6.0.21` fails on the default Rust engine path because
`TimelessMetrics.RustEngine` expects several NIF calls to return `{:ok, value}`
tuples, while the loaded Rust NIF returns bare values for at least write and
info operations.

This was exposed while updating `timeless_stack` to Elixir 1.20 / OTP 29 and
latest Timeless dependencies.

## Environment

- Elixir: 1.20.2
- Erlang/OTP: 29.0.2
- `timeless_metrics`: `v6.0.21`
- Caller: `timeless_stack` UI data source tests
- Metrics engine: default Rust engine

## Reproduction

In `timeless_stack`, with `timeless_metrics` pinned to `v6.0.21`, run:

```sh
mix test
```

The UI data source test starts a metrics store with the default options:

```elixir
start_supervised!(
  {TimelessMetrics, name: :test_metrics, data_dir: @data_dir, buffer_shards: 2}
)
```

Then it writes a point:

```elixir
TimelessMetrics.write(:test_metrics, "cpu_usage", %{"host" => "web-1"}, 73.5,
  timestamp: now
)
```

## Actual Failures

Writes fail because `RustEngine.write_resolved/4` only matches `{:ok, :ok}` or
`{:error, _}`, but `Nif.engine_write_batch_raw/2` returns bare `:ok`:

```text
** (CaseClauseError) no case clause matching: :ok
    (timeless_metrics 6.0.21) lib/timeless_metrics/rust_engine.ex:31:
    TimelessMetrics.RustEngine.write_resolved/4
```

Info calls fail because `RustEngine.info/1` pipes a bare map into
`unwrap_nif_ok/1`, which only accepts tuple-shaped values:

```text
** (FunctionClauseError) no function clause matching in
TimelessMetrics.RustEngine.unwrap_nif_ok/1

The following arguments were given:
%{
  "buffer_memory_mb" => 0.0,
  "buffered_points" => 0.0,
  "bytes_per_point" => 0.0,
  "chunk_count" => 0.0,
  "file_count" => 0.0,
  "partition_count" => 0.0,
  "series_count" => 0.0,
  "total_bytes" => 0.0,
  "total_points" => 0.0
}
```

## Suspected Cause

The Elixir wrapper and Rust NIF return contract drifted.

Older `RustEngine` code, such as `v6.0.0`, expected bare returns for some NIFs:

```elixir
def write(store, metric_name, labels, value, timestamp) do
  Nif.engine_write_batch_labeled(ref(store), [{metric_name, labels, timestamp, value}])
end

def info(store) do
  raw = Nif.engine_info(ref(store))
  ...
end
```

In `v6.0.21`, the wrapper expects tuple-wrapped returns:

```elixir
case Nif.engine_write_batch_raw(ref(store), encoded) do
  {:ok, :ok} -> :ok
  {:error, _} = error -> error
end

{:ok, raw} =
  Nif.engine_info(ref(store))
  |> unwrap_nif_ok()
```

But the actual NIF still returns bare `:ok` for writes and a bare map for info.

## Expected Behavior

The default Rust engine should support:

```elixir
TimelessMetrics.write(store, metric, labels, value, timestamp: ts)
TimelessMetrics.flush(store)
TimelessMetrics.info(store)
TimelessMetrics.query_multi(store, metric, labels, from: from, to: to)
```

without raising.

## Suggested Fix

Either:

1. Update the Rust NIF functions to consistently return `{:ok, value}` /
   `{:error, reason}` for all APIs the Elixir wrapper calls, or
2. Update `TimelessMetrics.RustEngine` to normalize both return shapes.

If backward compatibility with existing precompiled NIF artifacts matters,
normalizing both shapes in Elixir is the safer immediate fix.

Affected wrapper points observed from tests:

- `write_resolved/4`
- `write_batch/2`
- `flush/1`
- `info/1`
- potentially all callers using `unwrap_nif_ok/1`
