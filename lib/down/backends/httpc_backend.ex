defmodule Down.HttpcBackend do
  alias Down.Backend
  @behaviour Backend
  @moduledoc false

  @type state :: %{
          ref: reference(),
          pid: nil | pid()
        }

  @impl true
  @spec start(Down.request(), pid) :: {:ok, state(), Down.request()}
  def start(req, pid) do
    %{
      method: method,
      body: body,
      url: url,
      headers: headers,
      connect_timeout: connect_timeout,
      recv_timeout: recv_timeout,
      backend_opts: backend_opts
    } = req

    request = build_request(method, url, headers, body)

    http_options =
      backend_opts
      |> Enum.into([])
      |> Keyword.put(:autoredirect, false)
      |> Keyword.put(:timeout, recv_timeout)
      |> Keyword.put(:connect_timeout, connect_timeout)

    options = [
      sync: false,
      stream: {:self, :once},
      body_format: :binary,
      full_result: true,
      receiver: pid
    ]

    case :httpc.request(method, request, http_options, options) do
      {:ok, ref} ->
        {:ok, %{ref: ref, pid: nil}, req}

      {:error, error} ->
        {:error, error}
    end
  end

  defp build_request(method, url, headers, _body) when method in [:head, :get, :options],
    do: build_request(url, headers)

  @content_type_regex ~r/^content-type$/i
  defp build_request(_method, url, headers, body) do
    content_type =
      headers
      |> Enum.find_value(fn {label, value} -> if label =~ @content_type_regex, do: value end)
      |> to_charlist()

    {url, headers} = build_request(url, headers)
    body = to_charlist(body)
    {url, headers, content_type, body}
  end

  defp build_request(url, headers),
    do: {url |> URI.encode() |> to_charlist(), to_charlist_headers(headers)}

  defp to_charlist_headers(headers) do
    for {key, value} <- headers, do: {to_charlist(key), to_charlist(value)}
  end

  @impl true
  @spec demand_next(state()) :: state()
  def demand_next(%{pid: pid} = state) do
    :ok = :httpc.stream_next(pid)
    state
  end

  @impl true
  @spec handle_message(state(), Backend.raw_message()) :: {Backend.actions(), state()}
  def handle_message(%{ref: ref}, {:http, {ref, :stream_start, headers, pid}}) do
    headers = Down.Utils.process_headers(headers)
    # We hardcode the status_code, but in fact it could be also 206
    {[{:headers, headers}, {:status_code, 200}], %{ref: ref, pid: pid}}
  end

  def handle_message(%{ref: ref} = bd, {:http, {ref, :stream, chunk}}),
    do: {{:chunk, chunk}, bd}

  def handle_message(%{ref: ref} = bd, {:http, {ref, :stream_end, _headers}}) do
    # TODO headers
    {:done, bd}
  end

  # With errors
  def handle_message(%{ref: ref}, {:http, {ref, {:error, :timeout}}}),
    do: {{:error, :timeout}, nil}

  def handle_message(%{ref: ref} = bd, {:http, {ref, {{_, status_code, _}, headers, body}}}) do
    headers = Down.Utils.process_headers(headers)

    msgs = [
      {:status_code, status_code},
      {:headers, headers},
      {:chunk, body},
      :done
    ]

    {msgs, bd}
  end

  def handle_message(_, msg), do: {:ignored, msg}

  @impl true
  @spec stop(state()) :: :ok
  def stop(%{pid: pid}), do: :httpc.cancel_request(pid)
end
