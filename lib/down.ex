defmodule Down do
  @moduledoc """
  Down is a utility tool for streaming, flexible and safe downloading of remote
  files.

  Down is a thin wrapper around different HTTP backends focus on
  efficient and safe downloads.
  It also allows you to change backend without any code modification.

  The API is very small, it only consist in three operations:

  * `read/2` to download the content directly in memory.
  * `download/2` to download the content in a local file.
  * `stream/2` allows to have a a much more precise control of the download.

  ## Shared options

  All the Down operations accept the following options:

  * `:max_size` - The maximum size in bytes of the download.
    If the content is larger than this limit the function will return `{:error, :too_large}`.
  * `:headers` - A Keyword or a Map containing all request headers.
    The key and value are converted to strings.
  * `:method` - HTTP method used by the request.
    Possible values: `:get`, `:post`, `:delete`, `:put`, `:patch`, `:options`, `:head`, `:connect`, `:trace`.
    Default `:get`.
  * `:body`- HTTP body request in binary format. Default: `nil`.
  * `:backend` - The backend to use during for the request.
    Possible values: `:hackney`, `:httpc` and `:httpoison`.
  * `:backend_opts` - Additional options passed to the backend.
    Notice: Down uses some options to work with the backend. In case of conflict,
    Down options will be used.
  * `:total_timeout` - Timeout time for the request.
    The clock starts ticking when the request is sent.
    Time is in milliseconds.
    Default is `:infinity`.
  * `:recv_timeout` - If a persistent connection is idle longer than the `:recv_timeout`
    in milliseconds, the client closes the connection.
    The server can also have such a timeout but do not take that for granted.
    Default is 30_000.
    Only implemented for `:ibrowse` backend.
  * `:connect_timeout` - The time in milliseconds to wait for the request to connect,
    :infinity will wait indefinitely. The default is 15_000.
  """

  alias Down.Options

  @type url :: String.t()
  @type opts :: map() | Keyword.t()
  @type header :: {String.t(), String.t()}
  @type headers :: [header]

  @type method :: :get | :post | :delete | :put | :patch | :options | :head | :connect | :trace
  @type request :: %{
          url: url(),
          method: method(),
          # TODO
          body: term(),
          headers: list({String.t(), String.t()}),
          backend_opts: term(),
          total_timeout: timeout(),
          connect_timeout: timeout(),
          recv_timeout: timeout()
        }

  @type response :: %{
          # FIXME headers is a list
          headers: list({String.t(), String.t()}),
          status_code: nil | non_neg_integer(),
          size: nil | non_neg_integer(),
          encoding: nil | String.t()
        }

  @default_backend [Down.MintBackend, Down.HackneyBackend, Down.IbrowseBackend, Down.HttpcBackend]
                   |> Enum.find(&Code.ensure_loaded?(&1))
  @doc """
  Returns the backend used in case none is passed as an option in any operation.

  The value is fetched from the application environment `Application.get_env(:down, :backend)`.
  In case it is not set, it will return the first backend compiled from the following list:

  * `Down.MintBackend`
  * `Down.HackneyBackend`
  * `Down.IbrowseBackend`
  * `Down.HttpcBackend`

  Note that `Down.HttpcBackend` is always compiled and will be used in case
  no optional dependencies have been added.
  """
  def default_backend() do
    Application.get_env(:down, :backend, @default_backend)
  end

  @doc """
  Returns a stream with the content of the remote file.

  The remote connection isn't created until the first chunk is requested.
  """
  @spec stream(url, opts) :: {:ok, Stream.t()} | {:error, Down.Error.t()}
  def stream(url, opts \\ %{}) do
    with {:ok, opts} <- Options.build(url, opts) do
      start_fun = fn ->
        child = {Down.IO, opts}
        {:ok, pid} = DynamicSupervisor.start_child(Down.Supervisor, child)
        pid
      end

      next_fun = fn pid ->
        case GenServer.call(pid, :next_chunk) do
          :halt -> {:halt, pid}
          reply -> {[reply], pid}
        end
      end

      stop_fun = fn pid ->
        GenServer.stop(pid)
      end

      {:ok, Stream.resource(start_fun, next_fun, stop_fun)}
    end
  end

  @spec download(url(), opts()) :: Download.t()
  def download(url, opts \\ %{}), do: run(:download, url, opts)

  @doc """
  Returns {:ok, response} if the request is successful, {:error, reason} otherwise.
  """
  @spec read(url(), opts()) :: {:ok, String.t()} | {:error, Down.Error.t()}
  def read(url, opts \\ %{}) do
    with {:ok, stream} <- stream(url, opts) do
      read =
        stream
        |> Enum.to_list()
        |> IO.iodata_to_binary()

      {:ok, read}
    end
  end

  defp run(operation, url, opts) do
    with {:ok, opts} <- Options.build(url, opts),
         timeout = opts.total_timeout,
         args = {operation, self(), opts},
         child = {Down.Worker, args},
         {:ok, pid} <- DynamicSupervisor.start_child(Down.Supervisor, child) do
      ref = Process.monitor(pid)

      receive do
        {Down.Worker, ^pid, reply} ->
          Process.demonitor(ref, [:flush])
          reply

        {:DOWN, ^ref, _, _proc, reason} ->
          Process.demonitor(ref, [:flush])
          {:error, reason}
      after
        timeout ->
          Process.demonitor(ref, [:flush])
          Process.exit(pid, :normal)
          {:error, :timeout}
      end
    end
  end
end
