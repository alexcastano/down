defmodule Down.MintBackend do
  @moduledoc false

  def run(req, _pid) do
    %{
      method: method,
      body: body,
      url: url,
      headers: headers,
      backend_opts: _backend_opts,
      total_timeout: _total_timeout,
      connect_timeout: connect_timeout,
      inactivity_timeout: _inactivity_timeout
    } = req

    headers = Map.to_list(headers)
    method = method(method)
    transport_opts = [transport_opts: [timeout: connect_timeout]]
    {scheme, host, port, path} = desconstruct_url(url)

    with {:ok, conn} <- Mint.HTTP.connect(scheme, host, port, transport_opts),
         {:ok, conn, request_ref} <- Mint.HTTP.request(conn, method, path, headers, body) do
      {:ok, %{conn: conn, request_ref: request_ref}, req}
    else
      {:error, %Mint.TransportError{reason: :econnrefused}} -> {:error, :econnrefused}
    end
  end

  defp desconstruct_url(url) do
    %URI{scheme: scheme, host: host, port: port, path: path, query: query} = URI.parse(url)
    path = %URI{path: path, query: query} |> URI.to_string()
    scheme = String.to_atom(scheme)
    {scheme, host, port, path}
  end

  defp method(method), do: method |> Atom.to_string() |> String.upcase()

  # TODO ?
  def next_chunk(_ret) do
    # IO.puts("next chunk")
    :ok
  end

  def handle_info(ret = %{conn: conn}, message) do
    case Mint.HTTP.stream(conn, message) do
      {:ok, conn, messages} ->
        ret = %{ret | conn: conn}

        actions =
          for message <- messages do
            handle_mint_msg(message, ret.request_ref)
          end

        {:parsed, actions, ret, false}

      :unknown ->
        {:no_parsed, message}
    end
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

  def stop(%{conn: conn}), do: Mint.HTTP.close(conn)
end
