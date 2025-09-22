local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local DEFAULT_FOLDER_NAME = "__state-manager-default-folder__"
local HIDDEN_FOLDER_NAME = "__state-manager-hidden-folder__"
local ASSOCIATES_FOLDER_NAME = "__state-associates__"
local PROXY_FOLDER_NAME = "__state-associates__"
local WRITE_EVENT_NAME = "URE_StateWrite"
local LOCAL_WRITE_EVENT_NAME = "BE_StateWrite"
local TAG_PREFIX = "state-manager:"

local NIL_TOKEN = table.freeze({})

local ERR_NO_CLASSNAME = "[StateManager.new]: State must have a ClassName string"
local ERR_TYPE_MISMATCH = "[StateManager%s]: Type mismatch, expected %q, got %q"
local ERR_INCORRECT_RUN_CONTEXT = "[%s.%s]: You cannot %s a server owned state from the client. Please do this on the server"

local Packages = ReplicatedStorage.Packages

local Trove = require(Packages.Trove)
local Tree = require(Packages.Tree)
local BufferUtil = require(Packages.BufferUtil)

local assign = require(script.assign)

local function getOrCreate(parent: Instance, name: string, className: string)
	local thing = parent:FindFirstChild(name)
	if not thing then
		thing = Instance.new(className)
		thing.Name = name
		thing.Parent = parent
	end
	return thing
end

local DefaultFolder, HiddenFolder = nil, nil
if RunService:IsServer() then
	DefaultFolder = getOrCreate(ReplicatedStorage, DEFAULT_FOLDER_NAME, "Folder")
	HiddenFolder = getOrCreate(ServerStorage, HIDDEN_FOLDER_NAME, "Folder")
elseif RunService:IsClient() then
	DefaultFolder = ReplicatedStorage:WaitForChild(DEFAULT_FOLDER_NAME)
end

export type StateOptions = {
	WillReplicate: boolean,
	ClassName: string,
	Parent: Instance,
	WriteLib: ModuleScript,
}

export type State = {
	Trove: Trove.Trove,
	Data: { [string]: any },

	SetValue: (self: State, path: { string }, value: assign.ValueBaseCompatible) -> (),
	ArrayInsert: (self: State, path: { string }, value: assign.ValueBaseCompatible, index: number?) -> (),
	ArrayRemove: (self: State, path: { string }, index: number) -> (),

	Write: (self: State, funcName: string, ...any) -> (),
	ListenToWrite: (self: State, funcName: string, listener: () -> ()) -> () -> (),

	ObserveValue: (self: State, path: { string }, listener: (value: assign.ValueBaseCompatible, trove: Trove.Trove) -> ()) -> () -> (),
	ObserveArray: (
		self: State,
		path: { string },
		listener: (value: assign.ValueBaseCompatible, index: number, trove: Trove.Trove) -> ()
	) -> () -> (),

	Associate: (self: State, instance: Instance) -> boolean,
	IsAssociated: (self: State, instance: Instance) -> boolean,
	GetAssociate: (self: State, name: string) -> Instance?,

	Dissociate: (self: State, instance: Instance) -> boolean,
	DissociateAll: (self: State) -> boolean,

	Destroy: (self: State) -> (),
}

type StateManager = {
	new: (options: StateOptions, defaultData: { [string?]: any }) -> State,

	observe: (className: string, listener: (state: State) -> ()) -> () -> (),
	observeInstance: (instance: Instance, className: string, listener: (state: State) -> ()) -> () -> (),

	getAll: (className: string) -> { State },
	fromFolder: (stateFolder: Folder) -> State | nil,
	fromInstance: (instance: Instance, className: string) -> State | nil,

	destroy: (state: State) -> (),
}

