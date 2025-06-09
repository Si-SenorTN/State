local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local DEFAULT_FOLDER_NAME = "__state-manager-default-folder__"
local HIDDEN_FOLDER_NAME = "__state-manager-hidden-folder__"
local ASSOCIATES_FOLDER_NAME = "__state-associates__"
local PROXY_FOLDER_NAME = "__state-associates__"
local TAG_PREFIX = "state-manager:"

local ERR_NO_CLASSNAME = "[StateManager.new]: State must have a ClassName string"
local ERR_TYPE_MISMATCH = "[StateManager%s]: Type mismatch, expected %q, got %q"
local ERR_INCORRECT_RUN_CONTEXT = "[%s.%s]: You cannot %s a server owned state from the client. Please do this on the server"

local Packages = ReplicatedStorage.Packages

local Trove = require(Packages.Trove)
local Tree = require(Packages.Tree)

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
}

export type State = {
	Trove: Trove.Trove,
	Data: { [string]: any },

	SetValue: (self: State, path: { string }, value: any) -> (),
	ObserveChange: (self: State, path: { string }, listener: (value: any) -> ()) -> Trove.Trove,

	Associate: (self: State, instance: Instance) -> (),
	IsAssociated: (self: State, instance: Instance) -> boolean,

	Dissociate: (self: State, Instance) -> (),
	DissociateAll: (self: State) -> (),

	Destroy: (self: State) -> (),
}

local State = {}
State.__index = State

