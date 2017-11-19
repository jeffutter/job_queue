defmodule JobQueue.Queue do
  require Logger

  use GenStage

  alias JobQueue.Job

  defstruct name: "", q: nil, in_progress: nil, pending_demand: 0, max_retries: 5, dedupe: false

  # Client

  def start_link(name, options \\ []) do
    GenStage.start_link(__MODULE__, {name, options}, name: name)
  end

  def add(queue_name, event, options \\ []) do
    reply = Keyword.get(options, :reply, false)
    GenStage.cast(queue_name, {:push, event, self(), reply})
  end

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
        Logger.error("Unknown Message: #{inspect(unknown)}")
        {:ok, :ok}
    after
      timeout -> {:error, "timeout"}
    end
  end

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

  def ack(job = %Job{queue: queue}) do
    GenStage.cast(queue, {:ack, job})
  end

  def ack(job = %Job{queue: queue}, reply) do
    GenStage.cast(queue, {:ack, job, reply})
  end

  def nack(job = %Job{queue: queue}) do
    GenStage.cast(queue, {:nack, job})
  end

  def state(queue_name) do
    GenStage.call(queue_name, :state)
  end

  # Server

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

  def handle_cast({:ack, %Job{id: id}}, queue = %__MODULE__{in_progress: in_progress}) do
    dispatch_jobs(%__MODULE__{queue | in_progress: Map.delete(in_progress, id)}, [])
  end

  def handle_cast({:ack, job = %Job{from: from, reply: send_reply}, reply}, queue = %__MODULE__{}) do
    if send_reply do
      Process.send(from, reply, [])
    end

    handle_cast({:ack, job}, queue)
  end

  def handle_cast(
        {:nack, job = %Job{id: id, retry_count: retry_count}},
        queue = %__MODULE__{name: name, q: q, in_progress: in_progress, max_retries: max_retries}
      ) do
    if retry_count < max_retries do
      dispatch_jobs(
        %__MODULE__{
          queue
          | q: :queue.in(%Job{job | retry_count: retry_count + 1}, q),
            in_progress: Map.delete(in_progress, id)
        },
        []
      )
    else
      Logger.error(
        "#{inspect(name)} Queue failed to re-queue job, retry(#{retry_count}/#{max_retries}): #{
          inspect(job)
        }"
      )

      dispatch_jobs(%__MODULE__{queue | in_progress: Map.delete(in_progress, id)}, [])
    end
  end

  def handle_cast(
        {:push, event, from, reply},
        queue = %__MODULE__{q: q, name: name, dedupe: dedupe}
      ) do
    job = Job.new(event, name, from, reply)

    if dedupe && exists?(queue, job) do
      dispatch_jobs(queue, [])
    else
      updated_queue = :queue.in(job, q)
      dispatch_jobs(%__MODULE__{queue | q: updated_queue}, [])
    end
  end

  def handle_call(:state, _from, queue) do
    {:reply, queue, [], queue}
  end

  def handle_demand(incoming_demand, queue = %__MODULE__{pending_demand: pending_demand}) do
    dispatch_jobs(%__MODULE__{queue | pending_demand: incoming_demand + pending_demand}, [])
  end

  # Private Functions

  defp dispatch_jobs(
         queue = %__MODULE__{
           name: name,
           q: q,
           pending_demand: pending_demand,
           in_progress: in_progress
         },
         jobs
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
          Logger.debug("#{inspect(name)} Queue Empty")
          {:noreply, Enum.reverse(jobs), %__MODULE__{queue | q: q}}
      end
    else
      {:noreply, Enum.reverse(jobs), queue}
    end
  end

  defp exists?(%__MODULE__{q: q, in_progress: in_progress}, %Job{event: event}) do
    compare = fn
      %Job{event: ^event} -> true
      _ -> false
    end

    Enum.any?(:queue.to_list(q), compare) || Enum.any?(Map.values(in_progress), compare)
  end
end
