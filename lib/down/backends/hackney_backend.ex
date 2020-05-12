if Code.ensure_loaded?(:hackney) do
  defmodule Down.HackneyBackend do
    @moduledoc false

    @type state :: reference()

    @spec run(Down.request(), pid) :: {:ok, state(), Down.request()}
    def run(req, pid) do
      %{
        method: method,
        body: body,
        url: url,
        headers: headers,
        backend_opts: backend_opts,
        connect_timeout: connect_timeout,
        recv_timeout: recv_timeout
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
        |> Keyword.put(:recv_timeout, recv_timeout)

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

    @spec next_chunk(state()) :: state()
    def next_chunk(ref) do
      :ok = :hackney.stream_next(ref)
      ref
    end

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

    def handle_info(ref, {:hackney_response, ref, {:see_other, _, _}}),
      do: {:parsed, :ignore, ref, false}

    def handle_info(ref, {:hackney_response, ref, {:error, {:closed, :timeout}}}),
      do: {:parsed, {:error, :timeout}, nil, false}

    def handle_info(_, msg), do: {:no_parsed, msg}

    @spec stop(state()) :: :ok
    def stop(ref),
      do: :hackney.close(ref)
  end
end
