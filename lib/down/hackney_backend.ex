defmodule Down.HackneyBackend do
  @moduledoc false

  def run(req, pid) do
    %{
      method: method,
      body: body,
      url: url,
      headers: headers,
      backend_opts: backend_opts,
      total_timeout: total_timeout,
      connect_timeout: connect_timeout,
      inactivity_timeout: _inactivity_timeout
    } = req

    headers = Enum.into(headers, [])
    body = body || ""

    backend_opts =
      backend_opts
      |> Enum.into([])
      |> Keyword.put(:async, :once)
      |> Keyword.put(:stream, pid)
      |> Keyword.put(:follow_redirect, false)
      |> Keyword.put(:connect_timeout, connect_timeout)
      |> Keyword.put(:recv_timeout, total_timeout)

    case :hackney.request(method, url, headers, body, backend_opts) do
      {:ok, ref} ->
        {:ok, ref, req}

      {:error, :checkout_timeout} ->
        {:error, :conn_timeout}

      {:error, {:tls_alert, _}} ->
        {:error, :ssl_error}

      error ->
        error
    end
  end

  def next_chunk(ref), do: :ok = :hackney.stream_next(ref)

  def handle_info(ref, {:hackney_response, ref, {:status, status, _reason}}) do
    {:parsed, {:status_code, status}, ref, true}
  end

  def handle_info(ref, {:hackney_response, ref, {:headers, headers}}) do
    headers = Down.Utils.process_headers(headers)
    {:parsed, {:headers, headers}, ref, true}
  end

  def handle_info(ref, {:hackney_response, ref, :done}), do: {:parsed, :done, ref, false}

  def handle_info(ref, {:hackney_response, ref, chunk}) when is_binary(chunk),
    do: {:parsed, {:chunk, chunk}, ref, false}

  def handle_info(ref, {:hackney_response, ref, {:redirect, url, headers}}) do
    {:parsed, {:redirect, url, headers}, ref, false}
  end

  def handle_info(ref, {:hackney_response, ref, {:see_other, _, _}}),
    do: {:parsed, :ignore, ref, false}

  def handle_info(ref, {:hackney_response, ref, {:error, {:closed, :timeout}}}),
    do: {:parsed, {:error, :timeout}, nil, false}

  def handle_info(_, msg), do: {:no_parsed, msg}

  def stop(ref),
    # do: {:ok, {_response, _transport, _socket, _buffer}} = :hackney.cancel_request(ref)
    do: :hackney.close(ref)
end
