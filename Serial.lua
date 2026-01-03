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
local apiDumpRaw = {}
local instanceDefaults = {}
-- table used to quickly check if a class can be instanced by a script
local instanceableInstances = {}

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
	
	NumberRange = {function(d)
		return {d.Min, d.Max}
	end,
	function(s)
		return NumberRange.new(s[1], s[2])
	end,
	},
	
	Vector3 = {function(d)
		return {d.X, d.Y, d.Z}
	end,
	function(s)
		return Vector3.new(table.unpack(s))
	end},
	
	CFrame = {function(d)
		return {d:GetComponents()}
	end,
	function(s)
		return CFrame.new(table.unpack(s))
	end,
	},
	
	BrickColor = {function(d)
		return tostring(d)
	end,
	function(s)
		return BrickColor.new(s)
	end,
	},
	
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

local IGNORE_PROPERTIES = {"Parent"} -- this property is handled in another way, so it must be ignored from the API dump



-- FUNCTIONS
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

-- UTIL Copies any table, recursive version included
local function tableClone(tbl)
	local clone = table.clone(tbl)
	
	for i, v in pairs(clone) do
		if (type(v) == "table") then
			clone[i] = tableClone(v)
		end
	end
	
	return clone
end

-- UTIL Copies any key of super that is not in dest (basically applies hierarchy)
local function tableApplySuper(dest, super)
	for i, v in pairs(super) do
		if (dest[i] == nil) then
			dest[i] = tableClone(super[i])
		end
	end
end

local function getAPIVersion()
	local response = HttpService:GetAsync(API_CURRENT_VERSION_URL)
	return response
end

local function getAPIDumpRaw(v: string)
	local response = HttpService:GetAsync(string.format(API_DUMP_URL, v))
	apiDumpRaw = HttpService:JSONDecode(response)
end

-- loads all properties and its types of an instance using the raw api dump
local function loadProperties(instance)
	local properties = {}
	
	for i, p in pairs(instance.Members) do
		if (p.MemberType == "Property") then
			if (p.Tags and (table.find(p.Tags, "ReadOnly") or table.find(p.Tags, "NotScriptable") or table.find(p.Tags, "Deprecated"))) then
				continue
			end
			-- no need to serialize those properties since it is not possible to read or write them
			if (p.Security.Read ~= "None" or p.Security.Write ~= "None") then
				continue
			end
			if (table.find(IGNORE_PROPERTIES, p.Name)) then
				continue
			end
			
			if (p.ValueType.Category == "Enum") then
				properties[p.Name] = {"Enum"} -- enums
			elseif (p.ValueType.Category == "Class") then
				properties[p.Name] = {"Instance"} -- instance reference properties, they are handled differently than other properties
			else
				properties[p.Name] = {p.ValueType.Name} -- other types
			end
		end
	end
	
	if (instanceDefaults[instance.Superclass]) then -- inherits properties from its parent class (example: Part inherits Anchored from BasePart)
		tableApplySuper(properties, instanceDefaults[instance.Superclass])
	end
	
	instanceDefaults[instance.Name] = properties
end

local function areDefaultsLoaded(instanceType: string): boolean
	return instanceDefaults[instanceType].Name and instanceDefaults[instanceType].Name[2]
end

local function loadDefaults(instanceType: string)
	if (areDefaultsLoaded(instanceType)) then return end

	local instance = Instance.new(instanceType)
	
	-- stores the default values of the instance properties so it does not store them on serialization (storage optimization)
	for name, p in pairs(instanceDefaults[instanceType]) do
		p[2] = instance[name]
	end
	instance:Destroy()
end

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

