
--[[
Howdy application readers, I have fully reorganized my system to be fully compliant with the feedback I got on my last application. 
- No nested functions
- Guards at every point necessary, such as every use of FindFirstChild() and GetChildren()
- And, the biggest change, I cut the clutter out of my functions as was recommended in the last application; the big functions have been divided into smaller functions, readability is much improved.
- ^Moreover, repetitive functionality from before (like multiple parts of the script referencing attributes), have been converted to centralized functions.

Once more, ty lots for your continued time reading and providing feedback to help me improve my structure!
]]

-- Import necessary services at the top
local PathfindingService = game:GetService("PathfindingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")

local PetMovementReplication = require(ReplicatedStorage.Modules.PetMovementReplication)  -- This will be essential later in order to have the server's manual CFrame overriding be matched by smoother methods on the client 

-- Constants
local BASEBEHINDDISTANCE = 6 -- Fixed distance that the first spawned pet will always stay behind the player
local BEHINDDISTANCEINTERVAL = 6 -- The fixed *added* distance between subsequent pets behind the next in line
local PETATTACKCOOLDOWN = 12 -- Yield time before attacks can be called to prevent multiple pathfinding commands sent at a time
local BASEDAMAGE = 0.25 -- This is the damage per pet bounce in an attack; basically, this is a small value because it is called with every time during the petAttackScene that the pets jump on the target
local MAXATTACKDISTANCE = 35 --This is the max a player can click with the pet attack tool, otherwise send the missedNotification 
local MAXPETS = 6 -- Max amount of total pets a player can have in their folder (ergo, present in the workspace) at any given time

-- Notification messages for the client UI to show in certain conditions, these are called back to below.
local missedNotification = "You clicked too far! Try again :D" -- Send this notification in accordance with the MAXATTACKDISTANCE comment conditions.
local inOwnCircleNotification = "Get out of your own attack zone, silly!!!" -- Send this notification if a player has.. for some reason.. stepped into their own petAttackScene; they are not damage prone, but thought it was a nice touch.


local function newEvent(name) -- New function added during reorganization to avoid repetitive Instance.new()'s.
	if not name then return end -- Another guard I made sure to add, since if the name wasn't passed this wouldn't execute right
	local event = Instance.new("RemoteEvent",ReplicatedStorage)
	event.Name=name 
	return event -- Send the event back in instance form
end 

local petClickedEvent = newEvent("PetClicked") -- This will be the communicator for when a player clicks on a pet in their UI to spawn it, handling the next parts here on the server.

local notify = newEvent("Notify")-- This will be used to send notifications (defined above) to the client, to display as text in their UI- my attempt to make this experience more beginner friendly and easy to pick up.

local getMouseHit = Instance.new("RemoteFunction")
getMouseHit.Name = "GetMouseHit" -- This will be used throughout the system to invoke a player's mouse.hit, returning it as a vector3 and having the client filter out some things.
getMouseHit.Parent = ReplicatedStorage

local AttackIndicator = ReplicatedStorage:WaitForChild("AttackIndicator") -- All the effects for the AttackIndicator; the circle, the sparks, and the angry dog icon. 


function GetTouchingParts(part)
	local connection = part.Touched:Connect(function() end)
	local results = part:GetTouchingParts()
	connection:Disconnect() -- Disconnecting so I don't end up with a new lingering connection each time its called.
	return results -- Return all of the results that were touched, filtering through them and assigning damage will is done in following functions.
end


function createPathAndGetWaypoints(player, startPosition, endPosition) -- Function for whenever PathfindingService:CreatePath is needed
	local path = PathfindingService:CreatePath({
		AgentCanJump = true,
		AgentRadius = 1.5,
		AgentHeight = 5,
		AgentCanWalkOnWater = false,
		WaypointSpacing = .5
	}) -- Path settings, lower waypoint spacing for smooth close-range following of the pets' host player.
	path:ComputeAsync(startPosition, endPosition)
	return path:GetWaypoints()  -- Compute the path/waypoints here and return them for easy auto path generation without having to type this out every time
