defmodule Down.TestBackend do
  alias Down.Backend
  @behaviour Backend

  @type state() :: pid()

  @impl true
  @spec start(Down.request(), pid()) :: {:ok, state(), Down.request()} | {:error, term()}
  def start(request, _pid) do
    pid = request.backend_opts
    send(pid, {__MODULE__, :start})
    {:ok, pid, request}
  end

  @impl true
  @spec demand_next(state()) :: state()
  def demand_next(pid) do
    send(pid, {__MODULE__, :demand_next})
    pid
  end

  @impl true
  @spec handle_message(state(), Backend.raw_message()) :: {Backend.actions(), state()}
  def handle_message(pid, message) do
    List.wrap(message) |> Enum.each(&send(pid, {__MODULE__, :handle_message, &1}))
    {message, pid}
  end

  @impl true
  @spec stop(state()) :: :ok
  def stop(pid) do
    send(pid, {__MODULE__, :stop})
    :ok
  end
end
