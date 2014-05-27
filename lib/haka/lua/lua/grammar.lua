-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this
-- file, You can obtain one at http://mozilla.org/MPL/2.0/.

local class = require('class')
local rem = require("regexp/pcre")
local parse = require("parse")
local grammar_dg = require('grammar_dg')

local grammar_int = {}
local grammar = {}

grammar.result = require("parse_result")

--
-- Grammar env
--

local GrammarEnv = class.class("GrammarEnv")

function GrammarEnv.method:__init(grammar)
	self._grammar = grammar
	self._compiled = {}
end

function GrammarEnv.method:get(entity)
	local dg = rawget(self._compiled, entity)
	return dg
end

function GrammarEnv.method:register(entity, dg)
	rawset(self._compiled, entity, dg)
end

function GrammarEnv.method:unregister(entity, dg)
	rawset(self._compiled, entity, nil)
end

--
-- Grammar converter
--

grammar.converter = {}
grammar_int.converter = grammar.converter

function grammar.converter.mult(val)
	return {
		get = function (x) return x * val end,
		set = function (x)
			if x % val ~= 0 then
				error(string.format("invalid value, it must be a multiple of %d", val))
			end
			return x / val
		end
	}
end

grammar.converter.bool = {
	get = function (x) return x ~= 0 end,
	set = function (x) if x then return 1 else return 0 end end
}

function grammar.converter.tonumber(format, base)
	return {
		get = function (x) return tonumber(x, base) end,
		set = function (x) return string.format(format, x) end
	}
end

grammar.converter.string = {
	get = function (x) return x:asstring() end,
	set = function (x) return x end
}


--
-- Grammar description
--

grammar_int.Entity = class.class('Entity')

function grammar_int.Entity.method:_as(name)
	local clone = self:clone()
	clone.named = name
	return clone
end

function grammar_int.Entity.method:compile(env, rule, id)
	return self:do_compile(env, rule, id)
end

function grammar_int.Entity.method:convert(converter, memoize)
	local clone = self:clone()
	clone.converter = converter
	clone.memoize = memoize or clone.memoize
	return clone
end

function grammar_int.Entity.method:validate(validate)
	local clone = self:clone()
	clone.validate = validate
	return clone
end

function grammar_int.Entity.getoption(cls, opt)
	local v

	if cls._options then
		v = cls._options[opt]
		if v then return v end
	end

	local super = cls.super
	while super do
		if super._options then
			v = super._options[opt]
			if v then return v end
		end

		super = super.super
	end
end

function grammar_int.Entity.method:options(options)
	local clone = self:clone()
	for k, v in pairs(options) do
		if type(k) == 'string' then
			local opt = grammar_int.Entity.getoption(class.classof(self), k)
			assert(opt, string.format("invalid option '%s'", k))
			opt(clone, v)
		elseif type(v) == 'string' then
			local opt = grammar_int.Entity.getoption(class.classof(self), v)
			assert(opt, string.format("invalid option '%s'", v))
			opt(clone)
		else
			error("invalid option")
		end
	end
	return clone
end

grammar_int.Entity._options = {}

function grammar_int.Entity._options.memoize(self)
	self.memoize = true
end

grammar_int.Compound = class.class('Compound', grammar_int.Entity)

function grammar_int.Compound.method:compile(env, rule, id)
	local compiled = env:get(self)
	if compiled then
		return grammar_dg.Recurs:new(rule, id, compiled)
	end

	-- Create a DGCompound in order to use it for recursive case
	local compound = grammar_dg.Compound:new(rule, id, compiled)
	env:register(self, compound)
	local ret = self:do_compile(env, rule, id)
	env:unregister(self)
	compound:add(ret)
	return compound
end


grammar_int.Record = class.class('Record', grammar_int.Compound)

function grammar_int.Record.method:__init(entities)
	self.entities = entities
	self.extra_entities = {}
	self.on_finish = {}
