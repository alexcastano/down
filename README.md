# Down

Down is a utility tool for streaming, flexible and safe downloading of remote files.

Full documentation can be found at [https://hexdocs.pm/down ](https://hexdocs.pm/down)

## Installation

Add `down` to your list of dependencies in` mix.exs`:

```elixir
def deps do
  [
    {:down, "~> 0.1.0"}
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

## High level API

There are three main functions ready to use.

If the remote content is the only thing you need, `Down.read/2` function is a good option.
It returns a string with the full content:

```iex
iex> Down.read("https://google.com")
{:ok,
 "<!DOCTYPE html>\n<html xmlns=\"http://www.w3.org/1999/xhtml\" lang=\"en\">\n " <> ...}
```

And its variant `Down.read!/2`:

```iex
iex> Down.read("https://google.com")
"<!DOCTYPE html>\n<html xmlns=\"http://www.w3.org/1999/xhtml\" lang=\"en\">\n " <> ...
```

If you need more information about the response, like the headers or the status code,
you can use `Down.request/2` or `Down.request!/2`:

```iex
iex> Down.read("https://google.com")
"<!doctype html><html itemscope=\"\" itemtype=\"http://schema.org/WebPage" <> ...
```

On the other hand, if your intention is to have more control about
how the content is downloaded, you can create a `Stream` using the function `Down.stream/2`:

```iex
# Download the content until we get the title
# This example doesn't cover all the possibilities
iex> Down.stream("https://elixir-lang.org") |> Enum.find_value(&Regex.run(~r/\<title\>(.*)\<\/title\>/i, &1, capture: :all_but_first))
["Elixir"]
```

### Maximum size

If you're accepting URLs from outside or untrusted source,
it's a good policy to limit the size of the download,
because attackers are always looking to over work your servers.
Down allows you to pass a `:max_size` and `:on_max_size` options.

When `:on_max_size` is set to `:abort`
When `:on_max_size` is set to `:slice`

```iex
iex> Down.download("http://example.com/image.jpg", max_size: 5 * 1024 * 1024) # 5 MB
{:error, :too_large}
```

What is the advantage of using Down instead of simply checking the size after downloading?
Down terminates the download very early, as soon as it gets to the `Content-Length` header.
When the `Content-Length` header is missing,
Down terminates the download as soon as the downloaded content surpasses the `:max_size` option.

`:max_size` can be used in any Down operation.

### Redirections

Down handles redirects using the `:max_redirects` option.
In the case a request produces more redirects than the given option
it returns an error:

```iex
iex> Down.download("http://example.com/100_redirects.html", max_redirects: 1)
# FIXME
{:error, :too_many_redirects}
```

### Options

All the Down operations accept the following options:

  * `:backend` - The backend to use during for the request. More info in "Backends" section.
  * `:backend_opts` - Additional options passed to the backend.
    Notice: Down uses some options to work with the backend. In case of conflict,
    Down options overwrites the given ones.
  * `:body`- HTTP body request in binary format. Default: `nil`.
  * `:buffer_size` - TODO
  * `:connect_timeout` - The time in milliseconds to wait for the request to connect,
    `:infinity` will wait indefinitely. Default: `15_000`.
  * `:headers` - A Keyword or a Map containing all request headers.
    The key and value are converted to strings.
  * `:max_redirections` - The maximum times a redirection will be follow.
    It can be any positive integer or `:infinity`.  Default: `5`
  * `:max_size` - The maximum size in bytes of the download.
    If the content is larger than this limit the function will return `{:error, :too_large}`.
  * `:method` - HTTP method used by the request.
    Possible values: `:get`, `:post`, `:delete`, `:put`, `:patch`, `:options`, `:head`, `:connect`, `:trace`.
    Default: `:get`.
  * `:total_timeout` - Timeout time for the request.
    The clock starts ticking when the request is sent.
    Time is in milliseconds.
    Default: `:infinity`.
  * `:recv_timeout` - If a persistent connection is idle longer than the `:recv_timeout`
    in milliseconds, the client closes the connection.
    The server can also have such a timeout but do not take that for granted.
    Default is 30_000.
    Only implemented for `:ibrowse` backend.

## Streaming

Down has the ability to retrieve remote file content *as it is being
downloaded*. The `Down.stream/2` function returns a stream which
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
upcasing it and finally storing in a local file, chunk by chunk.
We don't keep in memory the whole file in any moment, so we are using less memory:

```iex
# Stores a webpage in a file upcasing all the content
iex> Down.stream("https://elixir-lang.org") |>
...> Stream.map(&String.upcase/1) |>
...> Stream.into(File.stream!("/tmp/download.html")) |>
...> Stream.run()
```

## Low level API

To have the maximum control about the download you can use the low level API.
With `Down.open/2` you can start a download which will be linked to the current process:

```iex
iex> {:ok, pid} = Down.open("https://elixir-lang.org")
{:ok, #PID<0.264.0>}
```

Now a connection was established with the remote server.
You can ask for chunks with `Down.chunk/1`:

```iex
iex> Down.chunk(pid)
"<!DOCTYPE html>\n<html xmlns=\"http://www.w3.org/1999/xhtml\" lang=\"en\">\n<head>\n  " <> ...
```

But you can get also the headers and the status code `Down.resp_headers/1` and `Down.status_code`:

```iex
iex> Down.status_code(pid)
200
iex> Down.resp_headers(pid)
[
  {"server", "GitHub.com"},
  {"content-type", "text/html; charset=utf-8"},
  ...
]
```

Indeed, you can also get even more internal information with `Down.info/2`:

```iex
iex> Down.info(pid, [:buffer_size, :position, :content_length, :request])
[
  buffer_size: 2808,
  position: 2409,
  content_length: 19192,
  request: %{
    headers: [{"User-Agent", "Down/0.1.0"}],
    method: :get,
    url: "https://elixir-lang.org/"
  }
]
```

When you want to close the connection but we want to keep
the download process alive to get more information later, you can use `Down.cancel/1`:

```iex
iex> Down.cancel(pid)
:ok
```

The process didn't die, so you can keep request information. To get all the buffer
content you can use `Down.flush/1`:

```iex
iex> Down.flush(pid)
["p.com/\">Elixir on Slack</a></li>\n " <> ...]
```

Finally, when you want to kill the process, and to close the connection if it still open,
you should use `Down.close/1`:

```iex
iex> Down.close(pid)
:ok
```

## Backends

There are four optional backends in Down, they are ordered by preference:

* `Down.MintBackend` which uses [`Mint` library](https://github.com/elixir-mint/mint)
* `Down.HackneyBackend` which uses [`:hackney` library](https://github.com/benoitc/hackney)
* `Down.IbrowseBackend` which uses [`:ibrowse` library](https://github.com/cmullaparthi/ibrowse)
* `Down.HttpcBackend` which uses [`:httpc` library](http://erlang.org/doc/man/httpc.html)

If any of them is installed as a dependency in the current project,
it will be compiled and it may be used as `:backend` option.
Otherwise, they won't be compiled so they cannot be used.

In the case the `:backend` option is not given in the call of a Down function,
the first available in the previous list will be used.
Notice that the `Down.HttpcBackend` is always available because it is included in Erlang OTP,
so in case none of the previous libraries is installed it will be used by default.

To know which backend will be used in case the `:backend` option is not given,
you can use the function `Down.default_backend/0`:

```iex
iex> Down.default_backend()
Down.MintBackend
```

To modify the default backend globally,
you can set the option `:backend` in the `:down` application:

```elixir
config :down, :backend, Down.HackneyBackend
```

Warning: this will change the default for all the applications using Down.
Because of this, giving the `:backend` option in each individual
request is the preferred method, especially for libraries:

```iex
iex> Down.read("https://example.com/api.json", backend: Down.IbrowseBackend)
```

You can create a small wrapper around Down request to change the default backend.


### SSL

`:hackney` and `Mint` with `CAStore` have proper SSL (https) support.


## Connection Pools

Down doesn't have any kind of support for connection pools.
However, if you are using `Down.HackneyBackend` or `Down.IbrowseBackend` you
can still use their connection pools using the `:backend_opts`:

```iex
iex> opts = [backend: Down.HackneyBackend, backend_opts: [pool: :my_hackney_pool]]
iex> Down.read("https://www.phoenixframework.org/", opts)
```

<!-- MDOC !-->

## Testing

To run the test correctly, you need to have an httpbin server running on port `6080`.
There is a `docker-compose.yml` file already setup, so you can run
`docker-compose up` before running the tests.

## TODO

Before publishing a stable version the following tasks should be done:

* Handle body stream
* Handle form data
* Handle cookies

## Acknowledgment

This library is heavily inspired on the awesome Ruby gem [down](https://github.com/janko/down)

## License

MIT License. Copyright (c) 2020 Alex Castaño
