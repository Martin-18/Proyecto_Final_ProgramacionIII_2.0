defmodule Trivia.Persistencia do
  @moduledoc """
  SERVIDOR: lectura y escritura de los archivos de `data/`.

  Todas las escrituras (users.json y results.log) pasan por este único GenServer,
  así dos partidas que terminan al mismo tiempo no mezclan sus líneas.
  Las lecturas del historial se hacen con `File.stream!/1` para recorrerlo línea por línea.
  """
  use GenServer

  @usuarios "users.json"
  @preguntas "questions.json"
  @resultados "results.log"

  # ========== API ==========

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc "Guarda la lista completa de usuarios `[%{\"usuario\" => u, \"clave\" => c}]`."
  def guardar_usuarios(usuarios), do: GenServer.call(__MODULE__, {:guardar_usuarios, usuarios})

  @doc "Agrega una línea al historial de partidas."
  def registrar_resultado(linea), do: GenServer.call(__MODULE__, {:registrar_resultado, linea})

  @doc """
  Ejecuta `funcion` sobre el historial dentro de este proceso y devuelve su resultado.

  La función recibe el stream de líneas (por ejemplo `&Historial.ranking/1`). Como
  este proceso atiende un mensaje a la vez, una consulta nunca lee el archivo
  mientras otra partida está escribiendo su línea.
  """
  def consultar_historial(funcion) when is_function(funcion, 1),
    do: GenServer.call(__MODULE__, {:consultar_historial, funcion})

  @doc "Lee los usuarios registrados. Si el archivo no existe devuelve una lista vacía."
  def cargar_usuarios do
    case leer_json(ruta(@usuarios)) do
      {:ok, lista} when is_list(lista) -> lista
      _ -> []
    end
  end

  @doc "Lee el banco de preguntas desde questions.json."
  def cargar_preguntas(ruta_archivo \\ ruta(@preguntas)) do
    case leer_json(ruta_archivo) do
      {:ok, lista} when is_list(lista) -> {:ok, lista}
      {:ok, _otro} -> {:error, :formato_invalido}
      {:error, motivo} -> {:error, motivo}
    end
  end

  @doc """
  Devuelve el historial como un stream de líneas (lazy).
  Si todavía no hay partidas registradas devuelve una lista vacía.
  Los demás procesos del servidor no la llaman directamente: usan `consultar_historial/1`.
  """
  def historial do
    archivo = ruta(@resultados)

    if File.exists?(archivo) do
      archivo
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
    else
      []
    end
  end

  @doc "Carpeta donde viven los archivos de datos (configurable para pruebas)."
  def directorio, do: Application.get_env(:proyecto_trivia, :directorio_datos, "data")

  # ========== Callbacks ==========

  @impl true
  def init(:ok) do
    File.mkdir_p!(directorio())
    {:ok, %{}}
  end

  @impl true
  def handle_call({:guardar_usuarios, usuarios}, _from, estado) do
    respuesta =
      case Jason.encode(usuarios, pretty: true) do
        {:ok, json} -> File.write(ruta(@usuarios), json)
        {:error, motivo} -> {:error, motivo}
      end

    {:reply, respuesta, estado}
  end

  @impl true
  def handle_call({:registrar_resultado, linea}, _from, estado) do
    # [:append] agrega al final sin sobrescribir lo que ya había
    {:reply, File.write(ruta(@resultados), linea <> "\n", [:append]), estado}
  end

  @impl true
  def handle_call({:consultar_historial, funcion}, _from, estado) do
    {:reply, funcion.(historial()), estado}
  end

  # ========== Funciones auxiliares ==========

  defp ruta(nombre), do: Path.join(directorio(), nombre)

  defp leer_json(ruta_archivo) do
    with {:ok, contenido} <- File.read(ruta_archivo),
         {:ok, datos} <- Jason.decode(contenido) do
      {:ok, datos}
    end
  end
end
