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
    TestBackend.fake_message(pid, [status_msg, headers_msg])

    assert_receive {TestBackend, :handle_message, ^status_msg}
    assert_receive {TestBackend, :handle_message, ^headers_msg}
    pid
  end

  defp send_chunk(pid, chunk) do
    msg = {:chunk, chunk}
    TestBackend.fake_message(pid, msg)
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
      pid = open(opts, 203)
      assert 203 == Down.IO.status_code(pid)
      assert :ok == Down.IO.cancel(pid)
      assert 203 == Down.IO.status_code(pid)
    end

    test "returns nil when cancelled before getting it", %{opts: opts} do
      assert {:ok, pid} = Down.open("http://localhost/", opts)

      parent = self()

      spawn(fn ->
        send(parent, :status_requested)
        assert nil == Down.IO.resp_headers(pid)
        send(parent, :status_received)
      end)

      assert_receive :status_requested
      assert :ok == Down.IO.cancel(pid)
      assert nil == Down.IO.status_code(pid)

      assert_receive :status_received
    end

    test "returns nil when errors", %{opts: opts} do
      assert {:ok, pid} = Down.open("http://localhost/", opts)

      parent = self()

      spawn(fn ->
        send(parent, :status_requested)
        assert nil == Down.IO.resp_headers(pid)
        send(parent, :status_received)
      end)

      assert_receive :status_requested
      TestBackend.fake_message(pid, {:error, :unknown})
      assert nil == Down.IO.status_code(pid)

      assert_receive :status_received
    end

    test "with buffer_size: 0, demands chunks when it is needed", %{opts: opts} do
      opts = [{:buffer_size, 0} | opts]
      assert {:ok, pid} = Down.open("http://localhost/", opts)
      assert_receive {TestBackend, :start}
      refute_receive {TestBackend, :demand_next}

      parent = self()

      spawn(fn ->
        assert 200 = Down.IO.status_code(pid)
        send(parent, :status_received)
      end)

      refute_receive :status_received
      assert_received {TestBackend, :demand_next}

      TestBackend.fake_message(pid, {:status_code, 200})
      assert_receive :status_received

      assert 200 = Down.IO.status_code(pid)
      refute_received {TestBackend, :demand_next}
    end

    test "responds as soon as possible", %{opts: opts} do
      assert {:ok, pid} = Down.open("http://localhost/", opts)
      assert_receive {TestBackend, :start}
      refute_receive {TestBackend, :demand_next}

      parent = self()

      spawn(fn ->
        assert Down.IO.chunk(pid)
        send(parent, :chunk_received)
      end)

      assert_receive {TestBackend, :demand_next}

      spawn(fn ->
        assert 200 = Down.IO.status_code(pid)
        send(parent, :status_received)
      end)

      refute_receive {TestBackend, :demand_next}

      TestBackend.fake_message(pid, {:status_code, 200})
      assert_receive :status_received

      refute_receive :chunk_received
    end
  end

  describe "resp_headers/1" do
    test "works", %{opts: opts} do
      headers = [{"foo", "bar"}]
      pid = open(opts, 203, headers)
      assert headers == Down.IO.resp_headers(pid)
      assert :ok == Down.IO.cancel(pid)
      assert headers == Down.IO.resp_headers(pid)
    end

    test "returns nil when cancelled before getting it", %{opts: opts} do
      assert {:ok, pid} = Down.open("http://localhost/", opts)

      parent = self()

      spawn(fn ->
        send(parent, :headers_requested)
        assert nil == Down.IO.resp_headers(pid)
        send(parent, :headers_received)
      end)

      assert_receive :headers_requested
      assert :ok == Down.IO.cancel(pid)
      assert nil == Down.IO.resp_headers(pid)

      assert_receive :headers_received
    end

    test "returns nil when errors", %{opts: opts} do
      assert {:ok, pid} = Down.open("http://localhost/", opts)

      parent = self()

      spawn(fn ->
        send(parent, :headers_requested)
        assert nil == Down.IO.resp_headers(pid)
        send(parent, :headers_received)
      end)

      assert_receive :headers_requested

      TestBackend.fake_message(pid, {:error, :unknown})
      assert nil == Down.IO.resp_headers(pid)

      assert_receive :headers_received
    end

    test "with buffer_size: 0, demands with resp_headers/1", %{opts: opts} do
      opts = [{:buffer_size, 0} | opts]
      assert {:ok, pid} = Down.open("http://localhost/", opts)
      assert_receive {TestBackend, :start}
      refute_receive {TestBackend, :demand_next}

      parent = self()

      spawn(fn ->
        assert [] = Down.IO.resp_headers(pid)
        send(parent, :headers_received)
      end)

      refute_receive :headers_received
      assert_received {TestBackend, :demand_next}

      TestBackend.fake_message(pid, {:status_code, 200})
      assert_receive {TestBackend, :handle_message, {:status_code, 200}}
      assert_receive {TestBackend, :demand_next}
      refute_receive :headers_received

      TestBackend.fake_message(pid, {:headers, []})
      assert_receive :headers_received

      refute_received {TestBackend, :demand_next}
    end

    test "responds as soon as possible", %{opts: opts} do
      assert {:ok, pid} = Down.open("http://localhost/", opts)
      assert_receive {TestBackend, :start}
      refute_receive {TestBackend, :demand_next}

      parent = self()

      spawn(fn ->
        assert Down.IO.chunk(pid)
        send(parent, :chunk_received)
      end)

      assert_receive {TestBackend, :demand_next}

      spawn(fn ->
        assert [] = Down.IO.resp_headers(pid)
        send(parent, :headers_received)
      end)

      refute_receive {TestBackend, :demand_next}

      TestBackend.fake_message(pid, status_code: 200, headers: [])
      assert_receive :headers_received

      refute_receive :chunk_received
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
        assert "chunk" = Down.IO.chunk(pid)
        send(parent, :chunk_received)
      end)

      refute_receive :chunk_received
      assert_receive {TestBackend, :demand_next}

      TestBackend.fake_message(pid, {:status_code, 200})
      assert_receive {TestBackend, :handle_message, {:status_code, 200}}
      assert_receive {TestBackend, :demand_next}
      refute_receive :chunk_received

      TestBackend.fake_message(pid, {:headers, []})
      assert_receive {TestBackend, :handle_message, {:headers, []}}
      assert_receive {TestBackend, :demand_next}
      refute_receive :chunk_received

      TestBackend.fake_message(pid, {:chunk, "chunk"})
      assert_receive {TestBackend, :handle_message, {:chunk, "chunk"}}
      assert_receive :chunk_received
      refute_receive {TestBackend, :demand_next}
    end

    test "returns nil when cancelled before getting it", %{opts: opts} do
      pid = open(opts)

      parent = self()

      spawn(fn ->
        send(parent, :chunk_requested)
        assert nil == Down.IO.chunk(pid)
        send(parent, :chunk_received)
      end)

      assert_receive :chunk_requested

      assert :ok == Down.IO.cancel(pid)
      assert nil == Down.IO.chunk(pid)

      assert_receive :chunk_received
    end

    test "returns nil when errors", %{opts: opts} do
      pid = open(opts)

      parent = self()

      spawn(fn ->
        send(parent, :chunk_requested)
        assert nil == Down.IO.chunk(pid)
        send(parent, :chunk_received)
      end)

      assert_receive :chunk_requested

      TestBackend.fake_message(pid, {:error, :unknown})
      assert nil == Down.IO.chunk(pid)

      assert_receive :chunk_received
    end

    test "returns :eof", %{opts: opts} do
      pid = open(opts)

      parent = self()

      spawn(fn ->
        send(parent, :chunk_requested)
        assert :eof == Down.IO.chunk(pid)
        send(parent, :chunk_received)
      end)

      assert_receive :chunk_requested

      TestBackend.fake_message(pid, :done)
      assert :eof == Down.IO.chunk(pid)

      assert_receive :chunk_received
    end
  end

  describe "cancel/1" do
    test "set status to :cancelled", %{opts: opts} do
      pid = open(opts)
      assert :ok == Down.IO.cancel(pid)
      assert :cancelled == Down.IO.info(pid, :status)
    end

    test "replies pending requests", %{opts: opts} do
      pid = open(opts)

      parent = self()

      spawn(fn ->
        send(parent, :chunk_requested)
        assert nil == Down.IO.chunk(pid)
        send(parent, :chunk_received)
      end)

      assert_receive :chunk_requested

      assert :ok == Down.IO.cancel(pid)

      assert_receive :chunk_received
    end

    test "doesn't handle more backend messages", %{opts: opts} do
      pid = open(opts)

      assert :ok == Down.IO.cancel(pid)
      assert_receive {TestBackend, :demand_next}
      assert_receive {TestBackend, :stop}

      msg = {:chunk, "chunk"}
      TestBackend.fake_message(pid, msg)
      refute_receive {TestBackend, :handle_message, ^msg}
    end
  end

  describe "flush/1" do
    test "returns inmediatly the buffer content", %{opts: opts} do
      pid = open(opts)
      TestBackend.fake_message(pid, {:chunk, "chunk"})
      TestBackend.fake_message(pid, {:chunk, "chunk"})

      assert ["chunk", "chunk"] = Down.IO.flush(pid)
      assert [] = Down.IO.flush(pid)
    end

    test "works when cancelled", %{opts: opts} do
      pid = open(opts)
      TestBackend.fake_message(pid, {:chunk, "chunk"})
      TestBackend.fake_message(pid, {:chunk, "chunk"})

      assert :ok = Down.IO.cancel(pid)
      assert ["chunk", "chunk"] = Down.IO.flush(pid)
      assert [] = Down.IO.flush(pid)
    end

    test "works list when errors", %{opts: opts} do
      pid = open(opts)
      TestBackend.fake_message(pid, {:chunk, "chunk"})
      TestBackend.fake_message(pid, {:chunk, "chunk"})
      TestBackend.fake_message(pid, {:error, :unknown})

      assert ["chunk", "chunk"] = Down.IO.flush(pid)
      assert [] = Down.IO.flush(pid)
    end

    test "returns empty list when finished", %{opts: opts} do
      pid = open(opts)
      TestBackend.fake_message(pid, {:chunk, "chunk"})
      TestBackend.fake_message(pid, {:chunk, "chunk"})
      TestBackend.fake_message(pid, :done)

      assert ["chunk", "chunk"] = Down.IO.flush(pid)
      assert [] = Down.IO.flush(pid)
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
    test "with :buffer_size", %{opts: opts} do
      pid = open(opts)
      assert 0 == Down.IO.info(pid, :buffer_size)

      TestBackend.fake_message(pid, {:chunk, "chunk"})
      assert 5 == Down.IO.info(pid, :buffer_size)

      TestBackend.fake_message(pid, {:chunk, "chunk"})
      assert 10 == Down.IO.info(pid, :buffer_size)

      assert "chunk" == Down.IO.chunk(pid)
      assert 5 == Down.IO.info(pid, :buffer_size)

      TestBackend.fake_message(pid, :done)
      assert 5 == Down.IO.info(pid, :buffer_size)

      assert "chunk" == Down.IO.chunk(pid)
      assert 0 == Down.IO.info(pid, :buffer_size)
    end

    test "with :content_length", %{opts: opts} do
      headers = [{"foo", "bar"}, {"content-length", "100"}]
      pid = open(opts, 203, headers)

      assert 100 == Down.IO.info(pid, :content_length)
    end

    # TODO
    test "with :content_type", %{opts: _opts} do
    end

    test "with :error", %{opts: opts} do
      pid = open(opts)
      assert nil == Down.IO.info(pid, :error)

      TestBackend.fake_message(pid, {:error, :unknown})
      assert :unknown == Down.IO.info(pid, :error)
    end

    test "with :max_redirections", %{opts: opts} do
      opts = [{:max_redirections, 3} | opts]
      pid = open(opts)
      assert 3 == Down.IO.info(pid, :max_redirections)
    end

    test "with :min_buffer_size", %{opts: opts} do
      opts = [{:buffer_size, 3} | opts]
      pid = open(opts)
      assert 3 == Down.IO.info(pid, :min_buffer_size)
    end

    test "with :position", %{opts: opts} do
      pid = open(opts)
      assert 0 == Down.IO.info(pid, :position)

      TestBackend.fake_message(pid, {:chunk, "chunk"})
      assert 5 == Down.IO.info(pid, :position)

      TestBackend.fake_message(pid, {:chunk, "chunk"})
      assert 10 == Down.IO.info(pid, :position)
    end

    test "with :redirections", %{opts: opts} do
      assert {:ok, pid} = Down.open("http://localhost/", opts)
      assert_receive {TestBackend, :start}

      headers = [{"location", "http://localhost/redirect_1"}]
      status_msg = {:status_code, 301}
      headers_msg = {:headers, headers}
      TestBackend.fake_message(pid, [status_msg, headers_msg])

      assert_receive {TestBackend, :handle_message, ^status_msg}
      assert_receive {TestBackend, :handle_message, ^headers_msg}
      assert_receive {TestBackend, :start}

      assert [
               %{
                 headers: [{"location", "http://localhost/redirect_1"}],
                 status_code: 301,
                 url: "http://localhost/"
               }
             ] == Down.IO.info(pid, :redirections)

      headers = [{"location", "http://localhost/redirect_2"}]
      status_msg = {:status_code, 301}
      headers_msg = {:headers, headers}
      TestBackend.fake_message(pid, [status_msg, headers_msg])

      assert_receive {TestBackend, :handle_message, ^status_msg}
      assert_receive {TestBackend, :handle_message, ^headers_msg}
      assert_receive {TestBackend, :start}

      assert [
               %{
                 headers: [{"location", "http://localhost/redirect_2"}],
                 status_code: 301,
                 url: "http://localhost/redirect_1"
               },
               %{
                 headers: [{"location", "http://localhost/redirect_1"}],
                 status_code: 301,
                 url: "http://localhost/"
               }
             ] == Down.IO.info(pid, :redirections)

      headers = [{"location", "http://localhost/redirect_3"}]
      status_msg = {:status_code, 301}
      headers_msg = {:headers, headers}
      TestBackend.fake_message(pid, [status_msg, headers_msg])

      assert_receive {TestBackend, :handle_message, ^status_msg}
      assert_receive {TestBackend, :handle_message, ^headers_msg}
      assert_receive {TestBackend, :start}

      assert [
               %{
                 headers: [{"location", "http://localhost/redirect_3"}],
                 status_code: 301,
                 url: "http://localhost/redirect_2"
               },
               %{
                 headers: [{"location", "http://localhost/redirect_2"}],
                 status_code: 301,
                 url: "http://localhost/redirect_1"
               },
               %{
                 headers: [{"location", "http://localhost/redirect_1"}],
                 status_code: 301,
                 url: "http://localhost/"
               }
             ] == Down.IO.info(pid, :redirections)
    end

    test "with :request", %{opts: opts} do
      pid = open(opts)

      assert %{
               headers: [{"User-Agent", "Down/0.0.1"}],
               method: :get,
               url: "http://localhost/"
             } = Down.IO.info(pid, :request)
    end

    test "with :response", %{opts: opts} do
      headers = [{"foo", "bar"}, {"content-length", 100}]
      pid = open(opts, 203, headers)

      assert %{
               headers: ^headers,
               size: 100,
               encoding: nil,
               status_code: 203
             } = Down.IO.info(pid, :response)
    end

    test "with :status", %{opts: opts} do
      assert {:ok, pid} = Down.open("http://localhost/", opts)

      assert :connecting == Down.IO.info(pid, :status)
      TestBackend.fake_message(pid, {:status_code, 200})
      assert :streaming == Down.IO.info(pid, :status)

      TestBackend.fake_message(pid, {:headers, []})
      assert :streaming == Down.IO.info(pid, :status)

      TestBackend.fake_message(pid, {:chunk, "chunk"})
      assert :streaming == Down.IO.info(pid, :status)

      TestBackend.fake_message(pid, :done)
      assert :completed == Down.IO.info(pid, :status)

      Down.IO.close(pid)

      assert {:ok, pid} = Down.open("http://localhost/", opts)
      TestBackend.fake_message(pid, {:error, :unknown})
      assert :error == Down.IO.info(pid, :status)

      assert {:ok, pid} = Down.open("http://localhost/", opts)
      Down.IO.cancel(pid)
      assert :cancelled == Down.IO.info(pid, :status)
    end

    test "with list", %{opts: opts} do
      headers = [{"foo", "bar"}, {"content-length", 100}]
      pid = open(opts, 203, headers)

      TestBackend.fake_message(pid, {:chunk, "chunk"})
      TestBackend.fake_message(pid, {:error, :refused})

      requests = [
        :buffer_size,
        :content_length,
        :content_type,
        :error,
        :max_redirections,
        :min_buffer_size,
        :position,
        :redirections,
        :request,
        :response,
        :status
      ]

      assert [
               5,
               100,
               nil,
               :refused,
               5,
               102_400,
               5,
               [],
               %{headers: [{"User-Agent", "Down/0.0.1"}], method: :get, url: "http://localhost/"},
               %{
                 encoding: nil,
                 headers: [{"foo", "bar"}, {"content-length", 100}],
                 size: 100,
                 status_code: 203
               },
               :error
             ] = Down.IO.info(pid, requests)
    end
  end

  describe "redirections" do
    test "works", %{opts: opts} do
      assert {:ok, pid} = Down.open("http://localhost/", opts)
      assert_receive {TestBackend, :start}

      headers = [{"location", "http://localhost/redirect"}]
      status_msg = {:status_code, 301}
      headers_msg = {:headers, headers}
      TestBackend.fake_message(pid, [status_msg, headers_msg])

      assert_receive {TestBackend, :handle_message, ^status_msg}
      assert_receive {TestBackend, :handle_message, ^headers_msg}

      assert :redirecting == Down.IO.info(pid, :status)

      assert_receive {TestBackend, :stop}
      assert_receive {TestBackend, :start}

      status_msg = {:status_code, 200}
      headers_msg = {:headers, []}
      TestBackend.fake_message(pid, [status_msg, headers_msg])

      assert_receive {TestBackend, :handle_message, ^status_msg}
      assert_receive {TestBackend, :handle_message, ^headers_msg}

      assert :streaming == Down.IO.info(pid, :status)
    end

    test "doesn't allow more than max_redirections", %{opts: opts} do
      opts = [{:max_redirections, 0} | opts]
      assert {:ok, pid} = Down.open("http://localhost/", opts)
      assert_receive {TestBackend, :start}

      headers = [{"location", "http://localhost/redirect"}]
      status_msg = {:status_code, 301}
      headers_msg = {:headers, headers}
      TestBackend.fake_message(pid, [status_msg, headers_msg])

      assert_receive {TestBackend, :handle_message, ^status_msg}
      assert_receive {TestBackend, :handle_message, ^headers_msg}

      assert :error == Down.IO.info(pid, :status)
      assert :too_many_redirects == Down.IO.info(pid, :error)
    end
  end

  test "starts and stops", %{opts: opts} do
    {:ok, pid} = Down.open("http://localhost/", opts)
    assert_receive {TestBackend, :start}

    TestBackend.fake_message(pid, :done)
    assert_receive {TestBackend, :handle_message, :done}
    refute_receive {TestBackend, :stop}
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
      assert "1" = Down.IO.chunk(pid)
      send(parent, :chunk_received)
    end)

    assert_receive :chunk_received
    assert_received {TestBackend, :demand_next}

    send_chunk(pid, "456")
    refute_receive {TestBackend, :demand_next}

    assert "2" = Down.IO.chunk(pid)
    refute_receive {TestBackend, :demand_next}

    assert "3" = Down.IO.chunk(pid)
    refute_receive {TestBackend, :demand_next}

    assert "456" = Down.IO.chunk(pid)
    assert_received {TestBackend, :demand_next}
  end
end
