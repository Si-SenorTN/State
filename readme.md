# State Manager

State Manager is a practical state solution that keeps Roblox as its' source of truth.

A source of truth is a single, reliable, source of data, that is able to be accessed by any script, environment, or thread, without suffering desynchronization or data copying. We achieve this though ValueBases and Folders, they are the backbone of this setup.

Since we are relying on instances, we:
- Do not have to wait for some process to start in order to use our data.
- Do not suffer from the random bug of module scripts re-requiring
- Have a replicating, single source of data

The only thing we have to wait on is our instances existing. This is the essence of keeping Roblox as our source of truth.

When we use ValueBases, we gain access to a few powerful features:

- Automatic replication
- Free type checking
- Changes automatically throttle to 60hz (1/60)
- Changed signal is already included
- Duplicate values dont trigger the changed signal

Our Source of state will exist as a Folder anywhere in the hierarchy. When we wrap state around these instances, we are creating a "snapshot" of state, rather than having to pass a single table all around our code.

This is what our snapshot might look like

```lua
local StateManager = require(Packages.StateManager)

local state = StateManager.new({
	ClassName = "MyState",
	WillReplicate = true,
}, {
	MyValue = 35,
	MyArray = {},
	NestedData = {
		AnotherValue = "important string"
	}
})

print(state.Data.MyValue) -- 35

state:SetValue({"NestedData", "AnotherValue"}, "even better string")
print(state.Data.NestedData.AnotherValue) -- "even better string"
```

`StateManager.new` will initialize the state folder, and then give you back a snapshot. A snapshot can be destroyed, but only the snapshot will cease to exist, the instances will stay untouched.

When you are totally done with your state, you must call `StateManager.destroy` to properly dispose of the state for good.

# Comparisons with [Replica](https://github.com/MadStudioRoblox/Replica)
This module shares a lot of similarities with replica/replicaservice. At the time of writing I'm making the switch from replica to this module. I don't have much  negative to say about replica, if anything I took inspiration from it. But I've recently been moving in a different direction and Replica doesn't fit my needs anymore.

A lot of the api share the same function names and design philosophies. Here are a few comparisons:

- `Set({string}, value)` vs `SetValue({string}, value)`
- `Write(funcName, ...any)`
- `ListenToWrite(funcName, listener)`
- `ArrayInsert({string}, value, index)`
- `ArrayRemove({string}, index)`
- `Replica.OnNew(className, listener)` vs `StateManager.observe(className, listener)` `StateManager.observeInstance(instance, className, listener)`

# Why the switch?

In my personal opinion, I do not like some of the limitations replicas impose. To name a few:
- You cannot listen to changes server side.
- It is not convenient to access replicas from neighboring scripts.
- Replica creation needs to be listened to first, **and then** requested.
- The server doesn't have the ability to listen to created replicas, without custom implementation.
- Almost forces you to use a single script structure

And There are some minor issues that I have as well.
- The new `OnChange` listener does not make it easy to listen to array changes.
- There is no observer pattern when listening to value changes.
- There are no client only replicas

# How do I improve upon Replicas?
Going down the list,
- observing value and array changes are present for both the server and client.
- I've made it super conventient to access a state snapshot with little to no outside effort.
- You do not have to start any process to get access to state. If it is server -> server, client -> client, server -> client, each patterns have all the same abilities to access state. As soon as the instances are created, state is ready to be queried and used.
- Any script can access the same state and subscribe to the same exact changes.
- All state changes are able to be observed, including array insert and remove.
- State is able to be created client side and used all the same, and will not replicate to the server.
- StateManager is self aware of the run-context, and will not allow the client to perform write calls on a server owned state.

I would also like to mention network usage. ValueBases have less overhead when replicating its value to the client vs RemoteEvents *(by very little)*. Replicas are a RemoteEvent based framework, and don't do any kind of compression for packets. I don't either, infact, I cant, *directly*. I will mention more about how we can compress my State later, but first, I want to showcase the difference in network usage, as is, between Replica and StateManager.

First, I ran this stress test replicating 100 states with a deep nested value to a random number [-100, 100], every single frame.
![stress_test_server](/images/stress_test_server.JPG)

And on the client, just a noop listener. *(makes no difference)*
![stress_test_client](/images/stress_test_client.JPG)

And no, they were not both running at the same time, I just uncommented them so they were easier to read.

And these were the results:

### Replica network usage

![replica_recv](/images/replica_recv.JPG)

### StateManager network usage

