defmodule Trivia.Bot do
  @moduledoc """
  SERVIDOR: jugador automático.

  Cada bot vive en su propio proceso, enlazado a su partida (muere con ella).
  Recibe las mismas notificaciones que el cliente humano y, cuando le llega una
  pregunta, decide qué contestar y programa la respuesta con `Process.send_after/3`.
  Responde por el mismo camino que un humano: `Trivia.Partida.responder/3`.

  La decisión (`decidir/4`) es una función separada del proceso para poder probarla.
  """
  use GenServer

  alias Trivia.Partida

  @letras ["A", "B", "C", "D"]

  # Probabilidad de acertar (%) por nivel y momento de la respuesta (% del tiempo)
  @dificultades %{
    facil: %{aciertos: %{basico: 40, intermedio: 30, avanzado: 20}, momento: {40, 90}},
    dificil: %{aciertos: %{basico: 80, intermedio: 70, avanzado: 60}, momento: {10, 40}}
  }

  # ========== API ==========

  @doc "Dificultades válidas."
  def dificultades, do: Map.keys(@dificultades)

  @doc "Convierte el texto del comando add_bot en una dificultad."
  def dificultad_desde_texto("facil"), do: {:ok, :facil}
  def dificultad_desde_texto("dificil"), do: {:ok, :dificil}
  def dificultad_desde_texto(_), do: {:error, :dificultad_invalida}

  @doc "Inicia el bot enlazado al proceso que lo llama (la partida)."
  def start_link(partida, nombre, dificultad) do
    GenServer.start_link(__MODULE__, %{partida: partida, nombre: nombre, dificultad: dificultad})
  end

  @doc """
  Decide la respuesta del bot: devuelve `{letra, retardo_ms}`.

  - Acierta según la probabilidad de su dificultad y del nivel de la pregunta.
  - Si falla, escoge al azar una de las tres opciones incorrectas.
  - El retardo cae dentro del rango de tiempo de su dificultad.
  """
  def decidir(dificultad, nivel, correcta, tiempo_pregunta) do
    %{aciertos: aciertos, momento: momento} = Map.fetch!(@dificultades, dificultad)
    {letra(Map.fetch!(aciertos, nivel), correcta), retardo(momento, tiempo_pregunta)}
  end

  @doc "Rango del retardo en milisegundos para una dificultad y un tiempo de pregunta."
  def rango_retardo(dificultad, tiempo_pregunta) do
    {minimo, maximo} = @dificultades |> Map.fetch!(dificultad) |> Map.fetch!(:momento)
    {div(tiempo_pregunta * 1000 * minimo, 100), div(tiempo_pregunta * 1000 * maximo, 100)}
  end

  # ========== Callbacks ==========

  @impl true
  def init(estado), do: {:ok, estado}

  # Llega una pregunta: el bot recibe además el nivel y la respuesta correcta
  # (datos privados que la partida nunca envía a los clientes)
  @impl true
  def handle_info({:trivia, {:pregunta, publica, %{nivel: nivel, respuesta: correcta}}}, estado) do
    {letra, retardo} = decidir(estado.dificultad, nivel, correcta, publica.tiempo)
    Process.send_after(self(), {:responder, letra}, retardo)
    {:noreply, estado}
  end

  # Se cumplió el retardo: responde como cualquier otro jugador
  def handle_info({:responder, letra}, estado) do
    responder(estado, letra)
    {:noreply, estado}
  end

  # La partida terminó bien: el bot también termina
  def handle_info(:terminar, estado), do: {:stop, :normal, estado}

  # Las demás notificaciones (cierre de ronda, ranking...) no le interesan al bot
  def handle_info(_mensaje, estado), do: {:noreply, estado}

  # ========== Funciones auxiliares ==========

  # Si la partida terminó justo antes de que el bot respondiera (por ejemplo, porque
  # el jugador abandonó), la llamada falla con un exit. Se ignora: el bot va a recibir
  # :terminar enseguida y no debe dejar un error en el log del servidor.
  defp responder(estado, letra) do
    Partida.responder(estado.partida, estado.nombre, letra)
  catch
    :exit, _razon -> :partida_no_disponible
  end

  defp letra(probabilidad, correcta) do
    if :rand.uniform(100) <= probabilidad do
      correcta
    else
      Enum.random(@letras -- [correcta])
    end
  end

  defp retardo({minimo, maximo}, tiempo_pregunta) do
    {desde, hasta} = {tiempo_pregunta * 1000 * minimo / 100, tiempo_pregunta * 1000 * maximo / 100}
    round(desde + :rand.uniform() * (hasta - desde))
  end
end
