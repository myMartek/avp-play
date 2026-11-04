# Walkabout Mini Golf with Spatial Personas (experimental)

A round of Walkabout with friends who are in a FaceTime call with you: the game draws no heads for the other
players, their Spatial Personas stand where those heads would be, and a teleport by any player takes the whole group
along. Locomotion is teleport only while this is on, and snap turning with the stick is off while a SharePlay session
runs: turn with your body.

This is an experiment. The first run with two headsets showed no Personas (see below why) and teleports that sprang
back; both are changed since toolchain 859, and it has not been tried with two headsets again. Please report what
you see.

## Turning it on

1. On the game's page, under **Spatial Personas (experimental)**, turn on *Build with SharePlay for Spatial
   Personas*, then **Install** or **Update**. The game is built with the Group Activities entitlement (SharePlay)
   and the option switched on. Turning it off and updating builds the game as before; saves stay.
2. Everyone who plays together needs this build **and the same bundle identifier** – easiest through **Friends**
   ([docs/friends.md](friends.md)): one paid team builds the game once for everybody and hands it over. Otherwise:: SharePlay finds the app on the
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

**The picture goes through RealityKit.** visionOS does not show Spatial Personas while an app draws through a
Compositor Services layer, which is how Klepton normally presents a game. In this mode the toolchain hands the
finished picture to RealityKit instead. The game still renders as before, with its own foveated rendering; only the
last step changes, and it costs some performance.

**Everyone stands on one rig.** A Persona stands where that player is in the shared space; the game draws another
player's head at their rig plus their head. Both agree only when all players stand on the same rig. So the group
shares one: the toolchain measures where your rig stands in the course every frame (the camera's world pose with the
head pose it handed the game taken off). When it moves by more than half a metre or 10° and holds still, that is your
teleport: one message to the others, and every other game is moved to the same rig. Each group rig carries a
revision and is applied once (up to three tries, in case the game moves itself back); after that, whatever the game
does is the player's own teleport again. For the same reason snap turning is held at 0° while a session runs: a turn
by one player would turn the course under everybody else.

**Seats are fixed.** The spatial template gives each role (`player1` … `player8`) a seat 0.9 m apart, so physical
distances between players are the same in the room and in the game. The participant with the lowest id hands out the
roles and the current group rig and sends them to whoever joins; a stale message never overwrites a newer revision.

The matching runtime change comes with the toolchain archive attached to the test build (not yet on
`myMartek/Klepton`): `runtime/guest/kl_personas.c`,
`visionos/Sources/KleptonPersonas.swift`,
`DEBUG_ENV_VARS.md` › *Walkabout with Spatial Personas*. A toolchain without it builds the game as usual and says so
in the job's log.

## What the next two-headset run has to settle

- Whether the Personas appear at all with the picture in RealityKit (the panel should say *spatial* in a call).
- Whether a teleport takes the other player along every time, and whether Walkabout keeps the rig it was moved to.
- Whether the Persona stands on the head to the centimetre, or whether the game's rig and its camera differ by an
  offset the measurement does not see.
- How much frame rate the RealityKit presentation costs on a busy course.
