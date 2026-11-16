defmodule Trivia.Servidor do
  @moduledoc """
  SERVIDOR: punto de entrada de las peticiones de los clientes.

  Se registra con el nombre `Trivia.Servidor`, así el cliente lo ubica con
  `{Trivia.Servidor, nodo_servidor}` sin conocer su PID. Identifica al jugador por
  el PID del receptor que el cliente envía en cada petición y enruta al gestor
  correspondiente. Siempre responde `{:ok, datos}`, `:ok` o `{:error, motivo}`.
  """
  use GenServer
  require Logger

  alias Trivia.{BancoPreguntas, Bot, GestorJugadores, GestorPartidas, Partida}

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  # ========== Callbacks ==========

  @impl true
  def init(:ok) do
    Util.imprimir_mensaje("""

    ===============================================
      Servidor de Trivia iniciado en #{node()}
      Esperando clientes...
    ===============================================
    """)

    {:ok, %{}}
  end

  @impl true
  def handle_call(peticion, _from, estado) do
    respuesta =
      try do
        atender(peticion)
      rescue
        # Un dato inesperado en una petición no puede tumbar al servidor
        error ->
          Logger.error("Petición #{comando(peticion)} lanzó un error: #{Exception.message(error)}")
          {:error, :error_interno}
      catch
        # Si una partida justo terminó o se está reiniciando, la llamada sale con exit
        :exit, _razon ->
          Logger.warning("Petición #{comando(peticion)}: la partida ya no estaba disponible")
          {:error, :no_en_partida}
      end

    {:reply, respuesta, estado}
  end

  # Solo el nombre del comando: la petición completa no se escribe en el log
  # porque connect lleva la clave del jugador
  defp comando(peticion) when is_tuple(peticion) and tuple_size(peticion) > 0, do: inspect(elem(peticion, 0))
  defp comando(_peticion), do: "desconocida"

  # ========== Enrutamiento ==========

  defp atender(:ping), do: :pong

  # El guard descarta una petición mal armada antes de que llegue al gestor
  defp atender({:connect, usuario, clave, cliente}) when is_pid(cliente),
    do: GestorJugadores.conectar(usuario, clave, cliente)

  defp atender({:disconnect, cliente}) do
    with {:ok, usuario} <- GestorJugadores.usuario_de(cliente) do
      GestorPartidas.abandonar(usuario) # Si no estaba en partida devuelve un error que se ignora
      GestorJugadores.desconectar(cliente)
    end
  end

  defp atender({:score, cliente}) do
    with {:ok, usuario} <- GestorJugadores.usuario_de(cliente), do: GestorJugadores.score(usuario)
  end

  defp atender({:ranking, cliente, tema}) do
    with {:ok, _usuario} <- GestorJugadores.usuario_de(cliente), do: GestorJugadores.ranking(tema)
  end

  # Temas del banco con la cantidad de preguntas por nivel (nunca las preguntas)
  defp atender({:topics, cliente}) do
    with {:ok, _usuario} <- GestorJugadores.usuario_de(cliente), do: {:ok, BancoPreguntas.cantidades()}
  end

  # Estado de la partida del jugador: tema, nivel, ronda actual y puntajes
  defp atender({:status, cliente}) do
    with {:ok, usuario} <- GestorJugadores.usuario_de(cliente),
         {:ok, partida} <- GestorPartidas.partida_de(usuario) do
      {:ok, partida |> Partida.info() |> Map.delete(:cliente)}
    end
  end

  defp atender({:create_game, cliente, tema, preguntas, tiempo}) do
    with {:ok, usuario} <- GestorJugadores.usuario_de(cliente) do
      GestorPartidas.crear(usuario, cliente, tema, preguntas, tiempo)
    end
  end

  defp atender({:add_bot, cliente, dificultad}) do
    with {:ok, usuario} <- GestorJugadores.usuario_de(cliente),
         {:ok, partida} <- GestorPartidas.partida_de(usuario),
         {:ok, dificultad} <- Bot.dificultad_desde_texto(dificultad) do
      Partida.agregar_bot(partida, dificultad)
    end
  end

  defp atender({:start_game, cliente}) do
    with {:ok, usuario} <- GestorJugadores.usuario_de(cliente),
         {:ok, partida} <- GestorPartidas.partida_de(usuario) do
      Partida.iniciar(partida)
    end
  end

  defp atender({:leave_game, cliente}) do
    with {:ok, usuario} <- GestorJugadores.usuario_de(cliente), do: GestorPartidas.abandonar(usuario)
  end

  defp atender({:answer, cliente, letra}) do
    with {:ok, usuario} <- GestorJugadores.usuario_de(cliente),
         {:ok, partida} <- GestorPartidas.partida_de(usuario) do
      Partida.responder(partida, usuario, letra)
    end
  end

  defp atender(_otra), do: {:error, :comando_desconocido}
end
