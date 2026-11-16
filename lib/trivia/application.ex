defmodule Trivia.Application do
  @moduledoc """
  Arranque de la aplicación según el papel del nodo.

  - Un nodo cuyo nombre empieza por `servidor` (por ejemplo `iex --sname servidor -S mix`)
    levanta todo el árbol del servidor.
  - Cualquier otro nodo (clientes, `mix test`) no levanta nada del servidor: así el
    cliente nunca tiene su propia copia del juego. El cliente se abre con
    `Trivia.Cliente.iniciar()`.
  """
  use Application

  @impl true
  def start(_type, _args) do
    hijos = if servidor?(), do: hijos_servidor(), else: []
    Supervisor.start_link(hijos, strategy: :one_for_one, name: Trivia.Supervisor)
  end

  @doc "Indica si este nodo cumple el papel de servidor."
  def servidor? do
    node() |> Atom.to_string() |> String.starts_with?("servidor@")
  end

  # El orden importa: cada proceso puede usar a los que arrancaron antes que él
  defp hijos_servidor do
    [
      Trivia.Persistencia,       # Único proceso que escribe en data/
      Trivia.BancoPreguntas,     # Carga questions.json en memoria
      Trivia.GestorJugadores,    # Usuarios y sesiones
      Trivia.SupervisorPartidas, # DynamicSupervisor de las partidas
      Trivia.GestorPartidas,     # Creación y ubicación de partidas
      Trivia.Servidor            # Recibe las peticiones de los clientes
    ]
  end
end
