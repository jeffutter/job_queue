defmodule JobQueue.Job do
  @moduledoc false

  @type t :: %__MODULE__{
          id: integer | nil,
          event: any | nil,
          from: pid | nil,
          queue: any | nil,
          reply: boolean,
          retry_count: non_neg_integer
        }

  defstruct id: nil,
            event: nil,
            from: nil,
            queue: nil,
            reply: false,
            retry_count: 0

  @spec new(any, any, pid, boolean) :: t
  def new(event, queue, from, reply \\ false) do
    %__MODULE__{
      id: :erlang.unique_integer(),
      event: event,
      from: from,
      queue: queue,
      reply: reply
    }
  end
end