end

function grammar_int.Record.method:extra(functions)
	for name, func in pairs(functions) do
		if type(name) == 'string' then self.extra_entities[name] = func
		else table.insert(self.on_finish, func) end
	end
	return self
end

function grammar_int.Record.method:do_compile(env, rule, id)
	local iter, ret

	ret = grammar_dg.Retain:new(haka.packet_mode() == 'passthrough')

	iter = grammar_dg.RecordStart:new(rule, id, self.named)
	if self.converter then iter:convert(self.converter, self.memoize) end
	if self.validate then iter:validate(self.validate) end
	ret:add(iter)

	for i, entity in ipairs(self.entities) do
		local next = entity:compile(env, self.rule or rule, i)
		if next then
			if iter then
				iter:add(next)
				iter = next
			else
				ret = next
				iter = ret
			end
		end
	end

	local pop = grammar_dg.RecordFinish:new(self.named ~= nil)
	for _, f in ipairs(self.on_finish) do
		pop:onfinish(f)
	end
	for name, f in pairs(self.extra_entities) do
		pop:extra(name, f)
	end
	iter:add(pop)
	iter:add(grammar_dg.Release:new())

	return ret
end


grammar_int.Sequence = class.class('Sequence', grammar_int.Compound)

function grammar_int.Sequence.method:__init(entities)
	self.entities = entities
end

function grammar_int.Sequence.method:do_compile(env, rule, id)
	local iter, ret

	ret = grammar_dg.RecordStart:new(rule, id, self.named)

	if self.converter then ret:convert(self.converter, self.memoize) end
	if self.validate then ret:validate(self.validate) end
	iter = ret

	for i, entity in ipairs(self.entities) do
		if entity.named then
			haka.log.warning("grammar", "named element '%s' are not supported in sequence", entity.named)
		end

		local next = entity:compile(env, self.rule or rule, i)
		if next then
			if iter then
				iter:add(next)
				iter = next
			else
				ret = next
				iter = ret
			end
		end
	end

	local pop = grammar_dg.RecordFinish:new(self.named ~= nil)
	iter:add(pop)

	return ret
end


grammar_int.Union = class.class('Union', grammar_int.Compound)

function grammar_int.Union.method:__init(entities)
	self.entities = entities
end

function grammar_int.Union.method:do_compile(env, rule, id)
	local ret = grammar_dg.UnionStart:new(rule, id, self.named)

	for i, entity in ipairs(self.entities) do
		local next = entity:compile(env, self.rule or rule, i)
		if next then
			ret:add(next)
			ret:add(grammar_dg.UnionRestart:new())
		end
	end

	ret:add(grammar_dg.UnionFinish:new(self.named))
	return ret
end

grammar_int.Try = class.class('Try', grammar_int.Compound)

function grammar_int.Try.method:__init(cases)
	self.cases = cases
end

function grammar_int.Try.method:do_compile(env, rule, id)
	local first_try = nil
	local previous_try = nil
	local finish = grammar_dg.TryFinish:new(self.rule or rule, id, self.named)

	-- For each case we prepend a catch entity
	-- and we chain catch entities together to try every cases
	for i, entity in ipairs(self.cases) do
		local next = entity:compile(env, self.rule or rule, i)

		if next then
			local try = grammar_dg.Try:new(self.rule or rule, id, self.named)
			try:add(next)
			try:add(finish)
			if previous_try then
				previous_try:catch(try)
			end
			previous_try = try
			first_try = first_try or try
		end
	end

	if not first_try then
		error("cannot create a try element without any case")
	end

	-- End with error if everything failed
	previous_try:catch(grammar_dg.Error:new(self.rule or rule, "cannot find a successful try case"))

	return first_try
end

grammar_int.Branch = class.class('Branch', grammar_int.Compound)

function grammar_int.Branch.method:__init(cases, select)
	self.selector = select
	self.cases = { default = 'error' }
	for key, value in pairs(cases) do
		self.cases[key] = value
	end
