defmodule JobQueue.Mixfile do
  use Mix.Project

  def project do
    [
      app: :job_queue,
      docs: [
        extras: ["README.md"]
      ],
      deps: deps(),
      description: description(),
      elixir: "~> 1.5",
      name: "Job Queue",
      package: package(),
      source_url: "https://github.com/jeffutter/job_queue",
      start_permanent: Mix.env() == :prod,
      version: "0.1.0"
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
      {:earmark, "~> 0.1", only: :dev},
      {:ex_doc, "~> 0.11", only: :dev},
      {:dialyxir, "~> 0.5", only: [:dev], runtime: false},
      {:inch_ex, only: :docs},
      gen_stage: "~> 0.12.1"
    ]
  end

  defp description do
    """
    Job Queue based on Genstage with retries, deduplication and replies.
    """
  end

  def package do
    [
      name: :job_queue,
      maintainers: ["Jeffery Utter"],
      licenses: ["MIT"],
      links: %{"Github" => "https://github.com/jeffutter/job_queue"},
    ]
  end
end
