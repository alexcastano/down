defmodule Down.Backend do
  @type t() :: module()
  @type state :: term()
  @type raw_message() :: term()
  @type action ::
          {:status_code, non_neg_integer()}
          | {:headers, Down.headers()}
          | {:chunk, binary()}
          | :done
          | {:error, term()}
          | {:ignored, raw_message()}
  @type actions :: [action()] | action()

  @callback start(Down.request(), pid()) :: {:ok, state(), Down.request()} | {:error, term()}
  @callback demand_next(state()) :: state()
  @callback handle_message(state(), raw_message()) :: {action() | actions(), state()}
  @callback stop(state()) :: :ok
end
