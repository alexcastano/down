defmodule Down.IOTest do
  use ExUnit.Case, async: true

  alias Down.TestBackend

  setup do
    opts = [backend: TestBackend, backend_opts: self()]
    bypass = Bypass.open()
    {:ok, bypass: bypass, opts: opts}
  end

  defp open(opts, status_code \\ 200, headers \\ []) do
    assert {:ok, pid} = Down.open("http://localhost/", opts)
    assert_receive {TestBackend, :start}

    status_msg = {:status_code, status_code}
    headers_msg = {:headers, headers}
    send(pid, [status_msg, headers_msg])

    assert_receive {TestBackend, :handle_message, ^status_msg}
    assert_receive {TestBackend, :handle_message, ^headers_msg}
    pid
  end

  defp send_chunk(pid, chunk) do
    msg = {:chunk, chunk}
    send(pid, msg)
    assert_receive {TestBackend, :handle_message, ^msg}
  end

  defmacro assert_next_receive(pattern, timeout \\ 100) do
    quote do
      receive do
        message ->
          assert unquote(pattern) = message
      after
        unquote(timeout) ->
          # you might want to raise a better message here
          raise "timeout"
      end
    end
  end

  describe "start_link/2" do
    test "detect invalid urls" do
      assert {:error, %Down.Error{reason: :invalid_url}} = Down.IO.start_link("https://")

      assert {:error, %Down.Error{reason: :invalid_url}} =
               Down.IO.start_link("ftp://elixir-lang.com")

      assert {:error, %Down.Error{reason: :invalid_url}} =
               Down.IO.start_link("https://elixir-lang.com:66666")
    end

    test "detect invalid options" do
      assert {:error, %Down.Error{reason: :invalid_method}} =
               Down.IO.start_link("https://elixir-lang.com/", method: :load)
    end
  end

  describe "status_code/1" do
    test "works", %{opts: opts} do
      opts = [{:buffer_size, 0} | opts]
      pid = open(opts, 203)
      assert {:ok, 203} = Down.IO.status_code(pid)
      assert :ok = Down.IO.cancel(pid)
      assert {:ok, 203} = Down.IO.status_code(pid)
    end

    test "returns cancelled" do
    end

    test "returns errors" do
    end

    test "with buffer_size: 0, demands chunks when it is needed", %{opts: opts} do
      opts = [{:buffer_size, 0} | opts]
      assert {:ok, pid} = Down.open("http://localhost/", opts)
      assert_receive {TestBackend, :start}
      refute_receive {TestBackend, :demand_next}

      parent = self()

      spawn(fn ->
        assert {:ok, 200} = Down.IO.status_code(pid)
        send(parent, :status_received)
      end)

      refute_receive :status_received
      assert_received {TestBackend, :demand_next}

      send(pid, {:status_code, 200})
      assert_receive :status_received

      assert {:ok, 200} = Down.IO.status_code(pid)
      refute_received {TestBackend, :demand_next}

      Down.IO.close(pid)
    end

    test "responds as soon as possible", %{opts: opts} do
      opts
    end
  end

  describe "resp_headers/1" do
    test "works", %{opts: opts} do
    end

    test "returns cancelled" do
    end

    test "returns errors" do
    end

    test "with buffer_size: 0, demands with resp_headers/1", %{opts: opts} do
      opts = [{:buffer_size, 0} | opts]
      assert {:ok, pid} = Down.open("http://localhost/", opts)
      assert_receive {TestBackend, :start}
      refute_receive {TestBackend, :demand_next}

      parent = self()

      spawn(fn ->
        assert {:ok, []} = Down.IO.resp_headers(pid)
        send(parent, :headers_received)
      end)

      refute_receive :headers_received
      assert_received {TestBackend, :demand_next}

      send(pid, {:status_code, 200})
      assert_receive {TestBackend, :handle_message, {:status_code, 200}}
      assert_receive {TestBackend, :demand_next}
      refute_receive :headers_received

      send(pid, {:headers, []})
      assert_receive :headers_received

      refute_received {TestBackend, :demand_next}

      Down.IO.close(pid)
    end

    test "responds as soon as possible", %{opts: opts} do
      opts
    end
  end

  describe "chunk/1" do
    test "with buffer_size: 0 demands with chunk/1", %{opts: opts} do
      opts = [{:buffer_size, 0} | opts]
      assert {:ok, pid} = Down.open("http://localhost/", opts)
      assert_next_receive({TestBackend, :start})
      refute_receive {TestBackend, :demand_next}

      parent = self()

      spawn(fn ->
        assert {:ok, "chunk"} = Down.IO.chunk(pid)
        send(parent, :chunk_received)
      end)

      refute_receive :chunk_received
      assert_receive {TestBackend, :demand_next}

      send(pid, {:status_code, 200})
      assert_receive {TestBackend, :handle_message, {:status_code, 200}}
      assert_receive {TestBackend, :demand_next}
      refute_receive :chunk_received

      send(pid, {:headers, []})
      assert_receive {TestBackend, :handle_message, {:headers, []}}
      assert_receive {TestBackend, :demand_next}
      refute_receive :chunk_received

      send(pid, {:chunk, "chunk"})
      assert_receive {TestBackend, :handle_message, {:chunk, "chunk"}}
      assert_receive :chunk_received
      refute_receive {TestBackend, :demand_next}

      Down.IO.close(pid)
    end

    test "demands chunks until buffer size is achieve", %{opts: opts} do
      opts = [{:buffer_size, 3} | opts]
      pid = open(opts)
      assert_receive {TestBackend, :demand_next}

      send_chunk(pid, "1")
      assert_receive {TestBackend, :demand_next}

      send_chunk(pid, "2")
      assert_receive {TestBackend, :demand_next}

      send_chunk(pid, "3")
      refute_receive {TestBackend, :demand_next}

      parent = self()

      spawn(fn ->
        assert {:ok, "1"} = Down.IO.chunk(pid)
        send(parent, :chunk_received)
      end)

      assert_receive :chunk_received
      assert_received {TestBackend, :demand_next}

      send_chunk(pid, "456")
      refute_receive {TestBackend, :demand_next}

      assert {:ok, "2"} = Down.IO.chunk(pid)
      refute_receive {TestBackend, :demand_next}

      assert {:ok, "3"} = Down.IO.chunk(pid)
      refute_receive {TestBackend, :demand_next}

      assert {:ok, "456"} = Down.IO.chunk(pid)
      assert_received {TestBackend, :demand_next}

      Down.IO.close(pid)
    end

    test "returns cancelled" do
    end

    test "returns errors" do
    end

    test "returns :eof" do
    end
  end

  describe "cancel/1" do
    test "set status to :cancelled" do
    end

    test "replies pending requests" do
    end

    test "doesn't handle more backend messages" do
    end
  end

  describe "flush/1" do
    test "returns inmediatly the buffer content" do
    end

    test "returns cancelled" do
    end

    test "returns errors" do
    end

    test "returns :eof" do
    end
  end

  describe "close/1" do
    test "stops process", %{opts: opts} do
      opts = [{:buffer_size, 0} | opts]
      pid = open(opts)
      assert Process.alive?(pid)
      assert :ok = Down.IO.close(pid)
      assert_next_receive({TestBackend, :stop})
      refute Process.alive?(pid)
    end
  end

  describe "info/2" do
  end

  describe "info/1" do
  end

  test "starts and stops", %{opts: opts} do
    {:ok, pid} = Down.open("http://localhost/", opts)
    assert_receive {TestBackend, :start}

    send(pid, :done)
    assert_receive {TestBackend, :handle_message, :done}
    refute_receive {TestBackend, :stop}
  end
end
