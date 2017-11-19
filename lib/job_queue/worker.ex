defmodule JobQueue.Worker do
  alias JobQueue.{Job, Queue}

  @callback handle_event(event :: any) :: {:ok, any} | {:error, any} | {:retry, any}

  defmacro __using__(_) do
    quote location: :keep do
      use JobQueue.Logger

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

          log(
            :info,
            job,
            "Duration",
            to_string(:erlang.convert_time_unit(end_time - start_time, :native, :millisecond)) <>
              "ms"
          )
        end
      end
    end
  end
end
