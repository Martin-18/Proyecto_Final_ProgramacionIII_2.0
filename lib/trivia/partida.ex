defmodule Trivia.Partida do
  @moduledoc """
  SERVIDOR: GenServer de una partida.

  Cada partida vive en su propio proceso, supervisado por `Trivia.SupervisorPartidas`
  con `restart: :transient`: si falla se reinicia desde cero (estado esperando, solo
  con el creador) y si termina bien no se reinicia.

  La partida entrega sus notificaciones con `send/2` a los PID registrados, sin
  distinguir si son del cliente (otro nodo) o de un bot (este nodo). Todas tienen
  la forma `{:trivia, evento}`.
  """
  use GenServer, restart: :transient
  require Logger

  alias Trivia.{BancoPreguntas, Bot, Historial, Persistencia, Ronda}

  @min_jugadores 3
  @max_jugadores 4
  @pausa_entre_rondas 3000

  # ========== API ==========

  @doc """
  Inicia la partida. `args` es un mapa con id, creador, tema, nivel, total
  (número de preguntas), tiempo (segundos) y cliente (PID que recibe las notificaciones).
  """
  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  def agregar_bot(partida, dificultad), do: GenServer.call(partida, {:agregar_bot, dificultad})
  def iniciar(partida), do: GenServer.call(partida, :iniciar)
  def responder(partida, jugador, letra), do: GenServer.call(partida, {:responder, jugador, letra})
  def abandonar(partida), do: GenServer.call(partida, :abandonar)
  def info(partida), do: GenServer.call(partida, :info)

  @doc "Provoca una falla a propósito (para demostrar el reinicio en la sustentación)."
  def provocar_falla(partida), do: GenServer.cast(partida, :fallar)

  # ========== Callbacks ==========

  @impl true
  def init(args) do
    # Se reporta con cast: el gestor está esperando a que el supervisor termine de
    # arrancar esta partida, así que un call desde aquí lo dejaría bloqueado.
    GenServer.cast(Trivia.GestorPartidas, {:partida_arrancada, args.id, self()})

    estado = %{
      id: args.id,
      creador: args.creador,
      tema: args.tema,
      nivel: args.nivel,
      total: args.total,
      tiempo: args.tiempo,
      estado: :esperando,
      jugadores: [%{nombre: args.creador, pid: args.cliente, tipo: :humano}],
      puntajes: %{args.creador => 0},
      preguntas: [],
      pregunta_actual: 0,
      ronda: nil,
      temporizador: nil
    }

    {:ok, estado}
  end

  @impl true
  def handle_call({:agregar_bot, dificultad}, _from, estado) do
    with :ok <- validar_agregar_bot(estado) do
      nombre = "bot_#{cantidad_bots(estado) + 1}"
      # start_link desde la partida: el bot queda enlazado y muere con ella
      {:ok, pid} = Bot.start_link(self(), nombre, dificultad)

      nuevo = %{
        estado
        | jugadores: estado.jugadores ++ [%{nombre: nombre, pid: pid, tipo: :bot}],
          puntajes: Map.put(estado.puntajes, nombre, 0)
      }

      {:reply, {:ok, %{bot: nombre, dificultad: dificultad, jugadores: length(nuevo.jugadores)}}, nuevo}
    else
      error -> {:reply, error, estado}
    end
  end

  def handle_call(:iniciar, _from, estado) do
    with :ok <- validar_inicio(estado),
         {:ok, preguntas} <- BancoPreguntas.sortear(estado.tema, estado.nivel, estado.total) do
      nuevo = %{estado | estado: :en_curso, preguntas: preguntas}

      notificar(nuevo, {:inicio, %{id: nuevo.id, tema: nuevo.tema, total: nuevo.total,
                                   tiempo: nuevo.tiempo, jugadores: nombres(nuevo)}})

      send(self(), :siguiente_ronda)
      {:reply, :ok, nuevo}
    else
      error -> {:reply, error, estado}
    end
  end

  def handle_call({:responder, jugador, letra}, _from, estado) do
    if jugador in nombres(estado) do
      case Ronda.registrar(estado.ronda, jugador, letra, ahora()) do
        {:ok, ronda} ->
          # Si ya respondieron todos, la ronda se cierra sin esperar el temporizador
          if Ronda.todos_respondieron?(ronda, nombres(estado)), do: send(self(), {:fin_ronda, ronda.numero})
          {letra_valida, instante} = Map.fetch!(ronda.respuestas, jugador)
          segundos = Float.round((instante - ronda.inicio_ms) / 1000, 1)
          {:reply, {:ok, %{letra: letra_valida, segundos: segundos}}, %{estado | ronda: ronda}}

        error ->
          {:reply, error, estado}
      end
    else
      {:reply, {:error, :no_en_partida}, estado}
    end
  end

  def handle_call(:abandonar, _from, %{estado: :esperando} = estado) do
    # El creador sale antes de iniciar: la partida se cancela sin registrar nada
    GenServer.cast(Trivia.GestorPartidas, {:partida_terminada, estado.id})
    notificar(estado, {:partida_cancelada, estado.id})
    terminar_bots(estado)
    {:stop, :normal, :ok, %{estado | estado: :finalizada}}
  end

  def handle_call(:abandonar, _from, estado) do
    # Abandono con la partida en curso: termina ya y se registra lo obtenido hasta ahora
    {:stop, :normal, :ok, finalizar(estado, :abandono)}
  end

  def handle_call(:info, _from, estado) do
    resumen = Map.take(estado, [:id, :creador, :tema, :nivel, :total, :tiempo, :estado, :pregunta_actual, :puntajes])
    [%{pid: cliente} | _bots] = estado.jugadores
    {:reply, Map.merge(resumen, %{jugadores: nombres(estado), cliente: cliente}), estado}
  end

  @impl true
  def handle_cast(:fallar, _estado), do: raise("Falla simulada en la partida")

  @impl true
  def handle_info(:siguiente_ronda, %{estado: :en_curso} = estado) do
    if estado.pregunta_actual >= estado.total do
      {:stop, :normal, finalizar(estado, :completa)}
    else
      {:noreply, abrir_ronda(estado)}
    end
  end

  # Cierre por temporizador o porque todos respondieron. El número evita cerrar
  # dos veces la misma ronda o una ronda distinta a la que programó el mensaje.
  def handle_info({:fin_ronda, numero}, %{ronda: %Ronda{numero: numero}} = estado) do
    {:noreply, cerrar_ronda(estado)}
  end

  def handle_info(_mensaje, estado), do: {:noreply, estado}

  # ========== Reglas de armado (funciones puras) ==========

  @doc "Verifica si se puede agregar un bot a la partida."
  def validar_agregar_bot(%{estado: estado}) when estado != :esperando, do: {:error, :partida_iniciada}
  def validar_agregar_bot(%{jugadores: jugadores}) when length(jugadores) >= @max_jugadores, do: {:error, :partida_llena}
  def validar_agregar_bot(_estado), do: :ok

  @doc "Verifica si la partida se puede iniciar (creador + al menos dos bots)."
  def validar_inicio(%{estado: estado}) when estado != :esperando, do: {:error, :partida_iniciada}
  def validar_inicio(%{jugadores: jugadores}) when length(jugadores) < @min_jugadores, do: {:error, :bots_insuficientes}
  def validar_inicio(_estado), do: :ok

  # ========== Funciones auxiliares ==========

  defp abrir_ronda(estado) do
    numero = estado.pregunta_actual + 1
    pregunta = Enum.at(estado.preguntas, numero - 1)

    publica = %{
      numero: numero,
      total: estado.total,
      tema: estado.tema,
      nivel: pregunta.nivel,
      enunciado: pregunta.enunciado,
      opciones: pregunta.opciones,
      tiempo: estado.tiempo
    }

    # La respuesta correcta solo viaja a los bots, que viven en el servidor
    privada = %{nivel: pregunta.nivel, respuesta: pregunta.respuesta}

    Enum.each(estado.jugadores, fn
      %{tipo: :bot, pid: pid} -> send(pid, {:trivia, {:pregunta, publica, privada}})
      %{tipo: :humano, pid: pid} -> send(pid, {:trivia, {:pregunta, publica}})
    end)

    temporizador = Process.send_after(self(), {:fin_ronda, numero}, estado.tiempo * 1000)
    %{estado | pregunta_actual: numero, ronda: Ronda.nueva(numero, pregunta, ahora()), temporizador: temporizador}
  end

  defp cerrar_ronda(estado) do
    cancelar_temporizador(estado.temporizador)
    ronda = estado.ronda
    resultados = Ronda.resultados(ronda, nombres(estado), estado.tiempo)

    puntajes =
      Enum.reduce(resultados, estado.puntajes, fn {jugador, puntos}, acumulado ->
        Map.update!(acumulado, jugador, &(&1 + puntos))
      end)

    detalle = Enum.map(resultados, fn {jugador, puntos} -> {jugador, puntos, Map.fetch!(puntajes, jugador)} end)
    letra = ronda.pregunta.respuesta

    notificar(estado, {:fin_ronda, %{numero: ronda.numero, correcta: letra,
                                     texto_correcta: ronda.pregunta.opciones[letra], resultados: detalle}})

    # Pausa entre rondas: no hay ronda abierta, una respuesta tardía se rechaza
    Process.send_after(self(), :siguiente_ronda, pausa_entre_rondas())
    %{estado | puntajes: puntajes, ronda: nil, temporizador: nil}
  end

  # Muestra el ranking, persiste el resultado y libera al jugador
  defp finalizar(estado, motivo) do
    cancelar_temporizador(estado.temporizador)

    ranking = Enum.sort_by(estado.puntajes, fn {jugador, puntaje} -> {-puntaje, jugador} end)
    {ganadores, _maximo} = Util.maximos_en(estado.puntajes)

    # 1. Primero se guarda el resultado, así score y ranking ya lo ven cuando llegue el anuncio
    linea = Historial.linea(fecha_actual(), estado.id, estado.tema, estado.nivel, ganadores, ranking)

    case Persistencia.registrar_resultado(linea) do
      :ok -> :ok
      {:error, razon} -> Logger.error("No se pudo guardar el resultado de #{estado.id}: #{inspect(razon)}")
    end

    # 2. Después se libera al jugador en el gestor, para que pueda crear otra partida
    #    apenas vea el anuncio (el gestor atiende sus mensajes en orden de llegada)
    GenServer.cast(Trivia.GestorPartidas, {:partida_terminada, estado.id})

    # 3. Por último se anuncia el ranking a todos los jugadores
    notificar(estado, {:fin_partida, %{id: estado.id, tema: estado.tema, nivel: estado.nivel,
                                       ranking: ranking, ganadores: ganadores, motivo: motivo}})

    terminar_bots(estado)
    %{estado | estado: :finalizada, ronda: nil, temporizador: nil}
  end

  defp notificar(estado, evento) do
    Enum.each(estado.jugadores, fn %{pid: pid} -> send(pid, {:trivia, evento}) end)
  end

  defp terminar_bots(estado) do
    estado.jugadores
    |> Enum.filter(&(&1.tipo == :bot))
    |> Enum.each(fn %{pid: pid} -> send(pid, :terminar) end)
  end

  defp nombres(estado), do: Enum.map(estado.jugadores, & &1.nombre)
  defp cantidad_bots(estado), do: Enum.count(estado.jugadores, &(&1.tipo == :bot))

  defp cancelar_temporizador(nil), do: :ok
  defp cancelar_temporizador(referencia), do: Process.cancel_timer(referencia)

  defp ahora, do: System.monotonic_time(:millisecond)

  # 3 segundos según el enunciado; las pruebas la acortan con la configuración
  defp pausa_entre_rondas, do: Application.get_env(:proyecto_trivia, :pausa_entre_rondas, @pausa_entre_rondas)

  defp fecha_actual do
    NaiveDateTime.local_now()
    |> NaiveDateTime.truncate(:second)
    |> NaiveDateTime.to_string()
  end
end
