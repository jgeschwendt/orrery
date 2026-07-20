defmodule Orrery.Store do
  @moduledoc """
  Shared filesystem guards for the ~/.claude overlay:

    * `component?/1` — is a client-supplied string a single safe path segment (no
      traversal, no separator)? Every Orrery entry point that joins a request param
      into a path runs it through this before touching disk.
    * `write!/2` — atomic write (temp in the same dir, then rename) so an interrupted
      write can never leave a truncated file that later parses as empty and gets
      overwritten with defaults.
  """

  @doc "True only if `seg` is one safe filename component — rejects `.`, `..`, separators, NUL."
  def component?(seg) when is_binary(seg),
    do:
      seg not in ["", ".", ".."] and not String.contains?(seg, "\0") and Path.basename(seg) == seg

  def component?(_), do: false

  @doc "Atomically write `contents` to `path` (temp + rename within the same directory)."
  def write!(path, contents) do
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp.#{System.unique_integer([:positive])}"
    File.write!(tmp, contents)

    case File.rename(tmp, path) do
      :ok ->
        :ok

      {:error, reason} ->
        File.rm(tmp)
        raise File.Error, reason: reason, action: "rename to #{path}", path: tmp
    end
  end
end
