defmodule JobQueue.Worker do
  @moduledoc """
  A behaviour and a module to handle some of the ceremony around a ConsumerSupervisor Worker.

  ## Example
      iex> # Setup Worker
      ...> defmodule JobQueueWorker do
      ...>   use JobQueue.Worker
      ...>
      ...>   def handle_event(event) do
      ...>     {:ok, event}
      ...>   end
      ...> end
      ...>
      ...> # Start Queue
      ...> {:ok, _queue} = JobQueue.Queue.start_link(WorkerQueue)
      ...>
      ...> # Setup Processor
      ...> {:ok, _processor} = JobQueue.Processor.start_link(WorkerQueue, JobQueueWorker)
      ...>
      ...> # Queue a Job
      ...> JobQueue.Queue.add_sync(WorkerQueue, :done)
      {:ok, :done}

  Compare this with the documentation of `JobQueue.Processor` to see the advantage to using `Worker`
  """
  alias JobQueue.{Job, Queue}

  @doc """
  A callback to handle events coming off the queue.

  ## Return Values
    * `{:ok, message}` - This will `ack` the message back to the Queue and
       reply with `message`
    * `{:error, message}` - This will `nack` the message back to the Queue with
      `message` as the error message.
    * `{:retry, message}` - This will retry the job on the queue sending along
      `message`.
  """
  @callback handle_event(any) :: {:ok, any} | {:error, any} | {:retry, any}

  defmacro __using__(_) do
    quote location: :keep do
      use JobQueue.Logger

      @behaviour JobQueue.Worker

      def start_link(job = %Job{event: event}) do
        log(:info, job, "Adding")

        start_time =
          if Logger.level() in [:debug, :info] do
            :erlang.monotonic_time()
          else
            nil
          end

        Task.start_link(fn ->
          case handle_event(event) do
            {:ok, response} ->
              log_time(job, start_time)
              log(:debug, job, "Complete")
              Queue.ack(job, {:ok, response})

            {:retry, message} ->
              log(:error, job, "Retrying", message)
              Queue.nack(job)

            {:error, response} ->
              log(:error, job, "Failed", response)
              log_time(job, start_time)
              Queue.ack(job, {:error, response})

            unknown ->
              log(:error, job, "Unknown Message", unknown)
          end
        end)
      end

      def log_time(job, start_time) do
        if Logger.level() in [:debug, :info] do
          end_time = :erlang.monotonic_time()

          duration =
            :erlang.convert_time_unit(
              end_time - start_time,
              :native,
              :millisecond
            )

          log(
            :info,
            job,
            "Duration",
            to_string(duration) <> "ms"
          )
        end
      end
    end
  end
end
