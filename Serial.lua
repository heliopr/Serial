--[[
Made by helioroqueargh (discord: maqagril)

This is an attempt of making a serialization module that requires no manual work in regards to setting up instances, but only in types.
It works by sending a request to an API Dump server, then parsing the result into a more comprehensible way, and storing every property
along with its type into instanceDefaults. Every time an instance is serialized, it checks if the defaults have been loaded, if not then it
proceeds to create a new instance of that same class, and storing the defaults into instanceDefaults, and then it proceeds to save only
those properties that have been modified.

I have made simple benchmarks of this module and it seems to be able to serialize around 150k instances per second, while deserializing
around 80k per second, on my computer of course.

Examle usage:

	local Serial = require(game.ReplicatedStorage.Serial)
	print("getting api dump")

	Serial.GetLatestAPIDump()

	task.wait(5)
	print("serializing")

	local t = os.clock()
	local serialized = Serial.SerializeInstance(workspace.Model)
	print("serialize time", os.clock()-t)

	print("Descendants", #workspace.Model:GetDescendants())
	print(serialized)

	workspace.Model:Destroy()

	task.wait(3)

	t = os.clock()
	Serial.DeserializeInstance(serialized, workspace)
	print("deserialize time", os.clock()-t)
	print(#workspace.Model:GetDescendants())
]]


-- CONFIG
--[[DON'T CHANGE UNLESS YOU KNOW WHAT YOU ARE DOING]]
local API_CURRENT_VERSION_URL = "https://setup.rbxcdn.com/versionQTStudio"
local API_DUMP_URL = "https://setup.rbxcdn.com/%s-API-Dump.json" -- %s format
--[[DON'T CHANGE UNLESS YOU KNOW WHAT YOU ARE DOING]]


-- SERVICES
local HttpService = game:GetService("HttpService")


-- VARIABLES
local apiDumpRaw = {} -- stores the raw JSON data from Roblox
local instanceDefaults = {} -- cached property names and default values for each class
local instanceableInstances = {} -- table used to quickly check if a class can be instanced by a script

-- any primitive type can be defined in this way as they don't need any transformation to be stored in json (serializer and deserializer)
local primitiveType = {function(deserialized) return deserialized end, function(serialized) return serialized end}

-- each value in this dictionary follows this pattern:
-- {serializeFunction, deserializeFunction}
local TYPES = {
	string = primitiveType,
	boolean = primitiveType,
	number = primitiveType,

	-- api dump types
	int = primitiveType,
	int64 = primitiveType,
	float = primitiveType,
	double = primitiveType,
	bool = primitiveType,

	Content = primitiveType,

	-- converts NumberRange to a simple array {min, max}
	NumberRange = {function(d)
		return {d.Min, d.Max}
	end,
	function(s)
		return NumberRange.new(s[1], s[2])
	end,
	},

	-- converts a Vector3 to an array {x, y, z}
	Vector3 = {function(d)
		return {d.X, d.Y, d.Z}
	end,
	function(s)
		return Vector3.new(table.unpack(s))
	end},

	-- CFrame <-> 12-number component array (cframe:GetComponents())
	CFrame = {function(d)
		return {d:GetComponents()}
	end,
	function(s)
		return CFrame.new(table.unpack(s))
	end,
	},

	-- each BrickColor has a name so it is just stored as a string
	BrickColor = {function(d)
		return tostring(d)
	end,
	function(s)
		return BrickColor.new(s)
	end,
	},

	-- converts Color3 to an array {r, g, b}
	Color3 = {function(d)
		return {d.R, d.G, d.B}
	end,
	function(s)
		return Color3.new(table.unpack(s))
	end,
	},

	Vector2 = {function(d)
		return {d.X, d.Y}
	end,
	function(s)
		return Vector2.new(table.unpack(s))
	end,
	},

	-- enums are stored as strings ex: "Enum.Material.Plastic"
	Enum = {function(d)
		return tostring(d)
	end,
	function(s)
		local split = string.split(s, ".")
		return Enum[split[2]][split[3]]
	end},

	-- this property might be nil sometimes (i figured this out after 3 hours of pain and suffering :skull:)
	PhysicalProperties = {function(d)
		return if d then {d.Density, d.Friction, d.Elasticity, d.FrictionWeight, d.ElasticityWeight} else nil
	end,
	function(s)
		return if s then PhysicalProperties.new(table.unpack(s)) else nil
	end,
	},

	-- NumberSequences can be stored by their keypoints
	NumberSequence = {function(d)
		local s = {}
		for i, v in pairs(d.Keypoints) do
			table.insert(s, {v.Time, v.Value, v.Envelope})
		end
		return s
	end,
	function(s)
		local d = {}
		for i, v in pairs(s) do
			table.insert(d, NumberSequenceKeypoint.new(v[1], v[2], v[3]))
		end
		return NumberSequence.new(d)
	end,},

	Font = {function(d)
		return {d.Family, tostring(d.Weight):split(".")[3], tostring(d.Style):split(".")[3]}
	end,
	function(s)
		return Font.new(s[1], Enum.FontWeight[s[2]], Enum.FontStyle[s[3]])
	end,},

	UDim2 = {function(d)
		return {d.X.Scale, d.X.Offset, d.Y.Scale, d.Y.Offset}
	end,
	function(s)
		return UDim2.new(s[1], s[2], s[3], s[4])
	end,},

	UDim = {function(d)
		return {d.Scale, d.Offset}
	end,
	function(s)
		return UDim.new(s[1], s[2])
	end,}
}

local IGNORE_PROPERTIES = {"Parent"} -- this property can be ignored because it is handled in another way

-- FUNCTIONS

-- helper functions to apply the irght transformation function for a specific type
local function serializeValue(value: any, vtype: string)
	local t = TYPES[vtype]
	if (not t) then warn("Unknown type "..tostring(vtype)) return value end
	return t[1](value)
end

local function deserializeValue(value: any, vtype: string)
	local t = TYPES[vtype]
	if (not t) then warn("Unknown type "..tostring(vtype)) return value end
	return t[2](value)
end

-- copies any table recursively
local function tableClone(tbl)
	local clone = table.clone(tbl)
	for i, v in pairs(clone) do
		if (type(v) == "table") then
			clone[i] = tableClone(v) -- recursive part
		end
	end
	return clone
end

-- copies any key of super that is not in dest (basically applies inheritance)
local function tableApplySuper(dest, super)
	for i, v in pairs(super) do
		if (dest[i] == nil) then
			dest[i] = tableClone(super[i])
		end
	end
end

-- fetches the latest Studio version, used in the api dump
local function getAPIVersion()
	local response = HttpService:GetAsync(API_CURRENT_VERSION_URL)
	return response
end

-- fetches the full JSON dump of the Roblox API
local function getAPIDumpRaw(v: string)
	local response = HttpService:GetAsync(string.format(API_DUMP_URL, v))
	apiDumpRaw = HttpService:JSONDecode(response)
end

-- loads all properties and its types of an instance using the raw api dump
local function loadProperties(instance)
	local properties = {}

	for i, p in pairs(instance.Members) do
		if (p.MemberType == "Property") then
			-- this skips properties that are read only, not scriptable), or deprecated
			if (p.Tags and (table.find(p.Tags, "ReadOnly") or table.find(p.Tags, "NotScriptable") or table.find(p.Tags, "Deprecated"))) then
				continue
			end

			-- no need to serialize those properties since it is not possible to read or write them
			if (p.Security.Read ~= "None" or p.Security.Write ~= "None") then
				continue
			end
			
			-- self explanatory, ignores properties in IGNORE_PROPERTIES
			if (table.find(IGNORE_PROPERTIES, p.Name)) then
				continue
			end

			if (p.ValueType.Category == "Enum") then
				properties[p.Name] = {"Enum"}  -- all enums have the same type "Enum"
			elseif (p.ValueType.Category == "Class") then
				properties[p.Name] = {"Instance"} -- instance reference properties, they are handled differently than other properties
			else
				properties[p.Name] = {p.ValueType.Name} -- any other type can be stored as its own name
			end
		end
	end

	if (instanceDefaults[instance.Superclass]) then  -- inherits properties from its parent class (example: Part inherits Anchored from BasePart)
		tableApplySuper(properties, instanceDefaults[instance.Superclass])
	end

	instanceDefaults[instance.Name] = properties
end

-- helper to check if we have already cached the default values for a class
local function areDefaultsLoaded(instanceType: string): boolean
	return instanceDefaults[instanceType].Name and instanceDefaults[instanceType].Name[2]
end

-- creates a temporary instance to see what its default property values are
-- this allows us to only save properties the user has changed, saving massive amounts of space, but maybe increasing the serialization time a little bit
local function loadDefaults(instanceType: string)
	if (areDefaultsLoaded(instanceType)) then return end

	local instance = Instance.new(instanceType)

	-- stores the default values of the instance properties so it does not store them on serialization (storage optimization)
	for name, p in pairs(instanceDefaults[instanceType]) do
		p[2] = instance[name]
	end
	instance:Destroy() -- destroy the instance so we don't leak any memory
end

-- processing loop for the API Dump
local function processAPIDump()
	for i, v in pairs(apiDumpRaw.Classes) do
		if (v.Tags and (table.find(v.Tags, "Service"))) then -- since this API dump returns basically every instance in Roblox, it is important to ignore services
			continue
		end

		if (not v.Tags or not table.find(v.Tags, "NotCreatable")) then -- this ignores non creatable instances (the reason is very obvious)
			table.insert(instanceableInstances, v.Name)
		end

		loadProperties(v)
	end
end

-- converts a single Instance into a serialized table
local function serializeInstance(instance: Instance)
	local instanceType = instance.ClassName
	if (not table.find(instanceableInstances, instanceType)) then return nil end
	local serialized = {Type = instanceType, Properties = {}}
	
	-- only loads defaults for instances that need to be serialized
	if (not areDefaultsLoaded(instanceType)) then
		loadDefaults(instanceType) 
	end

	for property, value in pairs(instanceDefaults[instanceType]) do
		-- if the instance has a property with its default value and that is not an instance reference, don't store it
		if (value[2] ~= instance[property] and value[1] ~= "Instance") then
			serialized.Properties[property] = serializeValue(instance[property], value[1])
		end
	end

	-- handle CollectionService tags
	local tags = instance:GetTags()
	if (#tags > 0) then -- don't bother storing tags for an instance that does not have any
		serialized.Tags = tags
	end

	-- handle Attributes
	local attributes = instance:GetAttributes()
	if (next(attributes)) then  -- checks if there are any attributes (#attributes doesn't work since this is a dictionary)
		serialized.Attributes = {}
		for i, a in pairs(attributes) do
			local t = typeof(a) -- attributes can't have instance references so typeof works well
			serialized.Attributes[i] = {t, serializeValue(a, t)}
		end
	end

	return serialized
end

-- serializes the object children recursively
local function serializeInstanceRecursive(instance: Instance, id: number, lookup)
	id = id or 1
	local serialized = serializeInstance(instance)
	if (not serialized) then return nil, id end

	serialized.Id = id -- assigns a unique id to each instance (for referencing purposes)
	lookup[instance] = serialized -- map the real Instance to the lookup table
	id += 1

	local children = instance:GetChildren()
	if (#children > 0) then  -- don't bother storing children for instances without any
		serialized.Children = {}
		for i, v in pairs(children) do
			local childSerialized, newId = serializeInstanceRecursive(v, id, lookup)
			if (childSerialized) then
				table.insert(serialized.Children, childSerialized)
				id = newId -- keeps track of the ids that are being assigned to instances
			end
		end
	end
	return serialized, id
end

-- we can't save a real object in JSON so instead, we save the unique id of the target object so we can relink it during deserialization
local function serializeInstanceProperties(lookup, ancestor: Instance)
	-- this serializes all of the instance reference properties
	for i, s in pairs(lookup) do
		for p, v in pairs(instanceDefaults[s.Type]) do
			if (v[1] == "Instance") then
				local target = i[p]
				if (target) then
					local ss = lookup[target]
					if (ss) then
						s.Properties[p] = ss.Id -- store the id of the target
					end
				end
			end
		end
	end
end

-- reconstructs a single Instance from a serialized table
local function deserializeInstance(serialized: {[any]: any}): Instance
	local instanceType = serialized.Type
	if (not table.find(instanceableInstances, instanceType)) then return nil end
	local instance = Instance.new(instanceType)

	for property, value in pairs(serialized.Properties) do
		local default = instanceDefaults[instanceType][property] -- finds the default for that property
		if (default and default[1] ~= "Instance") then
			instance[property] = deserializeValue(value, default[1]) -- changes all properties that are not instance references (this will be done later, after everything is created)
		end
	end

	if (serialized.Tags) then
		for i, tag in pairs(serialized.Tags) do
			instance:AddTag(tag)
		end
	end

	if (serialized.Attributes) then
		for attribute, value in pairs(serialized.Attributes) do
			instance:SetAttribute(attribute, deserializeValue(value[2], value[1]))
		end
	end

	return instance
end

-- recursively builds the object tree and sets parents
local function deserializeInstanceRecursive(serialized: {[any]: any}, parent: Instance, lookup): Instance
	local instance = deserializeInstance(serialized)
	if (not instance) then return nil end
	lookup[serialized.Id] = {instance, serialized}  -- to be used later for instance reference deserialization

	if (parent) then
		instance.Parent = parent  -- sets the correct parent for this instance
	end

	if (serialized.Children) then
		for i, child in pairs(serialized.Children) do
			deserializeInstanceRecursive(child, instance, lookup)
		end
	end

	return instance
end

-- final pass: now that all instances exist, we go back and set properties that refer to other instances
local function deserializeInstanceProperties(lookup)
	for i, v in pairs(lookup) do
		local instance = v[1]
		local serialized = v[2]

		for p, value in pairs(serialized.Properties) do
			local default = instanceDefaults[serialized.Type][p]
			if (default and default[1] == "Instance") then  -- filters instance reference properties
				local target = lookup[value] -- look up the instance by the id that was stored
				if (target) then
					instance[p] = target[1] -- sets the correct instance references after every instance is created
				end
			end
		end
	end
end


-- PUBLIC API
local Serial = {}

-- must be called once to prepare the system
function Serial.GetLatestAPIDump()
	local apiVersion = getAPIVersion()
	getAPIDumpRaw(apiVersion)
	processAPIDump()

	apiDumpRaw = nil -- free memory, apiDumpRaw is useless after being processed
end

-- TODO
--[[function Serial.LoadCachedDefaults()
	
end]]

-- Takes an instance and serializes its properties into a table
function Serial.SerializeInstance(instance: Instance): {[any]: any}
	assert(typeof(instance) == "Instance", "Invalid instance")
	local lookup = {}
	local serialized, _ = serializeInstanceRecursive(instance, 1, lookup)
	serializeInstanceProperties(lookup, instance)

	return serialized
end

-- Deserializes a table and parents it to an instance, if one is given
function Serial.DeserializeInstance(serialized: {[any]: any}, parent: Instance?): Instance
	local lookup = {}
	local instance = deserializeInstanceRecursive(serialized, nil, lookup)
	deserializeInstanceProperties(lookup)
	if (parent) then
		instance.Parent = parent  -- after everything is done, set the correct parent
	end

	return instance
end


return Serial
