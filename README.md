# Down

Down is a utility tool for streaming, flexible and safe downloading of remote files.

Full documentation can be found at [https://hexdocs.pm/down ](https://hexdocs.pm/down)

## Installation

Add `down` to your list of dependencies in` mix.exs`:

```elixir
def deps do
  [
    {:down, "~> 0.0.1"}
  ]
end
```

Install via `mix deps.get`.

## Why another HTTP library?

The library's main functionality is to *create streams* from external remote HTTP files.
It can also be useful for the following reasons:

* It offers safer downloads with size limitation.
* It offers a simple API with good defaults to "just download" content.
* It offers a thin wrapper--with a normalized API--that allows you to use different HTTP backend libraries.
* Low memory consumption.
* Not extra dependencies.

## Maximum size

If you're accepting URLs from outside or untrusted source,
it's a good policy to limit the size of the download,
because attackers are always looking to over work your servers.
Down allows you to pass a `:max_size` option:

```iex
iex> Down.download("http://example.com/image.jpg", max_size: 5 * 1024 * 1024) # 5 MB
{:error, :too_large}
```

What is the advantage of using Down instead of simply checking the size after downloading?
Down terminates the download very early, as soon as it gets to the `Content-Length` header.
When the `Content-Length` header is missing,
Down terminates the download as soon as the downloaded content surpasses the `:max_size` option.

`:max_size` can be used in any Down operation.

## Redirections

Down handles redirects using the `:max_redirects` option.
In the case a request produces more redirects than the given option
it returns an error:

```iex
iex> Down.download("http://example.com/100_redirects.html", max_redirects: 1)
{:error, :too_many_redirects}
```

## Downloading

The primary function is `Down.download/2` which stores the remote file as a temporary file.
The returned `Down.Download` struct contains more information about the request
including `file_path` with the location of the temporary file:

```iex
iex> {:ok, download} = Down.download("http://localhost:6080/robots.txt")
{:ok, %Down.Download{
  backend: Down.HackneyBackend,
  file_path: "/tmp/f-1552846757-26630-1bzq5eq.txt",
  original_filename: "robots.txt",
  request: %{
    backend_opts: nil,
    body: nil,
    headers: %{"User-Agent" => "Down/0.0.1"},
    method: :get,
    timeout: 5000,
    url: "http://localhost:6080/robots.txt"
  },
  response: %{
    encoding: nil,
    headers: %{
      "access-control-allow-credentials" => "true",
      "access-control-allow-origin" => "*",
      "connection" => "keep-alive",
      "content-length" => "30",
      "content-type" => "text/plain",
      "date" => "Sun, 17 Mar 2019 18:19:17 GMT",
      "server" => "gunicorn/19.9.0"
    },
    size: 30,
    status_code: 200
  },
  size: 30
}}
iex> download.file_path
"/tmp/f-1552846757-26630-1bzq5eq.txt"
```

### Destination

By default the remote file will be downloaded into a temporary location.
If you would like the file to be downloaded to a
specific location on disk, you can specify the `:destination` option:

```iex
iex> Down.download("http://example.com/image.jpg", destination: "/path/to/destination")
{:ok, %Down.download{
  file_path: "/path/to/destination"
}}
```

## Read

If the remote content is the only thing you need, `Down.read/2` function is a good option.
It returns a string with the full content:

```iex
iex> Down.read("https://google.com")
{:ok,
 "<!doctype html><html itemscope=\"\" itemtype=\"http://schema.org/WebPage" <> ...}
```

## Streaming

Down has the ability to retrieve remote file content *as it is being
downloaded*. The `Down.stream` function returns a stream which
can be used with functions in the [`Stream`](https://hexdocs.pm/elixir/Stream.html)
and [`Enum`](https://hexdocs.pm/elixir/Enum.html) module functions.

The content of the remote file is streamed in binary chunks.
Because streams are lazy, the chunks are only downloaded on demand.
This means that if only the first chunk is requested,
the rest of the file isn't downloaded and the operation won't consume more resources.
This is very convenient when working with large files,
or when we're only interested in some parts of the file,
or when keeping low memory consumption is important.

In the following example we are downloading the Elixir webpage content,
but only until the title is reached:

```iex
# This example doesn't cover all the possibilities
# and it doesn't close the connection
iex> Down.stream("https://elixir-lang.org") |> Enum.find_value(&Regex.run(~r/\<title\>(.*)\<\/title\>/i, &1, capture: :all_but_first))
["Elixir"]
```

## Architecture

Every Down operation creates a new process under a custom `DynamicSupervisor`.
However, Down doesn't have any kind of pool connection or a maximum connection number limitation.
`:hackney` and `:ibrowser` backends use their own connection pool,
so if you're using one of these backends you're automatically using its connection pool.


## Backends

There are four optional backends in Down:

* [`:hackney`](https://github.com/benoitc/hackney)
* [`:httpc`](http://erlang.org/doc/man/httpc.html)
* [`:ibrowser`](https://github.com/cmullaparthi/ibrowse)
* [`Mint`](https://github.com/ericmj/mint)

The default is `:httpc` which comes by default in Erlang,
so no additional dependencies are needed to use Down.
It can be changed globally using the following config:

```elixir
config :down, :backend, :hackney
```

The backend can also be changed in runtime and per request,
simply by using the `:backend` argument:

```iex
iex> Down.read("https://example.com/api.json", backend: :ibrowser)
```

`Down` and `:hackney` have proper SSL (https) support.

## Testing

To run the test correctly, you need to have an httpbin server running on port `6080`.
The best way to do it is using the [kennethreitz/httpbin docker image](https://hub.docker.com/r/kennethreitz/httpbin/):

```
docker run -p 6080:80 -d kennethreitz/httpbin
```

## TODO

Before publishing a stable version the following tasks should be done:

* :inet.setopts(active: :once)
* :hackney.stream_next()
* Check the minimum compatible version for the backends dependencies.
* Improve tests.
* Improve docs.
* Fix timeouts
* API to close streams
* API to fetch metadata information from a stream
* Handle form data
* Handle cookies

## Acknowledgment

This library is heavily inspired on the awesome Ruby gem [down](https://github.com/janko/down)
