-- Import necessary services at the top
local PathfindingService = game:GetService("PathfindingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")

local PetMovementReplication = require(ReplicatedStorage.Modules.PetMovementReplication) -- This will be essential later in order to have the server's manual CFrame overriding be matched by smoother methods on the client 

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

-- Create RemoteEvents and RemoteFunctions
local petClickedEvent = Instance.new("RemoteEvent")
petClickedEvent.Name = "PetClicked" -- This will be the communicator for when a player clicks on a pet in their UI to spawn it, handling the next parts here on the server.
petClickedEvent.Parent = ReplicatedStorage 

local getMouseHit = Instance.new("RemoteFunction")
getMouseHit.Name = "GetMouseHit" -- This will be used throughout the system to invoke a player's mouse.hit, returning it as a vector3 and having the client filter out some things.
getMouseHit.Parent = ReplicatedStorage

local notify = Instance.new("RemoteEvent")
notify.Name = "Notify"  -- This will be used to send notifications (defined above) to the client, to display as text in their UI- my attempt to make this experience more beginner friendly and easy to pick up.
notify.Parent = ReplicatedStorage

local AttackIndicator = ReplicatedStorage:FindFirstChild("AttackIndicator") -- All the effects for the AttackIndicator; the circle, the sparks, and the angry dog icon.

-- Function to get touching parts of a given part, special handling so that the pets can deal damage while the CanCollide is off. (It is typically on, but disabled during the petAttackScene)
function GetTouchingParts(part) 
	local connection = part.Touched:Connect(function() end)
	local results = part:GetTouchingParts()
	connection:Disconnect() -- Disconnecting so I don't end up with a new lingering connection each time its called.
	return results -- Return all of the results that were touched, filtering through them and assigning damage will is done in following functions.
end

function petAttackScene(player, centerPoint, petFolder, indicator) -- This is the visual attack, throughout this the pets jump on the center and deal damage to anything in the circle- ensuring they keep circle formation as well as return to it.
	if player:GetAttribute("AttackScene") then return end  -- If this part, the attack scene itself, is already in progress, do not proceed with the new scene.
	player:SetAttribute("AttackScene", true) -- If it passed the above, set the attribute to prevent the player from duplicating attacks at the same time.
	local numBounces = 6 -- Number of times the pets will jump on the center then return before the sequence is over.
	indicator:FindFirstChild("AttackingParticle", true).Enabled = true -- This is for the shards particle: enable them with the scene.

	for _, petObject in pairs(petFolder:GetChildren()) do -- For every pet the player has spawned:
		petObject.CanCollide = false -- Temporarily disabling collisions so they dont spazz each other / targets out during the jumps. This gets re-enabled.
		coroutine.wrap(function() -- Coroutine to not holdup the server
			local originalPosition = petObject.Position -- Reference the starting point (in this case, around the circle)

			local jumpHeight = 5 
			local jumpDuration = 0.2 
			local landDuration = 0.1 -- Just the basic settings so I can easily go back and mess with the jumping

			for i = 1, numBounces do -- Iterate until the pet has bounced the numBounces amount.
				local petJumpingInfo = TweenInfo.new(jumpDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out) -- Combining with the jumpDuration, design the tween
				local goalJump = {Position = Vector3.new(centerPoint.X, originalPosition.Y + jumpHeight, centerPoint.Z)} -- Calculate the jump position, usinng the centerpoint, originalPosition, and jumpHeight
				local tweenJump = TweenService:Create(petObject, petJumpingInfo, goalJump) 
				tweenJump:Play()
				tweenJump.Completed:Wait() -- Tween the jump, then wait before the pet continues the scene.

				-- Landing animation
				local petLandingInfo = TweenInfo.new(landDuration, Enum.EasingStyle.Linear, Enum.EasingDirection.Out)
				local goalLand = {Position = Vector3.new(centerPoint.X, originalPosition.Y, centerPoint.Z)}
				local tweenLand = TweenService:Create(petObject, petLandingInfo, goalLand)
				tweenLand:Play()
				tweenLand.Completed:Wait()

				-- Deal damage when landing on the center
				task.wait(0.15)  -- Wait a bit for stability after landing

				local hitbox = indicator:FindFirstChild("Hitbox") -- Get the hitbox that I have already manually created and sized
				if hitbox then -- Don't continue if, for some reason, it isn't found
					local touchingParts = GetTouchingParts(hitbox) -- Get everything touching the hitbox using the GetTouchingParts documented above.
					for _, part in pairs(touchingParts) do
						local character = part:FindFirstAncestorWhichIsA("Model") -- See if there's a character; using FindFirstAncestorWhichIsA so if it's an accessory or something it still finds the model.
						if character == player.Character then 
							notify:FireClient(player, inOwnCircleNotification)
							-- If the character is the same player commanding the pets, send the inOwnCircleNotification to let them know to "Get out of your own attack zone, silly!!!"
							continue end -- Continue rather than stopping, so that the pets will ignore the player and still hit the targets.
						local humanoid = character:FindFirstChildWhichIsA("Humanoid") -- Check for humanoid, thereby seeing also if it is a real rig.
						if humanoid then
							humanoid:TakeDamage(BASEDAMAGE) -- Deal damage, albeit minor since this will continue as they keep jumping
						end
					end
				end

				task.wait(0.15)  -- Give a moment to land before continuing

				-- Return to the center:
				local tweenInfoReturn = TweenInfo.new(jumpDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.In) -- Nothing much, just the tween customization.
				local goalReturn = {Position = originalPosition} 
				local tweenReturn = TweenService:Create(petObject, tweenInfoReturn, goalReturn) -- Along with the previous line, set up the pet to return to the circular position
				tweenReturn:Play() 
				tweenReturn.Completed:Wait() -- Play the tween, then await its end

				if i < numBounces then
					task.wait(0.5 + math.random() * 1) -- Slight, randomized yield before the next jump- this ensures that pets dont attack in uniform, more-so taking turns.
				end
			end
		end)()
	end