![state_manager_recv](/images/state_recv.JPG)

Both of these are really bad, yeah I know. It's an extreme example and I (and I'm sure loleris) would never reccomend changing a value every single frame using our respective frameworks.

But with that being said, Replica uses over 3x more KBs than StateManager. The main difference here is we don't have to send that long path table over the network, or an id. And the deeper it gets, the worse it gets for replica, yet we stay unchanged. This is the power of using instances.

But RemoteEvents do have an edge over us, they can use buffers to compress packet size, and the effects are dramatic. We dont have access to use buffers directly. Nor does Replica, and if you wanted to use them, it'd be very difficult to implement. Implementing it with StateManager though, is simplier than you may think.

```lua
local StateManager = require(Packages.StateManager)
local BufferUtil = require(Packages.BufferUtil)

local replicationFolder = Instance.new("Folder")
replicationFolder.Name = "ReplicationFolder"
replicationFolder.Parent = ReplicatedStorage

for i = 1, 100 do
	local state = StateManager.new({
		ClassName = "Entity",
		WillReplicate = false, -- THIS IS SUPER IMPORTANT
		-- By not replicating it, we eliminate all usual network traffic
	}, {
		Id = i,
		Position = Vector3.one,
	})

	local rev = state.Trove:Construct(Instance, "UnreliableRemoteEvent")
	rev.Name = "Entity/" .. state.Data.Id
	rev.Parent = replicationFolder

	state:Associate(rev)

	local function getPosition()
		return Vector3.new(math.random(-100, 100), 2, math.random(-100, 100))
	end

	local currentTime = os.clock()
	local throttleTime = 1 / 10 -- throttle to 10hz instead of 60
	-- this is about as fast as id replicate a property like this one
	-- the client can grab this value and then interpolate towards it
	-- based off the prev vector they got
	RunService.Heartbeat:Connect(function()
		if os.clock() - currentTime > throttleTime then
			currentTime = os.clock()
			state:SetValue({ "Position" }, getPosition())
		end
	end)

	state:ObserveValue({ "Position" }, function(value)
		local writer = BufferUtil.writer()
		writer:WriteInt16(value.X)
		writer:WriteInt16(value.Z)
		rev:FireAllClients(writer:GetBuffer())
	end)
end
```

```lua
-- client
local StateManager = require(Packages.StateManager)
local BufferUtil = require(Packages.BufferUtil)

local repFolder = ReplicatedStorage:WaitForChild("ReplicationFolder")
local function onEventAdded(rev)
	local arr = rev.Name:split("/")
	local state = StateManager.new({
		ClassName = arr[1],
	}, {
		Id = arr[2],
	})
	state.Trove:Connect(rev.OnClientEvent, function(packet)
		local reader = BufferUtil.reader(packet)
		local x = reader:ReadInt16()
		local z = reader:ReadInt16()
		local y = 2 -- this is inferred
		-- in real practice we might raycast to the floor.
		local vec = Vector3.new(x, y, z)
		--print(vec)
		state:SetValue({ "Position" }, vec)
	end)
end
for _, child in repFolder:GetChildren() do
	onEventAdded(child)
end
repFolder.ChildAdded:Connect(onEventAdded)
```

### The result
![state_with_buffer](/images/state_with_buffer.JPG)

This is a very dirty implementation, but we're well under the target, and it really didn't take much. 100 entities constantly updating their positions.

Keep in mind this is with no remote que, no extra optimizations, apart from the throttle. The main takeaway here is we were able to have our state on both networks, synced, and compressed. We have a lossless position on the server we can constantly update and suffer no network penalty.

### Want the full story? Read the API section to get in-depth coverage.

# API

## Types

### `StateOptions`
```lua
{
	WillReplicate: boolean,
	ClassName: string,
	Parent: Instance,
	WriteLib: ModuleScript,
}
```
#### `WillReplicate`
Server option only, will determine what default parent to set it to, if none is provided. If false it will default to `ServerStorage`, true will default to `ReplicatedStorage`

#### `ClassName`
Associating a class name with state will allow you to differentiate it from other states. ClassNames are queryable and can be observed.

#### `Parent`
Allows you to set a custom parent for your state. If none is provided, it will determine a default parent based on the `WillReplicate` field, and whether or not it was created on the server.

#### `WriteLib`
Optional field to provide a module script instance containing custom mutators.
```lua
-- inside writelib
return {
	Increment = function(state, increment)
		state:SetValue({"ImportantData"}, true)
		state:SetValue({"AnotherImportantData"}, state.Data.AnotherImportantData + increment)
	end,
	-- etc
}
```

