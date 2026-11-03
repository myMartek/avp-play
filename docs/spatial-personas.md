# Walkabout Mini Golf with Spatial Personas (experimental)

A round of Walkabout with friends who are in a FaceTime call with you: the game draws no heads for the other
players, their Spatial Personas stand where those heads would be, and every teleport in the game moves your Persona
to where your rig lands. Locomotion is teleport only while this is on.

This is an experiment. It has not yet been tried with two headsets; the build exists to find out whether the
Personas stand exactly on the heads. Please report what you see.

## Turning it on

1. On the game's page, under **Spatial Personas (experimental)**, turn on *Build with SharePlay for Spatial
   Personas*, then **Install** or **Update**. The game is built with the Group Activities entitlement (SharePlay)
   and the option switched on. Turning it off and updating builds the game as before; saves stay.
2. Everyone who plays together needs this build **and the same bundle identifier**: SharePlay finds the app on the
   other participants' devices by it. The game's page shows the identifier the build will have; the default prefix
   contains the Mac's user name, so every co-player sets the same bundle prefix under Settings › Advanced. Two
   different Apple teams may register the same identifier; a wildcard App ID is not possible with Group Activities.
3. SharePlay needs a **paid Apple Developer Program** membership on the Mac that builds the game: Apple grants Group
   Activities to paid teams only. With a free team the game is built without it and the job says so.
4. On the headset: start the FaceTime call, open the game's start window, **Settings › Spatial Personas ›
   Start SharePlay** (or accept the friend's SharePlay in the call), then **Start** the game. Everyone joins the same
   Walkabout room as usual.

The start window's panel shows the session: who is in it, each player's role and position, what visionOS reports
as their seat, and a log. Below it, a **test scene** opens a mixed space with a floor grid and three positions
A (0, 0), B (3, 0), C (0, −4) to try teleporting between while the game is not running.

The option can also be switched in the start window (*Play with Spatial Personas*); it takes effect the next time
the game starts. From the command line, `--spatial-personas` on an install or job does what the toggle does.

## How it works

Walkabout's course and the shared space of the SharePlay group are tied by one rigid motion that all participants
agree on. The toolchain measures where your rig stands in the course every frame (the camera's world pose with the
head pose it handed the game taken off), and when that changes and holds still, it is a teleport: one message to the
others and one change of the spatial template, which asks visionOS to put your seat where your rig is. Until the
system moves your seat, the picture stays where it was; then you land on the target, and everybody's heads and
Personas agree. The compositor keeps working in the raw world; only the game's idea of where its tracking origin
stands moves.

Positions come from the game on each device, never from a guess about another player. Each participant owns its
own seat and the revision on it, so a stale message never overwrites a newer position. The participant with the
lowest id hands out the roles (`player1` … `player8`) and the shared origin and sends the whole state to whoever
joins. Nothing moves a Persona directly: visionOS does, from the template.

The matching runtime change is in `myMartek/Klepton`, branch `avp-play` (`runtime/guest/kl_personas.c`,
`visionos/Sources/KleptonPersonas.swift`, the shared-space offset in `runtime/xr/kl_ovrp.c`;
`DEBUG_ENV_VARS.md` › *Walkabout with Spatial Personas*). A toolchain without it builds the game as usual and says so
in the job's log.

## What a two-headset run has to settle

- Whether a Compositor Services space that is already open when the session arrives is re-based into the shared
  space, or whether the game has to be started after SharePlay (the recommended order either way).
- Whether ARKit's device anchor is stated in the shared space once a seat exists (the design assumes it is; the
  panel shows the seat visionOS reports next to the logical one).
- How far a seat may be from the origin before visionOS refuses it: a course is tens of metres across.
- Whether the Persona stands on the head to the centimetre, or whether the game's rig and its camera differ by an
  offset the measurement does not see.