end

-- Function to create pet attack
function createPetAttack(player, mouseHit)
	if player:GetAttribute("PetsAttacking") then return end -- Detect if the base attribute for both attackScene and this function is ticked; if it is, prevent the player stack attack commands by returning.
	player:SetAttribute("PetsAttacking", true) -- Following^, set the attribute to enable the return above.
	local effect = AttackIndicator:Clone()
	effect.Position = mouseHit
	effect.Parent = workspace -- This is the ring effect, the circle is placed to mark the attack and the pets then revolve around it.

	local petsFolder = workspace:FindFirstChild(player.Name .. "Pets") -- Find the player's pet folder established on PlayerAdded
	local numPets = #petsFolder:GetChildren() -- Total # of pets the player currently has in their workspace folder

	for i, petObject in pairs(petsFolder:GetChildren()) do 
		local angle = (i - 1) * (2 * math.pi / numPets) -- Angle around the circle
		local x_offset = 5 * math.cos(angle)  --X offset generated using cosine, the angle, and a defined radius that may need to be adjusted as I enlarge the circle effect.
		local z_offset = 5 * math.sin(angle) -- Z offset,similar logic but with sine- same pre-determined radius.

		local path = PathfindingService:CreatePath({
			AgentCanJump = true,
			AgentRadius = 1.5,
			AgentHeight = 5,
			AgentCanWalkOnWater = false,
			WaypointSpacing = .5
		}) 
		petObject.CFrame = CFrame.new(petObject.Position, mouseHit)

		path:ComputeAsync(petObject.Position, mouseHit + Vector3.new(x_offset, 0, z_offset)) -- Compute the path, combining the mouse.hit (aka centerPoint) with the offsets above
		local waypoints = path:GetWaypoints()

		if #waypoints > 0 then
			coroutine.wrap(function()
				task.wait(PETATTACKCOOLDOWN) -- Await the total PETATTACKCOOLDOWN
				player:SetAttribute("AttackScene", nil)
				player:SetAttribute("PetsAttacking", nil) -- Set related attributes used to track the status to nil, allowing player to attack as normal after.
				effect:Destroy() -- Clear the effect from the completed attack
				for _,pet in pairs(petsFolder) do 
					pet.CanCollide = true -- Re-enabling collisions from when I turned them off for the pet attack scene
				end
			end)()

			coroutine.wrap(function()
				for _, waypoint in pairs(waypoints) do -- Iterate through the waypoints, with a check on the next line
					if not player.Character or not player.Character.PrimaryPart then break end -- Do not continue if the corresponding player has no character

					local root = player.Character.HumanoidRootPart
					local targetCFrame = CFrame.new(waypoint.Position + Vector3.new(x_offset, 0, z_offset)) -- Get where the pet should end up, calling back to the offsets ensuring a uniform circle formation with the pets.
					petObject.CFrame = targetCFrame
					petObject:SetAttribute("OP", targetCFrame.Position) -- Set this attribute, short for OriginalPosition, letting the pet know the position outside the ring to return to during the attackScene when they jump.
					RunService.Heartbeat:Wait()
				end

				if i == numPets then -- Pass if all of the pets have made it to the starting point (circle-based) 
					petAttackScene(player, mouseHit, petsFolder, effect) -- Once they have, the petAttackScene sequence kicks in- making them jump on the center of target and deal damage at interval
				end
			end)()
		end
	end 
end

