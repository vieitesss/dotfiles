# NOTES — el mundo del usuario

Materia prima para los workflow specs de `workflows/`. Fuente inicial:
`lo-que-suelo-hacer-en-mi-dia-a-dia.md` + hechos verificados del entorno.
(Pendiente Q1: decidir si este workspace vive aquí o en otro repo.)

## Su día (raw, de su propio documento)

1. Mira el tiempo, siempre en la misma web.
2. Prepara el desayuno.
3. Comprueba el email.
4. Va a un coworking (trabaja remoto); a veces se queda en casa.
5. En el trabajo: comprueba qué tiene que hacer.
6. Siempre varias tareas pendientes → tiene que priorizar para empezar.
7. Trabaja en 2 cosas a la vez como máximo, usando agentes.
8. Workflow de trabajo fijo (skills de `~/work/prefapp/skills/skills/workflow`):
   plan → issue → implement → review.
9. Siempre pi + subagents + esas skills.
10. GitHub constantemente: PRs, issues, actions.
11. Mensajes de compañeros en Google Chat; reuniones en Meet.
12. Problema que intenta resolver con `~/personal/tt`: mantener las tareas
    ordenadas por repositorio.

## Herramientas (verificado)

| Herramienta | Qué es | Acceso |
|---|---|---|
| `tt` (ToTask) | Su app de tareas, en desarrollo activo en `~/personal/tt`. Tareas por **project** (= directorio/repo), store markdown, TUI + CLI | `tt --json`, `tt add/list/...` |
| pi + subagents | Su harness de agentes | local |
| workflow skills | plan → issue → implement → review | `~/work/prefapp/skills/skills/workflow` |
| `gh` | GitHub CLI, autenticado como `vieitesss` | scopes: repo, workflow, admin:org... |
| `gog` | Google CLI (Gmail, Chat, Meet, Calendar, Tasks...) | `gog --json`, keyring local |
| Jev / TypeSafe | modelo System One (juicios tipados: Choice, Noul, Score) | `TYPESAFE_API_KEY` presente |
| Telegram | bridge activo en pi | posible canal de briefs |
| web del tiempo | fuente meteorológica fija | URL pendiente de preguntar |

## Entorno (verificado)

- Host `vieitesrpi`: Raspberry Pi, uptime de días → candidato a host
  siempre activo (schedules, pollers de eventos).
- Trabaja en remoto (coworking o casa) → el portátil no es host fiable
  para daemons; la rpi sí.

## Terminología canónica (a afilar en el grilling)

- **tarea** — ¿task de tt, issue de GitHub, o ambas? (pendiente Q4)
- **priorizar** — proceso manual hoy (pendiente)

## Bucles candidatos detectados (sin priorizar aún)

- **A. Briefing matinal** — tiempo + email + tareas + GitHub + agenda. Trigger: schedule.
- **B. Captura de tareas** — email/chat → tarea en tt. Trigger: evento. (Jev: ¿accionable? ¿qué repo?)
- **C. ¿Qué hago ahora?** — priorización asistida sobre tt. Trigger: bajo demanda. (Jev: Score)
- **D. Vigilancia GitHub** — review requests, CI roto, mentions. Trigger: evento.
- **E. Post-Meet** — reunión → action items en tt. Trigger: evento (fin de reunión).
