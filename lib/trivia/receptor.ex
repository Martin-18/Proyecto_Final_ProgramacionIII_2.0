defmodule Trivia.Receptor do
  @moduledoc """
  CLIENTE: recepción de notificaciones de la partida.

  Es un proceso aparte del que lee el teclado, así una pregunta o el cierre de una
  ronda se muestran apenas llegan, aunque el jugador no haya escrito nada.
  Su PID es el que el cliente registra en el servidor y en la partida.

  Está hecho con lo visto en la guía de procesos: un bucle recursivo con `receive`
  que conserva su estado entre un mensaje y otro, mensajes etiquetados con un átomo,
  un nombre registrado con `Process.register/2` y el patrón de petición y respuesta
  (con `after`) para detenerlo.
  """
  alias Trivia.Nivel

  @nombre :trivia_receptor
  @prompt "trivia> "
  @espera_detener 1000

  # ========== API ==========

  @doc "Lanza el receptor enlazado al proceso del cliente y lo registra con un nombre."
  def iniciar do
    pid = spawn_link(fn -> loop(%{servidor: nil}) end)
    Process.register(pid, @nombre)
    pid
  end

  @doc "Indica si ya hay un receptor corriendo en este nodo (un cliente abierto)."
  def activo?, do: Process.whereis(@nombre) != nil

  @doc """
  Texto del prompt del cliente.

  Fuera de IEx empieza con un retorno de carro (`\\r`): si el prompt ya estaba
  escrito en esa línea lo sobrescribe, y así no aparece repetido cuando el cliente
  y el receptor lo escriben casi al mismo tiempo.
  """
  def prompt, do: if(dentro_de_iex?(), do: @prompt, else: "\r" <> @prompt)

  @doc "Le pide al receptor que vigile el nodo del servidor para avisar si se cae."
  def vigilar(receptor, nodo_servidor), do: send(receptor, {:vigilar, nodo_servidor})

  @doc """
  Detiene el receptor con petición y respuesta: le envía el PID de quien pide y
  espera la confirmación, como máximo un segundo.
  """
  def detener(receptor) do
    send(receptor, {:detener, self()})

    receive do
      :receptor_detenido -> :ok
    after
      @espera_detener -> :sin_respuesta
    end
  end

  # ========== Bucle del proceso ==========

  # El estado guarda qué nodo se está vigilando (nil si ninguno)
  defp loop(%{servidor: servidor} = estado) do
    receive do
      # Notificación de la partida
      {:trivia, evento} ->
        evento |> formatear() |> mostrar()
        loop(estado)

      {:vigilar, nodo} ->
        loop(vigilar_nodo(estado, nodo))

      # El operador pin (^) hace que solo coincida con el nodo que se está vigilando
      {:nodedown, ^servidor} ->
        mostrar("\nSe perdió la conexión con el servidor. Cuando vuelva a estar disponible, ejecuta connect de nuevo.")
        loop(%{estado | servidor: nil})

      {:detener, remitente} ->
        send(remitente, :receptor_detenido)
        :ok # No vuelve a llamar a loop, así que el proceso termina

      _otro ->
        loop(estado)
    end
  end

  defp vigilar_nodo(%{servidor: nodo} = estado, nodo), do: estado

  defp vigilar_nodo(estado, nodo) do
    # Si el nodo desaparece, este proceso recibe {:nodedown, nodo}
    Node.monitor(nodo, true)
    %{estado | servidor: nodo}
  end

  # Fuera de IEx la consola no vuelve a dibujar el prompt después de un mensaje
  # que llega de otro proceso, así que se escribe de nuevo para que el jugador
  # sepa que puede seguir escribiendo. Dentro de IEx la consola ya lo hace sola.
  defp mostrar(texto) do
    Util.imprimir_mensaje(texto)
    unless dentro_de_iex?(), do: IO.write(prompt())
  end

  defp dentro_de_iex? do
    Code.ensure_loaded?(IEx) and apply(IEx, :started?, [])
  end

  # ========== Formato de cada notificación ==========

  @doc "Convierte una notificación de la partida en el texto que se muestra."
  def formatear({:inicio, info}) do
    """

    >>> La partida #{info.id} comienza: #{info.total} preguntas de #{info.tema}, #{info.tiempo} s por pregunta.
        Jugadores: #{Enum.join(info.jugadores, ", ")}
    """
  end

  def formatear({:pregunta, p}) do
    """

    ═══ Pregunta #{p.numero} de #{p.total} - #{String.capitalize(p.tema)} - Nivel #{Nivel.texto(p.nivel)} ═══
    #{p.enunciado}
      #{opcion(p.opciones, "A")}#{opcion(p.opciones, "B")}
      #{opcion(p.opciones, "C")}#{opcion(p.opciones, "D")}
    Tiempo: #{p.tiempo} segundos

    Responde con answer <letra> (o escribe solo la letra)
    """
  end

  def formatear({:fin_ronda, r}) do
    filas =
      Enum.map(r.resultados, fn {jugador, puntos, total} ->
        "  #{String.pad_trailing(jugador, 10)}#{String.pad_leading(con_signo(puntos), 4)}   (total #{total})"
      end)

    """

    Respuesta correcta: #{r.correcta}) #{r.texto_correcta}

    #{Enum.join(filas, "\n")}
    """
  end

  def formatear({:fin_partida, f}) do
    filas =
      f.ranking
      |> Enum.with_index(1)
      |> Enum.map(fn {{jugador, puntaje}, posicion} ->
        "#{String.pad_trailing(to_string(posicion), 5)}#{String.pad_trailing(jugador, 10)}#{String.pad_leading(to_string(puntaje), 7)}"
      end)

    aviso = if f.motivo == :abandono, do: "\n(La partida terminó antes por abandono; se registraron los puntajes obtenidos.)", else: ""

    """

    ═══ Fin de la partida #{f.id} (#{f.tema}, nivel #{Nivel.texto(f.nivel)}) ═══#{aviso}
    #    Jugador   Puntaje
    #{Enum.join(filas, "\n")}

    #{ganadores(f.ganadores)}
    Ya puedes crear otra partida.
    """
  end

  def formatear({:partida_cancelada, id}),
    do: "\nLa partida #{id} se canceló porque el creador salió antes de iniciarla."

  def formatear({:partida_reiniciada, id}) do
    "\nLa partida #{id} falló y se reinició sin su progreso. " <>
      "Agrega los bots y ejecuta start_game para jugar de nuevo."
  end

  def formatear(otro), do: "\n[Notificación] #{inspect(otro)}"

  # ========== Auxiliares ==========

  defp opcion(opciones, letra), do: String.pad_trailing("#{letra}) #{opciones[letra]}", 34)

  defp con_signo(puntos) when puntos > 0, do: "+#{puntos}"
  defp con_signo(puntos), do: to_string(puntos)

  defp ganadores([unico]), do: "Ganador: #{unico}"
  defp ganadores(varios), do: "Ganadores (empate): #{Enum.join(varios, ", ")}"
end