end

function grammar_int.Branch.method:do_compile(env, rule, id)
	local ret = grammar_dg.Branch:new(rule, id, self.selector)

	for key, entity in pairs(self.cases) do
		if key ~= 'default' then
			local next = entity:compile(env, self.rule or rule, key)
			if next then
				ret:case(key, next)
			end
		end
	end

	local default = self.cases.default
	if default == 'error' then
		ret._next = grammar_dg.Error:new(self.rule or rule, "invalid case")
	elseif default ~= 'continue' then
		local next = default:compile(env, self.rule or rule, 'default')
		if next then
			ret._next = next
		end
	end

	return ret
end


grammar_int.Array = class.class('Array', grammar_int.Compound)

function grammar_int.Array.method:__init(entity)
	self.entity = entity
end


function grammar_int.Array.method:do_compile(env, rule, id)
	local start = grammar_dg.ArrayStart:new(rule, id, self.named, self.create, self.resultclass)
	if self.converter then start:convert(self.converter, self.memoize) end

	local loop = grammar_dg.Branch:new(nil, nil, self.more)
	local push = grammar_dg.ArrayPush:new(rule, id)
	local inner = self.entity:compile(env, self.rule or rule, id)
	local pop = grammar_dg.ArrayPop:new()
	local finish = grammar_dg.ResultPop:new()

	start:set_entity(inner)

	push:add(inner)
	push:add(pop)
	push:add(loop)
	loop:case(true, push)
	loop:add(finish)
	start:add(loop)

	return start
end

grammar_int.Array._options = {}

function grammar_int.Array._options.count(self, size)
	local sizefunc

	if type(size) ~= 'function' then
		sizefunc = function () return size end
	else
		sizefunc = size
	end

	self.more = function (array, ctx)
		return #array < sizefunc(ctx:result(-2), ctx)
	end
end

