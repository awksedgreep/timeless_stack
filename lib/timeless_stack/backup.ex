defmodule TimelessStack.Backup do
  @moduledoc false

  @signals [:metrics, :logs, :traces]
  @format_version 1

  def create(target_dir, opts \\ []) when is_binary(target_dir) do
    target = Path.expand(target_dir)
    parent = Path.dirname(target)
    name = Path.basename(target)

    staging =
      Path.join(parent, ".#{name}.timeless-backup-#{System.unique_integer([:positive])}.partial")

    with :ok <- require_new_target(target),
         :ok <- File.mkdir_p(parent),
         :ok <- File.mkdir(staging) do
      try do
        create_staged(staging, target, opts)
      after
        File.rm_rf(staging)
      end
    else
      {:error, reason} -> {:error, {:prepare_backup, reason}}
    end
  rescue
    error -> {:error, {:backup_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:backup_failed, kind, reason}}
  end

  def verify(path) when is_binary(path) do
    root = Path.expand(path)

    with {:ok, checksums} <- File.read(Path.join(root, "SHA256SUMS")),
         {:ok, entries} <- parse_checksums(checksums),
         :ok <- verify_entries(root, entries),
         {:ok, manifest} <- read_json(Path.join(root, "manifest.json")),
         true <- manifest["format_version"] == @format_version do
      {:ok, manifest}
    else
      false -> {:error, :unsupported_backup_format}
      {:error, _reason} = error -> error
    end
  end

  @doc "Restore a verified release backup into a new or empty offline data directory."
  def restore(backup_path, data_dir) when is_binary(backup_path) and is_binary(data_dir) do
    backup = Path.expand(backup_path)
    target = Path.expand(data_dir)
    parent = Path.dirname(target)

    staging =
      Path.join(
        parent,
        ".#{Path.basename(target)}.timeless-restore-#{System.unique_integer([:positive])}.partial"
      )

    with {:ok, manifest} <- verify(backup),
         :ok <- require_empty_restore_target(target),
         :ok <- File.mkdir_p(parent),
         :ok <- File.mkdir(staging) do
      try do
        restore_staged(backup, staging, target, manifest)
      after
        File.rm_rf(staging)
      end
    else
      {:error, reason} -> {:error, {:prepare_restore, reason}}
    end
  rescue
    error -> {:error, {:restore_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:restore_failed, kind, reason}}
  end

  defp create_staged(staging, target, opts) do
    modules =
      Keyword.get(opts, :signal_modules, %{
        metrics: TimelessStack.MetricsDataPlane,
        logs: TimelessStack.LogsDataPlane,
        traces: TimelessStack.TracesDataPlane
      })

    with :ok <- flush_control_plane_buffers(opts),
         {:ok, release_state} <- backup_release_state(staging, opts),
         {:ok, policies} <- backup_auth_policies(staging, opts),
         {:ok, reports} <- backup_signals(staging, modules),
         {:ok, health} <- signal_health(modules),
         {:ok, control} <- backup_control(staging, opts),
         {:ok, artifacts} <- artifact_inventory(staging),
         manifest = manifest(reports, health, control, release_state, policies, artifacts),
         :ok <- write_json(Path.join(staging, "manifest.json"), manifest),
         {:ok, manifest_entry} <- inventory_entry(staging, Path.join(staging, "manifest.json")),
         checksummed = artifacts ++ [manifest_entry],
         :ok <- write_checksums(staging, checksummed),
         :ok <- verify_staged(staging, checksummed),
         :ok <- publish_restore(staging, target) do
      {:ok, Map.put(manifest, :path, target)}
    end
  end

  defp flush_control_plane_buffers(opts) do
    case Keyword.get(opts, :logs_buffer_flush, :default) do
      false ->
        :ok

      fun when is_function(fun, 0) ->
        normalize_buffer_flush(fun.())

      :default ->
        case GenServer.whereis(TimelessUI.LogsDataPlane.Buffer) do
          nil -> :ok
          _pid -> normalize_buffer_flush(TimelessUI.LogsDataPlane.Buffer.flush())
        end
    end
  catch
    :exit, reason -> {:error, {:control_plane_buffer_flush_failed, reason}}
  end

  defp normalize_buffer_flush(:ok), do: :ok
  defp normalize_buffer_flush({:ok, _report}), do: :ok

  defp normalize_buffer_flush({:error, reason}),
    do: {:error, {:control_plane_buffer_flush_failed, reason}}

  defp normalize_buffer_flush(other),
    do: {:error, {:invalid_control_plane_buffer_flush_result, other}}

  defp restore_staged(backup, staging, target, manifest) do
    with :ok <- restore_signal_databases(backup, staging, manifest["storage_layout"]),
         :ok <- restore_control_database(backup, staging, manifest["control"]),
         :ok <- restore_tree(Path.join(backup, "legacy"), staging),
         :ok <-
           restore_tree(
             Path.join([backup, "control", "auth"]),
             Path.join([staging, "control", "auth"])
           ),
         :ok <-
           write_json(Path.join(staging, "restore-manifest.json"), %{
             "backup_manifest_sha256" => sha256_file(Path.join(backup, "manifest.json")),
             "restored_at" =>
               DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
           }),
         :ok <- publish(staging, target) do
      {:ok, %{path: target, backup: backup}}
    end
  end

  defp restore_signal_databases(backup, staging, layout) when is_map(layout) do
    if Enum.sort(Map.keys(layout)) != ~w(logs metrics traces) do
      {:error, {:invalid_storage_layout, Map.keys(layout)}}
    else
      Enum.reduce_while(@signals, :ok, fn signal, :ok ->
        name = Atom.to_string(signal)
        entry = Map.fetch!(layout, name)
        source_name = entry["backup_file"]
        data_directory = entry["data_directory"]
        target_name = entry["target_name"]

        if source_name == "#{name}.db" and data_directory == name and
             safe_basename?(target_name) do
          source = Path.join(backup, source_name)
          destination = Path.join([staging, data_directory, target_name])

          with :ok <- File.mkdir_p(Path.dirname(destination)),
               :ok <- copy_verified_file(source, destination),
               :ok <- verify_sqlite_backup(destination, name) do
            {:cont, :ok}
          else
            {:error, reason} -> {:halt, {:error, {:restore_signal, signal, reason}}}
          end
        else
          {:halt, {:error, {:unsafe_storage_layout, signal, entry}}}
        end
      end)
    end
  end

  defp restore_signal_databases(_backup, _staging, layout),
    do: {:error, {:invalid_storage_layout, layout}}

  defp restore_control_database(backup, staging, %{"included" => true, "file" => source_name})
       when is_binary(source_name) do
    if safe_basename?(source_name) do
      source = Path.join(backup, source_name)
      destination = Path.join(staging, "timeless_ui.db")

      with :ok <- copy_verified_file(source, destination),
           :ok <- verify_sqlite_backup(destination, nil) do
        :ok
      end
    else
      {:error, {:unsafe_control_database, source_name}}
    end
  end

  defp restore_control_database(_backup, _staging, control),
    do: {:error, {:control_database_not_included, control}}

  defp restore_tree(source, destination) do
    cond do
      not File.exists?(source) ->
        :ok

      File.dir?(source) ->
        with :ok <- File.mkdir_p(destination) do
          source
          |> File.ls!()
          |> Enum.sort()
          |> Enum.reduce_while(:ok, fn name, :ok ->
            if name == "source-manifest.json" do
              {:cont, :ok}
            else
              case restore_tree(Path.join(source, name), Path.join(destination, name)) do
                :ok -> {:cont, :ok}
                {:error, reason} -> {:halt, {:error, reason}}
              end
            end
          end)
        end

      File.regular?(source) ->
        copy_verified_file(source, destination)

      true ->
        {:error, {:unsupported_restore_path, source}}
    end
  end

  defp copy_verified_file(source, destination) do
    case stream_copy(source, destination) do
      {:ok, _copy} -> :ok
      {:error, :source_not_regular} -> {:error, {:restore_source_missing, source}}
      {:error, :destination_exists} -> {:error, {:restore_destination_exists, destination}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_sqlite_backup(path, signal) do
    timeout = Application.get_env(:timeless_stack, :sqlite_verify_timeout, 300_000)

    task =
      Task.async(fn ->
        try do
          verify_sqlite_backup_sync(path, signal)
        rescue
          error -> {:error, {:sqlite_verification_failed, path, error}}
        catch
          kind, reason -> {:error, {:sqlite_verification_failed, path, kind, reason}}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:sqlite_verification_failed, path, reason}}
      nil -> {:error, {:sqlite_verification_timeout, path, timeout}}
    end
  end

  defp verify_sqlite_backup_sync(path, signal) do
    with {:ok, connection} <- Exqlite.Sqlite3.open(path, mode: :readonly) do
      try do
        with {:ok, [["ok"]]} <- TimelessMetrics.DB.execute(connection, "PRAGMA quick_check", []),
             :ok <- verify_restored_schema(connection, signal) do
          :ok
        else
          other -> {:error, {:sqlite_verification_failed, path, other}}
        end
      after
        Exqlite.Sqlite3.close(connection)
      end
    end
  end

  defp verify_restored_schema(_connection, nil), do: :ok

  defp verify_restored_schema(connection, signal) do
    case TimelessMetrics.DB.execute(
           connection,
           "SELECT version FROM _timeless_schema_migrations WHERE signal=?1 ORDER BY version DESC LIMIT 1",
           [signal]
         ) do
      {:ok, [[1]]} -> :ok
      other -> {:error, {:invalid_data_schema, signal, other}}
    end
  end

  defp require_empty_restore_target(path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        :ok

      {:ok, %{type: :directory}} ->
        if(File.ls!(path) == [], do: :ok, else: {:error, :destination_not_empty})

      {:ok, _stat} ->
        {:error, :destination_not_directory}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp publish_restore(staging, target) do
    case File.lstat(target) do
      {:error, :enoent} -> :ok
      {:ok, %{type: :directory}} -> File.rmdir(target)
      {:ok, _stat} -> {:error, :destination_not_directory}
      {:error, reason} -> {:error, reason}
    end
    |> case do
      :ok -> rename_staging(staging, target)
      {:error, _reason} = error -> error
    end
  end

  defp safe_basename?(name) when is_binary(name),
    do: name not in ["", ".", ".."] and Path.basename(name) == name

  defp safe_basename?(_name), do: false

  defp backup_signals(staging, modules) do
    Enum.reduce_while(@signals, {:ok, %{}}, fn signal, {:ok, reports} ->
      destination = Path.join(staging, "#{signal}.db")
      module = Map.fetch!(modules, signal)

      case module.backup(destination) do
        {:ok, report} when is_map(report) ->
          normalized = stringify_keys(report)

          if normalized["signal"] == Atom.to_string(signal) and
               normalized["destination"] == destination and
               is_integer(normalized["bytes"]) and normalized["bytes"] > 0 and
               File.regular?(destination) do
            {:cont, {:ok, Map.put(reports, signal, normalized)}}
          else
            {:halt, {:error, {:invalid_signal_backup_report, signal, normalized}}}
          end

        {:error, reason} ->
          {:halt, {:error, {:signal_backup_failed, signal, reason}}}

        other ->
          {:halt, {:error, {:invalid_signal_backup_result, signal, other}}}
      end
    end)
  end

  defp signal_health(modules) do
    Enum.reduce_while(@signals, {:ok, %{}}, fn signal, {:ok, health} ->
      case Map.fetch!(modules, signal).health() do
        {:ok, %{"build" => build} = result} when is_map(build) ->
          {:cont, {:ok, Map.put(health, signal, result)}}

        {:ok, result} ->
          {:halt, {:error, {:missing_signal_build_identity, signal, result}}}

        {:error, reason} ->
          {:halt, {:error, {:signal_health_failed, signal, reason}}}
      end
    end)
  end

  defp backup_control(staging, opts) do
    case Keyword.get(opts, :control_backup, :default) do
      false ->
        {:ok, %{"included" => false}}

      fun when is_function(fun, 1) ->
        destination = Path.join(staging, "control.db")

        case fun.(destination) do
          :ok -> validate_control_backup(destination)
          {:ok, _} -> validate_control_backup(destination)
          {:error, _reason} = error -> error
          other -> {:error, {:invalid_control_backup_result, other}}
        end

      :default ->
        destination = Path.join(staging, "control.db")
        repo = Keyword.get(opts, :repo, TimelessUI.Repo)

        case Ecto.Adapters.SQL.query(repo, "VACUUM INTO ?1", [destination], timeout: 300_000) do
          {:ok, _result} -> validate_control_backup(destination)
          {:error, reason} -> {:error, {:control_backup_failed, reason}}
        end
    end
  rescue
    error -> {:error, {:control_backup_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:control_backup_failed, kind, reason}}
  end

  defp validate_control_backup(path) do
    if File.regular?(path) and File.stat!(path).size > 0 do
      {:ok, %{"included" => true, "file" => Path.basename(path)}}
    else
      {:error, :control_backup_missing}
    end
  end

  defp backup_release_state(staging, opts) do
    Enum.reduce_while(data_planes(opts), {:ok, %{retained: %{}, layout: %{}}}, fn plane,
                                                                                  {:ok, state} ->
      signal = Keyword.fetch!(plane, :signal)
      data_dir = plane |> Keyword.fetch!(:data_dir) |> Path.expand()
      extension = Keyword.fetch!(plane, :extension)
      startup = Keyword.fetch!(plane, :startup_module)

      startup_opts =
        plane
        |> Keyword.get(:startup_opts, [])
        |> Keyword.put(:extension_path, extension)

      stats = startup.stats(data_dir, startup_opts)
      target_path = map_value(stats, :target_path)

      if map_value(stats, :ready) != true or not is_binary(target_path) do
        {:halt, {:error, {:signal_not_ready_for_backup, signal, stats}}}
      else
        layout = %{
          "backup_file" => "#{signal}.db",
          "data_directory" => Atom.to_string(signal),
          "target_name" => Path.basename(target_path),
          "startup_state" => to_string(map_value(stats, :state))
        }

        state = put_in(state, [:layout, signal], layout)

        case map_value(stats, :source_manifest_digest) do
          nil ->
            {:cont, {:ok, state}}

          expected when is_binary(expected) ->
            with {:ok, source} <- invoke_legacy_manifest(signal, data_dir, startup_opts, opts),
                 ^expected <- map_value(source, :digest),
                 {:ok, copied} <- copy_legacy_manifest(staging, signal, data_dir, source) do
              {:cont, {:ok, put_in(state, [:retained, signal], copied)}}
            else
              actual when is_binary(actual) ->
                {:halt, {:error, {:retained_source_digest_mismatch, signal, expected, actual}}}

              {:error, reason} ->
                {:halt, {:error, {:retained_source_backup_failed, signal, reason}}}
            end
        end
      end
    end)
  end

  defp invoke_legacy_manifest(signal, data_dir, startup_opts, opts) do
    case Keyword.get(opts, :legacy_manifest) do
      fun when is_function(fun, 3) -> fun.(signal, data_dir, startup_opts)
      nil -> legacy_manifest(signal, data_dir, startup_opts)
    end
  end

  defp legacy_manifest(:metrics, data_dir, _opts),
    do: TimelessMetrics.ReleaseMigration.legacy_manifest(data_dir)

  defp legacy_manifest(:logs, data_dir, opts),
    do: TimelessLogs.ReleaseMigration.legacy_manifest(data_dir, opts)

  defp legacy_manifest(:traces, data_dir, opts),
    do: TimelessTraces.ReleaseMigration.legacy_manifest(data_dir, opts)

  defp copy_legacy_manifest(staging, signal, root, manifest) do
    destination_root = Path.join([staging, "legacy", Atom.to_string(signal)])
    files = map_value(manifest, :files) || []

    with :ok <- File.mkdir_p(destination_root),
         :ok <- copy_manifest_files(files, root, destination_root),
         :ok <-
           write_file(
             Path.join(destination_root, "source-manifest.json"),
             map_value(manifest, :json)
           ) do
      {:ok,
       %{
         "digest" => map_value(manifest, :digest),
         "bytes" => map_value(manifest, :bytes),
         "files" => length(files),
         "path" => Path.relative_to(destination_root, staging)
       }}
    end
  end

  defp copy_manifest_files(files, source_root, destination_root) do
    Enum.reduce_while(files, :ok, fn entry, :ok ->
      relative = map_value(entry, :path)
      expected = map_value(entry, :sha256)
      source = safe_join(source_root, relative)
      destination = safe_join(destination_root, relative)

      with {:ok, %{sha256: actual}} <-
             stream_copy(source, destination, mtime: map_value(entry, :mtime)),
           ^expected <- actual do
        {:cont, :ok}
      else
        {:error, :source_not_regular} ->
          {:halt, {:error, {:invalid_legacy_source_path, relative}}}

        actual when is_binary(actual) ->
          {:halt, {:error, {:legacy_copy_digest_mismatch, relative, expected, actual}}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp safe_join(root, relative) when is_binary(relative) do
    if Path.type(relative) == :relative and ".." not in Path.split(relative) do
      Path.join(root, relative)
    else
      raise ArgumentError, "unsafe backup manifest path #{inspect(relative)}"
    end
  end

  defp backup_auth_policies(staging, opts) do
    Enum.reduce_while(data_planes(opts), {:ok, %{}}, fn plane, {:ok, policies} ->
      signal = Keyword.fetch!(plane, :signal)

      case Keyword.get(plane, :auth_policy_path) do
        nil ->
          {:cont, {:ok, policies}}

        source ->
          destination = Path.join([staging, "control", "auth", "#{signal}.json"])

          with {:ok, body} <- File.read(source),
               {:ok, decoded} when is_map(decoded) <- Jason.decode(body),
               :ok <- File.mkdir_p(Path.dirname(destination)),
               :ok <- write_file(destination, body) do
            {:cont,
             {:ok,
              Map.put(policies, signal, %{
                "path" => Path.relative_to(destination, staging),
                "sha256" => sha256_file(destination)
              })}}
          else
            {:error, reason} -> {:halt, {:error, {:backup_auth_policy, signal, reason}}}
          end
      end
    end)
  end

  defp data_planes(opts) do
    Keyword.get(
      opts,
      :data_planes,
      Application.get_env(:timeless_ui, :telemetry_data_planes, [])
    )
  end

  defp manifest(reports, health, control, release_state, policies, artifacts) do
    %{
      "format_version" => @format_version,
      "stack_version" => TimelessStack.version(),
      "created_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "signals" => reports,
      "health" => health,
      "control" => control,
      "storage_layout" => release_state.layout,
      "retained_rollback_sources" => release_state.retained,
      "auth_policies" => policies,
      "artifacts" => artifacts
    }
  end

  defp artifact_inventory(root) do
    entries =
      root
      |> regular_files()
      |> Enum.reject(fn {path, _stat} -> Path.basename(path) == "SHA256SUMS" end)
      |> Enum.map(fn {path, stat} -> inventory_entry(root, path, stat) end)

    {:ok, entries}
  rescue
    error -> {:error, {:inventory_backup, Exception.message(error)}}
  end

  defp inventory_entry(root, path) do
    case File.lstat(path) do
      {:ok, %{type: :regular} = stat} -> {:ok, inventory_entry(root, path, stat)}
      {:ok, stat} -> {:error, {:unsupported_backup_path, path, stat.type}}
      {:error, reason} -> {:error, {:inventory_backup, path, reason}}
    end
  end

  defp inventory_entry(root, path, stat) do
    %{
      "path" => Path.relative_to(path, root),
      "bytes" => stat.size,
      "sha256" => sha256_file(path)
    }
  end

  defp regular_files(root) do
    root
    |> File.ls!()
    |> Enum.sort()
    |> Enum.flat_map(fn name ->
      path = Path.join(root, name)

      case File.lstat(path) do
        {:ok, %{type: :regular} = stat} -> [{path, stat}]
        {:ok, %{type: :directory}} -> regular_files(path)
        {:ok, stat} -> raise "backup contains unsupported #{stat.type} path #{path}"
        {:error, reason} -> raise "cannot inspect backup path #{path}: #{inspect(reason)}"
      end
    end)
  end

  defp write_checksums(root, files) do
    body =
      files
      |> Enum.sort_by(& &1["path"])
      |> Enum.map_join("", &"#{&1["sha256"]}  #{&1["path"]}\n")

    write_file(Path.join(root, "SHA256SUMS"), body)
  end

  defp parse_checksums(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, entries} ->
      case String.split(line, "  ", parts: 2) do
        [digest, path] when byte_size(digest) == 64 ->
          {:cont, {:ok, [{path, digest} | entries]}}

        _ ->
          {:halt, {:error, {:invalid_checksum_line, line}}}
      end
    end)
  end

  defp verify_entries(root, entries) do
    Enum.reduce_while(entries, :ok, fn {relative, expected}, :ok ->
      path = safe_join(root, relative)

      if File.regular?(path) and sha256_file(path) == expected do
        {:cont, :ok}
      else
        {:halt, {:error, {:backup_checksum_mismatch, relative}}}
      end
    end)
  end

  # Creation already hashed every immutable artifact after all producers had
  # synced it. Validate that the generated checksum index and file set describe
  # exactly those hashes without re-reading multi-GB databases. `verify/1`
  # remains a full independent re-hash for restores and operator checks.
  defp verify_staged(root, expected_entries) do
    expected_checksums =
      expected_entries
      |> Enum.map(&{&1["path"], &1["sha256"]})
      |> Enum.sort()

    expected_sizes = Map.new(expected_entries, &{&1["path"], &1["bytes"]})

    with {:ok, body} <- File.read(Path.join(root, "SHA256SUMS")),
         {:ok, parsed} <- parse_checksums(body),
         true <- Enum.sort(parsed) == expected_checksums,
         {:ok, manifest} <- read_json(Path.join(root, "manifest.json")),
         true <- manifest["format_version"] == @format_version,
         true <- staged_sizes(root) == expected_sizes do
      :ok
    else
      false -> {:error, :invalid_staged_backup}
      {:error, _reason} = error -> error
    end
  end

  defp staged_sizes(root) do
    root
    |> regular_files()
    |> Enum.reject(fn {path, _stat} -> Path.basename(path) == "SHA256SUMS" end)
    |> Map.new(fn {path, stat} -> {Path.relative_to(path, root), stat.size} end)
  end

  defp publish(staging, target) do
    with :ok <- require_new_target(target),
         :ok <- rename_staging(staging, target) do
      :ok
    else
      {:error, reason} -> {:error, {:publish_backup, reason}}
    end
  end

  defp require_new_target(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, _stat} -> {:error, :destination_exists}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_json(path) do
    with {:ok, body} <- File.read(path), do: Jason.decode(body)
  end

  defp write_json(path, value), do: write_file(path, Jason.encode_to_iodata!(value, pretty: true))

  defp write_file(path, contents) do
    with {:ok, file} <- :file.open(String.to_charlist(path), [:write, :binary, :exclusive]),
         :ok <- :file.write(file, contents),
         :ok <- :file.sync(file),
         :ok <- :file.close(file) do
      :ok
    end
  end

  defp sync_file(path) do
    with {:ok, file} <- :file.open(String.to_charlist(path), [:read, :binary]),
         :ok <- :file.sync(file),
         :ok <- :file.close(file) do
      :ok
    end
  end

  # Staging is deliberately a hidden sibling of the target. Keeping this
  # invariant explicit guarantees the final rename is same-filesystem atomic.
  defp rename_staging(staging, target) do
    if Path.dirname(Path.expand(staging)) == Path.dirname(Path.expand(target)) do
      File.rename(staging, target)
    else
      {:error, :staging_must_share_target_parent}
    end
  end

  defp stream_copy(source, destination, opts \\ []) do
    with {:ok, source_stat} <- regular_source(source),
         :ok <- require_new_copy_target(destination),
         :ok <- File.mkdir_p(Path.dirname(destination)),
         {:ok, source_file} <- :file.open(String.to_charlist(source), [:read, :binary, :raw]) do
      case :file.open(String.to_charlist(destination), [:write, :binary, :raw, :exclusive]) do
        {:ok, destination_file} ->
          try do
            with {:ok, digest, bytes} <-
                   copy_chunks(
                     source_file,
                     destination_file,
                     :crypto.hash_init(:sha256),
                     0
                   ),
                 true <- bytes == source_stat.size,
                 :ok <- :file.sync(destination_file),
                 :ok <-
                   File.touch(destination, Keyword.get(opts, :mtime, source_stat.mtime)),
                 :ok <- sync_file(destination) do
              {:ok, %{sha256: Base.encode16(digest, case: :lower), bytes: bytes}}
            else
              false -> {:error, :copy_size_mismatch}
              {:error, reason} -> {:error, reason}
            end
          after
            :file.close(destination_file)
            :file.close(source_file)
          end

        {:error, reason} ->
          :file.close(source_file)
          {:error, reason}
      end
    else
      {:error, :eexist} -> {:error, :destination_exists}
      {:error, reason} -> {:error, reason}
    end
  end

  defp regular_source(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %{type: :regular} = stat} -> {:ok, stat}
      {:ok, _stat} -> {:error, :source_not_regular}
      {:error, :enoent} -> {:error, :source_not_regular}
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_new_copy_target(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, _stat} -> {:error, :destination_exists}
      {:error, reason} -> {:error, reason}
    end
  end

  defp copy_chunks(source, destination, digest, bytes) do
    case :file.read(source, 1_048_576) do
      {:ok, chunk} ->
        case :file.write(destination, chunk) do
          :ok ->
            copy_chunks(
              source,
              destination,
              :crypto.hash_update(digest, chunk),
              bytes + byte_size(chunk)
            )

          {:error, reason} ->
            {:error, reason}
        end

      :eof ->
        {:ok, :crypto.hash_final(digest), bytes}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sha256_file(path) do
    path
    |> File.stream!(1_048_576, [])
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
  defp map_value(map, key), do: Map.get(map, key, Map.get(map, to_string(key)))
end
