if Code.ensure_loaded?(HTTPotion) do
  defmodule Down.HTTPotionBackend do
    @moduledoc false

    def run(url, pid) do
      case HTTPotion.get(url, ibrowse: [stream_to: {pid, :once}]) do
        %HTTPotion.AsyncResponse{id: id} ->
          {:ok, id}

        %HTTPotion.ErrorResponse{message: msg} ->
          {:error, msg}
      end
    end

    def next_chunk(id) do
      :ok = :ibrowse.stream_next(id)
    end

    def parse_response(id, {:ibrowse_async_headers, id, status_code, headers}) do
      IO.inspect(headers)
      {status_code_int, _} = :string.to_integer(status_code)

      {:ok, {:init, headers, status_code_int}}
    end

    def parse_response(id, {:ibrowse_async_response_timeout, id}) do
      {:error, :timeout}
    end

    def parse_response(id, {:ibrowse_async_response, id, data}) do
      {:ok, {:data, data}}
    end

    def parse_response(id, {:ibrowse_async_response_end, id}) do
      {:ok, :end}
    end

    def parse_response(_, _), do: {:error, :no_valid}
  end
end
