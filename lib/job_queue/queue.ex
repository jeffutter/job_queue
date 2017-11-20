defmodule JobQueue.Queue do
  @moduledoc """
  A GenStage based Queue that supports retries, tracking of in-progress jobs
  and deduplication. The queue itself is based on an erlang `:queue`.

  Being based on GenStage, the Queue will not process any events until a
  consumer is attached that requests demand.

  ## Example
      iex> # Setup a Worker
      ...> defmodule MyWorker do
      ...>   use GenStage
      ...>
      ...>   def start_link() do
      ...>     GenStage.start_link(__MODULE__, :ok)
      ...>   end
      ...>
      ...>   def init(:ok) do
      ...>     {:consumer, :ok, subscribe_to: [{MyWorkerQueue, min_demand: 1, max_demand: 3}]}
      ...>   end
      ...>
      ...>   def handle_events(events, _from, state) do
      ...>     for job = %JobQueue.Job{from: from, event: event} <- events do
      ...>       Process.send(from, event, [])
      ...>       Queue.ack(job)
      ...>     end
      ...>
      ...>     {:noreply, [], state}
      ...>   end
      ...> end
      ...>
      ...> # Start the Queue
      ...> {:ok, _queue} = Queue.start_link(MyWorkerQueue)
      ...>
      ...> # Start the Consumer
      ...> {:ok, _worker} = MyWorker.start_link()
      ...>
      ...> # Do some work
      ...> Queue.add(MyWorkerQueue, "Work Done")
      ...> receive do
      ...>   "Work Done" -> "Success"
      ...> after
      ...>   500 -> "Failure"
      ...> end
      "Success"

  This example uses a GenStage consumer for the worker. You could theoretically
  use multiple stages as long as the final consumer calls `JobQueue.Queue.ack` or
  `JobQueue.Queue.nack`. `JobQueue` also provides some assistance for creating simple,
  one-step workers using `JobQueue.Processor` and `JobQueue.Worker`. 
  """

  require Logger

  use GenStage

  alias JobQueue.Job

  @type t :: %{
          name: String.t(),
          q: :queue.queue(),
          in_progress: %{},
          pending_demand: integer,
          max_retries: integer,
          dedupe: boolean
        }

  defstruct name: "",
            q: nil,
            in_progress: %{},
            pending_demand: 0,
            max_retries: 5,
            dedupe: false

  # Client

  @doc """
  Starts a `JobQueue.Queue` with the given options.
  
  ## Options

    * `max_retries` - The maximum number of times jobs in this queue will 
      retry before failing.

    * `dedupe` - Whether or not the queue discards duplicate events that are
      already in the queue.

  ## Return values

  If the Queue is successfully created and initialized, this function returns
  `{:ok, pid}`, where `pid` is the pid of the stage. If a process with the
  specified name already exists, this function returns
  `{:error, {:already_started, pid}}` with the pid of that process.

  If the `JobQueue.Queue.init/1` callback fails with `reason`, this function returns
  `{:error, reason}`. Otherwise, if `JobQueue.Queue.init/1` returns `{:stop, reason}`
  or `:ignore`, the process is terminated and this function returns
  `{:error, reason}` or `:ignore`, respectively.
  """
  @spec start_link(any, Keyword.t()) :: GenServer.on_start()
  def start_link(name, options \\ []) do
    GenStage.start_link(__MODULE__, {name, options}, name: name)
  end

  @doc """
  Adds an event to the given queue with the given options.

  ## Options

    * `reply` - Wether the job will send a reply to the initiating process
      when `JobQueue.Queue.ack/2` is called.
  """
  @spec add(any, any, Keyword.t()) :: :ok
  def add(queue_name, event, options \\ []) do
    reply = Keyword.get(options, :reply, false)
    GenStage.cast(queue_name, {:push, event, self(), reply})
  end

  @doc """
  Adds an event to the given queue and waits for it to finish.
  """
  @spec add_sync(any, any, integer) :: {:ok, any} | {:error, any}
  def add_sync(module, message, timeout \\ 5_000) do
    # TODO: Make this actually cancel the task after timeout
    add(module, message, reply: true)

    receive do
      {:ok, message} ->
        {:ok, message}

      {:error, e} ->
        {:error, e}

      unknown ->
        Logger.error(fn -> "Unknown Message: #{inspect(unknown)}" end)
        {:ok, :ok}
    after
      timeout -> {:error, "timeout"}
    end
  end

  @doc """
  Adds a list of `{id, event}` to the given queue and waits for them all to finish.

  ## Options
  
    * `instance_timeout` - The timeout for any one event to process. Defaults to `5_000`.
    * `batch_timeout` - The timeout for the entire batch. Defaults to `20_000`.
  """
  @spec add_sync_batch(term, list({any, any}), Keyword.t()) ::
          {:ok, list({any, {:ok, any}})} | {:error, String.t(), any}
  def add_sync_batch(module, messages, options \\ []) do
    instance_timeout = Keyword.get(options, :instance_timeout, 5_000)
    batch_timeout = Keyword.get(options, :batch_timeout, 20_000)

    id_and_task =
      messages
      |> Enum.map(fn {id, message} ->
           {
             Task.async(fn ->
               case add_sync(module, message, instance_timeout) do
                 {:ok, message} -> {:ok, message}
                 {:error, e} -> {:error, e}
               end
             end),
             id
           }
         end)
      |> Enum.into(%{})

    results =
      id_and_task
      |> Enum.map(fn {task, _id} -> task end)
      |> Task.yield_many(batch_timeout)
      |> Enum.map(fn {task, res} ->
           {
             Map.get(id_and_task, task),
             res || Task.shutdown(task, :brutal_kill)
           }
         end)
      |> Enum.map(fn
           {id, {:ok, {:ok, message}}} -> {id, {:ok, message}}
           {id, {:ok, {:error, e}}} -> {id, {:error, e}}
           {id, {:exit, e}} -> {id, {:error, "Task Exited: #{inspect(e)}"}}
           {id, e} -> {id, {:error, "Unexpeceted Task Error: #{inspect(e)}"}}
         end)
      |> Enum.into(%{})

    if Enum.all?(results, fn
         {_, {:ok, _}} -> true
         _ -> false
       end) do
      {:ok, results}
    else
      {
        :error,
        "One or more failures in #{inspect(module)} task results: #{inspect(results)}",
        results
      }
    end
  end

  @doc """
  Acknowledges a given job. This removes it from the `in_progress` list.
  """
  @spec ack(Job.t()) :: :ok
  def ack(job = %Job{queue: queue}) do
    GenStage.cast(queue, {:ack, job})
  end

  @doc """
  Acknowledges a given job with a reply. The reply will be sent to the Queuing process
  as long as it was queued with `JobQueue.Queue.add(queue, event, reply: true)`.
  """
  @spec ack(Job.t(), any) :: :ok
  def ack(job = %Job{queue: queue}, reply) do
    GenStage.cast(queue, {:ack, job, reply})
  end

  @doc """
  Negative Acknowledge a give job. This removes it from the `in_progress` list.
  """
  @spec nack(Job.t()) :: :ok
  def nack(job = %Job{queue: queue}) do
    GenStage.cast(queue, {:nack, job})
  end

  @doc """
  Retrieves the current state of the Queue
  """
  @spec state(any) :: t
  def state(queue_name) do
    GenStage.call(queue_name, :state)
  end

  # Server

  @doc false
  def init({name, options}) do
    max_retries = Keyword.get(options, :max_retries, 5)
    dedupe = Keyword.get(options, :dedupe, false)

    {
      :producer,
      %__MODULE__{
        name: name,
        q: :queue.new(),
        in_progress: Map.new(),
        max_retries: max_retries,
        dedupe: dedupe
      }
    }
  end

  @doc false
  def handle_cast({:ack, %Job{id: id}}, queue = %__MODULE__{in_progress: in_progress}) do
    queue
    |> Map.put(:in_progress, Map.delete(in_progress, id))
    |> dispatch_jobs()
  end

  @doc false
  def handle_cast({:ack, job = %Job{from: from, reply: send_reply}, reply}, queue = %__MODULE__{}) do
    if send_reply do
      Process.send(from, reply, [])
    end

    handle_cast({:ack, job}, queue)
  end

  @doc false
  def handle_cast(
        {:nack, job = %Job{id: id, retry_count: retry_count}},
        queue = %__MODULE__{
          name: name,
          q: q,
          in_progress: in_progress,
          max_retries: max_retries
        }
      ) do
    if retry_count < max_retries do
      dispatch_jobs(%__MODULE__{
        queue
        | q: :queue.in(%Job{job | retry_count: retry_count + 1}, q),
          in_progress: Map.delete(in_progress, id)
      })
    else
      Logger.error(fn ->
        "#{inspect(name)} Queue failed to re-queue job, retry(#{retry_count}/#{max_retries}): #{
          inspect(job)
        }"
      end)

      queue
      |> Map.put(:in_progress, Map.delete(in_progress, id))
      |> dispatch_jobs()
    end
  end

  @doc false
  def handle_cast(
        {:push, event, from, reply},
        queue = %__MODULE__{q: q, name: name, dedupe: dedupe}
      ) do
    job = Job.new(event, name, from, reply)

    if dedupe && exists?(queue, job) do
      dispatch_jobs(queue)
    else
      queue
      |> Map.put(:q, :queue.in(job, q))
      |> dispatch_jobs()
    end
  end

  @doc false
  def handle_call(:state, _from, queue) do
    {:reply, queue, [], queue}
  end

  @doc false
  def handle_demand(incoming_demand, queue = %__MODULE__{pending_demand: pending_demand}) do
    queue
    |> Map.put(:pending_demand, incoming_demand + pending_demand)
    |> dispatch_jobs()
  end

  # Private Functions

  defp dispatch_jobs(
         queue = %__MODULE__{
           name: name,
           q: q,
           pending_demand: pending_demand,
           in_progress: in_progress
         },
         jobs \\ []
       ) do
    if pending_demand > 0 do
      case :queue.out(q) do
        {{:value, job}, q} ->
          dispatch_jobs(
            %__MODULE__{
              queue
              | q: q,
                pending_demand: pending_demand - 1,
                in_progress: Map.put(in_progress, job.id, job)
            },
            [job | jobs]
          )

        {:empty, q} ->
          Logger.debug(fn -> "#{inspect(name)} Queue Empty" end)
          {:noreply, Enum.reverse(jobs), %__MODULE__{queue | q: q}}
      end
    else
      {:noreply, Enum.reverse(jobs), queue}
    end
  end

  defp exists?(%__MODULE__{q: q, in_progress: in_progress}, %Job{event: event}) do
    c = fn
      %Job{event: ^event} -> true
      _ -> false
    end

    Enum.any?(:queue.to_list(q), c) || Enum.any?(Map.values(in_progress), c)
  end
end
