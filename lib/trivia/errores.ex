defmodule Trivia.Errores do
  @moduledoc """
  COMPARTIDO (servidor y cliente): errores propios del juego.

  El servidor siempre responde `{:error, motivo}` con alguno de los átomos de
  este módulo, y el cliente usa `mensaje/1` para mostrarlo al jugador.
  Este módulo solo traduce átomos a texto, no tiene lógica de juego.
  """

  @mensajes %{
    # Sesión
    sin_sesion: "Primero debes iniciar sesión con: connect <usuario> <clave>",
    clave_incorrecta: "La clave no coincide con la del usuario registrado.",
    sesion_abierta_en_otro_cliente: "Ese usuario ya tiene una sesión abierta en otro cliente.",
    usuario_reservado: "Los usuarios que empiezan por bot_ están reservados para los bots.",
    usuario_invalido: "El usuario no puede estar vacío ni tener espacios o los signos ; = , |",
    clave_invalida: "La clave no puede estar vacía.",
    cliente_con_sesion: "Este cliente ya tiene una sesión abierta. Usa disconnect primero.",
    servidor_no_disponible: "El servidor no está disponible. Verifica que esté corriendo.",
    nodo_no_distribuido: "Este cliente no tiene nombre de nodo. Ábrelo con: iex --sname <nombre> -S mix",

    # Partidas
    ya_en_partida: "Ya estás en una partida. Usa leave_game para salir de ella.",
    tema_inexistente: "Ese tema no existe en el banco de preguntas.",
    preguntas_insuficientes: "El tema no tiene suficientes preguntas de algún nivel para esa cantidad.",
    parametros_invalidos: "Uso: create_game tema=<tema> preguntas=<n> tiempo=<segundos> (números mayores que 0)",
    no_en_partida: "No estás en ninguna partida.",
    partida_llena: "La partida ya tiene 4 jugadores, no se pueden agregar más bots.",
    partida_iniciada: "La partida ya está en curso.",
    bots_insuficientes: "Se necesitan al menos dos bots para iniciar la partida.",
    dificultad_invalida: "La dificultad del bot debe ser facil o dificil.",

    # Respuestas
    letra_invalida: "La respuesta debe ser A, B, C o D. Tu respuesta no se consumió.",
    sin_ronda_abierta: "No hay una ronda abierta en este momento. La respuesta se rechazó.",
    ya_respondio: "Ya respondiste esta pregunta. Solo cuenta tu primera respuesta.",

    # Comandos mal escritos
    uso_connect: "Uso: connect <usuario> <clave>",
    uso_add_bot: "Uso: add_bot <facil|dificil>",
    uso_answer: "Uso: answer <A|B|C|D>",

    # Genéricos
    comando_desconocido: "Comando desconocido. Escribe help para ver los comandos.",
    error_interno: "El servidor no pudo procesar la petición. Intenta de nuevo.",
    cliente_ya_abierto: "Ya hay un cliente abierto en esta consola."
  }

  @doc "Devuelve el texto que se le muestra al jugador para un motivo de error."
  def mensaje(motivo) when is_map_key(@mensajes, motivo), do: Map.get(@mensajes, motivo)
  def mensaje(motivo), do: "Error inesperado: #{inspect(motivo)}"

  @doc "Lista de todos los errores propios definidos."
  def motivos, do: Map.keys(@mensajes)
end
