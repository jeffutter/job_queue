defmodule JobQueue.Logger do
  alias ImagesResouce.Queue.Job

  defmacro __using__(_) do
    quote location: :keep do
      require Logger

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

          output =
            if details do
              output <> " - " <> details
            else
              output
            end

          output
        end)
      end
    end
  end
end
