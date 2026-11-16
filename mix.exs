defmodule Trivia.MixProject do
  use Mix.Project # Indica que este módulo es un proyecto Mix

  # Configuración del proyecto
  def project do
    [
      app: :proyecto_trivia,
      version: "1.0.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Configuración de la aplicación.
  # Trivia.Application decide, según el nombre del nodo, si levanta el servidor o no.
  def application do
    [
      mod: {Trivia.Application, []},
      extra_applications: [:logger]
    ]
  end

  # Librerías externas que usa el proyecto
  defp deps do
    [
      {:jason, "~> 1.4"} # Lectura y escritura de JSON (users.json y questions.json)
    ]
  end
end
