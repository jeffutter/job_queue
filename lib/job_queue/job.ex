defmodule JobQueue.Job do
  @type t :: %{
          id: integer | nil,
          event: any | nil,
          queue: term | nil,
          retry_count: integer,
          from: pid | nil,
          reply: boolean
        }
  defstruct id: nil, event: nil, queue: nil, retry_count: 0, from: nil, reply: false

  @spec new(any, term, pid, boolean) :: t
  def new(event, queue, from, reply \\ false) do
    %__MODULE__{
      id: :erlang.unique_integer(),
      event: event,
      queue: queue,
      from: from,
      reply: reply
    }
  end
end
