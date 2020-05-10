defmodule DownTest do
  use ExUnit.Case, async: true
  doctest Down

  def get_binary(url) do
    url = to_charlist(url)
    assert {:ok, _, _, body} = :ibrowse.send_req(url, [], :get, [], response_format: :binary)
    body
  end

  @base_url "http://localhost:6080"

  setup do
    # Needed it because we httpbin fails with too many fast requests
    Process.sleep(50)
    :ok
  end

  test "detect invalid urls" do
    assert {:error, :invalid_url} = Down.read("https://")
    assert {:error, :invalid_url} = Down.read("ftp://elixir-lang.com")
    assert {:error, :invalid_url} = Down.read("https://elixir-lang.com:66666")
  end

  test "detect invalid methods" do
    assert {:error, :invalid_method} = Down.read("https://elixir-lang.com/", method: :load)
  end

  # for backend <- [:httpc] do
  # for backend <- [:ibrowse] do
  # for backend <- [:hackney] do
  # for backend <- [:mint] do
  for backend <- [:hackney, :ibrowse, :httpc, :mint] do
    @backend backend

    describe "with #{@backend}" do
      test "reads" do
        url = "#{@base_url}/bytes/100?seed=0"
        assert {:ok, s} = Down.read(url, backend: @backend)
        assert get_binary(url) == s
      end

      test "streams" do
        url = "#{@base_url}/bytes/100?seed=0"

        s =
          url
          |> Down.stream(backend: @backend)
          |> Enum.to_list()

        assert [get_binary(url)] == s
      end

      test "accepts 'get' method" do
        url = "#{@base_url}/get"

        assert {:ok, %{response: %{status_code: 200}}} =
                 Down.download(url, backend: @backend, method: :get)
      end

      test "accepts 'post' method" do
        url = "#{@base_url}/post"

        body = %{foo: "bar"} |> Jason.encode!()
        headers = %{"Content-Type" => "application/json"}

        assert {:ok, %{response: %{status_code: 200}} = download} =
                 Down.download(url, backend: @backend, method: :post, body: body, headers: headers)

        assert %{
                 "data" => ^body,
                 "headers" => %{"Content-Type" => "application/json"}
               } =
                 download.file_path
                 |> File.read!()
                 |> Jason.decode!()
      end

      test "accepts 'head' method" do
        url = "#{@base_url}/get"

        assert {:ok, %{response: %{status_code: 200}}} =
                 Down.download(url, backend: @backend, method: :head)
      end

      test "accepts 'put' method" do
        url = "#{@base_url}/put"

        assert {:ok, %{response: %{status_code: 200}} = download} =
                 Down.download(url, backend: @backend, method: :put)
      end

      test "accepts 'patch' method" do
        url = "#{@base_url}/patch"

        assert {:ok, %{response: %{status_code: 200}} = download} =
                 Down.download(url, backend: @backend, method: :patch)
      end

      test "accepts 'delete' method" do
        url = "#{@base_url}/delete"

        assert {:ok, %{response: %{status_code: 200}}} =
                 Down.download(url, backend: @backend, method: :delete)
      end

      test "accepts 'options' method" do
        url = "#{@base_url}/get"

        assert {:ok, %{response: %{status_code: 200}}} =
                 Down.download(url, backend: @backend, method: :options)
      end

      test "downloads content from url" do
        url = "#{@base_url}/bytes/100?seed=0"
        assert {:ok, %{file_path: path}} = Down.download(url, backend: @backend)
        assert File.read!(path) == get_binary(url)
      end

      test "accepts maximum size" do
        url = "#{@base_url}/bytes/10"
        assert {:error, :too_large} = Down.download(url, max_size: 9, backend: @backend)

        assert {:ok, %{response: %{status_code: 200}}} =
                 Down.download(url, max_size: 10, backend: @backend)

        url = "#{@base_url}/stream-bytes/10"
        assert {:error, :too_large} = Down.download(url, max_size: 9, backend: @backend)

        url = "#{@base_url}/stream-bytes/10"

        assert {:ok, %{response: %{status_code: 200}}} =
                 Down.download(url, max_size: 10, backend: @backend)
      end

      test "follows redirect by default" do
        url = "#{@base_url}/redirect/1"

        assert {:ok, %{response: %{status_code: 200}}} = Down.download(url, backend: @backend)
      end

      test "max redirects works" do
        url = "#{@base_url}/redirect/5"

        assert {:error, :too_many_redirects} =
                 Down.download(url, backend: @backend, max_redirects: 1)

        assert {:error, :too_many_redirects} =
                 Down.download(url, backend: @backend, max_redirects: 4)

        assert {:ok, %{response: %{status_code: 200}}} =
                 Down.download(url, backend: @backend, max_redirects: 5)

        url = "#{@base_url}/redirect/1"

        assert {:error, :too_many_redirects} =
                 Down.download(url, backend: @backend, max_redirects: 0)
      end

      test "301, 302 & 303 redirects using get method" do
        url = "#{@base_url}/redirect-to?url=%2Fget&status_code=301"

        assert {:ok, %{response: %{status_code: 200}}} =
                 Down.download(url, backend: @backend, method: :post)

        url = "#{@base_url}/redirect-to?url=%2Fget&status_code=302"

        assert {:ok, %{response: %{status_code: 200}}} =
                 Down.download(url, backend: @backend, method: :patch)

        url = "#{@base_url}/redirect-to?url=%2Fget&status_code=303"

        assert {:ok, %{response: %{status_code: 200}}} =
                 Down.download(url, backend: @backend, method: :delete)
      end

      test "307 & 308 redirects keeps method" do
        url = "#{@base_url}/redirect-to?url=%2Fpost&status_code=307"
        assert {:ok, _} = Down.download(url, backend: @backend, method: :post)

        url = "#{@base_url}/redirect-to?url=%2Fget&status_code=307"
        assert {:error, _} = Down.download(url, backend: @backend, method: :post)

        url = "#{@base_url}/redirect-to?url=%2Fpost&status_code=308"
        assert {:ok, _} = Down.download(url, backend: @backend, method: :post)

        url = "#{@base_url}/redirect-to?url=%2Fget&status_code=308"
        assert {:error, _} = Down.download(url, backend: @backend, method: :post)
      end

      if @backend == :httpc, do: @tag(skip: "doesn't work")

      test "invalid redirects" do
        # redirect to http://localhost:9999/
        url = "#{@base_url}/redirect-to?url=http%3A%2F%2Flocalhost%3A9999%2F"
        # FIXME it does not work with httpc :(
        assert {:error, :econnrefused} = Down.download(url, backend: @backend)
      end

      test "infers file extension from url" do
        url = "#{@base_url}/robots.txt"
        assert {:ok, download} = Down.download(url, backend: @backend)
        assert Path.extname(download.file_path) == ".txt"

        url = "#{@base_url}/robots.txt?foo=bar"
        assert {:ok, download} = Down.download(url, backend: @backend)
        assert Path.extname(download.file_path) == ".txt"

        url = "#{@base_url}/redirect-to?url=/robots.txt"
        assert {:ok, download} = Down.download(url, backend: @backend)
        assert Path.extname(download.file_path) == ".txt"
      end

      test "set headers" do
        url = "#{@base_url}/headers"
        headers = [{"Foo", "Bar"}, {"User-Agent", "elixir"}]
        assert {:ok, download} = Down.download(url, backend: @backend, headers: headers)

        assert %{"Foo" => "Bar", "User-Agent" => "elixir"} =
                 download.file_path
                 |> File.read!()
                 |> Jason.decode!()
                 |> Map.get("headers")

        headers = [foo: "Bar"]
        assert {:ok, download} = Down.download(url, backend: @backend, headers: headers)

        user_agent = "Down/#{Mix.Project.config()[:version]}"

        assert %{"Foo" => "Bar", "User-Agent" => ^user_agent} =
                 download.file_path
                 |> File.read!()
                 |> Jason.decode!()
                 |> Map.get("headers")

        headers = %{"Foo" => "Bar"}
        assert {:ok, download} = Down.download(url, backend: @backend, headers: headers)

        user_agent = "Down/#{Mix.Project.config()[:version]}"

        assert %{"Foo" => "Bar", "User-Agent" => ^user_agent} =
                 download.file_path
                 |> File.read!()
                 |> Jason.decode!()
                 |> Map.get("headers")
      end

      test "get response headers and url" do
        url = "#{@base_url}/response-headers?Foo=Bar"
        assert {:ok, download} = Down.download(url, backend: @backend)
        assert download.response.headers["foo"] == "Bar"
        assert url == download.request.url

        assert {:ok, download} =
                 Down.download("#{@base_url}/redirect-to?url=#{url}", backend: @backend)

        assert download.response.headers["foo"] == "Bar"
        assert url == download.request.url
      end

      test "adds original_filename extracted from Content-Disposition" do
        content_disposition_url = "#{@base_url}/response-headers?Content-Disposition=inline;%20"
        url = "#{content_disposition_url}filename=%22my%20filename.ext%22"
        assert {:ok, download} = Down.download(url, backend: @backend)
        assert download.original_filename == "my filename.ext"

        url = "#{content_disposition_url}filename=%22my%2520filename.ext%22"
        assert {:ok, download} = Down.download(url, backend: @backend)
        assert download.original_filename == "my filename.ext"

        url = "#{content_disposition_url}filename=myfilename.ext%20"
        assert {:ok, download} = Down.download(url, backend: @backend)
        assert download.original_filename == "myfilename.ext"
      end

      test "adds original_filename extracted from URI path if Content-Disposition is blank" do
        assert {:ok, download} = Down.download("#{@base_url}/robots.txt", backend: @backend)
        assert "robots.txt" == download.original_filename

        # TODO
        # assert {:ok, download} = Down.download("#{@base_url}/basic-auth/user/pass%20word") do |client|
        #   client.basic_auth(user: "user", pass: "pass word")
        # end
        # assert "pass word" == download.original_filename

        url = "#{@base_url}/response-headers?Content-Disposition=inline;%20filename="
        assert {:ok, download} = Down.download(url, backend: @backend)
        assert "response-headers" == download.original_filename

        url = "#{@base_url}/response-headers?Content-Disposition=inline;%20filename=%22%22"
        assert {:ok, download} = Down.download(url, backend: @backend)
        assert "response-headers" == download.original_filename

        url = "#{@base_url}/anything/pass%20word"
        assert {:ok, download} = Down.download(url, backend: @backend)
        assert "pass word" == download.original_filename

        # FIXME
        if @backend != :hackney do
          assert {:ok, download} = Down.download("#{@base_url}/", backend: @backend)
          refute download.original_filename

          assert {:ok, download} = Down.download("#{@base_url}", backend: @backend)
          refute download.original_filename
        end
      end

      test "returns HTTP error response" do
        assert {:error, {:invalid_status_code, 404}} =
                 Down.download("#{@base_url}/status/404", backend: @backend)

        assert {:error, {:invalid_status_code, 500}} =
                 Down.download("#{@base_url}/status/500", backend: @backend)

        # FIXME
        # assert {:error, %{response: %{status_code: 100}}} =
        #          Down.download("#{@base_url}/status/100", backend: @backend)
      end

      test "returns invalid URL errors" do
        assert {:error, :invalid_url} = Down.download("foo://example.org", backend: @backend)
        # FIXME Some day
        # assert {:error, :invalid_url} = Down.download("http://example.org\\foo")
      end

      if @backend == :httpc, do: @tag(skip: "doesn't work")

      test "returns connection error" do
        assert {:error, :econnrefused} = Down.download("http://localhost:9999", backend: @backend)
      end

      test "returns recv timeout errors" do
        opts = [recv_timeout: 10, backend: @backend]
        assert {:error, :timeout} = Down.download("#{@base_url}/delay/2", opts)
      end

      test "returns total timeout errors" do
        opts = [total_timeout: 10, backend: @backend]
        assert {:error, :timeout} = Down.download("#{@base_url}/delay/2", opts)
      end

      if @backend not in [:mint, :hackney], do: @tag(skip: true)

      test "returns SSL errors" do
        assert {:error, :ssl_error} =
                 Down.download("https://wrong.host.badssl.com/", backend: @backend)

        assert {:error, :ssl_error} =
                 Down.download("https://expired.badssl.com/", backend: @backend)
      end
    end
  end
end
