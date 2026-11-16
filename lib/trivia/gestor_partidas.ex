defmodule Trivia.GestorPartidas do
  @moduledoc """
  SERVIDOR: creación y ubicación de partidas, y aviso de reinicio.

  Guarda qué partida tiene cada jugador (`por_usuario`) y el PID actual de cada
  partida (`partidas`). Cuando una partida arranca le reporta su id y su PID; si
  el id ya existía con otro PID, es un reinicio y se le avisa al creador.

  Si este gestor llegara a fallar, el supervisor raíz lo reinicia y en `init/1`
  reconstruye su estado preguntándole a `SupervisorPartidas` qué partidas siguen
  vivas, de modo que ninguna partida en curso queda perdida.
  """
  use GenServer
  require Logger

  alias Trivia.{BancoPreguntas, Historial, Nivel, Partida, Persistencia, SupervisorPartidas}

  # ========== API ==========

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Crea una partida para el usuario y lo deja dentro de ella."
  def crear(usuario, cliente, tema, total, tiempo),
    do: GenServer.call(__MODULE__, {:crear, usuario, cliente, tema, total, tiempo})

  @doc "PID de la partida en la que está el usuario."
  def partida_de(usuario), do: GenServer.call(__MODULE__, {:partida_de, usuario})

  @doc "El usuario abandona su partida (leave_game o disconnect)."
  def abandonar(usuario), do: GenServer.call(__MODULE__, {:abandonar, usuario})

  @doc "El cliente del usuario se cayó: se aplica el abandono si estaba en una partida."
  def jugador_desconectado(usuario), do: GenServer.cast(__MODULE__, {:jugador_desconectado, usuario})

  @doc "Partidas activas: `%{id => %{pid, creador}}`."
  def listar, do: GenServer.call(__MODULE__, :listar)

  @doc "Provoca una falla en una partida para demostrar el reinicio (usar desde el servidor)."
  def simular_falla(id), do: GenServer.call(__MODULE__, {:simular_falla, id})

  # ========== Callbacks ==========

  @impl true
  def init(:ok) do
    partidas = recuperar_partidas()
    if map_size(partidas) > 0, do: Logger.warning("Gestor reiniciado: se recuperaron #{map_size(partidas)} partidas activas")

    {:ok,
     %{
       siguiente: siguiente_numero(partidas),
       partidas: partidas,
       por_usuario: Map.new(partidas, fn {id, datos} -> {datos.creador, id} end)
     }}
  end

  @impl true
  def handle_call({:crear, usuario, cliente, tema, total, tiempo}, _from, estado) do
    with :ok <- libre(estado, usuario),
         {:ok, total} <- validar_numero(total),
         {:ok, tiempo} <- validar_numero(tiempo),
         nivel = Persistencia.consultar_historial(&Nivel.nivel_en_tema(&1, usuario, tema)),
         :ok <- BancoPreguntas.validar(tema, nivel, total) do
      id = "P-#{estado.siguiente}"
      args = %{id: id, creador: usuario, tema: tema, nivel: nivel, total: total, tiempo: tiempo, cliente: cliente}
      {:ok, pid} = SupervisorPartidas.iniciar_partida(args)
      Logger.info("Partida #{id} creada por #{usuario} (#{tema}, #{nivel})")

      nuevo = %{
        estado
        | siguiente: estado.siguiente + 1,
          partidas: Map.put(estado.partidas, id, %{pid: pid, creador: usuario, cliente: cliente}),
          por_usuario: Map.put(estado.por_usuario, usuario, id)
      }

      {:reply, {:ok, %{id: id, nivel: nivel, tema: tema, total: total, tiempo: tiempo}}, nuevo}
    else
      error -> {:reply, error, estado}
    end
  end

  def handle_call({:partida_de, usuario}, _from, estado) do
    {:reply, buscar(estado, usuario), estado}
  end

  def handle_call({:abandonar, usuario}, _from, estado) do
    case buscar(estado, usuario) do
      {:ok, pid} ->
        llamar(fn -> Partida.abandonar(pid) end)
        {:reply, :ok, quitar(estado, Map.get(estado.por_usuario, usuario))}

      error ->
        {:reply, error, estado}
    end
  end

  def handle_call(:listar, _from, estado) do
    {:reply, Map.new(estado.partidas, fn {id, datos} -> {id, Map.take(datos, [:pid, :creador])} end), estado}
  end

  def handle_call({:simular_falla, id}, _from, estado) do
    case Map.fetch(estado.partidas, id) do
      {:ok, %{pid: pid}} -> {:reply, Partida.provocar_falla(pid), estado}
      :error -> {:reply, {:error, :partida_inexistente}, estado}
    end
  end

  @impl true
  def handle_cast({:partida_arrancada, id, pid}, estado) do
    case Map.fetch(estado.partidas, id) do
      {:ok, %{pid: ^pid}} ->
        # Primer arranque: el PID es el mismo que devolvió el supervisor
        {:noreply, estado}

      {:ok, datos} ->
        # El id ya existía con otro PID: la partida se reinició tras una falla
        Logger.warning("La partida #{id} se reinició (nuevo PID #{inspect(pid)})")
        send(datos.cliente, {:trivia, {:partida_reiniciada, id}})
        {:noreply, put_in(estado, [:partidas, id, :pid], pid)}

      :error ->
        {:noreply, estado}
    end
  end

  def handle_cast({:partida_terminada, id}, estado), do: {:noreply, quitar(estado, id)}

  def handle_cast({:jugador_desconectado, usuario}, estado) do
    case buscar(estado, usuario) do
      {:ok, pid} ->
        Logger.info("#{usuario} se desconectó durante la partida; se aplica el abandono")
        llamar(fn -> Partida.abandonar(pid) end)
        {:noreply, quitar(estado, Map.get(estado.por_usuario, usuario))}

      _ ->
        {:noreply, estado}
    end
  end

  # ========== Funciones auxiliares ==========

  # Le pregunta a cada partida viva sus datos para volver a armar la tabla id => partida.
  # En el primer arranque del servidor no hay partidas y devuelve un mapa vacío.
  defp recuperar_partidas do
    SupervisorPartidas.pids_partidas()
    |> Enum.map(fn pid -> {pid, llamar(fn -> Partida.info(pid) end)} end)
    |> Enum.filter(fn {_pid, info} -> is_map(info) and info.estado != :finalizada end)
    |> Map.new(fn {pid, info} -> {info.id, %{pid: pid, creador: info.creador, cliente: info.cliente}} end)
  end

  # Los id continúan desde el último usado: el mayor entre el historial (P-1001, P-1002, ...)
  # y las partidas que siguen activas
  defp siguiente_numero(partidas) do
    del_historial = Persistencia.consultar_historial(&Historial.ultimo_numero_partida/1)

    partidas
    |> Map.keys()
    |> Enum.map(&Historial.numero_partida/1)
    |> Enum.max(fn -> 0 end)
    |> max(del_historial)
    |> Kernel.+(1)
  end

  defp libre(estado, usuario) do
    if Map.has_key?(estado.por_usuario, usuario), do: {:error, :ya_en_partida}, else: :ok
  end

  defp buscar(estado, usuario) do
    with {:ok, id} <- Map.fetch(estado.por_usuario, usuario),
         {:ok, %{pid: pid}} <- Map.fetch(estado.partidas, id) do
      {:ok, pid}
    else
      :error -> {:error, :no_en_partida}
    end
  end

  defp quitar(estado, nil), do: estado

  defp quitar(estado, id) do
    case Map.pop(estado.partidas, id) do
      {nil, _} -> estado
      {datos, partidas} -> %{estado | partidas: partidas, por_usuario: Map.delete(estado.por_usuario, datos.creador)}
    end
  end

  defp validar_numero(valor) do
    case Util.validar_positivo(valor) do
      {:ok, numero} when is_integer(numero) -> {:ok, numero}
      _ -> {:error, :parametros_invalidos}
    end
  end

  # Llama a una partida sin caerse si justo terminó o se está reiniciando
  defp llamar(funcion) do
    funcion.()
  catch
    :exit, _razon -> {:error, :no_en_partida}
  end
end
