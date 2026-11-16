defmodule Trivia.Pregunta do
  @moduledoc "SERVIDOR: estructura de una pregunta del banco."
  @enforce_keys [:tema, :nivel, :enunciado, :opciones, :respuesta]
  defstruct [:tema, :nivel, :enunciado, :opciones, :respuesta]
end

defmodule Trivia.BancoPreguntas do
  @moduledoc """
  SERVIDOR: carga el banco de preguntas al arrancar y lo mantiene en memoria.

  El banco se organiza como `%{tema => %{nivel => [%Pregunta{}]}}`.
  El sorteo y la validación son funciones puras (`sortear_en/4`, `validar_en/4`)
  para poder probarlas sin levantar el proceso.
  """
  use GenServer
  require Logger

  alias Trivia.{Nivel, Pregunta, Persistencia}

  @letras ["A", "B", "C", "D"]
  @campos ["tema", "nivel", "enunciado", "opciones", "respuesta"]

  # ========== API ==========

  def start_link(opciones \\ []) do
    GenServer.start_link(__MODULE__, opciones, name: __MODULE__)
  end

  @doc "Temas disponibles en el banco."
  def temas, do: GenServer.call(__MODULE__, :temas)

  @doc "Temas con la cantidad de preguntas de cada nivel (para el comando topics)."
  def cantidades, do: GenServer.call(__MODULE__, :cantidades)

  @doc "Verifica que el tema exista y alcance para el reparto del nivel."
  def validar(tema, nivel, total), do: GenServer.call(__MODULE__, {:validar, tema, nivel, total})

  @doc "Sortea las preguntas de una partida."
  def sortear(tema, nivel, total), do: GenServer.call(__MODULE__, {:sortear, tema, nivel, total})

  # ========== Callbacks ==========

  @impl true
  def init(opciones) do
    ruta = Keyword.get(opciones, :ruta, Path.join(Persistencia.directorio(), "questions.json"))

    case Persistencia.cargar_preguntas(ruta) do
      {:ok, lista} ->
        {banco, descartadas} = construir(lista)
        Logger.info("Banco de preguntas cargado: #{resumen(banco)}")
        if descartadas > 0, do: Logger.warning("Se descartaron #{descartadas} preguntas mal formadas")
        {:ok, banco}

      {:error, motivo} ->
        Logger.error("No se pudo cargar #{ruta}: #{inspect(motivo)}")
        {:ok, %{}}
    end
  end

  @impl true
  def handle_call(:temas, _from, banco), do: {:reply, banco |> Map.keys() |> Enum.sort(), banco}

  def handle_call(:cantidades, _from, banco), do: {:reply, cantidades_de(banco), banco}

  def handle_call({:validar, tema, nivel, total}, _from, banco) do
    {:reply, validar_en(banco, tema, nivel, total), banco}
  end

  def handle_call({:sortear, tema, nivel, total}, _from, banco) do
    {:reply, sortear_en(banco, tema, nivel, total), banco}
  end

  # ========== Funciones puras ==========

  @doc """
  Construye el banco a partir de la lista leída del JSON.
  Devuelve `{banco, cantidad_descartadas}`.
  """
  def construir(lista) do
    {validas, invalidas} =
      lista
      |> Enum.map(&convertir/1)
      |> Enum.split_with(&match?({:ok, _}, &1))

    banco =
      validas
      |> Enum.map(fn {:ok, pregunta} -> pregunta end)
      |> Enum.group_by(& &1.tema)
      |> Map.new(fn {tema, preguntas} -> {tema, Enum.group_by(preguntas, & &1.nivel)} end)

    {banco, length(invalidas)}
  end

  @doc """
  Lista ordenada de `{tema, %{basico: n, intermedio: n, avanzado: n}}` con la
  cantidad de preguntas de cada nivel.
  """
  def cantidades_de(banco) do
    banco
    |> Enum.map(fn {tema, por_nivel} ->
      {tema, Map.new(Nivel.niveles(), fn nivel -> {nivel, length(Map.get(por_nivel, nivel, []))} end)}
    end)
    |> Enum.sort()
  end

  @doc "Verifica que exista el tema y que haya suficientes preguntas para el reparto."
  def validar_en(banco, tema, nivel, total) do
    case Map.fetch(banco, tema) do
      :error ->
        {:error, :tema_inexistente}

      {:ok, por_nivel} ->
        alcanza =
          nivel
          |> Nivel.reparto(total)
          |> Enum.all?(fn {nivel_pregunta, cantidad} ->
            length(Map.get(por_nivel, nivel_pregunta, [])) >= cantidad
          end)

        if alcanza, do: :ok, else: {:error, :preguntas_insuficientes}
    end
  end

  @doc """
  Sortea sin repetir las preguntas de cada nivel según el reparto, y las ordena
  de menor a mayor nivel (dentro de un nivel quedan en el orden del sorteo).
  """
  def sortear_en(banco, tema, nivel, total) do
    with :ok <- validar_en(banco, tema, nivel, total) do
      reparto = Nivel.reparto(nivel, total)
      por_nivel = Map.fetch!(banco, tema)

      preguntas =
        Enum.flat_map(Nivel.niveles(), fn nivel_pregunta ->
          por_nivel
          |> Map.get(nivel_pregunta, [])
          |> Enum.take_random(Map.fetch!(reparto, nivel_pregunta))
        end)
        |> Enum.shuffle()

      {:ok, preguntas}
    end
  end

  # Convierte un mapa del JSON en %Pregunta{} validando sus campos
  defp convertir(%{} = mapa) do
    with true <- Util.contiene_todos?(Map.keys(mapa), @campos),
         {:ok, nivel} <- Nivel.desde_texto(mapa["nivel"]),
         %{} = opciones <- mapa["opciones"],
         true <- Enum.sort(Map.keys(opciones)) == @letras,
         true <- mapa["respuesta"] in @letras,
         true <- tema_valido?(mapa["tema"]) do
      {:ok,
       %Pregunta{
         tema: mapa["tema"],
         nivel: nivel,
         enunciado: mapa["enunciado"],
         opciones: opciones,
         respuesta: mapa["respuesta"]
       }}
    else
      _ -> {:error, :pregunta_invalida}
    end
  end

  defp convertir(_), do: {:error, :pregunta_invalida}

  defp tema_valido?(tema) when is_binary(tema), do: tema != "" and tema == String.downcase(tema) and not String.contains?(tema, " ")
  defp tema_valido?(_), do: false

  defp resumen(banco) do
    banco
    |> Enum.map(fn {tema, por_nivel} ->
      cantidades = Enum.map(Nivel.niveles(), fn nivel -> length(Map.get(por_nivel, nivel, [])) end)
      "#{tema} (#{Enum.join(cantidades, "/")})"
    end)
    |> Enum.join(", ")
  end
end
