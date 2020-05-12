defmodule Down.HttpcBackend do
  @moduledoc false

  @type state :: %{
          ref: reference(),
          pid: nil | pid()
        }

  @spec run(Down.request(), pid) :: {:ok, state(), Down.request()}
  def run(req, pid) do
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

  @spec next_chunk(state()) :: state()
  def next_chunk(%{pid: pid} = state) do
    :ok = :httpc.stream_next(pid)
    state
  end

  def handle_info(%{ref: ref}, {:http, {ref, :stream_start, headers, pid}}) do
    headers = Down.Utils.process_headers(headers)
    # We hardcode the status_code, but in fact it could be also 206
    msgs = [
      {:headers, headers},
      {:status_code, 200}
    ]

    {:parsed, msgs, %{ref: ref, pid: pid}, true}
  end

  def handle_info(%{ref: ref} = bd, {:http, {ref, :stream, chunk}}),
    do: {:parsed, {:chunk, chunk}, bd, false}

  def handle_info(%{ref: ref} = bd, {:http, {ref, :stream_end, _headers}}) do
    # TODO headers
    {:parsed, :done, bd, false}
  end

  # With errors
  def handle_info(%{ref: ref}, {:http, {ref, {:error, :timeout}}}),
    do: {:parsed, {:error, :timeout}, nil, false}

  def handle_info(%{ref: ref} = bd, {:http, {ref, {{_, status_code, _}, headers, body}}}) do
    headers = Down.Utils.process_headers(headers)

    msgs = [
      {:headers, headers},
      {:status_code, status_code},
      {:chunk, body},
      :done
    ]

    {:parsed, msgs, bd, false}
  end

  def handle_info(_, msg), do: {:no_parsed, msg}

  @spec stop(state()) :: :ok
  def stop(%{pid: pid}), do: :httpc.cancel_request(pid)
end
