local mqtt   = require("mqtt_library")
local screen = { w = love.graphics.getWidth(), h = love.graphics.getHeight()  }

-- coordinator
local id     = tonumber(arg[2])
local ip     = arg[3] or "127.0.0.1"
local coord  = id

love.window.setTitle("dofight player: "..id)
--love.window.setTitle("dofight player: "..id)

local ship = {
	id = coord,         -- player id

	rho=  10,           -- radius
	phi=   0,           -- angle
	vp =   0, vc = 1.2, -- angle speed
	af =   0,
	sx = 100,           -- x,y
	sy = 100 * (id+1),
	vx =   0, vy =   0, -- velocity
	ax =   0, ay =   0, -- acceleration

	score       = 0,    -- number of kills
	num_bullets = 0,
	max_bullets = 5,
	bullets = {}
}

-- list with all ships
local ships = {}

-- in  : table
-- out : string
-- note: make sure it is acyclic!
function marshall2(t)
	local result = {}

	table.insert(result, "return {")
	marshall_r(result, t)
	table.insert(result, "}")

	return table.concat(result)
end

function marshall_r(result, t)
	for k,v in pairs(t) do
		-- key
		if     (type(k) == "number") then table.insert(result, '['..k..']')
		elseif (type(k) == "string") then table.insert(result, k)
		end

		table.insert(result, "=")

		-- val
		if     (type(v) == "number") then table.insert(result, v)
		elseif (type(v) == "string") then table.insert(result, '[['..v..']]')
		elseif (type(v) == "table" ) then
			table.insert(result, "{")
			marshall_r  (result, v)
			table.insert(result, "}")
		end

		table.insert(result, ",")
	end
end

-- in : string with encoded parameter list
-- out: table as array with parameters in order
function unmarshall(s)
	return loadstring(s)()
end

-- build network packages
function build_netpak()
	local net_ship = {
		id=ship.id, phi=ship.phi,
		sx=ship.sx, sy=ship.sy,
		vx=ship.vx, vy=ship.vy,
		bullets= {},
	}
	for k,v in pairs(ship.bullets) do
		local net_bullet = {
			sx=v.sx, sy=v.sy,
			vx=v.vx, vy=v.vy
		}
		table.insert(net_ship.bullets, net_bullet)
	end
	return marshall2(net_ship)
end

function mqtt_cb(topic, message)
	if (message == nil or topic == nil) then return end
	local as_table = unmarshall(message)

	if (topic == "partial-update") then
		ships[as_table.id] = as_table
	elseif (topic == "full-update") then
		ships = as_table
	elseif (topic == "ctl") then
		if     (as_table.id == ship.id) then return end

		if     (as_table.action == "join") then
			print('player: '..as_table.id..' has joined the game')

			coord = math.huge
			for _,s in pairs(ships) do
				if (s.id < coord) then coord = s.id end
			end

			-- only coord will send this message
			if ship.id == coord then
				print("player "..ship.id.." will update ".. as_table.id)
				mqtt_client:publish("full-update", marshall2(ships))
			end

		elseif (as_table.action == "quit") then

			coord = math.huge
			for _,s in pairs(ships) do
				if (s.id < coord) then coord = s.id end
			end

			print('player: '..as_table.id..' has left the game')
			ships[as_table.id] = nil
		elseif (as_table.action == "kill") then

			if (as_table.src == ship.id) then
				ship.score = ship.score + 1
			end
			if (as_table.dst == ship.id) then
				ship.sx = math.random(screen.w)
				ship.sy = math.random(screen.h)
			end

		end
	else
		print("failed to parse:", message)
	end
end

function love.load()
	mqtt_client = mqtt.client.create(ip, 1883, mqtt_cb)
	mqtt_client:connect(tostring(ship.id))
	mqtt_client:subscribe({"ctl"})
	mqtt_client:subscribe({"partial-update"})
	mqtt_client:subscribe({"full-update"})

	mqtt_client:publish("ctl", marshall2({action="join" , id=ship.id}))
end

function love.quit()
	mqtt_client:publish("ctl", marshall2({action="quit", id=ship.id}))
end

function love.keypressed(key, scancode, repeated)
	if repeated then return end

	if (key == 'w') then ship.af = ship.af + 10 end
	if (key == 'd') then ship.vp = ship.vp + ship.vc  end
	if (key == 'a') then ship.vp = ship.vp - ship.vc  end
	
	if (key == ' ' or key == 'space') then
		if (ship.num_bullets < ship.max_bullets) then
			local bullet = {
				sx = ship.sx,
				sy = ship.sy,
				vx = ship.vx + 50*math.cos(ship.phi),
				vy = ship.vy + 50*math.sin(ship.phi),
			}

			ship.num_bullets = ship.num_bullets + 1
			table.insert(ship.bullets, bullet)
		end
	end
