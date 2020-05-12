defmodule Down.Utils do
  @moduledoc false

  @regex1 ~r/filename="([^"]*)"/
  @regex2 ~r/filename=(.+)/
  def filename_from_content_disposition(string) when is_binary(string) do
    opts = [capture: :all_but_first]

    (Regex.run(@regex1, string, opts) || Regex.run(@regex2, string, opts))
    |> case do
      nil ->
        nil

      [""] ->
        nil

      [s] ->
        s
        |> URI.decode()
        |> String.trim()
    end
  end

  def filename_from_content_disposition(_), do: nil

  def filename_from_url(url) do
    url
    |> URI.parse()
    |> Map.get(:path, "")
    |> URI.decode()
    |> Path.basename()
    |> case do
      "" -> nil
      name -> name
    end
  end

  def process_headers(headers) do
    Enum.reduce(headers, %{}, fn {key, value}, acc ->
      key = key |> to_string |> String.downcase()
      value = value |> to_string

      Map.update(acc, key, value, &[value | List.wrap(&1)])
    end)
  end

  def get_original_filename(state) do
    state.response.headers
    |> Map.get("content-disposition")
    |> Down.Utils.filename_from_content_disposition() ||
      Down.Utils.filename_from_url(state.request.url)
  end

  # Code inspired by Temp: https://github.com/danhper/elixir-temp/blob/master/lib/temp.ex
  def tmp_path(ext \\ nil) do
    name =
      [timestamp(), "-", :os.getpid(), "-", random_string()]
      |> add_extension(ext)
      |> Enum.join()

    Path.join(tmp_dir(), name)
  end

  defp tmp_dir() do
    case System.tmp_dir() do
      nil -> "/tmp"
      path -> path
    end
  end

  defp timestamp() do
    {ms, s, _} = :os.timestamp()
    Integer.to_string(ms * 1_000_000 + s)
  end

  defp add_extension(parts, ext)
  defp add_extension(parts, nil), do: parts
  defp add_extension(parts, ""), do: parts
  defp add_extension(parts, "." <> _ext = ext), do: parts ++ [ext]
  defp add_extension(parts, ext), do: parts ++ [".", ext]

  defp random_string do
    Integer.to_string(rand_uniform(0x100000000), 36) |> String.downcase()
  end

  if :erlang.system_info(:otp_release) >= '18' do
    defp rand_uniform(num) do
      :rand.uniform(num)
    end
  else
    defp rand_uniform(num) do
      :random.uniform(num)
    end
  end
end