function State.new(stateFolder: Folder): State
	local self = setmetatable({}, State)
	self.Trove = Trove.new()
	self.Data = assign.fromFolder(stateFolder)

	self._instance = stateFolder

	if RunService:IsClient() and stateFolder:GetAttribute("RunContext") == "server" then
		self._associatesFolder = stateFolder:WaitForChild(ASSOCIATES_FOLDER_NAME, 5)
		if not self._associatesFolder then
			self._associatesFolder = Instance.new("Folder")
			self._associatesFolder.Name = ASSOCIATES_FOLDER_NAME
			self._associatesFolder.Parent = stateFolder
		end
	else
		self._associatesFolder = getOrCreate(stateFolder, ASSOCIATES_FOLDER_NAME, "Folder")
	end

	self.Trove:Connect(stateFolder.Destroying, function()
		self:Destroy()
	end)

	for _, valueBase in self._instance:GetDescendants() do
		if valueBase:IsA("ValueBase") then
			self.Trove:Connect(valueBase.Changed, function(newValue)
				local parent = valueBase.Parent
				local path = { valueBase.Name }
				while parent ~= self._instance do
					table.insert(path, 1, parent.Name)
					parent = parent.Parent
				end

				local pointer = self.Data
				for i = 1, #path - 1 do
					pointer = pointer[path[i]]
				end
				pointer[path[#path]] = newValue
			end)
		end
	end

	return self
end

function State.Associate(self: State, instance: Instance)
	if RunService:IsClient() and self._instance:GetAttribute("RunContext") == "server" then
		error("You cannot associate a server owned state from the client. Please do this on the server")
	end

	if self:IsAssociated(instance) then
		warn(`This state is already associated with {instance:GetFullName()}`)
		return
	end

	local proxyFolder = getOrCreate(instance, PROXY_FOLDER_NAME, "Folder")
	if proxyFolder:FindFirstChild(self._instance.Name) then
		warn(
			`A state with the same class name, {self._instance.Name} was already found in {instance:GetFullName()}.\nPlease dissociate that state before associating this one`
		)
		return
	end

	local pointer = Instance.new("ObjectValue")
	pointer.Name = instance.Name
	pointer.Value = instance
	pointer.Parent = self._associatesFolder

	local proxy = Instance.new("ObjectValue")
	proxy.Name = self._instance.Name
	proxy.Value = self._instance
	proxy.Parent = proxyFolder
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

function State.Dissociate(self: State, instance: Instance)
	if RunService:IsClient() and self._instance:GetAttribute("RunContext") == "server" then
		error(ERR_INCORRECT_RUN_CONTEXT:format("State", "Dissociate", "dissociate"), 2)
	end
	local pointer = self._associatesFolder:FindFirstChild(instance.Name)
	if pointer then
		local className = pointer.Name
		local inst = pointer.Value
		local proxyFolder = inst:FindFirstChild(PROXY_FOLDER_NAME)
		if proxyFolder then
			local proxyPointer = proxyFolder:FindFirstChild(className)
			if proxyPointer then
				proxyPointer:Destroy()
			end
		end
		pointer:Destroy()
	else
		warn(`{instance:GetFullName()} was not associated with {self._instance.Name}`)
	end
end

function State.DissociateAll(self: State)
	if RunService:IsClient() and self._instance:GetAttribute("RunContext") == "server" then
		error(ERR_INCORRECT_RUN_CONTEXT:format("State", "DissociateAll", "dissociate"), 2)
	end
	local associatesFolder = self._associatesFolder
	if associatesFolder then
		for _, pointer in associatesFolder:GetChildren() do
			self:Dissociate(pointer.Value)
		end
	end
end

function State.SetValue(self: State, path: { string }, value: any)
	if RunService:IsClient() and self._instance:GetAttribute("RunContext") == "server" then
		error(ERR_INCORRECT_RUN_CONTEXT:format("State", "SetValue", "change"), 2)
	end
	local pointer = self.Data
	for i = 1, #path - 1 do
		pointer = pointer[path[i]]
	end
	pointer[path[#path]] = value

	local success, valueBase = pcall(Tree.Find, self._instance, table.concat(path, "/"), "ValueBase")
	if not success then
		if #path > 1 then
			error("Path is invalid. You cannot set deep values within fields that do not exist", 2)
		end

		assign.fromTable({ [path[1]] = value }, self._instance)
		valueBase = self._instance:FindFirstChild(path[1])
	end

	if valueBase and valueBase:IsA("ValueBase") then
		valueBase.Value = value
	end
end

function State.ObserveChange(self: State, path: { string }, listener: (value: any) -> ())
	local valueBase = Tree.Await(self._instance, table.concat(path, "/"), 5, "ValueBase")
	if valueBase then
		local trove = self.Trove:Extend()
		task.spawn(listener, valueBase.Value)
		trove:Connect(valueBase.Changed, listener)
		return trove
	end
	return nil
end

function State.Destroy(self: State)
	self.Trove:Destroy()
end

local StateManager = {}

function StateManager.new(options: StateOptions, defaultData: { [string]: any })
	local className = assert(options.ClassName, ERR_NO_CLASSNAME)
	assert(typeof(className) == "string", ERR_TYPE_MISMATCH:format(".new", "string", typeof(className)))

	if options.WillReplicate == nil then
		options.WillReplicate = true
	end

	local Tags = options.Tags
	if Tags then
		assert(typeof(Tags) == "table", ERR_TYPE_MISMATCH:format(".new", "table", typeof(Tags)))
	end

	local stateFolder = Instance.new("Folder")
	stateFolder.Name = ("State<%s>"):format(className)
	stateFolder:SetAttribute("ClassName", className)
	stateFolder:SetAttribute("RunContext", if RunService:IsServer() then "server" else "client")

	if defaultData then
		assign.fromTable(defaultData, stateFolder)
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

	local state = State.new(stateFolder)

	return state
end

StateManager.fromFolder = State.new

function StateManager.fromInstance(instance: Instance, className: string)
	local proxyFolder = instance:FindFirstChild(PROXY_FOLDER_NAME)
	if not proxyFolder then
		warn(`No associated state was found in {instance:GetFullName()}`)
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
end

function StateManager.getAll(className: string)
	local output = {}
	for _, inst in CollectionService:GetTagged(TAG_PREFIX .. className) do
		output[inst.Name] = State.new(inst)
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
