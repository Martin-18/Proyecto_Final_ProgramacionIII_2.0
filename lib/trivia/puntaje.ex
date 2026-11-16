defmodule Trivia.Puntaje do
  @moduledoc """
  SERVIDOR: cálculo del puntaje de una ronda (funciones puras).

  | Situación            | Básico | Intermedio | Avanzado |
  |----------------------|--------|------------|----------|
  | Respuesta correcta   |   +10  |    +15     |   +20    |
  | Respuesta incorrecta |    -5  |     -8     |   -10    |
  | Sin responder        |     0  |      0     |     0    |

  A una respuesta correcta se le suma la bonificación por rapidez:
  `trunc(5 * segundos_restantes / tiempo_pregunta)`.
  """

  @correcta %{basico: 10, intermedio: 15, avanzado: 20}
  @incorrecta %{basico: -5, intermedio: -8, avanzado: -10}
  @bonificacion_maxima 5

  @doc """
  Puntos de una ronda.

  `resultado` es `:correcta`, `:incorrecta` o `:sin_responder`.
  `segundos_restantes` es lo que le faltaba al temporizador cuando llegó la respuesta.

      iex> Trivia.Puntaje.puntos_ronda(:basico, :correcta, 11, 15)
      13
  """
  def puntos_ronda(_nivel, :sin_responder, _segundos_restantes, _tiempo_pregunta), do: 0

  def puntos_ronda(nivel, :incorrecta, _segundos_restantes, _tiempo_pregunta),
    do: Map.fetch!(@incorrecta, nivel)

  def puntos_ronda(nivel, :correcta, segundos_restantes, tiempo_pregunta),
    do: Map.fetch!(@correcta, nivel) + bonificacion(segundos_restantes, tiempo_pregunta)

  @doc "Bonificación por rapidez, siempre entre 0 y 5."
  def bonificacion(segundos_restantes, tiempo_pregunta)
      when is_number(segundos_restantes) and segundos_restantes > 0 and tiempo_pregunta > 0 do
    min(trunc(@bonificacion_maxima * segundos_restantes / tiempo_pregunta), @bonificacion_maxima)
  end

  def bonificacion(_segundos_restantes, _tiempo_pregunta), do: 0

  @doc "Indica si una letra respondida es correcta, incorrecta o si no hubo respuesta."
  def resultado(nil, _correcta), do: :sin_responder
  def resultado(letra, letra), do: :correcta
  def resultado(_letra, _correcta), do: :incorrecta
end
