defmodule Down.Worker do
  @moduledoc false

  use GenServer, restart: :transient

  def start_link(args) do
    # gen_opts = [debug: [:statistics, :trace]]
    gen_opts = []
    GenServer.start_link(__MODULE__, args, gen_opts)
  end

  # server

  @impl true
  def init({url, operation, client_pid, opts}) do
    with {:ok, request} <- build_req(url, opts),
         backend = Down.Utils.get_backend(opts),
         {:ok, backend_data, request} <- backend.run(request, self()) do
      state = %{
        backend: backend,
        backend_data: backend_data,
        buffer: [],
        current_redirects: 0,
        destination: Map.get(opts, :destination),
        error: nil,
        file: nil,
        file_path: nil,
        finished: false,
        max_redirects: Map.get(opts, :max_redirects, 5),
        max_size: Map.get(opts, :max_size),
        operation: operation,
        client_pid: client_pid,
        position: 0,
        request: request,
        response: new_response(),
        stream_reply_to: nil
      }

      {:ok, state}
    else
      # FIXME
      {:error, reason} -> {:stop, reason}
    end
  end

  defp new_response(), do: %{headers: [], status_code: nil, size: nil, encoding: nil}

  defp build_req(url, opts) do
    with {:ok, url} <- Down.Utils.normalize_url(url),
         {:ok, method} <- Down.Utils.validate_method(opts[:method]),
         {:ok, headers} <- Down.Utils.normalize_headers(opts[:headers]) do
      {:ok,
       %{
         url: url,
         method: method,
         body: Map.get(opts, :body),
         headers: headers,
         backend_opts: Map.get(opts, :backend_opts, []),
         total_timeout: Map.get(opts, :total_timeout, :infinity),
         connect_timeout: Map.get(opts, :connect_timeout, 15_000),
         inactivity_timeout: Map.get(opts, :inactivity_timeout, 120_000),
       }}
    end
  end


  @impl true
  def handle_call(:next_chunk, _from, %{buffer: [], backend_data: nil} = state) do
    {:reply, :halt, state}
  end

  def handle_call(:next_chunk, from, %{buffer: []} = state) do
    {:noreply, %{state | stream_reply_to: from}}
  end

  def handle_call(:next_chunk, _from, %{buffer: [head | rest]} = state) do
    state = %{state | buffer: rest}
    ask_next_chunk_if_need_it(state)
    {:reply, head, state}
  end

  @impl true
  def handle_info(msg, state) do
    msg
    |> backend_handle_info(state)
    |> handle_backend_reply(state)
  end

  defp backend_handle_info(msg, %{backend: backend, backend_data: backend_data}),
    do: backend.handle_info(backend_data, msg)

  defp handle_backend_reply({:no_parsed, _msg}, state), do: {:noreply, state}

  defp handle_backend_reply({:parsed, action, backend_data, force_next_chunk}, state) do
    state = %{state | backend_data: backend_data}

    case process_backend_action(action, state) do
      {:ok, state} ->
        state = reply_to_client(state)
        ask_next_chunk_if_need_it(state, force_next_chunk)
        {:noreply, state}

      {:redirect, state} ->
        state = stop_backend(state)

        case go_redirect(state) do
          {:ok, state} -> {:noreply, state}
          {:error, error} -> {:stop, :normal, %{state | error: error}}
        end

      {:done, state} ->
        state = reply_to_client(state)
        if should_stop?(state), do: {:stop, :normal, state}, else: {:noreply, state}

      {:error, state} ->
        {:stop, :normal, state}
    end
  end

  defp reply_to_client(state = %{operation: :stream, stream_reply_to: pid, buffer: [head | tail]})
       when not is_nil(pid) do
    GenServer.reply(pid, head)
    %{state | buffer: tail, stream_reply_to: nil}
  end

  defp reply_to_client(
         state = %{operation: :stream, stream_reply_to: pid, backend_data: nil, buffer: []}
       )
       when not is_nil(pid) do
    GenServer.reply(pid, :halt)
    %{state | stream_reply_to: nil}
  end

  defp reply_to_client(state), do: state

  defp should_stop?(%{operation: :stream}), do: false
  defp should_stop?(_), do: true

  defp go_redirect(%{current_redirects: c, max_redirects: m})
       when m != :infinite and c >= m,
       do: {:error, :too_many_redirects}

  defp go_redirect(%{backend: backend} = state) do
    with {:ok, request} <- build_new_request(state),
         state = Map.merge(state, %{request: request, response: new_response()}),
         {:ok, backend_data, request} <- backend.run(request, self()) do
      {:ok,
       %{
         state
         | request: request,
           backend_data: backend_data,
           current_redirects: state.current_redirects + 1
       }}
    end
  end

  defp build_new_request(%{response: %{status_code: status_code}} = state)
       when status_code in [307, 308] do
    with {:ok, redirect_url} <- Down.Utils.build_redirect_url(state) do
      {:ok, %{state.request | url: redirect_url}}
    end
  end

  defp build_new_request(%{response: %{status_code: status_code}} = state)
       when status_code in [301, 302, 303] do
    with {:ok, redirect_url} <- Down.Utils.build_redirect_url(state) do
      headers = Map.delete(state.request.headers, "Content-Type")

      request =
        Map.merge(state.request, %{
          method: :get,
          body: nil,
          headers: headers,
          url: redirect_url
        })

      {:ok, request}
    end
  end

  defp build_new_request(_), do: {:error, :invalid_redirect}

  defp ask_next_chunk_if_need_it(state, arg \\ :ignore)

  defp ask_next_chunk_if_need_it(state, :force_next_chunk),
    do: ask_next_chunk(state)

  defp ask_next_chunk_if_need_it(%{backend_data: nil}, _), do: :ok

  defp ask_next_chunk_if_need_it(state = %{operation: :stream, buffer: []}, _),
    do: ask_next_chunk(state)

  defp ask_next_chunk_if_need_it(%{operation: :stream}, _), do: :ok

  defp ask_next_chunk_if_need_it(%{operation: operation} = state, _)
       when operation in [:download, :read],
       do: ask_next_chunk(state)

  defp ask_next_chunk(%{backend: backend, backend_data: backend_data}),
    do: backend.next_chunk(backend_data)

  defp process_backend_action(actions, state) when is_list(actions) do
    Enum.reduce(actions, {:ok, state}, fn
      action, {:ok, state} ->
        process_backend_action(action, state)

      _action, ret ->
        ret
    end)
  end

  defp process_backend_action(:ignore, state), do: {:ok, state}

  defp process_backend_action(:done, state) do
    {:done, %{state | backend_data: nil}}
  end

  # Ibrowse return empty chunks sometimes
  defp process_backend_action({:chunk, ""}, state), do: {:ok, state}

  defp process_backend_action({:chunk, chunk}, %{position: position} = state) do
    with {:ok, state} <- perform_operation(chunk, state),
         position = position + byte_size(chunk),
         :ok <- check_max_size(position, state),
         :ok <- ask_next_chunk_if_need_it(state) do
      {:ok, %{state | position: position}}
    else
      {:error, error} ->
        {:error, %{state | error: error}}
    end
  end

  defp process_backend_action({:headers, headers}, state) do
    size = get_size_header(headers)
    encoding = get_encoding_header(headers)

    state =
      state
      |> put_in([:response, :headers], headers)
      |> put_in([:response, :size], size)
      |> put_in([:response, :encoding], encoding)

    with :ok <- check_max_size(headers, state),
         :ok <- verify_redirection(state) do
      {:ok, state}
    else
      {:redirect, _state} = ret ->
        ret

      {:error, error} ->
        {:error, %{state | error: error}}
    end
  end

  defp process_backend_action({:status_code, status_code}, state) do
    state = put_in(state, [:response, :status_code], status_code)

    with :ok <- verify_redirection(state), do: {:ok, state}
  end

  defp process_backend_action({:error, error}, state) do
    {:error, %{state | error: error}}
  end

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

  @redirect_status [301, 302, 303, 307, 308]

  defp verify_redirection(%{response: %{headers: []}}), do: :ok
  defp verify_redirection(%{response: %{status_code: nil}}), do: :ok

  defp verify_redirection(%{response: %{status_code: status}} = state)
       when status in @redirect_status,
       do: {:redirect, state}

  defp verify_redirection(_), do: :ok

  defp get_size_header(%{"content-length" => size}) when is_binary(size),
    do: String.to_integer(size)

  defp get_size_header(%{"content-length" => size}) when is_integer(size), do: size
  defp get_size_header(_), do: nil

  # defp get_encoding_header(%{"content-type" => size}) when is_integer(size), do: size
  defp get_encoding_header(_), do: nil

  @impl true
  def terminate(reason, %{file: file} = state) when not is_nil(file) do
    File.close(file)
    terminate(reason, %{state | file: nil})
  end

  def terminate(reason, %{backend_data: backend_data} = state) when not is_nil(backend_data) do
    state = stop_backend(state)
    terminate(reason, state)
  end

  def terminate(reason, %{client_pid: pid} = state) do
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

  defp stop_backend(%{backend: backend, backend_data: backend_data} = state) do
    backend.stop(backend_data)
    %{state | backend_data: nil}
  end

  defp check_max_size(_, %{max_size: nil}), do: :ok

  defp check_max_size(%{"content-length" => size}, %{max_size: max_size}) do
    if String.to_integer(size) > max_size, do: {:error, :too_large}, else: :ok
  end

  defp check_max_size(current_size, %{max_size: max_size})
       when is_integer(current_size) and current_size > max_size,
       do: {:error, :too_large}

  defp check_max_size(_, _), do: :ok

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
