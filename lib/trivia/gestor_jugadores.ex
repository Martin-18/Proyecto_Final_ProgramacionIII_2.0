defmodule Trivia.GestorJugadores do
  @moduledoc """
  SERVIDOR: registro, sesiones, puntajes y ranking.

  - Los usuarios se cargan de data/users.json al arrancar y se guardan a través de
    `Trivia.Persistencia` cuando alguien se registra.
  - Una sesión asocia un usuario con el PID del receptor de su cliente. Ese PID se
    monitorea: si el cliente se cae, llega `:DOWN`, se cierra la sesión y se aplica
    el abandono de la partida.
  - El puntaje, las partidas jugadas, el nivel y el ranking se calculan recorriendo
    el historial con streams; el jugador no guarda estadísticas.
  """
  use GenServer
  require Logger

  alias Trivia.{GestorPartidas, Historial, Nivel, Persistencia}

  @prefijo_reservado "bot_"
  @caracteres_prohibidos [" ", ";", "=", ",", "|"]

  # ========== API ==========

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Inicia sesión; si el usuario no existe lo registra."
  def conectar(usuario, clave, cliente), do: GenServer.call(__MODULE__, {:conectar, usuario, clave, cliente})

  @doc "Cierra la sesión asociada al PID del cliente."
  def desconectar(cliente), do: GenServer.call(__MODULE__, {:desconectar, cliente})

  @doc "Usuario que tiene sesión abierta con ese PID de cliente."
  def usuario_de(cliente), do: GenServer.call(__MODULE__, {:usuario_de, cliente})

  @doc "Puntaje acumulado, partidas jugadas y detalle por tema."
  def score(usuario), do: GenServer.call(__MODULE__, {:score, usuario})

  @doc "Ranking histórico global, o de un tema."
  def ranking(tema \\ nil), do: GenServer.call(__MODULE__, {:ranking, tema})

  # ========== Callbacks ==========

  @impl true
  def init(:ok) do
    usuarios =
      Persistencia.cargar_usuarios()
      |> Util.indexar_por("usuario")
      |> Map.new(fn {usuario, datos} -> {usuario, datos["clave"]} end)

    Logger.info("Usuarios registrados cargados: #{map_size(usuarios)}")
    {:ok, %{usuarios: usuarios, sesiones: %{}, por_cliente: %{}}}
  end

  @impl true
  def handle_call({:conectar, usuario, clave, cliente}, _from, estado) do
    with :ok <- validar_usuario(usuario),
         :ok <- validar_clave(clave),
         :ok <- cliente_sin_sesion(estado, cliente),
         :ok <- usuario_sin_sesion(estado, usuario),
         {:ok, nuevo_registro, estado} <- autenticar(estado, usuario, clave) do
      referencia = make_ref()

      estado = %{
        estado
        | sesiones: Map.put(estado.sesiones, usuario, {cliente, referencia}),
          por_cliente: Map.put(estado.por_cliente, cliente, usuario)
      }

      Logger.info("#{usuario} inició sesión desde #{node(cliente)}")
      {:reply, {:ok, %{usuario: usuario, nuevo: nuevo_registro}}, estado}
    else
      error -> {:reply, error, estado}
    end
  end

  def handle_call({:desconectar, cliente}, _from, estado) do
    case Map.fetch(estado.por_cliente, cliente) do
      {:ok, usuario} ->
        Logger.info("#{usuario} cerró sesión")
        {:reply, {:ok, usuario}, cerrar_sesion(estado, usuario, true)}

      :error ->
        {:reply, {:error, :sin_sesion}, estado}
    end
  end

  def handle_call({:usuario_de, cliente}, _from, estado) do
    case Map.fetch(estado.por_cliente, cliente) do
      {:ok, usuario} -> {:reply, {:ok, usuario}, estado}
      :error -> {:reply, {:error, :sin_sesion}, estado}
    end
  end

  def handle_call({:score, usuario}, _from, estado) do
    {:reply, {:ok, Persistencia.consultar_historial(&calcular_score(&1, usuario))}, estado}
  end

  def handle_call({:ranking, tema}, _from, estado) do
    filas = Persistencia.consultar_historial(&Historial.ranking(&1, tema))
    {:reply, {:ok, %{tema: tema, filas: filas}}, estado}
  end

  # El proceso del cliente desapareció (se cerró la consola o se cayó el nodo)
  @impl true
  def handle_info({:DOWN, _referencia, :process, cliente, razon}, estado) do
    case Map.fetch(estado.por_cliente, cliente) do
      {:ok, usuario} ->
        Logger.warning("El cliente de #{usuario} se desconectó (#{inspect(razon)})")
        GestorPartidas.jugador_desconectado(usuario)
        {:noreply, cerrar_sesion(estado, usuario, false)}

      :error ->
        {:noreply, estado}
    end
  end

  def handle_info(_mensaje, estado), do: {:noreply, estado}

  # ========== Funciones puras ==========

  @doc "Score de un usuario a partir de las líneas del historial."
  def calcular_score(lineas, usuario) do
    temas =
      lineas
      |> Historial.puntaje_por_tema(usuario)
      |> Enum.map(fn {tema, puntaje} -> {tema, puntaje, Nivel.nivel_por_puntaje(puntaje)} end)
      |> Enum.sort()

    %{
      usuario: usuario,
      puntaje: Historial.puntaje_total(lineas, usuario),
      partidas: Historial.partidas_jugadas(lineas, usuario),
      temas: temas
    }
  end

  @doc "Valida el nombre de usuario (no vacío, sin espacios ni separadores, sin prefijo bot_)."
  def validar_usuario(usuario) when is_binary(usuario) do
    cond do
      usuario == "" -> {:error, :usuario_invalido}
      String.contains?(usuario, @caracteres_prohibidos) -> {:error, :usuario_invalido}
      String.starts_with?(usuario, @prefijo_reservado) -> {:error, :usuario_reservado}
      true -> :ok
    end
  end

  def validar_usuario(_), do: {:error, :usuario_invalido}

  # ========== Funciones auxiliares ==========

  defp validar_clave(clave) when is_binary(clave) and clave != "", do: :ok
  defp validar_clave(_), do: {:error, :clave_invalida}

  defp cliente_sin_sesion(estado, cliente) do
    if Map.has_key?(estado.por_cliente, cliente), do: {:error, :cliente_con_sesion}, else: :ok
  end

  defp usuario_sin_sesion(estado, usuario) do
    if Map.has_key?(estado.sesiones, usuario), do: {:error, :sesion_abierta_en_otro_cliente}, else: :ok
  end

  # Usuario existente: la clave debe coincidir. Usuario nuevo: se registra y se guarda.
  defp autenticar(estado, usuario, clave) do
    case Map.fetch(estado.usuarios, usuario) do
      {:ok, ^clave} ->
        {:ok, false, estado}

      {:ok, _otra} ->
        {:error, :clave_incorrecta}

      :error ->
        usuarios = Map.put(estado.usuarios, usuario, clave)

        usuarios
        |> Enum.map(fn {u, c} -> %{"usuario" => u, "clave" => c} end)
        |> Enum.sort_by(& &1["usuario"])
        |> Persistencia.guardar_usuarios()

        Logger.info("Nuevo usuario registrado: #{usuario}")
        {:ok, true, %{estado | usuarios: usuarios}}
    end
  end

  defp cerrar_sesion(estado, usuario, quitar_monitor?) do
    case Map.pop(estado.sesiones, usuario) do
      {nil, _} ->
        estado

      {{cliente, referencia}, sesiones} ->
        if quitar_monitor?, do: Process.demonitor(referencia, [:flush])
        %{estado | sesiones: sesiones, por_cliente: Map.delete(estado.por_cliente, cliente)}
    end
  end
end