local function serializeInstance(instance: Instance)
	local instanceType = instance.ClassName
	if (not table.find(instanceableInstances, instanceType)) then return nil end
	local serialized = {Type = instanceType, Properties = {}}
	
	if (not areDefaultsLoaded(instanceType)) then
		loadDefaults(instanceType) -- only loads defaults for instances that need to be serialized
	end
	
	for property, value in pairs(instanceDefaults[instanceType]) do
		if (value[2] ~= instance[property] and value[1] ~= "Instance") then -- if the instance has a property with its default value, don't store it
			serialized.Properties[property] = serializeValue(instance[property], value[1])
		end
	end
	
	local tags = instance:GetTags()
	if (#tags > 0) then
		serialized.Tags = tags
	end
	
	local attributes = instance:GetAttributes()
	if (next(attributes)) then -- checks if there are any attributes (#attributes doesn't work since this is a dictionary)
		serialized.Attributes = {}
		for i, a in pairs(attributes) do
			local t = typeof(a) -- attributes can't have instance references so typeof works well
			serialized.Attributes[i] = {t, serializeValue(a, t)}
		end
	end
	
	return serialized
end

local function serializeInstanceRecursive(instance: Instance, id: number, lookup)
	id = id or 1
	local serialized = serializeInstance(instance)
	if (not serialized) then return nil, id end
	serialized.Id = id -- assigns a unique id to each instance (for referencing purposes)
	lookup[instance] = serialized
	id += 1
	
	local children = instance:GetChildren()
	if (#children > 0) then -- don't bother storing children for instances without any
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

local function serializeInstanceProperties(lookup, ancestor: Instance)
	-- this serializes all of the instance reference properties
	for i, s in pairs(lookup) do
		for p, v in pairs(instanceDefaults[s.Type]) do
			if (v[1] == "Instance") then
				local target = i[p]
				if (target) then
					local ss = lookup[target]
					if (ss) then
						s.Properties[p] = ss.Id
					end
				end
			end
		end
	end
end

local function deserializeInstance(serialized: {[any]: any}): Instance
	local instanceType = serialized.Type
	if (not table.find(instanceableInstances, instanceType)) then return nil end
	local instance = Instance.new(instanceType)
	
	for property, value in pairs(serialized.Properties) do
		local default = instanceDefaults[instanceType][property]
		if (default[1] ~= "Instance") then
			instance[property] = deserializeValue(value, default[1]) -- changes all properties that are not instance references (this will be done later, after everything is created)
		end
	end
	
	if (serialized.Tags) then
		for i, tag in pairs(serialized.Tags) do
			instance:AddTag(tag) -- sets tags
		end
	end
	
	if (serialized.Attributes) then
		for attribute, value in pairs(serialized.Attributes) do
			instance:SetAttribute(attribute, deserializeValue(value[2], value[1])) -- sets attributes
		end
	end
	
	return instance
end

local function deserializeInstanceRecursive(serialized: {[any]: any}, parent: Instance, lookup): Instance
	local instance = deserializeInstance(serialized)
	if (not instance) then return nil end
	lookup[serialized.Id] = {instance, serialized} -- to be used later for instance reference deserialization
	
	if (parent) then
		instance.Parent = parent -- sets the correct parent for this instance
	end
	
	if (serialized.Children) then
		for i, child in pairs(serialized.Children) do
			deserializeInstanceRecursive(child, instance, lookup)
		end
	end
	
	return instance
end

local function deserializeInstanceProperties(lookup)
	for i, v in pairs(lookup) do
		local instance = v[1]
		local serialized = v[2]
		
		for p, value in pairs(serialized.Properties) do
			local default = instanceDefaults[serialized.Type][p]
			if (default[1] == "Instance") then -- filters instance reference properties
				local target = lookup[value]
				if (target) then
					instance[p] = target[1] -- sets the correct instance references after every instance is created
				end
			end
		end
	end
end


-- API
local Serial = {}

function Serial.GetLatestAPIDump()
	local apiVersion = getAPIVersion()
	getAPIDumpRaw(apiVersion)
	processAPIDump()
	
	apiDumpRaw = nil -- apiDumpRaw is useless after being processed
end

-- TODO
--[[function Serial.LoadCachedDefaults()
	
end]]


-- Takes an instance and serializes its properties into a table
function Serial.SerializeInstance(instance: Instance): {[any]: any}
	assert(typeof(instance) == "Instance", "Invalid instance")
	local lookup = {}
	local serialized = serializeInstanceRecursive(instance, 1, lookup)
	serializeInstanceProperties(lookup, instance)
	
	return serialized
end

-- Deserializes a table and parents it to an instance, if one is given
function Serial.DeserializeInstance(serialized: {[any]: any}, parent: Instance?): Instance
	local lookup = {}
	local instance = deserializeInstanceRecursive(serialized, nil, lookup)
	deserializeInstanceProperties(lookup)
	if (parent) then
		instance.Parent = parent -- after everything is done, set the correct parent
	end
	
	return instance
end


return Serial