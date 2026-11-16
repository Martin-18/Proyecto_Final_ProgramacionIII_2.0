defmodule Trivia.Ronda do
  @moduledoc """
  SERVIDOR: estado y reglas de una ronda abierta (funciones puras).

  La partida guarda `nil` cuando no hay ronda abierta (antes de iniciar, en la
  pausa de 3 segundos entre rondas o al terminar). Así, una respuesta que llega
  en esos momentos se rechaza en lugar de contar para la pregunta siguiente.
  """
  alias Trivia.Puntaje

  @letras ["A", "B", "C", "D"]

  defstruct numero: 0, pregunta: nil, inicio_ms: 0, respuestas: %{}

  @doc "Abre una ronda registrando el instante (en milisegundos) en que empieza."
  def nueva(numero, pregunta, inicio_ms) do
    %__MODULE__{numero: numero, pregunta: pregunta, inicio_ms: inicio_ms}
  end

  @doc """
  Registra la respuesta de un jugador.

  Reglas:
  - Sin ronda abierta se rechaza con `:sin_ronda_abierta`.
  - Una letra distinta de A, B, C o D se rechaza con `:letra_invalida` y no consume la respuesta.
  - Solo cuenta la primera respuesta; las siguientes dan `:ya_respondio`.
  """
  def registrar(ronda, jugador, letra, instante_ms) do
    with {:ok, ronda} <- abierta(ronda),
         {:ok, letra} <- validar_letra(letra),
         :ok <- primera_respuesta(ronda, jugador) do
      {:ok, %{ronda | respuestas: Map.put(ronda.respuestas, jugador, {letra, instante_ms})}}
    end
  end

  @doc "Indica si ya respondieron todos los jugadores de la lista."
  def todos_respondieron?(ronda, jugadores) do
    Util.contiene_todos?(Map.keys(ronda.respuestas), jugadores)
  end

  @doc """
  Puntos que obtuvo cada jugador en la ronda: lista de `{jugador, puntos}`.
  Los segundos restantes se calculan con el instante en que llegó cada respuesta.
  """
  def resultados(ronda, jugadores, tiempo_pregunta) do
    %{nivel: nivel, respuesta: correcta} = ronda.pregunta

    Enum.map(jugadores, fn jugador ->
      case Map.get(ronda.respuestas, jugador) do
        nil ->
          {jugador, Puntaje.puntos_ronda(nivel, :sin_responder, 0, tiempo_pregunta)}

        {letra, instante_ms} ->
          restantes = segundos_restantes(ronda.inicio_ms, instante_ms, tiempo_pregunta)
          {jugador, Puntaje.puntos_ronda(nivel, Puntaje.resultado(letra, correcta), restantes, tiempo_pregunta)}
      end
    end)
  end

  @doc "Segundos que le faltaban al temporizador en el instante de la respuesta."
  def segundos_restantes(inicio_ms, instante_ms, tiempo_pregunta) do
    max(tiempo_pregunta * 1000 - (instante_ms - inicio_ms), 0) / 1000
  end

  @doc "Normaliza y valida la letra de una respuesta."
  def validar_letra(letra) when is_binary(letra) do
    letra = letra |> String.trim() |> String.upcase()
    if letra in @letras, do: {:ok, letra}, else: {:error, :letra_invalida}
  end

  def validar_letra(_), do: {:error, :letra_invalida}

  defp abierta(nil), do: {:error, :sin_ronda_abierta}
  defp abierta(%__MODULE__{} = ronda), do: {:ok, ronda}

  defp primera_respuesta(ronda, jugador) do
    if Map.has_key?(ronda.respuestas, jugador), do: {:error, :ya_respondio}, else: :ok
  end
end