end

function love.keyreleased(key, scancode)
	if (key == 'w') then ship.af = ship.af - 10 end
	if (key == 'd') then ship.vp = ship.vp - ship.vc  end
	if (key == 'a') then ship.vp = ship.vp + ship.vc  end
end

function love.update(dt)
	local now = love.timer.getTime()
	next_network_update = next_network_update or 0
	debug_lines = {}
	mqtt_client:handler()

	ship.phi= ship.phi+ ship.vp*dt

	ship.ax = ship.af * math.cos(ship.phi) - ship.vx*dt
	ship.ay = ship.af * math.sin(ship.phi) - ship.vy*dt

	ship.vx = 0.999*ship.vx + 10*ship.ax*dt
	ship.vy = 0.999*ship.vy + 10*ship.ay*dt

	ship.sx = 1.0*ship.sx + ship.vx*dt
	ship.sy = 1.0*ship.sy + ship.vy*dt

	if (ship.sx <        0) then ship.sx = ship.sx + screen.w end
	if (ship.sy <        0) then ship.sy = ship.sy + screen.h end

	if (ship.sx > screen.w) then ship.sx = ship.sx - screen.w end
	if (ship.sy > screen.h) then ship.sy = ship.sy - screen.h end

	if true then
		-- local interpolation of game state (for network packages)
		for _,ship in pairs(ships) do
			--ship.phi= ship.phi+ ship.vp*dt

			--ship.ax = ship.af * math.cos(ship.phi) - ship.vx*dt
			--ship.ay = ship.af * math.sin(ship.phi) - ship.vy*dt

			--ship.vx = 0.999*ship.vx + 10*ship.ax*dt
			--ship.vy = 0.999*ship.vy + 10*ship.ay*dt

			ship.sx = 1.0*ship.sx + ship.vx*dt
			ship.sy = 1.0*ship.sy + ship.vy*dt

			for k,bullet in pairs(ship.bullets) do
				bullet.sx = bullet.sx + bullet.vx * dt
				bullet.sy = bullet.sy + bullet.vy * dt

				if (bullet.sx > screen.w or bullet.sx < 0 or
					bullet.sy > screen.h or bullet.sy < 0) then
					ship.bullets[k] = nil
				end
			end
		end
	end

	-- solve colisions with env
	for _,bullet in pairs(ship.bullets) do
		bullet.sx = bullet.sx + bullet.vx * dt
		bullet.sy = bullet.sy + bullet.vy * dt

		if (bullet.sx > screen.w or bullet.sx < 0 or
		    bullet.sy > screen.h or bullet.sy < 0) then
			ship.bullets[_] = nil
			ship.num_bullets = ship.num_bullets - 1
		end
	end

	-- each ship comptutes its bullet colisions with other ships
	for b_id,b in pairs(ship.bullets) do
		for s_id,s in pairs(ships) do
			if s.id ~= ship.id then
				local dx = s.sx - b.sx
				local dy = s.sy - b.sy
				local d  = math.sqrt(dx*dx + dy*dy)

				--table.insert(debug_lines, {b.sx, b.sy, s.sx, s.sy})

				if (d < ship.rho) then
					mqtt_client:publish("ctl", marshall2({action="kill", src=ship.id, dst=s.id}))
					ship.bullets[b_id] = nil
					ship.num_bullets = ship.num_bullets - 1
				end
			end
		end
	end
	--]]

	-- send a update every 100ms 
	if (now > next_network_update) then
		-- build network packages
		local net_ship = {
			id=ship.id, phi=ship.phi,
			sx=ship.sx, sy=ship.sy,
			bullets= {},
		}
		for k,v in pairs(ship.bullets) do
			local net_bullet = {
				sx=v.sx, sy=v.sy,
				vx=v.vx, vy=v.vy
			}
			table.insert(net_ship.bullets, net_bullet)
		end

		local netpak = build_netpak()
		mqtt_client:publish("partial-update", netpak)

		-- every 100ms
		next_network_update = now + 0.1
	end
end

function love.draw()
	for _,v in pairs(ships) do
		if (v.bullets) then
			for bk,bv in pairs(v.bullets) do
				love.graphics.circle("fill", bv.sx, bv.sy, 2)
			end
		end
		love.graphics.push()
		love.graphics.translate(v.sx, v.sy)
		love.graphics.rotate(v.phi)
		love.graphics.circle("line", 0, 0, 10)
		love.graphics.line(0, 0, 10, 0)

		love.graphics.pop()
	end

	for _,v in pairs(debug_lines) do
		love.graphics.line(v[1], v[2], v[3], v[4])
	end
end
