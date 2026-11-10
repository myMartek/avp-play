# Walkabout Mini Golf with Spatial Personas (experimental)

A round of Walkabout with friends who are in a FaceTime call with you: the game draws no heads for the other
players, their Spatial Personas stand where those heads would be, and a teleport by the player whose turn it is takes the
whole group along. Locomotion is teleport only while this is on, and snap turning with the stick is off while a
SharePlay session runs: turn with your body. If a Persona turns into a round tile (visionOS does that on a hot
headset), the game shows that player's head again.

This is an experiment. Two runs with two headsets so far; what the second one found is changed in toolchain 861
(see *What changed after the second run*). Please report what you see.

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
teleport: one message to the others, and every other game is moved to the same rig. Only the player whose turn it
is moves the group (the game's own turn, `Ball.myTurn`); a teleport by anyone else is taken back. In the game's
"simultaneous" turn mode everyone may. Each group rig carries a
revision and is applied once (up to three tries, in case the game moves itself back); after that, whatever the game
does is the player's own teleport again. For the same reason snap turning is held at 0° while a session runs (the
profile's snap angle; your own value comes back afterwards): a turn by one player would turn the course under
everybody else.

**Seats are fixed.** The spatial template gives each role (`player1` … `player8`) a seat 0.9 m apart, 1.5 m in front
of the start window, so physical
distances between players are the same in the room and in the game. The participant with the lowest id hands out the
roles and the current group rig and sends them to whoever joins; a stale message never overwrites a newer revision.

The matching runtime change comes with the toolchain archive attached to the test build (not yet on
`myMartek/Klepton`): `runtime/guest/kl_personas.c`,
`visionos/Sources/KleptonPersonas.swift`,
`DEBUG_ENV_VARS.md` › *Walkabout with Spatial Personas*. A toolchain without it builds the game as usual and says so
in the job's log.

## What changed after the second run (toolchain 860/861)

- **The other player's putter was gone.** Walkabout hides another player's putter while their head is within 1.2 m
  of your eyes, and the seats are 0.9 m apart. In a SharePlay build that distance is 0.25 m now.
- **Snap turning was not really off in 859.** It held the wrong value; now it holds the profile's snap angle.
- **Standing inside the start window** when the session started there: the seats are 1.5 m in front of it now.
- **Delay and heat.** The RealityKit picture was four times the pixels the game draws; it is the game's size now.
  On a hot headset the RealityKit output halves its rate until it cools down.
- **Controller buttons after a tap elsewhere.** A finger on a Persona or work in Mac Virtual Display takes the focus,
  and then the buttons stop while tracking goes on. Still open: the attempt in 861–874 (invisible tap walls around
  you) made it worse, because visionOS turned every button press into a tap on those walls and only the start
  button reached the game. Toolchain 875 takes the walls out and tells visionOS that controller buttons belong to
  the game.

## Built on AVP Play 1.10.9 (toolchain 885)

This test build is AVP Play 1.10.9 with the Spatial Personas changes on top: toolchain 885 is release toolchain 876
(Half-Life 2 via SourceVR, the colour fixes for the SourceVR games, and everything of 874: Steam Workshop for
Half-Life: Alyx, Digital Crown and controller recovery, Portal fixes and languages) plus the nine Walkabout commits
of 875. Toolchain 875 was higher by number than 874 but lacked all of it, so Portal refused to build with it and
other games missed the crown fixes.

## What changed after the run of 2026-11-08 (toolchain 886)

- **Personas beside the avatar's hands.** Each headset counts positions from its own starting point, while visionOS
  places Personas in the space SharePlay shares. Each game now measures where its own starting point lies in that
  shared space (from what visionOS reports about you and where the headset is) and puts the group's position there.
  Only the place the group stands on moves; the game's head is never shifted.
- **Starting a level under the map.** The game puts everyone on the first tee by itself, and the turn rule took that
  back for everyone who was not on turn. For a short while after a new course or a new hole, the game's own moves now
  always count.
- **Taking turns.** The turn the game shows (the greyed-out ball is the one not on turn) is what the rule reads; in
  the last run it changed back and forth correctly on the headset that sent its log. Every teleport now says in the
  log whose turn it was.
- **The other player's putter.** The 1.2 m rule was off in both builds, and the putter was still missing. Hiding the
  heads now leaves alone everything that is not at the head, and the log says every ten seconds what the other
  player's putter is doing.

## What the next two-headset run has to settle

- Whether each Persona now stands on its avatar, and whether the level starts on the tee for both.
- Whether the other player's putter shows; if not, the `[personas] other player:` lines say why.
- Whether taking turns feels right; both players' logs show who was on turn at each teleport.
