if Code.ensure_loaded?(:hackney) do
  defmodule Down.HackneyBackend do
    alias Down.Backend
    @behaviour Backend
    @moduledoc false

    @type state :: reference()

    @impl true
    @spec start(Down.request(), pid) :: {:ok, state(), Down.request()}
    def start(req, pid) do
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

    @impl true
    @spec demand_next(state()) :: state()
    def demand_next(ref) do
      case :hackney.stream_next(ref) do
        :ok -> ref
        {:error, :req_not_found} -> ref
      end
    end

    @impl true
    @spec handle_message(state(), Backend.raw_message()) :: {Backend.action(), state()}
    def handle_message(ref, {:hackney_response, ref, {:status, status, _reason}}) do
      {{:status_code, status}, ref}
    end

    def handle_message(ref, {:hackney_response, ref, {:headers, headers}}) do
      headers = Down.Utils.process_headers(headers)
      {{:headers, headers}, ref}
    end

    def handle_message(ref, {:hackney_response, ref, :done}), do: {:done, ref}

    def handle_message(ref, {:hackney_response, ref, chunk}) when is_binary(chunk),
      do: {{:chunk, chunk}, ref}

    # def handle_message(ref, {:hackney_response, ref, {:see_other, _, _}}),
    #   do: {:parsed, :ignore, ref}

    def handle_message(ref, {:hackney_response, ref, {:error, {:closed, :timeout}}}),
      do: {{:error, :timeout}, nil}

    def handle_message(_, msg), do: {:ignored, msg}

    @impl true
    @spec stop(state()) :: :ok
    def stop(ref),
      do: :hackney.close(ref)
  end
end
