defmodule Down do
  @moduledoc """
  Down is a utility tool for streaming, flexible and safe downloading of remote
  files.

  Down is a thin wrapper around different HTTP backends focus on
  efficient and safe downloads.
  It also allows you to change backend without any code modification.

  The API is very small, it only consist in three operationsÑ

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
    Default is 120000 (= 2 min).
    Only implemented for `:ibrowse` backend.
  * `:connect_timeout` - The time in milliseconds to wait for the request to connect,
    :infinity will wait indefinitely (default: 15_000).
  """

  @type url :: String.t()
  @type opts :: map() | Keyword.t()

  @type method :: :get | :post | :delete | :put | :patch | :options | :head | :connect | :trace
  @type request :: %{
          url: url(),
          method: method(),
          # TODO
          body: term(),
          headers: map(),
          backend_opts: term(),
          total_timeout: timeout(),
          connect_timeout: timeout(),
          recv_timeout: timeout()
        }

  @type response :: %{
          # FIXME headers is a list
          headers: map(),
          status_code: nil | non_neg_integer(),
          size: nil | non_neg_integer(),
          encoding: nil | String.t()
        }

  @doc """
  Returns a stream with the content of the remote file.

  The remote connection isn't created until the first chunk is requested.
  """
  @spec stream(url, opts) :: Stream.t()
  def stream(url, opts \\ %{})
  def stream(url, opts) when is_list(opts), do: stream(url, opts |> Enum.into(%{}))
  def stream(url, opts) when is_map(opts), do: Down.Stream.new(url, opts)

  @spec download(url(), opts()) :: Download.t()
  def download(url, opts \\ %{}), do: run(:download, url, opts)

  @doc """
  Returns {:ok, response} if the request is successful, {:error, reason} otherwise.
  """
  @spec read(url(), opts()) :: String.t()
  def read(url, opts \\ %{}), do: run(:read, url, opts)

  defp run(operation, url, opts) when is_list(opts), do: run(operation, url, Enum.into(opts, %{}))

  defp run(operation, url, opts) do
    args = {url, operation, self(), opts}
    timeout = Map.get(opts, :total_timeout, :infinity)
    child = {Down.Worker, args}

    # with {:ok, pid} <- Down.Supervisor.start_child(args) do
    with {:ok, pid} <- DynamicSupervisor.start_child(Down.Supervisor, child) do
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
