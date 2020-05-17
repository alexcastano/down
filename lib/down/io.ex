defmodule Down.IO do
  @moduledoc false

  alias Down.Options

  # FIXME opaque? or private type
  @type operation :: :chunk | :status_code | :resp_headers
  @type operation_request :: {operation, GenServer.from()}
  @type status ::
          :connecting
          | :redirecting
          | :getting_headers
          | :getting_body
          | :completed
          | :cancelled
          | :error

  @type state :: %{
          backend: Down.Backend.t(),
          backend_data: term(),
          buffer: :queue.queue(String.t()),
          buffer_size: non_neg_integer(),
          current_redirects: integer(),
          demanded_next?: boolean(),
          destination: nil | String.t(),
          error: nil | term(),
          max_redirects: :infinity | non_neg_integer(),
          max_size: nil | non_neg_integer(),
          min_buffer_size: non_neg_integer(),
          pending_data_replies: :queue.queue(operation_request()),
          pending_info_replies: list(),
          position: non_neg_integer(),
          request: Down.request(),
          response: Down.response(),
          status: status()
        }

  use GenServer, restart: :transient

  defguard finished?(state) when :erlang.map_get(:backend_data, state) == nil

  def start_link(url, opts \\ []) do
    with {:ok, opts} <- Options.build(url, opts) do
      # gen_opts = [debug: [:statistics, :trace]]
      gen_opts = []
      GenServer.start_link(__MODULE__, opts, gen_opts)
    end
  end

  @spec status_code(pid()) :: {:ok, integer()} | {:error, any()}
  def status_code(pid) do
    GenServer.call(pid, :status_code)
  end

  @spec resp_headers(pid()) :: {:ok, Down.headers()} | {:error, any()}
  def resp_headers(pid) do
    GenServer.call(pid, :resp_headers)
  end

  @spec chunk(pid()) :: {:ok, String.t()} | {:ok, :eof} | {:error, any()}
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

  @impl true
  @spec init(Options.t()) :: {:ok, state(), {:continue, :start}}
  def init(%Options{} = opts) do
    request = build_req(opts)

    state = %{
      backend: opts.backend,
      backend_data: nil,
      buffer: :queue.new(),
      buffer_size: 0,
      current_redirects: 0,
      demanded_next?: false,
      destination: opts.destination,
      error: nil,
      max_redirects: opts.max_redirects,
      max_size: opts.max_size,
      min_buffer_size: opts.buffer_size,
      pending_data_replies: :queue.new(),
      pending_info_replies: [],
      position: 0,
      request: request,
      response: new_response(),
      status: :connecting
    }

    {:ok, state, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, state) do
    with {:ok, backend_data, request} <- state.backend.start(state.request, self()) do
      {:noreply, %{state | backend_data: backend_data, request: request}}
    else
      {:error, reason} -> {:stop, :normal, %{state | error: reason}}
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
  def handle_call(:status_code, from, %{response: %{status_code: nil}} = state) do
    state =
      state
      |> add_pending_info_reply({:status_code, from})
      |> maybe_demand_next()

    {:noreply, state}
  end

  def handle_call(:status_code, _from, %{response: %{status_code: status}} = state) do
    {:reply, {:ok, status}, state}
  end

  @impl true
  def handle_call(:resp_headers, from, %{response: %{headers: nil}} = state) do
    state =
      state
      |> add_pending_info_reply({:resp_headers, from})
      |> maybe_demand_next()

    {:noreply, state}
  end

  def handle_call(:resp_headers, _from, %{response: %{headers: resp_headers}} = state) do
    {:reply, {:ok, resp_headers}, state}
  end

  def handle_call(:chunk, _from, state) when finished?(state) do
    case pop_buffer(state) do
      :empty -> {:reply, {:ok, :eof}, state}
      {:value, chunk, state} -> {:reply, {:ok, chunk}, state}
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
        {:reply, {:ok, chunk}, maybe_demand_next(state)}
    end
  end

  def handle_call(:cancel, _from, state) do
    state =
      state
      |> maybe_stop_backend()
      |> maybe_reply_to_clients()

    {:reply, :ok, state}
  end

  @spec add_pending_info_reply(state(), operation_request()) :: state()
  def add_pending_info_reply(state, operation) do
    Map.update!(state, :pending_info_replies, &[operation | &1])
  end

  @spec append_pending_reply(state(), operation_request()) :: state()
  defp append_pending_reply(state, request) do
    Map.update!(state, :pending_data_replies, &:queue.in(request, &1))
  end

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

  @impl true
  def handle_info(:timeout, state) do
    {:stop, :normal, %{state | error: :timeout}}
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

    with :ok <- verify_no_errors(state),
         :ok <- verify_no_redirect(state),
         :ok <- verify_max_size(state) do
      state =
        state
        |> maybe_reply_to_clients()
        |> maybe_demand_next()

      {:noreply, state}
    end
  end

  @spec verify_no_errors(state()) :: :ok | {:stop, :normal, state()}
  defp verify_no_errors(%{error: nil}), do: :ok
  defp verify_no_errors(state), do: {:stop, :normal, state}

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
         {:ok, backend_data, request} <- backend.start(state.request, self()) do
      {:ok, %{state | request: request, backend_data: backend_data}}
    end
  end

  @spec build_redirected_state(state(), String.t()) :: state()
  defp build_redirected_state(state, redirect_url) do
    Map.merge(state, %{
      request: build_new_request(state, redirect_url),
      response: new_response(),
      position: 0,
      buffer: :queue.new(),
      buffer_size: 0,
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

  defp maybe_reply_to_clients(state) do
    state
    |> maybe_reply_info_to_clients()
    |> maybe_reply_data_to_clients()
  end

  defp maybe_reply_info_to_clients(%{pending_info_replies: []} = state) do
    state
  end

  defp maybe_reply_info_to_clients(state) do
    Map.update!(state, :pending_info_replies, fn pendings ->
      Enum.filter(pendings, fn
        {:status_code, from} ->
          if state.response.status_code do
            GenServer.reply(from, {:ok, state.response.status_code})
            false
          else
            true
          end

        {:resp_headers, from} ->
          if state.response.headers do
            GenServer.reply(from, {:ok, state.response.headers})
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

  defp maybe_reply_data_to_clients(state, %{buffer_empty?: true}) when finished?(state) do
    :queue.to_list(state.pending_data_replies)
    |> Enum.each(fn
      {:chunk, from} ->
        GenServer.reply(from, {:ok, :eof})
    end)

    %{state | pending_data_replies: :queue.new()}
  end

  defp maybe_reply_data_to_clients(state, %{buffer_empty?: true}) do
    state
  end

  defp maybe_reply_data_to_clients(state, _) do
    {:value, chunk, state} = pop_buffer(state)

    case pop_pending_reply(state) do
      {:value, :chunk, from, state} ->
        GenServer.reply(from, {:ok, chunk})
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
    %{state | backend_data: nil}
  end

  # Ibrowse return empty chunks sometimes
  defp process_backend_action({:chunk, ""}, state), do: state

  defp process_backend_action({:chunk, chunk}, state) do
    add_chunk_to_buffer(state, chunk)
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
    put_in(state, [:response, :status_code], status_code)
  end

  defp process_backend_action({:error, error}, state), do: %{state | error: error}

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

  defp maybe_stop_backend(state) when finished?(state), do: state

  defp maybe_stop_backend(%{backend: backend, backend_data: backend_data} = state) do
    backend.stop(backend_data)
    %{state | backend_data: nil}
  end
end
