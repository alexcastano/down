defmodule Down.OptionsTest do
  use ExUnit.Case, async: true

  alias Down.Options
  alias Down.Error

  @valid_url "http://url.com/"
  describe "build/2" do
    test "set default options" do
      assert {:ok, options} = Options.build(@valid_url, [])

      assert %Down.Options{
               backend: nil,
               backend_opts: '',
               body: nil,
               connect_timeout: 15000,
               destination: nil,
               headers: [{"User-Agent", "Down/0.0.1"}],
               max_redirects: 5,
               max_size: nil,
               method: :get,
               recv_timeout: 30000,
               total_timeout: :infinity,
               url: @valid_url
             } == options
    end

    test "validates url" do
      assert {:error, error} = Options.build("invalid_url", [])
      assert %Error{reason: :invalid_url} = error
      assert "invalid schema: only 'http' and 'https' allowed" == Exception.message(error)

      assert {:error, error} = Options.build("http://", [])
      assert %Error{reason: :invalid_url} = error
      assert "invalid host" == Exception.message(error)

      assert {:error, error} = Options.build("http://down:80000", [])
      assert %Error{reason: :invalid_url} = error
      assert "invalid port" == Exception.message(error)
    end

    test "adds default path" do
      assert {:ok, options} = Options.build("http://url.com", [])

      assert %Down.Options{
               backend: nil,
               backend_opts: '',
               body: nil,
               connect_timeout: 15000,
               destination: nil,
               headers: [{"User-Agent", "Down/0.0.1"}],
               max_redirects: 5,
               max_size: nil,
               method: :get,
               recv_timeout: 30000,
               total_timeout: :infinity,
               url: @valid_url
             } == options
    end

    test "validates method" do
      assert {:error, error} = Options.build(@valid_url, method: :none)
      assert %Error{reason: :invalid_method} = error
      assert "invalid method" == Exception.message(error)
    end

    test "validates headers" do
      assert {:error, error} = Options.build(@valid_url, headers: true)
      assert %Error{reason: :invalid_headers} = error
      assert "invalid headers" == Exception.message(error)
    end

    test "doesn't add user agent is already set" do
      headers = %{"user-agent" => "FAKE"}
      assert {:ok, options} = Options.build(@valid_url, headers: headers)
      assert %{headers: [{"user-agent", "FAKE"}]} = options

      headers = %{"USER-AGENT" => "FAKE"}
      assert {:ok, options} = Options.build(@valid_url, headers: headers)
      assert %{headers: [{"USER-AGENT", "FAKE"}]} = options
    end
  end
end
