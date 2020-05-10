defmodule Down.Utils do
  @moduledoc false

  @default_backend Down.IBrowseBackend
  @version Mix.Project.config()[:version]

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

  def normalize_url(url) do
    url
    |> URI.parse()
    |> case do
      %{scheme: scheme} when scheme not in ["http", "https"] ->
        {:error, :invalid_url}

      %{host: ""} ->
        {:error, :invalid_url}

      %{port: port} when port < 0 or port > 65355 ->
        {:error, :invalid_url}

      %{path: nil} = uri ->
        uri = Map.put(uri, :path, "/")
        {:ok, URI.to_string(uri)}

      uri ->
        # FIXME encode URI.char_unescaped?(char) chars
        {:ok, URI.to_string(uri)}
    end
  end

  @valid_methods [:get, :post, :delete, :put, :patch, :options, :head, :connect, :trace]
  def validate_method(nil), do: {:ok, :get}
  def validate_method(method) when method in @valid_methods, do: {:ok, method}
  def validate_method(_), do: {:error, :invalid_method}

  def normalize_headers(nil), do: normalize_headers([])

  def normalize_headers(headers) when is_map(headers) or is_list(headers) do
    {:ok,
     headers
     |> Enum.into(%{}, fn {key, value} -> {to_string(key), to_string(value)} end)
     |> Map.put_new("User-Agent", "Down/#{@version}")}
  end

  def normalize_headers(h), do: {:error, {:invalid_request, :headers, h}}

  def get_backend(%{backend: backend}), do: get_backend_impl(backend)

  def get_backend(_),
    do: Application.get_env(:down, :backend, @default_backend) |> get_backend_impl()

  def get_backend_impl(:hackney), do: Down.HackneyBackend
  def get_backend_impl(:ibrowse), do: Down.IBrowseBackend
  def get_backend_impl(:httpc), do: Down.HttpcBackend
  def get_backend_impl(:mint), do: Down.MintBackend
  def get_backend_impl(Mint), do: Down.MintBackend
  def get_backend_impl(backend) when is_atom(backend), do: backend
  def get_backend_impl(backend), do: raise("Invalid backend #{inspect(backend)}")

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