-- Function to handle player tool activation
function handlePlayerTool(player)
	local function characterAdded(character)
		local tool = player.Backpack:WaitForChild("Click To Make Pets Attack") -- Yield until the player actually has the tool to prevent an error
		tool.Activated:Connect(function() -- Listen for when the player is attempting to command an attack
			local hit = getMouseHit:InvokeClient(player) -- Get the player's mouse.hit from their client, this is setup to be returned as a Vector3 and filter out instances like the player's character and other invalids.
			if (hit - character.PrimaryPart.Position).Magnitude < MAXATTACKDISTANCE then 
				createPetAttack(player, hit) -- If under the maximum distance, start the attack by sending the pets around the circle via this function
			else 
				notify:FireClient(player, missedNotification) -- Send the missedNotification text to the player's UI through the already-coded notifications!
			end
		end)
	end 

	local getCharacter = player.Character or player.CharacterAdded:Wait() -- This is relevant for the comment below, making sure the character, well.. exists; or wait for it to
	characterAdded(getCharacter) -- I've set up this check to make sure that in cases where the player's character loads before the connection is established, call it manually as a failsafe.
	player.CharacterAdded:Connect(characterAdded) -- But, assuming things are normal, here is the standard connection!
end

local function handleMovementUpdates(player, petObject) -- This function is integral to replication of pet movement as will be described in the next lines
	PetMovementReplication.server:sendUpdate(petObject.Name, player.Name .. "Pets", petObject.CFrame) -- The calling of this in the initialization of the function is to ensure that, even when they are very first spawned, they smoothly tween to the accurate position. More details on how this works in next lines.
	petObject:GetPropertyChangedSignal("CFrame"):Connect(function() -- The use of this connection is critical when it comes to making sure that the server is 100% accurately detecting when pets are in motion, so that I can effectively have control of sending movement updates for the client to then replicate, as will be elaborated on in the next line.
		PetMovementReplication.server:sendUpdate(petObject.Name, player.Name .. "Pets", petObject.CFrame) -- Once more call the sendUpdate, except this time I am doing it within the context of the GetPropertyChangedSignal, thereby sending calling the module sendUpdate whenever the CFrame of the server-based pet instance is changed.
	end)
end 

function OnPlayerAdded(player)
	local folder = workspace:FindFirstChild(player.Name .. "Pets") or Instance.new("Folder") -- Attempt to see if the player had a folder from a previous session: otherwise, the "or Instance.new" initializes it for the coming code!
	folder.Name = player.Name .. "Pets" -- Assign the folder a name that can't naturally be replicated by using the player username, adding the word pets so I ofc have an identifier to separate it from things such as the character who share the name in workspace.
	folder.Parent = workspace -- So I can easily do workspace:FindFirstChild(playerName.."Pets") at any point I need to reference the folder, which I do several times throughout the script.
	handlePlayerTool(player) -- Initialize the tool handling in the context of pets- specifically this handles the "Click To Make Pets Attack" tool, detecting it being activated and then signaling the attack if it meets the conditions.
end

Players.PlayerAdded:Connect(OnPlayerAdded)