end

function getOrCreatePetsFolder(player)
	local folder = workspace:FindFirstChild(player.Name .. "Pets") -- Attempt to find an existing pet folder
	if not folder then -- If it is not found, take care of creating it here to avoid erroring
		folder = Instance.new("Folder", workspace)
		folder.Name = player.Name .. "Pets" -- Of course, the naming format we use across all the scripts for the player's pet folders
	end
	return folder -- Return the folder instance, be it the one that was found or created in absence of one.
end

function petJumpHandler(petObject, centerPoint, jumpHeight, duration) -- Handles the jumping portion of pet attack
    local petJumpingInfo = TweenInfo.new(duration, Enum.EasingStyle.Quad) 
    local goalPosition = Vector3.new(centerPoint.X, petObject.Position.Y + jumpHeight, centerPoint.Z) -- Pretty basic positioning, using the center of the attack object plus a Y put together of the pet's current elevation as well as our custom jumpHeight. 
    local tweenJump = TweenService:Create(petObject, petJumpingInfo, {Position=goalPosition})
    tweenJump:Play() -- Play the jump, sending the pet to bounce on the specified goalPosition before the petLandHandler logic.
    tweenJump.Completed:Wait() -- Play the jumping for the passed petObject, and await its completion before having it do another action.
end

function petLandHandler(petObject, originalPosition, duration)-- Handles the landing portion of pet attack
    local petLandingInfo = TweenInfo.new(duration) -- Simpler settings to make the landing more linear than stylish.
    local goalPosition = Vector3.new(originalPosition.X, originalPosition.Y, originalPosition.Z)
    local tweenLand = TweenService:Create(petObject, petLandingInfo, {Position=goalPosition})
    tweenLand:Play()
    tweenLand.Completed:Wait() -- Let the pet know to do the landing tween, then await completion before doing another iteration on the pet.
end

function notifyInCircle(player) -- separate notify functions for script cleanliness
	notify:FireClient(player, inOwnCircleNotification) -- Send the "Get out of your own attack zone, silly!!!" message to the respective player
end

function handleTouchResults(player,touchingParts)
	for _, part in pairs(touchingParts) do
                local character = part:FindFirstAncestorWhichIsA("Model") -- Find character using FindFirstAncestor to account for accessories offsetting the hierarchy
				if not character then return end -- If the character check failed, stopping here to prevent errors
                if character == player.Character then
                    notifyInCircle(player) -- Function call to send the "Get out of your own attack zone, silly!!!" notification to the passed player's client UI.
                    continue -- Using continue so that the player jumping in their own loop doesn't at all interact with the rest of the hit detection 
                end
                local humanoid = character:FindFirstChildWhichIsA("Humanoid")
                if humanoid then -- Check that the humanoid was found to avoid errors
                    humanoid:TakeDamage(BASEDAMAGE) -- Issue the damage to the detected humanoid if it made it this far
                end
            end
end

function randomAttackYield()
	local randTimeOffset=math.random()*.85
    task.wait(0.5 + randTimeOffset) -- Added this bit here to make for a little randomness in attack order and frequency- making it so all pets arent bouncing on target simultaneously.
end

function handleAttackSceneJumping(player, indicator, petObject, centerPoint) -- The central handler for jumping during the pet attack 
    local originalPosition = petObject.Position -- Stamp tighhe position in which the pet starts the sequence
    local numBounces = 6 -- Customizable total # of bounces
    local jumpHeight = 5 -- How high above the centerpoint the pets jump
    local jumpDuration = 0.2 
    local landDuration = 0.1

    for i = 1, numBounces do 
        petJumpHandler(petObject, centerPoint, jumpHeight, jumpDuration) -- Half of the tweening, handles the jumps
        petLandHandler(petObject, originalPosition, landDuration) -- Other half, handles the landings.. and then rinse and repeat

        task.wait(0.15)
        local hitbox = indicator:FindFirstChild("Hitbox") -- Pre-created asset into the game
        if hitbox then -- Double check if it was actually found
            local touchingParts = GetTouchingParts(hitbox) -- Fetch the touching parts using the previously established function
            handleTouchResults(player,touchingParts) -- Proceed with the hit detection logic here, including dealing damage
        end

        task.wait(jumpDuration+landDuration+.025) -- Not the same as the random yield, this is a fixed cooldown to await them landing and resting for a moment.
		randomAttackYield() -- Slightly randomized timing, more description in the function
		end
