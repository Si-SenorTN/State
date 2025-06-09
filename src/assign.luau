local ASSOCIATES_FOLDER_NAME = "__state-associates__"
local TYPE_MAP = {
	string = "StringValue",
	number = "NumberValue",
	boolean = "BoolValue",
	Instance = "ObjectValue",
	Vector3 = "Vector3Value",
	Vector2 = "Vector2Value",
	CFrame = "CFrameValue",
	Color3 = "Color3Value",
}
local WARN_DISALLOWED_TYPE = "[StateManager%s]: Type of %q cannot be converted to a ValueBase instance, Ignoring"

local assign = {}

function assign.fromFolder(folder: Folder)
	local output = {}
	for _, value in folder:GetChildren() do
		if value:IsA("Folder") then
			output[value.Name] = assign.fromFolder(value)
		else
			output[value.Name] = value.Value
		end
	end
	return output
end

function assign.fromTable(source: { [string]: any }, folder: Folder)
	for name, value in source do
		if name == ASSOCIATES_FOLDER_NAME then
			error(`State value cannot have same as associates folder: {ASSOCIATES_FOLDER_NAME}`)
		end

		local class = TYPE_MAP[typeof(value)]
		if class then
			local inst = Instance.new(class)
			inst.Name = name
			inst.Value = value
			inst.Parent = folder
		elseif typeof(value) == "table" then
			local subFolder = Instance.new("Folder")
			subFolder.Name = name
			subFolder.Parent = folder
			assign.fromTable(value, subFolder)
		else
			warn(WARN_DISALLOWED_TYPE:format(".new", class))
		end
	end
end

return assign
