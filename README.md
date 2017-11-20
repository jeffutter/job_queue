# JobQueue

[![Build Status](https://travis-ci.org/jeffutter/job_queue.svg?branch=master)](https://travis-ci.org/jeffutter/job_queue)
[![Hex.pm](https://img.shields.io/hexpm/v/job_queue.svg?maxAge=2592000)](https://hex.pm/packages/job_queue)
[![Inline docs](http://inch-ci.org/github/jeffutter/job_queue.svg)](http://inch-ci.org/github/jeffutter/job_queue)
[![Deps Status](https://beta.hexfaktor.org/badge/all/github/jeffutter/job_queue.svg)](https://beta.hexfaktor.org/github/jeffutter/job_queue)
[![License](http://img.shields.io/badge/license-MIT-brightgreen.svg)](http://opensource.org/licenses/MIT)


JobQueue is a small library for building job queues in Elixir. It is based on GenStage and erlang :queues.

The goal of the library is to simplify creation of queues with both single and multiple steps, as well as retrying of individual steps and deduplication of events.

## Example Use Case

JobQueue allows building complex workflows such as:

**Image Resizer**
* Queue a job with a link to an image to download
* Master Queue
  * This queue can deduplicate urls so that it won't re-download an image that is already being processed
  * This queue can also re-try if any sub-jobs fail
  * This queue is broken down to the following steps:
    * Step 1: Download the image
      * With one download queue, this can limit the total number of simultaneous downloads 
      * Abort entire pipeline if download fails
    * Step 2: Fan out jobs to resize the image to multiple sizes
      * Limit the number of simultaneous resizes
      * Abort all sizes if one resize fails
    * Step 3: Upload each size to another S3 Bucket
      * Limit the number of simultaneous downloads
      * Retry upload on failure
    * Step 4: Cleanup
      * Cleanup on failures or success
      * Acknowledge job to Master Queue
  * Retry the whole job depending on the nature of sub-job failures

## Installation

Add `job_queue` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:job_queue, "~> 0.1.0"}
  ]
end
```

## Documentation

Full documentation can be found on hexdocs at [https://hexdocs.pm/job_queue/](https://hexdocs.pm/job_queue/)

## Quick Start

Write a Worker module to handle your events:

```elixir
defmodule Worker do
  use JobQueue.Worker

  def handle_event(event) do
    IO.inspect(event)
    {:ok, event}
  end
end
```

Start the Queue and Processor:

```elixir
{:ok, _queue} = JobQueue.Queue.start_link(MyQueue)
{:ok, _processor} = JobQueue.Processor.start_link(MyQueue, Worker)
```

Add some work to the Queue:

```elixir
JobQueue.Queue.add_sync(MyQueue, :done)
#=> :done
```

You can also start the queue and processor from a supervisor:

```elixir
defmodule MyApp.Application do
  @moduledoc false

  use Application

  def start(_type, _args) do
    import Supervisor.Spec, warn: false

    children = [
      worker(JobQueue.Queue, [MyQueue], id: MyQueue),
      worker(JobQueue.Processor, [MyQueue, MyWorker], id: MyWorker),
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```