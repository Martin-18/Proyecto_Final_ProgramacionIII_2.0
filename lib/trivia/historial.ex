defmodule Trivia.Historial do
  @moduledoc """
  SERVIDOR: formato de las líneas de data/results.log y estadísticas calculadas desde ellas.

  Cada partida terminada es una línea de texto plano separada por `;`:

      fecha;id;tema;nivel;ganadores;jugador=puntaje,jugador=puntaje,...

  Ejemplo:

      2026-11-03 18:20:11;P-1001;ciencia;basico;pedro;pedro=48,bot_1=22,bot_2=-11

  Si hay empate, los ganadores van separados por `|`.
  Todas las funciones reciben cualquier enumerable de líneas (una lista o un
  `File.stream!/1`) y lo recorren con `Stream`, sin cargar todo el archivo.
  Las entradas de los bots (prefijo `bot_`) se ignoran en las estadísticas.
  """

  @separador ";"
  @prefijo_bot "bot_"

  # ========== Escritura ==========

  @doc "Construye la línea de historial de una partida."
  def linea(fecha, id, tema, nivel, ganadores, puntajes) do
    detalle =
      puntajes
      |> Enum.map(fn {jugador, puntaje} -> "#{jugador}=#{puntaje}" end)
      |> Enum.join(",")

    [fecha, id, tema, nivel, Enum.join(ganadores, "|"), detalle]
    |> Enum.join(@separador)
  end

  # ========== Lectura ==========

  @doc "Convierte una línea en un mapa. Devuelve `{:error, :linea_invalida}` si no tiene el formato."
  def parsear(linea) do
    case linea |> String.trim() |> String.split(@separador) do
      [fecha, id, tema, nivel, ganadores, detalle] ->
        {:ok,
         %{
           fecha: fecha,
           id: id,
           tema: tema,
           nivel: nivel,
           ganadores: String.split(ganadores, "|", trim: true),
           puntajes: parsear_puntajes(detalle)
         }}

      _ ->
        {:error, :linea_invalida}
    end
  end

  defp parsear_puntajes(detalle) do
    detalle
    |> String.split(",", trim: true)
    |> Enum.flat_map(fn par ->
      with [jugador, texto] <- String.split(par, "="),
           {puntaje, ""} <- Integer.parse(texto) do
        [{jugador, puntaje}]
      else
        _ -> []
      end
    end)
  end

  @doc "Stream de partidas válidas (las líneas mal formadas se descartan)."
  def entradas(lineas) do
    lineas
    |> Stream.map(&parsear/1)
    |> Stream.filter(&match?({:ok, _}, &1))
    |> Stream.map(fn {:ok, entrada} -> entrada end)
  end

  @doc "Indica si un nombre corresponde a un jugador automático."
  def bot?(jugador), do: String.starts_with?(jugador, @prefijo_bot)

  # Stream de {tema, jugador, puntaje} solo de jugadores humanos
  defp participaciones(lineas) do
    lineas
    |> entradas()
    |> Stream.flat_map(fn entrada ->
      Enum.map(entrada.puntajes, fn {jugador, puntaje} -> {entrada.tema, jugador, puntaje} end)
    end)
    |> Stream.reject(fn {_tema, jugador, _puntaje} -> bot?(jugador) end)
  end

  # ========== Estadísticas ==========

  @doc "Puntaje acumulado de un jugador en todas sus partidas."
  def puntaje_total(lineas, usuario) do
    lineas
    |> participaciones()
    |> Stream.filter(fn {_tema, jugador, _puntaje} -> jugador == usuario end)
    |> Stream.map(fn {_tema, _jugador, puntaje} -> puntaje end)
    |> Enum.sum()
  end

  @doc "Cantidad de partidas en las que participó el jugador."
  def partidas_jugadas(lineas, usuario) do
    lineas
    |> participaciones()
    |> Enum.count(fn {_tema, jugador, _puntaje} -> jugador == usuario end)
  end

  @doc "Puntaje del jugador en un tema. Un tema nunca jugado da 0."
  def puntaje_en_tema(lineas, usuario, tema) do
    lineas
    |> participaciones()
    |> Stream.filter(fn {t, jugador, _puntaje} -> t == tema and jugador == usuario end)
    |> Stream.map(fn {_tema, _jugador, puntaje} -> puntaje end)
    |> Enum.sum()
  end

  @doc "Mapa `%{tema => puntaje}` con los temas que ha jugado el usuario."
  def puntaje_por_tema(lineas, usuario) do
    lineas
    |> participaciones()
    |> Stream.filter(fn {_tema, jugador, _puntaje} -> jugador == usuario end)
    |> Enum.reduce(%{}, fn {tema, _jugador, puntaje}, acumulado ->
      Map.update(acumulado, tema, puntaje, &(&1 + puntaje))
    end)
  end

  @doc """
  Ranking histórico de jugadores humanos: lista de `{jugador, puntaje, partidas}`
  ordenada de mayor a menor puntaje. Con un tema, solo cuenta las partidas de ese tema.
  """
  def ranking(lineas, tema \\ nil) do
    lineas
    |> participaciones()
    |> Stream.filter(fn {t, _jugador, _puntaje} -> tema == nil or t == tema end)
    |> Enum.reduce(%{}, fn {_tema, jugador, puntaje}, acumulado ->
      Map.update(acumulado, jugador, {puntaje, 1}, fn {total, partidas} ->
        {total + puntaje, partidas + 1}
      end)
    end)
    |> Enum.map(fn {jugador, {puntaje, partidas}} -> {jugador, puntaje, partidas} end)
    |> Enum.sort_by(fn {jugador, puntaje, _partidas} -> {-puntaje, jugador} end)
  end

  @doc "Mayor número de partida registrado (por ejemplo 1004 para P-1004), o 1000 si no hay."
  def ultimo_numero_partida(lineas) do
    lineas
    |> entradas()
    |> Stream.map(fn entrada -> numero_partida(entrada.id) end)
    |> Enum.reduce(1000, &max/2)
  end

  @doc "Número de un id de partida (1004 para `P-1004`). Un id mal formado da 0."
  def numero_partida("P-" <> texto) do
    case Integer.parse(texto) do
      {numero, ""} -> numero
      _ -> 0
    end
  end

  def numero_partida(_id), do: 0
end
