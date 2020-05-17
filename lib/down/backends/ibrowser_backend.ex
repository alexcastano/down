if Code.ensure_loaded?(:ibrowse) do
  defmodule Down.IBrowseBackend do
    alias Down.Backend
    @behaviour Backend

    @type state() :: :ibrowse.req_id()

    @impl true
    @spec start(Down.request(), pid()) :: {:ok, state(), Down.request()} | {:error, term()}
    def start(req, pid) do
      %{
        method: method,
        body: body,
        url: url,
        headers: headers,
        backend_opts: backend_opts,
        total_timeout: total_timeout,
        connect_timeout: connect_timeout,
        recv_timeout: recv_timeout
      } = req

      headers = Enum.into(headers, [])
      url = to_charlist(url)
      body = body || []

      backend_opts =
        backend_opts
        |> Enum.into([])
        |> Keyword.put(:response_format, :binary)
        |> Keyword.put(:stream_to, {pid, :once})
        |> Keyword.put(:inactivity_timeout, recv_timeout)
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

    @impl true
    @spec demand_next(state()) :: state()
    def demand_next(id) do
      :ok = :ibrowse.stream_next(id)
      id
    end

    @impl true
    @spec handle_message(state(), Backend.raw_message()) :: {Backend.action(), state()}
    def handle_message(id, {:ibrowse_async_response_timeout, id}),
      do: {{:error, :timeout}, id}

    def handle_message(id, {:ibrowse_async_headers, id, status_code, headers}) do
      {status_code, []} = :string.to_integer(status_code)
      headers = Down.Utils.process_headers(headers)

      {[{:status_code, status_code}, {:headers, headers}], id}
    end

    def handle_message(id, {:ibrowse_async_response, id, {:error, :req_timedout}}),
      do: {{:error, :timeout}, nil}

    def handle_message(id, {:ibrowse_async_response, id, {:error, error}}),
      do: {{:error, error}, id}

    def handle_message(id, {:ibrowse_async_response, id, chunk}),
      do: {{:chunk, chunk}, id}

    def handle_message(id, {:ibrowse_async_response_end, id}), do: {:done, id}

    def handle_message(_, msg), do: {:ignored, msg}

    @impl true
    @spec stop(state()) :: :ok
    def stop(id), do: :ok = :ibrowse.stream_close(id)
  end
end
