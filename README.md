# RobloxRollback
This is an experimental system for fighting game style rollback netcode.
All contributions are welcome! Feel free to contact for questions, as this doc is incomplete.

## Usage
Server and Client must start ServerRunner and ClientRunner.
Provide a table with arguments into each. Requires Config. InputSerDes optional.
You must require the scheduler, initialize it with the Runner, then execute.
i.e.
```
local Runner = {Config = ..., frameRender, postSimRender, simRender, simulate}
ClientScheduler.init(Runner)
ClientScheduler.start(1)
```

simulate controls the world state logic. This is saved, and the basis for rollback.
- frameRender is called after each Heartbeat and that will depend on the scheduler. Use this for parametric functions- e.g. animations.
- simPostRender is called after every simulation step (post rollback corrections). It is always called every frame, so it is potentially expensive.
- simRender is called even after a rollback reprediction. It is also called before simPostRender.

### Config mandatory parameters
- .maxPingMs = 200 --Maximum before inputs are ignored
- .minPingMs = 10 --Minimum lag applied
- .maxPlayers = 4
- .playerInputTemplate = { --What drives the sync. Must be serializable data types. No CFrames (yet)
	Move = Vector3.zero,
}
- .reliableBufferSize = 4 --Batch of reliable inputs. Input and player count may affect this.
- .tickRate = 1/60 --For 60fps
- .fullGameBufferSize = 64000 --How many frames can exist in a single game. Hopefully deprecated.

## Key points
- Inputs are synced and predicted, world state is not
- Client > Server > Client model requires many more prediction frames.
	- The slowest player could affect quality for all players.

## Bugs
- High desync potential. Needs work
- Edge cases if players disconnect and reconnect
- Resyncs on client dropped frames does not work

## TODO
- Code is messy, needs improvement
- Better way of determining prediction frame count than roblox ping detection.
- Checkpointing implementation as deepcopy is expensive
	- Potentially with asynchronous checkpointing
- Instanced servers
	- With each on an Actor thread
- Correctly maintain buffer size on server, as right now it saves entire world state for every frame
- Easier way of determining if players are syncing
- Live implementation demonstrating key concerns
	- Instance/particle spawning
- Connection quality kick options 
	- Too low FPS will keep us too far behind all the time
- Spectators i.e. non participant, zero prediction, keeps world state
- A built in default, fits most serdes
- Support for custom network libraries
- More efficient networking (right now, buffers are mixed with other args)
- AssignPlayerId needs testing to ensure calling in order

## License
GNU LESSER GENERAL PUBLIC LICENSE as transcribed in LICENSE.md
You are obligated to open source any code based off my code, including modifications or improvements.