petClickedEvent.OnServerEvent:Connect(function(player, petName) -- Listener for the petClickedEvent: as described at the top, this is fired when a player tries to spawn a pet through their UI.
	local hit = getMouseHit:InvokeClient(player) -- Adding this check to make sure you can't spawn pets too far, and if they are too far send missed noti.
	if (hit-player.Character.PrimaryPart.Position).Magnitude > MAXATTACKDISTANCE then notify:FireClient(player,missedNotification) return end -- Using the constant MAXATTACKDISTANCE, check to see if the player has exceeded it; if so, notify them with the text from missedNotification letting them know they can try again.

	local petsFolder = ReplicatedStorage:FindFirstChild("Pets") -- Reference the pets folder; not one of an individual player, but the one in ReplicatedStorage that sources them.
	local petPart = petsFolder:FidFirstChild(petName) -- From aforementioned source folder, get the matching pet template to be cloned for the server-side instance
	if petPart then
		local clonedPetPart = petPart:Clone() -- Server pet part (to be assigned to the passed player)

		if (#workspace:FindFirstChild(player.Name.."Pets"):GetChildren()) >= MAXPETS then return end -- Do not proceed if the player has the max pets

		local newRandomName = "Pet_" .. player.Name .. "_" .. os.time()..clonedPetPart.Name -- Encoding the name here, using the time the player spawned it, so that even when a player spawns two of the identical pet, their names will be different.
		clonedPetPart.Name = newRandomName -- Apply from the previous comment ^
		clonedPetPart.Position = getMouseHit:InvokeClient(player) -- Get the player's mouse.hit from their client, this is setup to be returned as a Vector3 and filter out instances like the player's character and other invalids.
		clonedPetPart.Transparency = 1 -- Very important piece, the server-sided pets are invisible; this is so that all the client sees are its client instances, the ones I use PetMovementReplication to smooth on their side. This ensures centralization as well as universal enjoyment.
		clonedPetPart.Parent = workspace:FindFirstChild(player.Name.."Pets") -- If all reqs were met, to the player's pet folder!
		
		local behindDistance = player:GetAttribute("BehindDistance") -- Reference the previously established BehindDistance

		if not behindDistance then 
			player:SetAttribute("BehindDistance", BASEBEHINDDISTANCE) -- If somehow, something went wrong and the player does not have a value, assign the default before proceeding w/out the dependency.
		end 
		
		clonedPetPart:SetAttribute("BehindDistance", behindDistance) -- This will be used in the followPath function to, as described within, let the pets know how far to be behind the player / the pet infront of them.
		player:SetAttribute("BehindDistance", behindDistance + BEHINDDISTANCEINTERVAL) -- Building on that, add to the distance attribute so that the pets continue following the player in single file line, going more and more behind as pets are spawned.
		handleMovementUpdates(player, clonedPetPart) -- More documentation within the function, but it listens for the pets CFrame being changed to smoothly replicate the physics. 

		local function followPath() -- Here is the function for having the pets consistently follow their designated player
			local function moveDirChanged() -- Called whenever humanoid.MoveDirection is changed, more documentation on this connection at the bottom!
				if player:GetAttribute("PetsAttacking") then return end  -- Ensure that, initially, the pets are NOT in any level of the attack sequence
				if player.Character.Humanoid.MoveDirection == Vector3.new(0, 0, 0) then return end -- Block the function from continuing if the player has no movement
				local value = player.Character.Humanoid.MoveDirection -- Save the starting MoveDirection so I can reference it in the while loop and break this iteration when it has changed
				while player.Character.Humanoid.MoveDirection == value and not player:GetAttribute("PetsAttacking") do -- While the player is moving in the initial direction, and have not called an attack, loop through their movement
					local path = PathfindingService:CreatePath({
						AgentCanJump = true,
						AgentRadius = 1.5,
						AgentHeight = 5,
						AgentCanWalkOnWater = false,
						WaypointSpacing = 1.25
					}) -- Params for the path of following the character, the most important aspect being the WaypointSpacing- the more it is jacked, the more synthetic things will look.
					local position = (player.Character.PrimaryPart.CFrame * CFrame.new(0, 0, clonedPetPart:GetAttribute("BehindDistance"))).Position -- Using the BehindDistance (of the SPECIFIC PET), calculate where behind the player the pet needs to end up accordingly.
					path:ComputeAsync(clonedPetPart.Position, position)
					local waypoints = path:GetWaypoints() -- Just the basics here, using pathfinding to compute using the calculated position  and then initialize the waypoints table for the upcoming code

					if #waypoints > 0 then -- A check to make sure the waypoints actually exist
						for _, waypoint in pairs(waypoints) do -- Iterate through the waypoints
							if not player.Character or not player.Character.PrimaryPart then break end -- Break it completely if the player died in the process or something else happened to their character.
							local currentCFrame = clonedPetPart.CFrame -- Current CFrame
							local root = player.Character.HumanoidRootPart
							local look = Vector3.new(root.Position.X, clonedPetPart.Position.Y, root.Position.Z) -- Calculate where the pet should look, limiting it to certain orientation axis'.

							local targetCFrame = CFrame.new(waypoint.Position, look) -- Initilalize where the pet  needs to end this waypoint travel
							local stepCFrame = currentCFrame:Lerp(targetCFrame, .1) -- Lerp, so even the server has a degree of smoothness before the client does the rest.
							clonedPetPart.CFrame = stepCFrame -- Directly set it^

							if math.random() < 0.2 then -- Randomize the stop positions slightly.
								local randomOffset = Vector3.new(math.random(-1, 1) * 2.5, 0, math.random(-1, 1) * 2.5) -- Calculate offsets, allowing a negative 1 or positive 1 to influence the direction on the axis'.
								clonedPetPart.CFrame = CFrame.new(waypoint.Position + randomOffset, look) -- Manually set the CFrane, handleMovementUpdate() will smooth it for the client.
							end
						end
					end
				end
			end
			if player.Character:FindFirstChild("Humanoid").MoveDirection ~= Vector3.new(0, 0, 0) then -- If the player is currently moving when this is initialized,
				moveDirChanged() -- Then let the pets know they should now start moving aswell
			end
			player.Character:FindFirstChild("Humanoid"):GetPropertyChangedSignal("MoveDirection"):Connect(moveDirChanged) -- Same thing here, except this is an active connection to listen for all changes!
		end
		coroutine.wrap(followPath)() -- Call the player following function on a coroutine to not hold up anything else
	end

end)