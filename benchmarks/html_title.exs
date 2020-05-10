# url = "https://github.com/elixir-lang/elixir"
# result = [
#   "GitHub - elixir-lang/elixir: Elixir is a dynamic, functional language designed for building scalable and maintainable applications"
# ]

url = "https://marca.com/"
opts = [backend: :mint]
result = ["MARCA - Diario online l\xEDder en informaci\xF3n deportiva"]

regex = ~r"<title.*>(.*)</title>"

read = fn ->
  {:ok, body} = Down.read(url, opts)
  ^result = Regex.run(regex, body, capture: :all_but_first)
end

stream = fn ->
  ^result =
    Down.stream(url, opts)
    |> Enum.find_value(&Regex.run(regex, &1, capture: :all_but_first))
end

read.()
stream.()

# run_opts = [warmup: 1, memory_time: 5]
run_opts = [warmup: 0, time: 2]

Benchee.run(
  %{
    "read" => read,
    "stream" => stream
  },
  run_opts
)
