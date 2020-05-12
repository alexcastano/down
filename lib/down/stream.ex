defmodule Down.Stream do
  def new(opts) do
    Stream.resource(
      fn -> stream_start(opts) end,
      fn pid -> stream_continue(pid) end,
      fn pid -> stream_stop(pid) end
    )
  end

  defp stream_start(opts) do
    # FIXME timeout
    # gen_opts = [debug: [:statistics, :trace]]
    # timeout = Map.get(opts, :timeout, 5000)
    # gen_opts = [timeout: timeout, debug: [:statistics, :trace]]
    # gen_opts = [timeout: timeout]
    child = {Down.Worker, {:stream, self(), opts}}

    {:ok, pid} = DynamicSupervisor.start_child(Down.Supervisor, child)
    pid
  end

  defp stream_continue(pid) do
    case GenServer.call(pid, :next_chunk) do
      :halt -> {:halt, pid}
      reply -> {[reply], pid}
    end
  end

  defp stream_stop(pid), do: GenServer.stop(pid)
end
