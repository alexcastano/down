defmodule Down.IBrowseBackend do
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
      inactivity_timeout: inactivity_timeout
    } = req

    headers = Enum.into(headers, [])
    url = to_charlist(url)
    body = body || []

    backend_opts =
      backend_opts
      |> Enum.into([])
      |> Keyword.put(:response_format, :binary)
      |> Keyword.put(:stream_to, {pid, :once})
      |> Keyword.put(:inactivity_timeout, inactivity_timeout)
      |> Keyword.put(:connect_timeout, connect_timeout)

    case :ibrowse.send_req(url, headers, method, body, backend_opts, total_timeout) do
      {:ibrowse_req_id, id} ->
        {:ok, id, req}

      {:error, {:conn_failed, {:error, :timeout}}} ->
        {:error, :conn_timeout}

      {:error, {:conn_failed, {:error, :econnrefused}}} ->
        {:error, :econnrefused}

      error ->
        error
    end
  end

  def next_chunk(id) do
    :ok = :ibrowse.stream_next(id)
  end

  def handle_info(id, {:ibrowse_async_response_timeout, id}),
    do: {:parsed, {:error, :timeout}, id, false}

  def handle_info(id, {:ibrowse_async_headers, id, status_code, headers}) do
    {status_code, []} = :string.to_integer(status_code)
    headers = Down.Utils.process_headers(headers)

    {:parsed, [{:status_code, status_code}, {:headers, headers}], id, false}
  end

  def handle_info(id, {:ibrowse_async_response, id, {:error, :req_timedout}}),
    do: {:parsed, {:error, :timeout}, nil, false}

  def handle_info(id, {:ibrowse_async_response, id, {:error, error}}),
    do: {:parsed, {:error, error}, id, false}

  def handle_info(id, {:ibrowse_async_response, id, chunk}),
    do: {:parsed, {:chunk, chunk}, id, false}

  def handle_info(id, {:ibrowse_async_response_end, id}), do: {:parsed, :done, id, false}

  def handle_info(_, msg), do: {:no_parsed, msg}

  def stop(id), do: :ok = :ibrowse.stream_close(id)
end
