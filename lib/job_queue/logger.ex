defmodule JobQueue.Logger do
  @moduledoc """
  A small helper module containing a `log` function. It is mostly used in
  `JobQueue.Worker` for logging details about a job's life cycle.
  """
  alias ImagesResouce.Queue.Job

  defmacro __using__(_) do
    quote location: :keep do
      require Logger

      @doc """
      Job life cycle log messages. This takes a log level, a job struct a
      message and optional details and prints it in a consistent format.
      """
      @spec log(atom, Job.t(), String.t(), String.t() | nil) :: :ok
      def log(level, job, message, details \\ nil) do
        log_func =
          case level do
            :error -> &Logger.error/1
            :warn -> &Logger.warn/1
            :info -> &Logger.info/1
            :debug -> &Logger.debug/1
          end

        log_func.(fn ->
          output = inspect(__MODULE__) <> " - " <> message <> " for: " <> inspect(job)

          if details do
            output <> " - " <> details
          else
            output
          end
        end)
      end
    end
  end
end