function grammar_int.Array._options.untilcond(self, condition)
	self.more = function (array, ctx)
		if #array == 0 then return not condition(nil, ctx)
		else return not condition(array[#array], ctx) end
	end
end

function grammar_int.Array._options.whilecond(self, condition)
	self.more = function (array, ctx)
		if #array == 0 then return condition(nil, ctx)
		else return condition(array[#array], ctx) end
	end
end

function grammar_int.Array._options.create(self, f)
	self.create = f
end

function grammar_int.Array._options.result(self, resultclass)
	self.resultclass = resultclass
end


grammar_int.Number = class.class('Number', grammar_int.Entity)

function grammar_int.Number.method:__init(bits)
	self.bits = bits
end

function grammar_int.Number.method:do_compile(env, rule, id)
	local ret = grammar_dg.Number:new(rule, id, self.bits, self.endian, self.named)
	if self.converter then ret:convert(self.converter, self.memoize) end
	if self.validate then ret:validate(self.validate) end
	return ret
end

grammar_int.Number._options = {}
function grammar_int.Number._options.endianness(self, endian) self.endian = endian end


grammar_int.Bytes = class.class('Bytes', grammar_int.Entity)

function grammar_int.Bytes.method:do_compile(env, rule, id)
	if type(self.count) ~= 'function' then
		local count = self.count
		self.count = function (self) return count end
	end

	local ret = grammar_dg.Bytes:new(rule, id, self.count, self.named, self.chunked)
	if self.converter then ret:convert(self.converter, self.memoize) end
	if self.validate then ret:validate(self.validate) end
	return ret
end

grammar_int.Bytes._options = {}
function grammar_int.Bytes._options.chunked(self, callback) self.chunked = callback end
function grammar_int.Bytes._options.count(self, count) self.count = count end


grammar_int.Bits = class.class('Bits', grammar_int.Entity)

function grammar_int.Bits.method:__init(bits)
	self.bits = bits
end

function grammar_int.Bits.method:do_compile(env, rule, id)
	if type(self.bits) ~= 'function' then
		local bits = self.bits
		self.bits = function (self) return bits end
	end

	return grammar_dg.Bits:new(rule, id, self.bits)
end

grammar_int.Token = class.class('Token', grammar_int.Entity)

function grammar_int.Token.method:__init(pattern, raw)
	self.pattern = pattern
	self.raw = raw
end

function grammar_int.Token.method:do_compile(env, rule, id)
	if not self.re then
		self.re = rem.re:compile("^(?:"..self.pattern..")")
	end
	local ret = grammar_dg.Token:new(rule, id, self.pattern, self.re, self.named, self.raw)
	if self.converter then ret:convert(self.converter, self.memoize) end
	return ret
end

grammar_int.Execute = class.class('Execute', grammar_int.Entity)

function grammar_int.Execute.method:__init(func)
	self.func = func
end

function grammar_int.Execute.method:do_compile(env, rule, id)
	return grammar_dg.Execute:new(rule, id, self.func)
end

grammar_int.Retain = class.class('Retain', grammar_int.Entity)

function grammar_int.Retain.method:__init(readonly)
	self.readonly = readonly
end

function grammar_int.Retain.method:do_compile(env, rule, id)
	return grammar_dg.Retain:new(self.readonly)
end

grammar_int.Release = class.class('Release', grammar_int.Entity)

function grammar_int.Release.method:do_compile(env, rule, id)
	return grammar_dg.Release:new()
end

grammar_int.Empty = class.class('Empty', grammar_int.Entity)

function grammar_int.Empty.method:do_compile(env, rule, id)
	return nil
end

grammar_int.Error = class.class('Error', grammar_int.Entity)

function grammar_int.Error.method:__init(msg)
	self.msg = msg
end

function grammar_int.Error.method:do_compile(env, rule, id)
	return grammar_dg.Error:new(id, self.msg)
end

function grammar_int.record(entities)
	return grammar_int.Record:new(entities)
end

function grammar_int.sequence(entities)
	return grammar_int.Sequence:new(entities)
end

function grammar_int.union(entities)
	return grammar_int.Union:new(entities)
end

function grammar_int.try(cases)
	return grammar_int.Try:new(cases)
end

function grammar_int.branch(cases, select)
	return grammar_int.Branch:new(cases, select)
end

function grammar_int.optional(entity, present)
	return grammar_int.Branch:new({
		[true] = entity,
		default = 'continue'
	}, present)
end

function grammar_int.array(entity)
	return grammar_int.Array:new(entity)
end

function grammar_int.number(bits)
	return grammar_int.Number:new(bits)
end

function grammar_int.token(pattern)
	return grammar_int.Token:new(pattern, false)
end

function grammar_int.raw_token(pattern)
	return grammar_int.Token:new(pattern, true)
end

grammar_int.flag = grammar_int.number(1):convert(grammar_int.converter.bool, false)

function grammar_int.bytes()
	return grammar_int.Bytes:new()
end

function grammar_int.padding(args)
	if args.align then
		local align = args.align
		return grammar_int.Bits:new(function (self, ctx)
			local rem = (ctx.iter.meter * 8 + ctx._bitoffset) % align
			if rem > 0 then return align -rem
			else return 0 end
		end)
	elseif args.size then
		return grammar_int.Bits:new(args.size)
	else
		error("invalid padding option")
	end
end

function grammar_int.field(name, field)
	return field:_as(name)
end

function grammar_int.verify(func, msg)
	return grammar_int.Execute:new(function (self, ctx)
		if not func(self, ctx) then
			error(msg)
		end
	end)
end

function grammar_int.execute(func)
	return grammar_int.Execute:new(func)
end

function grammar_int.empty()
	return grammar_int.Empty:new()
end

function grammar_int.fail(msg)
	return grammar_int.Error:new(msg)
end

grammar_int.text = grammar_int.bytes():convert(grammar_int.converter.string, true)

--
-- Grammar
--

local Grammar = class.class("Grammar")

function Grammar.method:__init(name)
	rawset(self, '_name', name)
	rawset(self, '_rules', {})
	rawset(self, '_exports', {})
end

function Grammar.method:dump_graph(file)
	file:write("digraph grammar {\n")

	local ref = {}
	ref._index = 1

	for name, rule in pairs(self._exports) do
		file:write(string.format("subgraph cluster_%s { label=%s \n", name, name))
		rule:_dump_graph(file, ref)
		file:write("}\n")
	end

	file:write("}\n")
end

function Grammar.method:__index(name)
	local ret = self._exports[name]
	if not ret then
		error(string.format("unknown grammar public rule '%s'", name))
	end

	return ret
end

function Grammar.method:__newindex(key, value)
	error("read-only table")
end

local GrammarProxy = class.class("GrammarProxy", grammar_int.Entity)

function GrammarProxy.method:__init(name)
	self._name = name
end

function GrammarProxy.method:do_compile(env, rule, id)
	local entity = env._grammar._rules[self._name]
	if not entity then
		error("use of unimplemented entity: %s", proxy._name)
	end

	if self.named then
		local clone = entity:clone()
		clone.named = self.named
		entity = clone
	end

	return entity:compile(env, rule, id)
end

function grammar_env(gr)
	local func = {
		export = function (...)
			for _, proxy in ipairs({...}) do
				gr._exports[proxy._name] = true
			end
		end,
		extend = function (...)
			for _, grammar in ipairs({...}) do
				table.merge(gr._rules, grammar._rules)
				-- We just need key of exports to recompile it
				table.merge(gr._exports, grammar._exports)
			end
		end,
		define = function (...)
			for _, name in ipairs({...}) do
				gr._rules[name] = GrammarProxy:new(name)
			end
		end
	}

	return {
		__index = function (self, name)
			local ret

			-- Search in grammar function
			ret = func[name]
			if ret then
				return ret
			end

			-- Search in the grammar environment
			ret = grammar_int[name]
			if ret then return ret end

			-- Search the defined rules
			ret = gr._rules[name]
			if ret then
				if class.isa(ret, GrammarProxy) then
					return ret
				else
					-- Create a proxy to allow inheritance
					return GrammarProxy:new(name)
				end
			end

			return nil
		end;
		__newindex = function (self, key, value)
			-- Forbid override to grammar elements
			if grammar_int[key] or key == 'export' then
				error(string.format("'%s' is reserved in the grammar scope", key))
			end

			if class.isa(value, grammar_int.Entity) then
				-- Add the object in the rules
				gr._rules[key] = value
				value.rule = key
			else
				rawset(self, key, value)
			end
		end
	}
end

function grammar.new(name, def)
	assert(type(def) == 'function', "grammar definition must be a function")

	local g = Grammar:new(name)

	-- Add a metatable to the environment only during the definition
	-- of the grammar.
	local env = debug.getfenv(def)
	setmetatable(env, grammar_env(g))

	def()
	setmetatable(env, nil)

	-- Search for unimplemented rule
	for name, rule in pairs(g._rules) do
		if class.isa(rule, GrammarProxy) then
			error("unimplemented rule: "..name)
		end
	end

	-- Compile exported entities
	for name, _  in pairs(g._exports) do
		local value = g._rules[name]
		if not value then
			error("exported rule must be registered in the grammar: "..name)
		end

		local genv = GrammarEnv:new(g)
		g._exports[name] = value:compile(genv)
	end

	if grammar.debug then
		haka.log.warning("grammar", "dumping '%s' grammar graph to %s.dot", g._name, g._name)
		f = io.open(string.format("%s.dot", g._name), "w+")
		g:dump_graph(f)
		f:close()
	end

	return g
end

grammar.debug = false

haka.grammar = grammar