### `ValueBaseCompatible`
```lua
string | number | boolean | Instance | Vector3 | Vector2 | CFrame | Color3 | BrickColor | Ray | table
```
Any type that has a corresponding `ValueBase` instance. table resolves to `Folder` instances.

## StateManager

### `StateManager.new`
```lua
(options: StateOptions, defaultData: { [string?]: any }) -> State,
```
Creates a completely new state folder, and returns a state snapshot.

### `StateManager.observe`
```lua
(className: string, listener: (state: State) -> ()) -> () -> ()
```
Observes states based on their class names.
```lua
StateManager.observe("PlayerData", function(state)
	state.Trove:Add(function()
		print("this state was removed")
	end)
end)
```

### `StateManager.observeInstance`
```lua
(instance: Instance, className: string, listener: (state: State) -> ()) -> () -> ()
```
Observes states of a specific ClassName **Associated** with an instance.
```lua
local terrainData = StateManager.new({
	ClassName = "TerrainData"
})
terrainData:Associate(workspace.Terrain)
-------------------------------------------------------------------------------
StateManager.observeInstance(workspace.Terrain, "TerrainData", function(state)
	print(state)
end)
```

### `StateManager.getAll`
```lua
(className: string) -> { State }
```
Querys all currently existing states of a specific ClassName.
```lua
for _, state in StateManager.getAll("PlayerData") do
	print(state)
end
```

### `StateManager.fromFolder`
```lua
(stateFolder: Folder) -> State | nil
```
Converts a state folder into a State snapshot object.
```lua
local folder = Players.LocalPlayer:FindFirstChild("State<PlayerData>")
if folder then
	local state = StateManager.fromFolder(folder)
	print(state)
end
```

### `StateManager.fromInstance`
```lua
(instance: Instance, className: string) -> State | nil
```
Querys an **Associated** state of a specific ClassName from the passed instance
```lua
local state = StateManager.new({
	ClassName = "PlayerData"
}, {
	hello = "world"
})
state:Associate(Players.LocalPlayer)

local newState = StateManager.fromInstance(Players.LocalPlayer, "PlayerData")
print(newState == state) -- false
print(newState.Data.hello == state.Data.hello) -- true
-- both snapshot the same folder, but are two separate objects
```

### `StateManager.destroy`
```lua
(state: State) -> ()
```
The **only** method that will permenantly dispose of any passed state
```lua
StateManager.destroy(state)
-- all associated instances will be un-associated and folder will be destroyed
-- thus causing all snapshots of this folder to destroy themselves.
```

## State

### `State.Data`
```lua
{ [string]: any }
```
The data table dynamically changes to match the state instances hierarchy and values. This table is meant to be read only, but I cannot freeze it due to its dynamic nature. If you are using something like [ProfileService](), you can directly set a profiles data table to the states data table.

### `State.Trove`
State exposes its internal trove so you can add temporary state to it, and hook to when `Destroy` is called.
```lua
local state = StateManager.fromInstance(Player.LocalPlayer)
state.Trove:Add(function()
	print("State was destroyed")
end)

task.delay(5, function()
	state:Destroy() -- print runs
end)
```

### `State.SetValue`
```lua
(self: State, path: { string }, value: assign.ValueBaseCompatible) -> ()
```
Sets any value inside the state. **Mutator functions do not do any kind of type checking**. Errors will be thrown if you pass a value incompatible with a value base.
```lua
state:SetValue({ "MyCoolTable", "MyCoolValue" }, 47)
```

### `State.ArrayInsert`
```lua
(self: State, path: { string }, value: assign.ValueBaseCompatible, index: number?) -> ()
```
Inserts an element into state with an ordinal key. `ArrayInsert` and `ArrayRemove` automatically
reorder instances depending on when and where they were inserted.
**Mutator functions do not do any kind of type checking**. Errors will be thrown if you pass a value incompatible with a value base.
**Be careful when inserting table values into an array**. Changes made to the sub table will **not** invoke the observer. **Do not mix arrays with dictionaries**. The auto sorting behavior **will** mess up the dictionary keys.

```lua
state:ArrayInsert({ "MyCoolTable" }, "John")
state:ArrayInsert({ "MyCoolTable" }, "Jane")
state:ArrayInsert({ "MyCoolTable" }, "William")
--> 1 John, 2 Jane, 3 William

state:ArrayInsert({ "MyCoolTable" }, "Nancy", 2)
--> 1 John, 2 Nancy, 3 Jane, 4 William
```