end

function petAttackScene(player, centerPoint, petFolder, indicator)
	if player:GetAttribute("AttackScene") then return end -- Do not proceed if the player is detected to already be attacking
	player:SetAttribute("AttackScene", true) -- If passed, set the attribute to true so they cannot stack attacks at once
	local activePets = petFolder:GetChildren() 
	if not activePets or #activePets == 0 then return end -- Yet another guard, if no pets then don't continue with attack- would be pointless.
	local checkForAttackingParticle = indicator:FindFirstChild("AttackingParticle", true) -- See if the sparks particle exists
	if checkForAttackingParticle then checkForAttackingParticle.Enabled = true end -- If found, enable the particle
	
	for _, petObject in pairs(activePets) do
		petObject.CanCollide = false -- Disable CanCollide, only temporarily, so the pets do not whack each other.
		task.spawn(handleAttackSceneJumping, player, indicator, petObject, centerPoint) -- Calls the manager function for all the tweening of the attack scene
	end
end

function clearAttackAttributes(player)
	player:SetAttribute("AttackScene", nil)
	player:SetAttribute("PetsAttacking", nil) -- Clear the attack related attributes representing the different stages, called once the cooldown has passed and a player is fully good to attack once more.
end

function handleAttackCooldown(player, effect, petsFolder)
	if not petsFolder then return end -- If no pets folder, don't continue- means the player has left 
	task.wait(PETATTACKCOOLDOWN)-- Await the total PETATTACKCOOLDOWN
	clearAttackAttributes(player)-- Set related attributes used to track the status to nil, allowing player to attack as normal after.
	effect:Destroy()-- Clear the effect from the completed attack
	for _, pet in pairs(petsFolder:GetChildren()) do 
		pet.CanCollide = true-- Re-enabling collisions from when I turned them off for the pet attack scene (more info on that in the function)
	end
end

function attackSceneUponArrival(player, petObject, x_offset, z_offset, i, numPets, mouseHit, petsFolder, effect, waypoints)-- Ensures the pets are in uniform position around the circle / attack effect before going to the scene.
	for _, waypoint in pairs(waypoints) do-- Iterate through the waypoints, with a check on the next line
		if not player.Character or not player.Character.PrimaryPart then break end-- Do not continue if the corresponding player has no character

		local targetCFrame = CFrame.new(waypoint.Position + Vector3.new(x_offset, 0, z_offset)) -- Use the offsets to form where the pet needs to end in this iteration on the server
		petObject.CFrame = targetCFrame -- Set the CFrame to above ^
		petObject:SetAttribute("OP", targetCFrame.Position) --- Set this attribute, short for OriginalPosition, letting the pet know the position outside the ring to return to during the attackScene when they jump.
		RunService.Heartbeat:Wait() 
	end

	if i == numPets then -- Detect if all pets have made it
		petAttackScene(player, mouseHit, petsFolder, effect) -- If they have, take the attacking to the next stage. 
	end
end

function calculateCircle(i,numPets)
	local angle = (i - 1) * (2 * math.pi / numPets)-- Angle around the circle effect
	local xOffset = 5 * math.cos(angle)--X offset generated using cosine, the angle, and a defined radius that may need to be adjusted as I enlarge the circle effect.
	local zOffset = 5 * math.sin(angle)-- Z offset,similar logic but with sine- same pre-determined radius.

	return xOffset,zOffset -- Return both values needed, angle was only needed for calculating them,+