local function getFromPath(data: { [string]: any }, path: { string })
	local pointer = data
	for i = 1, #path - 1 do
		pointer = pointer[path[i]]
	end

	return pointer[path[#path]]
end

local function setFromPath(data: { [string]: any }, path: { string }, newValue: any)
	local pointer = data
	for i = 1, #path - 1 do
		pointer = pointer[path[i]]
	end
	pointer[path[#path]] = newValue
end

local function trySetFromPath(data: { [string]: any }, path: { string }, newValue: any)
	local pointer = data
	for i = 1, #path - 1 do
		pointer = pointer[path[i]]
		if pointer == nil then
			return
		end
	end
	pointer[path[#path]] = newValue
end

local function walkUpPath(topParent: Instance, descendant: Instance)
	local parent = descendant.Parent
	local path = { descendant.Name }
	while parent ~= topParent do
		table.insert(path, 1, parent.Name)
		parent = parent.Parent
	end
	return path
end

local function invokeWriteLibListeners(state: State, funcName)
	for _, func in state._writeLibListeners[funcName] do
		task.spawn(func)
	end
end

local function canReplicate(inst: Instance)
	return not inst:IsDescendantOf(ServerScriptService) and not inst:IsDescendantOf(ServerStorage)
end

local State = {}
State.__index = State

function State.new(stateFolder: Folder)
	local self = setmetatable({}, State) :: State
	self.Trove = Trove.new()

	self._instance = stateFolder

	self._dataFolder = assert(stateFolder:WaitForChild("Data", 5), "What happened to the data folder??")
	self.Data = assign.fromFolder(self._dataFolder)

	local writeLib = self._instance:FindFirstChild("WriteLib")
	if writeLib then
		self._writeLib = require(writeLib.Value)
		self._writeLibListeners = {}
		for funcName in self._writeLib do
			self._writeLibListeners[funcName] = {}
		end
	end

	if RunService:IsClient() and stateFolder:GetAttribute("RunContext") == "server" then
		self._associatesFolder = stateFolder:WaitForChild(ASSOCIATES_FOLDER_NAME, 60)

		if writeLib then
			local unreliableEvent: UnreliableRemoteEvent = assert(stateFolder:WaitForChild(WRITE_EVENT_NAME, 60), "Missing remote event for WriteLib")
			self.Trove:Connect(unreliableEvent.OnClientEvent, function(buf)
				local reader = BufferUtil.reader(buf)
				local funcName = reader:ReadString()
				invokeWriteLibListeners(self, funcName)
			end)
		end

		if not self._associatesFolder then
			self._associatesFolder = Instance.new("Folder")
			self._associatesFolder.Name = ASSOCIATES_FOLDER_NAME
			self._associatesFolder.Parent = stateFolder
		end
	else
		self._associatesFolder = getOrCreate(stateFolder, ASSOCIATES_FOLDER_NAME, "Folder")

		if writeLib then
			if RunService:IsServer() or stateFolder:GetAttribute("RunContext") == "client" then
				self._be = getOrCreate(stateFolder, LOCAL_WRITE_EVENT_NAME, "BindableEvent")
			else
				self._be = stateFolder:WaitForChild(LOCAL_WRITE_EVENT_NAME, 60)
			end
			self.Trove:Connect(self._be.Event, function(funcName)
				invokeWriteLibListeners(self, funcName)
			end)
			if RunService:IsServer() and canReplicate(self._instance) then
				self._unreliableEvent = getOrCreate(stateFolder, WRITE_EVENT_NAME, "UnreliableRemoteEvent")
			end
		end
	end

	self.Trove:Connect(stateFolder.Destroying, function()
		self:DissociateAll()
		self:Destroy()
	end)

	local watchingValueBases = self.Trove:Extend()
	local function onValueBaseAdded(valueBase)
		if valueBase:IsA("ValueBase") then
			local inner = watchingValueBases:Extend()
			local path = walkUpPath(self._dataFolder, valueBase)

			local function onValueChanged(newValue)
				setFromPath(self.Data, path, newValue)
			end

			inner:Connect(valueBase.Destroying, function()
				trySetFromPath(self.Data, path, nil)
				watchingValueBases:Remove(inner)
			end)
			inner:Connect(valueBase.Changed, onValueChanged)
			onValueChanged(valueBase.Value)
		elseif valueBase:IsA("Folder") then
			local inner = watchingValueBases:Extend()
			local path = walkUpPath(self._dataFolder, valueBase)

			setFromPath(self.Data, path, assign.fromFolder(valueBase))
			inner:Connect(valueBase.Destroying, function()
				trySetFromPath(self.Data, path, nil)
				watchingValueBases:Remove(inner)
			end)
		end
	end

	for _, valueBase in self._dataFolder:GetDescendants() do
		task.spawn(onValueBaseAdded, valueBase)
	end
	self.Trove:Connect(self._dataFolder.DescendantAdded, onValueBaseAdded)

	return self
end

function State.Write(self: State, funcName: string, ...: any)
	if RunService:IsClient() and self._instance:GetAttribute("RunContext") == "server" then
		error(ERR_INCORRECT_RUN_CONTEXT:format("State", "Write", "make write calls to"), 2)
	end

	if not self._writeLib then
		error("[State.Write]: No WriteLib present", 2)
	end

	local func = self._writeLib[funcName]
	if func then
		task.spawn(func, self, ...)

		if self._be then
			self._be:Fire(funcName)
		end
		if self._unreliableEvent then
			local writer = BufferUtil.writer()
			writer:WriteString(funcName)
			self._unreliableEvent:FireAllClients(writer:GetBuffer())
		end
	else
		error(`[State.Write]: Function name "{funcName}" does not exist within WriteLib`, 2)
	end
end

function State.ListenToWrite(self: State, funcName: string, listener: () -> ())
	if not self._writeLib then
		error("[State.ListenToWrite]: No WriteLib present", 2)
	end

	local directory = self._writeLibListeners[funcName]
	if directory then
		table.insert(self._writeLibListeners[funcName], listener)
		return function()
			table.remove(self._writeLibListeners[funcName], table.find(self._writeLibListeners[funcName], listener))
		end
	else
		error(`"[State.ListenToWrite]: Function name "{funcName}" does not exist within WriteLib`, 2)
	end
end

function State.Associate(self: State, instance: Instance, key: string?)
	if RunService:IsClient() and self._instance:GetAttribute("RunContext") == "server" then
		error(ERR_INCORRECT_RUN_CONTEXT:format("State", "Associate", "associate"), 2)
	end

	if self:IsAssociated(instance) then
		warn(`[State.Associate]: This state is already associated with {instance:GetFullName()}`)
		return false
	end

	local proxyFolder = getOrCreate(instance, PROXY_FOLDER_NAME, "Folder")
	if proxyFolder:FindFirstChild(self._instance.Name) then
		warn(
			`A state with the same class name, {self._instance.Name} was already found in {instance:GetFullName()}.`
				.. `\nPlease dissociate that state before associating this one`
		)
		return false
	end

	local pointer = Instance.new("ObjectValue")
	pointer.Name = key or instance.Name
	pointer.Value = instance
	pointer.Parent = self._associatesFolder

	local proxy = Instance.new("ObjectValue")
	proxy.Name = self._instance.Name
	proxy.Value = self._instance
	proxy.Parent = proxyFolder

	return true
end

function State.IsAssociated(self: State, instance: Instance)
	local proxyFolder = instance:FindFirstChild(PROXY_FOLDER_NAME)
	if proxyFolder then
		local pointer = proxyFolder:FindFirstChild(self._instance.Name)
		if pointer and pointer.Value == self._instance then
			return true
		end
	end
	return false
end

function State.GetAssociate(self: State, name: string)
	local associates = self._instance:FindFirstChild(ASSOCIATES_FOLDER_NAME)
	if associates then
		local associate = associates:FindFirstChild(name)
		if associate then
			return associate.Value
		end
	end
	return nil
end

local function unsafeDissociate(className: string, pointer: ObjectValue)
	local inst = pointer.Value
	local proxyFolder = inst:FindFirstChild(PROXY_FOLDER_NAME)
	if proxyFolder then
		local proxyPointer = assert(proxyFolder:FindFirstChild(className), "Missing ProxyPointer")
		if proxyPointer then
			proxyPointer:Destroy()
		end
	end
	pointer:Destroy()
end

function State.Dissociate(self: State, instance: Instance)
	if RunService:IsClient() and self._instance:GetAttribute("RunContext") == "server" then
		error(ERR_INCORRECT_RUN_CONTEXT:format("State", "Dissociate", "dissociate"), 2)
	end
	local pointer = self._associatesFolder:FindFirstChild(instance.Name)
	if pointer then
		local ok, errorMessage = pcall(unsafeDissociate, self._instance.Name, pointer)
		if ok then
			return true
		else
			warn(errorMessage)
			return false
		end
	else
		warn(`{instance:GetFullName()} was not associated with {self._instance.Name}`)
		return false
	end
end

function State.DissociateAll(self: State)
	if RunService:IsClient() and self._instance:GetAttribute("RunContext") == "server" then
		error(ERR_INCORRECT_RUN_CONTEXT:format("State", "DissociateAll", "dissociate"), 2)
	end
	local associatesFolder = self._associatesFolder
	if associatesFolder then
		for _, pointer in associatesFolder:GetChildren() do
			local ok, errorMessage = pcall(unsafeDissociate, self._instance.Name, pointer)
			if not ok then
				warn(errorMessage)
			end
		end
		return true
	end
	return false
end

function State.SetValue(self: State, path: { string }, value: assign.ValueBaseCompatible)
	if RunService:IsClient() and self._instance:GetAttribute("RunContext") == "server" then
		error(ERR_INCORRECT_RUN_CONTEXT:format("State", "SetValue", "change"), 2)
	end

	local success, valueBase = pcall(Tree.Find, self._dataFolder, table.concat(path, "/"))
	if not success then
		if value == NIL_TOKEN then
			error("[State.SetValue]: Cannot set a non-existant value to Nil")
		end

		if #path > 1 then
			local p = table.move(path, 1, #path - 1, 1, {})
			local ok, folder = pcall(Tree.Find, self._dataFolder, table.concat(p, "/"), "Folder")
			if not ok then
				error("[State.SetValue]: Path is invalid. You cannot set deep values within values or fields that do not exist", 2)
			end
			assign.fromTable({ [path[#path]] = value }, folder)
			valueBase = folder:FindFirstChild(path[#path])
		else
			assign.fromTable({ [path[1]] = value }, self._dataFolder)
			valueBase = self._dataFolder:FindFirstChild(path[1])
			return
		end
	end

	if valueBase then
		if value == NIL_TOKEN then
			valueBase:Destroy()
		elseif valueBase:IsA("ValueBase") then
			valueBase.Value = value -- let this error. thats what the free type checking is for, and we were throwing an error after a type check anyways
		elseif valueBase:IsA("Folder") then
			error("[State.SetValue]: Cannot change a tables value. Consider setting it to Nil and then setting it", 2)
		end
	else
		error("[State.SetValue]: Attempting to set an unknown value", 2)
	end
end

function State.ArrayInsert(self: State, path: { string }, value: assign.ValueBaseCompatible, index: number?)
	if value == NIL_TOKEN then
		error("[State.ArrayInsert]: Cannot insert a Nil Token", 2)
	end

	local success, folder = pcall(Tree.Find, self._dataFolder, table.concat(path, "/"), "Folder")
	if not success then
		local errorMessage = folder
		error("[State.ArrayInsert]: " .. errorMessage, 2)
	end

	if index and index < 1 then
		index = 1
	end

	local maxNum = #folder:GetChildren() + 1
	if not index or index > maxNum then
		index = maxNum
	end

	for i, v in folder:GetChildren() do
		if i >= index then
			v.Name = tostring(i + 1)
		end
	end
	assign.fromTable({ [index] = value }, folder)
end

function State.ArrayRemove(self: State, path: { string }, index: number)
	if typeof(index) ~= "number" then
		error("[State.ArrayRemove]: You can only remove a numeric index", 2)
	end

	local success, folder = pcall(Tree.Find, self._dataFolder, table.concat(path, "/"), "Folder")
	if not success then
		local errorMessage = folder
		error("[State.ArrayRemove]: " .. errorMessage)
	end

	index = math.clamp(index, 1, #folder:GetChildren())

	local value = folder:FindFirstChild(tostring(index))
	if not value then
		error("[State.ArrayRemove]: Attempt to remove an index that does not exist", 2)
	end

	for _, v in folder:GetChildren() do
		local currentIndex = tonumber(v.Name)
		if currentIndex > index then
			v.Name = tostring(currentIndex - 1)
		end
	end
	value:Destroy()
end

--[=[
	Observe items inside an array. Will subscribe to **every single** change.

	Index changes will trigger the listener

	Value changes will trigger the listener

	Tables set as values **will not** reflect changes, so be careful using tables as values.

	```lua
		state:ObserveArray({ "Names" }, function(value, index, trove)
			print(index, "is now", value)

			trove:Add(function()
				print(value, "was removed")
			end)
		end)

		state:ArrayInsert({ "Names" }, "John")
		state:ArrayInsert({ "Names" }, "Jane")
		state:ArrayInsert({ "Names" }, "Joe")
		-- 1 is now John
		-- 2 is now Jane
		-- 3 is now Joe
		state:ArrayRemove({ "Names" }, 2)
		-- Jane was removed
		-- 2 is now Joe
	```
]=]
function State.ObserveArray(self: State, path: { string }, listener: (value: assign.ValueBaseCompatible, index: number, trove: Trove.Trove) -> ())
	local trove = self.Trove:Extend()
	local pathString = table.concat(path, "/")
	local isTracking = false
	local function onDescendantsChanged()
		if isTracking then
			return
		end
		isTracking = true
		local success, folder = pcall(Tree.Find, self._dataFolder, pathString, "Folder")
		if success then
			local watcher = trove:Extend()
			watcher:Add(function()
				isTracking = false
			end)
			watcher:Connect(folder.Destroying, function()
				trove:Remove(watcher)
			end)

			local function onChildAdded(inst: Instance)
				local inner = watcher:Extend()
				local changed = inner:Extend()

				local function onValueChanged()
					local value = nil
					if inst:IsA("ValueBase") then
						value = inst.Value
					elseif inst:IsA("Folder") then
						local c = table.clone(path)
						table.insert(c, inst.Name)
						value = assign.fromFolder(inst)
					end
					listener(value, tonumber(inst.Name), changed)
				end

				local function issueChange()
					changed:Destroy()
					onValueChanged()
				end

				onValueChanged()
				inner:Connect(inst.Destroying, function()
					watcher:Remove(inner)
				end)
				inner:Connect(inst.Changed, issueChange)
				inner:Connect(inst:GetPropertyChangedSignal("Name"), issueChange)
			end

			for _, inst in folder:GetChildren() do
				task.spawn(onChildAdded, inst)
			end
			watcher:Connect(folder.ChildAdded, onChildAdded)
		end
	end
	onDescendantsChanged()
	trove:Connect(self._dataFolder.DescendantAdded, onDescendantsChanged)

	return function()
		trove:Destroy()
	end
end

--[=[
	Observe Values within data, given the path array. The value does not have to exist at any point to be observed.
	The listener will run the moment the path provided yields a value.

	Table values will trigger the listener but will not subscribe to changes, see `State.ObserveArray`
	```lua
	State:ObserveValue({ "Name" }, function(value, trove)
		print(value)
		trove:Add(function()
			print("value was removed")
		end)
	end)
	```
	You **can** observe individual table fields
	```lua
	State:SetValue({ "Names", "Jane" }, true)

	State:ObserveValue({ "Names", "Jane" }, function(value, trove) end)
	```
]=]
function State.ObserveValue(self: State, path: { string }, listener: (value: assign.ValueBaseCompatible, trove: Trove.Trove) -> ())
	local trove = self.Trove:Extend()
	local isTracking = false
	local pathString = table.concat(path, "/")
	local function onDescendantsChanged()
		local success, valueBase = pcall(Tree.Find, self._dataFolder, pathString)
		if success and not isTracking then
			isTracking = true
			local inner = trove:Extend()
			inner:Add(function()
				isTracking = false
			end)

			if valueBase:IsA("ValueBase") then
				task.spawn(listener, valueBase.Value, inner)
				inner:Connect(valueBase.Changed, listener)
			elseif valueBase:IsA("Folder") then
				task.spawn(listener, getFromPath(self.Data, path), inner)
				warn(
					`[State.ObserveValue]: path "{pathString}" is a table value`
						.. `\nChanges to its members will not be reflected`
						.. `\nConsider listening to the tables fields instead`
				)
			end
			inner:Connect(valueBase.Destroying, function()
				trove:Remove(inner)
			end)
		end
	end

	onDescendantsChanged()
	trove:Connect(self._dataFolder.DescendantAdded, onDescendantsChanged)

	return function()
		trove:Destroy()
	end
end

function State.Destroy(self: State)
	self.Trove:Destroy()

	table.clear(self)
	setmetatable(self, nil)
end

local StateManager = {} :: StateManager
StateManager.Nil = NIL_TOKEN

function StateManager.new(options: StateOptions, defaultData: { [string]: any })
	local className = assert(options.ClassName, ERR_NO_CLASSNAME)
	assert(typeof(className) == "string", ERR_TYPE_MISMATCH:format(".new", "string", typeof(className)))

	if options.WillReplicate == nil then
		options.WillReplicate = true
	end

	local stateFolder = Instance.new("Folder")
	stateFolder.Name = ("State<%s>"):format(className)
	stateFolder:SetAttribute("ClassName", className)
	stateFolder:SetAttribute("RunContext", if RunService:IsServer() then "server" else "client")

	local dataFolder = Instance.new("Folder")
	dataFolder.Name = "Data"
	dataFolder.Parent = stateFolder

	if defaultData then
		assign.fromTable(defaultData, dataFolder)
	end

	if options.WriteLib then
		local modErr = "[StateManager.new]: WriteLib must be a ModuleScript instance"
		assert(typeof(options.WriteLib) == "Instance", modErr)
		assert(options.WriteLib:IsA("ModuleScript"), modErr)

		if RunService:IsServer() and options.WillReplicate == true and canReplicate(options.WriteLib) == false then
			warn("[StateManager.new]: WriteLib is not in a replicable Container.\nAttempting manual WriteLib move")
			options.WriteLib.Parent = ReplicatedStorage
		end

		local pointer = Instance.new("ObjectValue")
		pointer.Name = "WriteLib"
		pointer.Value = options.WriteLib
		pointer.Parent = stateFolder
	end

	local parent = options.Parent
	if parent == nil or typeof(parent) ~= "Instance" then
		if options.WillReplicate == false and RunService:IsServer() then
			parent = HiddenFolder
		else
			parent = DefaultFolder
		end
	end
	stateFolder.Parent = parent

	CollectionService:AddTag(stateFolder, TAG_PREFIX .. className)

	return State.new(stateFolder)
end

StateManager.fromFolder = State.new

function StateManager.fromInstance(instance: Instance, className: string)
	local proxyFolder = instance:FindFirstChild(PROXY_FOLDER_NAME)
	if not proxyFolder then
		warn(`[StateManager.fromInstance]: No associated state was found in {instance:GetFullName()}`)
		return nil
	end

	local pointer = proxyFolder:FindFirstChild(("State<%s>"):format(className))
	if pointer and pointer:IsA("ObjectValue") then
		local folder = pointer.Value
		if folder and folder:IsA("Folder") then
			if folder:HasTag(TAG_PREFIX .. className) then
				return State.new(folder)
			end
		end
	end
	return nil
end

function StateManager.getAll(className: string)
	local output = {}
	for _, inst in CollectionService:GetTagged(TAG_PREFIX .. className) do
		table.insert(output, State.new(inst))
	end
	return output
end

function StateManager.observe(className: string, listener: (state: State) -> ())
	local all = StateManager.getAll(className)

	local observerTrove = Trove.new()
	local troves = {}
	local function onStateAdded(state: State)
		local trove = observerTrove:Extend()
		trove:Add(state)
		troves[state._instance] = trove
		listener(state)
	end

	local function onInstanceAdded(folder: Folder)
		local state = State.new(folder)
		onStateAdded(state)
	end

	for _, state in all do
		task.spawn(onStateAdded, state)
	end
	local tag = TAG_PREFIX .. className
	observerTrove:Connect(CollectionService:GetInstanceAddedSignal(tag), onInstanceAdded)
	observerTrove:Connect(CollectionService:GetInstanceRemovedSignal(tag), function(inst)
		local trove = troves[inst]
		if trove then
			observerTrove:Remove(trove)
			troves[inst] = nil
		end
	end)

	return function()
		observerTrove:Destroy()
	end
end

function StateManager.observeInstance(instance: Instance, className: string, listener: (state: State) -> ())
	local trove = Trove.new()
	local inner = trove:Extend()

	local function watchFolder(folder: Folder)
		local snapShots = {}
		local function onPointerAdded(pointer: ObjectValue)
			if pointer:IsA("ObjectValue") then
				local stateFolder = pointer.Value
				if stateFolder:GetAttribute("ClassName") == className then
					local state = State.new(stateFolder)
					snapShots[pointer] = state
					task.spawn(listener, state)
				end
			else
				warn(
					`[StateManager.observeInstance]: An unknown instance entered {folder:GetFullName()}`
						.. `\nName: {pointer.Name}\nClass: {pointer.ClassName}`
				)
			end
		end
		for _, pointer in folder:GetChildren() do
			onPointerAdded(pointer)
		end
		inner:Connect(folder.ChildAdded, onPointerAdded)
		inner:Connect(folder.ChildRemoved, function(child)
			if child:IsA("ObjectValue") then
				local state = snapShots[child]
				if state then
					state:Destroy()
				end
			end
		end)
	end

	local proxyFolder = instance:FindFirstChild(PROXY_FOLDER_NAME)
	trove:Connect(instance.ChildAdded, function(child)
		if child:IsA("Folder") and child.Name == PROXY_FOLDER_NAME then
			watchFolder(child)
			proxyFolder = child
		end
	end)

	trove:Connect(instance.ChildRemoved, function(child)
		if child == proxyFolder then
			inner:Destroy()
			proxyFolder = nil
		end
	end)

	if proxyFolder then
		watchFolder(proxyFolder)
	end

	return function()
		trove:Destroy()
	end
end

function StateManager.destroy(state: State)
	local handle = state._instance
	if RunService:IsClient() and handle:GetAttribute("RunContext") == "server" then
		error(ERR_INCORRECT_RUN_CONTEXT:format("StateManager", "destroy", "destroy"), 2)
	end

	state:DissociateAll()
	state:Destroy()
	handle:Destroy()
end

return StateManager
