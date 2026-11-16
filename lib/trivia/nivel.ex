defmodule Trivia.Nivel do
  @moduledoc """
  SERVIDOR: nivel del jugador en un tema y reparto de preguntas por nivel.

  Son funciones puras: reciben las líneas del historial (no abren el archivo),
  por eso se pueden probar con ExUnit pasando una lista de líneas.
  """
  alias Trivia.Historial

  @niveles [:basico, :intermedio, :avanzado]

  # Umbrales del puntaje acumulado en el tema
  @umbral_intermedio 60
  @umbral_avanzado 180

  # Porcentaje de preguntas de cada nivel según el nivel del jugador
  @reparto %{
    basico: %{basico: 70, intermedio: 30, avanzado: 0},
    intermedio: %{basico: 20, intermedio: 60, avanzado: 20},
    avanzado: %{basico: 0, intermedio: 30, avanzado: 70}
  }

  @doc "Lista de niveles ordenados de menor a mayor."
  def niveles, do: @niveles

  @doc "Decide el nivel a partir del puntaje acumulado en un tema."
  def nivel_por_puntaje(puntaje) when puntaje >= @umbral_avanzado, do: :avanzado
  def nivel_por_puntaje(puntaje) when puntaje >= @umbral_intermedio, do: :intermedio
  def nivel_por_puntaje(_puntaje), do: :basico

  @doc """
  Nivel de un jugador en un tema, calculado recorriendo las líneas del historial.
  Un tema nunca jugado da puntaje 0, es decir, nivel básico.
  """
  def nivel_en_tema(lineas, usuario, tema) do
    lineas
    |> Historial.puntaje_en_tema(usuario, tema)
    |> nivel_por_puntaje()
  end

  @doc """
  Cantidad de preguntas de cada nivel para una partida.

  Para los dos niveles distintos al del jugador se usa trunc(total * porcentaje / 100);
  las preguntas que sobran son del nivel del jugador.

      iex> Trivia.Nivel.reparto(:basico, 5)
      %{basico: 4, intermedio: 1, avanzado: 0}
  """
  def reparto(nivel, total) when nivel in @niveles and is_integer(total) and total > 0 do
    porcentajes = Map.fetch!(@reparto, nivel)

    otros =
      porcentajes
      |> Enum.reject(fn {nivel_pregunta, _porcentaje} -> nivel_pregunta == nivel end)
      |> Map.new(fn {nivel_pregunta, porcentaje} -> {nivel_pregunta, div(total * porcentaje, 100)} end)

    propias = total - (otros |> Map.values() |> Enum.sum())
    Map.put(otros, nivel, propias)
  end

  @doc "Texto del nivel para mostrar en pantalla."
  def texto(:basico), do: "básico"
  def texto(:intermedio), do: "intermedio"
  def texto(:avanzado), do: "avanzado"
  def texto(otro), do: to_string(otro)

  @doc "Convierte el texto de un nivel (por ejemplo del JSON) en átomo."
  def desde_texto("basico"), do: {:ok, :basico}
  def desde_texto("intermedio"), do: {:ok, :intermedio}
  def desde_texto("avanzado"), do: {:ok, :avanzado}
  def desde_texto(_), do: {:error, :nivel_invalido}
end
