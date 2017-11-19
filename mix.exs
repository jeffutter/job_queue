defmodule JobQueue.Mixfile do
  use Mix.Project

  def project do
    [
      app: :job_queue,
      version: "0.1.0",
      elixir: "~> 1.5",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:credo, "~> 0.8", only: [:dev, :test], runtime: false},
      gen_stage: "~> 0.12.1"
    ]
  end
end
