defmodule Down.Download do
  @type t :: %{
          backend: atom(),
          size: non_neg_integer(),
          request: Down.request(),
          response: Down.response(),
          file_path: Path.t(),
          original_filename: String.t()
        }
  defstruct [:backend, :size, :request, :response, :file_path, :original_filename]
end