end

function createPetAttack(player, mouseHit)
	if player:GetAttribute("PetsAttacking") then return end--- Detect if the base attribute for both attackScene and this function is ticked; if it is, prevent the player stack attack commands by returning.
	player:SetAttribute("PetsAttacking", true)-- Following^, set the attribute to enable the return above.
	local effect = AttackIndicator:Clone()-- This is the ring effect, the circle is placed to mark the attack and the pets then revolve around it.
	effect.Position = mouseHit
	effect.Parent = workspace

	local petsFolder = getOrCreatePetsFolder(player)-- Find the player's pet folder or worst case create it
	local checkHasPets = petsFolder:GetChildren()
	if not checkHasPets or #checkHasPets == 0 then return end
	local numPets = #checkHasPets -- Total # of pets the player currently has in their workspace folder

	for i, petObject in pairs(checkHasPets) do 
		
		local xOffset,zOffset = calculateCircle(i,numPets) -- Use the calculateCircle function to get the circular formation for the pets to abide by
		local waypoints = createPathAndGetWaypoints(player, petObject.Position, mouseHit + Vector3.new(xOffset, 0, zOffset)) -- Use the waypoint function to create, compute, and return all waypoints
		task.spawn(attackSceneUponArrival, player, petObject, xOffset, zOffset, i, numPets, mouseHit, petsFolder, effect, waypoints) -- Next, using the waypoints, call the arrival function to let it know the pets are in the circle

		if #waypoints > 0 then -- Check that there are waypoints to iterate through
			task.spawn(handleAttackCooldown, effect, petsFolder) -- Await the cooldown before re-enabling everything
		end
	end 
end

function callTheAttack(player)
	local hit = getMouseHitForPlayer(player) -- Use the getMouseHit function for getting the position, for the distance check
	local character = player.Character  
	if not character then return end -- If no character, don't continue
	if (hit - character.PrimaryPart.Position).Magnitude < MAXATTACKDISTANCE then  -- Distance check
		createPetAttack(player, hit) -- If it was close enough, proceed with the attack
	else 
		notifyMissedAttack(player) -- Call the notifyMissedAttack which will send a message to the player via a UI telling them they need to click closer
	end
end

function moveThroughFollowingWaypoints(player,petObject,waypoints)
	if #waypoints > 0 then -- A check to make sure the waypoints actually exist
			for _, waypoint in pairs(waypoints) do-- Iterate through the waypoints
				if not player.Character or not player.Character.PrimaryPart then break end-- Break it completely if the player died in the process or something else happened to their character.
				local currentCFrame = petObject.CFrame -- Holding the current CFrame
				local root = player.Character.HumanoidRootPart
				local look = Vector3.new(root.Position.X, petObject.Position.Y, root.Position.Z)-- Calculate where the pet should look, limiting it to certain orientation axis'.
				local targetCFrame = CFrame.new(waypoint.Position, look)-- Initilalize where the pet  needs to end this waypoint travel
				local stepCFrame = currentCFrame:Lerp(targetCFrame, .1) -- Lerp, so even the server has a degree of smoothness before the client does the rest.
				petObject.CFrame = stepCFrame-- Directly set it^
			end
		end
end

function followingMoveDirChanged(player, petObject) -- Called whenever humanoid.MoveDirection is changed, more documentation on this connection below
	if player:GetAttribute("PetsAttacking") then return end  -- Ensure that, initially, the pets are NOT in any level of the attack sequence
	local value = player.Character.Humanoid.MoveDirection -- Vector3 direction in which the character is moving
	while player.Character.Humanoid.MoveDirection == value and not player:GetAttribute("PetsAttacking") do-- While the player is moving in the initial direction, and have not called an attack, loop through their movement
		local waypoints = createPathAndGetWaypoints(player, petObject.Position, (player.Character.PrimaryPart.CFrame * CFrame.new(0, 0, petObject:GetAttribute("BehindDistance"))).Position)
		task.spawn(moveThroughFollowingWaypoints,player,petObject,waypoints) -- Call the moveThroughFollowingWaypoints to go about moving the pets using the waypoints we calculated above.
		RunService.Heartbeat:Wait() 
	end
