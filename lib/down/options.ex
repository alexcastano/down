defmodule Down.Options do
  @moduledoc false

  @down_version Mix.Project.config()[:version]

  @type t :: %__MODULE__{
          url: URI.t(),
          total_timeout: timeout(),
          recv_timeout: timeout(),
          connect_timeout: timeout(),
          backend: atom(),
          backend_opts: term(),
          body: term(),
          method: Down.method(),
          headers: Down.headers(),
          max_redirects: non_neg_integer(),
          max_size: nil | non_neg_integer(),
          destination: nil | Path.t()
        }

  defstruct url: nil,
            total_timeout: :infinity,
            recv_timeout: 30_000,
            connect_timeout: 15_000,
            backend: nil,
            backend_opts: [],
            body: nil,
            method: :get,
            headers: [],
            max_redirects: 5,
            max_size: nil,
            destination: nil

  @spec build(String.t(), map() | Keyword.t()) :: {:ok, t()} | {:error, Down.Error.t()}
  def build(url, options) do
    options =
      __MODULE__
      |> struct(options)
      |> Map.update!(:backend, &(&1 || Down.default_backend()))

    with {:ok, url} <- normalize_url(url),
         {:ok, _method} <- validate_method(options.method),
         {:ok, headers} <- normalize_headers(options.headers) do
      options =
        options
        |> Map.put(:url, url)
        |> Map.put(:headers, headers)

      {:ok, options}
    else
      {:error, {reason, msg}} -> {:error, %Down.Error{reason: reason, custom_message: msg}}
      {:error, reason} -> {:error, %Down.Error{reason: reason}}
    end
  end

  def normalize_url(url) do
    url
    |> URI.parse()
    |> case do
      %{scheme: scheme} when scheme not in ["http", "https"] ->
        {:error, {:invalid_url, "invalid schema: only 'http' and 'https' allowed"}}

      %{host: host} when host in [nil, ""] ->
        {:error, {:invalid_url, "invalid host"}}

      %{port: port} when port < 0 or port > 65355 ->
        {:error, {:invalid_url, "invalid port"}}

      uri ->
        uri =
          Map.update!(uri, :path, fn
            nil -> "/"
            path -> path
          end)

        # FIXME encode URI.char_unescaped?(char) chars
        {:ok, URI.to_string(uri)}
    end
  end

  @valid_methods [:get, :post, :delete, :put, :patch, :options, :head, :connect, :trace]
  def validate_method(method) when method in @valid_methods, do: {:ok, method}
  def validate_method(_), do: {:error, :invalid_method}

  def normalize_headers(nil), do: normalize_headers([])

  def normalize_headers(headers) when is_map(headers) or is_list(headers) do
    {:ok,
     headers
     |> Enum.map(fn {key, value} -> {to_string(key), to_string(value)} end)
     |> maybe_add_user_agent()}
  end

  def normalize_headers(_), do: {:error, :invalid_headers}

  @user_agent_regex ~r/^user-agent$/i
  def maybe_add_user_agent(headers) do
    headers
    |> Enum.find(fn {label, _} -> label =~ @user_agent_regex end)
    |> case do
      nil -> [{"User-Agent", "Down/#{@down_version}"} | headers]
      _ -> headers
    end
  end
end
