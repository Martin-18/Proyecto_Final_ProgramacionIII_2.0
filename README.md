# Trivia Concurrente

Juego de preguntas por consola en Elixir. Un **servidor** guarda todo el juego y cada jugador se conecta desde su propia consola (**cliente**) para jugar contra 2 o 3 bots. Varias partidas pueden jugarse al mismo tiempo.

Proyecto Final de Programación III · Universidad del Quindío

**Integrantes:** Martin Rios Florez · Samuel Calderon Candela 


## Instalación

En la carpeta del proyecto:

```bash
mix deps.get
mix compile
```

## Ejecución

> En **PowerShell** se escribe `iex.bat`; en **CMD**, Linux o macOS, `iex`.

**1. Servidor** (una sola consola, se deja abierta):

```bash
iex.bat --sname servidor -S mix
```

**2. Cliente** (una consola por jugador, cada una con un nombre distinto):

```bash
iex.bat --sname pedro -S mix
```

y dentro de IEx:

```elixir
Trivia.Cliente.iniciar()
```

El nodo llamado `servidor` arranca el servidor; cualquier otro nombre arranca solo un cliente, que se conecta al servidor del mismo equipo al usar `connect`.

## Comandos del juego

| Comando | Para qué sirve |
|---|---|
| `connect <usuario> <clave>` | Entrar (si el usuario no existe, se crea) |
| `create_game tema=ciencia preguntas=5 tiempo=15` | Crear una partida |
| `add_bot facil` / `add_bot dificil` | Agregar un bot (mínimo 2, máximo 4 jugadores) |
| `start_game` | Empezar la partida |
| `answer B` (o solo `B`) | Responder la pregunta |
| `score` / `ranking [tema]` | Ver puntos propios / tabla de mejores jugadores |
| `topics` / `status` | Ver temas disponibles / estado de la partida |
| `leave_game` / `disconnect` / `exit` | Salir de la partida / cerrar sesión / cerrar el cliente |
| `help` | Ver todos los comandos |

Temas: `ciencia`, `historia`, `geografia` y `programacion` (8 preguntas por nivel cada uno).

## Datos

Se guardan en `data/`: `questions.json` (banco de preguntas), `users.json` y `results.log` (se crean solos al registrar jugadores y terminar partidas).
