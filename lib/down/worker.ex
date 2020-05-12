defmodule Down.Worker do
  @moduledoc false

  alias Down.Options

  @type operation :: :download | :stream | :read

  @type state :: %{
          backend: atom(),
          backend_data: term(),
          buffer: list(),
          client_pid: pid(),
          current_redirects: integer(),
          destination: nil | String.t(),
          error: nil | term(),
          file: nil | File.t(),
          file_path: nil | String.t(),
          finished: boolean(),
          max_redirects: :infinity | non_neg_integer(),
          max_size: nil | non_neg_integer(),
          operation: operation(),
          position: non_neg_integer(),
          request: Down.request(),
          response: Down.response(),
          stream_reply_to: nil
        }

  use GenServer, restart: :transient

  def start_link(args) do
    # gen_opts = [debug: [:statistics, :trace]]
    gen_opts = []
    GenServer.start_link(__MODULE__, args, gen_opts)
  end

  @impl true
  @spec init({operation(), pid(), Options.t()}) :: {:ok, state(), {:continue, :start}}
  def init({operation, client_pid, %Options{} = opts}) do
    request = build_req(opts)

    state = %{
      backend: opts.backend,
      backend_data: nil,
      buffer: [],
      current_redirects: 0,
      destination: opts.destination,
      error: nil,
      file: nil,
      file_path: nil,
      finished: false,
      max_redirects: opts.max_redirects,
      max_size: opts.max_size,
      operation: operation,
      client_pid: client_pid,
      position: 0,
      request: request,
      response: new_response(),
      stream_reply_to: nil
    }

    {:ok, state, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, state) do
    with {:ok, backend_data, request} <- state.backend.run(state.request, self()) do
      {:noreply, %{state | backend_data: backend_data, request: request}}
    else
      {:error, reason} -> {:stop, :normal, %{state | error: reason}}
    end
  end

  @spec new_response() :: Down.response()
  # FIXME
  # defp new_response(), do: %{headers: [], status_code: nil, size: nil, encoding: nil}
  defp new_response(), do: %{headers: %{}, status_code: nil, size: nil, encoding: nil}

  @spec build_req(Options.t()) :: Down.request()
  defp build_req(opts) do
    %{
      url: opts.url,
      method: opts.method,
      body: opts.body,
      headers: opts.headers,
      backend_opts: opts.backend_opts,
      total_timeout: opts.total_timeout,
      connect_timeout: opts.connect_timeout,
      recv_timeout: opts.recv_timeout
    }
  end

  @impl true
  def handle_call(:next_chunk, _from, %{buffer: [], backend_data: nil} = state) do
    {:reply, :halt, state}
  end

  def handle_call(:next_chunk, from, %{buffer: []} = state) do
    {:noreply, %{state | stream_reply_to: from}}
  end

  def handle_call(:next_chunk, _from, %{buffer: [head | rest]} = state) do
    state = maybe_ask_for_next_chunk(%{state | buffer: rest})
    {:reply, head, state}
  end

  @impl true
  def handle_info(:timeout, state) do
    {:stop, :normal, %{state | error: :timeout}}
  end

  def handle_info(msg, state) do
    msg
    |> backend_handle_info(state)
    |> handle_backend_reply(state)
  end

  defp backend_handle_info(msg, %{backend: backend, backend_data: backend_data}),
    do: backend.handle_info(backend_data, msg)

  defp handle_backend_reply({:no_parsed, _msg}, state), do: {:noreply, state}

  defp handle_backend_reply({:parsed, action, backend_data, force_next_chunk}, state) do
    state = process_backend_action(action, %{state | backend_data: backend_data})

    with :ok <- verify_no_errors(state),
         :ok <- verify_no_redirect(state),
         :ok <- verify_max_size(state),
         :ok <- verify_no_finished(state) do
      state =
        state
        |> maybe_reply_to_client()
        |> maybe_ask_for_next_chunk(force_next_chunk)

      {:noreply, state}
    end
  end

  @spec verify_no_errors(state()) :: :ok | {:stop, :normal, state()}
  defp verify_no_errors(%{error: nil}), do: :ok
  defp verify_no_errors(state), do: {:stop, :normal, state}

  @spec verify_no_finished(state()) :: :ok | {:stop, :normal, state()}
  defp verify_no_finished(%{backend_data: nil} = state) do
    if should_stop?(state) do
      {:stop, :normal, state}
    else
      :ok
    end
  end

  defp verify_no_finished(_state), do: :ok

  @spec should_stop?(state()) :: boolean()
  defp should_stop?(%{operation: :stream}), do: false
  defp should_stop?(_), do: true

  @spec verify_max_size(state()) :: :ok | {:stop, :normal, state()}
  defp verify_max_size(%{max_size: nil}), do: :ok

  defp verify_max_size(state = %{position: current_size, max_size: max_size})
       when is_integer(current_size) and current_size > max_size do
    {:stop, :normal, %{state | error: :too_large}}
  end

  # defp verify_max_size(state) %{"content-length" => size}, %{max_size: max_size}) do
  #   if String.to_integer(size) > max_size, do: {:error, :too_large}, else: :ok
  # end

  defp verify_max_size(_), do: :ok

  @redirect_status [301, 302, 303, 307, 308]

  @spec verify_no_redirect(state()) :: :ok | {:noreply, state} | {:stop, :normal, state}
  # defp verify_no_redirect(%{response: %{headers: []}}), do: :ok
  defp verify_no_redirect(%{response: %{headers: headers}}) when headers == %{}, do: :ok

  defp verify_no_redirect(%{response: %{status_code: status}} = state)
       when status in @redirect_status do
    state
    |> maybe_stop_backend()
    |> maybe_follow_redirect()
    |> case do
      {:ok, state} -> {:noreply, state}
      {:error, error} -> {:stop, :normal, %{state | error: error}}
    end
  end

  defp verify_no_redirect(_), do: :ok

  @spec maybe_follow_redirect(state) :: {:ok, state()} | {:error, term()}
  defp maybe_follow_redirect(%{current_redirects: c, max_redirects: m})
       when m != :infinite and c >= m,
       do: {:error, :too_many_redirects}

  defp maybe_follow_redirect(%{backend: backend} = state) do
    with {:ok, redirect_url} <- build_redirect_url(state),
         state = build_redirected_state(state, redirect_url),
         {:ok, backend_data, request} <- backend.run(state.request, self()) do
      {:ok, %{state | request: request, backend_data: backend_data}}
    end
  end

  @spec build_redirected_state(state(), Strint.t()) :: state()
  defp build_redirected_state(state, redirect_url) do
    Map.merge(state, %{
      request: build_new_request(state, redirect_url),
      response: new_response(),
      position: 0,
      buffer: [],
      current_redirects: state.current_redirects + 1
    })
  end

  @spec build_new_request(state(), String.t()) :: Down.request()
  defp build_new_request(%{response: %{status_code: status_code}} = state, redirect_url)
       when status_code in [307, 308] do
    %{state.request | url: redirect_url}
  end

  @content_type_regex ~r/^content-type$/i
  defp build_new_request(%{response: %{status_code: status_code}} = state, redirect_url)
       when status_code in [301, 302, 303] do
    headers =
      Enum.reject(state.request.headers, fn {label, _} -> label =~ @content_type_regex end)

    Map.merge(state.request, %{
      method: :get,
      body: nil,
      headers: headers,
      url: redirect_url
    })
  end

  defp build_redirect_url(%{request: %{url: current_url}, response: %{headers: headers}}) do
    case headers["location"] do
      nil ->
        {:error, :invalid_redirect}

      redirect_url ->
        case URI.parse(redirect_url) do
          # relative redirect
          %{host: host, scheme: scheme} when is_nil(host) or is_nil(scheme) ->
            {:ok, URI.merge(current_url, redirect_url) |> URI.to_string()}

          # absolute redirect
          _ ->
            {:ok, redirect_url}
        end
    end
  end

  defp maybe_reply_to_client(
         state = %{operation: :stream, stream_reply_to: pid, buffer: [head | tail]}
       )
       when not is_nil(pid) do
    GenServer.reply(pid, head)
    %{state | buffer: tail, stream_reply_to: nil}
  end

  defp maybe_reply_to_client(
         state = %{operation: :stream, stream_reply_to: pid, backend_data: nil, buffer: []}
       )
       when not is_nil(pid) do
    GenServer.reply(pid, :halt)
    %{state | stream_reply_to: nil}
  end

  defp maybe_reply_to_client(state), do: state

  @spec maybe_ask_for_next_chunk(state(), :force_next_chunk | :ignore) :: state()
  defp maybe_ask_for_next_chunk(state, arg \\ :ignore)

  defp maybe_ask_for_next_chunk(state, :force_next_chunk),
    do: ask_next_chunk(state)

  defp maybe_ask_for_next_chunk(%{backend_data: nil} = state, _), do: state

  defp maybe_ask_for_next_chunk(state = %{operation: :stream, buffer: []}, _),
    do: ask_next_chunk(state)

  defp maybe_ask_for_next_chunk(%{operation: :stream} = state, _), do: state

  defp maybe_ask_for_next_chunk(%{operation: operation} = state, _)
       when operation in [:download, :read],
       do: ask_next_chunk(state)

  @spec ask_next_chunk(state()) :: state()
  defp ask_next_chunk(state = %{backend: backend, backend_data: backend_data}) do
    backend_data = backend.next_chunk(backend_data)
    %{state | backend_data: backend_data}
  end

  defp process_backend_action(actions, state) when is_list(actions) do
    Enum.reduce(actions, state, &process_backend_action/2)
  end

  defp process_backend_action(:ignore, state), do: state

  defp process_backend_action(:done, state), do: %{state | backend_data: nil}

  # Ibrowse return empty chunks sometimes
  defp process_backend_action({:chunk, ""}, state), do: state

  defp process_backend_action({:chunk, chunk}, %{position: position} = state) do
    with {:ok, state} <- perform_operation(chunk, state) do
      position = position + byte_size(chunk)
      %{state | position: position}
    else
      {:error, error} ->
        %{state | error: error}
    end
  end

  defp process_backend_action({:headers, headers}, state) do
    size = get_size_header(headers)
    encoding = get_encoding_header(headers)

    state
    |> put_in([:response, :headers], headers)
    |> put_in([:response, :size], size)
    |> put_in([:response, :encoding], encoding)
  end

  defp process_backend_action({:status_code, status_code}, state) do
    put_in(state, [:response, :status_code], status_code)
  end

  defp process_backend_action({:error, error}, state), do: %{state | error: error}

  defp perform_operation(chunk, %{operation: operation, buffer: []} = state)
       when operation in [:read, :stream] do
    {:ok, %{state | buffer: [chunk]}}
  end

  defp perform_operation(chunk, %{operation: operation, buffer: buffer} = state)
       when operation in [:read, :stream] do
    {:ok, %{state | buffer: [buffer, chunk]}}
  end

  defp perform_operation(chunk, %{operation: :download, file: nil} = state) do
    {file_path, file} = open_file!(:download, state)

    state = %{state | file: file, file_path: file_path}
    perform_operation(chunk, state)
  end

  defp perform_operation(chunk, %{operation: :download, file: file} = state) do
    with :ok <- IO.binwrite(file, chunk), do: {:ok, state}
  end

  defp open_file!(:download, %{request: %{url: url}}) do
    %{path: path} = URI.parse(url)
    extension = Path.extname(path)
    file_path = Down.Utils.tmp_path(extension)
    file = File.open!(file_path, [:write, :delayed_write])
    {file_path, file}
  end

  defp get_size_header(%{"content-length" => size}) when is_binary(size),
    do: String.to_integer(size)

  defp get_size_header(%{"content-length" => size}) when is_integer(size), do: size
  defp get_size_header(_), do: nil

  # defp get_encoding_header(%{"content-type" => size}) when is_integer(size), do: size
  defp get_encoding_header(_), do: nil

  @impl true
  def terminate(reason, %{client_pid: pid} = state) do
    state =
      state
      |> maybe_close_file()
      |> maybe_stop_backend()

    case {reason, state.error, state.response.status_code} do
      {:normal, nil, status} when (status >= 200 and status <= 299) or is_nil(status) ->
        case build_reply(state) do
          :noreply -> nil
          reply -> send(pid, {__MODULE__, self(), {:ok, reply}})
        end

      {:normal, nil, status} ->
        send(pid, {__MODULE__, self(), {:error, {:invalid_status_code, status}}})

      {:normal, error, _} ->
        send(pid, {__MODULE__, self(), {:error, error}})

      {reason, _, _} ->
        send(pid, {__MODULE__, self(), {:error, reason}})
    end
  end

  defp maybe_close_file(%{file: nil} = state), do: state

  defp maybe_close_file(state) do
    File.close(state.file)
    %{state | file: nil}
  end

  defp maybe_stop_backend(%{backend_data: nil} = state), do: state

  defp maybe_stop_backend(%{backend: backend, backend_data: backend_data} = state) do
    backend.stop(backend_data)
    %{state | backend_data: nil}
  end

  defp build_reply(%{operation: :stream}), do: :noreply

  defp build_reply(%{operation: :download} = state) do
    %Down.Download{
      backend: state.backend,
      size: state.position,
      request: state.request,
      response: state.response,
      file_path: state.file_path,
      original_filename: Down.Utils.get_original_filename(state)
    }
  end

  defp build_reply(%{operation: :read, buffer: buffer}) do
    IO.iodata_to_binary(buffer)
  end
end
