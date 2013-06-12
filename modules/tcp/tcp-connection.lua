module("tcp-connection", package.seeall)

local function forge(self)
	pkt = self.stream:pop()
	if pkt then
		self.connection:stream(not self.direction):ack(pkt)
		return pkt
	end
end

local function drop(self)
	self.connection:close()
	self.connection = nil
end

local function dissect(pkt)
	local stream_dir

	local newpkt = {}
	newpkt.connection, newpkt.direction = pkt:getconnection()
	newpkt.dissector = "tcp-connection"
	newpkt.next_dissector = nil
	newpkt.valid = function (self)
		return newpkt.connection ~= nil
	end
	newpkt.drop = drop
	newpkt.forge = forge

	if not newpkt.connection then
		-- new connection
		if pkt.flags.syn then
			if haka.rule_hook("tcp-connection-new", pkt) then
				return nil
			end

			newpkt.connection = pkt:newconnection()
			newpkt.connection.data = {}
			newpkt.connection.data.next_dissector = newpkt.next_dissector
			newpkt.direction = true
		else
			haka.log.error("tcp-connection", "no connection found")
			pkt:drop()
			return nil
		end
	end

	newpkt.stream = newpkt.connection:stream(newpkt.direction)
	newpkt.stream:push(pkt)
	
	newpkt.next_dissector = newpkt.connection.data.next_dissector

	if pkt.flags.syn then
		return nil
	end

	-- handle ending handshake
	if pkt.flags.ack and newpkt.connection.state > 0 then
		newpkt.connection.state =  newpkt.connection.state + 1
	end

	if pkt.flags.fin then
		newpkt.connection.state =  newpkt.connection.state + 1
	end

	if newpkt.connection.state == 4 or pkt.flags.rst then
		newpkt.connection:close()
		newpkt.connection = nil
		return nil
	end

	return newpkt
end

haka.dissector {
	name = "tcp-connection",
	dissect = dissect
}
