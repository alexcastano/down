if Code.ensure_loaded?(Mint.HTTP) do
  defmodule Down.MintBackend do
    @moduledoc false

    @type state :: %{
            conn: Mint.t(),
            request_ref: Mint.Types.request_ref(),
            recv_timeout: timeout()
          }

    @spec run(Down.request(), pid) :: {:ok, state(), Down.request()}
    def run(req, _pid) do
      %{
        method: method,
        body: body,
        url: url,
        headers: headers,
        backend_opts: backend_opts,
        total_timeout: _total_timeout,
        connect_timeout: connect_timeout,
        recv_timeout: recv_timeout
      } = req

      method = method(method)

      transport_opts = [timeout: connect_timeout]

      opts =
        backend_opts
        |> Keyword.update(:transport_opts, transport_opts, &Keyword.merge(&1, transport_opts))
        |> Keyword.put(:mode, :passive)

      {scheme, host, port, path} = desconstruct_url(url)

      with {:ok, conn} <- Mint.HTTP.connect(scheme, host, port, opts),
           {:ok, conn, request_ref} <- Mint.HTTP.request(conn, method, path, headers, body) do
        state =
          next_chunk(%{
            conn: conn,
            request_ref: request_ref,
            recv_timeout: recv_timeout
          })

        {:ok, state, req}
      else
        {:error, %Mint.TransportError{reason: :econnrefused}} -> {:error, :econnrefused}
        {:error, %Mint.TransportError{reason: {:tls_alert, _}}} -> {:error, :ssl_error}
      end
    end

    defp desconstruct_url(url) do
      %URI{scheme: scheme, host: host, port: port, path: path, query: query} = URI.parse(url)
      path = %URI{path: path, query: query} |> URI.to_string()
      scheme = String.to_atom(scheme)
      {scheme, host, port, path}
    end

    defp method(method), do: method |> Atom.to_string() |> String.upcase()

    @spec next_chunk(state()) :: state()
    def next_chunk(state) do
      case Mint.HTTP.recv(state.conn, 0, state.recv_timeout) do
        {:ok, conn, responses} ->
          send(self(), responses)
          %{state | conn: conn}

        {:error, conn, %{reason: reason}, responses} ->
          responses = [{:error, state.request_ref, reason} | responses]
          send(self(), responses)
          %{state | conn: conn}
      end
    end

    def handle_info(ret, messages) do
      actions = Enum.map(messages, &handle_mint_msg(&1, ret.request_ref))
      {:parsed, actions, ret, false}
    end

    def handle_mint_msg({:status, request_ref, status}, request_ref),
      do: {:status_code, status}

    def handle_mint_msg({:headers, request_ref, headers}, request_ref),
      do: {:headers, Map.new(headers)}

    def handle_mint_msg({:data, request_ref, chunk}, request_ref),
      do: {:chunk, chunk}

    def handle_mint_msg({:done, request_ref}, request_ref),
      do: :done

    def handle_mint_msg({:error, request_ref, reason}, request_ref),
      do: {:error, reason}

    def handle_mint_msg(_ret, :unknown, msg) do
      {:no_parsed, msg}
    end

    @spec stop(state()) :: :ok
    def stop(%{conn: conn}) do
      Mint.HTTP.close(conn)
      :ok
    end
  end
end