end

function handlePlayerTool(player)
	local character = ensureCharacterAndHumanoid(player)-- This is relevant for the comment below, using another function to get the character
	if not character then return end -- Do not continue if no character, prevent issues
	local tool = player.Backpack:WaitForChild("Click To Make Pets Attack") -- Yield until the player actually has the tool to prevent an error
	tool.Activated:Connect(function()-- Listen for when the player is attempting to command an attack, proceed in callTheAttack() function to avoid nested funcs.
		callTheAttack(player) -- Move forward with attack logic, separate function for organization and bridging across the different stages and checks.
	end)
end

function sendMovementUpdate(player, petObject)
	PetMovementReplication.server:sendUpdate(petObject.Name, player.Name .. "Pets", petObject.CFrame) -- Send an update through the replication module where the client physics will be handled in accordance with the new positioning
end

function initialMovementUpdate(player, petObject) 
	sendMovementUpdate(player, petObject)
	petObject:GetPropertyChangedSignal("CFrame"):Connect(function() sendMovementUpdate(player, petObject) end) -- Connecting the property changed of each pet's cframe and links it to the replication module which then takes care of visually updating the cframes on the client
end 

function getMouseHitForPlayer(player) -- Centralized function for getting player mouse hit from client
	return getMouseHit:InvokeClient(player) -- Get the player's mouse.hit from their client, this is setup to be returned as a Vector3 and filter out instances like the player's character and other invalids.
end


function notifyMissedAttack(player)
	notify:FireClient(player, missedNotification)-- Send the missedNotification text to the player's UI through the already-coded notifications!
end

function canPlayerSpawnPet(player, hit)
	return (hit - player.Character.PrimaryPart.Position).Magnitude <= MAXATTACKDISTANCE -- Separate function for determing if the player has clicked too far from what is allowed (as specified by MAXATTACKDISTANCE)
end


function setAttributeWithDefault(player, attributeName, defaultValue)
	local value = player:GetAttribute(attributeName) -- As described more in the next comment, check to see if the attribute exists.
	if not value then
		value = defaultValue -- Set the default if no attribute by the name currently exists 
		player:SetAttribute(attributeName, value) -- Added this function for centralization of initial attribute setting, rather than having to type the bulk each time.
	end
	return value 
end

function handlePlayerAdded(player) -- Called when a player joins, connection at the bottom of script
	task.spawn(handlePlayerTool, player) -- Initialize the tool handling in the context of pets- specifically this handles the "Click To Make Pets Attack" tool, detecting it being activated and then signaling the attack if it meets the conditions.
end

function followPath(player, petObject)
	local character, humanoid = ensureCharacterAndHumanoid(player)
	if not character  then return end -- Guard: if the character doesn't exist then do not continue with path following logic, it would only bug out.
	if humanoid.MoveDirection ~= Vector3.new(0, 0, 0) then -- Check to ensure the humanoid isn't static
		followingMoveDirChanged(player, petObject) -- Initially call the function descriped more below, so we can tell the pets to update their position based on following logic from the beginning
	end
	humanoid:GetPropertyChangedSignal("MoveDirection"):Connect(function() followingMoveDirChanged(player, petObject) end) -- Using GetPropertyChangedSignal to listen for whenever the player starts moving, then signal for the pets to follow
end

function ensureCharacterAndHumanoid(player)
	local character = player.Character or player.CharacterAdded:Wait() -- Check humanoid, but yield if it is not there so the player functions as normal
	return character, character:WaitForChild("Humanoid") -- Return both the character and humanoid, as is promised in the function name!
end

