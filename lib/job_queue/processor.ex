defmodule JobQueue.Processor do
  @moduledoc """
  A basic `ConsumerSupervisor` setup that works well with `JobQueue.Queue`
  and `JobQueue.Worker`.  

  ## Example
      iex> # Setup Worker
      ...> defmodule ProcessorWorker do
      ...>   def start_link(job = %JobQueue.Job{event: event}) do
      ...>     Task.start_link(fn ->
      ...>       JobQueue.Queue.ack(job, {:ok, event})
      ...>     end)
      ...>   end
      ...> end
      ...>
      ...> # Start Queue
      ...> {:ok, _queue} = JobQueue.Queue.start_link(ProcessorQueue)
      ...>
      ...> # Setup Processor
      ...> {:ok, _processor} = Processor.start_link(ProcessorQueue, ProcessorWorker)
      ...>
      ...> # Queue a Job
      ...> JobQueue.Queue.add_sync(ProcessorQueue, :done)
      {:ok, :done}
  """

  @doc """
  Starts a ConsumerSupervisor given a Queue name, the module of a worker and
  optional options.

  ## Options

    * `max_demand` - The maximum demand that will be asked for at once (think
      the max number of parallel jobs).
    * `min_demand` - The smallest amount of demand that will be asked for at
      once, for most queues you will want this to be 1.
  """
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
