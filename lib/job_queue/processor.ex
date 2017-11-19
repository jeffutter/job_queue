defmodule JobQueue.Processor do
  @spec start_link(term, term, Keyword.t()) :: {:ok, pid}
  def start_link(queue, worker_module, options \\ []) do
    import Supervisor.Spec

    max_demand = Keyword.get(options, :max_demand, 3)
    min_demand = Keyword.get(options, :min_demand, 1)

    children = [
      worker(worker_module, [], restart: :temporary)
    ]

    ConsumerSupervisor.start_link(
      children,
      strategy: :one_for_one,
      subscribe_to: [{queue, max_demand: max_demand, min_demand: min_demand}]
    )
  end
end
