defmodule Down.IO do
  @moduledoc false

  alias Down.Options

  # FIXME opaque? or private type
  @type operation :: :chunk | :status_code | :resp_headers
  @type operation_request :: {operation, GenServer.from()}
  @type status ::
          :connecting
          | :redirecting
          | :streaming
          | :completed
          | :cancelled
          | :error

  @type redirection :: %{
          url: Down.url(),
          status_code: non_neg_integer(),
          headers: Down.headers()
        }

  @type state :: %{
          backend: Down.Backend.t(),
          backend_data: term(),
          buffer: :queue.queue(String.t()),
          buffer_size: non_neg_integer(),
          demanded_next?: boolean(),
          error: nil | term(),
          max_redirections: :infinity | non_neg_integer(),
          max_size: nil | non_neg_integer(),
          min_buffer_size: non_neg_integer(),
          pending_data_replies: :queue.queue(operation_request()),
          pending_info_replies: list(),
          position: non_neg_integer(),
          redirections: [redirection()],
          request: Down.request(),
          response: Down.response(),
          status: status()
        }

  @type info_request :: :status | :buffer_size
  @info_request [
    :buffer_size,
    :error,
    :max_redirections,
    :min_buffer_size,
    :position,
    :redirections,
    :request,
    :response,
    :status
  ]

  use GenServer, restart: :transient

  defguard finished?(state)
           when :erlang.map_get(:status, state) in [:completed, :cancelled, :error]

  # @spec start_link(String.t(), Keyword.t()) :: GenServer.on_start()
  def start_link(url, opts \\ []) do
    with {:ok, opts} <- Options.build(url, opts) do
      # gen_opts = [debug: [:statistics, :trace]]
      gen_opts = []
      GenServer.start_link(__MODULE__, opts, gen_opts)
    end
  end

  @spec status_code(pid()) :: integer() | nil
  def status_code(pid) do
    GenServer.call(pid, :status_code)
  end

  @spec resp_headers(pid()) :: Down.headers() | nil
  def resp_headers(pid) do
    GenServer.call(pid, :resp_headers)
  end

  @spec chunk(pid()) :: String.t() | :eof | nil
  def chunk(pid) do
    GenServer.call(pid, :chunk)
  end

  @spec cancel(pid()) :: :ok
  def cancel(pid) do
    GenServer.call(pid, :cancel)
  end

  @spec close(pid()) :: :ok
  def close(pid) do
    GenServer.stop(pid)
  end

  def info(pid, request) when request in @info_request do
    GenServer.call(pid, {:info, request})
  end

  # TODO TESTS
  def info(pid, requests) when is_list(requests) do
    Enum.each(requests, &(&1 in @info_request || raise(ArgumentError, inspect(&1))))
    GenServer.call(pid, {:info, requests})
  end

  @impl true
  @spec init(Options.t()) :: {:ok, state(), {:continue, :start}}
  def init(%Options{} = opts) do
    request = build_req(opts)

    state = %{
      backend: opts.backend,
      backend_data: nil,
      buffer: :queue.new(),
      buffer_size: 0,
      demanded_next?: false,
      error: nil,
      max_redirections: opts.max_redirections,
      max_size: opts.max_size,
      min_buffer_size: opts.buffer_size,
      pending_data_replies: :queue.new(),
      pending_info_replies: [],
      position: 0,
      redirections: [],
      request: request,
      response: new_response(),
      status: :connecting
    }

    {:ok, state, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, state) do
    with {:ok, state} <- start_backend(state) do
      {:noreply, state}
    else
      {:error, reason} -> {:stop, :normal, %{state | error: reason}}
    end
  end

  defp start_backend(state) do
    with {:ok, backend_data, request} <- state.backend.start(state.request, self()) do
      {:ok, %{state | backend_data: backend_data, request: request}}
    end
  end

  @spec new_response() :: Down.response()
  defp new_response(), do: %{headers: nil, status_code: nil, size: nil, encoding: nil}

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
  def handle_call(:status_code, _from, state) when finished?(state) do
    {:reply, state.response.status_code, state}
  end

  def handle_call(:status_code, from, %{response: %{status_code: nil}} = state) do
    state =
      state
      |> add_pending_info_reply({:status_code, from})
      |> maybe_demand_next()

    {:noreply, state}
  end

  def handle_call(:status_code, _from, %{response: %{status_code: status}} = state) do
    {:reply, status, state}
  end

  @impl true
  def handle_call(:resp_headers, _from, state) when finished?(state) do
    {:reply, state.response.headers, state}
  end

  def handle_call(:resp_headers, from, %{response: %{headers: nil}} = state) do
    state =
      state
      |> add_pending_info_reply({:resp_headers, from})
      |> maybe_demand_next()

    {:noreply, state}
  end

  def handle_call(:resp_headers, _from, %{response: %{headers: resp_headers}} = state) do
    {:reply, resp_headers, state}
  end

  def handle_call(:chunk, _from, %{status: status} = state)
      when status in [:cancelled, :error] do
    {:reply, nil, state}
  end

  def handle_call(:chunk, _from, state) when finished?(state) do
    case pop_buffer(state) do
      :empty -> {:reply, :eof, state}
      {:value, chunk, state} -> {:reply, chunk, state}
    end
  end

  def handle_call(:chunk, from, state) do
    case pop_buffer(state) do
      :empty ->
        state =
          state
          |> append_pending_reply({:chunk, from})
          |> maybe_demand_next()

        {:noreply, state}

      {:value, chunk, state} ->
        {:reply, chunk, maybe_demand_next(state)}
    end
  end

  def handle_call({:info, :status}, _from, state) do
    {:reply, state.status, state}
  end

  def handle_call({:info, :buffer_size}, _from, state) do
    {:reply, state.buffer_size, state}
  end

  def handle_call({:info, :error}, _from, state) do
    {:reply, state.error, state}
  end

  def handle_call(:cancel, _from, state) do
    {:reply, :ok, cancel(state, :cancelled)}
  end

  @spec pop_buffer(state()) :: {:value, binary(), state()} | :empty
  defp pop_buffer(state) do
    case :queue.out(state.buffer) do
      {{:value, chunk}, buffer} ->
        chunk_size = byte_size(chunk)

        state =
          state
          |> Map.put(:buffer, buffer)
          |> Map.update!(:buffer_size, &(&1 - chunk_size))

        {:value, chunk, state}

      {:empty, _} ->
        :empty
    end
  end

  defp cancel(state, :cancelled) do
    state
    |> set_status(:cancelled)
    |> maybe_stop_backend()
    |> maybe_reply_to_clients()
  end

  defp cancel(state, {:error, error}) do
    state
    |> set_status(:error)
    |> Map.put(:error, error)
    |> maybe_stop_backend()
    |> maybe_reply_to_clients()
  end

  @spec set_status(state(), status()) :: state()
  defp set_status(state, status) do
    Map.put(state, :status, status)
  end

  @spec add_pending_info_reply(state(), operation_request()) :: state()
  def add_pending_info_reply(state, operation) do
    Map.update!(state, :pending_info_replies, &[operation | &1])
  end

  @spec append_pending_reply(state(), operation_request()) :: state()
  defp append_pending_reply(state, request) do
    Map.update!(state, :pending_data_replies, &:queue.in(request, &1))
  end

  @impl true
  def handle_info(:timeout, state) do
    {:stop, :normal, %{state | error: :timeout}}
  end

  def handle_info(_msg, state) when finished?(state) do
    {:noreply, state}
  end

  def handle_info(msg, state) do
    msg
    |> backend_handle_message(state)
    |> handle_backend_actions(state)
  end

  defp backend_handle_message(msg, %{backend: backend, backend_data: backend_data}) do
    backend.handle_message(backend_data, msg)
  end

  defp handle_backend_actions({action, backend_data}, state) do
    state = %{state | demanded_next?: false, backend_data: backend_data}

    state = process_backend_action(action, state)

    case maybe_redirect(state) do
      {:break, state} ->
        {:noreply, state}

      :no_redirect ->
        state =
          state
          |> verify_max_size()
          |> maybe_reply_to_clients()
          |> maybe_demand_next()

        {:noreply, state}
    end
  end

  @spec verify_max_size(state()) :: state()
  defp verify_max_size(%{max_size: nil} = state), do: state

  defp verify_max_size(state = %{position: current_size, max_size: max_size})
       when is_integer(current_size) and current_size > max_size do
    cancel(state, {:error, :too_large})
  end

  defp verify_max_size(state), do: state

  @redirect_status [301, 302, 303, 307, 308]

  @spec maybe_redirect(state()) :: :no_redirect | {:break, state}
  defp maybe_redirect(%{response: %{headers: headers}}) when headers == [], do: :no_redirect

  defp maybe_redirect(%{response: %{status_code: status}} = state)
       when status in @redirect_status do
    state
    |> maybe_stop_backend()
    |> maybe_follow_redirect()
    |> case do
      {:ok, state} -> {:break, state}
      {:error, error} -> {:break, cancel(state, {:error, error})}
    end
  end

  defp maybe_redirect(_), do: :no_redirect

  @spec follow_redirect(state) :: {:ok, state()} | {:error, term()}
  defp maybe_follow_redirect(state) do
    if length(state.redirections) >= state.max_redirections do
      {:error, :too_many_redirects}
    else
      follow_redirect(state)
    end
  end

  defp follow_redirect(state) do
    with {:ok, redirect_url} <- build_redirect_url(state),
         state = build_redirected_state(state, redirect_url),
         {:ok, state} <- start_backend(state) do
      {:ok, state}
    end
  end

  @spec build_redirected_state(state(), String.t()) :: state()
  defp build_redirected_state(state, redirect_url) do
    redirection = %{
      status_code: state.response.status_code,
      headers: state.response.headers,
      url: state.request.url
    }

    Map.merge(state, %{
      request: build_new_request(state, redirect_url),
      response: new_response(),
      position: 0,
      buffer: :queue.new(),
      buffer_size: 0,
      status: :redirecting
    })
    |> Map.update!(:redirections, &[redirection | &1])
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
    headers
    |> List.keyfind("location", 0)
    |> case do
      nil ->
        {:error, :invalid_redirect}

      {"location", redirect_url} ->
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

  defp maybe_reply_to_clients(state) do
    state
    |> maybe_reply_info_to_clients()
    |> maybe_reply_data_to_clients()
  end

  defp maybe_reply_info_to_clients(%{pending_info_replies: []} = state) do
    state
  end

  defp maybe_reply_info_to_clients(state) when finished?(state) do
    Enum.each(state.pending_info_replies, fn
      {:status_code, from} -> GenServer.reply(from, state.response.status_code)
      {:resp_headers, from} -> GenServer.reply(from, state.response.headers)
    end)

    %{state | pending_info_replies: []}
  end

  defp maybe_reply_info_to_clients(state) do
    Map.update!(state, :pending_info_replies, fn pendings ->
      Enum.filter(pendings, fn
        {:status_code, from} ->
          if state.response.status_code do
            GenServer.reply(from, state.response.status_code)
            false
          else
            true
          end

        {:resp_headers, from} ->
          if state.response.headers do
            GenServer.reply(from, state.response.headers)
            false
          else
            true
          end
      end)
    end)
  end

  defp maybe_reply_data_to_clients(state) do
    maybe_reply_data_to_clients(
      state,
      %{
        buffer_empty?: :queue.is_empty(state.buffer),
        pending_replies_empty?: :queue.is_empty(state.pending_data_replies)
      }
    )
  end

  defp maybe_reply_data_to_clients(state, %{pending_replies_empty?: true}) do
    state
  end

  defp maybe_reply_data_to_clients(%{status: status} = state, %{buffer_empty?: true})
       when status in [:cancelled, :error] do
    :queue.to_list(state.pending_data_replies)
    |> Enum.each(fn {:chunk, from} -> GenServer.reply(from, nil) end)

    %{state | pending_data_replies: :queue.new()}
  end

  defp maybe_reply_data_to_clients(state, %{buffer_empty?: true}) when finished?(state) do
    :queue.to_list(state.pending_data_replies)
    |> Enum.each(fn {:chunk, from} -> GenServer.reply(from, :eof) end)

    %{state | pending_data_replies: :queue.new()}
  end

  defp maybe_reply_data_to_clients(state, %{buffer_empty?: true}) do
    state
  end

  defp maybe_reply_data_to_clients(state, _) do
    {:value, chunk, state} = pop_buffer(state)

    case pop_pending_reply(state) do
      {:value, :chunk, from, state} ->
        GenServer.reply(from, chunk)
        maybe_reply_data_to_clients(state)
    end
  end

  defp pop_pending_reply(state) do
    state
    |> Map.fetch!(:pending_data_replies)
    |> :queue.out()
    |> case do
      {:empty, pendings} ->
        {:empty, %{state | pending_data_replies: pendings}}

      {{:value, {operation, from}}, pendings} ->
        {:value, operation, from, %{state | pending_data_replies: pendings}}
    end
  end

  @spec maybe_demand_next(state()) :: state()
  defp maybe_demand_next(state) when finished?(state), do: state

  defp maybe_demand_next(%{demanded_next?: true} = state), do: state

  defp maybe_demand_next(%{buffer_size: current, min_buffer_size: min} = state)
       when current < min do
    demand_next(state)
  end

  defp maybe_demand_next(state) do
    cond do
      pending_replies?(state) -> demand_next(state)
      true -> state
    end
  end

  defp pending_replies?(state) do
    !:queue.is_empty(state.pending_data_replies) ||
      !Enum.empty?(state.pending_info_replies)
  end

  @spec demand_next(state()) :: state()
  defp demand_next(state = %{backend: backend, backend_data: backend_data}) do
    backend_data = backend.demand_next(backend_data)
    %{state | backend_data: backend_data, demanded_next?: true}
  end

  @spec process_backend_action(Down.Backend.actions(), state()) :: state()
  defp process_backend_action(actions, state) when is_list(actions) do
    Enum.reduce(actions, state, &process_backend_action/2)
  end

  defp process_backend_action({:ignore, _}, state), do: state

  defp process_backend_action(:done, state) do
    state
    |> Map.put(:backend_data, nil)
    |> set_status(:completed)
  end

  # Ibrowse return empty chunks sometimes
  defp process_backend_action({:chunk, ""}, state), do: state

  defp process_backend_action({:chunk, chunk}, state) do
    state
    |> add_chunk_to_buffer(chunk)
  end

  defp process_backend_action({:headers, headers}, state) do
    size = get_size_header(headers)
    encoding = get_encoding_header(headers)

    state
    # FIXME headers can be later too?
    |> put_in([:response, :headers], headers)
    |> put_in([:response, :size], size)
    |> put_in([:response, :encoding], encoding)
  end

  defp process_backend_action({:status_code, status_code}, state) do
    state
    |> put_in([:response, :status_code], status_code)
    |> set_status(:streaming)
  end

  defp process_backend_action({:error, error}, state) do
    state
    |> Map.put(:error, error)
    |> set_status(:error)
  end

  defp add_chunk_to_buffer(state, chunk) do
    chunk_size = byte_size(chunk)

    state
    |> Map.update!(:buffer_size, &(&1 + chunk_size))
    |> Map.update!(:position, &(&1 + chunk_size))
    |> Map.update!(:buffer, &:queue.in(chunk, &1))
  end

  defp get_size_header(%{"content-length" => size}) when is_binary(size),
    do: String.to_integer(size)

  defp get_size_header(%{"content-length" => size}) when is_integer(size), do: size
  defp get_size_header(_), do: nil

  # defp get_encoding_header(%{"content-type" => size}) when is_integer(size), do: size
  defp get_encoding_header(_), do: nil

  @impl true
  def terminate(_reason, state) do
    maybe_stop_backend(state)
  end

  defp maybe_stop_backend(%{backend_data: nil} = state), do: state

  defp maybe_stop_backend(%{backend: backend, backend_data: backend_data} = state) do
    backend.stop(backend_data)
    %{state | backend_data: nil}
  end
end