function placedPet(player,clonedPetPart, hit)
	local getPlayerPetsFolder = getOrCreatePetsFolder(player) -- Use this function to find, or create, a pet folder for the player
	clonedPetPart.Position = hit -- Spawn the pet where the player clicked, as per the UI
	clonedPetPart.Transparency = 1 -- Important: server instances are invisible, since PetMovementReplication uses their own client instances for smooth physics replication.
	clonedPetPart.Parent = getPlayerPetsFolder

	initialMovementUpdate(clonedPetPart.Parent, clonedPetPart)-- More documentation within the function, but it listens for the pets CFrame being changed to smoothly replicate the physics. 
	task.spawn(followPath, player, clonedPetPart) -- Initialize the following system to have pets follow the player when appropriate to do so
end

local function updateBehindDistance(player,behindDistance)
	player:SetAttribute("BehindDistance", behindDistance + BEHINDDISTANCEINTERVAL)-- Add to the distance attribute so that the pets continue following the player in single file line, going more and more behind as pets are spawned.
end 

function clonePet(clonedPetPart, player, hit) -- Time to clone the pet and get it in the 3D space.
	local newRandomName = "Pet_" .. player.Name .. "_" .. os.time() .. clonedPetPart.Name -- Encoding the name here, using the time the player spawned it, so that even when a player spawns two of the identical pet, their names will be different.
	clonedPetPart.Name = newRandomName -- Assign the established name ^
	setAttributeWithDefault(player, "BehindDistance", BASEBEHINDDISTANCE) -- Initialize BehindDistance, used to track how far to keep pets behind their player

	local behindDistance = player:GetAttribute("BehindDistance") -- These lines take care of behindDistance, a value to let the player know how many studs on the Z that pets should be behind them.
	clonedPetPart:SetAttribute("BehindDistance", behindDistance)
	updateBehindDistance(player,behindDistance)
	placedPet(player,clonedPetPart, hit) -- Call after the clone is initialized, proceeds with following and replication logic from there
end

local function checkPlayerHasMaxPets(player) -- Separate function to check for the max pets being exceeded
local getPlayerPetsFolder = getOrCreatePetsFolder(player)
	local getPlayerPets = #(getPlayerPetsFolder:GetChildren())
	if getPlayerPets >= MAXPETS then -- If amount of pets is equal to or higher than what is allowed,
		return true  -- Return true if the player DOES have max pets spawned.
	end
	return nil -- Return nothing if the player DOESN'T have the maximum pets spawned, therefore able to spawn more.
end

function createAndSpawnPet(player, petName, hit) -- Middleman between spawning the pet, performs some checks like if the instance exists, and importantly if the player has already exceeded the max pets they are allowed.
	local petsSource = ReplicatedStorage:FindFirstChild("Pets")-- Reference the pets folder; not one of an individual player, but the one in ReplicatedStorage that sources the templates of all pets models.
	if not petsSource then return end -- If this is missing it means there are no pet source models, which should not happen, but must be accounted for for the system to work as visually intended.

	local petPart = petsSource:FindFirstChild(petName)-- From aforementioned source folder, get the matching pet template to be cloned for the server-side instance
	if not petPart then return end-- Do not continue if the FindFirstChild failed

	if checkPlayerHasMaxPets(player) then return end 
	local clonedPetPart = petPart:Clone() -- Clone the source
	clonePet(clonedPetPart, player, hit) -- If it passed through the conditions, time to actually physically clone the pet.
end

function onPetClicked(player,petName)
	local hit = getMouseHitForPlayer(player) -- Get the players mouse.hit as a Vector3 pos
	if not canPlayerSpawnPet(player, hit) then notifyMissedAttack(player) return end  -- If it doenst meet the eligiblity defined in canPlayerSpawnPet, stop here after sending the missed notification to their client.
	createAndSpawnPet(player, petName, hit) -- But, if all goes well, let the player spawn their desired pet where they have clicked!
end 

petClickedEvent.OnServerEvent:Connect(onPetClicked) -- Connection for when a player attempts to spawn in a pet
Players.PlayerAdded:Connect(handlePlayerAdded) -- Connection for handlePlayerAdded w/ new players
