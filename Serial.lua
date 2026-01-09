--[[
Made by helioroqueargh (discord: maqagril)

This is an attempt of making a serialization module that requires no manual work in regards to setting up instances, but only in types.
It works by sending a request to an API Dump server, then parsing the result into a more comprehensible way, and storing every property
along with its type into instanceDefaults. Every time an instance is serialized, it checks if the defaults have been loaded, if not then it
proceeds to create a new instance of that same class, and storing the defaults into instanceDefaults, and then it proceeds to save only
those properties that have been modified.

I have made simple benchmarks of this module and it seems to be able to serialize around 110k instances per second, while deserializing
around 85k per second, on my computer of course.

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
local EncodingService = game:GetService("EncodingService")


-- VARIABLES
local apiDumpRaw = {} -- stores the raw JSON data from Roblox
local instanceDefaults = {} -- cached property names and default values for each class
local instanceableInstances = {} -- table used to quickly check if a class can be instanced by a script

-- any primitive type can be defined in this way as they don't need any transformation to be stored in json (serializer and deserializer)
local primitiveType = {function(deserialized) return deserialized end, function(serialized) return serialized end}

-- converts a buffer to a base 64 encoded string, we can't call buffer.tostring(b) directly because it cant be encoded to JSON
local function bToB64(b: buffer): string
	return buffer.tostring(EncodingService:Base64Encode(b))
end

-- converts a base 64 encoded string to a buffer
local function b64ToB(b64: string): buffer
	return EncodingService:Base64Decode(buffer.fromstring(b64))
end

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
	-- converts a boolean value to a number
	bool = {
		function(d)
			return if d then 1 else 0
		end,
		function(s)
			return s == 1
		end
	},

	Content = primitiveType,

	-- converts NumberRange to a buffer
	NumberRange = {
		function(d)
			local b = buffer.create(8)
			buffer.writef32(b, 0, d.Min)
			buffer.writef32(b, 4, d.Max)
			return bToB64(b)
		end,
		function(s)
			local b = b64ToB(s)
			return NumberRange.new(buffer.readf32(b, 0), buffer.readf32(b, 4))
		end
	},

	-- converts a Vector3 to a buffer
	Vector3 = {
		function(d)
			local b = buffer.create(12) -- X, Y, Z, each using 4 bytes = 12 bytes
			buffer.writef32(b, 0, d.X) -- first 4 bytes (0-3)
			buffer.writef32(b, 4, d.Y) -- the other 4 bytes (4-7)
			buffer.writef32(b, 8, d.Z) -- the last 4 bytes (8-11)
			return bToB64(b)
		end,
		function(s)
			local b = b64ToB(s)
			return Vector3.new(buffer.readf32(b, 0), buffer.readf32(b, 4), buffer.readf32(b, 8))
		end
	},

	-- CFrame <-> buffer
	CFrame = {
		function(d)
			local b = buffer.create(48)
			local x, y, z, R00, R01, R02, R10, R11, R12, R20, R21, R22 = d:GetComponents() -- GetComponents returns 12 values
			buffer.writef32(b, 0, x) -- store all 12 components into the buffer:
			buffer.writef32(b, 4, y)
			buffer.writef32(b, 8, z)
			buffer.writef32(b, 12, R00)
			buffer.writef32(b, 16, R01)
			buffer.writef32(b, 20, R02)
			buffer.writef32(b, 24, R10)
			buffer.writef32(b, 28, R11)
			buffer.writef32(b, 32, R12)
			buffer.writef32(b, 36, R20)
			buffer.writef32(b, 40, R21)
			buffer.writef32(b, 44, R22)
			return bToB64(b)
		end,
		function(s)
			local b = b64ToB(s)
			return CFrame.new(
				buffer.readf32(b, 0), buffer.readf32(b, 4), buffer.readf32(b, 8),
				buffer.readf32(b, 12), buffer.readf32(b, 16), buffer.readf32(b, 20),
				buffer.readf32(b, 24), buffer.readf32(b, 28), buffer.readf32(b, 32),
				buffer.readf32(b, 36), buffer.readf32(b, 40), buffer.readf32(b, 44)
			)
		end
	},

	-- each BrickColor has a name so it is just stored as a string
	BrickColor = {
		function(d)
			return tostring(d)
		end,
		function(s)
			return BrickColor.new(s)
		end,
	},

	-- converts Color3 to a 3 byte buffer
	Color3 = {
		function(d)
			local b = buffer.create(3)
			buffer.writeu8(b, 0, math.round(d.R*255))
			buffer.writeu8(b, 1, math.round(d.G*255))
			buffer.writeu8(b, 2, math.round(d.B*255))
			return bToB64(b)
		end,
		function(s)
			local b = b64ToB(s)
			return Color3.new(buffer.readu8(b, 0)/255, buffer.readu8(b, 1)/255, buffer.readu8(b, 2)/255)
		end
	},

	Vector2 = {
		function(d)
			local b = buffer.create(8)
			buffer.writef32(b, 0, d.X)
			buffer.writef32(b, 4, d.Y)
			return bToB64(b)
		end,
		function(s)
			local b = b64ToB(s)
			return Vector2.new(buffer.readf32(b, 0), buffer.readf32(b, 4))
		end
	},

	-- enums are stored as strings ex: "Enum.Material.Plastic"
	Enum = {
		function(d)
			return tostring(d)
		end,
		function(s)
			local split = string.split(s, ".")
			return Enum[split[2]][split[3]]
		end
	},
	
	-- converts a PhysicalProperties value to a buffer and vice versa
	PhysicalProperties = {
		function(d)
			if (not d) then -- this property might be nil sometimes (i figured this out after 3 hours of pain and suffering :skull:)
				return nil
			end
			local b = buffer.create(20)
			buffer.writef32(b, 0, d.Density)
			buffer.writef32(b, 4, d.Friction)
			buffer.writef32(b, 8, d.Elasticity)
			buffer.writef32(b, 12, d.FrictionWeight)
			buffer.writef32(b, 16, d.ElasticityWeight)
			return bToB64(b)
		end,
		function(s)
			if (not s) then
				return nil
			end
			local b = b64ToB(s)
			return PhysicalProperties.new(
				buffer.readf32(b, 0),
				buffer.readf32(b, 4),
				buffer.readf32(b, 8),
				buffer.readf32(b, 12),
				buffer.readf32(b, 16)
			)
		end
	},

	-- NumberSequences can be stored by their keypoints
	NumberSequence = {
		function(d)
			local kp = d.Keypoints
			local count = #kp
			local size = 4 + (count * 12) -- 4 bytes for count, 12 bytes per keypoint
			local b = buffer.create(size)

			buffer.writeu32(b, 0, count)

			local offset = 4
			for i, v in ipairs(kp) do -- store each keypoint in the buffer
				local v = v.Value
				buffer.writef32(b, offset, v.Time)
				buffer.writef32(b, offset + 4, v.Value)
				buffer.writef32(b, offset + 8, v.Envelope)
				offset += 12
			end
			return bToB64(b)
		end,
		function(s)
			local b = b64ToB(s)
			local count = buffer.readu32(b, 0) -- the first 4 bytes are used for counting
			local keypoints = table.create(count)

			local offset = 4
			for i = 1, count do
				local t = buffer.readf32(b, offset)
				local v = buffer.readf32(b, offset + 4)
				local e = buffer.readf32(b, offset + 8)
				table.insert(keypoints, NumberSequenceKeypoint.new(t, v, e))
				offset += 12
			end
			return NumberSequence.new(keypoints)
		end
	},
	
	-- there isn't really a better way to store a font other than a table
	Font = {
		function(d)
			return {d.Family, tostring(d.Weight):split(".")[3], tostring(d.Style):split(".")[3]}
		end,
		function(s)
			return Font.new(s[1], Enum.FontWeight[s[2]], Enum.FontStyle[s[3]])
		end,
	},
	
	-- converts a UDim2 to a buffer and vice versa
	UDim2 = {
		function(d)
			local b = buffer.create(16)
			buffer.writef32(b, 0, d.X.Scale)
			buffer.writef32(b, 4, d.X.Offset)
			buffer.writef32(b, 8, d.Y.Scale)
			buffer.writef32(b, 12, d.Y.Offset)
			return bToB64(b)
		end,
		function(s)
			local b = b64ToB(s)
			return UDim2.new(buffer.readf32(b, 0), buffer.readf32(b, 4),  buffer.readf32(b, 8), buffer.readf32(b, 12))
		end
	},

	UDim = {
		function(d)
			local b = buffer.create(8)
			buffer.writef32(b, 0, d.Scale)
			buffer.writef32(b, 4, d.Offset)
			return bToB64(b)
		end,
		function(s)
			local b = b64ToB(s)
			return UDim.new(buffer.readf32(b, 0), buffer.readf32(b, 4))
		end
	}
}

local IGNORE_PROPERTIES = {"Parent"} -- this property can be ignored because it is handled in another way

-- FUNCTIONS

-- helper functions to apply the irght transformation function for a specific type
local function serializeValue(value: any, vtype: string): any
	local t = TYPES[vtype]
	if (not t) then warn("Unknown type "..tostring(vtype)) return value end
	return t[1](value)
end

local function deserializeValue(value: any, vtype: string): any
	local t = TYPES[vtype]
	if (not t) then warn("Unknown type "..tostring(vtype)) return value end
	return t[2](value)
end

-- copies any table recursively
local function tableClone(tbl: {[any]: any}): {[any]: any}
	local clone = table.clone(tbl)
	for i, v in pairs(clone) do
		if (type(v) == "table") then
			clone[i] = tableClone(v) -- recursive part
		end
	end
	return clone
end

-- copies any key of super that is not in dest (basically applies inheritance)
local function tableApplySuper(dest: {[any]: any}, super: {[any]: any}): {[any]: any}
	for i, v in pairs(super) do
		if (dest[i] == nil) then
			dest[i] = tableClone(super[i])
		end
	end
end

-- fetches the latest Studio version, used in the api dump
local function getAPIVersion(): string
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
local function serializeInstance(instance: Instance): {[any]: any}
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
local function serializeInstanceRecursive(instance: Instance, id: number, lookup: {[any]: any}): ({[any]: any}, number)
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
local function serializeInstanceProperties(lookup: {[any]: any}, ancestor: Instance)
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
local function deserializeInstanceProperties(lookup: {[any]: any})
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

-- Must be called once to prepare the system
function Serial.GetLatestAPIDump()
	local apiVersion = getAPIVersion()
	getAPIDumpRaw(apiVersion)
	processAPIDump()

	apiDumpRaw = nil -- free memory, apiDumpRaw is useless after being processed
end

-- Loads cached api dump
function Serial.LoadCachedDump()
	local cachedAPIDump = script:FindFirstChild("CachedAPIDump")
	assert(cachedAPIDump, "Could not find cached api dump")
	
	cachedAPIDump = require(cachedAPIDump)
	instanceableInstances = cachedAPIDump["instanceableInstances"]
	instanceDefaults = cachedAPIDump["instanceDefaults"]
end

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