### `State.ArrayRemove`
```lua
(self: State, path: { string }, index: number) -> ()
```
Removes an element from state given the ordinal key, `index`. `ArrayInsert` and `ArrayRemove` automatically reorder instances depending on when and where they were inserted. **Do not mix arrays with dictionaries**. The auto sorting behavior **will** mess up the dictionary keys.
```lua
state:ArrayInsert({ "MyCoolTable" }, "John")
state:ArrayInsert({ "MyCoolTable" }, "Jane")
state:ArrayInsert({ "MyCoolTable" }, "William")

state:ArrayRemove({ "MyCoolTable" }, 2)
--> 1 John, 2 William
```

### `State.ObserveValue`
```lua
(self: State, path: { string }, listener: (value: assign.ValueBaseCompatible) -> ()) -> Trove.Trove
```
Subscribes to changes and immediately invokes the listener function if a value is already present. The value does not have to exist immediately to be observed. It can be set later and the observer will pick up on it.
```lua
state:SetValue({ "MyCoolValue" }, 16)
local stopObserving = state:ObserveChange({"MyCoolValue"}, function(value, trove)
	print("The value is",  value)
	trove:Add(function()
		print("the value is not", value, "anymore")
	end)
end)
state:SetValue({ "MyCoolValue" }, 32)
```

### `State.ObserveArray`
```lua
(
	self: State,
	path: { string },
	listener: (value: assign.ValueBaseCompatible, index: number, trove: Trove.Trove) -> ()
) -> () -> ()
```
Subscribes to array changes and immediates invokes the listener function if value(s) are already present. The array does not have to exist immediately to be observed. It can be set later and the observer will pick up on it. **Be careful when inserting table values into an array**. Changes made to the sub table will **not** invoke the observer.
```lua
state:ObserveArray({"MyCoolTable"}, function(value, key, trove)
	print(value, "is at", key)
	trove:Add(function()
		print(value, "is no longer at", key)
	end)
end)
state:ArrayInsert({ "MyCoolTable" }, "John")
state:ArrayInsert({ "MyCoolTable" }, "Jane")
state:ArrayInsert({ "MyCoolTable" }, "William")

state:ArrayRemove({ "MyCoolTable" }, 2)
```

### `State.Associate`
```lua
(self: State, instance: Instance) -> boolean
```
Associates an instance with this state.
```lua
state:Associate(Players.LocalPlayer)
```
### `State.IsAssociated`
```lua
(self: State, instance: Instance) -> boolean
```
Checks if an instance is associated with this state.
```lua
state:Associate(Players.LocalPlayer)
print(state:IsAssociated(Player.LocalPlayer)) --> true
```
### `State.GetAssociate`
```lua
(self: State, name: string) -> Instance?
```
Queries an associate instance by name.
```lua
local folder = Instance.new("Folder")
folder.Name = "SpecialFolder"
folder.Parent = ReplicatedStorage
state:Associate(folder)

print(state:IsAssociated(folder)) --> true
local pointer = state:GetAssociate("SpecialFolder")
print(pointer == folder) --> true
```
### `State.Dissociate`
```lua
(self: State, instance: Instance) -> boolean
```
Dissociates a specific instance with this state.
```lua
local folder = Instance.new("Folder")
folder.Name = "SpecialFolder"
folder.Parent = ReplicatedStorage
state:Associate(folder)

print(state:IsAssociated(folder)) --> true
state:Dissociate(folder)
print(state:IsAssociated(folder)) --> false
```
### `State.DissociateAll`
```lua
(self: State) -> boolean
```
Dissociates all instances with this state.
```lua
local folder = Instance.new("Folder")
folder.Name = "SpecialFolder"
folder.Parent = ReplicatedStorage
state:Associate(folder)
local folder2 = Instance.new("Folder")
folder2.Name = "SpecialFolder2"
folder2.Parent = ReplicatedStorage
state:Associate(folder2)

print(state:IsAssociated(folder)) --> true
print(state:IsAssociated(folder2)) --> true
state:DissociateAll(folder)
print(state:IsAssociated(folder)) --> false
print(state:IsAssociated(folder2)) --> false
```
### `State.Destroy`
```lua
(self: State) -> ()
```
Removes the current snapshot. **Will not destroy the state folder**. To destroy the state folder, please use `StateManager.destroy()`.