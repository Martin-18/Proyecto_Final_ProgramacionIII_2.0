defmodule Trivia.SupervisorPartidas do
  @moduledoc """
  SERVIDOR: DynamicSupervisor de las partidas activas.

  Cada partida se agrega en tiempo de ejecución. Como `Trivia.Partida` usa
  `restart: :transient`, el supervisor la reinicia con los mismos argumentos
  solo cuando termina de forma anormal.
  """
  use DynamicSupervisor

  def start_link(_opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc "Arranca una partida nueva bajo el supervisor."
  def iniciar_partida(args), do: DynamicSupervisor.start_child(__MODULE__, {Trivia.Partida, args})

  @doc "PID de las partidas que están vivas en este momento."
  def pids_partidas do
    __MODULE__
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_id, pid, _tipo, _modulos} -> pid end)
    |> Enum.filter(&is_pid/1)
  end

  @impl true
  def init(:ok) do
    # Se permiten más reinicios que el valor por defecto (3 en 5 s), porque los
    # reinicios se cuentan sumando todas las partidas y una falla en varias a la vez
    # no debe tumbar al supervisor.
    DynamicSupervisor.init(strategy: :one_for_one, max_restarts: 20, max_seconds: 5)
  end
end
