defmodule Trivia.Cliente do
  @moduledoc """
  CLIENTE: consola del jugador.

  No tiene lógica de juego. Su trabajo se divide en tres pasos:

  1. `interpretar/1` convierte lo que escribió el jugador en un comando (función pura).
  2. `pedir/2` arma la petición para `{Trivia.Servidor, nodo_servidor}` y espera la respuesta.
  3. `presentar/3` muestra la respuesta en pantalla.

  Las notificaciones de la partida las muestra `Trivia.Receptor`, que corre en
  otro proceso para no quedar bloqueado mientras se espera el teclado.

  Uso (en otra consola, con el servidor ya corriendo):

      iex --sname pedro -S mix        (en PowerShell: iex.bat --sname pedro -S mix)
      iex> Trivia.Cliente.iniciar()
  """
  alias Trivia.{Errores, Nivel, Receptor}

  @timeout 10_000

  # ========== Inicio ==========

  @doc "Abre la consola del jugador."
  def iniciar(nodo_servidor \\ nil) do
    cond do
      not Node.alive?() ->
        mostrar_error(:nodo_no_distribuido)

      Receptor.activo?() ->
        mostrar_error(:cliente_ya_abierto)

      true ->
        servidor = nodo_servidor || nodo_servidor_por_defecto()
        receptor = Receptor.iniciar()
        Util.imprimir_mensaje(bienvenida(servidor))
        loop(%{servidor: servidor, receptor: receptor, usuario: nil})
    end
  end

  # El servidor corre en el mismo equipo con el nombre "servidor".
  # Se puede cambiar con la variable de entorno TRIVIA_SERVIDOR (por ejemplo servidor@OTRO_PC).
  defp nodo_servidor_por_defecto do
    case System.get_env("TRIVIA_SERVIDOR") do
      nil ->
        [_nombre, equipo] = node() |> Atom.to_string() |> String.split("@")
        String.to_atom("servidor@" <> equipo)

      nodo ->
        String.to_atom(nodo)
    end
  end

  # Bucle recursivo: lee un comando, lo atiende y vuelve a esperar el siguiente
  defp loop(estado) do
    case Util.leer_linea(Receptor.prompt()) do
      # La consola se cerró: se sale como con exit
      :fin -> salir(estado)
      {:ok, linea} -> atender(estado, interpretar_linea(linea))
    end
  end

  defp atender(estado, :vacio), do: loop(estado)
  defp atender(estado, {:ok, :exit}), do: salir(estado)
  defp atender(estado, {:ok, comando}), do: estado |> ejecutar(comando) |> loop()

  defp atender(estado, {:error, motivo}) do
    mostrar_error(motivo)
    loop(estado)
  end

  defp salir(estado) do
    if estado.usuario, do: pedir(estado, :disconnect)
    Receptor.detener(estado.receptor)
    Util.imprimir_mensaje("Hasta pronto.")
  end

  # ========== 1. Interpretar lo que escribe el jugador (funciones puras) ==========

  @doc """
  Interpreta una línea completa. El nombre del comando no distingue mayúsculas.
  Devuelve `:vacio`, `{:ok, comando}` o `{:error, motivo}`.
  """
  def interpretar_linea(linea) do
    case String.split(linea) do
      [] -> :vacio
      [nombre | argumentos] -> interpretar([String.downcase(nombre) | argumentos])
    end
  end

  @doc """
  Convierte la lista de palabras en un comando.

      iex> Trivia.Cliente.interpretar(["connect", "pedro", "1234"])
      {:ok, {:connect, "pedro", "1234"}}
      iex> Trivia.Cliente.interpretar(["answer"])
      {:error, :uso_answer}
  """
  def interpretar(["connect", usuario, clave]), do: {:ok, {:connect, usuario, clave}}
  def interpretar(["connect" | _]), do: {:error, :uso_connect}
  def interpretar(["disconnect"]), do: {:ok, :disconnect}
  def interpretar(["score"]), do: {:ok, :score}
  def interpretar(["ranking"]), do: {:ok, {:ranking, nil}}
  def interpretar(["ranking", tema]), do: {:ok, {:ranking, String.downcase(tema)}}
  def interpretar(["topics"]), do: {:ok, :topics}
  def interpretar(["status"]), do: {:ok, :status}

  def interpretar(["create_game" | parametros]) do
    with {:ok, tema, preguntas, tiempo} <- leer_parametros(parametros) do
      {:ok, {:create_game, tema, preguntas, tiempo}}
    end
  end

  def interpretar(["add_bot", dificultad]), do: {:ok, {:add_bot, String.downcase(dificultad)}}
  def interpretar(["add_bot" | _]), do: {:error, :uso_add_bot}
  def interpretar(["start_game"]), do: {:ok, :start_game}
  def interpretar(["leave_game"]), do: {:ok, :leave_game}
  def interpretar(["answer", letra]), do: {:ok, {:answer, letra}}
  def interpretar(["answer" | _]), do: {:error, :uso_answer}
  def interpretar(["help"]), do: {:ok, :help}
  def interpretar([salir]) when salir in ["exit", "salir"], do: {:ok, :exit}
  # Atajo: escribir solo la letra equivale a answer <letra>
  def interpretar([letra]) when byte_size(letra) == 1, do: {:ok, {:answer, letra}}
  def interpretar(_desconocido), do: {:error, :comando_desconocido}

  # tema=<tema> preguntas=<n> tiempo=<segundos>, en cualquier orden
  defp leer_parametros(parametros) do
    valores =
      parametros
      |> Enum.map(&String.split(&1, "=", parts: 2))
      |> Enum.filter(&match?([_clave, _valor], &1))
      |> Map.new(fn [clave, valor] -> {String.downcase(clave), valor} end)

    with {:ok, tema} <- Map.fetch(valores, "tema"),
         {preguntas, ""} <- Integer.parse(Map.get(valores, "preguntas", "")),
         {tiempo, ""} <- Integer.parse(Map.get(valores, "tiempo", "")) do
      {:ok, String.downcase(tema), preguntas, tiempo}
    else
      _ -> {:error, :parametros_invalidos}
    end
  end

  # ========== 2. Enviar la petición al servidor ==========

  defp ejecutar(estado, :help) do
    Util.imprimir_mensaje(ayuda())
    estado
  end

  # Para conectarse, primero se enlaza este nodo con el del servidor
  defp ejecutar(estado, {:connect, _usuario, _clave} = comando) do
    if Node.connect(estado.servidor) do
      presentar(comando, pedir(estado, comando), estado)
    else
      presentar(comando, {:error, :servidor_no_disponible}, estado)
    end
  end

  defp ejecutar(estado, comando), do: presentar(comando, pedir(estado, comando), estado)

  # Envía la petición y espera la respuesta. El servidor se ubica por su nombre
  # registrado y el nodo donde corre, sin conocer su PID.
  defp pedir(estado, comando) do
    GenServer.call({Trivia.Servidor, estado.servidor}, peticion(comando, estado.receptor), @timeout)
  catch
    :exit, _razon -> {:error, :servidor_no_disponible}
  end

  # Toda petición lleva el PID del receptor: así el servidor sabe qué jugador la
  # hace y a dónde debe enviar la partida sus notificaciones
  defp peticion({:connect, usuario, clave}, receptor), do: {:connect, usuario, clave, receptor}
  defp peticion({:ranking, tema}, receptor), do: {:ranking, receptor, tema}
  defp peticion({:create_game, tema, preguntas, tiempo}, receptor), do: {:create_game, receptor, tema, preguntas, tiempo}
  defp peticion({:add_bot, dificultad}, receptor), do: {:add_bot, receptor, dificultad}
  defp peticion({:answer, letra}, receptor), do: {:answer, receptor, letra}
  defp peticion(comando, receptor) when is_atom(comando), do: {comando, receptor}

  # ========== 3. Presentar la respuesta ==========

  defp presentar({:connect, _, _}, {:ok, %{usuario: usuario, nuevo: nuevo}}, estado) do
    # Desde ahora el receptor avisa si el servidor se cae
    Receptor.vigilar(estado.receptor, estado.servidor)
    registro = if nuevo, do: " (usuario nuevo registrado)", else: ""
    Util.imprimir_mensaje("Bienvenido, #{usuario}#{registro}. Escribe help para ver los comandos.")
    %{estado | usuario: usuario}
  end

  defp presentar(:disconnect, {:ok, usuario}, estado) do
    Util.imprimir_mensaje("Sesión de #{usuario} cerrada.")
    %{estado | usuario: nil}
  end

  defp presentar(:score, {:ok, score}, estado), do: decir(estado, formatear_score(score))
  defp presentar({:ranking, _tema}, {:ok, ranking}, estado), do: decir(estado, formatear_ranking(ranking))
  defp presentar(:topics, {:ok, temas}, estado), do: decir(estado, formatear_temas(temas))
  defp presentar(:status, {:ok, partida}, estado), do: decir(estado, formatear_partida(partida))

  defp presentar({:create_game, _, _, _}, {:ok, p}, estado) do
    decir(estado, """
    Partida #{p.id} creada: #{p.tema}, #{p.total} preguntas, #{p.tiempo} s por pregunta.
    Tu nivel en #{p.tema}: #{Nivel.texto(p.nivel)}.
    Agrega al menos dos bots con: add_bot facil | add_bot dificil
    """)
  end

  defp presentar({:add_bot, _}, {:ok, b}, estado),
    do: decir(estado, "Se agregó #{b.bot} (#{b.dificultad}). Jugadores: #{b.jugadores}/4")

  # La partida avisa el inicio con una notificación, aquí no hay nada que mostrar
  defp presentar(:start_game, :ok, estado), do: estado
  defp presentar(:leave_game, :ok, estado), do: decir(estado, "Saliste de la partida.")

  defp presentar({:answer, _}, {:ok, %{letra: letra, segundos: segundos}}, estado),
    do: decir(estado, "Respuesta #{letra} registrada a los #{Util.formatear_decimal(segundos, 1)} s.")

  defp presentar(_comando, {:error, motivo}, estado) do
    mostrar_error(motivo)
    estado
  end

  defp presentar(_comando, otra, estado), do: decir(estado, inspect(otra))

  defp decir(estado, texto) do
    Util.imprimir_mensaje(texto)
    estado
  end

  defp mostrar_error(motivo), do: Util.imprimir_error("Error: " <> Errores.mensaje(motivo))

  # ========== Formato de las tablas ==========

  @doc false
  def formatear_score(s) do
    filas =
      Enum.map(s.temas, fn {tema, puntaje, nivel} ->
        "#{String.pad_trailing(tema, 14)}#{String.pad_leading(to_string(puntaje), 7)}   #{nivel}"
      end)

    detalle = if filas == [], do: "Todavía no has jugado ninguna partida.", else: Enum.join(filas, "\n")

    """
    === #{s.usuario} ===
    Puntaje acumulado: #{s.puntaje}
    Partidas jugadas: #{s.partidas}

    Tema          Puntaje   Nivel
    #{detalle}
    """
  end

  @doc false
  def formatear_ranking(%{tema: tema, filas: filas}) do
    titulo = if tema, do: "=== Ranking de #{tema} ===", else: "=== Ranking global ==="

    cuerpo =
      filas
      |> Enum.with_index(1)
      |> Enum.map(fn {{jugador, puntaje, partidas}, posicion} ->
        String.pad_trailing(to_string(posicion), 5) <>
          String.pad_trailing(jugador, 12) <>
          String.pad_leading(to_string(puntaje), 7) <>
          String.pad_leading(to_string(partidas), 11)
      end)

    detalle = if cuerpo == [], do: "Todavía no hay partidas registradas.", else: Enum.join(cuerpo, "\n")

    """
    #{titulo}
    #    Jugador     Puntaje    Partidas
    #{detalle}
    """
  end

  @doc false
  def formatear_temas(temas) do
    filas =
      Enum.map(temas, fn {tema, cantidades} ->
        String.pad_trailing(tema, 14) <>
          String.pad_leading(to_string(cantidades.basico), 8) <>
          String.pad_leading(to_string(cantidades.intermedio), 13) <>
          String.pad_leading(to_string(cantidades.avanzado), 11)
      end)

    """
    === Temas disponibles (preguntas por nivel) ===
    Tema            Básico   Intermedio   Avanzado
    #{Enum.join(filas, "\n")}
    """
  end

  @doc false
  def formatear_partida(p) do
    filas =
      p.jugadores
      |> Enum.map(fn jugador ->
        "#{String.pad_trailing(jugador, 12)}#{String.pad_leading(to_string(Map.get(p.puntajes, jugador, 0)), 7)}"
      end)

    """
    === Partida #{p.id} ===
    Tema: #{p.tema}   Nivel: #{Nivel.texto(p.nivel)}   Estado: #{texto_estado(p.estado)}
    Pregunta: #{p.pregunta_actual} de #{p.total}   Tiempo por pregunta: #{p.tiempo} s

    Jugador     Puntaje
    #{Enum.join(filas, "\n")}
    """
  end

  defp texto_estado(:esperando), do: "esperando (agrega bots y ejecuta start_game)"
  defp texto_estado(:en_curso), do: "en curso"
  defp texto_estado(otro), do: to_string(otro)

  defp bienvenida(servidor) do
    """

    ===============================================
      Trivia Concurrente - Cliente
      Nodo: #{node()}   Servidor: #{servidor}
    ===============================================
    Escribe help para ver los comandos.
    """
  end

  defp ayuda do
    """
    Comandos disponibles:
      connect <usuario> <clave>      Inicia sesión (si no existe, registra al usuario)
      disconnect                     Cierra la sesión
      score                          Tu puntaje, partidas jugadas y nivel por tema
      ranking [tema]                 Ranking histórico global o de un tema
      topics                         Temas disponibles y cuántas preguntas tiene cada nivel
      create_game tema=<t> preguntas=<n> tiempo=<s>
                                     Crea una partida (ejemplo: tema=ciencia preguntas=5 tiempo=15)
      add_bot <facil|dificil>        Agrega un jugador automático
      start_game                     Inicia la partida (requiere al menos 2 bots)
      answer <A|B|C|D>               Responde la pregunta actual (también sirve escribir solo la letra)
      status                         Estado de tu partida: ronda actual y puntajes
      leave_game                     Abandona la partida
      help                           Muestra esta ayuda
      exit                           Sale del cliente
    """
  end
end
