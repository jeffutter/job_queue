defmodule JobQueue.QueueTest do
  use ExUnit.Case

  alias JobQueue.{Job, Queue, Processor}

  defmodule Worker do
    def start_link(job = %Job{from: from, event: event}) do
      Task.start_link(fn ->
        case event do
          :ack ->
            Queue.ack(job)
            Process.send(from, event, [])

          :reply ->
            Queue.ack(job, :reply)

          :nack ->
            Queue.nack(%Job{job | event: :ack})
            Process.send(from, event, [])

          {:sleep, _} ->
            :timer.sleep(50)
            Queue.ack(job)
            Process.send(from, event, [])

          _ ->
            Process.send(from, event, [])
        end
      end)
    end
  end

  setup context do
    dedupe =
      if context[:dedupe] do
        true
      else
        false
      end

    {:ok, _queue} = Queue.start_link(TestQueue, dedupe: dedupe)
    {:ok, _processor} = Processor.start_link(TestQueue, Worker)
    :ok
  end

  test "it processes a job" do
    Queue.add(TestQueue, "foo")
    assert_receive "foo", 500
    assert in_progress_length() == 1
  end

  test "acks a job" do
    Queue.add(TestQueue, :ack)
    assert_receive :ack, 500
    assert in_progress_length() == 0
  end

  test "replies to a job" do
    Queue.add(TestQueue, :reply, reply: true)
    assert_receive :reply, 500
    assert in_progress_length() == 0
  end

  @tag dedupe: true
  test "dedupes a job" do
    Queue.add(TestQueue, {:sleep, :ok})
    Queue.add(TestQueue, {:sleep, :ok})
    Queue.add(TestQueue, {:sleep, :ok})
    Queue.add(TestQueue, {:sleep, :ok})

    assert queue_length() == 0
    assert in_progress_length() == 1

    assert_receive {:sleep, :ok}, 500
    refute_receive {:sleep, :ok}, 500
    assert in_progress_length() == 0
  end

  test "retries a job" do
    Queue.add(TestQueue, :nack)
    assert_receive :nack, 500
    assert_receive :ack, 500
    assert in_progress_length() == 0
  end

  test "processes 3 at a time" do
    0..9
    |> Enum.each(fn n -> Queue.add(TestQueue, {:sleep, n}) end)

    :timer.sleep(10)
    assert queue_length() == 7
    assert in_progress_length() == 3

    :timer.sleep(50)
    assert_receive {:sleep, 0}, 10
    assert_receive {:sleep, 1}, 10
    assert_receive {:sleep, 2}, 10
    assert queue_length() == 4
    assert in_progress_length() == 3

    :timer.sleep(50)
    assert_receive {:sleep, 3}, 10
    assert_receive {:sleep, 4}, 10
    assert_receive {:sleep, 5}, 10
    assert queue_length() == 1
    assert in_progress_length() == 3

    :timer.sleep(50)
    assert_receive {:sleep, 6}, 10
    assert_receive {:sleep, 7}, 10
    assert_receive {:sleep, 8}, 10
    assert queue_length() == 0
    assert in_progress_length() == 1

    :timer.sleep(50)
    assert_receive {:sleep, 9}, 10
    assert queue_length() == 0
    assert in_progress_length() == 0
  end

  defp queue_length do
    %Queue{q: q} = Queue.state(TestQueue)
    :queue.len(q)
  end

  defp in_progress_length do
    %Queue{in_progress: in_progress} = Queue.state(TestQueue)
    length(Map.keys(in_progress))
  end
end
