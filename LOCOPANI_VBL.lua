-- ============================================================
-- LOCOPANI COMPAT (V27) - camada de compatibilidade entre executores
-- Cria apelidos/fallbacks para funcoes que mudam de nome ou nao existem
-- em Delta, Potassium, Xeno, Arceus X etc. Tudo protegido com pcall.
-- ============================================================
do
	local okG, genv = pcall(function() return getgenv() end)
	if not okG or type(genv) ~= "table" then genv = _G end
	local fenv
	pcall(function() fenv = getfenv(0) end)

	local function get(name)
		local v
		pcall(function() v = genv[name] end)
		if v == nil then pcall(function() v = _G[name] end) end
		if v == nil and fenv then pcall(function() v = fenv[name] end) end
		return v
	end
	local function put(name, value)
		pcall(function() genv[name] = value end)
		pcall(function() _G[name] = value end)
		if fenv then pcall(function() fenv[name] = value end) end
	end
	local function alias(name, ...)
		if type(get(name)) == "function" then return end
		for _, other in ipairs({ ... }) do
			local f = get(other)
			if type(f) == "function" then put(name, f) return end
		end
	end
	local function nested(tbl, field)
		local t = get(tbl)
		if type(t) == "table" and type(t[field]) == "function" then return t[field] end
	end

	-- HTTP: request / http_request / syn.request / http.request / fluxus.request
	if type(get("request")) ~= "function" then
		local f = get("http_request") or get("httprequest")
			or nested("syn", "request") or nested("http", "request") or nested("fluxus", "request")
		if f then put("request", f) end
	end
	if type(get("http_request")) ~= "function" and type(get("request")) == "function" then
		put("http_request", get("request"))
	end

	-- Apelidos comuns
	alias("getnamecallmethod", "get_namecall_method")
	alias("getthreadidentity", "get_thread_identity", "getidentity", "get_thread_context", "getthreadcontext")
	alias("getconnections", "get_signal_cons")
	alias("firesignal", "fire_signal")
	alias("getcustomasset", "getsynasset")
	alias("gethui", "get_hidden_gui")
	alias("setclipboard", "toclipboard", "set_clipboard")
	alias("isfile", "is_file")
	alias("readfile", "read_file")
	alias("writefile", "write_file")
	alias("makefolder", "make_folder")
	alias("isfolder", "is_folder")
	alias("listfiles", "list_files")
	alias("delfile", "delete_file")
	alias("getrawmetatable", "get_raw_metatable")

	if type(get("getrawmetatable")) ~= "function" then
		local dbg = get("debug")
		if type(dbg) == "table" and type(dbg.getmetatable) == "function" then
			put("getrawmetatable", dbg.getmetatable)
		end
	end

	-- newcclosure / cloneref (fallback simples)
	if type(get("newcclosure")) ~= "function" then put("newcclosure", function(f) return f end) end
	if type(get("cloneref")) ~= "function" then put("cloneref", function(x) return x end) end

	-- setreadonly seguro (nunca dispara erro). So e criado se o executor tiver alguma forma
	-- de destravar tabelas; senao os hooks de metatable ficam desligados sem quebrar nada.
	do
		local sro, mkw, mkr = get("setreadonly"), get("make_writeable"), get("make_readonly")
		local hasRaw = type(get("getrawmetatable")) == "function"
		if hasRaw and (type(sro) == "function" or type(mkw) == "function") then
			put("setreadonly", function(t, ro)
				if type(sro) == "function" then
					if pcall(sro, t, ro) then return end
				end
				if ro then
					if type(mkr) == "function" then pcall(mkr, t) end
				else
					if type(mkw) == "function" then pcall(mkw, t) end
				end
			end)
		end
	end

	-- firesignal via getconnections (executores que nao tem firesignal)
	if type(get("firesignal")) ~= "function" and type(get("getconnections")) == "function" then
		local gc = get("getconnections")
		put("firesignal", function(signal, ...)
			local args = table.pack(...)
			local ok, conns = pcall(gc, signal)
			if not ok or type(conns) ~= "table" then return end
			for _, c in ipairs(conns) do
				pcall(function()
					if type(c.Fire) == "function" then
						c:Fire(table.unpack(args, 1, args.n))
					elseif type(c.Function) == "function" then
						c.Function(table.unpack(args, 1, args.n))
					end
				end)
			end
		end)
	end
end

-- ============================================================
-- LOCOPANI Loading Screen (V24)
-- Logo "L" circular com glow roxo, bolinhas pulsando ao redor (uma por uma),
-- particulas roxas tipo neve, barra retangular de progresso (0-100%)
-- e fundo preto borrado. Dura 6 segundos (ou ate o script terminar).
-- ============================================================
do
	local env = (type(getgenv) == "function" and getgenv()) or _G
	if env.LOCOPANI_LOADER and type(env.LOCOPANI_LOADER.Destroy) == "function" then
		pcall(env.LOCOPANI_LOADER.Destroy)
	end
	local LOADER = {}
	env.LOCOPANI_LOADER = LOADER

	local RunService = game:GetService("RunService")

	-- Ajustes rapidos
	local MIN_TIME = 6 -- duracao da tela / tempo da barra 0-100% (segundos)
	local HOLD_100 = 0.4 -- tempo mostrando 100% antes de revelar o painel
	local MAX_TIME = 40 -- seguranca: fecha sozinha se algo travar
	local BLUR_SIZE = 26 -- forca do blur no fundo
	local BG_ALPHA = 0.8 -- opacidade do preto (0 a 1)
	local CY = -40 -- deslocamento vertical do logo (px)
	local DEBUG = false -- true = avisa no console quando esconde o painel
	local FLAKES = 40 -- quantidade de particulas de neve
	local PULSE_PERIOD = 1 -- cada bolinha pulsa a cada X segundos (uma depois da outra)
	local LOGO = 124 -- diametro do logo (px)
	local BAR_W = 360 -- largura da barra (px)

	local PURPLE = Color3.fromRGB(150, 70, 255)
	local VIOLET = Color3.fromRGB(176, 100, 255)
	local LAVENDER = Color3.fromRGB(226, 198, 255)
	local DOT_DIM = Color3.fromRGB(112, 58, 214)
	local DOT_HOT = Color3.fromRGB(240, 215, 255)

	local state = {
		fade = 0,
		target = 1,
		token = 0,
		t0 = 0,
		shownAt = 0,
		hideRequested = false,
		lastProg = 0,
		frame = 0,
		held = {},
		onReveal = {},
	}

	-- Devolve (reativa) os paineis que ficaram escondidos durante o carregamento
	local function release()
		local cbs = state.onReveal
		state.onReveal = {}
		for _, fn in ipairs(cbs) do
			task.spawn(function()
				pcall(fn)
			end)
		end
		for g, was in pairs(state.held) do
			state.held[g] = nil
			if g.Parent then
				pcall(function()
					g.Enabled = was
				end)
			end
		end
	end

	local function destroy()
		release()
		if state.conn then
			pcall(function()
				state.conn:Disconnect()
			end)
			state.conn = nil
		end
		if state.gui then
			pcall(function()
				state.gui:Destroy()
			end)
			state.gui = nil
		end
		if state.blur then
			pcall(function()
				state.blur:Destroy()
			end)
			state.blur = nil
		end
	end
	LOADER.Destroy = destroy

	local function parentGui(gui)
		pcall(function()
			if syn and syn.protect_gui then
				syn.protect_gui(gui)
			end
		end)
		if type(gethui) == "function" then
			local ok, hui = pcall(gethui)
			if ok and typeof(hui) == "Instance" and pcall(function()
				gui.Parent = hui
			end) then
				return
			end
		end
		if pcall(function()
			gui.Parent = game:GetService("CoreGui")
		end) then
			return
		end
		gui.Parent = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
	end

	local function round(obj)
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(1, 0)
		c.Parent = obj
		return c
	end

	local function corner(obj, radius)
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, radius)
		c.Parent = obj
		return c
	end

	local function build()
		local gui = Instance.new("ScreenGui")
		gui.Name = "LOCOPANILoading"
		gui.IgnoreGuiInset = true
		gui.ResetOnSpawn = false
		gui.DisplayOrder = 2147483647
		gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		parentGui(gui)
		state.gui = gui

		-- Blur real no mundo 3D (atras da tela preta)
		local okb, blur = pcall(function()
			local b = Instance.new("BlurEffect")
			b.Size = 0
			b.Parent = game:GetService("Lighting")
			return b
		end)
		if okb then
			state.blur = blur
		end

		-- Fundo preto (com leve degrade roxo escuro embaixo)
		local bg = Instance.new("Frame")
		bg.Name = "Background"
		bg.Size = UDim2.fromScale(1, 1)
		bg.BackgroundColor3 = Color3.new(1, 1, 1)
		bg.BorderSizePixel = 0
		bg.Active = true
		bg.ZIndex = 1
		bg.Parent = gui
		local grad = Instance.new("UIGradient")
		grad.Color = ColorSequence.new(Color3.fromRGB(0, 0, 0), Color3.fromRGB(24, 8, 44))
		grad.Rotation = 90
		grad.Parent = bg

		local function T(base)
			return 1 - (1 - base) * state.fade
		end

		-- Particulas roxas tipo neve (ficam atras de tudo)
		local stage = Instance.new("Frame")
		stage.Name = "Stage"
		stage.Size = UDim2.fromScale(1, 1)
		stage.BackgroundTransparency = 1
		stage.BorderSizePixel = 0
		stage.ZIndex = 2
		stage.Parent = gui

		local sizes = { 2, 2, 3, 3, 3, 4, 4, 5, 6 }
		local flakes = {}
		for i = 1, FLAKES do
			local sz = sizes[math.random(1, #sizes)]
			local fr = Instance.new("Frame")
			fr.AnchorPoint = Vector2.new(0.5, 0.5)
			fr.Size = UDim2.fromOffset(sz, sz)
			fr.BackgroundColor3 = Color3.fromRGB(math.random(175, 230), math.random(110, 190), 255)
			fr.BorderSizePixel = 0
			fr.ZIndex = 2
			fr.Parent = stage
			round(fr)
			flakes[i] = {
				frame = fr,
				x = math.random(),
				y = math.random(),
				speed = 0.035 + sz * 0.012 + math.random() * 0.02,
				amp = 0.008 + math.random() * 0.02,
				freq = 0.6 + math.random() * 1.2,
				phase = math.random() * 6.28,
				wind = 0.006 + math.random() * 0.01,
				base = 0.7 - sz * 0.07,
			}
		end

		-- Centro da tela (tamanho 0): tudo abaixo fica posicionado a partir do centro
		-- e escala sozinho em telas pequenas.
		local holder = Instance.new("Frame")
		holder.Name = "Center"
		holder.AnchorPoint = Vector2.new(0.5, 0.5)
		holder.Position = UDim2.fromScale(0.5, 0.5)
		holder.Size = UDim2.fromOffset(0, 0)
		holder.BackgroundTransparency = 1
		holder.BorderSizePixel = 0
		holder.ZIndex = 3
		holder.Parent = gui
		local fit = Instance.new("UIScale")
		fit.Parent = holder
		local function refit()
			local vs = Vector2.new(1280, 720)
			pcall(function()
				vs = workspace.CurrentCamera.ViewportSize
			end)
			fit.Scale = math.clamp(math.min(vs.Y / 640, vs.X / 460), 0.5, 1)
		end
		refit()

		-- Listas de itens que so precisam acompanhar o fade (atualizadas so quando o fade muda)
		local fadeF, fadeS = {}, {}
		local function regF(obj, base)
			obj.BackgroundTransparency = 1
			fadeF[#fadeF + 1] = { obj = obj, base = base }
		end
		local function regS(obj, base)
			obj.Transparency = 1
			fadeS[#fadeS + 1] = { obj = obj, base = base }
		end

		local function circle(parent, size, color, z)
			local f = Instance.new("Frame")
			f.AnchorPoint = Vector2.new(0.5, 0.5)
			f.Size = UDim2.fromOffset(size, size)
			f.BackgroundColor3 = color
			f.BorderSizePixel = 0
			f.ZIndex = z or 1
			f.Parent = parent
			round(f)
			return f
		end

		local function stroke(parent, color, thickness)
			local s = Instance.new("UIStroke")
			s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
			s.Color = color
			s.Thickness = thickness
			s.Parent = parent
			return s
		end

		-- Glow roxo atras do logo (camadas concentricas que pulsam)
		local glows = {}
		for i = 1, 9 do
			local g = circle(holder, LOGO + i * 24, PURPLE, 1)
			g.Position = UDim2.fromOffset(0, CY)
			glows[i] = { frame = g, size = LOGO + i * 24 }
		end

		-- ================= LOGO: "L" dentro de um circulo =================
		local logo = Instance.new("Frame")
		logo.Name = "Logo"
		logo.AnchorPoint = Vector2.new(0.5, 0.5)
		logo.Position = UDim2.fromOffset(0, CY)
		logo.Size = UDim2.fromOffset(LOGO, LOGO)
		logo.BackgroundTransparency = 1
		logo.BorderSizePixel = 0
		logo.ZIndex = 5
		logo.Parent = holder
		local logoScale = Instance.new("UIScale")
		logoScale.Parent = logo

		-- aro externo com degrade girando + glow
		local ringFrame = circle(logo, LOGO, Color3.new(1, 1, 1), 1)
		ringFrame.Position = UDim2.fromScale(0.5, 0.5)
		ringFrame.BackgroundTransparency = 1 -- o aro e so contorno
		local ringLine = stroke(ringFrame, Color3.new(1, 1, 1), 3)
		regS(ringLine, 0)
		local ringGlow = stroke(ringFrame, VIOLET, 10)
		regS(ringGlow, 0.82)
		local ringGrad = Instance.new("UIGradient")
		ringGrad.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, LAVENDER),
			ColorSequenceKeypoint.new(0.35, PURPLE),
			ColorSequenceKeypoint.new(0.65, Color3.fromRGB(86, 36, 170)),
			ColorSequenceKeypoint.new(1, LAVENDER),
		})
		ringGrad.Parent = ringLine

		-- disco escuro com degrade roxo
		local disc = circle(logo, LOGO - 12, Color3.new(1, 1, 1), 2)
		disc.Position = UDim2.fromScale(0.5, 0.5)
		regF(disc, 0)
		local discGrad = Instance.new("UIGradient")
		discGrad.Color = ColorSequence.new(Color3.fromRGB(118, 54, 214), Color3.fromRGB(28, 11, 62))
		discGrad.Rotation = 70
		discGrad.Parent = disc
		regS(stroke(disc, Color3.fromRGB(205, 160, 255), 1.5), 0.45)

		-- aro fininho interno
		local inner = circle(logo, LOGO - 36, Color3.new(1, 1, 1), 3)
		inner.Position = UDim2.fromScale(0.5, 0.5)
		inner.BackgroundTransparency = 1
		regS(stroke(inner, Color3.fromRGB(190, 140, 255), 1), 0.72)

		-- reflexo de vidro no topo
		local sheen = Instance.new("Frame")
		sheen.AnchorPoint = Vector2.new(0.5, 0)
		sheen.Position = UDim2.new(0.5, 0, 0, 9)
		sheen.Size = UDim2.fromOffset(LOGO * 0.66, LOGO * 0.34)
		sheen.BackgroundColor3 = Color3.new(1, 1, 1)
		sheen.BorderSizePixel = 0
		sheen.ZIndex = 4
		sheen.Parent = logo
		round(sheen)
		regF(sheen, 0)
		local sheenGrad = Instance.new("UIGradient")
		sheenGrad.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.8),
			NumberSequenceKeypoint.new(1, 1),
		})
		sheenGrad.Rotation = 90
		sheenGrad.Parent = sheen

		-- brilho atras do L
		local lcore = circle(logo, 74, VIOLET, 4)
		lcore.Position = UDim2.fromScale(0.5, 0.5)
		regF(lcore, 0.88)

		-- L geometrico (duas barras arredondadas) + camadas de glow
		local LX, LY, LT, LH, LW = 46, 34, 18, 55, 36
		local function bar(x, y, w, h, color, base, radius, z)
			local f = Instance.new("Frame")
			f.Position = UDim2.fromOffset(x, y)
			f.Size = UDim2.fromOffset(w, h)
			f.BackgroundColor3 = color
			f.BorderSizePixel = 0
			f.ZIndex = z
			f.Parent = logo
			corner(f, radius)
			regF(f, base)
			return f
		end
		local function glowL(expand, color, base)
			local r = expand + 5
			bar(LX - expand, LY - expand, LT + expand * 2, LH + expand * 2, color, base, r, 5)
			bar(LX - expand, LY + LH - LT - expand, LW + expand * 2, LT + expand * 2, color, base, r, 5)
		end
		glowL(13, PURPLE, 0.94)
		glowL(9, VIOLET, 0.88)
		glowL(5, VIOLET, 0.78)
		glowL(2, LAVENDER, 0.55)
		local lv = bar(LX, LY, LT, LH, Color3.new(1, 1, 1), 0, 5, 6)
		local lvGrad = Instance.new("UIGradient")
		lvGrad.Color = ColorSequence.new(Color3.new(1, 1, 1), LAVENDER)
		lvGrad.Rotation = 90
		lvGrad.Parent = lv
		bar(LX, LY + LH - LT, LW, LT, LAVENDER, 0, 5, 6)

		-- ================= BOLINHAS ao redor, pulsando uma por uma =================
		local rings = {
			{ n = 16, r = 90, dot = 7, off = 0 },
			{ n = 24, r = 118, dot = 5, off = 0.5 / 24 },
			{ n = 32, r = 146, dot = 4, off = 0 },
		}
		local dots = {}
		for _, rg in ipairs(rings) do
			for i = 1, rg.n do
				local ang = -math.pi / 2 + (i - 1) / rg.n * math.pi * 2 -- comeca no topo, sentido horario
				local f = circle(holder, rg.dot, DOT_DIM, 3)
				f.Position = UDim2.fromOffset(math.cos(ang) * rg.r, CY + math.sin(ang) * rg.r)
				local st = stroke(f, VIOLET, 1)
				dots[#dots + 1] = {
					frame = f,
					stroke = st,
					base = rg.dot,
					shift = (i - 1) / rg.n + rg.off,
				}
			end
		end

		-- ================= Titulo =================
		local TITLE_Y = CY + 190
		local BAR_Y = CY + 232
		local STATUS_Y = CY + 262

		local title = Instance.new("TextLabel")
		title.AnchorPoint = Vector2.new(0.5, 0.5)
		title.Position = UDim2.fromOffset(0, TITLE_Y)
		title.Size = UDim2.fromOffset(320, 36)
		title.BackgroundTransparency = 1
		title.Font = Enum.Font.GothamBold
		title.Text = "LOCOPANI"
		title.TextSize = 28
		title.TextColor3 = Color3.fromRGB(236, 220, 255)
		title.ZIndex = 10
		title.Parent = holder
		local titleStroke = stroke(title, Color3.fromRGB(150, 70, 255), 1.5)

		-- ================= Barra de progresso retangular =================
		local barGlow = Instance.new("Frame")
		barGlow.AnchorPoint = Vector2.new(0.5, 0.5)
		barGlow.Position = UDim2.fromOffset(0, BAR_Y)
		barGlow.Size = UDim2.fromOffset(BAR_W + 24, 26)
		barGlow.BackgroundColor3 = PURPLE
		barGlow.BorderSizePixel = 0
		barGlow.ZIndex = 1
		barGlow.Parent = holder
		corner(barGlow, 8)

		local track = Instance.new("Frame")
		track.Name = "ProgressBar"
		track.AnchorPoint = Vector2.new(0.5, 0.5)
		track.Position = UDim2.fromOffset(0, BAR_Y)
		track.Size = UDim2.fromOffset(BAR_W, 10)
		track.BackgroundColor3 = Color3.fromRGB(26, 11, 52)
		track.BorderSizePixel = 0
		track.ZIndex = 6
		track.Parent = holder
		corner(track, 3)
		regF(track, 0)
		regS(stroke(track, Color3.fromRGB(120, 68, 220), 1), 0.35)

		local fill = Instance.new("Frame")
		fill.Name = "Fill"
		fill.Size = UDim2.new(0, 0, 1, 0)
		fill.BackgroundColor3 = Color3.new(1, 1, 1)
		fill.BorderSizePixel = 0
		fill.ClipsDescendants = true
		fill.ZIndex = 7
		fill.Parent = track
		corner(fill, 3)
		regF(fill, 0)
		local fillGrad = Instance.new("UIGradient")
		fillGrad.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(110, 48, 228)),
			ColorSequenceKeypoint.new(0.6, Color3.fromRGB(165, 92, 255)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(228, 196, 255)),
		})
		fillGrad.Parent = fill

		-- brilho que corre dentro do preenchimento
		local shine = Instance.new("Frame")
		shine.Size = UDim2.new(0, 46, 1, 0)
		shine.BackgroundColor3 = Color3.new(1, 1, 1)
		shine.BorderSizePixel = 0
		shine.ZIndex = 8
		shine.Parent = fill
		regF(shine, 0)
		local shineGrad = Instance.new("UIGradient")
		shineGrad.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.5, 0.55),
			NumberSequenceKeypoint.new(1, 1),
		})
		shineGrad.Parent = shine

		-- divisorias a cada 10%
		for i = 1, 9 do
			local mark = Instance.new("Frame")
			mark.AnchorPoint = Vector2.new(0.5, 0)
			mark.Position = UDim2.new(i / 10, 0, 0, 0)
			mark.Size = UDim2.new(0, 1, 1, 0)
			mark.BackgroundColor3 = Color3.fromRGB(10, 4, 22)
			mark.BorderSizePixel = 0
			mark.ZIndex = 9
			mark.Parent = track
			regF(mark, 0.55)
		end

		-- ponta brilhante na frente do preenchimento
		local tip = Instance.new("Frame")
		tip.AnchorPoint = Vector2.new(0.5, 0.5)
		tip.Position = UDim2.new(0, 0, 0.5, 0)
		tip.Size = UDim2.fromOffset(4, 18)
		tip.BackgroundColor3 = Color3.new(1, 1, 1)
		tip.BorderSizePixel = 0
		tip.ZIndex = 10
		tip.Parent = track
		corner(tip, 2)
		local tipStroke = stroke(tip, VIOLET, 3)

		-- Porcentagem
		local status = Instance.new("TextLabel")
		status.AnchorPoint = Vector2.new(0.5, 0.5)
		status.Position = UDim2.fromOffset(0, STATUS_Y)
		status.Size = UDim2.fromOffset(320, 22)
		status.BackgroundTransparency = 1
		status.Font = Enum.Font.Gotham
		status.Text = "Carregando... 0%"
		status.TextSize = 16
		status.TextColor3 = Color3.fromRGB(175, 135, 235)
		status.ZIndex = 10
		status.Parent = holder

		-- Onde procurar o painel principal para esconde-lo durante o carregamento
		local roots = {}
		pcall(function()
			if type(gethui) == "function" then
				local h = gethui()
				if typeof(h) == "Instance" then
					roots[#roots + 1] = h
				end
			end
		end)
		pcall(function()
			roots[#roots + 1] = game:GetService("CoreGui")
		end)
		pcall(function()
			roots[#roots + 1] = game:GetService("Players").LocalPlayer.PlayerGui
		end)

		local lastPct = -1
		local lastFade = -1

		state.conn = RunService.RenderStepped:Connect(function(dt)
			dt = math.min(dt, 0.1)
			local now = os.clock() - state.t0
			state.fade = state.fade + (state.target - state.fade) * math.min(1, dt * 6)
			local f = state.fade
			state.frame = state.frame + 1

			if state.target == 0 and f < 0.02 then
				destroy()
				return
			end
			if state.target == 1 and os.clock() - state.shownAt > MAX_TIME then
				LOADER.Hide(true)
			end

			-- Esconde o painel principal enquanto a tela de carregamento estiver ativa
			if state.target == 1 then
				for g in pairs(state.held) do
					if g.Parent and g.Enabled then
						g.Enabled = false -- impede o painel de reaparecer
					end
				end
				if state.frame % 4 == 0 then
					for _, r in ipairs(roots) do
						pcall(function()
							local g = r:FindFirstChild("LOCOPANIArgonUI")
							if g then
								LOADER.Hold(g)
							end
						end)
					end
				end
			end

			if state.frame % 30 == 0 then
				refit()
			end

			-- Progresso 0..1 (chega em 100% em MIN_TIME segundos)
			local prog
			if state.target == 0 then
				prog = state.lastProg
			else
				local p = math.min((os.clock() - state.shownAt) / (MIN_TIME - HOLD_100), 1)
				local sm = p * p * (3 - 2 * p)
				prog = p * 0.5 + sm * 0.5
				if p >= 1 and not state.hideRequested then
					prog = 0.99 -- espera o script terminar
				end
				state.lastProg = prog
			end

			bg.BackgroundTransparency = T(1 - BG_ALPHA)
			if state.blur then
				state.blur.Size = BLUR_SIZE * f
			end

			-- Itens estaticos: so atualiza quando o fade muda
			if math.abs(f - lastFade) > 0.002 then
				lastFade = f
				for _, it in ipairs(fadeF) do
					it.obj.BackgroundTransparency = T(it.base)
				end
				for _, it in ipairs(fadeS) do
					it.obj.Transparency = T(it.base)
				end
				title.TextTransparency = 1 - f
				titleStroke.Transparency = T(0.5)
				status.TextTransparency = 1 - f
			end

			-- Glow pulsando
			local pulse = 1 + 0.05 * math.sin(now * 2.2)
			for _, g in ipairs(glows) do
				local s = g.size * pulse
				g.frame.Size = UDim2.fromOffset(s, s)
				g.frame.BackgroundTransparency = T(0.93)
			end

			-- Logo: aro girando e leve "respiracao"
			ringGrad.Rotation = (now * 80) % 360
			logoScale.Scale = 1 + 0.025 * math.sin(now * 2.2)

			-- Neve roxa
			for _, fl in ipairs(flakes) do
				fl.y = fl.y + fl.speed * dt
				fl.x = fl.x + fl.wind * dt
				if fl.y > 1.04 then
					fl.y = -0.04
					fl.x = math.random()
				end
				if fl.x > 1.04 then
					fl.x = -0.04
				end
				fl.frame.Position = UDim2.fromScale(fl.x + math.sin(now * fl.freq + fl.phase) * fl.amp, fl.y)
				fl.frame.BackgroundTransparency = T(fl.base + 0.1 * math.sin(now * 2 + fl.phase))
			end

			-- Bolinhas: cada uma pulsa uma vez por PULSE_PERIOD, uma depois da outra (sentido horario)
			local t = now / PULSE_PERIOD
			local parity = state.frame % 2
			for idx, d in ipairs(dots) do
				if idx % 2 == parity then
					local ph = (t - d.shift) % 1
					local k = math.min(1, ph / 0.06) * (1 - ph) ^ 3
					k = math.min(1, k * 1.25)
					local size = d.base * (1 + 0.9 * k)
					d.frame.Size = UDim2.fromOffset(size, size)
					d.frame.BackgroundColor3 = DOT_DIM:Lerp(DOT_HOT, k)
					d.frame.BackgroundTransparency = T(0.6 - 0.6 * k)
					d.stroke.Transparency = T(0.92 - 0.72 * k)
					d.stroke.Thickness = 1 + 3 * k
				end
			end

			-- Barra
			local fillPx = BAR_W * prog
			fill.Size = UDim2.new(prog, 0, 1, 0)
			shine.Position = UDim2.fromOffset(((now * 0.9) % 1) * (fillPx + 70) - 50, 0)
			tip.Position = UDim2.new(prog, 0, 0.5, 0)
			tip.BackgroundTransparency = T(prog > 0.005 and 0.05 or 1)
			tipStroke.Transparency = T(prog > 0.005 and 0.55 or 1)
			barGlow.Size = UDim2.fromOffset((BAR_W + 24) * pulse, 26 * pulse)
			barGlow.BackgroundTransparency = T(0.92 - 0.12 * prog)

			local pct = math.floor(prog * 100 + 0.0001)
			if pct ~= lastPct then
				lastPct = pct
				status.Text = "Carregando... " .. pct .. "%"
			end
		end)
	end

	function LOADER.Show()
		state.token = state.token + 1
		state.target = 1
		state.hideRequested = false
		state.shownAt = os.clock()
		state.lastProg = 0
		if state.gui then
			return
		end
		state.fade = 0
		state.t0 = os.clock()
		local ok, err = pcall(build)
		if not ok then
			destroy()
			warn("[LOCOPANI] tela de carregamento falhou: " .. tostring(err))
		end
	end

	function LOADER.Hide(instant)
		if not state.gui then
			return
		end
		state.token = state.token + 1
		state.hideRequested = true
		local token = state.token
		local wait_for = 0
		if not instant then
			local elapsed = os.clock() - state.shownAt
			wait_for = (elapsed < MIN_TIME) and (MIN_TIME - elapsed) or HOLD_100
		end
		task.spawn(function()
			if wait_for > 0 then
				task.wait(wait_for)
			end
			if token == state.token then
				if not instant then
					state.lastProg = 1
				end
				state.target = 0
				release() -- barra em 100%: mostra o painel
			end
		end)
	end

	-- Mantem um ScreenGui escondido ate a barra chegar a 100%
	function LOADER.Hold(g)
		if state.target ~= 1 or not state.gui then
			return
		end
		if typeof(g) ~= "Instance" or not g:IsA("ScreenGui") then
			return
		end
		if state.held[g] ~= nil then
			return
		end
		state.held[g] = g.Enabled
		pcall(function()
			g.Enabled = false
		end)
		if DEBUG then
			warn("[LOCOPANI] loader escondeu: " .. g.Name)
		end
	end

	-- Executa fn quando a barra chegar a 100% (ou na hora, se a tela nao estiver ativa)
	function LOADER.OnReveal(fn)
		if state.gui and state.target == 1 then
			state.onReveal[#state.onReveal + 1] = fn
		else
			task.spawn(function()
				pcall(fn)
			end)
		end
	end

	pcall(LOADER.Show)
end

-- ============================================================
-- LOCOPANI Cursor Realista (V2)
-- Cursor em alta resolucao (imagem embutida no proprio script):
--   * seta com contorno, degrade lavanda, brilho roxo e sombra
--   * vira "maozinha" sobre botoes e "I" sobre caixas de texto
--   * efeito de clique (aperta + ondas roxas)
--   * continua ativo mesmo com o painel fechado, e depois de reabrir
-- Se o executor nao suportar writefile/getcustomasset, usa uma seta
-- desenhada por codigo (mais simples) para nao quebrar.
-- ============================================================
do
	local env = (type(getgenv) == "function" and getgenv()) or _G

	-- ---------- AJUSTES ----------
	local SCALE = 1.0 -- tamanho do cursor (0.8 menor, 1.3 maior)
	local ALWAYS_ON = true -- true = tambem aparece com o painel fechado
	local SMART_ICONS = true -- maozinha em botoes / "I" em caixas de texto
	local RIPPLE = Color3.fromRGB(190, 130, 255)

	-- ---------- limpa versao anterior ----------
	if env.LOCOPANI_REAL_CURSOR and type(env.LOCOPANI_REAL_CURSOR.Destroy) == "function" then
		pcall(env.LOCOPANI_REAL_CURSOR.Destroy)
	end
	local API = { alive = false, window = nil }
	env.LOCOPANI_REAL_CURSOR = API

	-- imagem do cursor (3 sprites 128x128 lado a lado: seta | mao | texto)
	local SHEET_B64 = [=[
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]=]

	local function b64decode(s)
		s = s:gsub("[^%w%+/]", "")
		local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
		local map = {}
		for i = 1, #chars do
			map[chars:byte(i)] = i - 1
		end
		local bytes, n = {}, 0
		local buf, bits = 0, 0
		for i = 1, #s do
			buf = buf * 64 + map[s:byte(i)]
			bits = bits + 6
			if bits >= 8 then
				bits = bits - 8
				local p = 2 ^ bits
				local b = math.floor(buf / p)
				buf = buf - b * p
				n = n + 1
				bytes[n] = b
			end
		end
		local unpackFn = table.unpack or unpack
		local parts = {}
		local i = 1
		while i <= n do
			local j = math.min(i + 3999, n)
			parts[#parts + 1] = string.char(unpackFn(bytes, i, j))
			i = j + 1
		end
		return table.concat(parts)
	end
	API._b64decode = b64decode

	local function loadSheetAsset()
		local writefileFn = env.writefile or writefile
		local assetFn = env.getcustomasset or getcustomasset or env.getsynasset or getsynasset
		if type(writefileFn) ~= "function" or type(assetFn) ~= "function" then
			return nil
		end
		local ok, asset = pcall(function()
			local name = "locopani_cursor_sheet_v2.png"
			writefileFn(name, b64decode(SHEET_B64))
			return assetFn(name)
		end)
		if ok and type(asset) == "string" and asset ~= "" then
			return asset
		end
		return nil
	end

	-- sprites: posicao na imagem e "ponta" (hotspot) de cada um, em pixels da imagem 128x128
	local SPRITES = {
		arrow = { x = 0, hx = 21, hy = 13 },
		hand = { x = 128, hx = 44, hy = 18 },
		ibeam = { x = 256, hx = 64, hy = 64 },
	}
	local SHOWN = 64 * SCALE -- tamanho mostrado na tela (a imagem e 2x mais nitida)

	local function start()
		local UserInputService = game:GetService("UserInputService")
		local RunService = game:GetService("RunService")
		local TweenService = game:GetService("TweenService")
		local GuiService = game:GetService("GuiService")
		local Players = game:GetService("Players")

		-- celular/tablet nao tem cursor
		if not UserInputService.MouseEnabled then
			return
		end
		API.alive = true

		-- ---------- ScreenGui ----------
		local gui = Instance.new("ScreenGui")
		gui.Name = "LOCOPANICursor"
		gui.IgnoreGuiInset = true
		gui.ResetOnSpawn = false
		gui.DisplayOrder = 2147483647
		gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		pcall(function()
			if syn and syn.protect_gui then
				syn.protect_gui(gui)
			end
		end)
		local function parentGui()
			if type(gethui) == "function" then
				local ok, hui = pcall(gethui)
				if ok and typeof(hui) == "Instance" and pcall(function()
					gui.Parent = hui
				end) then
					return
				end
			end
			if pcall(function()
				gui.Parent = game:GetService("CoreGui")
			end) then
				return
			end
			gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
		end
		parentGui()

		-- raiz = ponta do cursor (onde o mouse realmente clica)
		local root = Instance.new("Frame")
		root.Name = "Cursor"
		root.BackgroundTransparency = 1
		root.BorderSizePixel = 0
		root.Size = UDim2.fromOffset(0, 0)
		root.Active = false
		root.Visible = false
		root.ZIndex = 100
		root.Parent = gui
		local press = Instance.new("UIScale")
		press.Scale = 1
		press.Parent = root
		local holder = Instance.new("Frame")
		holder.BackgroundTransparency = 1
		holder.BorderSizePixel = 0
		holder.Size = UDim2.fromOffset(0, 0)
		holder.Active = false
		holder.ZIndex = 100
		holder.Parent = root
		local pop = Instance.new("UIScale")
		pop.Scale = 1
		pop.Parent = holder

		local img = Instance.new("ImageLabel")
		img.Name = "Sprite"
		img.BackgroundTransparency = 1
		img.BorderSizePixel = 0
		img.Active = false
		img.ZIndex = 100
		img.Size = UDim2.fromOffset(SHOWN, SHOWN)
		img.ImageRectSize = Vector2.new(128, 128)
		img.Parent = holder

		local kind = "arrow"
		local function applySprite()
			local s = SPRITES[kind]
			img.ImageRectOffset = Vector2.new(s.x, 0)
			img.Position = UDim2.fromOffset(-s.hx / 2 * SCALE, -s.hy / 2 * SCALE)
		end
		applySprite()

		-- ---------- seta de reserva (sem imagem) ----------
		local fallbackBuilt = false
		local function buildFallbackArrow()
			if fallbackBuilt then
				return
			end
			fallbackBuilt = true
			img.Visible = false
			local FS = 1.4
			local OUTLINE = Color3.fromRGB(18, 10, 32)
			local PAD = 3
			local PTS = { { 0, 0 }, { 0, 17 }, { 4.2, 13.2 }, { 7.4, 20.2 }, { 10.3, 18.9 }, { 7.1, 12.2 }, { 12.4, 12.2 } }
			local poly = {}
			for i, p in ipairs(PTS) do
				poly[i] = { p[1] * FS, p[2] * FS }
			end
			local W = math.ceil(12.4 * FS) + PAD + 9
			local H = math.ceil(20.2 * FS) + PAD + 9
			local function segDist(px, py, ax, ay, bx, by)
				local abx, aby = bx - ax, by - ay
				local t = math.clamp(((px - ax) * abx + (py - ay) * aby) / (abx * abx + aby * aby), 0, 1)
				local dx, dy = px - (ax + abx * t), py - (ay + aby * t)
				return math.sqrt(dx * dx + dy * dy)
			end
			local function sdf(px, py)
				local dmin, inside = math.huge, false
				local n = #poly
				local j = n
				for i = 1, n do
					local a, b = poly[j], poly[i]
					dmin = math.min(dmin, segDist(px, py, a[1], a[2], b[1], b[2]))
					if (a[2] > py) ~= (b[2] > py) and px < (a[1] - b[1]) * (py - b[2]) / (a[2] - b[2]) + b[1] then
						inside = not inside
					end
					j = i
				end
				return inside and -dmin or dmin
			end
			local function addRuns(vals, n, y, color, z)
				local i = 1
				while i <= n do
					local v = vals[i]
					if v == 0 then
						i = i + 1
					else
						local j = i
						while j < n and vals[j + 1] == v do
							j = j + 1
						end
						local f = Instance.new("Frame")
						f.BorderSizePixel = 0
						f.Active = false
						f.BackgroundColor3 = color
						f.BackgroundTransparency = 1 - v / 10
						f.Position = UDim2.fromOffset(i - 1 - PAD, y - PAD)
						f.Size = UDim2.fromOffset(j - i + 1, 1)
						f.ZIndex = z
						f.Parent = holder
						i = j + 1
					end
				end
			end
			for gy = 0, H - 1 do
				local wy = gy + 0.5 - PAD
				local bl, wh = {}, {}
				for gx = 0, W - 1 do
					local d = sdf(gx + 0.5 - PAD, wy)
					local cw = math.floor(math.clamp(-0.15 - d, 0, 1) * 10 + 0.5)
					local cb = math.floor(math.clamp(1.15 - d, 0, 1) * 10 + 0.5)
					if cw == 10 then
						cb = 0
					end
					bl[gx + 1] = cb
					wh[gx + 1] = cw
				end
				local t = gy / H
				local fill = Color3.fromRGB(math.floor(255 - 29 * t), math.floor(255 - 43 * t), math.floor(255 - 5 * t))
				addRuns(bl, W, gy, OUTLINE, 101)
				addRuns(wh, W, gy, fill, 102)
			end
		end

		local sheet = loadSheetAsset()
		if sheet then
			img.Image = sheet
			-- se a imagem nao carregar em ate 4s, usa a seta de reserva
			task.spawn(function()
				local waited = 0
				while API.alive and not img.IsLoaded and waited < 4 do
					task.wait(0.1)
					waited = waited + 0.1
				end
				if API.alive and not img.IsLoaded then
					buildFallbackArrow()
				end
			end)
		else
			buildFallbackArrow()
		end

		-- ---------- efeitos ----------
		local function setKind(newKind)
			if newKind == kind then
				return
			end
			kind = newKind
			applySprite()
			pop.Scale = 0.8
			TweenService:Create(pop, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
		end

		local function ring(delay, from, to, thickness, life)
			task.delay(delay, function()
				if not API.alive then
					return
				end
				local mp = UserInputService:GetMouseLocation()
				local r = Instance.new("Frame")
				r.AnchorPoint = Vector2.new(0.5, 0.5)
				r.Position = UDim2.fromOffset(mp.X, mp.Y)
				r.Size = UDim2.fromOffset(from, from)
				r.BackgroundTransparency = 1
				r.BorderSizePixel = 0
				r.Active = false
				r.ZIndex = 1
				r.Parent = gui
				local rc = Instance.new("UICorner")
				rc.CornerRadius = UDim.new(1, 0)
				rc.Parent = r
				local st = Instance.new("UIStroke")
				st.Color = RIPPLE
				st.Thickness = thickness
				st.Transparency = 0.1
				st.Parent = r
				local info = TweenInfo.new(life, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
				TweenService:Create(r, info, { Size = UDim2.fromOffset(to, to) }):Play()
				TweenService:Create(st, info, { Transparency = 1, Thickness = 0.4 }):Play()
				task.delay(life + 0.05, function()
					if r.Parent then
						r:Destroy()
					end
				end)
			end)
		end

		local connections = {}
		connections[#connections + 1] = UserInputService.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 and root.Visible then
				TweenService:Create(press, TweenInfo.new(0.06, Enum.EasingStyle.Quad), { Scale = 0.84 }):Play()
				ring(0, 8, 54, 2.2, 0.45)
				ring(0.07, 6, 34, 1.4, 0.38)
			end
		end)
		connections[#connections + 1] = UserInputService.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				TweenService:Create(press, TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
			end
		end)

		-- ---------- icone do mouse do sistema ----------
		-- gameWants = o que o jogo quer (seta do Roblox visivel ou escondida)
		local gameWants = UserInputService.MouseIconEnabled
		local selfSet = false
		local hidingSystem = false
		local function setSystemIcon(v)
			if UserInputService.MouseIconEnabled ~= v then
				selfSet = true
				pcall(function()
					UserInputService.MouseIconEnabled = v
				end)
				selfSet = false
			end
		end
		connections[#connections + 1] = UserInputService:GetPropertyChangedSignal("MouseIconEnabled"):Connect(function()
			if not selfSet then
				gameWants = UserInputService.MouseIconEnabled
			end
		end)

		-- ---------- detecta botao / caixa de texto embaixo do mouse ----------
		local cands, candConns, boundSG = {}, {}, nil
		local function isCand(o)
			return o:IsA("GuiButton") or o:IsA("TextBox")
		end
		local function bindWindow(w)
			for _, c in ipairs(candConns) do
				pcall(function()
					c:Disconnect()
				end)
			end
			candConns, cands, boundSG = {}, {}, nil
			local sg = w and w.ScreenGui
			if typeof(sg) ~= "Instance" then
				return
			end
			boundSG = sg
			for _, o in ipairs(sg:GetDescendants()) do
				if isCand(o) then
					cands[o] = true
				end
			end
			candConns[1] = sg.DescendantAdded:Connect(function(o)
				if isCand(o) then
					cands[o] = true
				end
			end)
			candConns[2] = sg.DescendantRemoving:Connect(function(o)
				cands[o] = nil
			end)
		end
		local boundWindow = nil

		local function chainVisible(o, rootGui)
			local p = o
			while p and p ~= rootGui do
				if p:IsA("GuiObject") and not p.Visible then
					return false
				end
				p = p.Parent
			end
			return p == rootGui and rootGui.Enabled ~= false
		end

		local function insidePanel(mp, main)
			if typeof(main) ~= "Instance" then
				return false
			end
			local ok, res = pcall(function()
				local sgInset = (boundSG and boundSG.IgnoreGuiInset) and 0 or GuiService:GetGuiInset().Y
				local pos, size = main.AbsolutePosition, main.AbsoluteSize
				local my = mp.Y - sgInset
				return mp.X >= pos.X and mp.X <= pos.X + size.X and my >= pos.Y and my <= pos.Y + size.Y
			end)
			return ok and res
		end

		local function hoverKind(mp, main)
			local sg = boundSG
			local found = nil
			if sg and sg.Parent then
				local inset = sg.IgnoreGuiInset and 0 or GuiService:GetGuiInset().Y
				local mx, my = mp.X, mp.Y - inset
				for o in pairs(cands) do
					local pos, size = o.AbsolutePosition, o.AbsoluteSize
					if
						mx >= pos.X
						and mx <= pos.X + size.X
						and my >= pos.Y
						and my <= pos.Y + size.Y
						and size.X * size.Y < 250000
						and chainVisible(o, sg)
					then
						if o:IsA("TextBox") then
							return "ibeam"
						end
						found = "hand"
					end
				end
				if found then
					return found
				end
			end
			-- interface do proprio jogo (so quando o mouse nao esta sobre o painel)
			if insidePanel(mp, main) then
				return nil
			end
			local pg = Players.LocalPlayer and Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
			if pg then
				local ok, list = pcall(function()
					local inset = GuiService:GetGuiInset()
					return pg:GetGuiObjectsAtPosition(mp.X - inset.X, mp.Y - inset.Y)
				end)
				if ok and type(list) == "table" then
					for i = 1, math.min(#list, 8) do
						local o = list[i]
						if o:IsA("TextBox") then
							return "ibeam"
						elseif o:IsA("GuiButton") then
							local vis = true
							local p = o
							while p and not p:IsA("ScreenGui") do
								if p:IsA("GuiObject") and not p.Visible then
									vis = false
									break
								end
								p = p.Parent
							end
							if vis then
								return "hand"
							end
						end
					end
				end
			end
			return nil
		end

		-- silencia o cursor original da janela (Argon)
		local function silenceOriginal(w)
			local cg = w and w.CursorGui
			if typeof(cg) ~= "Instance" then
				return
			end
			if cg:IsA("ScreenGui") then
				if cg.Enabled then
					cg.Enabled = false
				end
			elseif cg:IsA("GuiObject") then
				if cg.Visible then
					cg.Visible = false
				end
			end
		end

		function API.Destroy()
			API.alive = false
			for _, c in ipairs(connections) do
				pcall(function()
					c:Disconnect()
				end)
			end
			connections = {}
			for _, c in ipairs(candConns) do
				pcall(function()
					c:Disconnect()
				end)
			end
			candConns = {}
			if API.loop then
				pcall(function()
					API.loop:Disconnect()
				end)
				API.loop = nil
			end
			if hidingSystem then
				setSystemIcon(gameWants)
			end
			pcall(function()
				gui:Destroy()
			end)
		end

		local frame = 0
		API.loop = RunService.RenderStepped:Connect(function()
			frame = frame + 1
			if gui.Parent == nil then
				pcall(parentGui)
			end

			local w = API.window
			if w ~= boundWindow then
				boundWindow = w
				pcall(bindWindow, w)
			end
			local main = w and w.Main
			local sg = w and w.ScreenGui
			-- V27: tambem conta como "painel visivel" enquanto a animacao do buraco negro esta rodando
			-- (a janela e escondida um pouco antes do fim do fechamento; o cursor nao pode sumir antes).
			local panelVisible = (typeof(main) == "Instance"
				and main.Parent ~= nil
				and main.Visible
				and (typeof(sg) ~= "Instance" or sg.Enabled))
				or (w ~= nil and w._LOCOPANI_Animating == true and typeof(sg) == "Instance" and sg.Enabled)

			local show = panelVisible or (ALWAYS_ON and gameWants)
			if show then
				-- mouse travado no centro (shift lock) ou menu do Roblox aberto: nao desenha
				if UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter or GuiService.MenuIsOpen then
					show = false
				end
			end

			if show then
				local mp = UserInputService:GetMouseLocation()
				root.Position = UDim2.fromOffset(mp.X, mp.Y)
				if not root.Visible then
					root.Visible = true
				end
				hidingSystem = true
				setSystemIcon(false)
				if panelVisible then
					silenceOriginal(w)
				end
				if SMART_ICONS and frame % 2 == 0 then
					local ok, k = pcall(hoverKind, mp, main)
					setKind((ok and k) or "arrow")
				end
			else
				if root.Visible then
					root.Visible = false
				end
				if hidingSystem then
					hidingSystem = false
					setSystemIcon(gameWants)
				end
			end
		end)
	end

	-- liga o cursor e permite que o painel se registre depois
	env.LOCOPANI_ApplyRealCursor = function(window)
		if not API.alive then
			pcall(start)
		end
		API.window = window
	end

	pcall(start)
end

-- LOCOPANI: baixa a UI (Argon) com vários métodos, para funcionar em mais executores.
do
    local env = (type(getgenv) == "function" and getgenv()) or _G
    env.LOCOPANI_LOAD_ARGON = function()
        local url = "https://raw.githubusercontent.com/JirkaachS/argon-ui/main/argon-ui.luau"
        local src

        local function good(ok, res)
            return ok and type(res) == "string" and #res > 0
        end

        -- 1) game:HttpGet / HttpGetAsync
        local ok, res = pcall(function() return game:HttpGet(url) end)
        if good(ok, res) then src = res end
        if not src then
            ok, res = pcall(function() return game:HttpGet(url, true) end)
            if good(ok, res) then src = res end
        end
        if not src then
            ok, res = pcall(function() return game:HttpGetAsync(url) end)
            if good(ok, res) then src = res end
        end

        -- 2) função request do executor (nomes diferentes em cada executor)
        if not src then
            local fn = env.request or env.http_request or env.httprequest
                or (type(request) == "function" and request)
                or (type(http_request) == "function" and http_request)
                or (type(httprequest) == "function" and httprequest)
            if not fn then
                for _, c in ipairs({ env.syn, env.http, env.fluxus, syn, http, fluxus }) do
                    if type(c) == "table" and type(c.request) == "function" then fn = c.request break end
                end
            end
            if type(fn) == "function" then
                local ok2, r = pcall(fn, { Url = url, Method = "GET" })
                if ok2 and type(r) == "table" and type(r.Body) == "string" and #r.Body > 0 then
                    src = r.Body
                end
            end
        end

        if not src then
            error("LOCOPANI: não consegui baixar a interface (UI). O executor bloqueou o download ou está sem internet.", 0)
        end

        local loader = loadstring or load
        if type(loader) ~= "function" then
            error("LOCOPANI: este executor não suporta loadstring.", 0)
        end
        local fn, err = loader(src)
        if not fn then
            error("LOCOPANI: falha ao ler a interface (UI): " .. tostring(err), 0)
        end
        return fn()
    end
end

local LOCOPANI_RAY_WINDOW
local LOCOPANI_RAYFIELD
local LOCOPANI_RAY_VISIBLE = true

-- LOCOPANI Matte Purple: fundo sólido, borda neon roxa e glow externo.
local function LOCOPANI_AddRainbowAccent(window)
    if not window or not window.Main then return end

    local main = window.Main
    if not main:IsA("GuiObject") then return end
    if main:FindFirstChild("LOCOPANI_RainbowBorder") then return end

    local purple = Color3.fromRGB(145, 65, 255)
    local deepPurple = Color3.fromRGB(25, 12, 43)

    pcall(function()
        main.BackgroundColor3 = deepPurple
        main.BackgroundTransparency = 0
    end)

    local sidebar = window.Sidebar
    if sidebar and sidebar:IsA("GuiObject") then
        pcall(function()
            sidebar.BackgroundColor3 = Color3.fromRGB(19, 10, 34)
            sidebar.BackgroundTransparency = 0
        end)
        local squareEdge = sidebar:FindFirstChild("SquareEdge")
        if squareEdge and squareEdge:IsA("GuiObject") then
            squareEdge.BackgroundTransparency = 0
            squareEdge.BackgroundColor3 = Color3.fromRGB(19, 10, 34)
        end
    end

    for _, child in ipairs(main:GetChildren()) do
        if child:IsA("UIStroke") then
            child.Enabled = false
        end
    end

    local outerGlow = Instance.new("UIStroke")
    outerGlow.Name = "LOCOPANI_RainbowGlow"
    outerGlow.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    outerGlow.Color = purple
    outerGlow.Thickness = 7
    outerGlow.Transparency = 0.48
    outerGlow.Parent = main

    local border = Instance.new("UIStroke")
    border.Name = "LOCOPANI_RainbowBorder"
    border.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    border.Color = Color3.fromRGB(180, 115, 255)
    border.Thickness = 1.8
    border.Transparency = 0.02
    border.Parent = main

    local pulseInfo = TweenInfo.new(1.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
    game:GetService("TweenService"):Create(outerGlow, pulseInfo, {
        Transparency = 0.68,
        Thickness = 5
    }):Play()
end

-- Partículas flutuam em várias direções; o brilho acompanha o cursor no ponto correto.
local function LOCOPANI_AddSiteEffects(window)
    if not window or not window.Main then return end

    local main = window.Main
    if not main:IsA("GuiObject") then return end
    if main:FindFirstChild("LOCOPANI_SiteEffects") then return end

    local tweenService = game:GetService("TweenService")
    local userInputService = game:GetService("UserInputService")
    local guiService = game:GetService("GuiService")
    local screenGui = window.ScreenGui

    local layer = Instance.new("Frame")
    layer.Name = "LOCOPANI_SiteEffects"
    layer.BackgroundTransparency = 1
    layer.BorderSizePixel = 0
    layer.Size = UDim2.fromScale(1, 1)
    layer.Position = UDim2.fromScale(0, 0)
    layer.ClipsDescendants = true
    layer.Active = false
    layer.Selectable = false
    layer.ZIndex = 20
    layer.Parent = main

    -- Slime trail: pequenas gotas elásticas que seguem o cursor e desaparecem suavemente.
    local trailFolder = Instance.new("Folder")
    trailFolder.Name = "LOCOPANI_SlimeTrail"
    trailFolder.Parent = layer

    local trailPool = {}
    local trailIndex = 0
    for i = 1, 9 do
        local blob = Instance.new("Frame")
        blob.Name = "SlimeBlob"
        blob.AnchorPoint = Vector2.new(0.5, 0.5)
        blob.Size = UDim2.fromOffset(18, 18)
        blob.BackgroundColor3 = Color3.fromRGB(165, 90, 255)
        blob.BackgroundTransparency = 0.18
        blob.BorderSizePixel = 0
        blob.Visible = false
        blob.ZIndex = 24
        blob.Parent = trailFolder
        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(1, 0)
        corner.Parent = blob
        local stroke = Instance.new("UIStroke")
        stroke.Color = Color3.fromRGB(220, 185, 255)
        stroke.Thickness = 1.2
        stroke.Transparency = 0.25
        stroke.Parent = blob
        trailPool[i] = {frame = blob, stroke = stroke}
    end

    local function spawnSlime(x, y, speed)
        trailIndex = trailIndex % #trailPool + 1
        local item = trailPool[trailIndex]
        local blob, stroke = item.frame, item.stroke
        if not blob.Parent then return end
        local size = math.random(9, 17)
        blob.Position = UDim2.fromOffset(x, y)
        blob.Size = UDim2.fromOffset(size * 1.35, size * 0.78)
        blob.Rotation = math.random(-25, 25)
        blob.BackgroundTransparency = 0.12
        stroke.Transparency = 0.18
        blob.Visible = true
        local duration = math.clamp(0.34 - (speed or 0) * 0.00012, 0.19, 0.34)
        tweenService:Create(blob, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
            Size = UDim2.fromOffset(2, 2),
            BackgroundTransparency = 1,
            Rotation = blob.Rotation + math.random(-35, 35),
        }):Play()
        tweenService:Create(stroke, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
            Transparency = 1,
            Thickness = 0.2,
        }):Play()
        task.delay(duration + 0.03, function()
            if blob.Parent then blob.Visible = false end
        end)
    end

    -- Clique: anel que expande como uma bolha estourando + gotículas radiais.
    local function popBubble(x, y)
        local ring = Instance.new("Frame")
        ring.Name = "LOCOPANI_BubblePop"
        ring.AnchorPoint = Vector2.new(0.5, 0.5)
        ring.Position = UDim2.fromOffset(x, y)
        ring.Size = UDim2.fromOffset(8, 8)
        ring.BackgroundTransparency = 1
        ring.BorderSizePixel = 0
        ring.ZIndex = 27
        ring.Parent = layer
        local round = Instance.new("UICorner")
        round.CornerRadius = UDim.new(1, 0)
        round.Parent = ring
        local outline = Instance.new("UIStroke")
        outline.Color = Color3.fromRGB(205, 155, 255)
        outline.Thickness = 3
        outline.Transparency = 0.08
        outline.Parent = ring
        tweenService:Create(ring, TweenInfo.new(0.38, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
            Size = UDim2.fromOffset(76, 76),
        }):Play()
        tweenService:Create(outline, TweenInfo.new(0.34, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
            Transparency = 1,
            Thickness = 0.4,
        }):Play()
        task.delay(0.42, function()
            if ring.Parent then ring:Destroy() end
        end)

        for i = 1, 8 do
            local angle = (math.pi * 2) * (i / 8)
            local distance = math.random(24, 48)
            local dot = Instance.new("Frame")
            dot.Name = "LOCOPANI_BubbleDroplet"
            dot.AnchorPoint = Vector2.new(0.5, 0.5)
            dot.Position = UDim2.fromOffset(x, y)
            local dotSize = math.random(4, 8)
            dot.Size = UDim2.fromOffset(dotSize, dotSize)
            dot.BackgroundColor3 = (i % 2 == 0)
                and Color3.fromRGB(225, 195, 255)
                or Color3.fromRGB(150, 75, 255)
            dot.BorderSizePixel = 0
            dot.ZIndex = 28
            dot.Parent = layer
            local dotCorner = Instance.new("UICorner")
            dotCorner.CornerRadius = UDim.new(1, 0)
            dotCorner.Parent = dot
            local target = UDim2.fromOffset(x + math.cos(angle) * distance, y + math.sin(angle) * distance)
            tweenService:Create(dot, TweenInfo.new(0.32, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
                Position = target,
                Size = UDim2.fromOffset(1, 1),
                BackgroundTransparency = 1,
            }):Play()
            task.delay(0.36, function()
                if dot.Parent then dot:Destroy() end
            end)
        end
    end

    local lastCursorPosition
    local function getLocalCursorPosition()
        local mouse = userInputService:GetMouseLocation()
        local inset = Vector2.new(0, 0)
        if screenGui then
            pcall(function()
                if not screenGui.IgnoreGuiInset then
                    local topLeft = guiService:GetGuiInset()
                    inset = Vector2.new(topLeft.X, topLeft.Y)
                end
            end)
        end
        local correctedMouse = mouse - inset
        return correctedMouse - main.AbsolutePosition
    end

    local function updateCursorGlow()
        if not layer.Parent or not main.Parent then return nil end
        local enabled = main.Visible
        if screenGui then
            pcall(function() enabled = enabled and screenGui.Enabled end)
        end
        if not enabled then
            lastCursorPosition = nil
            return nil
        end
        local localPosition = getLocalCursorPosition()
        local inside = localPosition.X >= 0 and localPosition.Y >= 0
            and localPosition.X <= main.AbsoluteSize.X
            and localPosition.Y <= main.AbsoluteSize.Y
        if not inside then
            lastCursorPosition = nil
            return nil
        end
        return localPosition
    end

    local connections = {}
    table.insert(connections, userInputService.InputChanged:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch then
            local pos = updateCursorGlow()
            if pos then
                local speed = 0
                if lastCursorPosition then
                    speed = (pos - lastCursorPosition).Magnitude
                end
                if not lastCursorPosition or speed >= 2.5 then
                    spawnSlime(pos.X, pos.Y, speed)
                end
                lastCursorPosition = pos
            end
        end
    end))
    table.insert(connections, userInputService.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            local pos = updateCursorGlow()
            if pos then
                popBubble(pos.X, pos.Y)
            end
        end
    end))
    -- Transição de abertura: uma estrela LOCOPANI gira e desaparece.
    -- A animação é acionada quando a janela volta a ficar visível.
    local transitionStar = Instance.new("TextLabel")
    transitionStar.Name = "LOCOPANI_TransitionStar"
    transitionStar.AnchorPoint = Vector2.new(0.5, 0.5)
    transitionStar.Position = UDim2.fromScale(0.5, 0.5)
    transitionStar.Size = UDim2.fromOffset(76, 76)
    transitionStar.BackgroundTransparency = 1
    transitionStar.Text = "✦"
    transitionStar.TextColor3 = Color3.fromRGB(210, 170, 255)
    transitionStar.TextTransparency = 1
    transitionStar.TextSize = 56
    transitionStar.Font = Enum.Font.GothamBold
    transitionStar.ZIndex = 80
    transitionStar.Visible = false
    transitionStar.Parent = layer

    local transitionScale = Instance.new("UIScale")
    transitionScale.Scale = 0.35
    transitionScale.Parent = transitionStar

    local transitionBusy = false
    local function playStarTransition()
        if transitionBusy or not main.Visible then return end
        transitionBusy = true
        transitionStar.Visible = true
        transitionStar.Rotation = -90
        transitionStar.TextTransparency = 0.05
        transitionScale.Scale = 0.35
        local spin = tweenService:Create(
            transitionStar,
            TweenInfo.new(0.62, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
            { Rotation = 450, TextTransparency = 1 }
        )
        local expand = tweenService:Create(
            transitionScale,
            TweenInfo.new(0.62, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
            { Scale = 1.45 }
        )
        spin:Play()
        expand:Play()
        task.delay(0.66, function()
            if transitionStar.Parent then transitionStar.Visible = false end
            transitionBusy = false
        end)
    end

    table.insert(connections, main:GetPropertyChangedSignal("Visible"):Connect(function()
        lastCursorPosition = nil
        if main.Visible then playStarTransition() end
    end))
    if screenGui then
        table.insert(connections, screenGui:GetPropertyChangedSignal("Enabled"):Connect(function()
            lastCursorPosition = nil
            if screenGui.Enabled and main.Visible then playStarTransition() end
        end))
    end

    local particleColors = {
        Color3.fromRGB(190, 130, 255),
        Color3.fromRGB(135, 90, 230),
        Color3.fromRGB(225, 195, 255),
        Color3.fromRGB(160, 90, 255),
    }

    -- Pool pequeno e fixo; cada partícula nasce em uma borda aleatória
    -- e atravessa a janela em uma direção diferente.
    for index = 1, 16 do
        local particle = Instance.new("Frame")
        particle.Name = "LOCOPANI_FloatingParticle"
        particle.AnchorPoint = Vector2.new(0.5, 0.5)
        particle.Size = UDim2.fromOffset(math.random(2, 4), math.random(2, 4))
        particle.BackgroundColor3 = particleColors[math.random(1, #particleColors)]
        particle.BackgroundTransparency = 1
        particle.BorderSizePixel = 0
        particle.Visible = false
        particle.Active = false
        particle.ZIndex = 23
        particle.Parent = layer

        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(1, 0)
        corner.Parent = particle

        task.spawn(function()
            while particle.Parent and layer.Parent do
                local visible = main.Visible
                if screenGui then
                    pcall(function() visible = visible and screenGui.Enabled end)
                end

                if visible then
                    local width = math.max(main.AbsoluteSize.X, 2)
                    local height = math.max(main.AbsoluteSize.Y, 2)
                    local side = math.random(1, 4)
                    local startX, startY, endX, endY

                    if side == 1 then -- esquerda para direita
                        startX, startY = -8, math.random(0, math.floor(height))
                        endX, endY = width + 8, math.clamp(startY + math.random(-150, 150), 0, height)
                    elseif side == 2 then -- direita para esquerda
                        startX, startY = width + 8, math.random(0, math.floor(height))
                        endX, endY = -8, math.clamp(startY + math.random(-150, 150), 0, height)
                    elseif side == 3 then -- topo para baixo/diagonal
                        startX, startY = math.random(0, math.floor(width)), -8
                        endX, endY = math.clamp(startX + math.random(-160, 160), 0, width), height + 8
                    else -- baixo para cima/diagonal
                        startX, startY = math.random(0, math.floor(width)), height + 8
                        endX, endY = math.clamp(startX + math.random(-160, 160), 0, width), -8
                    end

                    local duration = math.random(7, 13)
                    particle.Position = UDim2.fromOffset(startX, startY)
                    particle.BackgroundTransparency = math.random(12, 30) / 100
                    particle.Visible = true

                    local tween = tweenService:Create(
                        particle,
                        TweenInfo.new(duration, Enum.EasingStyle.Linear, Enum.EasingDirection.Out),
                        {
                            Position = UDim2.fromOffset(endX, endY),
                            BackgroundTransparency = 1,
                        }
                    )
                    tween:Play()
                    task.wait(duration + 0.1)
                    tween:Destroy()
                else
                    particle.Visible = false
                    task.wait(0.5)
                end
                if particle.Parent then
                    task.wait(math.random(10, 45) / 100)
                end
            end
        end)
    end

    window._LOCOPANI_SiteEffectConnections = connections
    window._LOCOPANI_SiteEffectsLayer = layer

    main.AncestryChanged:Connect(function(_, parent)
        if parent == nil then
            for _, connection in ipairs(connections) do
                pcall(function() connection:Disconnect() end)
            end
        end
    end)

    updateCursorGlow()
end


-- LOCOPANI interactive depth: soft purple hover glow + subtle 3D lift.
local function LOCOPANI_ApplyInteractivePolish(window)
    if not window then return end
    local root = window.ScreenGui or window.Main
    if not root then return end

    local TweenService = game:GetService("TweenService")
    local styled = setmetatable({}, { __mode = "k" })
    local purple = Color3.fromRGB(166, 92, 255)
    local brightPurple = Color3.fromRGB(210, 170, 255)

    local function replaceBranding(object)
        if not (object:IsA("TextLabel") or object:IsA("TextButton") or object:IsA("TextBox")) then
            return
        end
        local ok, currentText = pcall(function() return object.Text end)
        if not ok or type(currentText) ~= "string" then return end
        local updated = currentText
        updated = updated:gsub("[Aa][Rr][Gg][Oo][Nn]%s+[Hh][Uu][Bb]", "LOCOPANI")
        updated = updated:gsub("[Aa][Rr][Gg][Oo][Nn]%s+[Oo][Nn][Ll][Ii][Nn][Ee]", "LOCOPANI ONLINE")
        updated = updated:gsub("[Aa][Rr][Gg][Oo][Nn]", "LOCOPANI")
        if updated ~= currentText then
            pcall(function() object.Text = updated end)
        end
    end

    local function styleButton(button)
        if not button:IsA("GuiButton") or styled[button] then return end
        styled[button] = true

        local stroke = Instance.new("UIStroke")
        stroke.Name = "LOCOPANI_InteractiveGlow"
        stroke.Color = purple
        stroke.Thickness = 1
        stroke.Transparency = 1
        stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
        stroke.Parent = button

        local scale = Instance.new("UIScale")
        scale.Name = "LOCOPANI_InteractiveDepth"
        scale.Scale = 1
        scale.Parent = button

        local hovering = false
        local function tweenTo(size, transparency, thickness, duration)
            if not button.Parent then return end
            TweenService:Create(scale, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
                Scale = size
            }):Play()
            TweenService:Create(stroke, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
                Transparency = transparency,
                Thickness = thickness,
            }):Play()
        end

        button.MouseEnter:Connect(function()
            hovering = true
            tweenTo(1.035, 0.12, 2.2, 0.16)
        end)

        button.MouseLeave:Connect(function()
            hovering = false
            tweenTo(1, 1, 1, 0.18)
        end)

        button.Activated:Connect(function()
            tweenTo(1.045, 0.02, 2.8, 0.09)
            task.delay(0.12, function()
                if not button.Parent then return end
                if hovering then
                    tweenTo(1.035, 0.12, 2.2, 0.14)
                else
                    tweenTo(1, 1, 1, 0.18)
                end
            end)
        end)

        button.Destroying:Connect(function()
            styled[button] = nil
        end)
    end

    local function process(object)
        replaceBranding(object)
        if object:IsA("GuiButton") then
            styleButton(object)
        end
    end

    for _, object in ipairs(root:GetDescendants()) do
        process(object)
    end

    root.DescendantAdded:Connect(function(object)
        process(object)
        -- Some controls build their text/children immediately after parenting.
        task.defer(function()
            if object.Parent then
                process(object)
                for _, child in ipairs(object:GetDescendants()) do
                    process(child)
                end
            end
        end)
    end)
end

-- ============================================================
-- LOCOPANI LANGUAGE SYSTEM
-- Tela de escolha de idioma (roxa, glow 3D, blur preto atrás e
-- partículas roxas voando) + sistema de tradução T("texto em PT").
-- O idioma escolhido fica salvo em "locopani_lang.dat" e pode ser
-- trocado depois em UI Settings > Menu > Idioma.
--
-- Para traduzir mais textos do script:
--   LOCOPANI_I18N.AddStrings("en", { ["Texto em português"] = "English text" })
-- e use LOCOPANI_I18N.T("Texto em português") onde o texto aparece.
-- ============================================================
do
    local env = (type(getgenv) == "function" and getgenv()) or _G
    if env.LOCOPANI_I18N and type(env.LOCOPANI_I18N.Destroy) == "function" then
        pcall(env.LOCOPANI_I18N.Destroy)
    end

    local TweenService = game:GetService("TweenService")
    local RunService = game:GetService("RunService")

    local I18N = { Lang = "pt" }
    env.LOCOPANI_I18N = I18N

    local LANG_FILE = "locopani_lang.dat"
    local pickerState = {}

    -- Idiomas disponíveis no dropdown ({ código, nome exibido })
    local LANGUAGES = {
        { "pt", "Português (Brasil)" },
        { "en", "English" },
        { "es", "Español" },
        { "fr", "Français" },
        { "de", "Deutsch" },
        { "it", "Italiano" },
        { "ru", "Русский (Russian)" },
        { "ja", "日本語 (Japanese)" },
        { "ko", "한국어 (Korean)" },
        { "zh", "中文 简体 (Chinese)" },
        { "zh-tw", "中文 繁體 (Chinese Traditional)" },
        { "ar", "العربية (Arabic)" },
        { "hi", "हिन्दी (Hindi)" },
        { "tr", "Türkçe" },
        { "id", "Bahasa Indonesia" },
        { "vi", "Tiếng Việt" },
        { "th", "ไทย (Thai)" },
        { "pl", "Polski" },
        { "nl", "Nederlands" },
        { "uk", "Українська (Ukrainian)" },
        { "ro", "Română" },
        { "cs", "Čeština" },
        { "sv", "Svenska" },
        { "el", "Ελληνικά (Greek)" },
        { "hu", "Magyar" },
        { "he", "עברית (Hebrew)" },
        { "fil", "Filipino" },
        { "ms", "Bahasa Melayu" },
        { "da", "Dansk" },
        { "fi", "Suomi" },
        { "no", "Norsk" },
        { "bg", "Български (Bulgarian)" },
        { "hr", "Hrvatski" },
        { "sk", "Slovenčina" },
        { "sr", "Српски (Serbian)" },
        { "bn", "বাংলা (Bengali)" },
        { "fa", "فارسی (Persian)" },
        { "ur", "اردو (Urdu)" },
        { "ca", "Català" },
        { "lt", "Lietuvių" },
        { "lv", "Latviešu" },
        { "et", "Eesti" },
        { "sl", "Slovenščina" },
    }
    local byCode, byName = {}, {}
    for _, l in ipairs(LANGUAGES) do
        byCode[l[1]] = l[2]
        byName[l[2]] = l[1]
    end

    I18N.Languages = LANGUAGES
    function I18N.GetDisplayName(code) return byCode[code] or byCode.pt end
    function I18N.CodeFromDisplay(name) return byName[name] end
    function I18N.GetDisplayNames()
        local names = {}
        for _, l in ipairs(LANGUAGES) do names[#names + 1] = l[2] end
        return names
    end

    -- ------------------------------------------------------------
    -- Traduções (chave = texto original em português)
    -- Idiomas sem tradução caem para o inglês (e depois para o português).
    -- ------------------------------------------------------------
    local DICT = {}
    local function add(src, tr) DICT[src] = tr end

    add("Escolha seu idioma", {
        en = "Choose your language", es = "Elige tu idioma", fr = "Choisissez votre langue",
        de = "Wähle deine Sprache", it = "Scegli la tua lingua", ru = "Выберите язык",
        ja = "言語を選択してください", ko = "언어를 선택하세요", zh = "选择您的语言",
        tr = "Dilinizi seçin", id = "Pilih bahasa Anda",
    })
    add("Selecione o idioma do LOCOPANI", {
        en = "Select the language for LOCOPANI", es = "Selecciona el idioma de LOCOPANI",
        fr = "Sélectionnez la langue de LOCOPANI", de = "Wähle die Sprache für LOCOPANI",
        it = "Seleziona la lingua di LOCOPANI", ru = "Выберите язык LOCOPANI",
        ja = "LOCOPANIの言語を選択してください", ko = "LOCOPANI 언어를 선택하세요",
        zh = "选择 LOCOPANI 的语言", tr = "LOCOPANI için dili seçin",
        id = "Pilih bahasa untuk LOCOPANI",
    })
    add("Continuar", {
        en = "Continue", es = "Continuar", fr = "Continuer", de = "Weiter", it = "Continua",
        ru = "Продолжить", ja = "続ける", ko = "계속", zh = "继续", tr = "Devam", id = "Lanjutkan",
    })
    add("Você conseguirá mudar depois nas configurações", {
        en = "You will be able to change it later in the settings",
        es = "Podrás cambiarlo después en los ajustes",
        fr = "Vous pourrez la modifier plus tard dans les paramètres",
        de = "Du kannst sie später in den Einstellungen ändern",
        it = "Potrai cambiarla più tardi nelle impostazioni",
        ru = "Вы сможете изменить его позже в настройках",
        ja = "あとで設定から変更できます",
        ko = "나중에 설정에서 변경할 수 있습니다",
        zh = "您可以稍后在设置中更改",
        tr = "Daha sonra ayarlardan değiştirebilirsiniz",
        id = "Anda dapat mengubahnya nanti di pengaturan",
    })
    add("Idioma", {
        en = "Language", es = "Idioma", fr = "Langue", de = "Sprache", it = "Lingua",
        ru = "Язык", ja = "言語", ko = "언어", zh = "语言", tr = "Dil", id = "Bahasa",
    })
    add("Idioma alterado.", {
        en = "Language changed.", es = "Idioma cambiado.", fr = "Langue modifiée.",
        de = "Sprache geändert.", it = "Lingua modificata.", ru = "Язык изменён.",
        ja = "言語を変更しました。", ko = "언어가 변경되었습니다.", zh = "语言已更改。",
        tr = "Dil değiştirildi.", id = "Bahasa diubah.",
    })
    add("Acesso ao LOCOPANI", {
        en = "LOCOPANI Access", es = "Acceso a LOCOPANI", fr = "Accès à LOCOPANI",
        de = "LOCOPANI-Zugang", it = "Accesso a LOCOPANI", ru = "Доступ к LOCOPANI",
        ja = "LOCOPANIへのアクセス", ko = "LOCOPANI 접속", zh = "LOCOPANI 访问",
        tr = "LOCOPANI Erişimi", id = "Akses LOCOPANI",
    })
    add("PEGAR ID ROBLOX", {
        en = "GET ROBLOX ID", es = "COPIAR ID DE ROBLOX", fr = "COPIER L'ID ROBLOX",
        de = "ROBLOX-ID KOPIEREN", it = "COPIA ID ROBLOX", ru = "СКОПИРОВАТЬ ID ROBLOX",
        ja = "ROBLOX IDを取得", ko = "ROBLOX ID 복사", zh = "获取 ROBLOX ID",
        tr = "ROBLOX ID'Yİ KOPYALA", id = "SALIN ID ROBLOX",
    })
    add("ID do Roblox copiado:", {
        en = "Roblox ID copied:", es = "ID de Roblox copiado:", fr = "ID Roblox copié :",
        de = "Roblox-ID kopiert:", it = "ID Roblox copiato:", ru = "ID Roblox скопирован:",
        ja = "ROBLOX IDをコピーしました:", ko = "ROBLOX ID 복사됨:", zh = "已复制 ROBLOX ID：",
        tr = "ROBLOX ID kopyalandı:", id = "ID Roblox disalin:",
    })
    add("Status", {
        en = "Status", es = "Estado", fr = "Statut", de = "Status", it = "Stato",
        ru = "Статус", ja = "ステータス", ko = "상태", zh = "状态", tr = "Durum", id = "Status",
    })
    add("Digite sua chave de acesso e clique em Validar key.", {
        en = "Enter your access key and click Validate key.",
        es = "Escribe tu clave de acceso y haz clic en Validar clave.",
        fr = "Saisissez votre clé d'accès et cliquez sur Valider la clé.",
        de = "Gib deinen Zugangsschlüssel ein und klicke auf Schlüssel prüfen.",
        it = "Inserisci la tua chiave di accesso e clicca su Convalida chiave.",
        ru = "Введите ключ доступа и нажмите «Проверить ключ».",
        ja = "アクセスキーを入力して「キーを認証」をクリックしてください。",
        ko = "액세스 키를 입력하고 키 인증을 클릭하세요.",
        zh = "输入您的访问密钥并点击验证密钥。",
        tr = "Erişim anahtarınızı girin ve Anahtarı doğrula'ya tıklayın.",
        id = "Masukkan kunci akses Anda lalu klik Validasi kunci.",
    })
    add("Validar key", {
        en = "Validate key", es = "Validar clave", fr = "Valider la clé", de = "Schlüssel prüfen",
        it = "Convalida chiave", ru = "Проверить ключ", ja = "キーを認証", ko = "키 인증",
        zh = "验证密钥", tr = "Anahtarı doğrula", id = "Validasi kunci",
    })
    add("Digite sua chave de acesso.", {
        en = "Enter your access key.", es = "Escribe tu clave de acceso.",
        fr = "Saisissez votre clé d'accès.", de = "Gib deinen Zugangsschlüssel ein.",
        it = "Inserisci la tua chiave di accesso.", ru = "Введите ключ доступа.",
        ja = "アクセスキーを入力してください。", ko = "액세스 키를 입력하세요.",
        zh = "请输入您的访问密钥。", tr = "Erişim anahtarınızı girin.",
        id = "Masukkan kunci akses Anda.",
    })
    add("Verificando key no Supabase...", {
        en = "Verifying key on Supabase...", es = "Verificando la clave en Supabase...",
        fr = "Vérification de la clé sur Supabase...", de = "Schlüssel wird bei Supabase geprüft...",
        it = "Verifica della chiave su Supabase...", ru = "Проверка ключа в Supabase...",
        ja = "Supabaseでキーを確認中...", ko = "Supabase에서 키 확인 중...",
        zh = "正在通过 Supabase 验证密钥...", tr = "Anahtar Supabase'de doğrulanıyor...",
        id = "Memverifikasi kunci di Supabase...",
    })
    add("Chave validada. Iniciando LOCOPANI...", {
        en = "Key validated. Starting LOCOPANI...", es = "Clave validada. Iniciando LOCOPANI...",
        fr = "Clé validée. Démarrage de LOCOPANI...", de = "Schlüssel bestätigt. LOCOPANI wird gestartet...",
        it = "Chiave convalidata. Avvio di LOCOPANI...", ru = "Ключ подтверждён. Запуск LOCOPANI...",
        ja = "キーが認証されました。LOCOPANIを起動しています...",
        ko = "키가 인증되었습니다. LOCOPANI를 시작합니다...",
        zh = "密钥已验证，正在启动 LOCOPANI...", tr = "Anahtar doğrulandı. LOCOPANI başlatılıyor...",
        id = "Kunci tervalidasi. Memulai LOCOPANI...",
    })
    add("Chave inválida.", {
        en = "Invalid key.", es = "Clave inválida.", fr = "Clé invalide.", de = "Ungültiger Schlüssel.",
        it = "Chiave non valida.", ru = "Недействительный ключ.", ja = "無効なキーです。",
        ko = "잘못된 키입니다.", zh = "密钥无效。", tr = "Geçersiz anahtar.", id = "Kunci tidak valid.",
    })
    add("Esta chave já pertence a outro jogador.", {
        en = "This key already belongs to another player.",
        es = "Esta clave ya pertenece a otro jugador.",
        fr = "Cette clé appartient déjà à un autre joueur.",
        de = "Dieser Schlüssel gehört bereits einem anderen Spieler.",
        it = "Questa chiave appartiene già a un altro giocatore.",
        ru = "Этот ключ уже принадлежит другому игроку.",
        ja = "このキーはすでに別のプレイヤーに登録されています。",
        ko = "이 키는 이미 다른 플레이어에게 등록되어 있습니다.",
        zh = "此密钥已属于其他玩家。",
        tr = "Bu anahtar zaten başka bir oyuncuya ait.",
        id = "Kunci ini sudah dimiliki pemain lain.",
    })

    -- Tradução: T("texto em português", [código do idioma])
    function I18N.T(src, lang)
        src = tostring(src)
        lang = lang or I18N.Lang
        if lang == "pt" then return src end
        local e = DICT[src]
        if not e then return src end
        return e[lang] or e[string.match(lang, "^(%a+)")] or e.en or src
    end

    local reverse = nil -- texto traduzido -> texto original (para re-traduzir a UI)
    function I18N.AddStrings(lang, map)
        if type(map) ~= "table" then return end
        for src, tr in pairs(map) do
            DICT[src] = DICT[src] or {}
            DICT[src][lang] = tr
        end
        reverse = nil
    end

    -- ------------------------------------------------------------
    -- Salvar / carregar idioma
    -- ------------------------------------------------------------
    local function getSaved()
        local isfileFn = env.isfile or isfile
        local readfileFn = env.readfile or readfile
        if type(isfileFn) ~= "function" or type(readfileFn) ~= "function" then return nil end
        local okE, exists = pcall(isfileFn, LANG_FILE)
        if not okE or not exists then return nil end
        local okR, txt = pcall(readfileFn, LANG_FILE)
        if not okR or type(txt) ~= "string" then return nil end
        txt = string.lower((string.gsub(txt, "%s+", "")))
        if byCode[txt] then return txt end
        return nil
    end

    local function saveLang(code)
        local writefileFn = env.writefile or writefile
        if type(writefileFn) == "function" then
            pcall(writefileFn, LANG_FILE, code)
        end
    end

    -- Sugere o idioma conforme o idioma do Roblox do jogador
    local function guessLanguage()
        local ok, id = pcall(function()
            return game:GetService("LocalizationService").RobloxLocaleId
        end)
        if ok and type(id) == "string" then
            id = string.lower((string.gsub(id, "_", "-")))
            if byCode[id] then return id end
            local base = string.match(id, "^(%a+)")
            if base and byCode[base] then return base end
        end
        return "pt"
    end

    -- ------------------------------------------------------------
    -- Tradução automática da UI inteira
    -- 1) dicionário acima  2) cache salvo  3) Google Translate (via request do executor)
    -- Textos novos que aparecerem nas UIs do LOCOPANI são traduzidos sozinhos.
    -- ------------------------------------------------------------
    local HttpService = game:GetService("HttpService")
    local GOOGLE_CODES = { zh = "zh-CN", ["zh-tw"] = "zh-TW", fil = "tl", he = "iw" }
    local EXCLUDE = { LOCOPANILanguage = true, LOCOPANILoading = true, LOCOPANIFX = true }
    local records = setmetatable({}, { __mode = "k" })
    local caches = {}
    local queue, queued = {}, {}
    local queuedTotal, batchCount = 0, 0
    local cacheDirty = {}
    local needScan, needRestore, autoStarted = false, false, false
    local requestFn = nil

    local function getRequest()
        if requestFn ~= nil then return requestFn or nil end
        local f = env.request or env.http_request or env.httprequest
            or (type(request) == "function" and request) or (type(http_request) == "function" and http_request)
            or (type(httprequest) == "function" and httprequest) or nil
        if type(f) ~= "function" then
            for _, c in ipairs({ env.syn, env.http, env.fluxus, syn, http, fluxus }) do
                if type(c) == "table" and type(c.request) == "function" then f = c.request break end
            end
        end
        requestFn = (type(f) == "function" and f) or false
        return requestFn or nil
    end
    function I18N.HasHttp() return getRequest() ~= nil end

    local function buildReverse()
        reverse = {}
        for src, e in pairs(DICT) do
            reverse[src] = src
            for _, tr in pairs(e) do reverse[tr] = src end
        end
    end

    local function cacheFile(lang)
        return "locopani_tr_" .. (string.gsub(lang, "[^%w]", "_")) .. ".json"
    end

    local function getCache(lang)
        local c = caches[lang]
        if c then return c end
        c = {}
        caches[lang] = c
        local isfileFn = env.isfile or isfile
        local readfileFn = env.readfile or readfile
        if type(isfileFn) == "function" and type(readfileFn) == "function" then
            local ok, exists = pcall(isfileFn, cacheFile(lang))
            if ok and exists then
                local okR, txt = pcall(readfileFn, cacheFile(lang))
                if okR and type(txt) == "string" then
                    local okJ, data = pcall(function() return HttpService:JSONDecode(txt) end)
                    if okJ and type(data) == "table" then
                        for k, v in pairs(data) do
                            if type(v) == "string" then c[k] = v end
                        end
                    end
                end
            end
        end
        return c
    end

    local function saveCache(lang)
        local writefileFn = env.writefile or writefile
        local c = caches[lang]
        if type(writefileFn) ~= "function" or not c then return end
        local out = {}
        for k, v in pairs(c) do
            if type(v) == "string" then out[k] = v end
        end
        local okJ, txt = pcall(function() return HttpService:JSONEncode(out) end)
        if okJ then pcall(writefileFn, cacheFile(lang), txt) end
    end

    -- Traduz uma lista de textos (um por linha). Devolve lista ou nil.
    local function googleBatch(tl, strings)
        local req = getRequest()
        if not req then return nil end
        local url = "https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl="
            .. tl .. "&dt=t&q=" .. HttpService:UrlEncode(table.concat(strings, "\n"))
        local ok, res = pcall(req, { Url = url, Method = "GET" })
        if not ok or type(res) ~= "table" then return nil end
        local code = tonumber(res.StatusCode or res.Status or 0) or 0
        local body = res.Body or res.body
        if type(body) ~= "string" or (code ~= 0 and (code < 200 or code >= 300)) then return nil end
        local okJ, data = pcall(function() return HttpService:JSONDecode(body) end)
        if not okJ or type(data) ~= "table" or type(data[1]) ~= "table" then return nil end
        local parts = {}
        for _, seg in ipairs(data[1]) do
            if type(seg) == "table" and type(seg[1]) == "string" then parts[#parts + 1] = seg[1] end
        end
        local joined = string.gsub(table.concat(parts), "\n+$", "")
        local out = {}
        for line in string.gmatch(joined .. "\n", "(.-)\n") do out[#out + 1] = line end
        if #out ~= #strings then return nil end
        return out
    end

    -- Textos que NÃO devem ser traduzidos (números, códigos, nomes, rich text...)
    local function shouldSkip(s)
        if #s < 2 or #s > 400 then return true end
        if not string.find(s, "%a") then return true end
        if string.find(s, "%d") then return true end
        if string.find(s, "\n", 1, true) then return true end
        if string.find(s, "<", 1, true) and string.find(s, ">", 1, true) then return true end
        if string.find(s, "XXXX", 1, true) then return true end
        if string.find(s, "^[%w_]+$") and string.find(s, "_", 1, true) then return true end
        return false
    end

    local function enqueue(lang, s)
        local key = lang .. "|" .. s
        if queued[key] or queuedTotal > 1500 then return end
        queued[key] = true
        queuedTotal = queuedTotal + 1
        queue[#queue + 1] = { lang = lang, text = s }
    end

    local function machine(lang, source)
        local lead, core, trail = string.match(source, "^(%s*)(.-)(%s*)$")
        if core == "" or byName[core] or shouldSkip(core) then return source end
        local v = getCache(lang)[core]
        if v ~= nil then
            if v then return lead .. v .. trail end
            return source
        end
        if not getRequest() then return source end
        enqueue(lang, core)
        return nil -- ainda traduzindo
    end

    local function lookup(source, lang)
        if not reverse then buildReverse() end
        local src = reverse[source]
        if src then
            local e = DICT[src]
            local exact = e and e[lang]
            if exact then return exact end
            if lang == "pt" then return src end
            if not getRequest() then return I18N.T(src, lang) end
            source = src
        end
        return machine(lang, source)
    end

    local function handle(inst, prop, lang)
        local cur = inst[prop]
        if type(cur) ~= "string" or cur == "" then return end
        local rec = records[inst]
        if not rec then rec = {}; records[inst] = rec end
        local r = rec[prop]

        if lang == "pt" then
            if not reverse then buildReverse() end
            local base = (r and r.shown == cur and r.orig) or cur
            local pt = reverse[base] or base
            if pt ~= cur then inst[prop] = pt end
            rec[prop] = nil
            return
        end

        local source
        if r and r.shown ~= nil and r.shown == cur then
            source = r.orig
        elseif r and r.orig == cur then
            source = cur
        else
            source = cur
            r = { orig = cur }
            rec[prop] = r
        end
        local res = lookup(source, lang)
        if res ~= nil then
            if res ~= cur then inst[prop] = res end
            r.shown = res
        end
    end

    local function getRoots()
        local roots = {}
        pcall(function()
            if type(gethui) == "function" then
                local h = gethui()
                if typeof(h) == "Instance" then roots[#roots + 1] = h end
            end
        end)
        pcall(function() roots[#roots + 1] = game:GetService("CoreGui") end)
        pcall(function()
            local pg = game:GetService("Players").LocalPlayer:FindFirstChild("PlayerGui")
            if pg then roots[#roots + 1] = pg end
        end)
        return roots
    end

    local function scan()
        local lang = I18N.Lang
        local n = 0
        for _, root in ipairs(getRoots()) do
            for _, g in ipairs(root:GetChildren()) do
                if g:IsA("ScreenGui") and string.sub(g.Name, 1, 8) == "LOCOPANI" and not EXCLUDE[g.Name] then
                    for _, inst in ipairs(g:GetDescendants()) do
                        if inst:IsA("TextLabel") or inst:IsA("TextButton") then
                            pcall(handle, inst, "Text", lang)
                        elseif inst:IsA("TextBox") then
                            pcall(handle, inst, "PlaceholderText", lang)
                        end
                        n = n + 1
                        if n % 250 == 0 then task.wait() end
                    end
                end
            end
        end
    end

    local function worker()
        while not I18N._dead do
            local first = queue[1]
            if first and getRequest() and batchCount < 600 then
                local lang = first.lang
                local batch, chars, i = {}, 0, 1
                while queue[i] and #batch < 20 do
                    local it = queue[i]
                    if it.lang == lang then
                        if chars + #it.text > 700 and #batch > 0 then break end
                        batch[#batch + 1] = it.text
                        chars = chars + #it.text + 1
                        table.remove(queue, i)
                    else
                        i = i + 1
                    end
                end
                batchCount = batchCount + 1
                local gl = GOOGLE_CODES[lang] or lang
                local res = googleBatch(gl, batch)
                if not res then
                    res = {}
                    for j, s in ipairs(batch) do
                        local r1 = googleBatch(gl, { s })
                        res[j] = (r1 and r1[1]) or false
                        task.wait(0.1)
                    end
                end
                local c = getCache(lang)
                for j, s in ipairs(batch) do
                    c[s] = res[j] or false
                    queued[lang .. "|" .. s] = nil
                end
                cacheDirty[lang] = true
                needScan = true
                task.wait(0.2)
            else
                for lang in pairs(cacheDirty) do
                    saveCache(lang)
                    cacheDirty[lang] = nil
                end
                task.wait(0.4)
            end
        end
    end

    function I18N.StartAuto()
        needScan = true
        if autoStarted then return end
        autoStarted = true
        task.spawn(worker)
        task.spawn(function()
            local last = 0
            while not I18N._dead do
                if I18N.Lang ~= "pt" or needRestore then
                    if needScan or needRestore or os.clock() - last > 2.5 then
                        needScan = false
                        needRestore = false
                        pcall(scan)
                        last = os.clock()
                    end
                end
                task.wait(0.4)
            end
        end)
    end

    function I18N.SetLanguage(code)
        if not byCode[code] then return false end
        I18N.Lang = code
        saveLang(code)
        queue = {}
        queued = {}
        needRestore = true
        I18N.StartAuto()
        return true
    end

    -- ------------------------------------------------------------
    -- Tela de escolha de idioma
    -- ------------------------------------------------------------
    local function parentGui(gui)
        pcall(function()
            if syn and syn.protect_gui then syn.protect_gui(gui) end
        end)
        if type(gethui) == "function" then
            local ok, hui = pcall(gethui)
            if ok and typeof(hui) == "Instance" and pcall(function() gui.Parent = hui end) then
                return
            end
        end
        if pcall(function() gui.Parent = game:GetService("CoreGui") end) then return end
        gui.Parent = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
    end

    local function corner(obj, radius)
        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0, radius)
        c.Parent = obj
        return c
    end

    local function border(obj, color, thickness, transparency)
        local s = Instance.new("UIStroke")
        s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
        s.Color = color
        s.Thickness = thickness
        s.Transparency = transparency or 0
        s.Parent = obj
        return s
    end

    local function cleanupPicker()
        if pickerState.fx then
            pcall(pickerState.fx.Destroy)
            pickerState.fx = nil
        end
        if pickerState.conn then
            pcall(function() pickerState.conn:Disconnect() end)
            pickerState.conn = nil
        end
        if pickerState.gui then
            pcall(function() pickerState.gui:Destroy() end)
            pickerState.gui = nil
        end
        if pickerState.blur then
            pcall(function() pickerState.blur:Destroy() end)
            pickerState.blur = nil
        end
    end
    function I18N.Destroy()
        I18N._dead = true
        cleanupPicker()
    end

    -- ------------------------------------------------------------
    -- Efeitos: slime seguindo o cursor + bolhas quando toca/clica
    -- ------------------------------------------------------------
    function I18N.AttachFX()
        local UserInputService = game:GetService("UserInputService")
        local GuiService = game:GetService("GuiService")

        local gui = Instance.new("ScreenGui")
        gui.Name = "LOCOPANIFX"
        gui.IgnoreGuiInset = true
        gui.ResetOnSpawn = false
        gui.DisplayOrder = 2147483647
        gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
        parentGui(gui)

        local layer = Instance.new("Frame")
        layer.Size = UDim2.fromScale(1, 1)
        layer.BackgroundTransparency = 1
        layer.BorderSizePixel = 0
        layer.Active = false
        layer.Parent = gui

        local function circle(parent, size, color, transparency)
            local f = Instance.new("Frame")
            f.AnchorPoint = Vector2.new(0.5, 0.5)
            f.Size = UDim2.fromOffset(size, size)
            f.BackgroundColor3 = color
            f.BackgroundTransparency = transparency
            f.BorderSizePixel = 0
            f.Active = false
            f.Parent = parent
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(1, 0)
            c.Parent = f
            return f
        end

        -- Slime: cabeça elástica + rastro que escorrega atrás
        local N = 11
        local headColor, tailColor = Color3.fromRGB(190, 110, 255), Color3.fromRGB(100, 45, 210)
        local blobs = {}
        for i = 1, N do
            local sz = math.floor(26 - (i - 1) * 1.9)
            local f = circle(layer, sz, headColor:Lerp(tailColor, (i - 1) / (N - 1)), 0.05 + i * 0.03)
            f.ZIndex = N - i + 1
            border(f, Color3.fromRGB(225, 190, 255), 1.5, 0.5)
            blobs[i] = { frame = f, x = 0, y = 0, size = sz }
        end
        local head = blobs[1].frame
        local shine = circle(head, 8, Color3.new(1, 1, 1), 0.35)
        shine.Position = UDim2.new(0.32, 0, 0.3, 0)

        local drops, bubbles = {}, {}
        local target = UserInputService:GetMouseLocation()
        local hasMouse = UserInputService.MouseEnabled
        local lastTouch = -10
        local first = true
        local inset = 0
        pcall(function() inset = GuiService:GetGuiInset().Y end)

        local function spawnBubbles(pos)
            for _ = 1, 7 do
                if #bubbles >= 70 then break end
                local sz = math.random(10, 26)
                local f = circle(layer, sz, Color3.fromRGB(200, 150, 255), 0.82)
                f.ZIndex = 50
                local st = border(f, Color3.fromRGB(235, 210, 255), 1.5, 0.25)
                local dot = circle(f, math.max(3, sz * 0.22), Color3.new(1, 1, 1), 0.2)
                dot.Position = UDim2.new(0.3, 0, 0.28, 0)
                bubbles[#bubbles + 1] = {
                    frame = f, stroke = st, dot = dot, sz = sz,
                    x = pos.X + math.random(-14, 14), y = pos.Y + math.random(-8, 8),
                    vx = math.random(-25, 25), vy = -math.random(40, 110),
                    life = 0, maxLife = 0.9 + math.random() * 0.9, phase = math.random() * 6.28,
                }
            end
        end

        local conns = {}
        conns[#conns + 1] = UserInputService.InputBegan:Connect(function(input)
            local ut = input.UserInputType
            if ut == Enum.UserInputType.MouseButton1 then
                spawnBubbles(UserInputService:GetMouseLocation())
            elseif ut == Enum.UserInputType.Touch then
                local p = Vector2.new(input.Position.X, input.Position.Y + inset)
                target = p
                lastTouch = os.clock()
                spawnBubbles(p)
            end
        end)
        conns[#conns + 1] = UserInputService.InputChanged:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.Touch then
                target = Vector2.new(input.Position.X, input.Position.Y + inset)
                lastTouch = os.clock()
            end
        end)

        conns[#conns + 1] = RunService.RenderStepped:Connect(function(dt)
            dt = math.min(dt, 0.05)
            if hasMouse then
                target = UserInputService:GetMouseLocation()
                layer.Visible = true
            else
                layer.Visible = os.clock() - lastTouch < 0.9
            end

            local h = blobs[1]
            if first then
                for _, b in ipairs(blobs) do b.x, b.y = target.X, target.Y end
                first = false
            end
            local ox, oy = h.x, h.y
            local k = 1 - math.exp(-dt * 30)
            h.x = h.x + (target.X - h.x) * k
            h.y = h.y + (target.Y - h.y) * k
            for i = 2, N do
                local p, b = blobs[i - 1], blobs[i]
                local kk = 1 - math.exp(-dt * (26 - i * 1.6))
                b.x = b.x + (p.x - b.x) * kk
                b.y = b.y + (p.y - b.y) * kk
            end
            for _, b in ipairs(blobs) do
                b.frame.Position = UDim2.fromOffset(b.x, b.y)
            end

            -- cabeça estica na direção do movimento
            local vx, vy = target.X - h.x, target.Y - h.y
            local len = math.sqrt(vx * vx + vy * vy)
            local st = math.clamp(len / 50, 0, 0.7)
            head.Size = UDim2.fromOffset(26 * (1 + st), 26 * (1 - st * 0.45))
            head.Rotation = math.deg(math.atan2(vy, vx))
            shine.Rotation = -head.Rotation

            -- pingos de slime caindo quando mexe rápido
            local speed = math.sqrt((h.x - ox) ^ 2 + (h.y - oy) ^ 2) / math.max(dt, 0.001)
            if speed > 600 and #drops < 14 and math.random() < dt * 14 then
                local sz = math.random(4, 8)
                local f = circle(layer, sz, Color3.fromRGB(165, 85, 245), 0.1)
                f.ZIndex = 1
                drops[#drops + 1] = { frame = f, x = h.x, y = h.y, vx = math.random(-30, 30), vy = 0, life = 1 }
            end
            for i = #drops, 1, -1 do
                local d = drops[i]
                d.life = d.life - dt * 1.1
                d.vy = d.vy + 900 * dt
                d.x = d.x + d.vx * dt
                d.y = d.y + d.vy * dt
                if d.life <= 0 then
                    d.frame:Destroy()
                    table.remove(drops, i)
                else
                    d.frame.Position = UDim2.fromOffset(d.x, d.y)
                    d.frame.BackgroundTransparency = 1 - d.life * 0.9
                end
            end

            -- bolhas: sobem balançando e estouram no fim
            for i = #bubbles, 1, -1 do
                local b = bubbles[i]
                b.life = b.life + dt
                local t = b.life / b.maxLife
                if t >= 1 then
                    b.frame:Destroy()
                    table.remove(bubbles, i)
                else
                    b.x = b.x + b.vx * dt + math.sin(b.life * 5 + b.phase) * 0.6
                    b.y = b.y + b.vy * dt
                    local pop = math.clamp((t - 0.82) / 0.18, 0, 1)
                    local s = b.sz * (1 + 0.25 * t) * (1 + 0.5 * pop)
                    b.frame.Size = UDim2.fromOffset(s, s)
                    b.frame.Position = UDim2.fromOffset(b.x, b.y)
                    b.frame.BackgroundTransparency = 0.82 + 0.18 * pop
                    b.stroke.Transparency = 0.25 + 0.75 * pop
                    b.dot.BackgroundTransparency = 0.2 + 0.8 * pop
                end
            end
        end)

        local fx = {}
        function fx.Destroy()
            for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
            conns = {}
            pcall(function() gui:Destroy() end)
        end
        return fx
    end

    function I18N.ShowPicker()
        if pickerState.gui then cleanupPicker() end

        local selected = guessLanguage()
        local confirmed = false

        local gui = Instance.new("ScreenGui")
        gui.Name = "LOCOPANILanguage"
        gui.IgnoreGuiInset = true
        gui.ResetOnSpawn = false
        gui.DisplayOrder = 2147483646
        gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
        parentGui(gui)
        pickerState.gui = gui
        pcall(function() pickerState.fx = I18N.AttachFX() end)

        -- Blur real atrás (borrão) + fundo preto
        pcall(function()
            local b = Instance.new("BlurEffect")
            b.Size = 0
            b.Parent = game:GetService("Lighting")
            pickerState.blur = b
            TweenService:Create(b, TweenInfo.new(0.5), { Size = 26 }):Play()
        end)

        local bg = Instance.new("Frame")
        bg.Name = "Background"
        bg.Size = UDim2.fromScale(1, 1)
        bg.BackgroundColor3 = Color3.new(1, 1, 1)
        bg.BackgroundTransparency = 1
        bg.BorderSizePixel = 0
        bg.Active = true
        bg.ZIndex = 1
        bg.Parent = gui
        local bgGrad = Instance.new("UIGradient")
        bgGrad.Color = ColorSequence.new(Color3.fromRGB(0, 0, 0), Color3.fromRGB(28, 8, 52))
        bgGrad.Rotation = 90
        bgGrad.Parent = bg
        TweenService:Create(bg, TweenInfo.new(0.5), { BackgroundTransparency = 0.15 }):Play()

        -- Partículas roxas voando atrás da telinha
        local stage = Instance.new("Frame")
        stage.Name = "Particles"
        stage.Size = UDim2.fromScale(1, 1)
        stage.BackgroundTransparency = 1
        stage.BorderSizePixel = 0
        stage.ZIndex = 2
        stage.Parent = gui

        local sizes = { 2, 2, 3, 3, 3, 4, 4, 5, 6, 7 }
        local flakes = {}
        for i = 1, 58 do
            local sz = sizes[math.random(1, #sizes)]
            local fr = Instance.new("Frame")
            fr.AnchorPoint = Vector2.new(0.5, 0.5)
            fr.Size = UDim2.fromOffset(sz, sz)
            fr.BackgroundColor3 = Color3.fromRGB(math.random(150, 235), math.random(80, 185), 255)
            fr.BorderSizePixel = 0
            fr.Parent = stage
            corner(fr, sz)
            if sz >= 5 then border(fr, Color3.fromRGB(170, 90, 255), 3, 0.8) end
            flakes[i] = {
                frame = fr,
                x = math.random(),
                y = math.random(),
                speed = 0.03 + sz * 0.012 + math.random() * 0.05, -- sobe voando
                drift = 0.004 + math.random() * 0.016,
                amp = 0.006 + math.random() * 0.016,
                freq = 0.5 + math.random() * 1.4,
                phase = math.random() * 6.28,
                base = 0.55 - sz * 0.04,
            }
        end

        -- Telinha (holder = balança suavemente)
        local W, H = 400, 310
        local holder = Instance.new("Frame")
        holder.Name = "Holder"
        holder.AnchorPoint = Vector2.new(0.5, 0.5)
        holder.Position = UDim2.fromScale(0.5, 0.5)
        holder.Size = UDim2.fromOffset(W, H)
        holder.BackgroundTransparency = 1
        holder.BorderSizePixel = 0
        holder.ZIndex = 3
        holder.Parent = gui

        local fit = 1
        pcall(function()
            local vs = workspace.CurrentCamera.ViewportSize
            fit = math.clamp(math.min((vs.X - 24) / W, (vs.Y - 24) / H), 0.5, 1)
        end)
        local uiScale = Instance.new("UIScale")
        uiScale.Scale = fit * 0.8
        uiScale.Parent = holder
        TweenService:Create(uiScale, TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
            { Scale = fit }):Play()

        -- Glow roxo (camadas concêntricas)
        local glows = {}
        for i = 1, 8 do
            local g = Instance.new("Frame")
            g.AnchorPoint = Vector2.new(0.5, 0.5)
            g.Position = UDim2.new(0.5, 0, 0.5, 6)
            g.BackgroundColor3 = Color3.fromRGB(150, 70, 255)
            g.BackgroundTransparency = 0.9
            g.BorderSizePixel = 0
            g.ZIndex = 1
            g.Parent = holder
            corner(g, 22 + i * 7)
            g.Size = UDim2.fromOffset(W + i * 16, H + i * 16)
            glows[i] = { frame = g, pad = i * 16 }
        end

        -- Sombra + espessura (efeito 3D)
        local shadow = Instance.new("Frame")
        shadow.AnchorPoint = Vector2.new(0.5, 0.5)
        shadow.Position = UDim2.new(0.5, 0, 0.5, 20)
        shadow.Size = UDim2.new(1, -10, 1, 0)
        shadow.BackgroundColor3 = Color3.new(0, 0, 0)
        shadow.BackgroundTransparency = 0.55
        shadow.BorderSizePixel = 0
        shadow.ZIndex = 2
        shadow.Parent = holder
        corner(shadow, 22)

        local thickness = Instance.new("Frame")
        thickness.AnchorPoint = Vector2.new(0.5, 0.5)
        thickness.Position = UDim2.new(0.5, 0, 0.5, 10)
        thickness.Size = UDim2.new(1, 0, 1, 0)
        thickness.BackgroundColor3 = Color3.fromRGB(58, 20, 120)
        thickness.BorderSizePixel = 0
        thickness.ZIndex = 3
        thickness.Parent = holder
        corner(thickness, 20)

        local panel = Instance.new("Frame")
        panel.Name = "Panel"
        panel.Size = UDim2.fromScale(1, 1)
        panel.BackgroundColor3 = Color3.new(1, 1, 1)
        panel.BorderSizePixel = 0
        panel.ZIndex = 4
        panel.Parent = holder
        corner(panel, 20)
        local panelGrad = Instance.new("UIGradient")
        panelGrad.Color = ColorSequence.new(Color3.fromRGB(100, 46, 184), Color3.fromRGB(38, 14, 80))
        panelGrad.Rotation = 90
        panelGrad.Parent = panel
        local panelStroke = border(panel, Color3.new(1, 1, 1), 2, 0)
        local strokeGrad = Instance.new("UIGradient")
        strokeGrad.Color = ColorSequence.new(Color3.fromRGB(225, 180, 255), Color3.fromRGB(115, 55, 215))
        strokeGrad.Rotation = 60
        strokeGrad.Parent = panelStroke

        -- Brilho de vidro no topo (bevel)
        local sheen = Instance.new("Frame")
        sheen.Position = UDim2.new(0, 4, 0, 4)
        sheen.Size = UDim2.new(1, -8, 0.45, 0)
        sheen.BackgroundColor3 = Color3.new(1, 1, 1)
        sheen.BorderSizePixel = 0
        sheen.ZIndex = 1
        sheen.Parent = panel
        corner(sheen, 17)
        local sheenGrad = Instance.new("UIGradient")
        sheenGrad.Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.82),
            NumberSequenceKeypoint.new(1, 1),
        })
        sheenGrad.Rotation = 90
        sheenGrad.Parent = sheen

        -- Textos
        local title = Instance.new("TextLabel")
        title.Position = UDim2.new(0, 24, 0, 20)
        title.Size = UDim2.new(1, -48, 0, 28)
        title.BackgroundTransparency = 1
        title.Font = Enum.Font.GothamBold
        title.TextSize = 22
        title.TextColor3 = Color3.fromRGB(240, 225, 255)
        title.ZIndex = 3
        title.Parent = panel
        local titleStroke = Instance.new("UIStroke")
        titleStroke.Color = Color3.fromRGB(150, 70, 255)
        titleStroke.Thickness = 1
        titleStroke.Transparency = 0.5
        titleStroke.Parent = title

        local sub = Instance.new("TextLabel")
        sub.Position = UDim2.new(0, 24, 0, 52)
        sub.Size = UDim2.new(1, -48, 0, 18)
        sub.BackgroundTransparency = 1
        sub.Font = Enum.Font.Gotham
        sub.TextSize = 13
        sub.TextColor3 = Color3.fromRGB(190, 160, 235)
        sub.ZIndex = 3
        sub.Parent = panel

        -- Dropdown (caixa que mostra o idioma escolhido)
        local dropBox = Instance.new("Frame")
        dropBox.Position = UDim2.new(0, 24, 0, 88)
        dropBox.Size = UDim2.new(1, -48, 0, 44)
        dropBox.BackgroundColor3 = Color3.fromRGB(24, 10, 50)
        dropBox.BorderSizePixel = 0
        dropBox.ZIndex = 3
        dropBox.Parent = panel
        corner(dropBox, 10)
        local dropStroke = border(dropBox, Color3.fromRGB(160, 90, 255), 1.5, 0.1)

        local dropLabel = Instance.new("TextLabel")
        dropLabel.Position = UDim2.new(0, 14, 0, 0)
        dropLabel.Size = UDim2.new(1, -48, 1, 0)
        dropLabel.BackgroundTransparency = 1
        dropLabel.Font = Enum.Font.GothamMedium
        dropLabel.TextSize = 15
        dropLabel.TextColor3 = Color3.new(1, 1, 1)
        dropLabel.TextXAlignment = Enum.TextXAlignment.Left
        dropLabel.TextTruncate = Enum.TextTruncate.AtEnd
        dropLabel.ZIndex = 4
        dropLabel.Parent = dropBox

        local arrow = Instance.new("TextLabel")
        arrow.AnchorPoint = Vector2.new(0.5, 0.5)
        arrow.Position = UDim2.new(1, -22, 0.5, 0)
        arrow.Size = UDim2.fromOffset(20, 20)
        arrow.BackgroundTransparency = 1
        arrow.Font = Enum.Font.GothamBold
        arrow.Text = "▼"
        arrow.TextSize = 11
        arrow.TextColor3 = Color3.fromRGB(190, 130, 255)
        arrow.ZIndex = 4
        arrow.Parent = dropBox

        local dropClick = Instance.new("TextButton")
        dropClick.Size = UDim2.fromScale(1, 1)
        dropClick.BackgroundTransparency = 1
        dropClick.Text = ""
        dropClick.ZIndex = 5
        dropClick.Parent = dropBox

        -- Lista de idiomas (abre por cima do resto)
        local LIST_H = 150
        local list = Instance.new("ScrollingFrame")
        list.Name = "LanguageList"
        list.Position = UDim2.new(0, 24, 0, 138)
        list.Size = UDim2.new(1, -48, 0, 0)
        list.BackgroundColor3 = Color3.fromRGB(18, 7, 38)
        list.BorderSizePixel = 0
        list.Visible = false
        list.ScrollBarThickness = 4
        list.ScrollBarImageColor3 = Color3.fromRGB(170, 100, 255)
        list.CanvasSize = UDim2.new(0, 0, 0, 0)
        list.AutomaticCanvasSize = Enum.AutomaticSize.Y
        list.ScrollingDirection = Enum.ScrollingDirection.Y
        list.ZIndex = 30
        list.Parent = panel
        corner(list, 10)
        border(list, Color3.fromRGB(160, 90, 255), 1.5, 0.1)
        local layout = Instance.new("UIListLayout")
        layout.SortOrder = Enum.SortOrder.LayoutOrder
        layout.Padding = UDim.new(0, 2)
        layout.Parent = list
        local listPad = Instance.new("UIPadding")
        listPad.PaddingTop = UDim.new(0, 6)
        listPad.PaddingBottom = UDim.new(0, 6)
        listPad.PaddingLeft = UDim.new(0, 6)
        listPad.PaddingRight = UDim.new(0, 6)
        listPad.Parent = list

        -- Botão Continuar
        local contGlow = Instance.new("Frame")
        contGlow.Position = UDim2.new(0, 18, 0, 156)
        contGlow.Size = UDim2.new(1, -36, 0, 54)
        contGlow.BackgroundColor3 = Color3.fromRGB(150, 70, 255)
        contGlow.BackgroundTransparency = 0.8
        contGlow.BorderSizePixel = 0
        contGlow.ZIndex = 2
        contGlow.Parent = panel
        corner(contGlow, 16)

        local cont = Instance.new("TextButton")
        cont.Position = UDim2.new(0, 24, 0, 160)
        cont.Size = UDim2.new(1, -48, 0, 46)
        cont.BackgroundColor3 = Color3.new(1, 1, 1)
        cont.BorderSizePixel = 0
        cont.AutoButtonColor = false
        cont.Font = Enum.Font.GothamBold
        cont.TextSize = 16
        cont.TextColor3 = Color3.new(1, 1, 1)
        cont.ZIndex = 3
        cont.Parent = panel
        corner(cont, 12)
        local contGrad = Instance.new("UIGradient")
        contGrad.Color = ColorSequence.new(Color3.fromRGB(178, 96, 255), Color3.fromRGB(112, 50, 224))
        contGrad.Rotation = 90
        contGrad.Parent = cont
        local contStroke = border(cont, Color3.fromRGB(228, 195, 255), 1.5, 0.15)
        local contScale = Instance.new("UIScale")
        contScale.Parent = cont

        -- Texto de baixo
        local note = Instance.new("TextLabel")
        note.Position = UDim2.new(0, 24, 0, 232)
        note.Size = UDim2.new(1, -48, 0, 40)
        note.BackgroundTransparency = 1
        note.Font = Enum.Font.Gotham
        note.TextSize = 12
        note.TextWrapped = true
        note.TextYAlignment = Enum.TextYAlignment.Top
        note.TextColor3 = Color3.fromRGB(175, 145, 225)
        note.ZIndex = 3
        note.Parent = panel

        -- Lógica ---------------------------------------------------
        local items = {}
        local open = false

        local function refreshTexts()
            title.Text = I18N.T("Escolha seu idioma", selected)
            sub.Text = I18N.T("Selecione o idioma do LOCOPANI", selected)
            cont.Text = I18N.T("Continuar", selected)
            note.Text = I18N.T("Você conseguirá mudar depois nas configurações", selected)
            dropLabel.Text = byCode[selected] or selected
        end

        local function paintItems()
            for code, b in pairs(items) do
                if code == selected then
                    b.BackgroundTransparency = 0.15
                    b.TextColor3 = Color3.new(1, 1, 1)
                else
                    b.BackgroundTransparency = 1
                    b.TextColor3 = Color3.fromRGB(225, 205, 255)
                end
            end
        end

        local function setOpen(v)
            open = v
            if v then
                list.Visible = true
                TweenService:Create(list, TweenInfo.new(0.18, Enum.EasingStyle.Quad),
                    { Size = UDim2.new(1, -48, 0, LIST_H) }):Play()
                pcall(function()
                    for i, l in ipairs(LANGUAGES) do
                        if l[1] == selected then
                            list.CanvasPosition = Vector2.new(0, math.max(0, (i - 1) * 34 - 40))
                            break
                        end
                    end
                end)
            else
                TweenService:Create(list, TweenInfo.new(0.14, Enum.EasingStyle.Quad),
                    { Size = UDim2.new(1, -48, 0, 0) }):Play()
                task.delay(0.16, function()
                    if not open and list.Parent then list.Visible = false end
                end)
            end
            TweenService:Create(arrow, TweenInfo.new(0.18), { Rotation = v and 180 or 0 }):Play()
            TweenService:Create(dropStroke, TweenInfo.new(0.18), { Transparency = v and 0 or 0.1 }):Play()
        end

        local function choose(code)
            selected = code
            paintItems()
            refreshTexts()
            setOpen(false)
        end

        for i, l in ipairs(LANGUAGES) do
            local code, name = l[1], l[2]
            local b = Instance.new("TextButton")
            b.Name = code
            b.LayoutOrder = i
            b.Size = UDim2.new(1, -4, 0, 32)
            b.BackgroundColor3 = Color3.fromRGB(120, 55, 215)
            b.BackgroundTransparency = 1
            b.BorderSizePixel = 0
            b.AutoButtonColor = false
            b.Font = Enum.Font.Gotham
            b.TextSize = 14
            b.TextColor3 = Color3.fromRGB(225, 205, 255)
            b.TextXAlignment = Enum.TextXAlignment.Left
            b.Text = name
            b.ZIndex = 31
            b.Parent = list
            corner(b, 7)
            local pad = Instance.new("UIPadding")
            pad.PaddingLeft = UDim.new(0, 10)
            pad.Parent = b
            items[code] = b
            b.MouseEnter:Connect(function()
                if selected ~= code then
                    TweenService:Create(b, TweenInfo.new(0.1), { BackgroundTransparency = 0.6 }):Play()
                end
            end)
            b.MouseLeave:Connect(function()
                if selected ~= code then
                    TweenService:Create(b, TweenInfo.new(0.1), { BackgroundTransparency = 1 }):Play()
                end
            end)
            b.MouseButton1Click:Connect(function() choose(code) end)
        end

        dropClick.MouseButton1Click:Connect(function() setOpen(not open) end)

        cont.MouseEnter:Connect(function()
            TweenService:Create(contStroke, TweenInfo.new(0.12), { Transparency = 0 }):Play()
            TweenService:Create(contGlow, TweenInfo.new(0.12), { BackgroundTransparency = 0.65 }):Play()
        end)
        cont.MouseLeave:Connect(function()
            TweenService:Create(contStroke, TweenInfo.new(0.12), { Transparency = 0.15 }):Play()
            TweenService:Create(contGlow, TweenInfo.new(0.12), { BackgroundTransparency = 0.8 }):Play()
        end)
        cont.MouseButton1Down:Connect(function()
            TweenService:Create(contScale, TweenInfo.new(0.08), { Scale = 0.96 }):Play()
        end)
        cont.MouseButton1Up:Connect(function()
            TweenService:Create(contScale, TweenInfo.new(0.08), { Scale = 1 }):Play()
        end)
        cont.MouseButton1Click:Connect(function() confirmed = true end)

        refreshTexts()
        paintItems()

        -- Animação (partículas voando, glow pulsando, telinha flutuando)
        local t0 = os.clock()
        pickerState.conn = RunService.RenderStepped:Connect(function(dt)
            dt = math.min(dt, 0.1)
            local t = os.clock() - t0

            for _, fl in ipairs(flakes) do
                fl.y = fl.y - fl.speed * dt
                fl.x = fl.x + fl.drift * dt
                if fl.y < -0.05 then
                    fl.y = 1.05
                    fl.x = math.random()
                end
                if fl.x > 1.05 then fl.x = -0.05 end
                fl.frame.Position = UDim2.fromScale(fl.x + math.sin(t * fl.freq + fl.phase) * fl.amp, fl.y)
                fl.frame.BackgroundTransparency = fl.base + 0.15 * math.sin(t * 2 + fl.phase)
            end

            for _, g in ipairs(glows) do
                g.frame.BackgroundTransparency = 0.9 - 0.02 * math.sin(t * 2.2)
            end
        end)

        -- Espera o jogador confirmar
        while not confirmed and gui.Parent do
            task.wait(0.05)
        end

        I18N.Lang = selected
        saveLang(selected)

        -- Saída suave
        pcall(function()
            TweenService:Create(uiScale, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
                { Scale = fit * 0.85 }):Play()
            TweenService:Create(bg, TweenInfo.new(0.3), { BackgroundTransparency = 1 }):Play()
            if pickerState.blur then
                TweenService:Create(pickerState.blur, TweenInfo.new(0.3), { Size = 0 }):Play()
            end
        end)
        task.wait(0.32)
        cleanupPicker()
        return selected
    end

    -- Mostra a telinha só na primeira vez (ou se o arquivo não existir)
    function I18N.EnsureLanguage()
        local saved = getSaved()
        if saved then
            I18N.Lang = saved
            I18N.StartAuto()
            return saved
        end
        local loader = env.LOCOPANI_LOADER
        pcall(function() if loader then loader.Hide(true) end end)
        local ok, chosen = pcall(I18N.ShowPicker)
        cleanupPicker()
        pcall(function() if loader then loader.Show() end end)
        if not ok or not byCode[chosen] then
            I18N.Lang = guessLanguage()
        end
        I18N.StartAuto()
        return I18N.Lang
    end
end

-- Config UI isolada para evitar o limite de 200 registradores locais do Luau.
local function LOCOPANI_BuildConfigUI(v174, LOCOPANI_RAY_WINDOW, LOCOPANI_RayControl, LOCOPANI_ARGON)
  pcall(function() v174:SetConfigFolder("LOCOPANI") end)
  local configTab = LOCOPANI_RAY_WINDOW:Tab({ Title = "Configs", Icon = "folder-cog" })
  local configName = ""
  local selectedConfig = nil
  local configStatus
  local configDropdown
  local configNames = {}

  configTab:Input({
    Title = "Nome para salvar",
    Placeholder = "Digite um nome para salvar",
    Callback = function(value)
      configName = tostring(value or "")
    end,
  })

  local function setConfigStatus(message)
    if configStatus and configStatus.Set then
      pcall(function() configStatus:Set(message) end)
    end
    pcall(function() v174:Notify(message) end)
  end

  local function cleanConfigName(name)
    name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    name = name:gsub("[^%w_%-]", "_")
    if #name > 48 then name = name:sub(1, 48) end
    return name
  end

  local function refreshConfigList()
    local found = {}
    -- Use the same config manager as SaveConfig/LoadConfig, so the dropdown
    -- reads exactly the folder the script is configured to use.
    local ok, files = pcall(function() return v174:ListConfigs() end)
    if ok and type(files) == "table" then
      for _, item in ipairs(files) do
        local name = tostring(item):match("([^/\\]+)%.json$") or tostring(item)
        name = name:gsub("%.json$", "")
        if name ~= "" then found[name] = true end
      end
    end

    configNames = {}
    for name in pairs(found) do table.insert(configNames, name) end
    table.sort(configNames, function(a, b) return string.lower(a) < string.lower(b) end)

    if configDropdown and configDropdown.SetValues then
      configDropdown:SetValues(configNames)
    end

    if selectedConfig and not found[selectedConfig] then selectedConfig = nil end
    return configNames
  end

  -- Use the Gen2 wrapper so the dropdown can refresh through SetValues.
  configDropdown = LOCOPANI_RayControl("Dropdown", configTab, "Configurações", {
    Values = {},
    Default = nil,
    Placeholder = "Selecione uma configuração",
  }, function(selected)
    if type(selected) == "table" then selected = selected[1] end
    if type(selected) == "string" and selected ~= "" then
      selectedConfig = selected
      configName = selected
    end
  end)

  local function getConfigTarget()
    if tostring(configName or ""):gsub("%s+", "") ~= "" then
      return cleanConfigName(configName)
    end
    return cleanConfigName(selectedConfig)
  end

  configTab:Button({
    Title = "Atualizar lista",
    Callback = function()
      refreshConfigList()
      setConfigStatus("Lista de configurações atualizada.")
    end,
  })

  configTab:Button({
    Title = "Salvar configuração",
    Callback = function()
      local name = cleanConfigName(configName)
      if name == "" then
        setConfigStatus("Digite um nome para a nova configuração.")
        return
      end
      local saveCallOk, saveResult = pcall(function() return v174:SaveConfig(name) end)
      if saveCallOk and saveResult == true then
        selectedConfig = name
        refreshConfigList()
        if configDropdown and configDropdown.Set then
          pcall(function() configDropdown:Set(name) end)
        elseif configDropdown and configDropdown._control and configDropdown._control.Set then
          pcall(function() configDropdown._control:Set(name) end)
        end
        setConfigStatus("Configuração salva: " .. name)
      else
        setConfigStatus("Não foi possível salvar. Verifique se o executor suporta arquivos.")
      end
    end,
  })

  configTab:Button({
    Title = "Carregar selecionada",
    Callback = function()
      local name = getConfigTarget()
      if name == "" then
        setConfigStatus("Selecione uma configuração na lista ou digite um nome.")
        return
      end
      if v174:LoadConfig(name) then
        selectedConfig = name
        setConfigStatus("Configuração carregada: " .. name)
      else
        setConfigStatus("Configuração não encontrada ou arquivo indisponível: " .. name)
      end
    end,
  })

  configTab:Button({
    Title = "Excluir configuração selecionada",
    Callback = function()
      -- Exclusão baseada somente na seleção do dropdown, nunca no texto digitado.
      local name = cleanConfigName(selectedConfig)
      if name == "" then
        setConfigStatus("Selecione no menu a configuração que deseja excluir.")
        return
      end

      local env = (type(getgenv) == "function" and getgenv()) or _G
      local isfileFn = env.isfile or isfile
      local deleteFn = env.delfile or delfile
      local path = "LOCOPANI/configs/" .. name .. ".json"
      if type(deleteFn) ~= "function" then
        setConfigStatus("Este executor não suporta excluir arquivos (delfile).")
        return
      end

      local exists = false
      if type(isfileFn) == "function" then
        local okExists, result = pcall(isfileFn, path)
        exists = okExists and result == true
      else
        local listFn = env.listfiles or listfiles
        if type(listFn) == "function" then
          local okList, files = pcall(listFn, "LOCOPANI/configs")
          if okList and type(files) == "table" then
            for _, filePath in ipairs(files) do
              local base = tostring(filePath):match("([^/\\]+)%.json$")
              if base == name then exists = true break end
            end
          end
        end
      end
      if not exists then
        setConfigStatus("A configuração selecionada não foi encontrada.")
        refreshConfigList()
        return
      end

      local okDelete, deleteErr = pcall(deleteFn, path)
      if not okDelete then
        setConfigStatus("Falha ao excluir a configuração: " .. tostring(deleteErr))
        return
      end

      -- Remove o autoload caso ele aponte para a configuração excluída.
      local readFn = env.readfile or readfile
      local writeFn = env.writefile or writefile
      if type(readFn) == "function" and type(writeFn) == "function" then
        local okRead, autoName = pcall(readFn, "LOCOPANI/autoload.txt")
        if okRead and tostring(autoName or ""):gsub("^%s+", ""):gsub("%s+$", "") == name then
          pcall(writeFn, "LOCOPANI/autoload.txt", "")
        end
      end

      selectedConfig = nil
      configName = ""
      refreshConfigList()
      setConfigStatus("Configuração excluída: " .. name)
    end,
  })

  configTab:Button({
    Title = "Ativar autoload",
    Callback = function()
      local name = getConfigTarget()
      if name == "" then
        setConfigStatus("Selecione uma configuração na lista primeiro.")
        return
      end
      local env = (type(getgenv) == "function" and getgenv()) or _G
      local writeFn = env.writefile or writefile
      if type(writeFn) ~= "function" then
        setConfigStatus("Este executor não suporta salvar arquivos.")
        return
      end
      local env2 = (type(getgenv) == "function" and getgenv()) or _G
      local isfileFn = env2.isfile or isfile
      local exists = false
      if type(isfileFn) == "function" then
        local okExists, result = pcall(isfileFn, "LOCOPANI/configs/" .. name .. ".json")
        exists = okExists and result == true
      else
        local listFn = env2.listfiles or listfiles
        if type(listFn) == "function" then
          local okList, files = pcall(listFn, "LOCOPANI/configs")
          if okList and type(files) == "table" then
            for _, filePath in ipairs(files) do
              if tostring(filePath):match("([^/\\\\]+)%.json$") == name then
                exists = true
                break
              end
            end
          end
        end
      end
      if not exists then
        setConfigStatus("Essa configuração ainda não existe. Salve-a primeiro.")
        return
      end
      pcall(function()
        local mk = env.makefolder or makefolder
        if type(mk) == "function" then
          pcall(mk, "LOCOPANI")
          pcall(mk, "LOCOPANI/configs")
        end
      end)
      local ok = pcall(writeFn, "LOCOPANI/autoload.txt", name)
      if ok then
        setConfigStatus("Autoload ativado: " .. name)
      else
        setConfigStatus("Não foi possível definir o autoload.")
      end
    end,
  })

  configTab:Button({
    Title = "Desativar autoload",
    Callback = function()
      local env = (type(getgenv) == "function" and getgenv()) or _G
      local writeFn = env.writefile or writefile
      if type(writeFn) ~= "function" then
        setConfigStatus("Este executor não suporta arquivos.")
        return
      end
      local ok = pcall(writeFn, "LOCOPANI/autoload.txt", "")
      if ok then
        setConfigStatus("Autoload desativado.")
      else
        setConfigStatus("Não foi possível desativar o autoload.")
      end
    end,
  })

  refreshConfigList()
end

-- A autorizacao de distribuicao e feita pelo locopani-loader antes deste arquivo ser entregue.
-- O bootstrap define esta flag somente depois de receber o source do endpoint autorizado.
local LOCOPANI_BOOTSTRAP_ENV = (type(getgenv) == "function" and getgenv()) or _G
-- LOCOPANI: telinha de idioma (aparece antes da key, só na primeira vez)
pcall(function()
    local I18N = LOCOPANI_BOOTSTRAP_ENV and LOCOPANI_BOOTSTRAP_ENV.LOCOPANI_I18N
    if I18N and I18N.EnsureLanguage then I18N.EnsureLanguage() end
end)
local players, replicatedStorage, userInputService, tweenService, httpService, workspaceService,
  runService, lighting, teleportService, collectionService, replicatedFirst, soundService, v174,
  options, toggles, localPlayer2, currentCamera2, v175, v176, v177, v178, v179, v182, v183,
  v184, v185, v186, v187, v188, v189, v190, v191, v192, v193, v194, v195, v196, v197, v198,
  v199, v200, v201, v202, scoreEffect, v203, v204, v205, v206, v207, v208, v209, v210, jersey,
  v211, ball, v212, v213, v214, v215, v216, v217, v218, v219, v220, v221, v222, v223, v224,
  v225, v226, v227, v228, v229, v231, ballService, serve, effects, doMove, stopAllEmotes,
  effect, v235, v238, f50, v242, v243, v255, v308, v323, v329, v336, textButton2, textButton3,
  textButton4, v395, textButton5, bodyVelocity, f96, textButton6, v418, v440, v451, v495,
  LocopaniWindow, v545, v546

do
  players = game:GetService("Players")
  replicatedStorage = game:GetService("ReplicatedStorage")
  userInputService = game:GetService("UserInputService")
  tweenService = game:GetService("TweenService")
  local GuiService = game:GetService("GuiService")
  httpService = game:GetService("HttpService")
  workspaceService = game:GetService("Workspace")
  runService = game:GetService("RunService")
  lighting = game:GetService("Lighting")
  teleportService = game:GetService("TeleportService")
  collectionService = game:GetService("CollectionService")
  replicatedFirst = game:GetService("ReplicatedFirst")
  soundService = game:GetService("SoundService")

  local function f1()
    local TypeName = type(getgenv) == "function" and getgenv() or _G
    local GetFenv = (function()
      local okF, e = pcall(function() return getfenv(1) end)
      if okF and type(e) == "table" then return e end
      return {}
    end)()
    local v2 = {}

    local function f2(p1)
      for index, value in ipairs({ GetFenv, TypeName, _G }) do
        local Value = value
        local v4, v5 = pcall(function() return Value[p1] end)

        if v4 and type(v5) == "function" then
          return v5
        end
      end

      return nil
    end

    local function f3(p2)
      local v6, v7 = pcall(function() return GetFenv[p2] or TypeName[p2] end)

      if v6 and type(v7) == "table" then
        return v7
      end

      return nil
    end

    local function f4(p3, p4)
      if not p4 then
        table.insert(v2, p3)
        return
      end

      pcall(function() TypeName[p3] = p4 end)
      pcall(function() GetFenv[p3] = p4 end)
    end

    local f2_2 = f2("getconnections") or f2("get_signal_cons")
    f4("getconnections", f2_2)
    local f2_3 = f2("firesignal") or f2("fire_signal")
    local v10

    if f2_3 and f2_2 and function(p5, ...)
      for index2, value2 in ipairs(f2_2(p5)) do
      end
    end then
      local BindableEvent = Instance.new("BindableEvent")
      v10 = false
      BindableEvent.Event:Connect(function() v10 = true end)
      pcall(f2_3, BindableEvent.Event, true)
      task.wait(0.1)
      BindableEvent:Destroy()

      if not v10 then
        f2_3 = nil
      end
    end

    local f2_4 = f2("request") or f2("http_request")

    -- Check each nested request table independently. The old code accidentally
    -- looked up a field named "f2_4", so syn/http/fluxus.request was never used.
    if not f2_4 then
      local f3_2 = f3("syn")
      f2_4 = f3_2 and f3_2.request
    end
    if not f2_4 then
      local f3_2 = f3("http")
      f2_4 = f3_2 and f3_2.request
    end
    if not f2_4 then
      local f3_2 = f3("fluxus")
      f2_4 = f3_2 and f3_2.request
    end

    f4("httpGet", function(p6)
      local v11, v12 = pcall(function() return game:HttpGet(p6) end)

      if v11 and type(v12) == "string" and #v12 > 0 then
        return v12
      elseif f2_4 then
        local v13, v14 = pcall(f2_4, { Url = p6, Method = "GET" })

        if v13 and type(v14) == "table" and type(v14.Body) == "string" then
          return v14.Body
        end

        error("Locopani: no working HTTP method for " .. tostring(p6), 0)
        return
      else
        error("Locopani: no working HTTP method for " .. tostring(p6), 0)
        return
      end
    end)

    local f2_5 = f2("gethui") or f2("get_hidden_gui")
    local f2_6 = f2("protect_gui")

    if not f2_6 then
      local f3_3 = f3("syn")
      f2_6 = f3_3 and f3_3.protect_gui
    end

    f4("hidegui", function(p7)
      if f2_6 then
        pcall(f2_6, p7)
      end

      if f2_5 then
        local v16, v17 = pcall(f2_5)

        if v16 and typeof(v17) == "Instance" then
          p7.Parent = v17
          return
        end
      end

      local v18, v19 = pcall(game.GetService, game, "CoreGui")

      if v18 and v19 then
        if pcall(function() p7.Parent = v19 end) then
          return
        end

        p7.Parent = players.LocalPlayer:WaitForChild("PlayerGui")
        return
      end

      p7.Parent = players.LocalPlayer:WaitForChild("PlayerGui")
    end)

    if #v2 > 0 then
      warn("Locopani: this executor has no " .. table.concat(v2, ", ")
        .. " - features that need them stay off")
    end
  end

  f1()

  local TypeName_2 = type(getgenv) == "function" and getgenv() or _G
  local RawValue = rawget(TypeName_2, "Locopani_SESSION") or TypeName_2.Locopani_SESSION
  local TypeName_3 = type(RawValue) == "table" and RawValue.TypeName_3 or nil

  if type(RawValue) == "table" and type(RawValue.unload) == "function" then
    pcall(RawValue.unload)
  end

  local v20 = getrawmetatable and getrawmetatable(game)
  local v21 = v20 and rawget(v20, "__namecall")

  local v22 = {}
  v22.TypeName_3 = TypeName_3

  function v22.unload()
    if v22.TypeName_3 and v22.TypeName_3.inventory then
      pcall(function()
        local Module = require(replicatedStorage.Packages.Knit).GetController("InventoryController")

        if Module and Module.Inventory then
          Module.Inventory:set(v22.TypeName_3.inventory)
        end
      end)
    end

    if v22.ui and v22.ui.Unload then
      pcall(function() v22.ui:Unload() end)
    end

    for index3, value3 in ipairs(v22.links or {}) do
      local Value3 = value3
      pcall(function() Value3:Disconnect() end)
    end

    pcall(function()
      local v24 = {}

      for index4, value4 in ipairs(v22.tags or {}) do
        v24[value4] = true
      end

      if not next(v24) then
        return
      else
        local v25 = {}

        if type(gethui) == "function" then
          local v26, v27 = pcall(gethui)

          if v26 and v27 then
            table.insert(v25, v27)
          end
        end

        local Game = game
        table.insert(v25, Game:GetService("CoreGui"))

        if workspace.CurrentCamera then
          table.insert(v25, workspace.CurrentCamera)
        end

        if players.LocalPlayer then
          local PlayerGui = players.LocalPlayer:FindFirstChildOfClass("PlayerGui")

          if PlayerGui then
            table.insert(v25, PlayerGui)
          end
        end

        for index5, value5 in ipairs(v25) do
        end

        for index6, value6 in ipairs(workspace:GetChildren()) do
          if value6:IsA("Model") and value6.Name:match("^CLIENT_BALL_%d+$") then
            for index7, value7 in ipairs(value6:GetChildren()) do
              if v24[value7.Name] then
                value7:Destroy()
              end
            end
          end
        end

        for index8, value8 in ipairs(players:GetPlayers()) do
          if value8.Character then
            for index9, value9 in ipairs(value8.Character:GetChildren()) do
              if v24[value9.Name] then
                value9:Destroy()
              end
            end
          end
        end

        return
      end
    end)

    if v20 and v21 then
      pcall(setreadonly, v20, false)
      v20.__namecall = v21
      pcall(setreadonly, v20, true)
    end
  end

  v22.links = {}
  v22.tags = {}

  TypeName_2.Locopani_Season = v22

  local function f5()
    local LocalPlayer = players.LocalPlayer

    -- LOCOPANI UI theme: black minimalist / monochrome
    local v29 = {
      Accent = Color3.fromRGB(245, 245, 247),
      AccentSoft = Color3.fromRGB(42, 42, 46),
      Shell = Color3.fromRGB(8, 8, 9),
      ShellTop = Color3.fromRGB(24, 24, 26),
      Panel = Color3.fromRGB(15, 15, 17),
      Raised = Color3.fromRGB(30, 30, 33),
      Sunken = Color3.fromRGB(5, 5, 6),
      Line = Color3.fromRGB(72, 72, 77),
      LineSoft = Color3.fromRGB(38, 38, 42),
      Text = Color3.fromRGB(250, 250, 252),
      SubText = Color3.fromRGB(184, 184, 190),
      Faint = Color3.fromRGB(132, 132, 140),
    }

    local UDim_2 = UDim.new(1, 0)
    local TweenInfo_2 = TweenInfo.new(0.18, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)

    local v30 = {
      Options = {},
      Toggles = {},
      Theme = v29,
      CornerRadius = 12,
      ForceCheckbox = false,
      ShowToggleFrameInKeybinds = true,
      NotifySide = "Right",
      Unloaded = false,
      ToggleKeybind = nil,
      DefaultToggleKey = "RightShift",
    }

    local v31 = {}
    local v32 = {}
    local v33 = {}
    local v34 = {}
    local v35 = "Locopani"

    local function f6(p8, p9, p10)
      local Instance_2 = Instance.new(p8)

      for key, value10 in pairs(p9) do
        Instance_2[key] = value10
      end

      if p10 then
        Instance_2.Parent = p10
      end

      return Instance_2
    end

    local function f7(p11, cornerRadius, p12)
      local f6_2 = f6("UICorner", { CornerRadius = cornerRadius }, p11)

      if p12 then
        table.insert(v32, f6_2)
      end

      return f6_2
    end

    local function f8(p13, p14, p15, p16)
      return f6("UIStroke", {
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
        LineJoinMode = Enum.LineJoinMode.Round,
        Color = p14 or v29.Line,
        Thickness = p15 or 1,
        Transparency = p16 or 0,
      }, p13)
    end

    local function f9(p17, p18, p19, p20, p21)
      return f6("UIPadding", {
        PaddingLeft = UDim.new(0, p18 or 0),
        PaddingRight = UDim.new(0, p19 or 0),
        PaddingTop = UDim.new(0, p20 or 0),
        PaddingBottom = UDim.new(0, p21 or 0),
      }, p17)
    end

    local function f10(p22, p23, p24)
      return f6("UIListLayout", {
        FillDirection = p24 or Enum.FillDirection.Vertical,
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, p23 or 0),
      }, p22)
    end

    local function f11(p25, p26, p27)
      local New = tweenService:Create(p25, p27 and TweenInfo.new(
        p27, Enum.EasingStyle.Quart, Enum.EasingDirection.Out
      ) or TweenInfo_2, p26)

      New:Play()
      return New
    end

    local function f12(p28, p29)
      local Connection = p28:Connect(p29)
      table.insert(v31, Connection)
      return Connection
    end

    local function f13()
      return string.char(
        math.random(97, 122), math.random(97, 122), math.random(97, 122), math.random(97, 122)
      ) .. tostring(math.random(100000, 999999))
    end

    local f6_3 = f6("ScreenGui", {
      Name = f13(),
      ResetOnSpawn = false,
      IgnoreGuiInset = true,
      AutoLocalize = false,
      ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
      DisplayOrder = 9999,
    })

    local v38 = false

    if type(hidegui) == "function" then
      v38 = pcall(hidegui, f6_3)
    end

    if not v38 or not f6_3.Parent then
      f6_3.Parent = LocalPlayer:WaitForChild("PlayerGui")
    end

    pcall(function() userInputService.MouseIconEnabled = true end)

    local f6_4 = f6("Frame", {
      BackgroundColor3 = v29.Raised,
      BorderSizePixel = 0,
      AutomaticSize = Enum.AutomaticSize.XY,
      Size = UDim2.fromOffset(0, 0),
      Visible = false,
      ZIndex = 190,
    }, f6_3)

    f7(f6_4, UDim.new(0, 8))
    f8(f6_4, v29.Line, 1)
    f9(f6_4, 10, 10, 7, 7)

    local f6_5 = f6("TextLabel", {
      BackgroundTransparency = 1,
      AutomaticSize = Enum.AutomaticSize.XY,
      Font = Enum.Font.GothamMedium,
      TextSize = 12,
      TextColor3 = v29.Text,
      TextXAlignment = Enum.TextXAlignment.Left,
      Text = "",
      ZIndex = 191,
    }, f6_4)

    local f6_6 = f6("Frame", {
      AnchorPoint = Vector2.new(1, 0),
      Position = UDim2.new(1, -18, 0, 18),
      Size = UDim2.fromOffset(280, 0),
      AutomaticSize = Enum.AutomaticSize.Y,
      BackgroundTransparency = 1,
      ZIndex = 180,
    }, f6_3)

    f10(f6_6, 8)

    local f6_7 = f6("Frame", {
      Position = UDim2.fromOffset(24, 120),
      Size = UDim2.fromOffset(190, 0),
      AutomaticSize = Enum.AutomaticSize.Y,
      BackgroundColor3 = v29.Panel,
      BorderSizePixel = 0,
      Visible = false,
      ZIndex = 60,
    }, f6_3)

    f7(f6_7, UDim.new(0, v30.CornerRadius), true)
    f8(f6_7, v29.LineSoft, 1)
    f9(f6_7, 12, 12, 10, 12)
    f10(f6_7, 6)

    f6("TextLabel", {
      Size = UDim2.new(1, 0, 0, 16),
      BackgroundTransparency = 1,
      Font = Enum.Font.GothamBold,
      TextSize = 12,
      TextColor3 = v29.Text,
      TextXAlignment = Enum.TextXAlignment.Left,
      Text = "Keybinds",
      LayoutOrder = 0,
      ZIndex = 61,
    }, f6_7)

    local f6_8 = f6("Frame", {
      Size = UDim2.new(1, 0, 0, 0),
      AutomaticSize = Enum.AutomaticSize.Y,
      BackgroundTransparency = 1,
      LayoutOrder = 1,
      ZIndex = 61,
    }, f6_7)

    f10(f6_8, 4)

    v30.KeybindFrame = f6_7
    v30.Root = f6_3

    local function f14()
      return userInputService:GetMouseLocation() + Vector2.new(0, GuiService:GetGuiInset().Y)
    end

    local function f15(p30, p31)
      if not p31 or p31 == "" then
        return
      end

      f12(p30.MouseEnter, function()
        f6_5.Text = p31
        local f14_2 = f14()

        f6_4.Position = UDim2.fromOffset(f14_2.X + 16, f14_2.Y + 18)
        f6_4.Visible = true
      end)

      f12(p30.MouseMoved, function()
        if f6_4.Visible then
          local f14_3 = f14()
          f6_4.Position = UDim2.fromOffset(f14_3.X + 16, f14_3.Y + 18)
        end
      end)

      f12(p30.MouseLeave, function() f6_4.Visible = false end)
    end

    function v30:Notify(p32, p33)
      local P33 = p33
      local P32 = p32

      if type(p32) == "table" then
        P32 = p32.Description or p32.Title or p32.Text or ""
        P33 = P33 or p32.Time
      end

      local f6_9 = f6("Frame", {
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = v29.Raised,
        BorderSizePixel = 0,
        BackgroundTransparency = 1,
        ZIndex = 181,
      }, f6_6)

      f7(f6_9, UDim.new(0, 10))
      local f8_2 = f8(f6_9, v29.Line, 1, 1)
      f9(f6_9, 12, 12, 10, 10)

      local f6_10 = f6("TextLabel", {
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamMedium,
        TextSize = 12,
        TextColor3 = v29.Text,
        TextTransparency = 1,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextWrapped = true,
        Text = tostring(P32),
        ZIndex = 182,
      }, f6_9)

      f11(f6_9, { BackgroundTransparency = 0 })
      f11(f8_2, { Transparency = 0 })
      f11(f6_10, { TextTransparency = 0 })

      task.delay(P33 or 4, function()
        if not f6_9.Parent then
          return
        end

        f11(f6_9, { BackgroundTransparency = 1 })
        f11(f8_2, { Transparency = 1 })
        f11(f6_10, { TextTransparency = 1 })

        task.wait(0.24)
        f6_9:Destroy()
      end)
    end

    function v30:SetNotifySide(p34)
      v30.NotifySide = p34

      if p34 == "Left" then
        f6_6.AnchorPoint = Vector2.new(0, 0)
        f6_6.Position = UDim2.new(0, 18, 0, 18)
      else
        f6_6.AnchorPoint = Vector2.new(1, 0)
        f6_6.Position = UDim2.new(1, -18, 0, 18)
      end
    end

    local function f16()
      for index10, value11 in ipairs(f6_8:GetChildren()) do
        if value11:IsA("Frame") then
          value11:Destroy()
        end
      end

      local count = 0

      for index11, value12 in ipairs(v33) do
        if not value12.NoUI and value12.Value and value12.Value ~= "" then
          count = count + 1

          local f6_11 = f6("Frame", {
            Size = UDim2.new(1, 0, 0, 20),
            BackgroundTransparency = 1,
            LayoutOrder = count,
            ZIndex = 62,
          }, f6_8)

          f6("TextLabel", {
            Size = UDim2.new(1, -54, 1, 0),
            BackgroundTransparency = 1,
            Font = Enum.Font.GothamMedium,
            TextSize = 11,
            TextColor3 = v29.SubText,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
            Text = value12.Label,
            ZIndex = 62,
          }, f6_11)

          local f6_12 = f6("Frame", {
            AnchorPoint = Vector2.new(1, 0.5),
            Position = UDim2.new(1, 0, 0.5, 0),
            Size = UDim2.fromOffset(52, 18),
            BackgroundColor3 = v29.Sunken,
            BorderSizePixel = 0,
            ZIndex = 62,
          }, f6_11)

          f7(f6_12, UDim_2)
          f8(f6_12, v29.Line, 1)

          f6("TextLabel", {
            Size = UDim2.fromScale(1, 1),
            BackgroundTransparency = 1,
            Font = Enum.Font.GothamBold,
            TextSize = 10,
            TextColor3 = v29.Accent,
            TextTruncate = Enum.TextTruncate.AtEnd,
            Text = value12.Value,
            ZIndex = 63,
          }, f6_12)
        end
      end
    end

    local function f17(p35, p36)
      local v52 = false
      local position, position2

      f12(p35.InputBegan, function(p37)
        if p37.UserInputType == Enum.UserInputType.MouseButton1
          or p37.UserInputType == Enum.UserInputType.Touch then
          v52 = true
          position = p37.Position
          position2 = p36.Position
        end
      end)

      f12(p35.InputEnded, function(p38)
        if p38.UserInputType == Enum.UserInputType.MouseButton1
          or p38.UserInputType == Enum.UserInputType.Touch then
          v52 = false
        end
      end)

      f12(userInputService.InputChanged, function(p39)
        if not v52 then
          return
        end

        if p39.UserInputType == Enum.UserInputType.MouseMovement
          or p39.UserInputType == Enum.UserInputType.Touch then
          local v53 = p39.Position - position

          p36.Position = UDim2.new(
            position2.X.Scale, position2.X.Offset + v53.X, position2.Y.Scale,
            position2.Y.Offset + v53.Y
          )
        end
      end)
    end

    f17(f6_7, f6_7)

    local function f18(p40)
      local v54 = { Holder = p40, Order = 0 }

      local function f19(p41, p42)
        v54.Order = v54.Order + 1

        local f6_13 = f6("Frame", {
          Size = UDim2.new(1, 0, 0, p41 or 0),
          BackgroundTransparency = 1,
          LayoutOrder = v54.Order,
        }, p40)

        if p42 then
          f6_13.AutomaticSize = Enum.AutomaticSize.Y
        end

        return f6_13
      end

      local function f20(p43, text)
        return f6("TextLabel", {
          Size = UDim2.new(1, 0, 0, 15),
          BackgroundTransparency = 1,
          Font = Enum.Font.GothamMedium,
          TextSize = 12,
          TextColor3 = v29.SubText,
          TextXAlignment = Enum.TextXAlignment.Left,
          TextTruncate = Enum.TextTruncate.AtEnd,
          Text = text,
          LayoutOrder = 0,
        }, p43)
      end

      function v54:AddToggle(p44, p45)
        local P45 = p45
        P45 = P45 or {}

        local f19_2 = f19(30)

        local f6_14 = f6("TextLabel", {
          Size = UDim2.new(1, -54, 1, 0),
          BackgroundTransparency = 1,
          Font = Enum.Font.GothamMedium,
          TextSize = 12,
          TextColor3 = v29.SubText,
          TextXAlignment = Enum.TextXAlignment.Left,
          TextTruncate = Enum.TextTruncate.AtEnd,
          Text = P45.Text or p44,
        }, f19_2)

        local ForceCheckbox = v30.ForceCheckbox

        local f6_15 = f6("Frame", {
          AnchorPoint = Vector2.new(1, 0.5),
          Position = UDim2.new(1, 0, 0.5, 0),
          Size = ForceCheckbox and UDim2.fromOffset(21, 21) or UDim2.fromOffset(42, 22),
          BackgroundColor3 = v29.Sunken,
          BorderSizePixel = 0,
        }, f19_2)

        f7(f6_15, ForceCheckbox and UDim.new(0, 6) or UDim_2)
        local f8_3 = f8(f6_15, v29.Line, 1)

        local f6_16 = f6("Frame", {
          Position = ForceCheckbox and UDim2.fromOffset(5, 5) or UDim2.fromOffset(3, 3),
          Size = ForceCheckbox and UDim2.fromOffset(11, 11) or UDim2.fromOffset(16, 16),
          BackgroundColor3 = v29.Faint,
          BorderSizePixel = 0,
        }, f6_15)

        f7(f6_16, ForceCheckbox and UDim.new(0, 3) or UDim_2)

        if not ForceCheckbox then
          f8(f6_16, v29.Line, 1)
        end

        local f6_17 = f6("TextButton", {
          Size = UDim2.fromScale(1, 1),
          BackgroundTransparency = 1,
          Text = "",
          AutoButtonColor = false,
        }, f19_2)

        f15(f6_17, P45.Tooltip)

        local v63 = {
          Value = false,
          Type = "Toggle",
          Index = p44,
          Callbacks = {},
        }

        local function f21()
          if v63.Value then
            f11(f6_15, { BackgroundColor3 = v29.AccentSoft })
            f11(f8_3, { Color = v29.Accent })
            f11(f6_16, { BackgroundColor3 = v29.Text })
            f11(f6_14, { TextColor3 = v29.Text })

            if not ForceCheckbox then
              f11(f6_16, { Position = UDim2.fromOffset(23, 3) })
            end
          else
            f11(f6_15, { BackgroundColor3 = v29.Sunken })
            f11(f8_3, { Color = v29.Line })
            f11(f6_16, { BackgroundColor3 = v29.Faint })
            f11(f6_14, { TextColor3 = v29.SubText })

            if not ForceCheckbox then
              f11(f6_16, { Position = UDim2.fromOffset(3, 3) })
            end
          end
        end

        function v63:SetValue(p46, p47)
          v63.Value = p46 and true or false
          f21()

          if p47 then
            return
          end

          if P45.Callback then
            task.spawn(P45.Callback, v63.Value)
          end

          for index12, value13 in ipairs(v63.Callbacks) do
            task.spawn(value13, v63.Value)
          end
        end

        function v63.OnChanged(p48, p49)
          table.insert(v63.Callbacks, p49)
          task.spawn(p49, v63.Value)
          return v63
        end

        f12(f6_17.MouseButton1Click, function() v63:SetValue(not v63.Value) end)
        v63:SetValue(P45.Default and true or false, true)

        if P45.Default then
          if P45.Callback then
            task.spawn(P45.Callback, true)
          end
        end

        v30.Toggles[p44] = v63
        return v63
      end

      function v54:AddSlider(p50, p51)
        local P51 = p51
        P51 = P51 or {}

        local f19_3 = f19(44)
        f15(f19_3, P51.Tooltip)

        f6("TextLabel", {
          Size = UDim2.new(1, -70, 0, 16),
          BackgroundTransparency = 1,
          Font = Enum.Font.GothamMedium,
          TextSize = 12,
          TextColor3 = v29.SubText,
          TextXAlignment = Enum.TextXAlignment.Left,
          TextTruncate = Enum.TextTruncate.AtEnd,
          Text = P51.Text or p50,
        }, f19_3)

        local f6_18 = f6("TextLabel", {
          AnchorPoint = Vector2.new(1, 0),
          Position = UDim2.new(1, 0, 0, 0),
          Size = UDim2.fromOffset(70, 16),
          BackgroundTransparency = 1,
          Font = Enum.Font.GothamBold,
          TextSize = 12,
          TextColor3 = v29.Accent,
          TextXAlignment = Enum.TextXAlignment.Right,
          Text = "0",
        }, f19_3)

        local f6_19 = f6("Frame", {
          Position = UDim2.new(0, 0, 0, 26),
          Size = UDim2.new(1, 0, 0, 10),
          BackgroundColor3 = v29.Sunken,
          BorderSizePixel = 0,
        }, f19_3)

        f7(f6_19, UDim_2)
        f8(f6_19, v29.Line, 1)

        local f6_20 = f6("Frame", {
          Size = UDim2.new(0, 0, 1, 0),
          BackgroundColor3 = v29.Accent,
          BorderSizePixel = 0,
        }, f6_19)

        f7(f6_20, UDim_2)

        local f6_21 = f6("Frame", {
          AnchorPoint = Vector2.new(0.5, 0.5),
          Position = UDim2.new(0, 0, 0.5, 0),
          Size = UDim2.fromOffset(14, 14),
          BackgroundColor3 = v29.Text,
          BorderSizePixel = 0,
          ZIndex = 3,
        }, f6_19)

        f7(f6_21, UDim_2)
        f8(f6_21, v29.Accent, 1)
        local min = P51.Min or 0
        local max = P51.Max or 100
        local v70 = 10 ^ (P51.Rounding or 0)

        local v71 = {
          Value = P51.Default or min,
          Type = "Slider",
          Index = p50,
          Min = min,
          Max = max,
          Callbacks = {},
        }

        local function f22()
          local v72 = max - min
          local Clamp = v72 > 0 and math.clamp((v71.Value - min) / v72, 0, 1) or 0
          f6_20.Size = UDim2.new(Clamp, 0, 1, 0)
          f6_21.Position = UDim2.new(Clamp, 0, 0.5, 0)
          f6_18.Text = tostring(v71.Value) .. (P51.Suffix or "")
        end

        function v71:SetValue(p52, p53)
          local ToNumber = tonumber(p52) or min
          local MathClamp = math.clamp(ToNumber, min, max)
          local MathFloor = math.floor(MathClamp * v70 + 0.5) / v70
          v71.Value = MathFloor
          f22()

          if p53 then
            return
          end

          if P51.Callback then
            task.spawn(P51.Callback, MathFloor)
          end

          for index13, value14 in ipairs(v71.Callbacks) do
            task.spawn(value14, MathFloor)
          end
        end

        function v71.OnChanged(p54, p55)
          table.insert(v71.Callbacks, p55)
          task.spawn(p55, v71.Value)
          return v71
        end

        local function f23(p56)
          local X = f6_19.AbsoluteSize.X

          if X <= 0 then
            return
          end

          v71:SetValue(min + (max - min) * math.clamp((p56 - f6_19.AbsolutePosition.X) / X, 0, 1))
        end

        local v77 = false

        f12(f6_19.InputBegan, function(p57)
          if p57.UserInputType == Enum.UserInputType.MouseButton1
            or p57.UserInputType == Enum.UserInputType.Touch then
            v77 = true
            f11(f6_21, { Size = UDim2.fromOffset(18, 18) })
            f23(p57.Position.X)
          end
        end)

        f12(userInputService.InputEnded, function(p58)
          if p58.UserInputType == Enum.UserInputType.MouseButton1
            or p58.UserInputType == Enum.UserInputType.Touch then
            if v77 then
              v77 = false
              f11(f6_21, { Size = UDim2.fromOffset(14, 14) })
            end
          end
        end)

        f12(userInputService.InputChanged, function(p59)
          if v77
            and (p59.UserInputType == Enum.UserInputType.MouseMovement
              or p59.UserInputType == Enum.UserInputType.Touch) then
            f23(p59.Position.X)
          end
        end)

        v71:SetValue(P51.Default or min, true)

        if P51.Default ~= nil and P51.Callback then
          task.spawn(P51.Callback, v71.Value)
        end

        v30.Options[p50] = v71
        return v71
      end

      function v54:AddDropdown(p60, p61)
        local P61 = p61
        P61 = P61 or {}

        local f19_4 = f19(0, true)
        f10(f19_4, 6)
        f15(f19_4, P61.Tooltip)
        f20(f19_4, P61.Text or p60)

        local f6_22 = f6("TextButton", {
          Size = UDim2.new(1, 0, 0, 30),
          BackgroundColor3 = v29.Sunken,
          BorderSizePixel = 0,
          Font = Enum.Font.GothamMedium,
          TextSize = 12,
          TextColor3 = v29.Text,
          TextXAlignment = Enum.TextXAlignment.Left,
          TextTruncate = Enum.TextTruncate.AtEnd,
          Text = "",
          AutoButtonColor = false,
          LayoutOrder = 1,
        }, f19_4)

        f7(f6_22, UDim_2)
        local f8_4 = f8(f6_22, v29.Line, 1)
        f9(f6_22, 14, 30, 0, 0)

        local f6_23 = f6("TextLabel", {
          AnchorPoint = Vector2.new(1, 0.5),
          Position = UDim2.new(1, -12, 0.5, 0),
          Size = UDim2.fromOffset(12, 12),
          BackgroundTransparency = 1,
          Font = Enum.Font.GothamBold,
          TextSize = 12,
          TextColor3 = v29.Faint,
          Text = ">",
          Rotation = 90,
        }, f6_22)

        local f6_24 = f6("Frame", {
          Size = UDim2.new(1, 0, 0, 0),
          BackgroundColor3 = v29.Sunken,
          BorderSizePixel = 0,
          Visible = false,
          LayoutOrder = 2,
          ClipsDescendants = true,
        }, f19_4)

        f7(f6_24, UDim.new(0, 10))
        f8(f6_24, v29.Line, 1)

        local f6_25 = f6("ScrollingFrame", {
          Size = UDim2.fromScale(1, 1),
          BackgroundTransparency = 1,
          BorderSizePixel = 0,
          CanvasSize = UDim2.new(),
          AutomaticCanvasSize = Enum.AutomaticSize.Y,
          ScrollBarThickness = 2,
          ScrollBarImageColor3 = v29.Line,
          ScrollingDirection = Enum.ScrollingDirection.Y,
        }, f6_24)

        f10(f6_25, 3)
        f9(f6_25, 5, 7, 5, 5)

        local v85 = {
          Value = nil,
          Type = "Dropdown",
          Index = p60,
          Values = P61.Values or {},
          Callbacks = {},
          Open = false,
        }

        local v86 = {}

        local function f24()
          if P61.Multi then
            local selectedLabels = {}
            for _, item in ipairs(v85.Values) do
              if type(v85.Value) == "table" and v85.Value[item] then
                table.insert(selectedLabels, tostring(item))
              end
            end
            f6_22.Text = #selectedLabels > 0 and table.concat(selectedLabels, ", ") or "Nenhum selecionado"
          else
            f6_22.Text = tostring(v85.Value or "--")
          end

          for key2, value15 in pairs(v86) do
            local isSelected
            if P61.Multi then
              isSelected = type(v85.Value) == "table" and v85.Value[key2] == true
            else
              isSelected = key2 == v85.Value
            end
            if isSelected then
              f11(value15.Frame, { BackgroundColor3 = v29.AccentSoft })
              f11(value15.Edge, { Transparency = 0, Color = v29.Accent })
              f11(value15.Label, { TextColor3 = v29.Text })
            else
              f11(value15.Frame, { BackgroundColor3 = v29.Raised })
              f11(value15.Edge, { Transparency = 1, Color = v29.Line })
              f11(value15.Label, { TextColor3 = v29.SubText })
            end
          end
        end

        function v85:SetValue(p62, p63)
          if P61.Multi then
            v85.Value = type(p62) == "table" and p62 or {}
          else
            v85.Value = p62
          end
          f24()

          if p63 then
            return
          end

          if P61.Callback then
            task.spawn(P61.Callback, p62)
          end

          for index14, value16 in ipairs(v85.Callbacks) do
            task.spawn(value16, p62)
          end
        end

        function v85.OnChanged(p64, p65)
          table.insert(v85.Callbacks, p65)
          task.spawn(p65, v85.Value)
          return v85
        end

        local function f25()
          v85.Open = false

          f6_24.Visible = false
          f6_24.Size = UDim2.new(1, 0, 0, 0)

          f11(f6_23, { Rotation = 90 })
          f11(f8_4, { Color = v29.Line })
        end

        function v85:SetValues(p66)
          v85.Values = p66 or {}
          v86 = {}

          for index15, value17 in ipairs(f6_25:GetChildren()) do
            if value17:IsA("TextButton") then
              value17:Destroy()
            end
          end

          for index16, value18 in ipairs(v85.Values) do
            local Value18 = value18

            local f6_26 = f6("TextButton", {
              Size = UDim2.new(1, 0, 0, 26),
              BackgroundColor3 = v29.Raised,
              BorderSizePixel = 0,
              Font = Enum.Font.GothamMedium,
              TextSize = 12,
              TextColor3 = v29.SubText,
              TextXAlignment = Enum.TextXAlignment.Left,
              TextTruncate = Enum.TextTruncate.AtEnd,
              Text = "",
              AutoButtonColor = false,
              LayoutOrder = index16,
            }, f6_25)

            f7(f6_26, UDim_2)
            local f8_5 = f8(f6_26, v29.Line, 1, 1)
            local UDim2_2 = UDim2.new(1, -24, 1, 0)
            local UDim2_3 = UDim2.fromOffset(12, 0)
            local ToString = tostring(Value18)

            v86[Value18] = {
              Frame = f6_26,
              Edge = f8_5,
              Label = f6("TextLabel", {
                Size = UDim2_2,
                Position = UDim2_3,
                BackgroundTransparency = 1,
                Font = Enum.Font.GothamMedium,
                TextSize = 12,
                TextColor3 = v29.SubText,
                TextXAlignment = Enum.TextXAlignment.Left,
                TextTruncate = Enum.TextTruncate.AtEnd,
                Text = ToString,
              }, f6_26),
            }

            f12(f6_26.MouseButton1Click, function()
              if P61.Multi then
                local selected = {}
                if type(v85.Value) == "table" then
                  for selectedName, enabled in pairs(v85.Value) do
                    if enabled then selected[selectedName] = true end
                  end
                end
                selected[Value18] = not selected[Value18] or nil
                v85:SetValue(selected)
              else
                v85:SetValue(Value18)
                f25()
              end
            end)
          end

          f24()
        end

        f12(f6_22.MouseButton1Click, function()
          v85.Open = not v85.Open

          if v85.Open then
            local MathClamp_2 = math.clamp(#v85.Values * 29 + 10, 36, 168)

            f6_24.Visible = true
            f6_24.Size = UDim2.new(1, 0, 0, 0)

            f11(f6_24, { Size = UDim2.new(1, 0, 0, MathClamp_2) })
            f11(f6_23, { Rotation = 270 })
            f11(f8_4, { Color = v29.Accent })
          else
            f25()
          end
        end)

        v85:SetValues(P61.Values or {})
        v85:SetValue(P61.Default, true)

        if P61.Default ~= nil and P61.Callback then
          task.spawn(P61.Callback, P61.Default)
        end

        v30.Options[p60] = v85
        return v85
      end

      function v54:AddInput(p67, p68)
        local P68 = p68
        P68 = P68 or {}

        local f19_5 = f19(0, true)
        f10(f19_5, 6)
        f15(f19_5, P68.Tooltip)
        f20(f19_5, P68.Text or p67)
        local UDim2_4 = UDim2.new(1, 0, 0, 30)

        local f6_27 = f6("TextBox", {
          Size = UDim2_4,
          BackgroundColor3 = v29.Sunken,
          BorderSizePixel = 0,
          Font = Enum.Font.GothamMedium,
          TextSize = 12,
          TextColor3 = v29.Text,
          PlaceholderColor3 = v29.Faint,
          PlaceholderText = P68.Placeholder or "",
          TextXAlignment = Enum.TextXAlignment.Left,
          ClearTextOnFocus = false,
          Text = P68.Default or "",
          LayoutOrder = 1,
        }, f19_5)

        f7(f6_27, UDim_2)
        local f8_6 = f8(f6_27, v29.Line, 1)
        f9(f6_27, 14, 14, 0, 0)

        local v94 = {
          Value = P68.Default or "",
          Type = "Input",
          Index = p67,
          Callbacks = {},
        }

        local function f26(p69)
          v94.Value = p69

          if P68.Callback then
            task.spawn(P68.Callback, p69)
          end

          for index17, value19 in ipairs(v94.Callbacks) do
            task.spawn(value19, p69)
          end
        end

        function v94:SetValue(p70, p71)
          local ToString_2 = tostring(p70 or "")
          f6_27.Text = ToString_2

          if p71 then
            v94.Value = ToString_2
            return
          end

          f26(ToString_2)
        end

        function v94.OnChanged(p72, p73)
          table.insert(v94.Callbacks, p73)
          task.spawn(p73, v94.Value)
          return v94
        end

        f12(f6_27.Focused, function() f11(f8_6, { Color = v29.Accent }) end)

        f12(f6_27.FocusLost, function()
          f11(f8_6, { Color = v29.Line })
          local Text = f6_27.Text

          if P68.Numeric and Text ~= "" and not tonumber(Text) then
            f6_27.Text = v94.Value
            return
          end

          f26(Text)
        end)

        if not P68.Finished then
          f12(f6_27:GetPropertyChangedSignal("Text"), function()
            if f6_27:IsFocused() then
              local Text_2 = f6_27.Text

              if P68.Numeric and Text_2 ~= "" and not tonumber(Text_2) then
                return
              end

              f26(Text_2)
              return
            end
          end)
        end

        v30.Options[p67] = v94
        return v94
      end

      function v54:AddTextBox(p74, p75)
        local P75 = p75
        P75 = P75 or {}

        local f19_6 = f19(0, true)
        f10(f19_6, 6)
        f15(f19_6, P75.Tooltip)
        f20(f19_6, P75.Text or p74)

        local f6_28 = f6("Frame", {
          Size = UDim2.new(1, 0, 0, P75.Height or 140),
          BackgroundColor3 = v29.Sunken,
          BorderSizePixel = 0,
          LayoutOrder = 1,
        }, f19_6)

        f7(f6_28, UDim.new(0, 10))
        local f8_7 = f8(f6_28, v29.Line, 1)

        local f6_29 = f6("TextBox", {
          Size = UDim2.fromScale(1, 1),
          BackgroundTransparency = 1,
          Font = Enum.Font.Code,
          TextSize = 12,
          TextColor3 = v29.Text,
          PlaceholderColor3 = v29.Faint,
          PlaceholderText = P75.Placeholder or "",
          TextXAlignment = Enum.TextXAlignment.Left,
          TextYAlignment = Enum.TextYAlignment.Top,
          ClearTextOnFocus = false,
          MultiLine = true,
          TextWrapped = false,
          Text = P75.Default or "",
        }, f6_28)

        f9(f6_29, 12, 12, 10, 10)

        local v101 = {
          Value = P75.Default or "",
          Type = "TextBox",
          Index = p74,
          Callbacks = {},
        }

        local function f27(p76)
          v101.Value = p76

          if P75.Callback then
            task.spawn(P75.Callback, p76)
          end

          for index18, value20 in ipairs(v101.Callbacks) do
            task.spawn(value20, p76)
          end
        end

        function v101:SetValue(p77, p78)
          local ToString_3 = tostring(p77 or "")
          f6_29.Text = ToString_3

          if p78 then
            v101.Value = ToString_3
            return
          end

          f27(ToString_3)
        end

        function v101:GetValue()
          return f6_29.Text
        end

        function v101.OnChanged(p79, p80)
          table.insert(v101.Callbacks, p80)
          return v101
        end

        f12(f6_29.Focused, function() f11(f8_7, { Color = v29.Accent }) end)
        f12(f6_29.FocusLost, function() f11(f8_7, { Color = v29.Line }) end)

        if not P75.Finished then
          f12(f6_29:GetPropertyChangedSignal("Text"), function()
            if f6_29:IsFocused() then
              f27(f6_29.Text)
            end
          end)
        end

        v30.Options[p74] = v101
        return v101
      end

      function v54:AddButton(p81, p82)
        local text5, func

        if type(p81) == "table" then
          text5 = p81.Text
          func = p81.Func or p81.Callback
        else
          func = p82
          text5 = p81
        end

        local f19_7 = f19(32)

        local f6_30 = f6("TextButton", {
          Size = UDim2.fromScale(1, 1),
          BackgroundColor3 = v29.Raised,
          BorderSizePixel = 0,
          Font = Enum.Font.GothamBold,
          TextSize = 12,
          TextColor3 = v29.Text,
          Text = text5 or "Button",
          AutoButtonColor = false,
        }, f19_7)

        f7(f6_30, UDim_2)
        local f8_8 = f8(f6_30, v29.Line, 1)

        f12(f6_30.MouseEnter, function()
          f11(f6_30, { BackgroundColor3 = v29.AccentSoft })
          f11(f8_8, { Color = v29.Accent })
        end)

        f12(f6_30.MouseLeave, function()
          f11(f6_30, { BackgroundColor3 = v29.Raised })
          f11(f8_8, { Color = v29.Line })
        end)

        f12(f6_30.MouseButton1Click, function()
          f11(f6_30, { BackgroundColor3 = v29.Accent }, 0.08)
          task.delay(0.1, function() f11(f6_30, { BackgroundColor3 = v29.Raised }) end)

          if func then
            task.spawn(func)
          end
        end)

        local v106 = { Instance = f6_30 }

        function v106:SetText(text6)
          f6_30.Text = text6
        end

        return v106
      end

      function v54:AddDivider()
        local f19_8 = f19(9)

        local f6_31 = f6("Frame", {
          AnchorPoint = Vector2.new(0, 0.5),
          Position = UDim2.new(0, 0, 0.5, 0),
          Size = UDim2.new(1, 0, 0, 1),
          BackgroundColor3 = v29.LineSoft,
          BorderSizePixel = 0,
        }, f19_8)

        f7(f6_31, UDim_2)
        return { Instance = f6_31 }
      end

      function v54:AddLabel(p83, p84)
        local f19_9 = f19(0, true)

        local f6_32 = f6("TextLabel", {
          Size = UDim2.new(1, 0, 0, 0),
          AutomaticSize = Enum.AutomaticSize.Y,
          BackgroundTransparency = 1,
          Font = Enum.Font.GothamMedium,
          TextSize = 12,
          TextColor3 = v29.SubText,
          TextXAlignment = Enum.TextXAlignment.Left,
          TextWrapped = p84 and true or false,
          Text = p83 or "",
        }, f19_9)

        local v111 = { Instance = f6_32 }

        function v111:SetText(text7)
          f6_32.Text = text7
          return v111
        end

        function v111:AddKeyPicker(p85, p86)
          local P86 = p86
          P86 = P86 or {}

          f6_32.Size = UDim2.new(1, -66, 0, 0)

          local f6_33 = f6("TextButton", {
            AnchorPoint = Vector2.new(1, 0),
            Position = UDim2.new(1, 0, 0, 0),
            Size = UDim2.fromOffset(62, 22),
            BackgroundColor3 = v29.Sunken,
            BorderSizePixel = 0,
            Font = Enum.Font.GothamBold,
            TextSize = 11,
            TextColor3 = v29.Accent,
            TextTruncate = Enum.TextTruncate.AtEnd,
            Text = "",
            AutoButtonColor = false,
          }, f19_9)

          f7(f6_33, UDim_2)
          local f8_9 = f8(f6_33, v29.Line, 1)

          local v115 = {
            Value = P86.Default or "",
            Mode = P86.Mode or "Toggle",
            Type = "KeyPicker",
            Index = p85,
            Label = P86.Text or p83 or p85,
            NoUI = P86.NoUI and true or false,
            Active = false,
            Callbacks = {},
            Listening = false,
          }

          local function f28()
            f6_33.Text = v115.Listening and "..." or v115.Value ~= "" and v115.Value or "None"
            f11(f8_9, { Color = v115.Listening and v29.Accent or v29.Line })
          end

          function v115:SetValue(p87, p88)
            local P87 = p87

            if type(P87) == "table" then
              v115.Mode = P87[2] or v115.Mode
              P87 = P87[1]
            end

            v115.Value = tostring(P87 or "")
            f28()
            f16()

            if not p88 then
              for index19, value21 in ipairs(v115.Callbacks) do
                task.spawn(value21, v115.Value)
              end
            end
          end

          function v115.OnChanged(p89, p90)
            table.insert(v115.Callbacks, p90)
            return v115
          end

          function v115:GetState()
            return v115.Active
          end

          f12(f6_33.MouseButton1Click, function()
            v115.Listening = true
            f28()
          end)

          f12(userInputService.InputBegan, function(p91, p92)
            if v115.Listening then
              if p91.UserInputType == Enum.UserInputType.Keyboard then
                v115.Listening = false

                if p91.KeyCode == Enum.KeyCode.Backspace then
                  v115:SetValue("")
                else
                  v115:SetValue(p91.KeyCode.Name)
                end
              end

              return
            end

            if p92 or v115.Value == "" then
              return
            elseif userInputService:GetFocusedTextBox() then
              return
            elseif p91.UserInputType ~= Enum.UserInputType.Keyboard then
              return
            else
              if p91.KeyCode.Name ~= v115.Value then
                return
              end

              if v115.Mode == "Toggle" then
                v115.Active = not v115.Active
              else
                v115.Active = true
              end

              if P86.Callback then
                task.spawn(P86.Callback, v115.Active)
              end

              return
            end
          end)

          f12(userInputService.InputEnded, function(p93)
            if v115.Mode == "Hold" and p93.UserInputType == Enum.UserInputType.Keyboard
              and p93.KeyCode.Name == v115.Value then
              v115.Active = false

              if P86.Callback then
                task.spawn(P86.Callback, false)
              end
            end
          end)

          table.insert(v33, v115)
          v115:SetValue(P86.Default or "", true)
          v30.Options[p85] = v115
          return v115
        end

        return v111
      end

      return v54
    end

    local v117, v118, v119, v120, v121

    function v30:CreateWindow(p94)
      local v122 = p94 or {}

      v117 = f6("Frame", {
        Name = f13(),
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromOffset(780, 550),
        BackgroundColor3 = v29.Shell,
        BorderSizePixel = 0,
        ClipsDescendants = true,
        Visible = false,
      }, f6_3)

      f7(v117, UDim.new(0, v30.CornerRadius), true)
      f8(v117, v29.Line, 1)
      local f6_34 = f6("UIScale", { Scale = 1 }, v117)

      local function f29()
        if not v118 then
          return
        else
          local AbsoluteSize = f6_3.AbsoluteSize

          if AbsoluteSize.X < 1 or AbsoluteSize.Y < 1 then
            local CurrentCamera = workspace.CurrentCamera

            AbsoluteSize = CurrentCamera and CurrentCamera.ViewportSize
              or Vector2.new(1280, 720)
          end

          local MathMin = math.min(1, (AbsoluteSize.X - 24) / 780, (AbsoluteSize.Y - 24) / 550)
          v118.Scale = math.clamp(math.min(v30.DPI or 1, MathMin), 0.35, 2)
          return
        end
      end

      v118 = f6_34
      v30.Refit = f29
      f12(f6_3:GetPropertyChangedSignal("AbsoluteSize"), f29)
      task.defer(f29)

      f6(
        "UIGradient", { Rotation = 90, Color = ColorSequence.new(v29.ShellTop, v29.Shell) },
        v117
      )

      local f6_35 = f6(
        "Frame", { Size = UDim2.new(1, 0, 0, 56), BackgroundTransparency = 1 }, v117
      )

      f17(f6_35, v117)

      local f6_36 = f6("ImageLabel", {
        Position = UDim2.fromOffset(18, 15),
        Size = UDim2.fromOffset(26, 26),
        BackgroundColor3 = v29.Raised,
        BorderSizePixel = 0,
        ScaleType = Enum.ScaleType.Fit,
        Image = v122.Icon and "rbxassetid://" .. tostring(v122.Icon) or "",
      }, f6_35)

      f7(f6_36, UDim_2)
      f8(f6_36, v29.Line, 1)

      f6("TextLabel", {
        Position = UDim2.fromOffset(54, 14),
        Size = UDim2.fromOffset(240, 16),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        TextSize = 15,
        TextColor3 = v29.Text,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = v122.Title or "Menu",
      }, f6_35)

      f6("TextLabel", {
        Position = UDim2.fromOffset(54, 31),
        Size = UDim2.fromOffset(300, 14),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamMedium,
        TextSize = 11,
        TextColor3 = v29.Faint,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = v122.Footer or "",
      }, f6_35)

      local f6_37 = f6("TextButton", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -18, 0.5, 0),
        Size = UDim2.fromOffset(26, 26),
        BackgroundColor3 = v29.Raised,
        BorderSizePixel = 0,
        Font = Enum.Font.GothamBold,
        TextSize = 12,
        TextColor3 = v29.SubText,
        Text = "X",
        AutoButtonColor = false,
      }, f6_35)

      f7(f6_37, UDim_2)
      local f8_10 = f8(f6_37, v29.Line, 1)

      f12(f6_37.MouseEnter, function()
        f11(f6_37, { BackgroundColor3 = v29.AccentSoft })
        f11(f8_10, { Color = v29.Accent })
      end)

      f12(f6_37.MouseLeave, function()
        f11(f6_37, { BackgroundColor3 = v29.Raised })
        f11(f8_10, { Color = v29.Line })
      end)

      f12(f6_37.MouseButton1Click, function() v117.Visible = false end)

      f6("Frame", {
        Position = UDim2.fromOffset(0, 56),
        Size = UDim2.new(1, 0, 0, 1),
        BackgroundColor3 = v29.LineSoft,
        BorderSizePixel = 0,
      }, v117)

      v119 = f6("ScrollingFrame", {
        Position = UDim2.fromOffset(0, 57),
        Size = UDim2.new(0, 170, 1, -57),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        CanvasSize = UDim2.new(),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollBarThickness = 0,
        ScrollingDirection = Enum.ScrollingDirection.Y,
      }, v117)

      f10(v119, 6)
      f9(v119, 14, 14, 14, 14)

      local f6_38 = f6("Frame", {
        Position = UDim2.fromOffset(170, 57),
        Size = UDim2.new(0, 1, 1, -57),
        BackgroundColor3 = v29.LineSoft,
        BorderSizePixel = 0,
      }, v117)

      v120 = f6("Frame", {
        Position = UDim2.fromOffset(171, 57),
        Size = UDim2.new(1, -171, 1, -57),
        BackgroundTransparency = 1,
      }, v117)

      local v130 = false
      local Size = v117.Size

      local f6_39 = f6("TextButton", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -50, 0.5, 0),
        Size = UDim2.fromOffset(26, 26),
        BackgroundColor3 = v29.Raised,
        BorderSizePixel = 0,
        Font = Enum.Font.GothamBold,
        TextSize = 14,
        TextColor3 = v29.SubText,
        Text = "-",
        AutoButtonColor = false,
      }, f6_35)

      f7(f6_39, UDim_2)
      local f8_11 = f8(f6_39, v29.Line, 1)

      f12(f6_39.MouseEnter, function()
        f11(f6_39, { BackgroundColor3 = v29.AccentSoft })
        f11(f8_11, { Color = v29.Accent })
      end)

      f12(f6_39.MouseLeave, function()
        f11(f6_39, { BackgroundColor3 = v29.Raised })
        f11(f8_11, { Color = v29.Line })
      end)

      local function f30(p95)
        v130 = p95 and true or false
        f6_39.Text = v130 and "+" or "-"

        if not v130 then
          v119.Visible = true
          f6_38.Visible = true
          v120.Visible = true
        end

        f11(
          v117, { Size = v130 and UDim2.new(Size.X.Scale, Size.X.Offset, 0, 56) or Size }, 0.22
        )

        if v130 then
          task.delay(0.24, function()
            if v130 then
              v119.Visible = false
              f6_38.Visible = false
              v120.Visible = false
            end
          end)
        end
      end

      f12(f6_39.MouseButton1Click, function() f30(not v130) end)

      local v133 = { Instance = v117 }

      function v133.SetMinimized(p96, p97)
        f30(p97)
      end

      function v133.IsMinimized(p98)
        return v130
      end

      function v133:AddTab(text8)
        local f6_40 = f6("TextButton", {
          Size = UDim2.new(1, 0, 0, 34),
          BackgroundColor3 = v29.Panel,
          BackgroundTransparency = 1,
          BorderSizePixel = 0,
          Text = "",
          AutoButtonColor = false,
          LayoutOrder = #v34 + 1,
        }, v119)

        f7(f6_40, UDim_2)
        local f8_12 = f8(f6_40, v29.Line, 1, 1)

        local f6_41 = f6("Frame", {
          AnchorPoint = Vector2.new(0, 0.5),
          Position = UDim2.new(0, 11, 0.5, 0),
          Size = UDim2.fromOffset(3, 0),
          BackgroundColor3 = v29.Accent,
          BorderSizePixel = 0,
        }, f6_40)

        f7(f6_41, UDim_2)

        local f6_42 = f6("TextLabel", {
          Position = UDim2.fromOffset(24, 0),
          Size = UDim2.new(1, -34, 1, 0),
          BackgroundTransparency = 1,
          Font = Enum.Font.GothamMedium,
          TextSize = 12,
          TextColor3 = v29.SubText,
          TextXAlignment = Enum.TextXAlignment.Left,
          TextTruncate = Enum.TextTruncate.AtEnd,
          Text = text8,
        }, f6_40)

        local f6_43 = f6("Frame", {
          Size = UDim2.fromScale(1, 1),
          BackgroundTransparency = 1,
          Visible = false,
        }, v120)
        local pageMotionScale = f6("UIScale", { Scale = 1 }, f6_43)

        f9(f6_43, 14, 14, 14, 0)

        local f6_44 = f6("ScrollingFrame", {
          Size = UDim2.new(0.5, -7, 1, 0),
          BackgroundTransparency = 1,
          BorderSizePixel = 0,
          CanvasSize = UDim2.new(),
          AutomaticCanvasSize = Enum.AutomaticSize.Y,
          ScrollBarThickness = 2,
          ScrollBarImageColor3 = v29.Line,
          ScrollingDirection = Enum.ScrollingDirection.Y,
        }, f6_43)

        f10(f6_44, 12)
        f9(f6_44, 2, 8, 2, 16)

        local f6_45 = f6("ScrollingFrame", {
          Position = UDim2.new(0.5, 7, 0, 0),
          Size = UDim2.new(0.5, -7, 1, 0),
          BackgroundTransparency = 1,
          BorderSizePixel = 0,
          CanvasSize = UDim2.new(),
          AutomaticCanvasSize = Enum.AutomaticSize.Y,
          ScrollBarThickness = 2,
          ScrollBarImageColor3 = v29.Line,
          ScrollingDirection = Enum.ScrollingDirection.Y,
        }, f6_43)

        f10(f6_45, 12)
        f9(f6_45, 2, 8, 2, 16)

        local v141 = {
          Page = f6_43,
          Left = f6_44,
          Right = f6_45,
          Button = f6_40,
        }

        function v141:Select()
          for index20, value22 in ipairs(v34) do
            value22.Page.Visible = false

            f11(value22.Button, { BackgroundTransparency = 1 })
            f11(value22.Edge, { Transparency = 1 })
            f11(value22.Label, { TextColor3 = v29.SubText })
            f11(value22.Mark, { Size = UDim2.fromOffset(3, 0) })
          end

          f6_43.Visible = true
          pageMotionScale.Scale = 0.985
          f11(pageMotionScale, { Scale = 1 }, 0.13)

          f11(f6_40, { BackgroundTransparency = 0.86, BackgroundColor3 = v29.Accent })
          f11(f8_12, { Transparency = 0.45, Color = v29.Accent })
          f11(f6_42, { TextColor3 = v29.Text })
          f11(f6_41, { Size = UDim2.fromOffset(3, 16) })

          v121 = v141
        end

        local function f31(p99, p100)
          local f6_46 = f6("Frame", {
            Size = UDim2.new(1, 0, 0, 0),
            AutomaticSize = Enum.AutomaticSize.Y,
            BackgroundColor3 = v29.Panel,
            BorderSizePixel = 0,
            LayoutOrder = #p99:GetChildren(),
          }, p99)

          f7(f6_46, UDim.new(0, v30.CornerRadius), true)
          f8(f6_46, v29.LineSoft, 1)
          f9(f6_46, 14, 14, 12, 14)

          local f6_47 = f6("Frame", {
            Size = UDim2.new(1, 0, 0, 20),
            BackgroundTransparency = 1,
            LayoutOrder = 0,
          }, f6_46)

          f7(f6("Frame", {
            AnchorPoint = Vector2.new(0, 0.5),
            Position = UDim2.new(0, 0, 0.5, 0),
            Size = UDim2.fromOffset(3, 13),
            BackgroundColor3 = v29.Accent,
            BorderSizePixel = 0,
          }, f6_47), UDim_2)

          f6("TextLabel", {
            Position = UDim2.fromOffset(12, 0),
            Size = UDim2.new(1, -12, 1, 0),
            BackgroundTransparency = 1,
            Font = Enum.Font.GothamBold,
            TextSize = 12,
            TextColor3 = v29.Text,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
            Text = p100 or "",
          }, f6_47)

          local f6_48 = f6("Frame", {
            Size = UDim2.new(1, 0, 0, 0),
            AutomaticSize = Enum.AutomaticSize.Y,
            BackgroundTransparency = 1,
            LayoutOrder = 1,
          }, f6_46)

          f10(f6_48, 9)
          f9(f6_48, 0, 0, 8, 0)
          f10(f6_46, 0)
          return f18(f6_48)
        end

        function v141:AddLeftGroupbox(p101)
          return f31(f6_44, p101)
        end

        function v141:AddRightGroupbox(p102)
          return f31(f6_45, p102)
        end

        f12(f6_40.MouseButton1Click, function() v141:Select() end)

        f12(f6_40.MouseEnter, function()
          if v121 ~= v141 then
            f11(f6_40, { BackgroundTransparency = 0.92, BackgroundColor3 = v29.Text })
          end
        end)

        f12(f6_40.MouseLeave, function()
          if v121 ~= v141 then
            f11(f6_40, { BackgroundTransparency = 1 })
          end
        end)

        table.insert(v34, {
          Page = f6_43,
          Button = f6_40,
          Edge = f8_12,
          Label = f6_42,
          Mark = f6_41,
        })

        if #v34 == 1 then
          v141:Select()
        end

        return v141
      end

      function v133:SetCornerRadius(p103)
        v30.CornerRadius = p103

        for index21, value23 in ipairs(v32) do
          value23.CornerRadius = UDim.new(0, p103)
        end
      end

      function v133.Toggle(p104)
        v117.Visible = not v117.Visible
      end

      v30.Window = v133
      v30:SetNotifySide(v122.NotifySide or "Right")

      v117.Visible = true
      v117.Size = UDim2.fromOffset(780, 490)

      f11(v117, { Size = UDim2.fromOffset(780, 550) }, 0.28)
      return v133
    end

    f12(userInputService.InputBegan, function(p105, p106)
      if p106 or v30.Unloaded or not v117 then
        return
      elseif p105.UserInputType ~= Enum.UserInputType.Keyboard then
        return
      elseif userInputService:GetFocusedTextBox() then
        return
      else
        local DefaultToggleKey = v30.ToggleKeybind and v30.ToggleKeybind.Value or v30.DefaultToggleKey

        if DefaultToggleKey ~= "" and p105.KeyCode.Name == DefaultToggleKey then
          -- The old window is retained for legacy callbacks, but must never be shown.
          v117.Visible = false
          -- The dedicated RightShift handler below controls the Gen2 window.
        end

        return
      end
    end)

    function v30:SetDPIScale(p107)
      v30.DPI = math.clamp((tonumber(p107) or 100) / 100, 0.5, 2)

      if v30.Refit then
        v30.Refit()
      elseif v118 then
        v118.Scale = v30.DPI
      end
    end

    function v30:Unload()
      v30.Unloaded = true

      for index22, value25 in ipairs(v31) do
      end

      v31 = {}
      f6_3:Destroy()
    end

    local function f32()
      local RawValue_2 = rawget(_G, "writefile") or writefile
      local RawValue_3 = rawget(_G, "readfile") or readfile
      local RawValue_4 = rawget(_G, "listfiles") or listfiles
      local RawValue_5 = rawget(_G, "isfile") or isfile
      local RawValue_6 = rawget(_G, "isfolder") or isfolder
      local RawValue_7 = rawget(_G, "makefolder") or makefolder
      local RawValue_8 = rawget(_G, "delfile") or delfile

      if type(RawValue_2) ~= "function" or type(RawValue_3) ~= "function" or type(RawValue_4) ~= "function" then
        return nil
      end

      return {
        write = RawValue_2,
        read = RawValue_3,
        list = RawValue_4,
        exists = RawValue_5,
        folder = RawValue_6,
        mkdir = RawValue_7,
        remove = RawValue_8,
      }
    end

    function v30:SetConfigFolder(p108)
      v35 = p108
    end

    local function f33(p109)
      if p109.folder and p109.mkdir then
        if not p109.folder(v35) then
          p109.mkdir(v35)
        end

        if not p109.folder(v35 .. "/configs") then
          p109.mkdir(v35 .. "/configs")
        end
      end
    end

    local function f34()
      local v152 = { toggles = {}, options = {} }

      for key3, value26 in pairs(v30.Toggles) do
        v152.toggles[key3] = value26.Value
      end

      for key4, value27 in pairs(v30.Options) do
        if value27.Type == "KeyPicker" then
          v152.options[key4] = { value27.Value, value27.Mode }
        else
          v152.options[key4] = value27.Value
        end
      end

      return v152
    end

    local function f35(p110)
      for key5, value28 in pairs(p110.toggles or {}) do
        local Toggles = v30.Toggles[key5]

        if Toggles then
          Toggles:SetValue(value28)
        end
      end

      for key6, value29 in pairs(p110.options or {}) do
        local Options = v30.Options[key6]

        if Options and Options.SetValue then
          Options:SetValue(value29)
        end
      end
    end

    function v30:SaveConfig(p111)
      local f32_2 = f32()

      if not f32_2 or not p111 or p111 == "" then
        return false
      else
        f33(f32_2)
        local v156, v157 = pcall(httpService.JSONEncode, httpService, f34())

        if not v156 then
          return false
        end

        return pcall(f32_2.write, v35 .. "/configs/" .. p111 .. ".json", v157)
      end
    end

    function v30:LoadConfig(p112)
      local f32_3 = f32()

      if not f32_3 or not p112 or p112 == "" then
        return false
      else
        local v159, v160 = pcall(f32_3.read, v35 .. "/configs/" .. p112 .. ".json")

        if not v159 or type(v160) ~= "string" then
          return false
        else
          local v161, v162 = pcall(httpService.JSONDecode, httpService, v160)

          if not v161 or type(v162) ~= "table" then
            return false
          end

          f35(v162)
          return true
        end
      end
    end

    function v30:ListConfigs()
      local v163 = {}
      local f32_4 = f32()

      if not f32_4 then
        return v163
      else
        f33(f32_4)
        local v165, v166 = pcall(f32_4.list, v35 .. "/configs")

        if not v165 or type(v166) ~= "table" then
          return v163
        end

        for index23, value30 in ipairs(v166) do
          local StringMatch = string.match(value30, "([^/\\]+)%.json$")

          if StringMatch then
            table.insert(v163, StringMatch)
          end
        end

        return v163
      end
    end

    function v30:LoadAutoloadConfig()
      local f32_5 = f32()

      if not f32_5 then
        return
      else
        local v169, v170 = pcall(f32_5.read, v35 .. "/autoload.txt")

        if v169 and type(v170) == "string" and v170 ~= "" then
          v30:LoadConfig(v170)
        end

        return
      end
    end

    function v30:BuildConfigSection(p113)
      local AddRightGroupbox = p113:AddRightGroupbox("Configuration")
      local f32_6 = f32()
      local addInput, addDropdown, addLabel

      if not f32_6 then
        AddRightGroupbox:AddLabel("This executor has no file API, configs are off", true)
        return AddRightGroupbox
      else
        addInput = AddRightGroupbox:AddInput("ConfigName", {
          Default = "",
          Text = "Config name",
          Placeholder = "default",
        })

        addDropdown = AddRightGroupbox:AddDropdown("ConfigList", {
          Values = v30:ListConfigs(),
          Default = nil,
          Text = "Saved configs",
        })

        AddRightGroupbox:AddButton({
          Text = "Create",
          Func = function()
            if v30:SaveConfig(addInput.Value) then
              addDropdown:SetValues(v30:ListConfigs())
              v30:Notify("Saved config " .. addInput.Value)
            end
          end,
        })

        AddRightGroupbox:AddButton({
          Text = "Load",
          Func = function()
            if addDropdown.Value and v30:LoadConfig(addDropdown.Value) then
              v30:Notify("Loaded config " .. addDropdown.Value)
            end
          end,
        })

        AddRightGroupbox:AddButton({
          Text = "Overwrite",
          Func = function()
            if addDropdown.Value and v30:SaveConfig(addDropdown.Value) then
              v30:Notify("Overwrote config " .. addDropdown.Value)
            end
          end,
        })

        AddRightGroupbox:AddButton({
          Text = "Delete",
          Func = function()
            if addDropdown.Value and f32_6.remove then
              pcall(f32_6.remove, v35 .. "/configs/" .. addDropdown.Value .. ".json")

              addDropdown:SetValues(v30:ListConfigs())
              addDropdown:SetValue(nil, true)

              v30:Notify("Deleted config")
            end
          end,
        })

        AddRightGroupbox:AddButton({
          Text = "Refresh list",
          Func = function() addDropdown:SetValues(v30:ListConfigs()) end,
        })

        addLabel = AddRightGroupbox:AddLabel("Autoload: none", true)

        AddRightGroupbox:AddButton({
          Text = "Set as autoload",
          Func = function()
            if addDropdown.Value then
              pcall(f32_6.write, v35 .. "/autoload.txt", addDropdown.Value)
              addLabel:SetText("Autoload: " .. addDropdown.Value)
            end
          end,
        })

        AddRightGroupbox:AddButton({
          Text = "Clear autoload",
          Func = function()
            pcall(f32_6.write, v35 .. "/autoload.txt", "")
            addLabel:SetText("Autoload: none")
          end,
        })

        local v172, v173 = pcall(f32_6.read, v35 .. "/autoload.txt")

        if v172 and type(v173) == "string" and v173 ~= "" then
          addLabel:SetText("Autoload: " .. v173)
        end

        return AddRightGroupbox
      end
    end

    return v30
  end

  v174 = f5()
end

do
  local LOCOPANI_SESSION = (type(getgenv) == "function" and getgenv() or _G).LOCOPANI_SESSION

  if type(LOCOPANI_SESSION) == "table" then
    LOCOPANI_SESSION.ui = v174
  end

  options = v174.Options
  toggles = v174.Toggles

  v174.ForceCheckbox = false
  v174.ShowToggleFrameInKeybinds = true

  localPlayer2 = players.LocalPlayer
  currentCamera2 = workspaceService.CurrentCamera
  v175 = require(replicatedFirst.Controllers.AnimationController)

  v176 = string.char(math.random(97, 122), math.random(97, 122), math.random(97, 122))
    .. tostring(math.random(100000, 999999))

  v177 = string.char(math.random(97, 122), math.random(97, 122), math.random(97, 122))
    .. tostring(math.random(100000, 999999))

  local LOCOPANI_SESSION_2 = (type(getgenv) == "function" and getgenv() or _G).LOCOPANI_SESSION

  if type(LOCOPANI_SESSION_2) == "table" and type(LOCOPANI_SESSION_2.tags) == "table" then
    table.insert(LOCOPANI_SESSION_2.tags, v176)
    table.insert(LOCOPANI_SESSION_2.tags, v177)
  end
end

local function f36(p114)
  local LOCOPANI_SESSION_3 = (type(getgenv) == "function" and getgenv() or _G).LOCOPANI_SESSION

  if type(LOCOPANI_SESSION_3) == "table" and type(LOCOPANI_SESSION_3.links) == "table" then
    table.insert(LOCOPANI_SESSION_3.links, p114)
  end

  return p114
end

v178 = false
v179 = 5
local Color3_2 = Color3.fromRGB(0, 0, 255)

local function f37()
  for index24, value31 in ipairs(workspaceService:GetChildren()) do
    if value31:IsA("Model") and value31.Name:match("^CLIENT_BALL_%d+$") then
      local LOCOPANIBALL = value31:FindFirstChild("LOCOPANI.BALL")

      if LOCOPANIBALL then
        LOCOPANIBALL:Destroy()
      end
    end
  end
end

local function f38(p115)
  for index25, value32 in ipairs(p115:GetDescendants()) do
    if value32:IsA("BasePart") then
      return value32
    end
  end

  return nil
end

local Color = Color3_2
local transparency = 0.3

local function f39(p116)
  if not v178 then
    return
  end

  for index26, value33 in ipairs(workspaceService:GetChildren()) do
    if value33:IsA("Model") and value33.Name:match("^CLIENT_BALL_%d+$") then
      local LOCOPANIBALL2 = value33:FindFirstChild("LOCOPANI.BALL")

      if not LOCOPANIBALL2 then
        local f38_2 = f38(value33)

        if f38_2 then
          local Part = Instance.new("Part")
          Part.Name = "LOCOPANI.BALL"
          Part.Shape = Enum.PartType.Ball
          Part.Size = Vector3.new(2, 2, 2) * p116
          Part.CFrame = f38_2.CFrame
          Part.Anchored = true
          Part.CanCollide = false
          Part.Transparency = transparency
          Part.Material = Enum.Material.ForceField
          Part.Color = Color
          Part.Parent = value33
        end
      else
        LOCOPANIBALL2.Size = Vector3.new(2, 2, 2) * p116
        LOCOPANIBALL2.Color = Color
        LOCOPANIBALL2.Transparency = transparency
      end
    end
  end
end

do
  local function f40()
    if not v178 then
      return
    end

    for index27, value34 in ipairs(workspaceService:GetChildren()) do
      if value34:IsA("Model") and value34.Name:match("^CLIENT_BALL_%d+$") then
        local LOCOPANIBALL4 = value34:FindFirstChild("LOCOPANI.BALL")
        local f38_3 = f38(value34)

        if LOCOPANIBALL4 and f38_3 then
          LOCOPANIBALL4.CFrame = f38_3.CFrame
        end
      end
    end
  end

  workspaceService.ChildAdded:Connect(function(child)
    if child:IsA("Model") and child.Name:match("^CLIENT_BALL_%d+$") then
      task.wait(0.1)

      if v178 then
        f39(v179)
      end
    end
  end)

  runService.RenderStepped:Connect(function() f40() end)

  function enableHitbox()
    v178 = true
    f39(v179)
  end

  function disableHitbox()
    v178 = false
    f37()
  end

  function isHitboxEnabled()
    return v178
  end

  function setHitboxScale(p117)
    v179 = p117 or 5

    if v178 then
      f39(v179)
    end
  end

  function getHitboxScale()
    return v179
  end

  function setHitboxColor(p118)
    Color = p118 or Color3.fromRGB(0, 0, 255)

    if v178 then
      f39(v179)
    end
  end

  function setHitboxTransparency(p119)
    transparency = p119 or 0.3

    if v178 then
      f39(v179)
    end
  end

  _G.enableHitbox = enableHitbox
  _G.disableHitbox = disableHitbox
end

_G.isHitboxEnabled = isHitboxEnabled
_G.setHitboxScale = setHitboxScale
_G.getHitboxScale = getHitboxScale
_G.setHitboxColor = setHitboxColor
_G.setHitboxTransparency = setHitboxTransparency

v182 = false
v183 = false
v184 = false
v185 = false
v186 = false
v187 = false
v188 = false
v189 = false
v190 = false
v191 = false
v192 = false
v193 = false
v194 = {}
v195 = {}
v196 = false
v197 = false
v198 = false
v199 = false
v200 = 16
v201 = false
v202 = false
scoreEffect = "SupernovaScoreEffect"
v203 = false
v204 = false
v205 = {}
v206 = false
v207 = "UltimateChampionPlayerCard"
v208 = false
v209 = false
v210 = {}
jersey = "DragonTuxedoJersey"
v211 = {}
ball = "ClassicBall"
v212 = {}
v213 = false
v214 = false
v215 = {}
v216 = {}
v217 = "Normal"
v218 = "Normal"
v219 = false
v220 = false
v221 = false

do
  v222 = false
  v223 = false
  v224 = false
  v225 = false
  v226 = {}
  v227 = {}
  v228 = {}
  v229 = {}

  local v230 = {
    Color3.fromRGB(255, 0, 0), Color3.fromRGB(0, 255, 0), Color3.fromRGB(0, 0, 255),
    Color3.fromRGB(255, 165, 0), Color3.fromRGB(128, 0, 128), Color3.fromRGB(255, 255, 0),
    Color3.fromRGB(139, 0, 0), Color3.fromRGB(0, 100, 0),
  }

  v231 = {}
  ballService = replicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.BallService
  serve = replicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.GameService.RF.Serve
end

effects = replicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.BallService.RE.Effects
doMove = replicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.BallService.RE.DoMove
stopAllEmotes = replicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.AnimationService.RE.StopAllEmotes
effect = replicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.GameService.RE.Effect

-- Custom chat-title changer: affects the title attribute consumed by chat UI.
do
  _G.LOCOPANI_CustomChatTitle = _G.LOCOPANI_CustomChatTitle or {
    Enabled = false,
    Text = "CUSTOM TITLE",
    Color = Color3.fromRGB(96, 205, 255),
  }

  function _G.LOCOPANI_ApplyUserTitle()
    if not localPlayer2 then return end
    local customTitle = _G.LOCOPANI_CustomChatTitle
    if customTitle and customTitle.Enabled then
      local titleText = tostring(customTitle.Text or "")
      if titleText == "" then
        localPlayer2:SetAttribute("User_Title", "")
        return
      end
      local color = customTitle.Color or Color3.fromRGB(96, 205, 255)
      local r = math.clamp(math.floor(color.R * 255 + 0.5), 0, 255)
      local g = math.clamp(math.floor(color.G * 255 + 0.5), 0, 255)
      local b = math.clamp(math.floor(color.B * 255 + 0.5), 0, 255)
      local hex = string.format("#%02X%02X%02X", r, g, b)
      -- Escape rich-text characters so the user can type a literal title safely.
      titleText = titleText:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
      localPlayer2:SetAttribute("User_Title", '<font color="' .. hex .. '"><b>' .. titleText .. '</b></font>')
      return
    end
    if _G.CustomProtect and _G.CustomProtect.Enabled then
      localPlayer2:SetAttribute("User_Title", tostring(_G.CustomProtect.Title or ""))
    elseif _G.Protect and _G.Protect.IsEnabled and _G.Protect.IsEnabled() then
      localPlayer2:SetAttribute("User_Title", tostring(_G.Protect.Title or "<font color='#FF0000'><b>Pro</b></font>"))
    else
      localPlayer2:SetAttribute("User_Title", "")
    end
  end
end

-- LOCOPANI: troca de nomes idempotente (evita "PROTECTCTCT..." quando o texto novo
-- contém o texto antigo). Troca primeiro os trechos mais longos por um marcador e
-- só no fim coloca o nome final, então o resultado nunca é reprocessado.
function LOCOPANI_SafeReplace(text, candidates, replacement)
  if type(text) ~= "string" or text == "" then return text end
  local list = {}
  for _, c in ipairs(candidates) do
    if type(c) == "string" and c ~= "" then table.insert(list, c) end
  end
  table.sort(list, function(a, b) return #a > #b end)
  local PH = "\1LOCOPANI\2"
  local out, changed = text, false
  for _, c in ipairs(list) do
    local parts, pos = {}, 1
    while true do
      local a, b = string.find(out, c, pos, true)
      if not a then break end
      table.insert(parts, string.sub(out, pos, a - 1))
      table.insert(parts, PH)
      pos = b + 1
      changed = true
    end
    if #parts > 0 then
      table.insert(parts, string.sub(out, pos))
      out = table.concat(parts)
    end
  end
  if not changed then return text end
  local pieces, pos = {}, 1
  while true do
    local a, b = string.find(out, PH, pos, true)
    if not a then break end
    table.insert(pieces, string.sub(out, pos, a - 1))
    table.insert(pieces, replacement)
    pos = b + 1
  end
  table.insert(pieces, string.sub(out, pos))
  return table.concat(pieces)
end

local v232 = {
  NameTag = "LOCOPANI PROTECTION",
  Title = "<font color='#FF0000'><b>Pro</b></font>",
  NotifConn = nil,
  NotifConn2 = nil,
  CardLoopConn = nil,
  CharWatcher = nil,
  Enabled = true,
}

local function f41()
  if not v232.Enabled then
    return
  end

  if localPlayer2 and localPlayer2.Character then
    local Nametag = localPlayer2.Character:FindFirstChild("Nametag")

    if Nametag then
      local PlayerName = Nametag:FindFirstChild("PlayerName")

      if PlayerName and PlayerName:IsA("TextLabel") then
        -- Custom Protect tem prioridade também após respawn/reset.
        if _G.CustomProtect and _G.CustomProtect.Enabled then
          PlayerName.Text = tostring(_G.CustomProtect.Name or "CUSTOM NAME")
        else
          PlayerName.Text = v232.NameTag
        end
      end
    end
  end
end

local function f42()
  if not v232.Enabled then
    return
  end

  if localPlayer2 then
    _G.LOCOPANI_ApplyUserTitle()
  end
end

local function f43()
  if v232.CardLoopConn then
    v232.CardLoopConn:Disconnect()
    v232.CardLoopConn = nil
  end
end

local f44

local function f45()
  if v232.NotifConn then
    v232.NotifConn:Disconnect()
    v232.NotifConn = nil
  end

  if v232.NotifConn2 then
    v232.NotifConn2:Disconnect()
    v232.NotifConn2 = nil
  end

  if not v232.Enabled then
    return
  elseif not localPlayer2 then
    return
  else
    local Interface = localPlayer2.PlayerGui:FindFirstChild("Interface")

    if Interface then
      Interface = Interface:FindFirstChild("Persistent")

      if Interface then
        Interface = Interface:FindFirstChild("Notifications")
      end
    end

    if not Interface then
      return
    end

    for index28, value35 in ipairs(Interface:GetChildren()) do
      f44(value35)
    end

    v232.NotifConn = Interface.ChildAdded:Connect(function(child2) f44(child2) end)

    v232.NotifConn2 = Interface.DescendantAdded:Connect(function(descendant)
      if descendant:IsA("TextLabel") then
        if not v232.Enabled or not localPlayer2 then
          return
        end

        -- Nunca deixe o protetor antigo substituir o nome do Custom Protect.
        if _G.CustomProtect and _G.CustomProtect.Enabled then
          return
        end

        local text9 = descendant.Text or ""
        if string.find(text9, localPlayer2.Name, 1, true) then
          descendant.Text = LOCOPANI_SafeReplace(text9, { localPlayer2.Name }, v232.NameTag)
        end
      end
    end)

    return
  end
end

function f44(p120)
  -- Quando o Custom Protect estiver ativo, deixe a legenda usar o nome personalizado.
  if _G.CustomProtect and _G.CustomProtect.Enabled then
    return
  end
  if not v232.Enabled then
    return
  elseif not p120 then
    return
  elseif not localPlayer2 then
    return
  else
    local TextLabel = p120:FindFirstChild("TextLabel")

    if not TextLabel then
      for index29, value36 in ipairs(p120:GetDescendants()) do
        if value36:IsA("TextLabel") then
          TextLabel = value36
          break
        end
      end
    end

    if not TextLabel then
      return
    else
      local text10 = TextLabel.Text or ""

      if string.find(text10, localPlayer2.Name) then
        TextLabel.Text = LOCOPANI_SafeReplace(text10, { localPlayer2.Name }, v232.NameTag)
      end

      return
    end
  end
end

local function f46()
  -- O protetor antigo não deve sobrescrever o nome personalizado do Custom Protect.
  if _G.CustomProtect and _G.CustomProtect.Enabled then
    return
  end
  if not v232.Enabled then
    return
  else
    local StringUpper = string.upper(localPlayer2.Name)
    local Interface_2 = localPlayer2.PlayerGui:FindFirstChild("Interface")

    if Interface_2 then
      local Persistent = Interface_2:FindFirstChild("Persistent")

      if Persistent then
        for index30, value37 in ipairs(Persistent:GetChildren()) do
          if value37.Name == "FlashPlayerCardFrame" then
            local Username = value37:FindFirstChild("Username", true)

            if Username and Username:IsA("TextLabel") then
              local StringUpper_2 = string.upper(Username.Text or "")

              if string.find(StringUpper_2, StringUpper) then
                Username.Text = v232.NameTag
              end
            end
          end
        end
      end
    end

    return
  end
end

local function f47()
  if v232.CardLoopConn then
    v232.CardLoopConn:Disconnect()
    v232.CardLoopConn = nil
  end

  if not v232.Enabled then
    return
  end

  v232.CardLoopConn = runService.Heartbeat:Connect(function() f46() end)
end

local f48

local function f49(p121)
  v232.Enabled = p121 and true or false

  if p121 then
    f41()
    f42()
    f45()
    f47()
    f48()
    f46()
  else
    if v232.NotifConn then
      v232.NotifConn:Disconnect()
      v232.NotifConn = nil
    end

    if v232.NotifConn2 then
      v232.NotifConn2:Disconnect()
      v232.NotifConn2 = nil
    end

    if v232.CharWatcher then
      v232.CharWatcher:Disconnect()
      v232.CharWatcher = nil
    end

    f43()

    if localPlayer2.Character then
      local Nametag_2 = localPlayer2.Character:FindFirstChild("Nametag")

      if Nametag_2 then
        local PlayerName_2 = Nametag_2:FindFirstChild("PlayerName")

        if PlayerName_2 and PlayerName_2:IsA("TextLabel") then
          PlayerName_2.Text = localPlayer2.Name
        end
      end
    end

    _G.LOCOPANI_ApplyUserTitle()
  end
end

function f48()
  if v232.CharWatcher then
    v232.CharWatcher:Disconnect()
    v232.CharWatcher = nil
  end

  if not v232.Enabled then
    return
  end

  v232.CharWatcher = localPlayer2.CharacterAdded:Connect(function()
    task.wait(0.5)
    f41()
    f42()
    f45()
  end)
end

f41()
f42()
f45()
f47()
f48()
f46()

_G.Protect = {
  Toggle = f49,
  Update = function()
    f41()
    f42()
    f46()
  end,
  SetName = function(nameTag) v232.NameTag = nameTag end,
  SetTitle = function(title) v232.Title = title end,
  Title = v232.Title,
  IsEnabled = function() return v232.Enabled end,
}

_G.LOCOPANI = {
  Enable = function() f49(true) end,
  Disable = function() f49(false) end,
  SetNameTag = function(nameTag2)
    v232.NameTag = nameTag2
    f41()
  end,
  SetTitle = function(title2)
    v232.Title = title2
    f42()
  end,
  IsEnabled = function() return v232.Enabled end,
}

-- Reapply the default title after the Protect API is initialized.
_G.LOCOPANI_ApplyUserTitle()

v235 = {
  Enabled = false,
  Name = "CUSTOM NAME",
  Title = "<font color='#00FF00'><b>Custom</b></font>",
  NotifConn = nil,
  NotifConn2 = nil,
  CardLoopConn = nil,
  CharWatcher = nil,
}

function v235.updateNametag()
  if not v235.Enabled then
    return
  end

  if localPlayer2 and localPlayer2.Character then
    local Nametag_3 = localPlayer2.Character:FindFirstChild("Nametag")

    if Nametag_3 then
      local PlayerName_3 = Nametag_3:FindFirstChild("PlayerName")

      if PlayerName_3 and PlayerName_3:IsA("TextLabel") then
        PlayerName_3.Text = v235.Name
      end
    end
  end
end

function v235.updateTitle()
  if not v235.Enabled then
    return
  end

  if localPlayer2 then
    _G.LOCOPANI_ApplyUserTitle()
  end
end

v235.TextWatchers = v235.TextWatchers or {}

function v235.replaceLegendName(label)
  if not v235.Enabled or not localPlayer2 or not label
    or not label:IsA("TextLabel") then
    return
  end

  local text = label.Text or ""
  local playerName = localPlayer2.Name
  local customName = tostring(v235.Name or "CUSTOM NAME")
  local oldProtectName = tostring(v232 and v232.NameTag or "LOCOPANI PROTECTION")

  if text == "" then
    return
  end

  -- O listener do protetor antigo pode ter trocado o nome primeiro.
  -- Substituímos tanto o username real quanto o nome padrão antigo.
  text = LOCOPANI_SafeReplace(text, { playerName, oldProtectName, "LOCOPANI PROTECT" }, customName)

  if label.Text ~= text then
    label.Text = text
  end
end

function v235.watchLegendLabel(label)
  if not label or not label:IsA("TextLabel") then
    return
  end

  -- Process immediately, and again whenever the game updates the label's text.
  v235.replaceLegendName(label)

  if v235.TextWatchers[label] then
    return
  end

  local ok, connection = pcall(function()
    return label:GetPropertyChangedSignal("Text"):Connect(function()
      v235.replaceLegendName(label)
    end)
  end)

  if ok and connection then
    v235.TextWatchers[label] = connection
  end
end

function v235.processNotification(item)
  if not v235.Enabled or not item then
    return
  end

  if item:IsA("TextLabel") then
    v235.watchLegendLabel(item)
  end

  for _, descendant in ipairs(item:GetDescendants()) do
    if descendant:IsA("TextLabel") then
      v235.watchLegendLabel(descendant)
    end
  end
end

function v235.setupNotifications()
  if v235.NotifConn then
    v235.NotifConn:Disconnect()
    v235.NotifConn = nil
  end

  if v235.NotifConn2 then
    v235.NotifConn2:Disconnect()
    v235.NotifConn2 = nil
  end

  -- Remove text-change listeners from the previous interface.
  for label, connection in pairs(v235.TextWatchers) do
    if connection then
      pcall(function() connection:Disconnect() end)
    end
    v235.TextWatchers[label] = nil
  end

  if not v235.Enabled or not localPlayer2 then
    return
  end

  local playerGui = localPlayer2:FindFirstChildOfClass("PlayerGui")
  local interface = playerGui and playerGui:FindFirstChild("Interface")
  if not interface then
    return
  end

  -- Watch the whole Interface, not only Persistent/Notifications:
  -- score announcements/legend labels may be created elsewhere.
  v235.processNotification(interface)

  v235.NotifConn = interface.DescendantAdded:Connect(function(descendant)
    if not v235.Enabled then
      return
    end

    if descendant:IsA("TextLabel") then
      v235.watchLegendLabel(descendant)
    else
      v235.processNotification(descendant)
    end
  end)

  -- Also catch labels directly parented to Interface.
  v235.NotifConn2 = interface.ChildAdded:Connect(function(child)
    v235.processNotification(child)
  end)
end

function v235.protectPlayerCard()
  if not v235.Enabled then
    return
  else
    local StringUpper_3 = string.upper(localPlayer2.Name)
    local Interface_4 = localPlayer2.PlayerGui:FindFirstChild("Interface")

    if Interface_4 then
      local Persistent_2 = Interface_4:FindFirstChild("Persistent")

      if Persistent_2 then
        for index33, value40 in ipairs(Persistent_2:GetChildren()) do
          if value40.Name == "FlashPlayerCardFrame" then
            local Username_2 = value40:FindFirstChild("Username", true)

            if Username_2 and Username_2:IsA("TextLabel") then
              local StringUpper_4 = string.upper(Username_2.Text or "")

              if string.find(StringUpper_4, StringUpper_3) then
                Username_2.Text = v235.Name
              end
            end
          end
        end
      end
    end

    return
  end
end

function v235.startCardLoop()
  if v235.CardLoopConn then
    v235.CardLoopConn:Disconnect()
    v235.CardLoopConn = nil
  end

  if not v235.Enabled then
    return
  end

  v235.CardLoopConn = runService.Heartbeat:Connect(function() v235.protectPlayerCard() end)
end

function v235.stopCardLoop()
  if v235.CardLoopConn then
    v235.CardLoopConn:Disconnect()
    v235.CardLoopConn = nil
  end
end

function v235.installCharacterWatcher()
  if v235.CharWatcher then
    v235.CharWatcher:Disconnect()
    v235.CharWatcher = nil
  end

  if not v235.Enabled then
    return
  end

  v235.CharWatcher = localPlayer2.CharacterAdded:Connect(function()
    task.wait(0.5)

    v235.updateNametag()
    v235.updateTitle()
    v235.setupNotifications()
    v235.protectPlayerCard()
    if v235.refreshLeaderboardMask then
      v235.refreshLeaderboardMask()
    end
  end)
end

function v235.toggle(p123)
  v235.Enabled = p123 and true or false

  if p123 then
    v235.updateNametag()
    v235.updateTitle()
    v235.setupNotifications()
    v235.startCardLoop()
    v235.installCharacterWatcher()
    v235.protectPlayerCard()
    if v235.refreshLeaderboardMask then
      v235.refreshLeaderboardMask()
    end
  else
    if v235.NotifConn then
      v235.NotifConn:Disconnect()
      v235.NotifConn = nil
    end

    if v235.NotifConn2 then
      v235.NotifConn2:Disconnect()
      v235.NotifConn2 = nil
    end

    if v235.CharWatcher then
      v235.CharWatcher:Disconnect()
      v235.CharWatcher = nil
    end

    v235.stopCardLoop()

    for label, connection in pairs(v235.TextWatchers or {}) do
      if connection then
        pcall(function() connection:Disconnect() end)
      end
      v235.TextWatchers[label] = nil
    end

    if localPlayer2.Character then
      local Nametag_4 = localPlayer2.Character:FindFirstChild("Nametag")

      if Nametag_4 then
        local PlayerName_4 = Nametag_4:FindFirstChild("PlayerName")

        if PlayerName_4 and PlayerName_4:IsA("TextLabel") then
          PlayerName_4.Text = localPlayer2.Name
        end
      end
    end

    _G.LOCOPANI_ApplyUserTitle()
  end
end

function v235.setName(p124)
  v235.Name = p124 or "CUSTOM NAME"

  if v235.Enabled then
    v235.updateNametag()
    v235.protectPlayerCard()
    if v235.refreshLeaderboardMask then
      v235.refreshLeaderboardMask()
    end
  end
end

function v235.setTitle(p125)
  v235.Title = p125 or ""

  if v235.Enabled then
    v235.updateTitle()
  end
end

_G.CustomProtect = v235

do
-- LOCOPANI leaderboard/name privacy fix (optimized):
-- Watch text changes and newly-created UI elements instead of rescanning the whole
-- PlayerGui every 0.5 seconds. This keeps the name mask responsive with much less work.
local LOCOPANI_NameMaskConnections = {}
local LOCOPANI_NameMaskBusy = setmetatable({}, { __mode = "k" })

local function LOCOPANI_ApplyNameMask(label)
  if not label or not label.Parent then
    return
  end

  local player = localPlayer2
  if not player then
    return
  end

  local customEnabled = v235 and v235.Enabled == true
  local protectEnabled = v232 and v232.Enabled == true
  if not customEnabled and not protectEnabled then
    return
  end

  local realName = tostring(player.Name or "")
  if realName == "" then
    return
  end

  -- Read the current input value too, so the leaderboard never gets stuck
  -- displaying the default "CUSTOM NAME" after the user edits the field.
  local replacement
  if customEnabled then
    local configuredName = nil
    pcall(function()
      configuredName = options and options.customprotectname and options.customprotectname.Value
    end)
    if type(configuredName) ~= "string" or configuredName:gsub("%s+", "") == "" then
      configuredName = v235.Name
    end
    replacement = tostring(configuredName or "CUSTOM NAME")
  else
    replacement = tostring(v232.NameTag or "LOCOPANI PROTECTION")
  end

  local ok, currentText = pcall(function()
    return label.Text
  end)
  if not ok or type(currentText) ~= "string" or currentText == "" then
    return
  end

  local updatedText = currentText
  local candidates = { realName, tostring(v232 and v232.NameTag or "LOCOPANI PROTECTION"), "LOCOPANI PROTECT", "CUSTOM NAME" }
  updatedText = LOCOPANI_SafeReplace(updatedText, candidates, replacement)

  if updatedText ~= currentText then
    LOCOPANI_NameMaskBusy[label] = true
    pcall(function()
      label.Text = updatedText
    end)
    LOCOPANI_NameMaskBusy[label] = nil
  end
end

-- Reaplica imediatamente o nome atual a todos os labels já observados.
-- Isso permite trocar o nome durante a partida sem precisar reconectar.
v235.refreshLeaderboardMask = function()
  for label in pairs(LOCOPANI_NameMaskConnections) do
    if label and label.Parent then
      LOCOPANI_ApplyNameMask(label)
    else
      LOCOPANI_NameMaskConnections[label] = nil
    end
  end
end

local function LOCOPANI_WatchNameLabel(instance)
  if not (instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox")) then
    return
  end
  if LOCOPANI_NameMaskConnections[instance] then
    LOCOPANI_ApplyNameMask(instance)
    return
  end

  local ok, connection = pcall(function()
    return instance:GetPropertyChangedSignal("Text"):Connect(function()
      if not LOCOPANI_NameMaskBusy[instance] then
        LOCOPANI_ApplyNameMask(instance)
      end
    end)
  end)
  if ok and connection then
    LOCOPANI_NameMaskConnections[instance] = connection
  end

  LOCOPANI_ApplyNameMask(instance)
end

task.spawn(function()
  local player = localPlayer2
  if not player then
    return
  end

  local playerGui = player:FindFirstChildOfClass("PlayerGui")
  while not playerGui and player.Parent do
    task.wait(1)
    playerGui = player:FindFirstChildOfClass("PlayerGui")
  end
  if not playerGui then
    return
  end

  -- One initial pass, then only handle labels when their text/UI changes.
  for _, instance in ipairs(playerGui:GetDescendants()) do
    LOCOPANI_WatchNameLabel(instance)
  end

  playerGui.DescendantAdded:Connect(function(instance)
    LOCOPANI_WatchNameLabel(instance)
  end)
end)
end -- end scoped leaderboard name-mask block

v238 = { EffectEnabled = false, CardEnabled = false, BallEnabled = false }

-- LOCOPANI: pools do randomizador (multi-select). Vazio = sorteia entre todos.
LOCOPANI_RandomPool = { ScoreEffect = {}, Ball = {}, PlayerCard = {} }

do
  local function f51()
    local f50_2 = f50("Ball")

    if f50_2 then
      ball = f50_2

      if v220 then
        sweep()
      end

      v174:Notify("Random Ball: " .. f50_2)
    end
  end

  local function f52()
    local f50_3 = f50("ScoreEffect")

    if f50_3 then
      scoreEffect = f50_3

      v174:Notify("Random Effect: " .. f50_3)
    end
  end

  function f50(p126)
    -- LOCOPANI: 1) se houver itens marcados no dropdown, sorteia só entre eles.
    local pool = LOCOPANI_RandomPool and LOCOPANI_RandomPool[p126]
    if type(pool) == "table" then
      local chosen = {}
      for name, enabled in pairs(pool) do
        if enabled == true then table.insert(chosen, name) end
      end
      if #chosen > 0 then
        return chosen[math.random(1, #chosen)]
      end
    end

    -- 2) sem seleção: sorteia entre todos os itens da pasta do jogo.
    local names = {}
    if type(p126) == "string" then
      local folder = replicatedStorage:FindFirstChild("Assets") and replicatedStorage.Assets:FindFirstChild(p126)
        or replicatedStorage:FindFirstChild(p126)
        or (replicatedStorage:FindFirstChild("Content") and replicatedStorage.Content:FindFirstChild(p126))

      if folder then
        for _, child in ipairs(folder:GetChildren()) do
          if child:IsA("ModuleScript") or child:IsA("Model") or child:IsA("Folder") then
            table.insert(names, child.Name)
          end
        end
      end
    end

    -- 3) pasta não encontrada: usa a mesma lista que aparece nos dropdowns.
    if #names == 0 then
      local fallback = (p126 == "Ball" and v212) or (p126 == "ScoreEffect" and v205)
        or (p126 == "PlayerCard" and v210) or nil
      if type(fallback) == "table" then
        for _, name in ipairs(fallback) do table.insert(names, name) end
      end
    end

    if #names == 0 then
      return nil
    end

    return names[math.random(1, #names)]
  end

  local function f53(p127)
    if not v238.EffectEnabled then
      return
    end

    -- LOCOPANI: o sorteio do Score Effect agora acontece dentro de f114
    -- (no momento exato em que o efeito é disparado).
  end

  local function f54(p128)
    if not v238.BallEnabled then
      return
    end

    if p128:IsA("Model") and p128.Name:match("^CLIENT_BALL_") then
      task.wait(0.1)
      f51()
    end
  end

  workspace.ChildAdded:Connect(function(child4) f54(child4) end)
  workspace.DescendantAdded:Connect(function(descendant3) f53(descendant3) end)

  task.wait(1)

  for index35, value42 in ipairs(workspace:GetChildren()) do
    f54(value42)
  end

  for index36, value43 in ipairs(workspace:GetDescendants()) do
    f53(value43)
  end
end

local f55

local function f56()
  if v209 then
    return
  end

  if not v206 and not v238.CardEnabled then
    return
  else
    local Interface_5 = localPlayer2.PlayerGui:FindFirstChild("Interface")

    if Interface_5 then
      local Persistent_3 = Interface_5:FindFirstChild("Persistent")

      if Persistent_3 then
        for index37, value44 in ipairs(Persistent_3:GetChildren()) do
          if value44.Name == "FlashPlayerCardFrame" then
            local Username_3 = value44:FindFirstChild("Username", true)

            if Username_3 and Username_3:IsA("TextLabel") then
              local StringUpper_5 = string.upper(Username_3.Text or "")
              local StringUpper_6 = string.upper(localPlayer2.Name)

              if string.find(StringUpper_5, StringUpper_6) then
                if v228.__cardFiredFor == value44 then
                  return
                end

                if v238.CardEnabled then
                  local f50_4 = f50("PlayerCard")

                  if f50_4 then
                    v207 = f50_4
                    v174:Notify("Random Card: " .. f50_4)
                  end
                end

                v228.__cardFiredFor = value44
                value44:Destroy()
                task.wait(0.1)
                f55()
              end
            end
          end
        end

        return
      end

      return
    end

    return
  end
end

function f55()
  if v208 or v209 then
    return
  else
    local OnFlashCard = replicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.PlayerCardService.RE.OnFlashCard

    if OnFlashCard and firesignal then
      v209 = true
      v208 = true

      firesignal(OnFlashCard.OnClientEvent, {
        PlayerCardItemId = v207,
        Context = { Custom = {}, PlacementId = "ScoredPoint" },
        Player = localPlayer2,
      })

      task.wait(0.3)
      v208 = false
      v209 = false
    end

    return
  end
end

local connect2
local playerCardGuiConn
local playerCardInterfaceConn
local playerCardPersistentConn
local playerCardPending = false

local function f57()
  if connect2 then
    connect2:Disconnect()
    connect2 = nil
  end
  if playerCardGuiConn then
    playerCardGuiConn:Disconnect()
    playerCardGuiConn = nil
  end
  if playerCardInterfaceConn then
    playerCardInterfaceConn:Disconnect()
    playerCardInterfaceConn = nil
  end
  if playerCardPersistentConn then
    playerCardPersistentConn:Disconnect()
    playerCardPersistentConn = nil
  end
  playerCardPending = false
  v228.__cardFiredFor = nil
  v208 = false
  v209 = false
end

local function f58()
  if connect2 or playerCardGuiConn then
    return
  end

  local function attachPersistent(persistent)
    if not persistent or not persistent:IsA("Instance") then return end
    if connect2 and playerCardPersistentConn == persistent then return end
    if connect2 then
      connect2:Disconnect()
      connect2 = nil
    end
    playerCardPersistentConn = persistent

    local function onCardAdded(child5)
      if child5.Name ~= "FlashPlayerCardFrame" or playerCardPending then return end
      playerCardPending = true
      task.spawn(function()
        -- The game sometimes adds the card frame before its Username label is ready.
        for attempt = 1, 12 do
          if not child5.Parent then break end
          local username = child5:FindFirstChild("Username", true)
          if username and username:IsA("TextLabel") and username.Text ~= "" then
            break
          end
          task.wait(0.05)
        end
        if child5.Parent then
          f56()
        end
        playerCardPending = false
      end)
    end

    connect2 = persistent.ChildAdded:Connect(onCardAdded)
    -- Handle a card that appeared just before the listener was attached.
    for _, existingCard in ipairs(persistent:GetChildren()) do
      if existingCard.Name == "FlashPlayerCardFrame" then
        onCardAdded(existingCard)
      end
    end
  end

  local function attachInterface(interface)
    if not interface then return end
    local persistent = interface:FindFirstChild("Persistent")
    if persistent then attachPersistent(persistent) end

    if playerCardInterfaceConn then
      playerCardInterfaceConn:Disconnect()
      playerCardInterfaceConn = nil
    end
    playerCardInterfaceConn = interface.ChildAdded:Connect(function(child)
      if child.Name == "Persistent" then attachPersistent(child) end
    end)
  end

  local playerGui = localPlayer2:FindFirstChildOfClass("PlayerGui") or localPlayer2:WaitForChild("PlayerGui", 10)
  if not playerGui then return end

  local interface = playerGui:FindFirstChild("Interface")
  if interface then attachInterface(interface) end

  -- The interface can load after the toggle is enabled, so keep watching for it.
  playerCardGuiConn = playerGui.ChildAdded:Connect(function(child)
    if child.Name == "Interface" then attachInterface(child) end
  end)
end

_G.PlayerCard = {
  Enable = f58,
  Disable = f57,
  SetCard = function(p129) v207 = p129 end,
  GetCard = function() return v207 end,
  Fire = f55,
  Apply = function(p130)
    if p130 and p130 ~= "" then
      v207 = p130
    end

    if not v206 then
      v174:Notify("Turn PlayerCard Changer on first")
      return
    end

    v228.__cardFiredFor = nil
    f55()
  end,
}

v242 = {
  enabled = false,
  Color3_2 = Color3.fromRGB(255, 0, 0),
  currentPlayer = nil,
  originalColors = {},
  connection = nil,
}

function v242.saveAndPaint(p131)
  if not p131 then
    return
  end

  for index38, value45 in ipairs(p131:GetDescendants()) do
    if value45:IsA("BasePart") then
      if v242.originalColors[value45] == nil then
        v242.originalColors[value45] = value45.Color
      end

      value45.Color = v242.Color3_2
    end
  end
end

function v242.restoreColors(p132)
  if not p132 then
    return
  end

  for index39, value46 in ipairs(p132:GetDescendants()) do
    if value46:IsA("BasePart") and v242.originalColors[value46] then
      value46.Color = v242.originalColors[value46]
      v242.originalColors[value46] = nil
    end
  end
end

function v242.clearCurrent()
  if v242.currentPlayer then
    local Character = v242.currentPlayer.Character

    if Character then
      v242.restoreColors(Character)
    end

    v242.currentPlayer = nil
  end
end

function v242.start()
  if v242.connection then
    return
  else
    local BallTouched = replicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.BallService.RE.BallTouched

    if not BallTouched then
      return
    end

    v242.connection = BallTouched.OnClientEvent:Connect(function(p133)
      if not v242.enabled then
        return
      end

      if not (typeof(p133) == "Instance" and p133:IsA("Player")) then
        return
      end

      if v242.currentPlayer and v242.currentPlayer ~= p133 then
        local Character_2 = v242.currentPlayer.Character

        if Character_2 then
          v242.restoreColors(Character_2)
        end
      end

      if v242.currentPlayer ~= p133 then
        local Character_3 = p133.Character

        if Character_3 then
          v242.saveAndPaint(Character_3)
        else
          p133.CharacterAdded:Once(function(p134)
            task.wait(0.1)

            if v242.enabled then
              v242.saveAndPaint(p134)
            end
          end)
        end
      end

      v242.currentPlayer = p133
    end)

    return
  end
end

function v242.stop()
  if v242.connection then
    v242.connection:Disconnect()
    v242.connection = nil
  end

  v242.clearCurrent()
end

function v242.setColor(color3)
  v242.Color3_2 = color3

  if v242.enabled and v242.currentPlayer then
    local Character_4 = v242.currentPlayer.Character

    if Character_4 then
      v242.saveAndPaint(Character_4)
    end
  end
end

v243 = {
  enabled = false,
  wasInRange = false,
  cooldownActive = false,
  radius = 20,
  connection = nil,
  charConnection = nil,
}

function v243.getNearestBall()
  local MathHuge = math.MathHuge
  local Character_5 = localPlayer2.Character
  local v244

  if not Character_5 then
    return nil, nil
  else
    local HumanoidRootPart = Character_5:FindFirstChild("HumanoidRootPart")

    if not HumanoidRootPart then
      return nil, nil
    end

    for index40, value47 in ipairs(workspaceService:GetChildren()) do
      if value47:IsA("Model") and value47.Name:match("^CLIENT_BALL_%d+$") then
        for index41, value48 in ipairs(value47:GetDescendants()) do
          if value48:IsA("BasePart") then
            local Magnitude = (value48.Position - HumanoidRootPart.Position).Magnitude

            if Magnitude < MathHuge then
              v244 = value48
              MathHuge = Magnitude
            end

            break
          end
        end
      end
    end

    return v244, MathHuge
  end
end

function v243.isOnGround()
  local Character_6 = localPlayer2.Character

  if not Character_6 then
    return false
  else
    local Humanoid = Character_6:FindFirstChild("Humanoid")

    if not Humanoid then
      return false
    end

    return Humanoid.FloorMaterial ~= Enum.Material.Air
  end
end

function v243.triggerCooldown()
  v243.cooldownActive = true
  v243.wasInRange = true

  task.delay(5, function()
    v243.cooldownActive = false
    v243.wasInRange = false
  end)
end

do
  function v243.step()
    if not v243.enabled then
      return
    elseif v243.cooldownActive then
      return
    else
      local Character_7 = localPlayer2.Character

      if not Character_7 then
        return
      else
        local Humanoid_2 = Character_7:FindFirstChild("Humanoid")

        if not Humanoid_2 then
          return
        end

        if Humanoid_2:GetState() == Enum.HumanoidStateType.Jumping
          or Humanoid_2:GetState() == Enum.HumanoidStateType.Freefall or Humanoid_2.Jump == true then
          v243.wasInRange = false
          return
        elseif not v243.isOnGround() then
          v243.wasInRange = false
          return
        else
          local v245, v246 = v243.getNearestBall()

          if not v245 then
            v243.wasInRange = false
            return
          else
            local v247 = v246 <= v243.radius

            if v247 and not v243.wasInRange then
              if firesignal then
                firesignal(doMove.OnClientEvent, "Set", false, false)
                firesignal(stopAllEmotes.OnClientEvent)
              end

              v243.triggerCooldown()
            end

            v243.wasInRange = v247
            return
          end
        end
      end
    end
  end

  function v243.start()
    if v243.connection then
      return
    end

    v243.connection = runService.Heartbeat:Connect(v243.step)
    f36(v243.connection)

    if not v243.charConnection then
      v243.charConnection = localPlayer2.CharacterAdded:Connect(function()
        v243.wasInRange = false
        v243.cooldownActive = false
      end)

      f36(v243.charConnection)
    end
  end

  function v243.stop()
    if v243.connection then
      v243.connection:Disconnect()
      v243.connection = nil
    end

    if v243.charConnection then
      v243.charConnection:Disconnect()
      v243.charConnection = nil
    end

    v243.wasInRange = false
    v243.cooldownActive = false
  end

  function v243.setRadius(p135)
    v243.radius = p135 or 20
  end

  _G.AutoReceive = {
    SetEnabled = function(p136)
      v243.enabled = p136

      if p136 then
        v243.start()
      else
        v243.stop()
      end
    end,
    IsEnabled = function() return v243.enabled end,
    SetRadius = function(p137) v243.setRadius(p137) end,
  }

  local function f59()
    v212 = {}
    local seen = {}
    local Assets = replicatedStorage:FindFirstChild("Assets")
    local Ball = Assets and Assets:FindFirstChild("Ball")

    if Ball then
      for _, asset in ipairs(Ball:GetChildren()) do
        if asset:IsA("Model") and not seen[asset.Name] then
          seen[asset.Name] = true
          table.insert(v212, asset.Name)
        end
      end
    end

    -- Some games register ball cosmetics as inventory Item modules too.
    local entities = replicatedStorage:FindFirstChild("Content")
      and replicatedStorage.Content:FindFirstChild("Item")
      and replicatedStorage.Content.Item:FindFirstChild("Entities")
    if entities then
      for _, module in ipairs(entities:GetChildren()) do
        if module:IsA("ModuleScript") then
          local okItem, itemData = pcall(require, module)
          if okItem and type(itemData) == "table" and itemData.Type == "Ball"
            and not seen[module.Name] then
            seen[module.Name] = true
            table.insert(v212, module.Name)
          end
        end
      end
    end

    table.sort(v212)
    if #v212 == 0 then
      table.insert(v212, "ClassicBall")
      table.insert(v212, "ExtremeBall")
      table.insert(v212, "MediumBall")
    end
    return v212
  end

  local function f60()
    v210 = {}
    local seen = {}
    local content = replicatedStorage:FindFirstChild("Content")
    local itemFolder = content and content:FindFirstChild("Item")
    local Entities = itemFolder and itemFolder:FindFirstChild("Entities")

    if Entities then
      for _, module in ipairs(Entities:GetChildren()) do
        if module:IsA("ModuleScript") then
          local okItem, itemData = pcall(require, module)
          local itemName = module.Name
          local isCard = string.match(itemName, "Card") ~= nil
            or string.match(itemName, "PlayerCard") ~= nil
            or (okItem and type(itemData) == "table"
              and (itemData.Type == "PlayerCard" or itemData.Type == "Card"))
          if isCard and not seen[itemName] then
            seen[itemName] = true
            table.insert(v210, itemName)
          end
        end
      end
    end

    table.sort(v210)
    if #v210 == 0 then
      table.insert(v210, "ContentCreatorPlayerCard")
      table.insert(v210, "UltimateChampionPlayerCard")
      table.insert(v210, "ProPlayerCard")
    end
    return v210
  end

  local function f61()
    v205 = {}
    local seen = {}
    local Assets = replicatedStorage:FindFirstChild("Assets")
    local ScoreEffect = Assets and Assets:FindFirstChild("ScoreEffect")

    if ScoreEffect then
      for _, asset in ipairs(ScoreEffect:GetChildren()) do
        if asset:IsA("ModuleScript") and not seen[asset.Name] then
          seen[asset.Name] = true
          table.insert(v205, asset.Name)
        end
      end
    end

    local Entities = replicatedStorage:FindFirstChild("Content")
      and replicatedStorage.Content:FindFirstChild("Item")
      and replicatedStorage.Content.Item:FindFirstChild("Entities")
    if Entities then
      for _, module in ipairs(Entities:GetChildren()) do
        if module:IsA("ModuleScript") then
          local okItem, itemData = pcall(require, module)
          if okItem and type(itemData) == "table" and itemData.Type == "ScoreEffect"
            and not seen[module.Name] then
            seen[module.Name] = true
            table.insert(v205, module.Name)
          end
        end
      end
    end

    local Effects = Assets and Assets:FindFirstChild("Effects")
    if Effects then
      for _, name in ipairs({ "GroundHit1", "GroundHit2", "SupernovaScoreEffect" }) do
        if Effects:FindFirstChild(name) and not seen[name] then
          seen[name] = true
          table.insert(v205, name)
        end
      end
    end

    table.sort(v205)
    if #v205 == 0 then
      table.insert(v205, "SupernovaScoreEffect")
      table.insert(v205, "GroundHit1")
      table.insert(v205, "GroundHit2")
    end
    return v205
  end

  v205 = f61()

  local function f62()
    local GetRawMetatable = getrawmetatable(game)
    local namecall = GetRawMetatable.__namecall
    setreadonly(GetRawMetatable, false)

    function GetRawMetatable.__namecall(p138, ...)
      local GetNamecallMethod = getnamecallmethod()
      local v250 = ...

      if p138 == ballService.RF.Interact and GetNamecallMethod == "InvokeServer" then
        if type(v250) == "table" and v250.Move == "Spike" then
          if v222 and firesignal and localPlayer2 and localPlayer2.Character then
            firesignal(effects.OnClientEvent, {
              Character = localPlayer2.Character,
              Sound = "PowerSpike",
              Effect = "SpecialChargeSpikeVFX",
            })
          elseif v223 and firesignal and localPlayer2 and localPlayer2.Character then
            firesignal(effects.OnClientEvent, {
              Character = localPlayer2.Character,
              Sound = "PowerSpike",
              Effect = "HidariSpikeVFX",
            })
          end
        end

        return namecall(p138, v250)
      end

      return namecall(p138, ...)
    end

    setreadonly(GetRawMetatable, true)
  end

  v210 = f60()
  v212 = f59()

  if getrawmetatable and setreadonly and getnamecallmethod then
    pcall(f62)
  end
end

local function f63()
  local MathHuge_2 = math.huge
  local Character_8 = localPlayer2.Character
  local v251

  if not Character_8 then
    return nil
  else
    local HumanoidRootPart_2 = Character_8:FindFirstChild("HumanoidRootPart")

    if not HumanoidRootPart_2 then
      return nil
    end

    for index46, value53 in ipairs(workspaceService:GetChildren()) do
      if value53:IsA("Model") and value53.Name:match("^CLIENT_BALL_%d+$") then
        for index47, value54 in ipairs(value53:GetDescendants()) do
          if value54:IsA("BasePart") then
            local Magnitude_2 = (value54.Position - HumanoidRootPart_2.Position).Magnitude

            if Magnitude_2 < MathHuge_2 then
              MathHuge_2 = Magnitude_2
              v251 = value54
            end

            break
          end
        end
      end
    end

    return v251
  end
end

local function f64()
  v182 = true

  if v183 then
    return
  end

  local namecall2

  if not (getrawmetatable and setreadonly and getnamecallmethod) then
    return
  else
    local GetRawMetatable_2 = getrawmetatable(game)
    namecall2 = GetRawMetatable_2.__namecall
    setreadonly(GetRawMetatable_2, false)

    function GetRawMetatable_2.__namecall(p139, ...)
      local GetNamecallMethod_2 = getnamecallmethod()
      local v254 = ...

      if p139 == ballService.RF.Interact and GetNamecallMethod_2 == "InvokeServer" then
        if type(v254) == "table" and v254.Move == "Spike" and v182 then
          local LookVector = currentCamera2.CFrame.LookVector

          v254.LookVector = LookVector
          v254.Direction = LookVector

          if v254.MoveDirection then
            v254.MoveDirection = LookVector
          end
        end

        return namecall2(p139, v254)
      end

      return namecall2(p139, ...)
    end

    setreadonly(GetRawMetatable_2, true)
    v183 = true
    return
  end
end

local function f65()
  for index48, value55 in ipairs(workspaceService:GetChildren()) do
    if value55:IsA("Model") and value55.Name:match("^CLIENT_BALL_%d+$") then
      local Match = value55.Name:match("%d+")

      if Match then
        return tonumber(Match)
      end
    end
  end

  return nil
end

local function f66()
  v182 = false
end

v255 = { enabled = false, side = "Auto", reach = "All" }

local function f67()
  v184 = true

  if v185 then
    return
  end

  local namecall3

  if not (getrawmetatable and setreadonly and getnamecallmethod) then
    return
  else
    local GetRawMetatable_3 = getrawmetatable(game)
    namecall3 = GetRawMetatable_3.__namecall
    setreadonly(GetRawMetatable_3, false)

    function GetRawMetatable_3.__namecall(p140, ...)
      local GetNamecallMethod_3 = getnamecallmethod()
      local v258 = ...

      if p140 == ballService.RF.Interact and GetNamecallMethod_3 == "InvokeServer" then
        if type(v258) == "table" and v258.Move == "Spike" and v184 then
          if v258.TiltDirection and v258.LookVector then
            local TiltDirection = v258.TiltDirection

            if math.abs(TiltDirection.X) > 0.01 or math.abs(TiltDirection.Z) > 0.01 then
              local LookVector_2 = v258.LookVector
              local Vector3_2 = Vector3.new(TiltDirection.X, 0, TiltDirection.Z)

              v258.LookVector = Vector3.new(
                LookVector_2.X + Vector3_2.X * 0.3, LookVector_2.Y, LookVector_2.Z + Vector3_2.Z * 0.3
              ).Unit

              v258.TiltDirection = Vector3.new(
                TiltDirection.X * 1.35, TiltDirection.Y, TiltDirection.Z * 1.35
              )
            end
          end
        end

        return namecall3(p140, v258)
      end

      return namecall3(p140, ...)
    end

    setreadonly(GetRawMetatable_3, true)
    v185 = true
    return
  end
end

local function f68()
  v184 = false
end

do
  function v255.physics()
    local v259, v260 = pcall(require, replicatedStorage.Common.Physics)
    return v259 and v260 or nil
  end

  function v255.bounds()
    local Physics = v255.physics()
    local map, court

    if Physics and Physics._getCourtlines then
      local v262, v263 = pcall(Physics._getCourtlines)

      if v262 and v263 and v263:IsA("BasePart") then
        return v263.Position, v263.Size * 0.5, v263.Position.Y
      end

      map = workspaceService:FindFirstChild("Map")
      court = map and map:FindFirstChild("Court")

      if court then
        return court.Position, court.Size * 0.5 - Vector3.new(1, 0, 1), court.Position.Y + court.Size.Y * 0.5
      end

      return nil
    end

    map = workspaceService:FindFirstChild("Map")
    court = map and map:FindFirstChild("Court")

    if court then
      return court.Position, court.Size * 0.5 - Vector3.new(1, 0, 1), court.Position.Y + court.Size.Y * 0.5
    end

    return nil
  end

  function v255.trackBall(p141, p142, p143)
    if p143 <= 0 then
      return
    end

    v255.drift = (p141.Position - p142) / p143
  end

  function v255.origin()
    local f63_2 = f63()

    local Character_9 = localPlayer2.Character
      and localPlayer2.Character:FindFirstChild("HumanoidRootPart")

    if not f63_2 then
      return Character_9 and Character_9.Position or Vector3.zero
    else
      local v265 = not Character_9
      local drift = v255.drift

      if v265 or typeof(drift) ~= "Vector3" or drift.Magnitude < 1 then
        return f63_2.Position
      else
        local Position = f63_2.Position - Character_9.Position
        local AssemblyLinearVelocity = drift - Character_9.AssemblyLinearVelocity
        local Dot = AssemblyLinearVelocity:Dot(AssemblyLinearVelocity)

        if Dot < 1 then
          return f63_2.Position
        else
          local Dot_2 = Position:Dot(AssemblyLinearVelocity)
          local MathClamp_3 = math.clamp(-Dot_2 / Dot, 0, 0.45)
          return f63_2.Position + drift * MathClamp_3
        end
      end
    end
  end

  local function f69()
    local Character_10 = localPlayer2.Character
      and localPlayer2.Character:FindFirstChild("HumanoidRootPart")

    local v269 = not Character_10
    local v270, v271, v272 = v255.bounds()
    local v273

    if v269 or not v270 then
      return nil
    else
      local MathMax = math.max(v271.X - 2, 1)
      local MathMax_2 = math.max(v271.Z - 2, 1)
      local Map = workspaceService:FindFirstChild("Map")
      local BallCollideOnly = Map and Map:FindFirstChild("BallCollideOnly")
      local Net = BallCollideOnly and BallCollideOnly:FindFirstChild("Net")
      local Z = Net and Net.Position.Z or v270.Z
      local Value_2 = localPlayer2.Team and localPlayer2.Team:GetAttribute("Index")

      if Value_2 == 1 then
        v273 = 1
      elseif Value_2 == 2 then
        v273 = -1
      else
        v273 = Character_10.Position.Z < Z and 1 or -1
      end

      local v276 = v270.Z + v273 * MathMax_2
      local v277 = v270.X + v273 * MathMax
      local v278 = v270.X - v273 * MathMax
      local Origin = v255.origin()
      local MathAbs = math.abs(Character_10.Position.Z - Z)
      local Clamp_2 = 1 - math.clamp(MathAbs / (v271.Z / 3), 0, 1)
      v255.lean = Clamp_2
      local v282 = v270.Z + v273 * MathMax_2 * 0.3
      local reach = v255.reach
      local v283 = reach == "Nearest"

      local V283 = v283
      V283 = v283 or reach ~= "Back" and Clamp_2 > 0

      local side = v255.side

      if side == "Left" then
        return Vector3.new(v277, v272, V283 and v282 or v276)
      elseif side == "Right" then
        return Vector3.new(v278, v272, V283 and v282 or v276)
      else
        local v285 = {}

        if reach ~= "Nearest" then
          v285[#v285 + 1] = { at = Vector3.new(v277, v272, v276), reward = 0 }
          v285[#v285 + 1] = { at = Vector3.new(v278, v272, v276), reward = 0 }
        end

        if V283 then
          v285[#v285 + 1] = { at = Vector3.new(v277, v272, v282), reward = 0.45 * Clamp_2 }
          v285[#v285 + 1] = { at = Vector3.new(v278, v272, v282), reward = 0.45 * Clamp_2 }
        end

        local currentCamera3 = workspaceService.CurrentCamera or currentCamera2

        local LookVector_3 = currentCamera3 and currentCamera3.CFrame.LookVector
          or Character_10.CFrame.LookVector

        local Vector3_3 = Vector3.new(LookVector_3.X, 0, LookVector_3.Z)

        if Vector3_3.Magnitude < 0.01 then
          return v285[1].at
        else
          local Unit = Vector3_3.Unit
          local Physics_2 = v255.physics()
          local GetCourtlines = Physics_2 and Physics_2._getCourtlines and Physics_2._getCourtlines()
          local v287 = {}

          for index50, value56 in ipairs(players:GetPlayers()) do
            if value56 ~= localPlayer2
              and (not localPlayer2.Team or value56.Team ~= localPlayer2.Team) then
              local Character_11 = value56.Character

              local Character9 = Character_11

              Character9 = Character_11
                and value56.Character:FindFirstChild("HumanoidRootPart")

              if Character9 then
                v287[#v287 + 1] = Vector3.new(
                  Character9.Position.X, v272, Character9.Position.Z
                )
              end
            end
          end

          local v288 = {}

          for index51, value57 in ipairs(v285) do
            local v289 = true

            if GetCourtlines and Physics_2.isPositionInCourt then
              local v290, v291 = pcall(
                Physics_2.isPositionInCourt, value57.at, GetCourtlines, 0, nil
              )

              v289 = not v290 or v291
            end

            if v289 then
              local Vector3_4 = Vector3.new(value57.at.X - Origin.X, 0, value57.at.Z - Origin.Z)

              if Vector3_4.Magnitude > 0.01 then
                local Dot_3 = Vector3_4.Unit:Dot(Unit)
                v288[#v288 + 1] = { spot = value57.at, dot = Dot_3, reward = value57.reward }
              end
            end
          end

          if #v288 == 0 then
            return v285[1].at
          else
            local v292 = nil

            for index52, value58 in ipairs(v288) do
              if not v292 or value58.dot > v292.dot then
                v292 = value58
              end
            end

            local X_2 = v292.spot.X >= v270.X
            local spot = nil
            local v294 = nil

            for index53, value59 in ipairs(v288) do
              if value59.spot.X >= v270.X == X_2 then
                local v295 = 60

                for index54, value60 in ipairs(v287) do
                  local Magnitude_3 = (value60 - value59.spot).Magnitude

                  if Magnitude_3 < v295 then
                    v295 = Magnitude_3
                  end
                end

                local MathMin_2 = math.min(v295, 45) / 45 + value59.reward

                if not v294 or MathMin_2 > v294 then
                  v294 = MathMin_2
                  spot = value59.spot
                end
              end
            end

            return spot or v292.spot
          end
        end
      end
    end
  end

  function v255.facing()
    local f69_2 = f69()

    if not f69_2 then
      return nil
    else
      local Origin_2 = v255.origin()
      local Vector3_5 = Vector3.new(f69_2.X - Origin_2.X, 0, f69_2.Z - Origin_2.Z)

      local Character_12 = localPlayer2.Character
        and localPlayer2.Character:FindFirstChild("HumanoidRootPart")

      if Character_12 then
        local Map_2 = workspaceService:FindFirstChild("Map")
        local BallCollideOnly_2 = Map_2 and Map_2:FindFirstChild("BallCollideOnly")
        local Net_2 = BallCollideOnly_2 and BallCollideOnly_2:FindFirstChild("Net")
        local Z_2 = Net_2 and Net_2.Position.Z

        if Z_2 then
          local v299 = Character_12.Position.Z > Z_2 and 1 or -1

          if Vector3_5.Z * v299 >= 0 then
            Vector3_5 = Vector3.new(
              f69_2.X - Character_12.Position.X, 0, f69_2.Z - Character_12.Position.Z
            )
          end

          if Vector3_5.Z * v299 >= 0 then
            Vector3_5 = Vector3.new(Vector3_5.X, 0, -v299 * math.max(math.abs(Vector3_5.Z), 1))
          end
        end
      end

      if Vector3_5.Magnitude < 0.01 then
        return nil
      end

      return Vector3_5.Unit
    end
  end

  function v255.installAim()
    if v255.aimed then
      return
    end

    local namecall4

    if not (getrawmetatable and setreadonly and getnamecallmethod) then
      return
    else
      local GetRawMetatable_4 = getrawmetatable(game)
      namecall4 = GetRawMetatable_4.__namecall
      setreadonly(GetRawMetatable_4, false)

      function GetRawMetatable_4.__namecall(p144, ...)
        local GetNamecallMethod_4 = getnamecallmethod()
        local v302 = { ... }

        if p144 == ballService.RF.Interact and GetNamecallMethod_4 == "InvokeServer" then
          local v303 = v302[1]

          if v255.enabled and type(v303) == "table"
            and (v303.Move == "Spike" or v303.Move == "ServeSpike") then
            local steer = v255.enabled and v255.steer or nil
            if typeof(steer) ~= "Vector3" and currentCamera2 then
              steer = currentCamera2.CFrame.LookVector
            end

            if typeof(steer) == "Vector3" then
              local Vector3_6 = Vector3.new(steer.X, 0, steer.Z)

              if Vector3_6.Magnitude > 0.01 then
                local New_2 = (Vector3_6.Unit - Vector3.new(0, 0.35, 0)).Unit
                if v255.enabled then
                  v303.LookVector = New_2
                  v303.Direction = New_2
                end

              end
            end
          end

          return namecall4(p144, v303)
        end

        return namecall4(p144, unpack(v302))
      end

      setreadonly(GetRawMetatable_4, true)
      v255.aimed = true
      return
    end
  end
end

local namecall5, v304

local function f70()
  v186 = true

  if v187 then
    return
  end

  if not (getrawmetatable and setreadonly and getnamecallmethod) then
    return
  end

  v304 = getrawmetatable(game)
  namecall5 = v304.__namecall
  setreadonly(v304, false)

  function v304.__namecall(p145, ...)
    local GetNamecallMethod_5 = getnamecallmethod()
    local v306 = { ... }

    if p145 == ballService.RF.Interact and GetNamecallMethod_5 == "InvokeServer" then
      local v307 = v306[1]

      if type(v307) == "table" and v307.Move == "Spike" and v186 then
        v307.Charge = 1
        v307.SpecialCharge = 1
        v307.HoldDuration = 1

        if type(v307.CustomClient) == "table" then
          v307.CustomClient.HoldDuration = 1
        else
          v307.CustomClient = { HoldDuration = 1 }
        end
      end

      return namecall5(p145, unpack(v306))
    end

    return namecall5(p145, ...)
  end

  setreadonly(v304, true)
  v187 = true
end

local function f71()
  v186 = false
end

v308 = {
  enabled = false,
  gui = nil,
  loopThread = nil,
  heartbeatLink = nil,
  state = {
    tp = false,
    block = false,
    spike = false,
    jump = false,
    interval = 0.05,
  },
  jumpState = false,
}

function v308.getRF(p146)
  local v309, v310 = pcall(function()
    return replicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.BallService.RF[p146]
  end)

  if v309 and v310 then
    return v310
  else
    local v311, v312 = pcall(function()
      local Packages = replicatedStorage:FindFirstChild("Packages")

      if not Packages then
        return nil
      else
        local Index = Packages:FindFirstChild("_Index")

        if not Index then
          return nil
        end

        for v313, v314 in Index:GetChildren() do
          if v314.Name:find("knit") then
            local Knit = v314:FindFirstChild("knit")

            if Knit then
              local Services = Knit:FindFirstChild("Services")

              local Services_2 = Services
              Services_2 = Services and Knit.Services:FindFirstChild("BallService")

              if Services_2 then
                local RF = Services_2:FindFirstChild("RF")

                if RF then
                  return RF:FindFirstChild(p146)
                end
              end
            end
          end
        end

        return nil
      end
    end)

    return v311 and v312 or nil
  end
end

v308.remotes = {
  CreateHitbox = v308.getRF("CreateHitbox"),
  Interact = v308.getRF("Interact"),
  Jump = v308.getRF("Jump"),
  UpdateTilt = v308.getRF("UpdateTilt"),
}

function v308.getBall()
  for index56, value61 in ipairs(workspaceService:GetDescendants()) do
    if typeof(value61.Name) == "string" and value61.Name:sub(1, 12) == "CLIENT_BALL_" then
      local IsType = value61:IsA("BasePart") and value61

      local BasePart = IsType
      BasePart = IsType or value61:FindFirstChildWhichIsA("BasePart", true)

      if BasePart then
        local Value_3 = value61:GetAttribute("ServerId")
          or BasePart:GetAttribute("ServerId") or value61:GetAttribute("Id")
          or BasePart:GetAttribute("Id") or tonumber(value61.Name:sub(13))

        if Value_3 then
          return BasePart, Value_3
        end
      end
    end
  end

  return nil, 0
end

function v308.getHRP()
  local Character_13 = localPlayer2.Character
  return Character_13 and Character_13:FindFirstChild("HumanoidRootPart")
end

function v308.timestamp()
  local v315, v316 = pcall(function() return workspaceService:GetServerTimeNow() end)

  if v315 and typeof(v316) == "number" then
    return v316
  end

  return tick()
end

function v308.buildGUI()
  local frame, textBox

  if v308.gui then
    return
  else
    local ScreenGui = Instance.new("ScreenGui")
    ScreenGui.Name = v176 .. "_Farm"
    ScreenGui.ResetOnSpawn = false

    hidegui(ScreenGui)

    if not ScreenGui.Parent then
      ScreenGui.Parent = localPlayer2:WaitForChild("PlayerGui")
    end

    frame = Instance.new("Frame")
    frame.Size = UDim2.new(0, 150, 0, 175)
    frame.Position = UDim2.new(0.05, 0, 0.3, 0)
    frame.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
    frame.BorderSizePixel = 0
    frame.Active = true
    frame.Draggable = true
    frame.Parent = ScreenGui

    local UICorner = Instance.new("UICorner")
    UICorner.CornerRadius = UDim.new(0, 8)
    UICorner.Parent = frame

    local TextLabel_3 = Instance.new("TextLabel")
    TextLabel_3.Size = UDim2.new(1, 0, 0, 22)
    TextLabel_3.BackgroundTransparency = 1
    TextLabel_3.Text = "Auto Farm"
    TextLabel_3.TextColor3 = Color3.fromRGB(238, 240, 248)
    TextLabel_3.Font = Enum.Font.GothamBold
    TextLabel_3.TextSize = 13
    TextLabel_3.Parent = frame

    local function f72(p147, p148, p149)
      local TextButton = Instance.new("TextButton")
      TextButton.Size = UDim2.new(0, 134, 0, 24)
      TextButton.Position = UDim2.new(0, 8, 0, p147)
      TextButton.BackgroundColor3 = Color3.fromRGB(55, 55, 55)
      TextButton.Text = p148 .. " OFF"
      TextButton.TextColor3 = Color3.fromRGB(238, 240, 248)
      TextButton.TextSize = 12
      TextButton.Font = Enum.Font.GothamBold
      TextButton.AutoButtonColor = false
      TextButton.Parent = frame

      local UICorner_2 = Instance.new("UICorner")
      UICorner_2.CornerRadius = UDim.new(0, 6)
      UICorner_2.Parent = TextButton

      TextButton.MouseButton1Click:Connect(function()
        v308.state[p149] = not v308.state[p149]
        TextButton.Text = p148 .. " " .. (v308.state[p149] and "ON" or "OFF")

        TextButton.BackgroundColor3 = v308.state[p149] and Color3.fromRGB(0, 140, 0)
          or Color3.fromRGB(55, 55, 55)
      end)
    end

    f72(26, "TP", "tp")
    f72(54, "BALL", "block")
    f72(82, "SPIKE", "spike")
    f72(110, "JUMP", "jump")

    textBox = Instance.new("TextBox")
    textBox.Size = UDim2.new(0, 134, 0, 24)
    textBox.Position = UDim2.new(0, 8, 0, 140)
    textBox.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
    textBox.Text = "0.05"
    textBox.PlaceholderText = "interval"
    textBox.TextColor3 = Color3.fromRGB(238, 240, 248)
    textBox.TextSize = 13
    textBox.Font = Enum.Font.GothamMedium
    textBox.ClearTextOnFocus = false
    textBox.Parent = frame

    local UICorner_3 = Instance.new("UICorner")
    UICorner_3.CornerRadius = UDim.new(0, 6)
    UICorner_3.Parent = textBox

    textBox:GetPropertyChangedSignal("Text"):Connect(function()
      v308.state.interval = tonumber(textBox.Text) or 0.05
    end)

    v308.gui = ScreenGui
    return
  end
end

function v308.destroyGUI()
  if v308.gui then
    v308.gui:Destroy()
    v308.gui = nil
  end
end

function v308.start()
  if v308.enabled then
    return
  end

  v308.enabled = true
  v308.buildGUI()

  if v308.heartbeatLink then
    v308.heartbeatLink:Disconnect()
  end

  v308.heartbeatLink = runService.Heartbeat:Connect(function()
    if not v308.enabled or not v308.state.tp then
      return
    end

    local GetBall = v308.getBall()
    local GetHRP = v308.getHRP()

    if GetBall and GetHRP then
      pcall(function() GetHRP.CFrame = GetBall.CFrame end)
    end
  end)

  f36(v308.heartbeatLink)

  v308.loopThread = task.spawn(function()
    while v308.enabled do
      local interval = v308.state.interval or 0.05
      local v319, v320 = v308.getBall()
      local GetHRP_2 = v308.getHRP()

      local LookVector_4 = currentCamera2 and currentCamera2.CFrame.LookVector
        or Vector3.new(0, 0, -1)

      local lookVector5 = GetHRP_2 and GetHRP_2.CFrame.LookVector or Vector3.zero
      local Vector3_7 = Vector3.new(0, 1, 0)
      local Timestamp = v308.timestamp()

      if v308.state.block and v320 ~= 0 and v319 and v308.remotes.CreateHitbox
        and v308.remotes.Interact then
        local Random = "Block" .. math.random(1000000, 9999999)

        pcall(function()
          v308.remotes.CreateHitbox:InvokeServer({
            BallId = v320,
            Charge = 1,
            Key = Random,
            ClientTimestamp = Timestamp,
            Move = "Block",
          })
        end)

        pcall(function()
          v308.remotes.Interact:InvokeServer({
            Charge = 1,
            Move = "Block",
            SpecialCharge = 0,
            TiltDirection = Vector3_7,
            BallId = v320,
            MoveDirection = lookVector5,
            Key = Random,
            From = "Client",
            LookVector = LookVector_4,
            Timestamp = Timestamp,
            ClientCanRunSpecial = false,
            CustomClient = {},
          })
        end)

        if v308.remotes.UpdateTilt then
          pcall(function() v308.remotes.UpdateTilt:InvokeServer(Vector3_7) end)
        end
      end

      if v308.state.spike and v320 ~= 0 and v319 and v308.remotes.Interact then
        local Vector3_8 = Vector3.new(LookVector_4.X, 1, LookVector_4.Z)

        pcall(function()
          v308.remotes.Interact:InvokeServer({
            Charge = 1,
            Move = "Spike",
            SpecialCharge = 0,
            TiltDirection = Vector3_8,
            LookVector = LookVector_4,
            MoveDirection = lookVector5,
            ClientCanRunSpecial = false,
            From = "Client",
            Timestamp = Timestamp,
            BallId = v320,
            CustomClient = {},
          })
        end)

        if v308.remotes.UpdateTilt then
          pcall(function() v308.remotes.UpdateTilt:InvokeServer(Vector3_8) end)
        end
      end

      if v308.state.jump and v308.remotes.Jump then
        v308.jumpState = not v308.jumpState
        pcall(function() v308.remotes.Jump:InvokeServer(v308.jumpState) end)
      end

      task.wait(interval)
    end
  end)
end

function v308.stop()
  v308.enabled = false

  if v308.heartbeatLink then
    v308.heartbeatLink:Disconnect()
    v308.heartbeatLink = nil
  end

  v308.loopThread = nil
  v308.state.tp = false
  v308.state.block = false
  v308.state.spike = false
  v308.state.jump = false
  v308.jumpState = false
  v308.destroyGUI()
end

v323 = {
  enabled = false,
  connection = nil,
  lookVector = nil,
  direction = nil,
  tilt = nil,
  mode = "Nearest",
}

function v323.isSameTeam(p150)
  local Team = localPlayer2.Team

  if not Team then
    return false
  end

  return p150.Team == Team
end

function v323.getTarget()
  local Character_14 = localPlayer2.Character

  if not Character_14 then
    return nil
  else
    local HumanoidRootPart_3 = Character_14:FindFirstChild("HumanoidRootPart")

-- https://discord.gg/AwGHNh7Z7T
    if not HumanoidRootPart_3 then
      return nil
    else
      local v324 = {}

      for index57, value62 in ipairs(players:GetPlayers()) do
        if value62 ~= localPlayer2 and v323.isSameTeam(value62) then
          local Character_15 = value62.Character

          if Character_15 then
            local HumanoidRootPart_4 = Character_15:FindFirstChild("HumanoidRootPart")
            local Humanoid_3 = Character_15:FindFirstChildOfClass("Humanoid")

            if HumanoidRootPart_4 and Humanoid_3 and Humanoid_3.Health > 0 then
              table.insert(v324, HumanoidRootPart_4)
            end
          end
        end
      end

      if #v324 == 0 then
        return nil
      elseif v323.mode == "Random" then
        return v324[math.random(1, #v324)]
      else
        local v325 = nil
        local MathHuge_3 = math.huge

        for index58, value63 in ipairs(v324) do
          local Magnitude_4 = (value63.Position - HumanoidRootPart_3.Position).Magnitude

          if Magnitude_4 < MathHuge_3 then
            v325 = value63
            MathHuge_3 = Magnitude_4
          end
        end

        return v325
      end
    end
  end
end

function v323.calculateDirection()
  local Character_16 = localPlayer2.Character

  if not Character_16 then
    v323.lookVector = nil
    v323.direction = nil
    v323.tilt = nil

    return
  else
    local HumanoidRootPart_5 = Character_16:FindFirstChild("HumanoidRootPart")

    if not HumanoidRootPart_5 then
      v323.lookVector = nil
      v323.direction = nil
      v323.tilt = nil

      return
    else
      local GetTarget = v323.getTarget()

      if not GetTarget then
        v323.lookVector = nil
        v323.direction = nil
        v323.tilt = nil

        return
      else
        local Position_2 = HumanoidRootPart_5.Position
        local Position_3 = GetTarget.Position
        local Vector3_9 = Vector3.new(Position_3.X - Position_2.X, 0, Position_3.Z - Position_2.Z)

        if Vector3_9.Magnitude < 0.01 then
          v323.lookVector = nil
          v323.direction = nil
          v323.tilt = nil

          return
        else
          local Unit_2 = Vector3_9.Unit

          v323.lookVector = Vector3.new(Unit_2.X, 0, Unit_2.Z)
          v323.direction = Vector3.new(Unit_2.X, 0, Unit_2.Z)
          v323.tilt = Vector3.new(Unit_2.X, 1, Unit_2.Z)

          return
        end
      end
    end
  end
end

function v323.fire()
  if not v323.lookVector then
    return false
  end

  local f65_2 = f65()

  if not f65_2 then
    return false
  end

  pcall(function()
    local Interact = ballService.RF.Interact
    local Workspace = workspace

    Interact:InvokeServer({
      Charge = 1,
      Move = "JumpSet",
      SpecialCharge = 1,
      TiltDirection = v323.tilt,
      LookVector = v323.lookVector,
      Direction = v323.direction,
      MoveDirection = Vector3.new(0, 0, 0),
      ClientCanRunSpecial = false,
      From = "Client",
      Timestamp = Workspace:GetServerTimeNow(),
      BallId = f65_2,
      CustomClient = {},
    })
  end)

  return true
end

function v323.start()
  if v323.connection then
    return
  end

  v323.connection = runService.Heartbeat:Connect(function()
    if v323.enabled then
      v323.calculateDirection()
    end
  end)

  f36(v323.connection)
end

function v323.stop()
  if v323.connection then
    v323.connection:Disconnect()
    v323.connection = nil
  end

  v323.lookVector = nil
  v323.direction = nil
  v323.tilt = nil
end

_G.AutoSet = v323

v329 = {
  enabled = false,
  connection = nil,
  namecallOld = nil,
  hooked = false,
  direction = nil,
  targetName = nil,
  mode = "Nearest",
}

function v329.isSameTeam(p151)
  local Team_2 = localPlayer2.Team

  if not Team_2 then
    return false
  end

  return p151.Team == Team_2
end

function v329.getTarget()
  local Character_17 = localPlayer2.Character

  if not Character_17 then
    return nil
  else
    local HumanoidRootPart_6 = Character_17:FindFirstChild("HumanoidRootPart")

    if not HumanoidRootPart_6 then
      return nil
    else
      local v330 = {}

      for index59, value64 in ipairs(players:GetPlayers()) do
        if value64 ~= localPlayer2 and v329.isSameTeam(value64) then
          local Character_18 = value64.Character

          if Character_18 then
            local HumanoidRootPart_7 = Character_18:FindFirstChild("HumanoidRootPart")
            local Humanoid_4 = Character_18:FindFirstChildOfClass("Humanoid")

            if HumanoidRootPart_7 and Humanoid_4 and Humanoid_4.Health > 0 then
              table.insert(v330, HumanoidRootPart_7)
            end
          end
        end
      end

      if #v330 == 0 then
        return nil
      elseif v329.mode == "Random" then
        return v330[math.random(1, #v330)]
      else
        local v331 = nil
        local MathHuge_4 = math.huge

        for index60, value65 in ipairs(v330) do
          local Magnitude_5 = (value65.Position - HumanoidRootPart_6.Position).Magnitude

          if Magnitude_5 < MathHuge_4 then
            MathHuge_4 = Magnitude_5
            v331 = value65
          end
        end

        return v331
      end
    end
  end
end

function v329.calculateDirection()
  local Character_19 = localPlayer2.Character

  if not Character_19 then
    v329.direction = nil
    v329.targetName = nil
    return
  else
    local HumanoidRootPart_8 = Character_19:FindFirstChild("HumanoidRootPart")

    if not HumanoidRootPart_8 then
      v329.direction = nil
      v329.targetName = nil
      return
    else
      local GetTarget_2 = v329.getTarget()

      if not GetTarget_2 then
        v329.direction = nil
        v329.targetName = nil
        return
      else
        local Position_4 = HumanoidRootPart_8.Position
        local Position_5 = GetTarget_2.Position
        local Vector3_10 = Vector3.new(Position_5.X - Position_4.X, 0, Position_5.Z - Position_4.Z)

        if Vector3_10.Magnitude < 0.01 then
          v329.direction = nil
          v329.targetName = nil
          return
        end

        v329.direction = Vector3_10.Unit
        v329.targetName = GetTarget_2.Parent.Name

        return
      end
    end
  end
end

function v329.start()
  if not ballService then
    return
  end

  if v329.connection then
    return
  end

  v329.connection = runService.Heartbeat:Connect(function()
    if v329.enabled then
      v329.calculateDirection()
    end
  end)

  f36(v329.connection)

  if v329.hooked then
    return
  end

  if not (getrawmetatable and setreadonly and getnamecallmethod) then
    return
  else
    local GetRawMetatable_5 = getrawmetatable(game)
    v329.namecallOld = GetRawMetatable_5.__namecall
    setreadonly(GetRawMetatable_5, false)

    function GetRawMetatable_5.__namecall(p152, ...)
      local GetNamecallMethod_6 = getnamecallmethod()
      local v335 = ...

      if v329.enabled and p152 == ballService.RF.Interact and GetNamecallMethod_6 == "InvokeServer" then
        if type(v335) == "table" and v335.Move == "JumpSet" then
          if v329.direction then
            v335.LookVector = Vector3.new(v329.direction.X, 0, v329.direction.Z)
            v335.TiltDirection = Vector3.new(v329.direction.X, 1, v329.direction.Z)
            v335.MoveDirection = Vector3.new(0, 0, 0)
          end
        end

        return v329.namecallOld(p152, v335)
      end

      return v329.namecallOld(p152, ...)
    end

    setreadonly(GetRawMetatable_5, true)
    v329.hooked = true
    return
  end
end

function v329.stop()
  if v329.connection then
    v329.connection:Disconnect()
    v329.connection = nil
  end

  v329.direction = nil
  v329.targetName = nil
end

_G.AimSet = v329

v336 = { lastCount = 0 }

function v336.cleanName(p153)
  return p153:gsub("^DFInt", ""):gsub("^DFFlag", ""):gsub("^FFFlag", ""):gsub("^FFlag", ""):gsub(
    "^FInt", ""
  ):gsub(
    "^FString", ""
  ):gsub(
    "^FLog", ""
  )
end

function v336.apply(p154)
  local v337

  if type(setfflag) ~= "function" then
    v174:Notify("setfflag is not supported in this executor")
    return 0
  else
    local v338, v339 = pcall(function() return httpService:JSONDecode(p154) end)

    if not v338 or type(v339) ~= "table" then
      v174:Notify("Invalid JSON")
      return 0
    else
      v337 = 0
      local count2 = 0

      for key8, value66 in pairs(v339) do
        local Key8 = key8
        local Value66 = value66
        count2 = count2 + 1

        if count2 % 15 == 0 then
          task.wait()
        end

        pcall(function()
          local CleanName = v336.cleanName(Key8)
          local v343

          if type(getfflag) == "function" then
            v343 = getfflag(CleanName)
          end

          if v343 ~= nil or type(getfflag) ~= "function" then
            setfflag(CleanName, tostring(Value66))
            v337 = v337 + 1
          end
        end)
      end

      v336.lastCount = v337
      v174:Notify("Applied " .. v337 .. " fflag(s)")
      return v337
    end
  end
end

function v336.example()
  return [[
{
  "DFIntTaskSchedulerTargetFps": "9999",
  "FFlagDebugGraphicsDisableDirect3D11": "True"
}]]
end

local v344 = {
  active = false,
  links = {},
  damped = {},
  paused = {},
  loud = {
    [Enum.AnimationPriority.Action] = true,
    [Enum.AnimationPriority.Action2] = true,
    [Enum.AnimationPriority.Action3] = true,
    [Enum.AnimationPriority.Action4] = true,
  },
}

function v344.gag(p155)
  if type(getconnections) ~= "function" then
    return
  else
    local v345, v346 = pcall(getconnections, p155)

    if not v345 or type(v346) ~= "table" then
      return
    end

    for index61, value67 in ipairs(v346) do
      local Value67 = value67

      pcall(function()
        if Value67.Enabled ~= false then
          Value67:Disable()
          v344.paused[#v344.paused + 1] = Value67
        end
      end)
    end

    return
  end
end

function v344.quiet(p156)
  if not p156:IsA("Sound") then
    return
  end

  v344.damped[#v344.damped + 1] = { inst = p156, level = p156.Volume }

  pcall(function()
    p156.Volume = 0
    p156:Stop()
  end)
end

function v344.start()
  if v344.active then
    return
  else
    v344.active = true
    v344.gag(effects.OnClientEvent)
    v344.gag(effect.OnClientEvent)
    v344.animUntil = os.clock() + 0.2

    local Character_20 = localPlayer2.Character

    local Character17 = Character_20
      and Character_20:FindFirstChildWhichIsA("Animator", true)

    if Character17 then
      for index62, value68 in ipairs(Character17:GetPlayingAnimationTracks()) do
      end

      local AnimationPlayed = Character17.AnimationPlayed

      v344.links[#v344.links + 1] = AnimationPlayed:Connect(function(p157)
        if not v344.active or os.clock() > v344.animUntil then
          return
        end
      end)
    end

    for index63, value69 in ipairs({ workspaceService, soundService, Character_20 }) do
      if value69 then
        local DescendantAdded = value69.DescendantAdded

        v344.links[#v344.links + 1] = DescendantAdded:Connect(function(p158)
          if v344.active then
            v344.quiet(p158)
          end
        end)
      end
    end

    return
  end
end

function v344.stop()
  if not v344.active then
    return
  end

  v344.active = false

  for index64, value70 in ipairs(v344.links) do
    local Value70 = value70
    pcall(function() Value70:Disconnect() end)
  end

  v344.links = {}

  for index65, value71 in ipairs(v344.paused) do
    local Value71 = value71
    pcall(function() Value71:Enable() end)
  end

  v344.paused = {}

  for index66, value72 in ipairs(v344.damped) do
    local Value72 = value72

    if Value72.inst.Parent then
      pcall(function() Value72.inst.Volume = Value72.level end)
    end
  end

  v344.damped = {}
end

local function f73()
  local Character_21 = localPlayer2.Character
    and localPlayer2.Character:FindFirstChild("HumanoidRootPart")

  local v351

  if not Character_21 then
    return nil
  else
    local v352, v353, v354 = v255.bounds()

    if not v352 then
      return nil
    else
      local Map_3 = workspaceService:FindFirstChild("Map")
      local BallCollideOnly_3 = Map_3 and Map_3:FindFirstChild("BallCollideOnly")
      local Net_3 = BallCollideOnly_3 and BallCollideOnly_3:FindFirstChild("Net")
      local Z_3 = Net_3 and Net_3.Position.Z or v352.Z
      local v355 = Net_3 and Net_3.Position.Y + Net_3.Size.Y * 0.5 or v354
      local Value_4 = localPlayer2.Team and localPlayer2.Team:GetAttribute("Index")

      if Value_4 == 1 then
        v351 = 1
      elseif Value_4 == 2 then
        v351 = -1
      else
        v351 = Character_21.Position.Z < Z_3 and 1 or -1
      end

      local f63_3 = f63()
      local Position_6 = f63_3 and f63_3.Position

      local Position7 = Position_6
      Position7 = Position_6 or Character_21.Position + Vector3.new(0, 6, 0)

      local MathAbs_2 = math.abs(Z_3 - Position7.Z)
      local MathMax_3 = math.max(MathAbs_2, 2)
      local MathClamp_4 = math.clamp(0.45 * (Position7.Y - v355) / MathMax_3, -0.05, 0.3)
      local MathMax_4 = math.max(v353.Z - 2, 1)

      local Vector3_11 = Vector3.new(
        v352.X + (Position7.X - v352.X) * 0.25, v354, v352.Z + v351 * MathMax_4 * 0.55
      )

      local Vector3_12 = Vector3.new(Vector3_11.X - Position7.X, 0, Vector3_11.Z - Position7.Z)

      if Vector3_12.Magnitude < 0.01 then
        return nil
      end

      return (Vector3_12.Unit - Vector3.new(0, MathClamp_4, 0)).Unit
    end
  end
end

local v362 = { steer = nil, expiry = 0, hooked = false }
local connect3

local function f74()
  if connect3 then
    connect3:Disconnect()
    connect3 = nil
  end

  v196 = false
end

function v362.install()
  if v362.hooked then
    return
  end

  local namecall6

  if not (getrawmetatable and setreadonly and getnamecallmethod) then
    return
  else
    local GetRawMetatable_6 = getrawmetatable(game)
    namecall6 = GetRawMetatable_6.__namecall
    setreadonly(GetRawMetatable_6, false)

    function GetRawMetatable_6.__namecall(p159, ...)
      local v364 = { ... }
      local GetNamecallMethod_7 = getnamecallmethod()

      if p159 == ballService.RF.Interact and GetNamecallMethod_7 == "InvokeServer" then
        local v366 = v364[1]
        local steer2 = v362.steer

        if type(v366) == "table" and typeof(steer2) == "Vector3" and os.clock() < v362.expiry then
          if v366.Move == "Spike" or v366.Move == "ServeSpike" then
            v366.LookVector = steer2
            v366.Direction = steer2

            local Vector3_13 = Vector3.new(steer2.X, 0, steer2.Z)

            if typeof(v366.TiltDirection) == "Vector3" and Vector3_13.Magnitude > 0.01 then
              local Vector3_14 = Vector3.new(v366.TiltDirection.X, 0, v366.TiltDirection.Z).Magnitude

              if Vector3_14 > 0.05 then
                local v367 = Vector3_13.Unit * Vector3_14
                v366.TiltDirection = Vector3.new(v367.X, v366.TiltDirection.Y, v367.Z)
              end
            end
          end
        end

        return namecall6(p159, v366)
      end

      return namecall6(p159, unpack(v364))
    end

    setreadonly(GetRawMetatable_6, true)
    v362.hooked = true
    return
  end
end

local function f75()
  local v368

  if not v188 then
    return
  elseif not firesignal then
    return
  else
    local DoMove = replicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.BallService.RE.DoMove
    v344.start()
    v368 = v178
    v178 = true
    f39(300)
    local f73_2 = f73() or currentCamera2.CFrame.LookVector

    v362.steer = f73_2
    v362.expiry = os.clock() + 0.8
    v362.install()

    firesignal(DoMove.OnClientEvent, "Spike", false, false, f73_2)

    task.spawn(function()
      task.wait(0.3)
      v178 = v368

      if v368 then
        f39(v179)
      else
        f37()
      end

      v344.stop()
    end)

    return
  end
end

local function f76()
  if connect3 then
    return
  end

  local DoMove_2 = replicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.BallService.RE.DoMove

  connect3 = userInputService.JumpRequest:Connect(function()
    if v196 then
      task.wait(0.03)

      if firesignal then
        firesignal(DoMove_2.OnClientEvent, "Spike", false, false)
      end
    end
  end)

  v196 = true
end

do
  local function f77()
    local ScreenGui_2 = Instance.new("ScreenGui")
    ScreenGui_2.Name = v176

    hidegui(ScreenGui_2)
    ScreenGui_2.ResetOnSpawn = false

    textButton2 = Instance.new("TextButton")
    textButton2.Size = UDim2.new(0, 50, 0, 50)
    textButton2.Position = UDim2.new(0.5, -25, 0.85, -25)
    textButton2.BackgroundColor3 = Color3.fromRGB(255, 165, 0)
    textButton2.Text = "Spike"
    textButton2.TextColor3 = Color3.fromRGB(255, 255, 255)
    textButton2.TextScaled = true
    textButton2.Font = Enum.Font.GothamBold
    textButton2.Parent = ScreenGui_2
    textButton2.BackgroundTransparency = 0.2
    textButton2.BorderSizePixel = 0
    textButton2.Selectable = false

    local UICorner_4 = Instance.new("UICorner")
    UICorner_4.CornerRadius = UDim.new(1, 0)
    UICorner_4.Parent = textButton2

    local v369 = false
    local position8, position9

    textButton2.InputBegan:Connect(function(input)
      if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
        v369 = true
        position8 = input.Position
        position9 = textButton2.Position

        input.Changed:Connect(function()
          if input.UserInputState == Enum.UserInputState.End then
            v369 = false
          end
        end)
      end
    end)

    textButton2.InputChanged:Connect(function(input2)
      if v369
        and (input2.UserInputType == Enum.UserInputType.MouseMovement
          or input2.UserInputType == Enum.UserInputType.Touch) then
        local v370 = input2.Position - position8

        textButton2.Position = UDim2.new(
          position9.X.Scale, position9.X.Offset + v370.X, position9.Y.Scale,
          position9.Y.Offset + v370.Y
        )
      end
    end)

    textButton2.MouseButton1Click:Connect(function() f75() end)
    textButton2.Visible = false

    return textButton2
  end

  textButton2 = f77()

  f36(userInputService.JumpRequest:Connect(function()
    if not v224 and not v225 then
      return
    end

    local Character_22 = localPlayer2.Character
    local v371

    if not Character_22 or not Character_22.PrimaryPart then
      return
    elseif os.clock() - (v228.__kazanaAt or 0) < 0.35 then
      return
    else
      v228.__kazanaAt = os.clock()
      v371 = v225
      local Effects_2 = replicatedStorage.Assets:FindFirstChild("Effects")

      local Effects3 = Effects_2
        and Effects_2:FindFirstChild(v371 and "KazanaWhite" or "KazanaBlue")

      if not Effects3 then
        return
      end

      v2090 = getthreadidentity and getthreadidentity()

      pcall(function()
        require(Effects3)(Character_22)
        require(replicatedStorage.Tools.Sound).fromName(v371 and "Kazana_White" or "Kazana_Blue")({})
      end)

      return
    end
  end))
end

local f78

local function f79()
  if not v191 then
    return
  else
    local Character_23 = localPlayer2.Character

    if not Character_23 then
      return
    else
      local HumanoidRootPart_9 = Character_23:FindFirstChild("HumanoidRootPart")

      if not HumanoidRootPart_9 then
        return
      else
        local v372 = 10
        local unit4 = nil
        local f63_4 = f63()

        if f63_4 then
          local Vector3_15 = Vector3.new(
            f63_4.Position.X - HumanoidRootPart_9.Position.X, 0,
            f63_4.Position.Z - HumanoidRootPart_9.Position.Z
          )

          if Vector3_15.Magnitude > 0.01 then
            unit4 = Vector3_15.Unit
            v372 = math.clamp(Vector3_15.Magnitude - 1, 0, 16)
          end
        end

        if not unit4 then
          local LookVector_5 = currentCamera2.CFrame.LookVector
          unit4 = Vector3.new(LookVector_5.X, 0, LookVector_5.Z).Unit
        end

        f78(unit4)

        tweenService:Create(HumanoidRootPart_9, TweenInfo.new(0.2, Enum.EasingStyle.Linear), {
          CFrame = CFrame.new(HumanoidRootPart_9.Position + unit4 * v372)
            * CFrame.Angles(0, math.rad(HumanoidRootPart_9.Orientation.Y), 0),
        }):Play()

        return
      end
    end
  end
end

function f78(direction)
  local v374 = getthreadidentity and getthreadidentity()

  pcall(function()
    require(replicatedStorage.Content.Effect):Play("KuraiDashFX")({
      Player = localPlayer2,
      Direction = direction,
    })
  end)
end

local function f80()
  local ScreenGui_3 = Instance.new("ScreenGui")
  ScreenGui_3.Name = v176

  hidegui(ScreenGui_3)
  ScreenGui_3.ResetOnSpawn = false

  textButton3 = Instance.new("TextButton")
  textButton3.Size = UDim2.new(0, 50, 0, 50)
  textButton3.Position = UDim2.new(0.15, -25, 0.8, -25)
  textButton3.BackgroundColor3 = Color3.fromRGB(255, 200, 0)
  textButton3.Text = "Dash"
  textButton3.TextColor3 = Color3.fromRGB(255, 255, 255)
  textButton3.TextScaled = true
  textButton3.Font = Enum.Font.GothamBold
  textButton3.Parent = ScreenGui_3
  textButton3.BackgroundTransparency = 0.2
  textButton3.BorderSizePixel = 0
  textButton3.Selectable = false

  local UICorner_5 = Instance.new("UICorner")
  UICorner_5.CornerRadius = UDim.new(1, 0)
  UICorner_5.Parent = textButton3

  local v375 = false
  local position10, position11

  textButton3.InputBegan:Connect(function(input3)
    if input3.UserInputType == Enum.UserInputType.MouseButton1
      or input3.UserInputType == Enum.UserInputType.Touch then
      v375 = true
      position10 = input3.Position
      position11 = textButton3.Position

      input3.Changed:Connect(function()
        if input3.UserInputState == Enum.UserInputState.End then
          v375 = false
        end
      end)
    end
  end)

  textButton3.InputChanged:Connect(function(input4)
    if v375
      and (input4.UserInputType == Enum.UserInputType.MouseMovement
        or input4.UserInputType == Enum.UserInputType.Touch) then
      local v376 = input4.Position - position10

      textButton3.Position = UDim2.new(
        position11.X.Scale, position11.X.Offset + v376.X, position11.Y.Scale,
        position11.Y.Offset + v376.Y
      )
    end
  end)

  textButton3.MouseButton1Click:Connect(f79)
  textButton3.Visible = false

  return textButton3
end

local function f81()
  if not ballService then
    return
  else
    local f65_3 = f65()

    if not f65_3 then
      return
    else
      local Vector3_16 = Vector3.new(0, -1, 0)
      local Interact_2 = ballService.RF.Interact

      if Interact_2 then
        Interact_2:InvokeServer({
          Charge = 1,
          Move = "Block",
          SpecialCharge = 0,
          TiltDirection = Vector3.new(-0.1260179579258, 1, 0.99202799797058),
          LookVector = Vector3_16,
          MoveDirection = Vector3.new(0, 0, 0),
          ClientCanRunSpecial = false,
          From = "Client",
          BallId = f65_3,
          Timestamp = tick(),
          CustomClient = {},
        })
      end

      return
    end
  end
end

f80()

local function f82()
  local ScreenGui_4 = Instance.new("ScreenGui")
  ScreenGui_4.Name = v176

  hidegui(ScreenGui_4)
  ScreenGui_4.ResetOnSpawn = false

  textButton4 = Instance.new("TextButton")
  textButton4.Size = UDim2.new(0, 50, 0, 50)
  textButton4.Position = UDim2.new(0.35, -25, 0.8, -25)
  textButton4.BackgroundColor3 = Color3.fromRGB(255, 50, 50)
  textButton4.Text = "Stop"
  textButton4.TextColor3 = Color3.fromRGB(255, 255, 255)
  textButton4.TextScaled = true
  textButton4.Font = Enum.Font.GothamBold
  textButton4.Parent = ScreenGui_4
  textButton4.BackgroundTransparency = 0.2
  textButton4.BorderSizePixel = 0
  textButton4.Selectable = false

  local UICorner_6 = Instance.new("UICorner")
  UICorner_6.CornerRadius = UDim.new(1, 0)
  UICorner_6.Parent = textButton4

  local v378 = false
  local position12, position13

  textButton4.InputBegan:Connect(function(input5)
    if input5.UserInputType == Enum.UserInputType.MouseButton1
      or input5.UserInputType == Enum.UserInputType.Touch then
      v378 = true
      position12 = input5.Position
      position13 = textButton4.Position

      input5.Changed:Connect(function()
        if input5.UserInputState == Enum.UserInputState.End then
          v378 = false
        end
      end)
    end
  end)

  textButton4.InputChanged:Connect(function(input6)
    if v378
      and (input6.UserInputType == Enum.UserInputType.MouseMovement
        or input6.UserInputType == Enum.UserInputType.Touch) then
      local v379 = input6.Position - position12

      textButton4.Position = UDim2.new(
        position13.X.Scale, position13.X.Offset + v379.X, position13.Y.Scale,
        position13.Y.Offset + v379.Y
      )
    end
  end)

  textButton4.MouseButton1Click:Connect(function() f81() end)
  textButton4.Visible = v189

  return textButton4
end

do
  local function f83()
    local v380 = {
      enabled = false,
      move = "Auto",
      netRange = 9,
      lateral = 14,
      reach = 16,
      delay = 0.05,
      cooldown = 0.5,
      autoJump = true,
    }

    local v381 = false
    local v382 = 0

    local function f84(p160)
      local v383 = getthreadidentity and getthreadidentity()
      return (pcall(p160))
    end

    local v384, gameController

    local function f85()
      if v384 and gameController then
        return true
      end

      f84(function()
        v384 = require(replicatedFirst.Controllers.GameController.Handlers)
        gameController = require(replicatedStorage.Packages.Knit).GetController("GameController")
      end)

      return v384 ~= nil and gameController ~= nil
    end

    local function f86()
      local Tagged = collectionService:GetTagged("Net")[1]

      if Tagged and Tagged:IsA("BasePart") then
        return Tagged
      else
        local Map_4 = workspaceService:FindFirstChild("Map")
        local BallCollideOnly_4 = Map_4 and Map_4:FindFirstChild("BallCollideOnly")
        return BallCollideOnly_4 and BallCollideOnly_4:FindFirstChild("Net")
      end
    end

    local function f87(p161, p162)
      local Team_3 = localPlayer2.Team
      local Value_5 = Team_3 and Team_3:GetAttribute("Index")

      if Value_5 == 1 then
        return -1
      end

      if Value_5 == 2 then
        return 1
      end

      return p161.Position.Z >= p162 and 1 or -1
    end

    local function f88(p163, p164)
      local Z_4 = p164.Position.Z
      local v386 = p164.Position.Y + p164.Size.Y * 0.5
      local f87_2 = f87(p163, Z_4)
      local v388 = (p163.Position.Z - Z_4) * f87_2

      if v388 < 0 or v388 > v380.netRange then
        return nil
      else
        local f63_5 = f63()

        if not f63_5 then
          return nil
        elseif f63_5.Position.Y < v386 - 3 then
          return nil
        elseif math.abs(f63_5.Position.Z - Z_4) > v380.netRange + 6 then
          return nil
        elseif math.abs(f63_5.Position.X - p163.Position.X) > v380.lateral then
          return nil
        else
          local Team_4 = localPlayer2.Team

          for index69, value73 in ipairs(players:GetPlayers()) do
            if value73 ~= localPlayer2 and (Team_4 == nil or value73.Team ~= Team_4) then
              local Character_24 = value73.Character

              local Character20 = Character_24

              Character20 = Character_24
                and Character_24:FindFirstChild("HumanoidRootPart")

              if Character20 and Character_24:GetAttribute("Jumping") then
                local v390 = (Character20.Position.Z - Z_4) * f87_2

                if v390 < 0 and -v390 <= v380.netRange + 4
                  and (f63_5.Position - Character20.Position).Magnitude <= v380.reach
                  and math.abs(Character20.Position.X - p163.Position.X) <= v380.lateral then
                  return f63_5, Z_4, f87_2
                end
              end
            end
          end

          return nil
        end
      end
    end

    local function f89(p165, p166, p167)
      if v380.move ~= "Auto" then
        return v380.move
      end

      if (p165.Position.Z - p166) * p167 > 0 then
        return "Spike"
      end

      return "Block"
    end

    local function f90(actionName)
      if not f85() then
        return
      end

      local States = v384.States

      if States.IsBusy:get() or States.IsStunned:get() or States.IsServing:get() then
        return
      end

      if not States.IsPlaying:get() then
        return
      end

      if replicatedStorage:GetAttribute("ServedByTeam") then
        return
      end

      v381 = true

      task.spawn(function()
        if v380.autoJump and not States.IsJumping:get() then
          f84(function() gameController:PerformJump() end)
        end

        if v380.delay > 0 then
          task.wait(v380.delay)
        end

        f84(function()
          gameController:DoMove({
            ActionName = actionName,
            IsAerial = true,
            InputState = Enum.UserInputState.Begin,
            Metadata = {},
          })
        end)

        v382 = os.clock()
        v381 = false
      end)
    end

    f36(runService.Heartbeat:Connect(function()
      if not v380.enabled or v381 then
        return
      elseif os.clock() - v382 < v380.cooldown then
        return
      else
        local Character_25 = localPlayer2.Character

        local Character21 = Character_25
          and Character_25:FindFirstChild("HumanoidRootPart")

        if not Character21 then
          return
        else
          local f86_2 = f86()

          if not f86_2 then
            return
          else
            local v392, v393, v394 = f88(Character21, f86_2)

            if not v392 then
              return
            end

            f90(f89(v392, v393, v394))
            return
          end
        end
      end
    end))

    return { state = v380 }
  end

  v395 = f83()
end

local f91

local function f92()
  local unit5

  if not ballService then
    return
  else
    local f65_4 = f65()

    if not f65_4 then
      return
    else
      local f91_2 = f91()

      if not f91_2 then
        return
      else
        local HumanoidRootPart_10 = f91_2.Character:FindFirstChild("HumanoidRootPart")

        local Character_26 = localPlayer2.Character
          and localPlayer2.Character:FindFirstChild("HumanoidRootPart")

        if not HumanoidRootPart_10 or not Character_26 then
          return
        else
          local Unit_3 = (HumanoidRootPart_10.Position - Character_26.Position).Unit
          local Vector3_17 = Vector3.new(Unit_3.X, 1, Unit_3.Z)
          local Vector3_18 = Vector3.new(Unit_3.X, 0, Unit_3.Z)

          if Vector3_18.Magnitude > 0 then
            unit5 = Vector3_18.Unit
          else
            unit5 = Vector3.new(0.1756955832243, 9.2147594443759e-8, -0.98444455862045)
          end

          local Interact_3 = ballService.RF.Interact

          if Interact_3 then
            Interact_3:InvokeServer({
              Charge = 1,
              Move = "JumpSet",
              SpecialCharge = 0.99999963647062,
              TiltDirection = Vector3_17,
              LookVector = unit5,
              MoveDirection = Vector3.new(0, 0, 0),
              ClientCanRunSpecial = false,
              From = "Client",
              Timestamp = tick(),
              BallId = f65_4,
              CustomClient = {},
            })
          end

          return
        end
      end
    end
  end
end

function f91()
  local MathHuge_5 = math.huge

  local Character_27 = localPlayer2.Character
    and localPlayer2.Character:FindFirstChild("HumanoidRootPart")

  if not Character_27 then
    return nil
  end

  local v398

  for index70, value74 in ipairs(players:GetPlayers()) do
    if value74 ~= localPlayer2 and value74.Team == localPlayer2.Team then
      local Character_28 = value74.Character

      if Character_28 then
        local HumanoidRootPart_11 = Character_28:FindFirstChild("HumanoidRootPart")

        if HumanoidRootPart_11 then
          local Magnitude_6 = (HumanoidRootPart_11.Position - Character_27.Position).Magnitude

          if Magnitude_6 < MathHuge_5 then
            MathHuge_5 = Magnitude_6
            v398 = value74
          end
        end
      end
    end
  end

  return v398
end

local function f93()
  local ScreenGui_5 = Instance.new("ScreenGui")
  ScreenGui_5.Name = v176

  hidegui(ScreenGui_5)
  ScreenGui_5.ResetOnSpawn = false

  textButton5 = Instance.new("TextButton")
  textButton5.Size = UDim2.new(0, 50, 0, 50)
  textButton5.Position = UDim2.new(0.65, -25, 0.8, -25)
  textButton5.BackgroundColor3 = Color3.fromRGB(50, 150, 255)
  textButton5.Text = "Aim"
  textButton5.TextColor3 = Color3.fromRGB(255, 255, 255)
  textButton5.TextScaled = true
  textButton5.Font = Enum.Font.GothamBold
  textButton5.Parent = ScreenGui_5
  textButton5.BackgroundTransparency = 0.2
  textButton5.BorderSizePixel = 0
  textButton5.Selectable = false

  local UICorner_7 = Instance.new("UICorner")
  UICorner_7.CornerRadius = UDim.new(1, 0)
  UICorner_7.Parent = textButton5

  local v399 = false
  local position14, position15

  textButton5.InputBegan:Connect(function(input7)
    if input7.UserInputType == Enum.UserInputType.MouseButton1
      or input7.UserInputType == Enum.UserInputType.Touch then
      v399 = true
      position14 = input7.Position
      position15 = textButton5.Position

      input7.Changed:Connect(function()
        if input7.UserInputState == Enum.UserInputState.End then
          v399 = false
        end
      end)
    end
  end)

  textButton5.InputChanged:Connect(function(input8)
    if v399
      and (input8.UserInputType == Enum.UserInputType.MouseMovement
        or input8.UserInputType == Enum.UserInputType.Touch) then
      local v400 = input8.Position - position14

      textButton5.Position = UDim2.new(
        position15.X.Scale, position15.X.Offset + v400.X, position15.Y.Scale,
        position15.Y.Offset + v400.Y
      )
    end
  end)

  textButton5.MouseButton1Click:Connect(function() f92() end)
  textButton5.Visible = v190

  return textButton5
end

do
  f36(runService.RenderStepped:Connect(function()
    if not v199 then
      if bodyVelocity then
        bodyVelocity:Destroy()
        bodyVelocity = nil
      end

      return
    else
      local Character_29 = localPlayer2.Character
      local Humanoid_5 = Character_29 and Character_29:FindFirstChildOfClass("Humanoid")

      local Character23 = Character_29
      Character23 = Character_29 and Character_29:FindFirstChild("HumanoidRootPart")

      local v401 = not Humanoid_5
      local HumanoidRootPart21 = Character23

      if v401 or not HumanoidRootPart21 then
        return
      else
        if not bodyVelocity or bodyVelocity.Parent ~= HumanoidRootPart21 then
          if bodyVelocity then
            bodyVelocity:Destroy()
          end

          bodyVelocity = Instance.new("BodyVelocity")
          bodyVelocity.Name = v176
          bodyVelocity.MaxForce = Vector3.zero
          bodyVelocity.Velocity = Vector3.zero
          bodyVelocity.P = 12500
          bodyVelocity.Parent = HumanoidRootPart21
        end

        local MoveDirection = Humanoid_5.MoveDirection

        if MoveDirection.Magnitude == 0 then
          if v228.__controls == nil then
            local v403, v404 = pcall(function()
              return require(localPlayer2.PlayerScripts.PlayerModule):GetControls()
            end)

            v228.__controls = v403 and v404 or false
          end

          if v228.__controls then
            local v405, vectorToWorldSpace = pcall(
              v228.__controls.GetMoveVector, v228.__controls
            )

            if v405 and typeof(vectorToWorldSpace) == "Vector3"
              and vectorToWorldSpace.Magnitude > 0 then
              local CurrentCamera_2 = workspaceService.CurrentCamera

              if CurrentCamera_2 then
                vectorToWorldSpace = CurrentCamera_2.CFrame:VectorToWorldSpace(vectorToWorldSpace)
              end

              MoveDirection = Vector3.new(vectorToWorldSpace.X, 0, vectorToWorldSpace.Z)
            end
          end
        end

        if Humanoid_5.FloorMaterial == Enum.Material.Air and MoveDirection.Magnitude > 0 then
          bodyVelocity.MaxForce = Vector3.new(math.huge, 0, math.huge)
          bodyVelocity.Velocity = MoveDirection.Unit * v200
        else
          bodyVelocity.MaxForce = Vector3.zero
          bodyVelocity.Velocity = Vector3.zero
        end

        return
      end
    end
  end))

  local function f94(p168)
    if not p168.Character or v194[p168] then
      return
    else
      local Color3_3 = Color3.fromRGB(255, 72, 72)

      local Highlight = Instance.new("Highlight")
      Highlight.Name = v176
      Highlight.Adornee = p168.Character
      Highlight.FillColor = Color3_3
      Highlight.FillTransparency = 0.72
      Highlight.OutlineTransparency = 0
      Highlight.OutlineColor = Color3_3
      Highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
      Highlight.Parent = p168.Character

      v194[p168] = Highlight
      return
    end
  end

  local function f95(p169)
    if p169 == localPlayer2 then
      return false
    end

    if not p169.Team or not localPlayer2.Team then
      return false
    end

    return p169.Team ~= localPlayer2.Team
  end

  local function f97(p170)
    if v195[p170] then
      for key9, value75 in pairs(v195[p170]) do
        value75:Disconnect()
      end

      v195[p170] = nil
    end

    f96(p170)
  end

  function f96(p171)
    if v194[p171] then
      v194[p171]:Destroy()
      v194[p171] = nil
    end
  end

  local function f98(p172)
    if p172 == localPlayer2 then
      return
    else
      local function f99(p173)
        f97(p172)
        local Humanoid_6 = p173:WaitForChild("Humanoid", 3)

        if not Humanoid_6 or not p173:FindFirstChild("Head") then
          return
        else
          local Connection_2 = Humanoid_6.StateChanged:Connect(function(p174, p175)
            if not v193 or not f95(p172) then
              f96(p172)
              return
            end

            if p175 == Enum.HumanoidStateType.Jumping or p175 == Enum.HumanoidStateType.Freefall then
              f94(p172)
            elseif p175 == Enum.HumanoidStateType.Landed
              or p175 == Enum.HumanoidStateType.Running then
              f96(p172)
            end
          end)

          local Connection_3 = runService.Heartbeat:Connect(function()
            if not v193 or not p172.Character or not f95(p172) then
              f96(p172)
              return
            else
              local GetState = Humanoid_6:GetState()

              if GetState == Enum.HumanoidStateType.Jumping
                or GetState == Enum.HumanoidStateType.Freefall then
                f94(p172)
              else
                f96(p172)
              end

              return
            end
          end)

          v195[p172] = { f36(Connection_2), f36(Connection_3) }
          return
        end
      end

      if p172.Character then
        f99(p172.Character)
      end

      f36(p172.CharacterAdded:Connect(f99))
      return
    end
  end

  for index71, value76 in ipairs(players:GetPlayers()) do
    f98(value76)
  end

  f36(players.PlayerAdded:Connect(f98))
end

local function f100()
  v197 = false
end

local namecall7, v406

local function f101()
  v197 = true

  if v198 then
    return
  end

  if not (getrawmetatable and setreadonly and getnamecallmethod) then
    return
  end

  v406 = getrawmetatable(game)
  namecall7 = v406.__namecall
  setreadonly(v406, false)

  function v406.__namecall(p176, ...)
    local GetNamecallMethod_8 = getnamecallmethod()
    local v408 = p176 == serve
    local V408 = v408
    local v410 = { ... }

    if v408 then
      V408 = GetNamecallMethod_8 == "InvokeServer" and v197
    end

    if V408 then
      v410[2] = 5
      return namecall7(p176, unpack(v410))
    end

    return namecall7(p176, ...)
  end

  setreadonly(v406, true)
  v198 = true
end

local connect6

local function f102()
  local primaryPart, humanoid6, metadata, gameController2, v411

  if not v192 then
    return
  else
    local Character_30 = localPlayer2.Character

    if not Character_30 or not Character_30.PrimaryPart then
      return
    end

    primaryPart = Character_30.PrimaryPart
    humanoid6 = Character_30:FindFirstChildOfClass("Humanoid")

    if not humanoid6 or humanoid6.Health <= 0 then
      return
    end

    metadata = { Acceleration = -10000, TerminalVelocity = -300, Duration = 2 }
    gameController2 = nil
    v2368 = getthreadidentity and getthreadidentity()

    pcall(function()
      local Module_2 = require(replicatedStorage.Content.Ability.LeadFeet)

      if type(Module_2) == "table" and type(Module_2.Metadata) == "table" then
        metadata = Module_2.Metadata
      end

      gameController2 = require(replicatedStorage.Packages.Knit).GetController("GameController")

      if gameController2 then
        gameController2.IsBusy:set(false)
      end

      require(replicatedStorage.Content.Effect):Play("LeadFeetFX")({ Player = localPlayer2 })
      require(replicatedFirst.Controllers.GameController.Actions.Move.Jump).stop()

      if gameController2 then
        gameController2.IsBusy:set(true)
      end
    end)

    if connect6 then
      connect6:Disconnect()
      connect6 = nil
    end

    v411 = os.clock() + (metadata.Duration or 2)

    connect6 = runService.Heartbeat:Connect(function(delta)
      if not primaryPart.Parent or humanoid6.FloorMaterial ~= Enum.Material.Air
        or os.clock() >= v411 then
        if gameController2 then
          gameController2.IsBusy:set(false)
        end

        if connect6 then
          connect6:Disconnect()
          connect6 = nil
        end

        return
      else
        local AssemblyLinearVelocity_2 = primaryPart.AssemblyLinearVelocity

        local MathMax_5 = math.max(AssemblyLinearVelocity_2.Y
          + (metadata.Acceleration or -10000) * delta, metadata.TerminalVelocity or -300)

        primaryPart.AssemblyLinearVelocity = Vector3.new(
          AssemblyLinearVelocity_2.X, MathMax_5, AssemblyLinearVelocity_2.Z
        )

        return
      end
    end)

    return
  end
end

do
  local function f103()
    local ScreenGui_6 = Instance.new("ScreenGui")
    ScreenGui_6.Name = v176

    hidegui(ScreenGui_6)
    ScreenGui_6.ResetOnSpawn = false

    textButton6 = Instance.new("TextButton")
    textButton6.Size = UDim2.new(0, 50, 0, 50)
    textButton6.Position = UDim2.new(0.25, -25, 0.8, -25)
    textButton6.BackgroundColor3 = Color3.fromRGB(0, 255, 200)
    textButton6.Text = "LF"
    textButton6.TextColor3 = Color3.fromRGB(255, 255, 255)
    textButton6.TextScaled = true
    textButton6.Font = Enum.Font.GothamBold
    textButton6.Parent = ScreenGui_6
    textButton6.BackgroundTransparency = 0.2
    textButton6.BorderSizePixel = 0
    textButton6.Selectable = false

    local UICorner_8 = Instance.new("UICorner")
    UICorner_8.CornerRadius = UDim.new(1, 0)
    UICorner_8.Parent = textButton6

    local v414 = false
    local position16, position17

    textButton6.InputBegan:Connect(function(input9)
      if input9.UserInputType == Enum.UserInputType.MouseButton1
        or input9.UserInputType == Enum.UserInputType.Touch then
        v414 = true
        position16 = input9.Position
        position17 = textButton6.Position

        input9.Changed:Connect(function()
          if input9.UserInputState == Enum.UserInputState.End then
            v414 = false
          end
        end)
      end
    end)

    textButton6.InputChanged:Connect(function(input10)
      if v414
        and (input10.UserInputType == Enum.UserInputType.MouseMovement
          or input10.UserInputType == Enum.UserInputType.Touch) then
        local v415 = input10.Position - position16

        textButton6.Position = UDim2.new(
          position17.X.Scale, position17.X.Offset + v415.X, position17.Y.Scale,
          position17.Y.Offset + v415.Y
        )
      end
    end)

    textButton6.MouseButton1Click:Connect(f102)
    textButton6.Visible = false

    return textButton6
  end

  f103()

  local function f104()
    -- Avoid requiring every game Item ModuleScript during startup. Some modules
    -- can be expensive or yield indefinitely, preventing the WindUI window from
    -- ever being created after the key is accepted. Use replicated asset names
    -- first; this is enough for the local jersey selector and does not invoke
    -- game module code.
    v211 = {}

    local assets = replicatedStorage:FindFirstChild("Assets")
    local jerseyAssets = assets and assets:FindFirstChild("Jersey")

    if jerseyAssets then
      for _, item in ipairs(jerseyAssets:GetChildren()) do
        table.insert(v211, item.Name)
      end
    end

    -- Fallback: list module names without requiring/executing them.
    if #v211 == 0 then
      local content = replicatedStorage:FindFirstChild("Content")
      local itemFolder = content and content:FindFirstChild("Item")
      local entities = itemFolder and itemFolder:FindFirstChild("Entities")

      if entities then
        for _, item in ipairs(entities:GetChildren()) do
          if item:IsA("ModuleScript") then
            table.insert(v211, item.Name)
          end
        end
      end
    end

    table.sort(v211)
    return v211
  end

  f104()
end

local function f105(p177, p178)
  local Character_31 = localPlayer2.Character

  if not Character_31 or not Character_31:FindFirstChild("UpperTorso") then
    return false
  end

  local Assets_3 = replicatedStorage:FindFirstChild("Assets")
  Assets_3 = Assets_3 and Assets_3:FindFirstChild("Jersey")

  if not Assets_3 then
    return false
  else
    if not v228.__jerseyHook then
      v228.__jerseyHook = localPlayer2.CharacterAdded:Connect(function(character26)
        v418 = nil

        if character26:WaitForChild("UpperTorso", 10) and v219 then
          task.wait(1)
          f105(jersey)
        end
      end)
    end

    local function f106()
      for index74, value79 in ipairs(Character_31:GetChildren()) do
        if value79.Name == "JerseyFront" or value79.Name == "JerseyBack"
          or value79.Name == "_jerseyInstances" or value79:IsA("Clothing")
          or value79:IsA("ShirtGraphic") then
          value79:Destroy()
        end
      end
    end

    if not v219 and p178 ~= true then
      local v419 = v226[Character_31]

      if v419 then
        f106()

        for index75, value80 in ipairs(v419) do
          local Clone = value80:Clone()

          if Clone:IsA("SurfaceGui") then
            Clone.Adornee = Character_31:FindFirstChild("UpperTorso")
          end

          Clone.Parent = Character_31
        end

        v226[Character_31] = nil
      end

      v418 = nil
      return true
    else
      if not v226[Character_31] then
        local v420 = {}

        for index76, value81 in ipairs(Character_31:GetChildren()) do
          if value81.Name == "JerseyFront" or value81.Name == "JerseyBack"
            or value81:IsA("Clothing") or value81:IsA("ShirtGraphic") then
            table.insert(v420, value81:Clone())
          end
        end

        v226[Character_31] = v420
      end

      local function f107()
        local Shirt = Character_31:FindFirstChildOfClass("Shirt")

        if not Shirt then
          return nil
        end

        for index77, value82 in ipairs(Assets_3:GetChildren()) do
          for index78, value83 in ipairs(value82:GetChildren()) do
            local Shirt_2 = value83:FindFirstChild("Shirt")

            if Shirt_2 and Shirt_2:IsA("Shirt") and Shirt_2.ShirtTemplate == Shirt.ShirtTemplate then
              return value83.Name
            end
          end
        end

        return nil
      end

      local v421, v422 = pcall(require, replicatedStorage.Tools.Jersey)

      if not v421 or type(v422) ~= "table" or not v422.set then
        return false
      else
        v418 = v418 or f107()

        local v423, v424 = pcall(v422.set, {
          Player = localPlayer2,
          Character = Character_31,
          Id = p177 or jersey,
          TeamName = v418,
        })

        if not v423 then
          warn("[LOCOPANI] jersey apply failed: " .. tostring(v424))
          return false
        end

        v418 = v418 or f107()
        return true
      end
    end
  end
end

local function f108()
  local Assets_4 = replicatedStorage:FindFirstChild("Assets")
  Assets_4 = Assets_4 and Assets_4:FindFirstChild("Ball")

  local f109

  if not Assets_4 then
    return
  else
    function f109(p178)
      local v425 = v227[p178]

      if v425 then
        v425:Destroy()
        v227[p178] = nil
      end

      local v426 = v226[p178]

      if v426 then
        for key10, value84 in pairs(v426) do
          local Key10 = key10
          local Value84 = value84

          if Key10.Parent then
            pcall(function() Key10[Value84.field] = Value84.value end)
          end
        end

        v226[p178] = nil
      end
    end

    local function f110(p179)
      local PrimaryPart = p179.PrimaryPart

      local PrimaryPart2 = PrimaryPart
      PrimaryPart2 = PrimaryPart or p179:FindFirstChildWhichIsA("BasePart")

      local Assets3 = Assets_4
      local BasePart2 = PrimaryPart2
      local v431 = not BasePart2
      local Child = Assets3:FindFirstChild(ball)
      local v432

      if v431 or not Child then
        return
      else
        f109(p179)
        local GetDescendants = p179.GetDescendants
        v432 = {}

        local function f111(p180, p181, p182)
          v432[p180] = { field = p181, value = p180[p181] }
          p180[p181] = p182
        end

        for index79, value85 in ipairs(GetDescendants(p179)) do
          if value85:IsA("BasePart") then
            if value85.Name ~= v176 then
              f111(value85, "Transparency", 1)
            end
          elseif value85:IsA("Decal") or value85:IsA("Texture") then
            f111(value85, "Transparency", 1)
          elseif value85:IsA("Trail") or value85:IsA("ParticleEmitter") or value85:IsA("Beam")
            or value85:IsA("Light") or value85:IsA("Smoke") or value85:IsA("Fire")
            or value85:IsA("Sparkles") then
            f111(value85, "Enabled", false)
          end
        end

        v226[p179] = v432

        local Clone_2 = Child:Clone()
        Clone_2.Name = v177
        Clone_2.Parent = p179

        local v433 = {}

        if Clone_2:IsA("BasePart") then
          v433[#v433 + 1] = Clone_2
        end

        for index80, value86 in ipairs(Clone_2:GetDescendants()) do
          if value86:IsA("BasePart") then
            v433[#v433 + 1] = value86
          end
        end

        local IsType_2 = Clone_2:IsA("Model") and Clone_2.PrimaryPart or nil

        if not IsType_2 then
          local v434 = nil

          for index81, value87 in ipairs(v433) do
            if value87:IsA("BasePart") then
              local Z_5 = value87.Size.X * value87.Size.Y * value87.Size.Z
              local MathAbs_3 = math.abs(value87.Size.X - value87.Size.Y) < 0.5

              local V436 = MathAbs_3
              V436 = MathAbs_3 and math.abs(value87.Size.Y - value87.Size.Z) < 0.5

              local V435 = Z_5

              if value87:IsA("Part") and value87.Shape == Enum.PartType.Ball then
                V435 = V435 * 6
              elseif V436 then
                V435 = V435 * 3
              end

              if not v434 or V435 > v434 then
                IsType_2 = value87
                v434 = V435
              end
            end
          end
        end

        if IsType_2 then
          local ToObjectSpace = Clone_2:GetPivot():ToObjectSpace(IsType_2.CFrame)
          Clone_2:PivotTo(BasePart2.CFrame * ToObjectSpace:Inverse())
        else
          Clone_2:PivotTo(BasePart2.CFrame)
        end

        for index82, value88 in ipairs(v433) do
          value88.Anchored = false
          value88.CanCollide = false
          value88.CanQuery = false
          value88.CanTouch = false
          value88.Massless = true

          local WeldConstraint = Instance.new("WeldConstraint")
          WeldConstraint.Part0 = BasePart2
          WeldConstraint.Part1 = value88
          WeldConstraint.Parent = value88
        end

        v227[p179] = Clone_2
        return
      end
    end

    local v439 = {}

    for key11 in pairs(v227) do
      table.insert(v439, key11)
    end

    for index83, value89 in ipairs(v439) do
      f109(value89)
    end

    if not v220 then
      return
    end

    for index84, value90 in ipairs(workspaceService:GetChildren()) do
      if value90:IsA("Model") and value90.Name:match("^CLIENT_BALL_") then
        f110(value90)
      end
    end

    if not v228.__ballHook then
      v228.__ballHook = workspaceService.ChildAdded:Connect(function(child6)
        if not v220 or not child6:IsA("Model") or not child6.Name:match("^CLIENT_BALL_") then
          return
        end

        task.spawn(function()
          local count3 = 0

          while true do
            count3 = 1 + count3

            if not (40 >= count3) then
              break
            end

            if child6.PrimaryPart or child6:FindFirstChildWhichIsA("BasePart") then
              break
            end

            task.wait(0.05)
          end

          if v220 and child6.Parent then
            f108()
          end
        end)
      end)
    end

    return
  end
end

v440 = { enabled = false, hooked = false, charge = 1 }

function v440.effect(isStrong)
  local Character_32 = localPlayer2.Character
  local v441 = not Character_32
  local superDive

  if v441 or not Character_32.PrimaryPart then
    return
  else
    local Assets_5 = replicatedStorage:FindFirstChild("Assets")
    local Effects_3 = Assets_5 and Assets_5:FindFirstChild("Effects")
    superDive = Effects_3 and Effects_3:FindFirstChild("SuperDive")

    if not superDive then
      return
    end

    v2599 = getthreadidentity and getthreadidentity()
    pcall(function() task.spawn(require(superDive), Character_32, { IsStrong = isStrong }) end)
    return
  end
end

function v440.install()
  local dive

  if v440.hooked then
    return
  else
    local v442, v443 = pcall(require, replicatedStorage.Packages.Knit)

    if not v442 then
      return
    else
      local v444, v445 = pcall(v443.GetController, "GameController")

      if not v444 or type(v445) ~= "table" or type(v445.Dive) ~= "function" then
        return
      end

      dive = v445.Dive

      function v445.Dive(p183, p184, ...)
        local P184 = p184

        if not v440.enabled then
          return dive(p183, P184, ...)
        else
          local MathClamp_5 = math.clamp(v440.charge, 0, 1)
          local v448, v449 = pcall(require, replicatedStorage.Content.Style.Kimiro.Special)
          local Metadata = v448 and type(v449) == "table" and v449.Metadata

          if type(Metadata) == "table" then
            P184 = type(P184) == "table" and P184 or {}
            P184.MaxForce = Metadata.MaxForce
            P184.TimeScale = Metadata.TimeScale
            P184.StretchSpeedFactor = Metadata.StretchSpeedFactor
            P184.EasingStyle = Metadata.EasingStyle
            P184.Debounce = Metadata.Debounce

            if not P184.Target and typeof(Metadata.Power) == "NumberRange" then
              local Character_33 = localPlayer2.Character

              local Character28 = Character_33
              Character28 = Character_33 and Character_33:FindFirstChildOfClass("Humanoid")

              local moveDirection2 = Character28 and Character28.MoveDirection or Vector3.zero

              if moveDirection2.Magnitude < 0.5 and Character_33 then
                moveDirection2 = Character_33:GetPivot().LookVector
              end

              local Vector3_19 = Vector3.new(moveDirection2.X, 0, moveDirection2.Z)

              if Vector3_19.Magnitude > 0.01 then
                P184.Target = Vector3_19.Unit
                  * (Metadata.Power.Min + (Metadata.Power.Max - Metadata.Power.Min) * MathClamp_5)
              end
            end
          end

          local dive_2 = dive(p183, P184, ...)

          if dive_2 ~= nil then
            v440.effect(MathClamp_5 >= 0.5)
          end

          return dive_2
        end
      end

      v440.hooked = true
      return
    end
  end
end

v451 = { real = nil, want = {}, selected = {}, selectedItems = {}, featureEnabled = {}, controlEnabled = false }

function v451.mark(p185, p186)
  -- Legacy Visuals changers unlock their matching cosmetic category locally.
  -- Build the desired inventory from the actual feature toggles; v451.selected
  -- is reserved for selection/equip state and is not the toggle registry.
  v451.featureEnabled = v451.featureEnabled or {}
  v451.featureEnabled[p185] = p186 == true
  v451.want = {}
  for featureType, featureEnabled in pairs(v451.featureEnabled) do
    if featureEnabled == true then
      v451.want[featureType] = true
    end
  end

  if v451.controlEnabled == true or next(v451.want) ~= nil or v451.unlockAllJerseys == true then
    v451.wear()
  end

  local v452, v453 = pcall(require, replicatedStorage.Packages.Knit)
  local v454

  if not v452 then
    return
  else
    local v455, v456 = pcall(v453.GetController, "InventoryController")

    if not v455 or type(v456) ~= "table" or not v456.Inventory then
      return
    else
      local v457, v458 = pcall(function() return v456.Inventory:get() end)

      if not v457 or type(v458) ~= "table" then
        return
      else
        local TypeName_4 = type(getgenv) == "function" and getgenv() or _G

        local TypeName_5 = type(TypeName_4.LOCOPANI_SESSION) == "table" and TypeName_4.LOCOPANI_SESSION
          or nil

        if not v451.real then
          local vault2 = TypeName_5 and TypeName_5.vault or nil

          if vault2 and vault2.inventory then
            v451.real = vault2.inventory
            v451.realTitle = vault2.title
            v451.realEquipped = vault2.equipped or {}
          else
            local v459 = {}

            for key12, value91 in pairs(v458) do
              v459[key12] = value91
            end

            v451.real = v459
            v451.realTitle = localPlayer2:GetAttribute("User_Title")

            local v460, v461 = pcall(function() return v456.Equipped:get() end)
            local v462 = {}

            if v460 and type(v461) == "table" then
              for key13, value92 in pairs(v461) do
                v462[key13] = value92
              end
            end

            v451.realEquipped = v462

            if TypeName_5 then
              TypeName_5.vault = {
                inventory = v451.real,
                title = v451.realTitle,
                equipped = v451.realEquipped,
              }
            end
          end
        end

        local v463 = v451.controlEnabled == true or next(v451.want) ~= nil or v451.unlockAllJerseys == true

        if not v463 then
          pcall(function() v456.Inventory:set(v451.real) end)
          v451.real = nil

          if TypeName_5 then
            TypeName_5.vault = nil
          end

          return
        else
          local v467, v468 = pcall(require, replicatedStorage.Content.Item)
          local Item = replicatedStorage.Content.Item
          local v469 = not v467
          local Entities_3 = Item:FindFirstChild("Entities")

          if v469 or not Entities_3 then
            return
          end

          v454 = {}

          local function itemType(itemName)
            local itemModule = Entities_3:FindFirstChild(itemName)
            if itemModule and itemModule:IsA("ModuleScript") then
              local okItem, itemData = pcall(require, itemModule)
              if okItem and type(itemData) == "table" then
                return itemData.Type
              end
            end
            return nil
          end

          local controlledTypes = {
            PlayerCard = true,
            Card = true,
            Ball = true,
            ScoreEffect = true,
            Jersey = true,
          }

          local function isControlledCosmetic(itemName)
            -- First check the dropdown lists (this also covers asset-only cosmetics).
            for _, list in ipairs({ v210 or {}, v212 or {}, v205 or {}, v451.titleNames or {}, v211 or {}, v451.jerseyNames or {} }) do
              for _, listedName in ipairs(list) do
                if listedName == itemName then return true end
              end
            end
            -- Then classify by the actual inventory Item module type. This
            -- catches score effects/cards omitted from the old dropdown lists.
            local kind = itemType(itemName)
            if kind and controlledTypes[kind] == true then return true end
            -- Fallback for cosmetic inventory entries whose Item module is
            -- missing or uses a nonstandard Type field.
            local lowered = string.lower(tostring(itemName))
            return string.find(lowered, "playercard", 1, true) ~= nil
              or string.find(lowered, "card", 1, true) ~= nil
              or string.find(lowered, "ball", 1, true) ~= nil
              or string.find(lowered, "scoreeffect", 1, true) ~= nil
              or string.find(lowered, "groundhit", 1, true) ~= nil
              or string.find(lowered, "title", 1, true) ~= nil
              or string.find(lowered, "jersey", 1, true) ~= nil
          end

          for key14, value93 in pairs(v451.real) do
            if v451.controlEnabled ~= true or not isControlledCosmetic(key14)
              or (v451.selectedItems and v451.selectedItems[key14]) then
              v454[key14] = value93
            end
          end

          -- Visual-only inventory unlock: add every known jersey to the local
          -- inventory view without changing the Equipped store or calling Equip.
          if v451.unlockAllJerseys == true then
            for _, jerseyName in ipairs(v451.jerseyNames or v211 or {}) do
              if type(jerseyName) == "string" and jerseyName ~= "" then
                v454[jerseyName] = (v451.real and v451.real[jerseyName]) or 1
              end
            end
          end

          if v451.controlEnabled == true then
            -- Explicitly add every selected item, including Ball models that
            -- do not have a matching ModuleScript under Content.Item.Entities.
            for itemName, enabled in pairs(v451.selectedItems or {}) do
              if enabled then
                v454[itemName] = (v451.real and v451.real[itemName]) or 1
              end
            end
          else
            -- Preserve the pre-existing visual unlock behavior when the
            -- separate legacy changer toggles are used.
            for index85, value94 in ipairs(Entities_3:GetChildren()) do
              if value94:IsA("ModuleScript") and not v454[value94.Name] then
                local v470, v471 = pcall(require, value94)
                if v470 and type(v471) == "table" and v471.Type then
                  for key15 in pairs(v451.want) do
                    if v471.Type == v468.Type[key15] then
                      v454[value94.Name] = 1
                      break
                    end
                  end
                end
              end
            end
          end

          pcall(function() v456.Inventory:set(v454) end)
          return
        end
      end
    end
  end
end

function v451.typeOf(p187)
  local content = replicatedStorage:FindFirstChild("Content")
  local itemFolder = content and content:FindFirstChild("Item")
  local entities = itemFolder and itemFolder:FindFirstChild("Entities")
  local child = entities and entities:FindFirstChild(p187)
  if child and child:IsA("ModuleScript") then
    local okItem, itemData = pcall(require, child)
    if okItem and type(itemData) == "table" and itemData.Type then
      return itemData.Type, itemData
    end
  end
  -- Asset-only cosmetics don't always have an Item.Entity module.
  for _, name in ipairs(v210 or {}) do
    if name == p187 then return "PlayerCard", { DisplayName = p187 } end
  end
  for _, name in ipairs(v205 or {}) do
    if name == p187 then return "ScoreEffect", { DisplayName = p187 } end
  end
  for _, name in ipairs(v212 or {}) do
    if name == p187 then return "Ball", { DisplayName = p187 } end
  end
  for _, name in ipairs(v451.titleNames or {}) do
    if name == p187 then return "Title", { DisplayName = p187 } end
  end
  -- Jerseys are listed from Content.Item.Entities or Assets.Jersey, so they
  -- may be visible locally even when the server inventory does not own them.
  for _, name in ipairs(v451.jerseyNames or v211 or {}) do
    if name == p187 then return "Jersey", { DisplayName = p187, Id = p187 } end
  end
  return nil
end

function v451.paint(p188, p189, p190)
  local realEquipped = v451.realEquipped or {}

  if p188 == "Title" then
    pcall(function()
      localPlayer2:SetAttribute(
        "User_Title", p189 and (p190 and p190.DisplayName or p189) or v451.realTitle
      )
    end)
  elseif p188 == "ScoreEffect" then
    scoreEffect = p189 or realEquipped.ScoreEffect or "SupernovaScoreEffect"
  elseif p188 == "Ball" then
    ball = p189 or realEquipped.Ball or "ClassicBall"
    task.spawn(function() pcall(f108) end)
  elseif p188 == "Jersey" then
    if p189 then
      -- Equipping from either inventory uses the local visual setter directly;
      -- it must not depend on the separate Auto Apply Jersey toggle.
      jersey = p189
      v418 = nil
      task.spawn(function() pcall(f105, jersey, true) end)
    else
      -- On unequip/revert, restore the original local appearance unless
      -- Auto Apply Jersey is enabled, in which case re-apply the chosen jersey.
      jersey = realEquipped.Jersey or "DragonTuxedoJersey"
      v418 = nil
      task.spawn(function() pcall(f105, jersey, v219 == true) end)
    end
  elseif p188 == "PlayerCard" then
    if p189 then
      v207 = p189
    end
  end
end

function v451.setSlot(p191, p192)
  -- Visual-only equip: update the local Equipped store so the UI/game client
  -- reacts to the selected cosmetic without claiming ownership on the server.
  local okKnit, Knit = pcall(require, replicatedStorage.Packages.Knit)
  if not okKnit or not Knit then return false end

  local okController, inventoryController = pcall(Knit.GetController, "InventoryController")
  if not okController or type(inventoryController) ~= "table" or not inventoryController.Equipped then
    return false
  end

  local okEquipped, currentEquipped = pcall(function()
    return inventoryController.Equipped:get()
  end)
  if not okEquipped or type(currentEquipped) ~= "table" then return false end

  local updatedEquipped = {}
  for key, value in pairs(currentEquipped) do
    updatedEquipped[key] = value
  end

  if p192 == nil or p192 == false or p192 == "" then
    updatedEquipped[p191] = nil
  else
    updatedEquipped[p191] = p192
  end

  local okSet = pcall(function()
    inventoryController.Equipped:set(updatedEquipped)
  end)
  if not okSet then return false end

  -- Keep v451.realEquipped unchanged: it stores the player's original items
  -- so the visual spoof can be reverted cleanly when the toggle is disabled.
  return true
end

function v451.currentSlot(p193)
  local v480, v481 = pcall(require, replicatedStorage.Packages.Knit)
  local v482

  if not v480 then
    return nil
  else
    local v483
    v483, v482 = pcall(v481.GetController, "InventoryController")

    if not v483 or type(v482) ~= "table" or not v482.Equipped then
      return nil
    else
      local v484, v485 = pcall(function() return v482.Equipped:get() end)

      if v484 and type(v485) == "table" then
        return v485[p193]
      end

      return nil
    end
  end
end

function v451.dress(p194)
  local v486, v487 = v451.typeOf(p194)

  if not v486 then
    return false
  end

  if v486 == "Title" or v486 == "ScoreEffect" or v486 == "Ball" or v486 == "Jersey"
    or v486 == "PlayerCard" then
    v451.paint(v486, p194, v487)
    v451.setSlot(v486, p194)
    return true
  end

  if v486 ~= "ProfileArt" then
    return false
  end

  v451.setSlot(v486, p194)
  return true
end

function v451.revert(p195)
  local realEquipped2 = v451.realEquipped and v451.realEquipped[p195] or nil
  v451.paint(p195, nil)
  v451.setSlot(p195, realEquipped2)
end

function v451.wear()
  if v451.worn then
    return
  end

  local v488, namecall8

  if not (getrawmetatable and setreadonly and getnamecallmethod) then
    return
  else
    local v489

    v489, v488 = pcall(function()
      return replicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.InventoryService.RF.Equip
    end)

    if not v489 or not v488 then
      return
    else
      local GetRawMetatable_7 = getrawmetatable(game)
      namecall8 = GetRawMetatable_7.__namecall
      setreadonly(GetRawMetatable_7, false)

      function GetRawMetatable_7.__namecall(p196, ...)
        local v491 = { ... }

        if p196 == v488 and getnamecallmethod() == "InvokeServer" then
          local v492 = v491[1]

          if type(v492) == "string" and v451.real then
            local v493, v494 = v451.typeOf(v492)

            if not v451.real[v492] then
              if v493 and v451.currentSlot(v493) == v492 then
                v451.revert(v493)
                return true
              end

              v451.dress(v492)
              return true
            elseif v493 then
              v451.paint(v493, v492, v494)
            end
          end

          return namecall8(p196, unpack(v491))
        end

        return namecall8(p196, unpack(v491))
      end

      setreadonly(GetRawMetatable_7, true)
      v451.worn = true
      return
    end
  end
end

v495 = {
  enabled = false,
  marker = nil,
  label = nil,
  tracked = nil,
  last = nil,
  stamp = 0,
  drift = Vector3.zero,
}

function v495.clear()
  if v495.marker then
    v495.marker:Destroy()
    v495.marker = nil
    v495.label = nil
  end

  v495.tracked = nil
  v495.last = nil
  v495.drift = Vector3.zero
end

function v495.build()
  local Part_2 = Instance.new("Part")
  Part_2.Name = v176
  Part_2.Shape = Enum.PartType.Cylinder
  Part_2.Size = Vector3.new(0.2, 7, 7)
  Part_2.Anchored = true
  Part_2.CanCollide = false
  Part_2.CanQuery = false
  Part_2.CanTouch = false
  Part_2.Material = Enum.Material.Neon
  Part_2.Transparency = 0.35
  Part_2.CastShadow = false
  Part_2.Parent = currentCamera2

  local BillboardGui = Instance.new("BillboardGui")
  BillboardGui.Size = UDim2.new(0, 90, 0, 30)
  BillboardGui.StudsOffset = Vector3.new(0, 4, 0)
  BillboardGui.AlwaysOnTop = true
  BillboardGui.Parent = Part_2

  local TextLabel_4 = Instance.new("TextLabel")
  TextLabel_4.Size = UDim2.fromScale(1, 1)
  TextLabel_4.BackgroundTransparency = 1
  TextLabel_4.TextScaled = true
  TextLabel_4.Font = Enum.Font.GothamBold
  TextLabel_4.TextStrokeTransparency = 0
  TextLabel_4.Parent = BillboardGui

  v495.marker = Part_2
  v495.label = TextLabel_4
end

function v495.gravity()
  local v496, v497 = pcall(function()
    local Module_5 = require(replicatedStorage.Configuration.Game)
    local Module_6 = require(replicatedStorage.Common.State)
    return Module_6.get(replicatedStorage, Module_6.Id.Modifier, "BallGravity", Module_5.Physics.Gravity)
  end)

  if v496 and type(v497) == "number" and v497 > 0 then
    return v497
  end

  return 17
end

function v495.velocity(p197)
  local v500, v501 = pcall(require, replicatedStorage.Packages.Knit)

  if v500 then
    local v502, v503 = pcall(v501.GetController, "BallController")

    if v502 and type(v503) == "table" and type(v503.ActiveBalls) == "table" then
      for key17, value96 in pairs(v503.ActiveBalls) do
        local Ball_2 = value96.Ball

        if Ball_2 and Ball_2.Parent and Ball_2:IsAncestorOf(p197)
          and typeof(value96.Velocity) == "Vector3" then
          return value96.Velocity
        end
      end
    end

    return v495.drift
  end

  return v495.drift
end

function v495.solve(p198, p199, p200, p201)
  local v504 = p198.Y - p201

  if v504 < 0 then
    return nil
  else
    local v505 = p199.Y * p199.Y + 2 * p200 * v504

    if v505 < 0 then
      return nil
    else
      local Sqrt = (p199.Y + math.sqrt(v505)) / p200

      if Sqrt ~= Sqrt or Sqrt <= 0 or Sqrt > 15 then
        return nil
      end

      return Sqrt
    end
  end
end

function v495.netHit(p202, p203, p204, p205)
  local Map_5 = workspaceService:FindFirstChild("Map")
  local BallCollideOnly_5 = Map_5 and Map_5:FindFirstChild("BallCollideOnly")
  local Net_4 = BallCollideOnly_5 and BallCollideOnly_5:FindFirstChild("Net")

  if not Net_4 then
    return false
  else
    local Z_6 = Net_4.Position.Z - p202.Z

    if math.abs(p203.Z) < 0.01 then
      return false
    else
      local Z_7 = Z_6 / p203.Z

      if Z_7 <= 0 or Z_7 >= p205 then
        return false
      else
        local v509 = p202.Y + p203.Y * Z_7 - 0.5 * p204 * Z_7 * Z_7
        local v510 = p202.X + p203.X * Z_7

        if v509 > Net_4.Position.Y + Net_4.Size.Y * 0.5
          or v509 < Net_4.Position.Y - Net_4.Size.Y * 0.5 then
          return false
        end

        return math.abs(v510 - Net_4.Position.X) <= Net_4.Size.X * 0.5
      end
    end
  end
end

function v495.predict(p206)
  local v511, v512 = pcall(require, replicatedStorage.Common.Physics)

  if not v511 then
    return nil
  else
    local Gravity = v495.gravity()
    local Position_7 = p206.Position
    local Velocity = v495.velocity(p206)

    if typeof(Velocity) ~= "Vector3" then
      return nil
    else
      local LastFloorHeight = v512.LastFloorHeight

      if not LastFloorHeight then
        local v515, v516 = pcall(v512.calculateFloorHeight, Position_7, true)
        LastFloorHeight = v515 and v516 or nil
      end

      if not LastFloorHeight then
        return nil
      else
        local Solve = v495.solve(Position_7, Velocity, Gravity, LastFloorHeight)

        if not Solve then
          return nil
        else
          local Vector3_20 = Vector3.new(
            Position_7.X + Velocity.X * Solve, LastFloorHeight, Position_7.Z + Velocity.Z * Solve
          )

          local v518, v519 = pcall(
            v512.calculateFloorHeight, Vector3.new(Vector3_20.X, Position_7.Y, Vector3_20.Z), true
          )

          if v518 and type(v519) == "number" and math.abs(v519 - LastFloorHeight) > 0.05 then
            local Solve_2 = v495.solve(Position_7, Velocity, Gravity, v519)

            if Solve_2 then
              Solve = Solve_2

              Vector3_20 = Vector3.new(
                Position_7.X + Velocity.X * Solve, v519, Position_7.Z + Velocity.Z * Solve
              )
            end
          end

          return Vector3_20, v512, Solve, v495.netHit(Position_7, Velocity, Gravity, Solve)
        end
      end
    end
  end
end

local RenderStepped = runService.RenderStepped

local function f112(p207)
  v201 = p207

  if not p207 then
    local Character_34 = localPlayer2.Character

    if Character_34 then
      local Humanoid_7 = Character_34:FindFirstChild("Humanoid")

      if Humanoid_7 and not (v255 and v255.enabled) then
        Humanoid_7.AutoRotate = true -- FIX: antes setava false e travava a rotacao/shiftlock
      end
    end
  end
end

f36(RenderStepped:Connect(function()
  local v521, color5

  if not v495.enabled then
    if v495.marker then
      v495.clear()
    end

    return
  else
    local f63_6 = f63()

    if not f63_6 then
      if v495.marker then
        v495.marker.Transparency = 1
      end

      v495.last = nil
      return
    else
      local OsClock = os.clock()

      if v495.tracked == f63_6 and v495.last and OsClock > v495.stamp then
        v495.drift = (f63_6.Position - v495.last) / (OsClock - v495.stamp)
      end

      v495.tracked = f63_6
      v495.last = f63_6.Position
      v495.stamp = OsClock

      local v524, v525, v526, v527 = v495.predict(f63_6)

      if not v524 then
        if v495.marker then
          v495.marker.Transparency = 1
        end

        return
      else
        if not v495.marker then
          v495.build()
        end

        local GetCourtlines_2 = v525._getCourtlines and v525._getCourtlines()
        local v528 = true

        if GetCourtlines_2 and v525.isPositionInCourt then
          local v529, v530 = pcall(v525.isPositionInCourt, v524, nil, f63_6.Size.X * 0.5, nil)
          v528 = not v529 or v530
        end

        if v527 then
          color5 = Color3.fromRGB(250, 180, 40)
          v521 = "NET"
        elseif v528 then
          color5 = Color3.fromRGB(60, 220, 90)
          v521 = "IN"
        else
          local Color3_4 = Color3.fromRGB(235, 60, 60)
          v521 = "OUT"
          color5 = Color3_4
        end

        local MathClamp_6 = math.clamp(1 - v526 / 2, 0, 1)
        local v532 = 6 + MathClamp_6 * 3

        v495.marker.Size = Vector3.new(0.2, v532, v532)
        v495.marker.Transparency = 0.35 - MathClamp_6 * 0.15
        v495.marker.Color = color5

        v495.marker.CFrame = CFrame.new(v524 + Vector3.new(0, 0.1, 0))
          * CFrame.Angles(0, 0, math.rad(90))

        v495.label.Text = v521 .. "  " .. string.format("%.1fs", v526)
        v495.label.TextColor3 = color5

        return
      end
    end
  end
end))

-- LOCOPANI: FPS-friendly Score Effect preservation.
-- Roblox does not expose per-effect graphics quality, so do not raise global quality.
LOCOPANI_SCORE_QUALITY_ENABLED = false
LOCOPANI_SCORE_QUALITY_TOKEN = 0
LOCOPANI_SCORE_QUALITY_ACTIVE = false
LOCOPANI_SCORE_QUALITY_PREV_RENDER = nil
LOCOPANI_SCORE_QUALITY_PREV_SAVED = nil
LOCOPANI_SCORE_QUALITY_HAD_RENDER = false
LOCOPANI_SCORE_QUALITY_HAD_SAVED = false

function LOCOPANI_RestoreTemporaryScoreQuality()
  -- Safety cleanup for any older state; this version never boosts global quality.
  if not LOCOPANI_SCORE_QUALITY_ACTIVE then
    return
  end

  if LOCOPANI_SCORE_QUALITY_HAD_RENDER and LOCOPANI_SCORE_QUALITY_PREV_RENDER ~= nil then
    pcall(function()
      settings().Rendering.QualityLevel = LOCOPANI_SCORE_QUALITY_PREV_RENDER
    end)
  end

  if LOCOPANI_SCORE_QUALITY_HAD_SAVED and LOCOPANI_SCORE_QUALITY_PREV_SAVED ~= nil then
    pcall(function()
      UserSettings():GetService("UserGameSettings").SavedQualityLevel = LOCOPANI_SCORE_QUALITY_PREV_SAVED
    end)
  end

  LOCOPANI_SCORE_QUALITY_ACTIVE = false
  LOCOPANI_SCORE_QUALITY_PREV_RENDER = nil
  LOCOPANI_SCORE_QUALITY_PREV_SAVED = nil
  LOCOPANI_SCORE_QUALITY_HAD_RENDER = false
  LOCOPANI_SCORE_QUALITY_HAD_SAVED = false
end

function LOCOPANI_BoostTemporaryScoreQuality()
  -- Intentionally disabled: raising global quality caused FPS drops and did not
  -- selectively improve Score Effects.
  LOCOPANI_SCORE_QUALITY_ENABLED = false
  LOCOPANI_RestoreTemporaryScoreQuality()
end

function LOCOPANI_SetTemporaryScoreQuality(enabled)
  -- Compatibility wrapper: preserve the old callable API without a global boost.
  LOCOPANI_SCORE_QUALITY_ENABLED = false
  LOCOPANI_RestoreTemporaryScoreQuality()
end

local connect7, connect8, connect9

local function f113()
  if connect7 then
    return
  end

  v203 = false
  v204 = false

  local HitGround = replicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.BallService.RE.HitGround

  HitGround.OnClientEvent:Connect(function(...)
    local v533 = { ... }
    local Name_2 = localPlayer2.Name

    for key18, value97 in pairs(v533) do
      if tostring(value97) == Name_2 then
        v204 = true
        break
      end
    end
  end)

  local f114

  function f114(p208)
    if v203 then
      return
    elseif not v204 then
      return
    elseif not v202 then
      return
    else
      v203 = true

      local Child_3 = workspace:FindFirstChild(localPlayer2.Name)
        or workspace:FindFirstChild("uwuwuwiiwuw6")

      if v238 and v238.EffectEnabled then
        local randomEffect = f50("ScoreEffect")
        if randomEffect then
          scoreEffect = randomEffect
          pcall(function() v174:Notify("Random Effect: " .. randomEffect) end)
        end
      end

      local ScoreEffect_2 = scoreEffect
      local v535 = true

      if ScoreEffect_2 == "GroundHit1" or ScoreEffect_2 == "GroundHit2" then
        local v536 = ScoreEffect_2 == "GroundHit2"
        ScoreEffect_2 = nil
        v535 = v536
      end

      -- FPS-friendly mode: keep global rendering quality unchanged during score effects.

      if firesignal then
        firesignal(HitGround.OnClientEvent, table.unpack({
          p208, v535, false, 5, ScoreEffect_2, Child_3,
          Vector3.new(-0.0000020885916001134, 1, -0.000004710930170404),
        }, 1, 7))
      end

      if LOCOPANI_SCORE_QUALITY_ENABLED and LOCOPANI_SCORE_QUALITY_ACTIVE then
        LOCOPANI_SCORE_QUALITY_TOKEN = LOCOPANI_SCORE_QUALITY_TOKEN + 1
        LOCOPANI_QUALITY_RESTORE_TOKEN = LOCOPANI_SCORE_QUALITY_TOKEN
        task.delay(2.75, function()
          if LOCOPANI_QUALITY_RESTORE_TOKEN == LOCOPANI_SCORE_QUALITY_TOKEN then
            LOCOPANI_RestoreTemporaryScoreQuality()
          end
        end)
      end

      task.wait(0.5)
      v203 = false
      v204 = false
      return
    end
  end

  connect7 = workspace.ChildAdded:Connect(function(child7)
    if child7.Name == "HitIndicator" then
      if child7.Color == Color3.fromRGB(0, 255, 0) then
        f114(child7.Position)
      end
    end
  end)

  connect8 = workspace.DescendantAdded:Connect(function(descendant4)
    if descendant4.Name == "HitIndicator" and descendant4:IsA("BasePart") then
      if descendant4.Color == Color3.fromRGB(0, 255, 0) then
        f114(descendant4.Position)
      end
    end
  end)

  connect9 = workspace.DescendantRemoving:Connect(function(descendant5)
    if descendant5.Name == "HitIndicator" then
      v203 = false
      v204 = false
    end
  end)
end

local function f115()
  if connect7 then
    connect7:Disconnect()
    connect7 = nil
  end

  if connect8 then
    connect8:Disconnect()
    connect8 = nil
  end

  if connect9 then
    connect9:Disconnect()
    connect9 = nil
  end

  v203 = false
  v204 = false
end

do
  local connect10

  local function f116(p209)
    local Humanoid_8 = p209:WaitForChild("Humanoid")
    local HumanoidRootPart_12 = p209:WaitForChild("HumanoidRootPart")

    if connect10 then
      connect10:Disconnect()
      connect10 = nil
    end

    local rotateOverridden = false -- FIX: so restauramos o AutoRotate se fomos nos que desligamos
    local function restoreRotate()
      if rotateOverridden then
        rotateOverridden = false
        if Humanoid_8.Parent then Humanoid_8.AutoRotate = true end
      end
    end

    connect10 = Humanoid_8:GetPropertyChangedSignal("Jump"):Connect(function()
      if Humanoid_8.Jump and (v201 or v255.enabled) then
        task.defer(function()
          local enabled = v255.enabled and f63()
          local Position_8 = enabled and enabled.Position
          local OsClock_2 = os.clock()
          task.wait(0.03)

          if enabled and Position_8 and enabled.Parent then
            v255.trackBall(enabled, Position_8, os.clock() - OsClock_2)
          end

          local Facing = v255.enabled and v255.facing()

          if not Facing and v201 then
            Facing = Vector3.new(
              currentCamera2.CFrame.LookVector.X, 0, currentCamera2.CFrame.LookVector.Z
            )
          end

          if Facing and Facing.Magnitude > 0 then
            v255.steer = Facing

            -- O tilt e aplicado no instante do spike, nao no salto,
            -- para evitar que uma chamada antecipada sobrescreva a selecao.

            if v201 or v255.enabled then
              HumanoidRootPart_12.CFrame = CFrame.lookAt(HumanoidRootPart_12.Position, HumanoidRootPart_12.Position
                + Facing.Unit)

              Humanoid_8.AutoRotate = false
              rotateOverridden = true

              -- FIX: devolve o AutoRotate quando pousar (ou no maximo 2s)
              task.spawn(function()
                local t0 = os.clock()
                task.wait(0.15)
                while Humanoid_8.Parent and os.clock() - t0 < 2 do
                  local st = Humanoid_8:GetState()
                  if st ~= Enum.HumanoidStateType.Freefall and st ~= Enum.HumanoidStateType.Jumping then
                    break
                  end
                  task.wait()
                end
                restoreRotate()
              end)
            end
          end
        end)
      elseif not (v201 or v255.enabled) then
        -- FIX: antes era "AutoRotate = false" aqui, o que quebrava o shiftlock/rotacao
        restoreRotate()
      end
    end)
  end

  if localPlayer2.Character then
    f116(localPlayer2.Character)
  end

  f36(localPlayer2.CharacterAdded:Connect(f116))

  local function f117()
    if not v221 then
      return
    else
      local Character_35 = localPlayer2.Character

      if not Character_35 then
        return
      else
        local Humanoid_9 = Character_35:FindFirstChildOfClass("Humanoid")

        if not Humanoid_9 then
          return
        end

        if v175 and v175.PlayAnimation then
          Humanoid_9.Jump = true
          v175:PlayAnimation("SpikeJump")
          task.delay(0.28, function() v175:PlayAnimation("Spike") end)
        end

        return
      end
    end
  end

  f36(userInputService.JumpRequest:Connect(function()
    if v221 then
      f117()
    end
  end))
end

local function f118()
  coroutine.wrap(function()
    while v214 do
      local Text_3 = localPlayer2.PlayerGui.Interface.Lobby.Abilities.TopPanel.DisplayName.Text

      for index86, value98 in ipairs(v216) do
        if Text_3 == value98 then
          v214 = false
          return
        end
      end

      local v538 = { v218 == "Lucky" }
      local AbilityService = replicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.AbilityService

      if AbilityService then
        local RF_2 = AbilityService:FindFirstChild("RF")

        if RF_2 then
          local Roll = RF_2:FindFirstChild("Roll")

          if Roll then
            Roll:InvokeServer(unpack(v538))
          end
        end
      end

      task.wait(0)
    end
  end)()
end

local qualityLevel, savedQualityLevel

local function f119()
  for key19, value99 in pairs(v231) do
    for key20, value100 in pairs(value99) do
      key19[key20] = value100
    end
  end

  v231 = {}

  if qualityLevel ~= nil then
    settings().Rendering.QualityLevel = qualityLevel
    qualityLevel = nil
  end

  if savedQualityLevel ~= nil then
    local UserSettings_2 = UserSettings()
    UserSettings_2:GetService("UserGameSettings").SavedQualityLevel = savedQualityLevel
    savedQualityLevel = nil
  end
end

local function f120()
  local function f121(p210, p211)
    local v540, v541 = pcall(function() return p210[p211] end)

    if v540 then
      return v541
    end

    return nil
  end

  local function f122(p212, p213, p214)
    p212[p213] = p214
  end

  local function f123(p215, p216)
    if not p215 then
      return
    else
      local v542 = v231[p215]

      if not v542 then
        v542 = {}
        v231[p215] = v542
      end

      if v542[p216] == nil then
        local f121_2 = f121(p215, p216)

        if f121_2 == nil then
          return false
        end

        v542[p216] = f121_2
        return true
      end

      return true
    end
  end

  local function f124(p217, p218, p219)
    if not p217 then
      return
    end

    if not f123(p217, p218) then
      return
    end

    f122(p217, p218, p219)
  end

  local function f125(p220)
    if not p220 then
      return true
    else
      local Character_36 = localPlayer2.Character

      if Character_36 and p220:IsDescendantOf(Character_36) then
        return true
      end

      return false
    end
  end

  local function f126(p221)
    if f125(p221) then
      return
    end

    -- Preserve recognizable score-effect assets when the option is enabled.
    if _G.LOCOPANI_PRESERVE_SCORE_EFFECTS then
      local ancestor = p221
      for _ = 1, 12 do
        if not ancestor then break end
        local lowerName = string.lower(ancestor.Name)
        if string.find(lowerName, "score", 1, true)
          or string.find(lowerName, "effect", 1, true)
          or string.find(lowerName, "supernova", 1, true)
          or string.find(lowerName, "groundhit", 1, true)
          or string.find(lowerName, "impact", 1, true)
          or string.find(lowerName, "point", 1, true)
          or string.find(lowerName, "vfx", 1, true)
          or string.find(lowerName, "particle", 1, true)
          or string.find(lowerName, "aura", 1, true)
          or string.find(lowerName, "burst", 1, true)
          or string.find(lowerName, "celebration", 1, true)
          or string.find(lowerName, "hitindicator", 1, true)
          or string.find(lowerName, "spike", 1, true)
          or string.find(lowerName, "shockwave", 1, true)
          or string.find(lowerName, "ring", 1, true)
          or string.find(lowerName, "glow", 1, true)
          or string.find(lowerName, "flash", 1, true)
          or string.find(lowerName, "spark", 1, true)
          or string.find(lowerName, "explosion", 1, true)
          or string.find(lowerName, "nova", 1, true)
          or string.find(lowerName, "charge", 1, true)
          or string.find(lowerName, "trail", 1, true)
          or string.find(lowerName, "beam", 1, true) then
          return
        end
        ancestor = ancestor.Parent
      end
    end

    if p221:IsA("BasePart") then
      f124(p221, "Material", Enum.Material.SmoothPlastic)
      f124(p221, "Reflectance", 0)
      f124(p221, "CastShadow", false)

      if p221:IsA("MeshPart") then
        f124(p221, "RenderFidelity", Enum.RenderFidelity.Performance)
        f124(p221, "TextureID", "")
      end
    elseif p221:IsA("Decal") or p221:IsA("Texture") then
      f124(p221, "Transparency", 1)
    elseif p221:IsA("ParticleEmitter") or p221:IsA("Trail") or p221:IsA("Beam")
      or p221:IsA("Smoke") or p221:IsA("Fire") or p221:IsA("Sparkles") then
      f124(p221, "Enabled", false)
    elseif p221:IsA("PointLight") or p221:IsA("SpotLight") or p221:IsA("SurfaceLight") then
      f124(p221, "Enabled", false)
    elseif p221:IsA("SpecialMesh") then
      f124(p221, "TextureId", "")
    elseif p221:IsA("SurfaceAppearance") then
      f124(p221, "ColorMap", "")
      f124(p221, "MetalnessMap", "")
      f124(p221, "NormalMap", "")
      f124(p221, "RoughnessMap", "")
    end
  end

  local function f127()
    f124(lighting, "Technology", Enum.Technology.Compatibility)
    f124(lighting, "GlobalShadows", false)
    f124(lighting, "FogEnd", 1000000000)
    f124(lighting, "ShadowSoftness", 0)

    for index87, value101 in ipairs(lighting:GetChildren()) do
      if value101:IsA("PostEffect") then
        f124(value101, "Enabled", false)
      elseif value101:IsA("Atmosphere") then
        f124(value101, "Density", 0)
        f124(value101, "Haze", 0)
        f124(value101, "Glare", 0)
      elseif value101:IsA("Sky") then
        f124(value101, "CelestialBodiesShown", false)
        f124(value101, "StarCount", 0)
      end
    end
  end

  local function f128()
    local Terrain = workspace:FindFirstChildOfClass("Terrain")

    if not Terrain then
      return
    end

    f124(Terrain, "Decoration", false)
    f124(Terrain, "WaterWaveSize", 0)
    f124(Terrain, "WaterWaveSpeed", 0)
    f124(Terrain, "WaterReflectance", 0)
    f124(Terrain, "WaterTransparency", 1)
  end

  local function f129()
    local Settings = settings().Rendering

    if qualityLevel == nil then
      qualityLevel = Settings.QualityLevel
    end

    Settings.QualityLevel = Enum.QualityLevel.Level01
    local UserGameSettings = UserSettings():GetService("UserGameSettings")

    if savedQualityLevel == nil then
      savedQualityLevel = UserGameSettings.SavedQualityLevel
    end

    UserGameSettings.SavedQualityLevel = Enum.SavedQualitySetting.QualityLevel1
  end

  f129()

  f127()
  f128()

  for index88, value102 in ipairs(workspace:GetDescendants()) do
    f126(value102)
  end

  workspace.DescendantAdded:Connect(function(descendant6) f126(descendant6) end)
end

local function f130()
  coroutine.wrap(function()
    while v213 do
      local Text_4 = localPlayer2.PlayerGui.Interface.Lobby.Styles.TopPanel.DisplayName.Text

      for index89, value103 in ipairs(v215) do
        if Text_4 == value103 then
          v213 = false
          return
        end
      end

      local v544 = { v217 == "Lucky" }
      local StyleService = replicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.StyleService

      if StyleService then
        local RF_3 = StyleService:FindFirstChild("RF")

        if RF_3 then
          local Roll_2 = RF_3:FindFirstChild("Roll")

          if Roll_2 then
            Roll_2:InvokeServer(unpack(v544))
          end
        end
      end

      task.wait(0)
    end
  end)()
end

-- Argon UI bridge: adapts the existing LOCOPANI control wrappers to Argon UI.
do
do
  local okArgon, errArgon = pcall(function()
    LOCOPANI_ARGON = LOCOPANI_ARGON or ((type(getgenv) == "function" and getgenv()) or _G).LOCOPANI_LOAD_ARGON()
  end)
  if not okArgon then
    -- Fecha a tela de carregamento para o erro não ficar escondido atrás dela
    pcall(function()
      local e = (type(getgenv) == "function" and getgenv()) or _G
      if e.LOCOPANI_LOADER then e.LOCOPANI_LOADER.Hide(true) end
    end)
    error(errArgon, 0)
  end
end
local Argon = LOCOPANI_ARGON
local rawWindow = Argon:CreateWindow({
    Name = "LOCOPANI",
    Subtitle = "OWNER / CREATOR: LOCOPANI",
    Theme = "Amethyst",
    ToggleUIKeybind = Enum.KeyCode.RightShift,
    PlayerList = false,
    KeybindList = false,
    ConfigurationSaving = { Enabled = false },
    GuiName = "LOCOPANIArgonUI",
})
-- Esconde o painel até a tela de carregamento chegar a 100%
pcall(function()
  local env = (type(getgenv) == "function" and getgenv()) or _G
  local L = env.LOCOPANI_LOADER
  if L and L.Hold then
    L.Hold(rawWindow.ScreenGui)
    L.Hold(rawWindow.CursorGui)
  end
end)
pcall(function() rawWindow:SetSize(Vector2.new(980, 660)) end)
pcall(function() LOCOPANI_AddRainbowAccent(rawWindow) end)
pcall(function() LOCOPANI_AddSiteEffects(rawWindow) end)
pcall(function() LOCOPANI_ApplyInteractivePolish(rawWindow) end)
pcall(function() local e = (type(getgenv) == "function" and getgenv()) or _G e.LOCOPANI_ApplyRealCursor(rawWindow) end)

-- LOCOPANI motion + matching glass sidebar (low-cost tweens only).
do
  rawWindow._LOCOPANI_MotionMain = rawWindow.Main
  rawWindow._LOCOPANI_MotionShadow = rawWindow.Shadow
  rawWindow._LOCOPANI_MotionSidebar = rawWindow.Sidebar
  rawWindow._LOCOPANI_TweenService = game:GetService("TweenService")
  if rawWindow._LOCOPANI_MotionMain and rawWindow._LOCOPANI_MotionSidebar and not rawWindow._LOCOPANI_MotionMain:FindFirstChild("LOCOPANI_WindowMotion") then
    rawWindow._LOCOPANI_MainScale = Instance.new("UIScale")
    rawWindow._LOCOPANI_MainScale.Name = "LOCOPANI_WindowMotion"
    rawWindow._LOCOPANI_MainScale.Scale = 1
    rawWindow._LOCOPANI_MainScale.Parent = rawWindow._LOCOPANI_MotionMain
    -- Independent scale keeps the user's UI size separate from transition animation.
    rawWindow._LOCOPANI_UserScale = Instance.new("UIScale")
    rawWindow._LOCOPANI_UserScale.Name = "LOCOPANI_UserScale"
    rawWindow._LOCOPANI_UserScale.Scale = 1
    rawWindow._LOCOPANI_UserScale.Parent = rawWindow._LOCOPANI_MotionMain
    if rawWindow._LOCOPANI_MotionShadow then
      rawWindow._LOCOPANI_ShadowScale = Instance.new("UIScale")
      rawWindow._LOCOPANI_ShadowScale.Name = "LOCOPANI_ShadowMotion"
      rawWindow._LOCOPANI_ShadowScale.Scale = 1
      rawWindow._LOCOPANI_ShadowScale.Parent = rawWindow._LOCOPANI_MotionShadow
    end

    -- Match the sidebar to the glass panel and give its inner edge a subtle rainbow accent.
    rawWindow._LOCOPANI_MotionSidebar.BackgroundColor3 = Color3.fromRGB(15, 11, 24)
    rawWindow._LOCOPANI_MotionSidebar.BackgroundTransparency = 0.24
    rawWindow._LOCOPANI_SquareEdge = rawWindow._LOCOPANI_MotionSidebar:FindFirstChild("SquareEdge")
    if rawWindow._LOCOPANI_SquareEdge then
      rawWindow._LOCOPANI_SquareEdge.BackgroundColor3 = rawWindow._LOCOPANI_MotionSidebar.BackgroundColor3
      rawWindow._LOCOPANI_SquareEdge.BackgroundTransparency = rawWindow._LOCOPANI_MotionSidebar.BackgroundTransparency
    end
    rawWindow._LOCOPANI_SidebarDivider = rawWindow._LOCOPANI_MotionSidebar:FindFirstChild("LOCOPANI_RainbowSidebarEdge")
    if not rawWindow._LOCOPANI_SidebarDivider then
      rawWindow._LOCOPANI_SidebarDivider = Instance.new("Frame")
      rawWindow._LOCOPANI_SidebarDivider.Name = "LOCOPANI_RainbowSidebarEdge"
      rawWindow._LOCOPANI_SidebarDivider.BorderSizePixel = 0
      rawWindow._LOCOPANI_SidebarDivider.BackgroundColor3 = Color3.new(1, 1, 1)
      rawWindow._LOCOPANI_SidebarDivider.BackgroundTransparency = 0.08
      rawWindow._LOCOPANI_SidebarDivider.Position = UDim2.new(1, -2, 0, 12)
      rawWindow._LOCOPANI_SidebarDivider.Size = UDim2.new(0, 2, 1, -24)
      rawWindow._LOCOPANI_SidebarDivider.ZIndex = 10
      rawWindow._LOCOPANI_SidebarDivider.Parent = rawWindow._LOCOPANI_MotionSidebar
      rawWindow._LOCOPANI_EdgeGradient = Instance.new("UIGradient")
      rawWindow._LOCOPANI_EdgeGradient.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0.00, Color3.fromRGB(255, 75, 135)),
        ColorSequenceKeypoint.new(0.20, Color3.fromRGB(255, 165, 75)),
        ColorSequenceKeypoint.new(0.40, Color3.fromRGB(245, 235, 90)),
        ColorSequenceKeypoint.new(0.60, Color3.fromRGB(75, 255, 175)),
        ColorSequenceKeypoint.new(0.80, Color3.fromRGB(70, 190, 255)),
        ColorSequenceKeypoint.new(1.00, Color3.fromRGB(180, 100, 255)),
      })
      rawWindow._LOCOPANI_EdgeGradient.Rotation = 90
      rawWindow._LOCOPANI_EdgeGradient.Parent = rawWindow._LOCOPANI_SidebarDivider
      rawWindow._LOCOPANI_TweenService:Create(rawWindow._LOCOPANI_EdgeGradient, TweenInfo.new(12, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1, false), {Rotation = 450}):Play()
    end

    -- ============================================================
    -- LOCOPANI V27 Black Hole transition
    -- FECHAR: um buraco negro aparece NO MEIO do painel e puxa a UI inteira
    --         (janela girando + pedacos de UI + particulas em espiral).
    --         Termina com flash e onda de choque.
    -- ABRIR : o buraco negro aparece no meio e EXPELE tudo para fora:
    --         a janela nasce dele girando, com particulas e ondas de choque.
    --
    -- ANTI-TRAVA:
    --  * a escala/rotacao da janela (que forca o Roblox a recalcular toda a UI)
    --    e atualizada em poucos passos por segundo (WINDOW_FPS), nao a cada frame;
    --  * a janela e escondida assim que some dentro do buraco (nao desenha ela minuscula);
    --  * MODO LEVE automatico: se o FPS cair durante a animacao, ela para de
    --    escalar a janela e usa so o efeito do buraco (e lembra disso nas proximas vezes).
    -- ============================================================
    rawWindow._LOCOPANI_MotionToken = 0
    rawWindow._LOCOPANI_VisibilityGuard = false
    rawWindow._LOCOPANI_LastVisible = rawWindow._LOCOPANI_MotionMain.Visible
    rawWindow._LOCOPANI_ExpectedVisible = rawWindow._LOCOPANI_MotionMain.Visible

    local function LOCOPANI_BuildBlackHole()
      -- Ajustes rapidos -----------------------------------------
      local BH = {
        OPEN_TIME = 0.90,        -- duracao da abertura (s)
        CLOSE_TIME = 0.85,       -- duracao do fechamento (s)
        SWIRL_PARTICLES = 28,    -- riscos de luz em espiral
        UI_CHUNKS = 12,          -- pedacos de UI sendo puxados/expelidos
        DISK_DOTS = { 20, 26 },  -- tracos de cada anel do disco de acrecao
        SCALE_WINDOW = true,     -- true = janela encolhe/cresce; false = modo leve fixo
        WINDOW_FPS = 18,         -- quantas vezes/s a escala da janela muda (menor = menos trava)
        SPIN_DEG = 70,           -- giro da janela enquanto e puxada (0 = sem giro)
        DIM = 0.42,              -- escurecimento da tela durante o efeito (0 = desliga)
        AUTO_LITE = true,        -- troca sozinho para modo leve se o FPS cair
        LITE_FPS = 22,           -- abaixo disso (media) ativa o modo leve
      }
      local SMIN = 0.04          -- escala minima da janela (so e usada por instantes)
      local RINGS = {
        { a = 1.45, speed = 5.4, thick = 3.0 },
        { a = 2.05, speed = 3.3, thick = 2.4 },
      }
      local TILT = math.rad(-18)
      local FLATTEN = 0.30

      local RunService = game:GetService("RunService")
      local mainFrame = rawWindow._LOCOPANI_MotionMain
      local shadowFrame = rawWindow._LOCOPANI_MotionShadow
      local mainScale = rawWindow._LOCOPANI_MainScale
      local shadowScale = rawWindow._LOCOPANI_ShadowScale
      local motionRoot = rawWindow.ScreenGui or mainFrame.Parent
      local shadowIndependent = shadowFrame ~= nil and not shadowFrame:IsDescendantOf(mainFrame)


      -- UNICO ponto que muda Visible por conta propria. Registra o valor ESPERADO para o handler do
      -- RightShift distinguir "fui eu" de "foi o Argon" (evita o loop de fechar/abrir sozinho).
      local function setMainVisible(v)
        rawWindow._LOCOPANI_ExpectedVisible = v
        rawWindow._LOCOPANI_VisibilityGuard = true
        mainFrame.Visible = v
        if shadowFrame then shadowFrame.Visible = v end
        rawWindow._LOCOPANI_VisibilityGuard = false
        rawWindow._LOCOPANI_LastVisible = v
      end
      rawWindow._LOCOPANI_SetMainVisible = setMainVisible

      local cos, sin, atan2, sqrt = math.cos, math.sin, math.atan2, math.sqrt
      local PI = math.pi
      local liteMode = (BH.SCALE_WINDOW == false)

      local function clamp01(x)
        if x < 0 then return 0 elseif x > 1 then return 1 end
        return x
      end
      local function smooth(a, b, x)
        local t = clamp01((x - a) / (b - a))
        return t * t * (3 - 2 * t)
      end
      local function easeIn(x) return x * x * x end
      local function easeOutCubic(x) local u = 1 - x return 1 - u * u * u end
      local function easeOutBack(x)
        local c1 = 1.15
        local c3 = c1 + 1
        local u = x - 1
        return 1 + c3 * u * u * u + c1 * u * u
      end

      local function make(class, props, parent)
        local o = Instance.new(class)
        for k, v in pairs(props) do o[k] = v end
        o.Parent = parent
        return o
      end

      local layer = make("Frame", {
        Name = "LOCOPANI_BlackHoleTransition",
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Size = UDim2.fromScale(1, 1),
        Position = UDim2.fromScale(0, 0),
        Visible = false,
        Active = false,
        ZIndex = 10000,
      }, motionRoot)
      rawWindow._LOCOPANI_BlackHoleLayer = layer

      local Z_DIM, Z_HALO, Z_BACK, Z_HOLE, Z_PHOTON, Z_FRONT, Z_CHUNK, Z_PART, Z_WAVE, Z_FLASH =
        10001, 10002, 10004, 10010, 10011, 10013, 10018, 10020, 10030, 10031

      local function circle(name, z, color)
        local f = make("Frame", {
          Name = name, AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = color,
          BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.fromOffset(0, 0), ZIndex = z,
        }, layer)
        make("UICorner", { CornerRadius = UDim.new(1, 0) }, f)
        return f
      end
      local function pill(name, z, radius)
        local f = make("Frame", {
          Name = name, AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = Color3.new(1, 1, 1),
          BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.fromOffset(4, 2), ZIndex = z,
        }, layer)
        make("UICorner", { CornerRadius = radius or UDim.new(1, 0) }, f)
        return f
      end

      local dim = make("Frame", {
        Name = "Dim", BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 1,
        BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ZIndex = Z_DIM,
      }, layer)

      local HALO_COLOR = Color3.fromRGB(125, 55, 235)
      local halos = {
        { f = circle("Halo1", Z_HALO, HALO_COLOR), mul = 1.9, base = 0.72 },
        { f = circle("Halo2", Z_HALO, HALO_COLOR), mul = 3.0, base = 0.87 },
        { f = circle("Halo3", Z_HALO, HALO_COLOR), mul = 4.6, base = 0.95 },
      }

      local hole = circle("Singularity", Z_HOLE, Color3.fromRGB(1, 0, 5))
      hole.BackgroundTransparency = 0
      local holeStroke = make("UIStroke", { Color = Color3.fromRGB(120, 55, 230), Thickness = 2.5, Transparency = 1 }, hole)

      local photon = circle("PhotonRing", Z_PHOTON, Color3.new(0, 0, 0))
      local photonStroke = make("UIStroke", { Color = Color3.new(1, 1, 1), Thickness = 3, Transparency = 1 }, photon)
      local photonGradient = make("UIGradient", {
        Color = ColorSequence.new({
          ColorSequenceKeypoint.new(0.00, Color3.fromRGB(255, 244, 255)),
          ColorSequenceKeypoint.new(0.35, Color3.fromRGB(190, 120, 255)),
          ColorSequenceKeypoint.new(0.65, Color3.fromRGB(255, 190, 120)),
          ColorSequenceKeypoint.new(1.00, Color3.fromRGB(255, 244, 255)),
        }),
      }, photonStroke)

      local lens = circle("LensGlow", Z_PHOTON, Color3.new(0, 0, 0))
      local lensStroke = make("UIStroke", { Color = Color3.fromRGB(170, 100, 255), Thickness = 1.5, Transparency = 1 }, lens)

      local diskDots = {}
      for ri, n in ipairs(BH.DISK_DOTS) do
        for k = 1, n do
          diskDots[#diskDots + 1] = {
            f = pill("DiskStreak", Z_BACK), ring = ri, n = n,
            phi0 = (k / n) * PI * 2 + ri * 0.7, front = false,
          }
        end
      end

      local swirl = {}
      for i = 1, BH.SWIRL_PARTICLES do
        swirl[i] = { f = pill("SwirlParticle", Z_PART), x0 = 0, y0 = 0, r0 = 1, a0 = 0, d = 0, spin = 0, px = 0, py = 0, rot = 0 }
      end

      -- pedacos de UI (retangulos escuros com brilho roxo) para dar a sensacao de que a UI esta sendo engolida
      local chunks = {}
      for i = 1, BH.UI_CHUNKS do
        chunks[i] = { f = pill("UIChunk", Z_CHUNK, UDim.new(0, 4)), x0 = 0, y0 = 0, r0 = 1, a0 = 0, d = 0, spin = 0, w = 30, h = 16, rot0 = 0 }
      end

      local waves = {}
      for k = 1, 2 do
        local w = circle("Shockwave" .. k, Z_WAVE, Color3.new(0, 0, 0))
        local st = make("UIStroke", {
          Color = k == 1 and Color3.fromRGB(235, 205, 255) or Color3.fromRGB(125, 75, 245),
          Thickness = 2, Transparency = 1,
        }, w)
        waves[k] = { f = w, s = st }
      end

      local flash = circle("Flash", Z_FLASH, Color3.fromRGB(255, 240, 255))

      -- Geometria em cache --------------------------------------
      -- pivot = ponto fixo do UIScale (AnchorPoint da janela). O buraco fica no CENTRO da janela (pivot + cOff);
      -- se o AnchorPoint nao for (0.5,0.5), a janela e deslocada junto para encolher exatamente em direcao ao centro.
      local geom = { size = Vector2.new(980, 660), pivot = nil, ap = Vector2.new(0.5, 0.5), basePos = nil, shadowBase = nil }
      local function measure()
        pcall(function()
          local ap = mainFrame.AnchorPoint
          local sz = mainFrame.AbsoluteSize
          if sz.X > 20 and sz.Y > 20 then
            local pos = mainFrame.AbsolutePosition
            geom.pivot = (pos + Vector2.new(sz.X * ap.X, sz.Y * ap.Y)) - layer.AbsolutePosition
            geom.ap = ap
            if mainScale.Scale > 0.995 then
              geom.size = sz / mainScale.Scale
              geom.basePos = mainFrame.Position
              if shadowIndependent then geom.shadowBase = shadowFrame.Position end
            end
          end
        end)
        if not geom.pivot then geom.pivot = layer.AbsoluteSize / 2 end
        if not geom.basePos then geom.basePos = mainFrame.Position end
      end

      local C_FAR = Color3.fromRGB(150, 70, 255)
      local C_NEAR = Color3.fromRGB(255, 214, 160)
      local C_HOT = Color3.fromRGB(255, 196, 130)
      local C_COOL = Color3.fromRGB(150, 80, 255)
      local C_CHUNK = Color3.fromRGB(58, 34, 108)

      -- posicao orbital de uma particula: S=0 na posicao original, S=1 no centro
      local function orbit(p, S)
        local q = clamp01((S - p.d) / (1 - p.d))
        local e = q * q * q
        local r = p.r0 * (1 - e)
        local th = p.a0 + p.spin * e
        local flat = 1 - 0.62 * e
        local lx, ly = r * cos(th), r * sin(th) * flat
        local ang = TILT * e
        local ca, sa = cos(ang), sin(ang)
        return lx * ca - ly * sa, lx * sa + ly * ca, e, q
      end

      -- Loop principal ------------------------------------------
      local function run(opening, token)
        local W, H = geom.size.X, geom.size.Y
        local minWH = math.min(W, H)
        local ap = geom.ap
        local D = math.clamp(minWH * 0.17, 90, 150) -- diametro do buraco (grande, no meio)
        local cOff = Vector2.new((0.5 - ap.X) * W, (0.5 - ap.Y) * H)
        local center = geom.pivot + cOff            -- centro REAL da janela (onde fica o buraco)
        local centered = math.abs(ap.X - 0.5) < 0.01 and math.abs(ap.Y - 0.5) < 0.01
        local canRotate = BH.SPIN_DEG ~= 0 and centered
        local dur = opening and BH.OPEN_TIME or BH.CLOSE_TIME
        local ct, st = cos(TILT), sin(TILT)
        local winDt = 1 / BH.WINDOW_FPS

        for _, p in ipairs(swirl) do
          p.x0 = (math.random() - 0.5) * W * 1.04
          p.y0 = (math.random() - 0.5) * H * 1.04
          p.r0 = math.max(sqrt(p.x0 * p.x0 + p.y0 * p.y0), 8)
          p.a0 = atan2(p.y0, p.x0)
          p.d = math.random() * 0.3
          p.spin = (1.3 + math.random() * 1.7) * PI
          p.px, p.py = p.x0, p.y0
          p.rot = 0
        end
        for _, c in ipairs(chunks) do
          c.x0 = (math.random() - 0.5) * W * 0.9
          c.y0 = (math.random() - 0.5) * H * 0.9
          c.r0 = math.max(sqrt(c.x0 * c.x0 + c.y0 * c.y0), 8)
          c.a0 = atan2(c.y0, c.x0)
          c.d = math.random() * 0.25
          c.spin = (1.0 + math.random() * 1.4) * PI
          c.w = 22 + math.random() * 30
          c.h = 12 + math.random() * 16
          c.rot0 = math.random() * 40 - 20
        end
        for _, dd in ipairs(diskDots) do
          local ring = RINGS[dd.ring]
          local len = math.clamp(2 * PI * ring.a * D / dd.n * 0.5, 6, 32)
          dd.f.Size = UDim2.fromOffset(len, ring.thick)
          dd.front = false
          dd.f.ZIndex = Z_BACK
        end

        -- aplica escala/rotacao/posicao da janela (operacao CARA: chamada com limitador de taxa)
        local function setWindow(s, rot)
          mainScale.Scale = s
          if shadowScale then shadowScale.Scale = s end
          if not centered then
            local off = UDim2.fromOffset(cOff.X * (1 - s), cOff.Y * (1 - s))
            mainFrame.Position = geom.basePos + off
            if shadowIndependent and geom.shadowBase then shadowFrame.Position = geom.shadowBase + off end
          end
          if canRotate then
            mainFrame.Rotation = rot
            if shadowIndependent then shadowFrame.Rotation = rot end
          end
        end
        local winHidden = false
        local function hideMain()
          if winHidden then return end
          winHidden = true
          setMainVisible(false)
        end

        layer.Visible = true
        rawWindow._LOCOPANI_Animating = true -- o cursor continua visivel durante toda a animacao
        local t0 = os.clock()
        local lastC = t0
        local frames, samples, dtSum = 0, 0, 0
        local lastWinT = -1
        local litePopped = false

        while true do
          if token ~= rawWindow._LOCOPANI_MotionToken then return false end
          local c = os.clock()
          local now = c - t0
          local dtFrame = c - lastC
          lastC = c
          local t = now / dur
          if t > 1 then t = 1 end

          -- deteccao de FPS baixo -> modo leve ---------------------
          frames += 1
          if BH.AUTO_LITE and not liteMode and frames > 3 then
            samples += 1
            dtSum += dtFrame
            if samples >= 6 and (dtSum / samples) > (1 / BH.LITE_FPS) then
              liteMode = true
              -- para de escalar a janela: volta ao estado base
              if opening then
                setWindow(SMIN, 0)
              else
                hideMain()
              end
            end
          end

          -- linhas do tempo ---------------------------------------
          local hs, S
          if opening then
            hs = smooth(0, 0.16, t) * (1 - smooth(0.62, 0.95, t))
            S = 1 - clamp01((t - 0.12) / 0.7)
          else
            hs = smooth(0, 0.28, t) * (1 - smooth(0.8, 1, t))
            S = clamp01(t / 0.8)
          end
          local ha = clamp01(hs * 1.6)
          local R = D * hs * (1 + 0.035 * sin(now * 20))

          if BH.DIM > 0 then
            local da
            if opening then
              da = smooth(0, 0.12, t) * (1 - smooth(0.3, 0.9, t))
            else
              da = smooth(0, 0.3, t) * (1 - smooth(0.7, 1, t))
            end
            dim.BackgroundTransparency = 1 - BH.DIM * da
          end

          -- halos, buraco, anel de fotons ----------------------
          local cpos = UDim2.fromOffset(center.X, center.Y)
          for _, h in ipairs(halos) do
            local s = R * h.mul
            h.f.Size = UDim2.fromOffset(s, s)
            h.f.Position = cpos
            h.f.BackgroundTransparency = 1 - (1 - h.base) * ha
          end
          hole.Size = UDim2.fromOffset(R, R)
          hole.Position = cpos
          holeStroke.Transparency = 1 - 0.8 * ha
          photon.Size = UDim2.fromOffset(R * 1.2, R * 1.2)
          photon.Position = cpos
          photonStroke.Transparency = 1 - 0.95 * ha
          photonGradient.Rotation = now * 240
          lens.Size = UDim2.fromOffset(R * 1.55, R * 1.55)
          lens.Position = cpos
          lensStroke.Transparency = 1 - 0.4 * ha

          -- disco de acrecao ---------------------------------------
          for _, dd in ipairs(diskDots) do
            local ring = RINGS[dd.ring]
            local a = ring.a * D * hs
            local b = a * FLATTEN
            local phi = dd.phi0 + ring.speed * now
            local sp, cp = sin(phi), cos(phi)
            local lx, ly = a * cp, b * sp
            local tx, ty = -a * sp, b * cp
            dd.f.Position = UDim2.fromOffset(center.X + lx * ct - ly * st, center.Y + lx * st + ly * ct)
            dd.f.Rotation = atan2(tx * st + ty * ct, tx * ct - ty * st) * 180 / PI
            local bright = 0.5 + 0.5 * cos(phi - 1.0)
            dd.f.BackgroundColor3 = C_COOL:Lerp(C_HOT, bright)
            dd.f.BackgroundTransparency = 1 - ha * (0.3 + 0.7 * bright) * 0.95
            local isFront = sp > 0
            if isFront ~= dd.front then
              dd.front = isFront
              dd.f.ZIndex = isFront and Z_FRONT or Z_BACK
            end
          end

          -- riscos de luz em espiral -----------------------------
          for _, p in ipairs(swirl) do
            local x, y, e, q = orbit(p, S)
            local dx, dy = x - p.px, y - p.py
            local speed = sqrt(dx * dx + dy * dy)
            if speed > 0.4 then p.rot = atan2(dy, dx) * 180 / PI end
            p.px, p.py = x, y
            p.f.Position = UDim2.fromOffset(center.X + x, center.Y + y)
            p.f.Size = UDim2.fromOffset(math.clamp(3 + speed * 1.4, 3, 44), 3 - 1.4 * e)
            p.f.Rotation = p.rot
            p.f.BackgroundColor3 = C_FAR:Lerp(C_NEAR, e)
            local tr = math.max(smooth(0.9, 1, q), 1 - smooth(0, 0.12, q))
            p.f.BackgroundTransparency = 0.08 + 0.92 * tr
          end

          -- pedacos de UI ---------------------------------------
          for _, ch in ipairs(chunks) do
            local x, y, e, q = orbit(ch, S)
            local k = 1 - 0.88 * e
            ch.f.Position = UDim2.fromOffset(center.X + x, center.Y + y)
            ch.f.Size = UDim2.fromOffset(ch.w * k, ch.h * k)
            ch.f.Rotation = ch.rot0 + (ch.spin * e * 1.3) * 180 / PI
            ch.f.BackgroundColor3 = C_CHUNK:Lerp(C_NEAR, e * e)
            local tr = math.max(smooth(0.88, 1, q), 1 - smooth(0, 0.1, q))
            ch.f.BackgroundTransparency = 0.12 + 0.88 * tr
          end

          -- ondas de choque -------------------------------------
          for k = 1, 2 do
            local w = waves[k]
            local p
            if opening then
              p = clamp01((t - 0.14 - 0.06 * (k - 1)) / 0.6)
            else
              p = clamp01((t - 0.74 - 0.05 * (k - 1)) / 0.26)
            end
            if p > 0 and p < 1 then
              local maxD = opening and minWH * (0.75 + 0.3 * k) or D * (4 + 2 * k)
              local s = D + maxD * easeOutCubic(p)
              w.f.Size = UDim2.fromOffset(s, s)
              w.f.Position = cpos
              w.s.Transparency = 1 - 0.85 * (1 - p)
              w.s.Thickness = 3.4 - 2.9 * p
            else
              w.s.Transparency = 1
            end
          end

          -- flash --------------------------------------------------
          local fp = opening and clamp01((t - 0.12) / 0.22) or clamp01((t - 0.74) / 0.26)
          if fp > 0 and fp < 1 then
            local s = 30 + 220 * fp
            flash.Size = UDim2.fromOffset(s, s)
            flash.Position = cpos
            flash.BackgroundTransparency = 1 - 0.85 * sin(PI * fp)
          else
            flash.BackgroundTransparency = 1
          end

          -- janela (escala/rotacao LIMITADAS a WINDOW_FPS) -------------
          if not liteMode then
            local s, rot, p
            if opening then
              p = clamp01((t - 0.2) / 0.62)
              s = SMIN + (1 - SMIN) * easeOutBack(p)
              rot = -BH.SPIN_DEG * (1 - easeOutCubic(p))
            else
              p = clamp01((t - 0.12) / 0.62)
              local e = easeIn(p)
              s = 1 - (1 - SMIN) * e
              rot = BH.SPIN_DEG * e
            end
            if not winHidden then
              if t >= 1 or p >= 1 or (now - lastWinT) >= winDt then
                lastWinT = now
                setWindow(math.max(s, SMIN), rot)
              end
              -- fechar: a janela some dentro do buraco -> nao desenha mais
              if not opening and p >= 1 then hideMain() end
            end
          else
            -- MODO LEVE: sem escalar a janela
            if opening then
              if t >= 0.3 and not litePopped then
                litePopped = true
                setWindow(1, 0)
              end
            else
              if t >= 0.18 then hideMain() end
            end
          end

          if t >= 1 then break end
          RunService.RenderStepped:Wait()
        end

        -- estado final limpo ------------------------------------
        if opening then
          setWindow(1, 0)
        end
        layer.Visible = false
        rawWindow._LOCOPANI_Animating = false
        return true
      end

      -- restaura escala/rotacao/posicao da janela (usado depois de fechar, com a janela ja escondida)
      local function resetWindow()
        mainScale.Scale = 1
        if shadowScale then shadowScale.Scale = 1 end
        mainFrame.Rotation = 0
        if shadowIndependent then shadowFrame.Rotation = 0 end
        if geom.basePos then mainFrame.Position = geom.basePos end
        if shadowIndependent and geom.shadowBase then shadowFrame.Position = geom.shadowBase end
      end

      -- API publica ---------------------------------------------
      rawWindow.SetVisibility = function(self, visible)
        rawWindow._LOCOPANI_ShouldShow = visible ~= false
        rawWindow._LOCOPANI_MotionToken += 1
        local token = rawWindow._LOCOPANI_MotionToken
        measure() -- ANTES de alterar escala/visibilidade

        if rawWindow._LOCOPANI_ShouldShow then
          self._visible = true
          setMainVisible(true)
          if self._refreshOverlayVisibility then self:_refreshOverlayVisibility() end

          -- comeca minuscula no MESMO frame (nada pesado e desenhado enquanto so o buraco aparece)
          mainScale.Scale = SMIN
          if shadowScale then shadowScale.Scale = SMIN end
          task.spawn(function()
            run(true, token)
          end)
        else
          self._visible = false
          if self._dropdownPopup then pcall(function() self._dropdownPopup:Destroy() end) self._dropdownPopup = nil end
          if self._colorPopup then pcall(function() self._colorPopup:Destroy() end) self._colorPopup = nil end
          if self._refreshOverlayVisibility then self:_refreshOverlayVisibility() end
          task.spawn(function()
            local finished = run(false, token)
            if not finished or token ~= rawWindow._LOCOPANI_MotionToken or self._visible then return end
            setMainVisible(false)
            resetWindow()
          end)
        end
        return self
      end
    end
    LOCOPANI_BuildBlackHole()

    -- Route visibility changes made by Argon's own RightShift handler through the same effect.
    -- V27.1: compara com o valor ESPERADO (definido por setMainVisible) em vez de depender so de uma flag.
    -- Assim, esconder/mostrar a janela por dentro da animacao nunca e confundido com um clique do usuario,
    -- mesmo se o Roblox entregar o sinal atrasado (era isso que causava o loop de fechar/abrir sozinho).
    rawWindow._LOCOPANI_MotionMain:GetPropertyChangedSignal("Visible"):Connect(function()
      local nowVisible = rawWindow._LOCOPANI_MotionMain.Visible
      if rawWindow._LOCOPANI_VisibilityGuard or nowVisible == rawWindow._LOCOPANI_ExpectedVisible then
        return
      end
      -- mudanca externa (RightShift do Argon etc.): desfaz e refaz com a animacao
      local setVis = rawWindow._LOCOPANI_SetMainVisible
      if nowVisible then
        if setVis then setVis(false) end
        rawWindow:SetVisibility(true)
      else
        if setVis then setVis(true) end
        rawWindow:SetVisibility(false)
      end
    end)
  end
end

local LOCOPANI_ArgonTab = {}
LOCOPANI_ArgonTab.__index = LOCOPANI_ArgonTab
local LOCOPANI_ARGON_CONTROL_ID = 0
local function LOCOPANI_ArgonId(prefix)
    LOCOPANI_ARGON_CONTROL_ID += 1
    return "LOCOPANI_" .. tostring(prefix or "Control") .. "_" .. tostring(LOCOPANI_ARGON_CONTROL_ID)
end
local function LOCOPANI_ArgonControlAliases(control)
    if control then
        if not control.SetText then
            control.SetText = function(self, value)
                if self.SetContent then return self:SetContent(tostring(value or "")) end
                if self.Set then return self:Set(tostring(value or "")) end
                if self.SetTitle then return self:SetTitle(tostring(value or "")) end
            end
        end
        if not control.SetDesc then
            control.SetDesc = function(self, value)
                if self.SetContent then return self:SetContent(tostring(value or "")) end
                if self.Set then return self:Set(tostring(value or "")) end
            end
        end
    end
    return control
end
function LOCOPANI_ArgonTab:Tab(cfg)
    cfg = cfg or {}
    return setmetatable({ _tab = self._window:CreateTab(cfg.Title or "Tab", cfg.Icon or "activity") }, LOCOPANI_ArgonTab)
end
function LOCOPANI_ArgonTab:Section(cfg)
    local title = type(cfg) == "table" and (cfg.Title or cfg.Name) or tostring(cfg or "")
    return self._tab:CreateSection(title)
end
function LOCOPANI_ArgonTab:Paragraph(cfg)
    cfg = cfg or {}
    return LOCOPANI_ArgonControlAliases(self._tab:CreateParagraph({
        Title = cfg.Title or cfg.Name or "Information",
        Content = cfg.Desc or cfg.Content or cfg.Description or "",
        Icon = cfg.Icon,
    }))
end
function LOCOPANI_ArgonTab:Toggle(cfg)
    cfg = cfg or {}
    return LOCOPANI_ArgonControlAliases(self._tab:CreateToggle({
        Flag = cfg.Flag or LOCOPANI_ArgonId(cfg.Title), Name = cfg.Title or cfg.Name or "Toggle",
        Description = cfg.Desc or cfg.Description,
        CurrentValue = cfg.CurrentValue == true or cfg.Value == true or cfg.Default == true,
        Callback = cfg.Callback,
    }))
end
function LOCOPANI_ArgonTab:Button(cfg)
    cfg = cfg or {}
    return LOCOPANI_ArgonControlAliases(self._tab:CreateButton({
        Name = cfg.Title or cfg.Name or "Button", Description = cfg.Desc or cfg.Description,
        Callback = cfg.Callback or cfg.Func,
    }))
end
function LOCOPANI_ArgonTab:Slider(cfg)
    cfg = cfg or {}
    local value = cfg.Value
    local range = cfg.Range
    local default = cfg.CurrentValue or (type(value) == "table" and value.Default) or cfg.Default
    local minimum = (type(range) == "table" and range[1]) or (type(value) == "table" and value.Min) or cfg.Min
    local maximum = (type(range) == "table" and range[2]) or (type(value) == "table" and value.Max) or cfg.Max
    local rangeMin, rangeMax = tonumber(minimum) or 0, tonumber(maximum) or 100
    local increment = tonumber(cfg.Step or cfg.Increment) or 1
    if increment <= 0 then increment = 1 end
    return LOCOPANI_ArgonControlAliases(self._tab:CreateSlider({
        Flag = cfg.Flag or LOCOPANI_ArgonId(cfg.Title), Name = cfg.Title or cfg.Name or "Slider",
        Description = cfg.Desc or cfg.Description, Range = { rangeMin, rangeMax },
        Increment = increment, CurrentValue = tonumber(default) or rangeMin, Callback = cfg.Callback,
    }))
end
function LOCOPANI_ArgonTab:Dropdown(cfg)
    cfg = cfg or {}
    local selected = cfg.CurrentOption
    if selected == nil then selected = cfg.Value end
    if selected == nil then selected = cfg.Default end
    local current = selected
    if current == nil or current == "" then current = {} end
    return LOCOPANI_ArgonControlAliases(self._tab:CreateDropdown({
        Flag = cfg.Flag or LOCOPANI_ArgonId(cfg.Title), Name = cfg.Title or cfg.Name or "Dropdown",
        Description = cfg.Desc or cfg.Description, Options = cfg.Options or cfg.Values or {},
        MultipleOptions = cfg.MultipleOptions == true or cfg.Multi == true,
        CurrentOption = current, Callback = cfg.Callback,
    }))
end
function LOCOPANI_ArgonTab:Input(cfg)
    cfg = cfg or {}
    return LOCOPANI_ArgonControlAliases(self._tab:CreateInput({
        Flag = cfg.Flag or LOCOPANI_ArgonId(cfg.Title), Name = cfg.Title or cfg.Name or "Input",
        Description = cfg.Desc or cfg.Description, CurrentValue = cfg.CurrentValue or cfg.Value or cfg.Default or "",
        PlaceholderText = cfg.PlaceholderText or cfg.Placeholder or "Enter value...", Callback = cfg.Callback,
    }))
end
function LOCOPANI_ArgonTab:Colorpicker(cfg)
    cfg = cfg or {}
    return LOCOPANI_ArgonControlAliases(self._tab:CreateColorPicker({
        Flag = cfg.Flag or LOCOPANI_ArgonId(cfg.Title), Name = cfg.Title or cfg.Name or "Color",
        Description = cfg.Desc or cfg.Description,
        CurrentValue = cfg.CurrentValue or cfg.Default or Color3.fromRGB(96, 205, 255), Callback = cfg.Callback,
    }))
end
function LOCOPANI_ArgonTab:Keybind(cfg)
    cfg = cfg or {}
    return LOCOPANI_ArgonControlAliases(self._tab:CreateKeybind({
        Flag = cfg.Flag or LOCOPANI_ArgonId(cfg.Title), Name = cfg.Title or cfg.Name or "Keybind",
        CurrentKeybind = cfg.CurrentKeybind or cfg.Value or cfg.Default or "RightShift",
        Toggle = cfg.Toggle == true or cfg.Mode == "Toggle", Callback = cfg.Callback or cfg.ChangedCallback,
        OnPressed = cfg.OnPressed or cfg.Callback, DisplayInKeybindList = false,
    }))
end
function LOCOPANI_ArgonTab:Label(cfg)
    cfg = cfg or {}
    return LOCOPANI_ArgonControlAliases(self._tab:CreateLabel(cfg.Title or cfg.Text or ""))
end
function LOCOPANI_ArgonTab:Divider()
    return self._tab:CreateDivider()
end

LOCOPANI_RAY_WINDOW = setmetatable({ _window = rawWindow }, {
    __index = function(self, key)
        if key == "Tab" then
            return function(_, cfg)
                cfg = cfg or {}
                return setmetatable({ _window = self._window, _tab = self._window:CreateTab(cfg.Title or "Tab", cfg.Icon or "activity") }, LOCOPANI_ArgonTab)
            end
        end
        if key == "Open" then return function() self._window:Open() end end
        if key == "Close" then return function() self._window:Close() end end
        if key == "Notify" then return function(_, message) Argon:Notify({ Title = "LOCOPANI", Content = tostring(message), Duration = 4 }) end end
        return self._window[key]
    end
})

-- Compatibility state for legacy LOCOPANI callbacks; no second visible UI is created.
v174.KeybindFrame = v174.KeybindFrame or { Visible = false }
v174.Options = v174.Options or {}
v174.Toggles = v174.Toggles or {}
v174.Notify = function(_, message)
    pcall(function() Argon:Notify({ Title = "LOCOPANI", Content = tostring(message), Duration = 4 }) end)
end
v174.Unload = function()
    pcall(function() rawWindow:Close() end)
end
v174.SetDPIScale = function() end
v174.SetNotifySide = function() end
LOCOPANIHUBWindow = setmetatable({}, {
    __index = function(_, key)
        if key == "SetCornerRadius" then return function() end end
        if key == "Notify" then return function(_, message) v174:Notify(message) end end
        if key == "Unload" then return function() v174:Unload() end end
        return function() end
    end
})
_G.LOCOPANI_WINDOW = LOCOPANIHUBWindow

end

-- Updates e criada primeiro para aparecer como a primeira categoria da UI principal.
local LOCOPANI_RAY_TABS = {
  Updates = LOCOPANI_RAY_WINDOW:Tab({ Title = "Updates", Icon = "history" }),
  Main = LOCOPANI_RAY_WINDOW:Tab({ Title = "Main", Icon = "house" }),
  Graphics = LOCOPANI_RAY_WINDOW:Tab({ Title = "Graphics", Icon = "sliders-horizontal" }),
  Character = LOCOPANI_RAY_WINDOW:Tab({ Title = "Character", Icon = "user-round" }),
  Visuals = LOCOPANI_RAY_WINDOW:Tab({ Title = "Visuals", Icon = "eye" }),
  ["Inventário Controlado"] = LOCOPANI_RAY_WINDOW:Tab({ Title = "Inventário Controlado", Icon = "package" }),
  Misc = LOCOPANI_RAY_WINDOW:Tab({ Title = "Misc", Icon = "settings-2" }),
  GameJoin = LOCOPANI_RAY_WINDOW:Tab({ Title = "Game Join", Icon = "gamepad-2" }),
  ["UI Settings"] = LOCOPANI_RAY_WINDOW:Tab({ Title = "UI Settings", Icon = "palette" }),
}

-- UI scale control: independent of the short open/close motion scale.
do
  local uiSettingsTab = LOCOPANI_RAY_TABS["UI Settings"]
  if uiSettingsTab then
    uiSettingsTab:Slider({
      Title = "Tamanho da UI",
      Flag = "LOCOPANI_UIScale",
      Range = { 70, 130 },
      Value = 100,
      Step = 5,
      Callback = function(value)
        local scaleObject = LOCOPANI_RAY_WINDOW and LOCOPANI_RAY_WINDOW._window
          and LOCOPANI_RAY_WINDOW._window._LOCOPANI_UserScale
        if scaleObject and scaleObject.Parent then
          scaleObject.Scale = math.clamp((tonumber(value) or 100) / 100, 0.70, 1.30)
        end
      end,
    })
  end
end

-- ============================================================
-- LOCOPANI Dynamic Island
-- Ilha flutuante no topo da tela com FPS, ping (ms) e o jogo atual.
-- Clique = expandir/recolher | Arrastar = mover | Opção em UI Settings.
-- (Dentro de função própria para não gastar registradores locais do arquivo.)
-- ============================================================
pcall(function()
  local env = (type(getgenv) == "function" and getgenv()) or _G
  if env.LOCOPANI_ISLAND and type(env.LOCOPANI_ISLAND.Destroy) == "function" then
    pcall(env.LOCOPANI_ISLAND.Destroy)
  end

  local Players = game:GetService("Players")
  local RunService = game:GetService("RunService")
  local TweenService = game:GetService("TweenService")
  local UserInputService = game:GetService("UserInputService")

  local ISLAND = {}
  env.LOCOPANI_ISLAND = ISLAND

  local COLLAPSED = UDim2.fromOffset(200, 36)
  local EXPANDED = UDim2.fromOffset(330, 68)
  local START = UDim2.fromOffset(44, 24)
  local PURPLE = Color3.fromRGB(150, 70, 255)

  local pos = { x = 0, y = 8 } -- posição (deslocamento do topo central)
  local gameName = nil
  local pingItem = nil
  local obj = nil

  local function parentGui(gui)
    pcall(function()
      if syn and syn.protect_gui then syn.protect_gui(gui) end
    end)
    if type(gethui) == "function" then
      local ok, hui = pcall(gethui)
      if ok and typeof(hui) == "Instance" and pcall(function() gui.Parent = hui end) then return end
    end
    if pcall(function() gui.Parent = game:GetService("CoreGui") end) then return end
    gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
  end

  local function fpsColor(v)
    if v >= 50 then return Color3.fromRGB(110, 255, 150) end
    if v >= 30 then return Color3.fromRGB(255, 214, 90) end
    return Color3.fromRGB(255, 95, 110)
  end

  local function pingColor(v)
    if v < 80 then return Color3.fromRGB(110, 255, 150) end
    if v < 150 then return Color3.fromRGB(255, 214, 90) end
    return Color3.fromRGB(255, 95, 110)
  end

  local function getPing()
    if not pingItem then
      pcall(function()
        pingItem = game:GetService("Stats").Network.ServerStatsItem["Data Ping"]
      end)
    end
    if pingItem then
      local ok, v = pcall(function() return pingItem:GetValue() end)
      if ok and type(v) == "number" then return math.floor(v + 0.5) end
    end
    local ok2, p = pcall(function() return Players.LocalPlayer:GetNetworkPing() end)
    if ok2 and type(p) == "number" then return math.floor(p * 1000 + 0.5) end
    return 0
  end

  local function loadGameName(callback)
    if gameName then callback(gameName) return end
    task.spawn(function()
      local ok, info = pcall(function()
        return game:GetService("MarketplaceService"):GetProductInfo(game.PlaceId)
      end)
      gameName = (ok and type(info) == "table" and info.Name) or game.Name or "Roblox"
      callback(gameName)
    end)
  end

  local function clampX(x)
    local cam = workspace.CurrentCamera
    local half = (cam and cam.ViewportSize.X or 1000) / 2 - 24
    return math.clamp(x, -half, half)
  end

  local function build()
    local gui = Instance.new("ScreenGui")
    gui.Name = "LOCOPANIIsland"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.DisplayOrder = 900000
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    parentGui(gui)

    local me = { gui = gui, conns = {}, expanded = false, touched = false }
    obj = me

    local holder = Instance.new("Frame")
    holder.Name = "Island"
    holder.AnchorPoint = Vector2.new(0.5, 0)
    holder.Position = UDim2.new(0.5, pos.x, 0, pos.y)
    holder.Size = START
    holder.BackgroundColor3 = Color3.fromRGB(8, 6, 14)
    holder.BorderSizePixel = 0
    holder.ClipsDescendants = true
    holder.Parent = gui
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 22)
    corner.Parent = holder
    local stroke = Instance.new("UIStroke")
    stroke.Color = PURPLE
    stroke.Thickness = 1.5
    stroke.Transparency = 0.35
    stroke.Parent = holder

    -- Modo compacto: só FPS e ping
    local compact = Instance.new("TextLabel")
    compact.Size = UDim2.fromScale(1, 1)
    compact.BackgroundTransparency = 1
    compact.Font = Enum.Font.GothamMedium
    compact.TextSize = 14
    compact.TextColor3 = Color3.fromRGB(235, 225, 255)
    compact.RichText = true
    compact.Text = "-- FPS  •  -- ms"
    compact.TextTransparency = 1
    compact.ZIndex = 2
    compact.Parent = holder

    -- Modo expandido: ícone do jogo + nome + FPS e ping
    local icon = Instance.new("ImageLabel")
    icon.Position = UDim2.fromOffset(10, 10)
    icon.Size = UDim2.fromOffset(48, 48)
    icon.BackgroundColor3 = Color3.fromRGB(30, 16, 52)
    icon.BorderSizePixel = 0
    icon.Image = "rbxthumb://type=GameIcon&id=" .. tostring(game.GameId) .. "&w=150&h=150"
    icon.ImageTransparency = 1
    icon.BackgroundTransparency = 0
    icon.ZIndex = 2
    icon.Parent = holder
    local iconCorner = Instance.new("UICorner")
    iconCorner.CornerRadius = UDim.new(0, 12)
    iconCorner.Parent = icon

    local nameL = Instance.new("TextLabel")
    nameL.Position = UDim2.fromOffset(68, 11)
    nameL.Size = UDim2.new(1, -80, 0, 22)
    nameL.BackgroundTransparency = 1
    nameL.Font = Enum.Font.GothamBold
    nameL.TextSize = 15
    nameL.TextXAlignment = Enum.TextXAlignment.Left
    nameL.TextTruncate = Enum.TextTruncate.AtEnd
    nameL.TextColor3 = Color3.fromRGB(255, 255, 255)
    nameL.Text = "Carregando..."
    nameL.TextTransparency = 1
    nameL.ZIndex = 2
    nameL.Parent = holder

    local statsL = Instance.new("TextLabel")
    statsL.Position = UDim2.fromOffset(68, 35)
    statsL.Size = UDim2.new(1, -80, 0, 20)
    statsL.BackgroundTransparency = 1
    statsL.Font = Enum.Font.GothamMedium
    statsL.TextSize = 13
    statsL.TextXAlignment = Enum.TextXAlignment.Left
    statsL.TextColor3 = Color3.fromRGB(190, 170, 230)
    statsL.RichText = true
    statsL.Text = "-- FPS  •  -- ms"
    statsL.TextTransparency = 1
    statsL.ZIndex = 2
    statsL.Parent = holder

    -- Botão invisível por cima (clique e arraste)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.fromScale(1, 1)
    btn.BackgroundTransparency = 1
    btn.Text = ""
    btn.AutoButtonColor = false
    btn.ZIndex = 5
    btn.Parent = holder

    local function setExpanded(v)
      me.expanded = v
      TweenService:Create(holder,
        TweenInfo.new(v and 0.5 or 0.4, v and Enum.EasingStyle.Back or Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
        { Size = v and EXPANDED or COLLAPSED }):Play()
      local fi = TweenInfo.new(0.22, Enum.EasingStyle.Quad)
      TweenService:Create(icon, fi, { ImageTransparency = v and 0 or 1, BackgroundTransparency = v and 0 or 1 }):Play()
      TweenService:Create(nameL, fi, { TextTransparency = v and 0 or 1 }):Play()
      TweenService:Create(statsL, fi, { TextTransparency = v and 0 or 1 }):Play()
      TweenService:Create(compact, fi, { TextTransparency = v and 1 or 0 }):Play()
    end

    -- Nome do jogo (busca uma vez e guarda)
    loadGameName(function(name)
      if obj == me and nameL.Parent then nameL.Text = name end
    end)

    -- FPS + ping: atualiza 2x por segundo (só mexe no texto quando muda)
    local frames, acc, lastText = 0, 0, ""
    table.insert(me.conns, RunService.RenderStepped:Connect(function(dt)
      frames = frames + 1
      acc = acc + dt
      if acc < 0.5 then return end
      local fps = math.floor(frames / acc + 0.5)
      frames, acc = 0, 0
      local ping = getPing()
      local text = string.format('<font color="#%s">%d</font> FPS  •  <font color="#%s">%d</font> ms',
        fpsColor(fps):ToHex(), fps, pingColor(ping):ToHex(), ping)
      if text ~= lastText then
        lastText = text
        compact.Text = text
        statsL.Text = text
      end
    end))

    -- Arrastar (move) e clique (expande/recolhe)
    local dragging, moved = false, false
    local dragStart, startX, startY = Vector3.new(), 0, 0
    local function isPress(i)
      return i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch
    end
    table.insert(me.conns, btn.InputBegan:Connect(function(input)
      if isPress(input) then
        dragging, moved = true, false
        dragStart, startX, startY = input.Position, pos.x, pos.y
      end
    end))
    table.insert(me.conns, UserInputService.InputChanged:Connect(function(input)
      if not dragging then return end
      if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
        local d = input.Position - dragStart
        if d.Magnitude > 6 then moved = true end
        if moved then
          pos.x = clampX(startX + d.X)
          pos.y = math.max(0, startY + d.Y)
          holder.Position = UDim2.new(0.5, pos.x, 0, pos.y)
        end
      end
    end))
    table.insert(me.conns, UserInputService.InputEnded:Connect(function(input)
      if dragging and isPress(input) then
        dragging = false
        if not moved then
          me.touched = true
          setExpanded(not me.expanded)
        end
      end
    end))

    me.holder = holder

    -- Entrada: nasce pequena, expande, e recolhe sozinha depois de uns segundos
    task.defer(function()
      if obj ~= me then return end
      setExpanded(true)
      task.delay(3.5, function()
        if obj == me and me.expanded and not me.touched then setExpanded(false) end
      end)
    end)
  end

  function ISLAND.Enable()
    if obj then return end
    local ok, err = pcall(build)
    if not ok then
      ISLAND.Disable()
      warn("[LOCOPANI] Dynamic Island falhou: " .. tostring(err))
    end
  end

  function ISLAND.Disable()
    local me = obj
    obj = nil
    if not me then return end
    for _, c in ipairs(me.conns) do pcall(function() c:Disconnect() end) end
    pcall(function() me.gui:Destroy() end)
  end

  function ISLAND.ResetPosition()
    pos.x, pos.y = 0, 8
    if obj and obj.holder then obj.holder.Position = UDim2.new(0.5, 0, 0, 8) end
  end

  ISLAND.Destroy = ISLAND.Disable
end)

-- Opção no menu (UI Settings): liga/desliga a ilha e reseta a posição.
pcall(function()
  local env = (type(getgenv) == "function" and getgenv()) or _G
  local ISLAND = env.LOCOPANI_ISLAND
  local tab = LOCOPANI_RAY_TABS and LOCOPANI_RAY_TABS["UI Settings"]
  if not ISLAND or not tab then return end

  local wanted = true
  -- Liga só quando o painel for revelado (depois da tela de carregamento)
  local function enableWhenReady()
    local L = env.LOCOPANI_LOADER
    if L and L.OnReveal then
      L.OnReveal(function() if wanted then ISLAND.Enable() end end)
    else
      ISLAND.Enable()
    end
  end

  pcall(function() tab:Section({ Title = "Dynamic Island" }) end)
  pcall(function()
    tab:Toggle({
      Title = "Dynamic Island",
      Flag = "LOCOPANI_DynamicIsland",
      Desc = "Ilha flutuante com FPS, ping (ms) e o jogo atual. Clique para expandir, arraste para mover.",
      CurrentValue = true,
      Callback = function(value)
        wanted = value == true
        if wanted then enableWhenReady() else ISLAND.Disable() end
      end,
    })
  end)
  pcall(function()
    tab:Button({
      Title = "Resetar posição da ilha",
      Callback = function() ISLAND.ResetPosition() end,
    })
  end)

  enableWhenReady()
end)

-- ============================================================
-- LOCOPANI Fontes
-- Dropdown em UI Settings para trocar a fonte da UI do LOCOPANI e (opcional) das telas do jogo.
-- Fontes proprias (Minecraft, Tracejado) vem embutidas em base64 e so
-- aparecem se o executor tiver writefile + getcustomasset.
-- A escolha fica salva em "locopani_font.dat".
-- ============================================================
pcall(function()
  local env = (type(getgenv) == "function" and getgenv()) or _G
  local tab = LOCOPANI_RAY_TABS and LOCOPANI_RAY_TABS["UI Settings"]
  if not tab then return end

  if env.LOCOPANI_FONTS and type(env.LOCOPANI_FONTS.Destroy) == "function" then
    pcall(env.LOCOPANI_FONTS.Destroy)
  end

  local FONTS = {}
  env.LOCOPANI_FONTS = FONTS

  local HttpService = game:GetService("HttpService")
  local DEFAULT_NAME = "Padrão (Gotham)"
  local FONT_FILE = "locopani_font.dat"
  local EXCLUDE = { LOCOPANILoading = true, LOCOPANIFX = true }

  -- Fontes proprias (arquivos .ttf embutidos em base64)
  local CUSTOM = {
    { name = "Minecraft", file = "locopani_font_minecraft", data = "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" },
    { name = "Tracejado", file = "locopani_font_tracejado", data = "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" },
  }

  -- Fontes que ja existem no Roblox
  local BUILTIN = {
    "Arcade", "Bangers", "Cartoon", "Code", "Creepster", "Fantasy", "FredokaOne",
    "Highway", "Jura", "LuckiestGuy", "Michroma", "Nunito", "Oswald",
    "PermanentMarker", "SciFi", "SpecialElite", "Ubuntu",
  }

  local writeFn = env.writefile or writefile
  local getAsset = env.getcustomasset or getcustomasset or env.getsynasset or getsynasset
  local hasCustom = type(writeFn) == "function" and type(getAsset) == "function"

  -- --------------------------------------------------------
  -- Decodificador base64 (Lua puro, igual em qualquer executor)
  -- --------------------------------------------------------
  local B64 = {}
  do
    local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    for i = 1, #chars do B64[string.byte(chars, i)] = i - 1 end
  end

  local function b64decode(s)
    local out, chunk, n = {}, {}, 0
    local buf, bits = 0, 0
    for i = 1, #s do
      local v = B64[string.byte(s, i)]
      if v then
        buf = buf * 64 + v
        bits = bits + 6
        if bits >= 8 then
          bits = bits - 8
          local p = 2 ^ bits
          local byte = math.floor(buf / p)
          buf = buf % p
          n = n + 1
          chunk[n] = string.char(byte)
          if n >= 4096 then
            out[#out + 1] = table.concat(chunk, "", 1, n)
            n = 0
          end
        end
      end
    end
    if n > 0 then out[#out + 1] = table.concat(chunk, "", 1, n) end
    return table.concat(out)
  end

  -- --------------------------------------------------------
  -- Criar / carregar a fonte
  -- --------------------------------------------------------
  local customCache = {}

  local function buildCustom(entry)
    if customCache[entry.name] then return customCache[entry.name] end
    local ttf = entry.file .. ".ttf"
    local json = entry.file .. ".json"
    writeFn(ttf, b64decode(entry.data))
    local family = HttpService:JSONEncode({
      name = entry.name,
      faces = {
        { name = "Regular", weight = 400, style = "normal", assetId = getAsset(ttf) },
      },
    })
    writeFn(json, family)
    local font = Font.new(getAsset(json))
    customCache[entry.name] = font
    return font
  end

  -- Devolve (fonte, ok). fonte = nil com ok = true significa "fonte padrao".
  local function resolve(name)
    if name == DEFAULT_NAME then return nil, true end
    for _, c in ipairs(CUSTOM) do
      if c.name == name then
        if not hasCustom then return nil, false end
        local ok, f = pcall(buildCustom, c)
        if ok and f then return f, true end
        return nil, false
      end
    end
    local ok, f = pcall(function() return Font.fromEnum(Enum.Font[name]) end)
    if ok and f then return f, true end
    return nil, false
  end

  -- --------------------------------------------------------
  -- Aplicar na UI (so ScreenGuis do LOCOPANI)
  -- --------------------------------------------------------
  local dead = false
  local current = nil
  local selectedName = DEFAULT_NAME
  local originals = setmetatable({}, { __mode = "k" })
  local hooked = setmetatable({}, { __mode = "k" })
  local conns = {}
  local scanId = 0
  local needFull = false
  local gameFonts = true
  local GAME_FILE = "locopani_font_game.dat"

  local function sameFont(a, b)
    return a.Family == b.Family and a.Weight == b.Weight and a.Style == b.Style
  end

  local function applyTo(inst)
    if not (inst:IsA("TextLabel") or inst:IsA("TextButton") or inst:IsA("TextBox")) then return end
    pcall(function()
      if current then
        local ff = inst.FontFace
        if originals[inst] == nil and not sameFont(ff, current) then originals[inst] = ff end
        if not sameFont(ff, current) then inst.FontFace = current end
      else
        local o = originals[inst]
        if o ~= nil then
          originals[inst] = nil
          inst.FontFace = o
        end
      end
    end)
  end

  local function getRoots()
    local roots = {}
    pcall(function()
      if type(gethui) == "function" then
        local h = gethui()
        if typeof(h) == "Instance" then roots[#roots + 1] = h end
      end
    end)
    pcall(function() roots[#roots + 1] = game:GetService("CoreGui") end)
    pcall(function()
      local pg = game:GetService("Players").LocalPlayer:FindFirstChild("PlayerGui")
      if pg then roots[#roots + 1] = pg end
    end)
    return roots
  end

  local function getPlayerGui()
    local pg
    pcall(function() pg = game:GetService("Players").LocalPlayer:FindFirstChild("PlayerGui") end)
    return pg
  end

  local function isMine(g)
    return string.sub(g.Name, 1, 8) == "LOCOPANI"
  end

  -- Telas do LOCOPANI e, se ligado, telas do jogo (PlayerGui)
  local function eachGui(fn)
    for _, root in ipairs(getRoots()) do
      for _, g in ipairs(root:GetChildren()) do
        if g:IsA("ScreenGui") and isMine(g) and not EXCLUDE[g.Name] then
          fn(g)
        end
      end
    end
    if gameFonts then
      local pg = getPlayerGui()
      if pg then
        for _, g in ipairs(pg:GetChildren()) do
          if g:IsA("LayerCollector") and not isMine(g) then fn(g) end
        end
      end
    end
  end

  -- Devolve a fonte original dos textos do jogo
  local function restoreGame()
    local pg = getPlayerGui()
    if not pg then return end
    local n = 0
    for _, g in ipairs(pg:GetChildren()) do
      if not isMine(g) then
        for _, inst in ipairs(g:GetDescendants()) do
          local o = originals[inst]
          if o ~= nil then
            originals[inst] = nil
            pcall(function() inst.FontFace = o end)
          end
          n = n + 1
          if n % 250 == 0 then task.wait() end
        end
      end
    end
  end

  local function scanAll()
    scanId = scanId + 1
    local my = scanId
    local n = 0
    eachGui(function(g)
      for _, inst in ipairs(g:GetDescendants()) do
        if dead or my ~= scanId then return end
        applyTo(inst)
        n = n + 1
        if n % 250 == 0 then task.wait() end
      end
    end)
  end

  -- --------------------------------------------------------
  -- Salvar / carregar escolha
  -- --------------------------------------------------------
  local function saveChoice(name)
    local w = env.writefile or writefile
    if type(w) == "function" then pcall(w, FONT_FILE, name) end
  end

  local function loadChoice()
    local isfileFn = env.isfile or isfile
    local readFn = env.readfile or readfile
    if type(isfileFn) ~= "function" or type(readFn) ~= "function" then return nil end
    local ok, exists = pcall(isfileFn, FONT_FILE)
    if not (ok and exists) then return nil end
    local ok2, txt = pcall(readFn, FONT_FILE)
    if ok2 and type(txt) == "string" then
      return (string.gsub(txt, "^%s*(.-)%s*$", "%1"))
    end
    return nil
  end

  local function notify(msg)
    pcall(function() LOCOPANI_RAY_WINDOW:Notify(msg) end)
  end

  -- --------------------------------------------------------
  -- Lista do dropdown
  -- --------------------------------------------------------
  local options = { DEFAULT_NAME }
  if hasCustom then
    for _, c in ipairs(CUSTOM) do options[#options + 1] = c.name end
  end
  for _, n in ipairs(BUILTIN) do
    local ok, item = pcall(function() return Enum.Font[n] end)
    if ok and item then options[#options + 1] = n end
  end

  local function isOption(name)
    for _, o in ipairs(options) do
      if o == name then return true end
    end
    return false
  end

  function FONTS.Set(name, silent)
    if dead or not isOption(name) then return false end
    local font, ok = resolve(name)
    if not ok then
      notify("Não foi possível carregar essa fonte neste executor.")
      return false
    end
    current = font
    selectedName = name
    saveChoice(name)
    task.spawn(scanAll)
    if not silent then notify("Fonte alterada: " .. name) end
    return true
  end

  function FONTS.Destroy()
    dead = true
    current = nil
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    conns = {}
    eachGui(function(g)
      for _, inst in ipairs(g:GetDescendants()) do applyTo(inst) end
    end)
    pcall(restoreGame)
  end

  -- --------------------------------------------------------
  -- Opcao no menu (UI Settings)
  -- --------------------------------------------------------
  local saved = loadChoice()
  if saved and isOption(saved) then selectedName = saved end
  pcall(function()
    local isfileFn = env.isfile or isfile
    local readFn = env.readfile or readfile
    if type(isfileFn) == "function" and type(readFn) == "function" and isfileFn(GAME_FILE) then
      gameFonts = string.find(readFn(GAME_FILE), "0", 1, true) == nil
    end
  end)

  pcall(function() tab:Section({ Title = "Fonte da UI" }) end)
  pcall(function()
    local desc = "Troca a fonte do menu e, se a opção abaixo estiver ligada, também dos textos do jogo. O Tracejado não tem números nem alguns símbolos; esses caracteres aparecem na fonte padrão."
    if not hasCustom then
      desc = "Fontes próprias (Minecraft e Tracejado) não funcionam neste executor. Só as fontes do Roblox estão disponíveis."
    end
    tab:Dropdown({
      Title = "Fonte",
      Flag = "LOCOPANI_UIFont",
      Desc = desc,
      Options = options,
      CurrentOption = selectedName,
      Callback = function(value)
        if type(value) == "table" then value = value[1] end
        if type(value) == "string" and value ~= selectedName then
          FONTS.Set(value)
        end
      end,
    })
  end)

  pcall(function()
    tab:Toggle({
      Title = "Aplicar fonte também no jogo",
      Flag = "LOCOPANI_UIFontGame",
      Desc = "Troca a fonte dos textos do jogo (placar, menus, botões). Desligue se algum texto ficar estranho.",
      CurrentValue = gameFonts,
      Callback = function(value)
        value = value == true
        if value == gameFonts then return end
        gameFonts = value
        local w = env.writefile or writefile
        if type(w) == "function" then pcall(w, GAME_FILE, value and "1" or "0") end
        if value then
          needFull = true
          if current then task.spawn(scanAll) end
        else
          task.spawn(restoreGame)
        end
      end,
    })
  end)

  -- Aplica a fonte salva e acompanha telas novas do LOCOPANI
  if selectedName ~= DEFAULT_NAME then
    FONTS.Set(selectedName, true)
  end

  task.spawn(function()
    local lastFull = os.clock()
    while not dead do
      pcall(function()
        eachGui(function(g)
          if not hooked[g] then
            hooked[g] = true
            local mine = isMine(g)
            conns[#conns + 1] = g.DescendantAdded:Connect(function(inst)
              if current and (mine or gameFonts) then task.defer(applyTo, inst) end
            end)
            needFull = true
          end
        end)
        if current and (needFull or os.clock() - lastFull > 5) then
          needFull = false
          lastFull = os.clock()
          scanAll()
        end
      end)
      task.wait(1)
    end
  end)
end)

-- Changelog isolado em um bloco proprio para liberar registradores locais.
do
  local history = {
    {
      date = "20/10/2026",
      title = "Update ocorrida",
      changes = {
        "Bug fixes",
        "Level Changer",
      },
    },
    {
      date = "20/10/2026",
      title = "ScoreEffect Changer",
      changes = {
        "Corrigido o equipamento visual local dos ScoreEffects.",
        "Atualizado o estado local de equipamento para aplicar o efeito visual.",
      },
    },
    {
      date = "20/10/2026",
      title = "Visual Level",
      changes = {
        "Corrigida a exibicao do nivel acima do personagem.",
        "Melhorada a atualizacao do BillboardGui do personagem.",
      },
    },
    {
      date = "18/10/2026",
      title = "Linkvertise Key System",
      changes = {
        "Corrigida a validacao de respostas JSON e texto simples do Linkvertise Anti-Bypass.",
        "Respostas JSON validas com status true passaram a ser reconhecidas corretamente.",
      },
    },
  }

  -- Erros no conteudo do changelog nao devem impedir a inicializacao do hub.
  pcall(function()
    local updatesTab = LOCOPANI_RAY_TABS.Updates
    if not updatesTab then return end
    updatesTab:Section({ Title = "Historico de atualizacoes", Box = true, Opened = true })
    for _, update in ipairs(history) do
      updatesTab:Section({ Title = update.date .. " - " .. update.title, Box = true, Opened = true })
      for _, change in ipairs(update.changes) do
        updatesTab:Paragraph({ Title = "Update ocorrida", Desc = "- " .. change })
      end
    end
    updatesTab:Section({ Title = "Como adicionar uma update", Box = true, Opened = true })
    updatesTab:Paragraph({
      Title = "Dica",
      Desc = "Adicione novas entradas a tabela history neste bloco, com data, titulo e lista de mudancas.",
    })
  end)
end

local function LOCOPANI_RayControl(kind, tab, name, cfg, callback)
  cfg = cfg or {}
  local title = cfg.Text or cfg.Name or name or kind
  local initial = cfg.Default
  local handle = { Value = initial, _control = nil, _callbacks = {}, Values = cfg.Values }
  local function onValue(value, ...)
    if kind == "Dropdown" and type(value) == "table" and cfg.Multi ~= true then value = value[1] end
    handle.Value = value
    if callback then callback(value, ...) end
    for _, fn in ipairs(handle._callbacks) do task.spawn(fn, value) end
  end
  local flag = tostring(name or title or kind)
  if LOCOPANI_ARGON and LOCOPANI_ARGON.Flags and LOCOPANI_ARGON.Flags[flag] then
    flag = flag .. "_" .. tostring(math.floor(os.clock() * 1000000))
  end
  local common = { Flag = flag, Name = title, Description = cfg.Tooltip or cfg.Description, Callback = onValue }
  local h
  if kind == "Toggle" then
    common.CurrentValue = cfg.Default == true
    h = tab:Toggle(common)
  elseif kind == "Button" then
    common.Callback = callback or cfg.Func or cfg.Callback
    h = tab:Button(common)
  elseif kind == "Slider" then
    common.Range = { cfg.Min or 0, cfg.Max or 100 }
    common.Increment = cfg.Increment or (cfg.Rounding and cfg.Rounding > 0 and 10 ^ (-cfg.Rounding)) or 1
    common.CurrentValue = cfg.Default or cfg.Min or 0
    h = tab:Slider(common)
  elseif kind == "Dropdown" then
    common.Options = cfg.Values or {}
    common.MultipleOptions = cfg.Multi == true
    local selected = cfg.Default
    if selected == nil or selected == "" then selected = {} end
    common.CurrentOption = selected
    h = tab:Dropdown(common)
  elseif kind == "Input" or kind == "TextBox" then
    common.CurrentValue = cfg.Default or ""
    common.PlaceholderText = cfg.Placeholder or title
    h = tab:Input(common)
  elseif kind == "ColorPicker" then
    common.CurrentValue = cfg.Default or Color3.fromRGB(96, 205, 255)
    h = tab:Colorpicker(common)
  elseif kind == "Keybind" then
    common.CurrentKeybind = tostring(cfg.Default or "RightShift")
    common.Callback = cfg.ChangedCallback
    common.OnPressed = callback or cfg.Callback
    common.Toggle = cfg.Mode == "Toggle"
    h = tab:Keybind(common)
  elseif kind == "Label" then
    h = tab:Label({ Title = title, Text = title })
  elseif kind == "Divider" then
    h = tab:Divider()
  end
  handle._control = h
  if h then
    handle.Value = h.CurrentValue ~= nil and h.CurrentValue or handle.Value
    if kind == "Dropdown" and h.CurrentOption then
      handle.Value = cfg.Multi == true and h.CurrentOption or h.CurrentOption[1]
    end
  end
  function handle:SetValue(value, silent)
    self.Value = value
    local control = self._control
    if control then
      local ok = false
      for _, methodName in ipairs({"Set", "Select", "Update"}) do
        local method = control[methodName]
        if type(method) == "function" then ok = pcall(method, control, value, silent); if ok then break end end
      end
    end
    if not silent then
      local cb = callback or cfg.Callback
      if cb then task.spawn(cb, value) end
      for _, fn in ipairs(self._callbacks) do task.spawn(fn, value) end
    end
  end
  function handle:Set(value, silent) return self:SetValue(value, silent) end
  function handle:GetValue() return self.Value end
  function handle:SetValues(values)
    self.Values = values or {}
    local control = self._control
    if not control then return end
    for _, methodName in ipairs({"Refresh", "SetOptions", "SetValues", "UpdateOptions"}) do
      local method = control[methodName]
      if type(method) == "function" then
        local ok = pcall(method, control, self.Values, true)
        if ok then return true end
      end
    end
    pcall(function() control.Options = self.Values end)
    return false
  end
  function handle:OnChanged(fn) table.insert(self._callbacks, fn); return self end
  function handle:SetText(value)
    local control = self._control
    if control and control.SetContent then pcall(control.SetContent, control, tostring(value))
    elseif control and control.SetDesc then pcall(control.SetDesc, control, tostring(value))
    elseif control and control.SetTitle then pcall(control.SetTitle, control, tostring(value)) end
  end
  function handle:AddKeyPicker(keyName, keyCfg)
    return LOCOPANI_RayControl("Keybind", tab, keyName, keyCfg, keyCfg and keyCfg.Callback)
  end
  -- Yield one frame while building a large menu so the client can render between controls.
  task.wait()
  return handle
end

local LOCOPANI_RayGroup = {}
LOCOPANI_RayGroup.__index = LOCOPANI_RayGroup
function LOCOPANI_RayGroup:AddLeftGroupbox(name)
  self._tab:Section({ Title = name, Box = true, Opened = true })
  return setmetatable({ _tab = self._tab }, LOCOPANI_RayGroup)
end
function LOCOPANI_RayGroup:AddRightGroupbox(name) return self:AddLeftGroupbox(name) end
function LOCOPANI_RayGroup:AddToggle(name, cfg)
  local h = LOCOPANI_RayControl("Toggle", self._tab, name, cfg, cfg and cfg.Callback)
  if v174 and v174.Toggles then v174.Toggles[name] = h end
  toggles[name] = h
  return h
end
function LOCOPANI_RayGroup:AddButton(name, callback)
  local cfg = type(name) == "table" and name or { Text = name, Func = callback }
  local h = LOCOPANI_RayControl("Button", self._tab, nil, cfg, cfg.Func or cfg.Callback)
  return h
end
function LOCOPANI_RayGroup:AddSlider(name, cfg)
  local h = LOCOPANI_RayControl("Slider", self._tab, name, cfg, cfg and cfg.Callback)
  options[name] = h; v174.Options[name] = h
  return h
end
function LOCOPANI_RayGroup:AddColorPicker(name, cfg)
  local h = LOCOPANI_RayControl("ColorPicker", self._tab, name, cfg, cfg and cfg.Callback)
  options[name] = h; v174.Options[name] = h
  return h
end
function LOCOPANI_RayGroup:AddDropdown(name, cfg)
  local h = LOCOPANI_RayControl("Dropdown", self._tab, name, cfg, cfg and cfg.Callback)
  options[name] = h; v174.Options[name] = h
  return h
end
function LOCOPANI_RayGroup:AddInput(name, cfg) return self:AddTextBox(name, cfg) end
function LOCOPANI_RayGroup:AddTextBox(name, cfg)
  local h = LOCOPANI_RayControl("TextBox", self._tab, name, cfg, cfg and cfg.Callback)
  options[name] = h; v174.Options[name] = h
  return h
end
function LOCOPANI_RayGroup:AddLabel(name)
  return LOCOPANI_RayControl("Label", self._tab, nil, { Text = name })
end
function LOCOPANI_RayGroup:AddDivider() return LOCOPANI_RayControl("Divider", self._tab, nil, {}) end
function LOCOPANI_RayGroup:AddKeyPicker(name, cfg)
  local h = LOCOPANI_RayControl("Keybind", self._tab, name, cfg, cfg and cfg.Callback)
  options[name] = h; v174.Options[name] = h
  return h
end

v545 = {}
for key, rayTab in pairs(LOCOPANI_RAY_TABS) do
  v545[key] = setmetatable({ _tab = rayTab }, LOCOPANI_RayGroup)
end

v546 = {}
v546.LeftGroupBox = v545.Main:AddLeftGroupbox("Spike Settings")

v546.LeftGroupBox:AddToggle("redirectspike", {
  Text = "Redirect Spike",
  Tooltip = "Redirect spike to camera direction",
  Default = false,
  Callback = function(value104)
    if value104 then
      f64()
    else
      f66()
    end
  end,
})

v546.LeftGroupBox:AddToggle("autocorner", {
  Text = "Auto Corner",
  Tooltip = "Aims to the corner sides of the enemy's goal",
  Default = false,
  Callback = function(value105)
    v255.enabled = value105

    if value105 then
      v255.installAim()
    end
  end,
})

v546.LeftGroupBox:AddDropdown("autocornerside", {
  Values = { "Auto", "Left", "Right" },
  Default = "Auto",
  Text = "Corner Side",
  Callback = function(value106) v255.side = value106 end,
})

v546.LeftGroupBox:AddDropdown("autocornerreach", {
  Values = { "All", "Back", "Nearest" },
  Default = "All",
  Text = "Corner Depth",
  Callback = function(value107) v255.reach = value107 end,
})

v546.LeftGroupBox:AddLabel("Auto Corner bind"):AddKeyPicker("autocornerbind", {
  Default = "C",
  Mode = "Press",
  Text = "Auto Corner",
  Callback = function()
    local autocorner = toggles.autocorner

    if autocorner then
      autocorner:SetValue(not autocorner.Value)
    end
  end,
})

v546.LeftGroupBox:AddToggle("newspike", {
  Text = "Silent Spike",
  Tooltip = "Spike with no animation or sound",
  Default = false,
  Callback = function(value108)
    v188 = value108

    if textButton2 then
      textButton2.Visible = value108
    end
  end,
})

v546.LeftGroupBox:AddLabel("Silent Spike bind"):AddKeyPicker("newspikebind", {
  Default = "R",
  Mode = "Press",
  Text = "Silent Spike",
  Callback = function() f75() end,
})

v546.LeftGroupBox:AddToggle("sanju", {
  Text = "Sanju Tilt",
  Tooltip = "Sanju tilt effect",
  Default = false,
  Callback = function(value109)
    if value109 then
      f67()
    else
      f68()
    end
  end,
})

v546.LeftGroupBox:AddToggle("maxcharge", {
  Text = "Max Charge Special",
  Tooltip = "Max charge your special",
  Default = false,
  Callback = function(value110)
    if value110 then
      f70()
    else
      f71()
    end
  end,
})

v546.LeftGroupBox:AddToggle("autofarm", {
  Text = "Auto Farm",
  Tooltip = "Spike/Block/Jump/TP farm loop with its own GUI",
  Default = false,
  Callback = function(value111)
    if value111 then
      v308.start()
    else
      v308.stop()
    end
  end,
})

v546.LeftGroupBox:AddToggle("fakespike", {
  Text = "Fake Spike",
  Tooltip = "Auto fake spike when jumping",
  Default = false,
  Callback = function(value112) v221 = value112 end,
})

v546.LeftGroupBox:AddToggle("autocounter", {
  Text = "Auto Counter",
  Tooltip = "Counters an enemy spike when both of you are at the net",
  Default = false,
  Callback = function(value113) v395.state.enabled = value113 end,
})

v546.LeftGroupBox:AddDropdown("autocountermove", {
  Values = { "Auto", "Block", "Spike" },
  Default = "Auto",
  Text = "Counter Move",
  Tooltip = "Auto: block while the ball is still on their half, spike once it crosses",
  Callback = function(value114) v395.state.move = value114 end,
})

v546.LeftGroupBox:AddSlider("autocounternetrange", {
  Text = "Counter Net Range",
  Default = 9,
  Min = 3,
  Max = 20,
  Rounding = 1,
  Callback = function(value115) v395.state.netRange = value115 end,
})

v546.LeftGroupBox:AddSlider("autocounterlateral", {
  Text = "Counter Width",
  Default = 14,
  Min = 4,
  Max = 30,
  Rounding = 1,
  Callback = function(value116) v395.state.lateral = value116 end,
})

v546.LeftGroupBox:AddSlider("autocounterdelay", {
  Text = "Counter Delay",
  Default = 0.05,
  Min = 0,
  Max = 0.5,
  Rounding = 2,
  Callback = function(value117) v395.state.delay = value117 end,
})

v546.LeftGroupBox:AddToggle("autocounterjump", {
  Text = "Counter Auto Jump",
  Tooltip = "Jump before the counter, the block hitbox dies the moment you land",
  Default = true,
  Callback = function(value118) v395.state.autoJump = value118 end,
})

v546.LeftGroupBox:AddLabel("Auto Counter bind"):AddKeyPicker("autocounterbind", {
  Default = "N",
  Mode = "Press",
  Text = "Auto Counter",
  Callback = function()
    local autocounter = toggles.autocounter

    if autocounter then
      autocounter:SetValue(not autocounter.Value)
    end
  end,
})

v546.AutoSetGroup = v545.Main:AddLeftGroupbox("Auto Set")

v546.AutoSetGroup:AddToggle("autoset", {
  Text = "Auto Set",
  Tooltip = "Aims and fires a set at the target",
  Default = false,
  Callback = function(value119)
    v323.enabled = value119

    if value119 then
      v323.start()
    else
      v323.stop()
    end
  end,
})

v546.AutoSetGroup:AddDropdown("autosettarget", {
  Values = { "Nearest", "Random" },
  Default = "Nearest",
  Text = "Target Mode",
  Callback = function(value120) v323.mode = value120 end,
})

v546.AutoSetGroup:AddLabel("Set keybind"):AddKeyPicker("autosetfirebind", {
  Default = "F",
  Mode = "Press",
  Text = "Set",
  NoUI = false,
  Callback = function()
    if not v323.enabled then
      return
    end

    if v323.fire() then
      v174:Notify("Set fired")
    else
      v174:Notify("No target or no ball")
    end
  end,
})

v546.AimSetGroup = v545.Main:AddLeftGroupbox("Aim Set")

v546.AimSetGroup:AddToggle("aimset", {
  Text = "Aim Set",
  Tooltip = "Auto-aims any JumpSet at the target",
  Default = false,
  Callback = function(value121)
    v329.enabled = value121

    if value121 then
      v329.start()
    else
      v329.stop()
    end
  end,
})

v546.AimSetGroup:AddDropdown("aimsettarget", {
  Values = { "Nearest", "Random" },
  Default = "Nearest",
  Text = "Target Mode",
  Callback = function(value122) v329.mode = value122 end,
})

v546.HitboxGroup = v545.Main:AddRightGroupbox("Hitbox Settings")

v546.HitboxGroup:AddToggle("hitboxenable", {
  Text = "Enable Hitbox",
  Tooltip = "Turn Hitbox ON/OFF",
  Default = false,
  Callback = function(value123)
    if value123 then
      enableHitbox()
    else
      disableHitbox()
    end
  end,
})

v546.HitboxGroup:AddSlider("hitboxsize", {
  Text = "Hitbox Size",
  Tooltip = "Reach in studs, the server refuses anything past 20",
  Default = 5,
  Min = 0,
  Max = 20,
  Rounding = 1,
  Callback = function(value124) setHitboxScale(value124) end,
})

v546.HitboxGroup:AddDropdown("hitboxcolor", {
  Values = {
    "Invisible", "White", "Green", "Blue", "Red", "Yellow", "Purple", "Orange", "Pink",
  },
  Default = "Blue",
  Text = "Hitbox Color",
  Callback = function(value125)
    local Color3_5 = Color3.fromRGB(255, 255, 255)
    local Color3_6 = Color3.fromRGB(255, 255, 255)
    local Color3_7 = Color3.fromRGB(0, 255, 0)
    local Color3_8 = Color3.fromRGB(0, 0, 255)
    local Color3_9 = Color3.fromRGB(255, 0, 0)
    local Color3_10 = Color3.fromRGB(255, 255, 0)
    local Color3_11 = Color3.fromRGB(128, 0, 128)
    local Color3_12 = Color3.fromRGB(255, 165, 0)
    local Color3_13 = Color3.fromRGB(255, 105, 180)

    local v547 = {
      Invisible = 1,
      White = 0.3,
      Green = 0.3,
      Blue = 0.3,
      Red = 0.3,
      Yellow = 0.3,
      Purple = 0.3,
      Orange = 0.3,
      Pink = 0.3,
    }

    setHitboxColor(({
      Invisible = Color3_5,
      White = Color3_6,
      Green = Color3_7,
      Blue = Color3_8,
      Red = Color3_9,
      Yellow = Color3_10,
      Purple = Color3_11,
      Orange = Color3_12,
      Pink = Color3_13,
    })[value125] or Color3.fromRGB(0, 0, 255))

    setHitboxTransparency(v547[value125] or 0.3)

    if v178 then
      f39(v179)
    end
  end,
})

v546.HitboxGroup:AddButton({ Text = "Remove Hitboxes", Func = function() f37() end })

v546.HitboxGroup:AddButton({
  Text = "Show Stop Ball",
  Func = function()
    v189 = not v189

    if textButton4 then
      textButton4.Visible = v189
    else
      textButton4 = f82()
    end
  end,
})

v546.HitboxGroup:AddButton({
  Text = "Show Aim",
  Func = function()
    v190 = not v190

    if textButton5 then
      textButton5.Visible = v190
    else
      textButton5 = f93()
    end
  end,
})

do
  v546.GraphicsGroup = v545.Graphics:AddLeftGroupbox("Graphics Settings")

  -- Anti-Lag remains a local-only optimization. When score-effect preservation
  -- is enabled, f126 skips recognizable score-effect descendants.
  v546.GraphicsGroup:AddToggle("antilag", {
    Text = "Anti-Lag",
    Tooltip = "Reduce graphics for better performance",
    Default = false,
    Callback = function(value126)
      if value126 then
        f120()
      else
        f119()
      end
    end,
  })

  v546.GraphicsGroup:AddToggle("scoreeffectvisuals", {
    Text = "Preserve Score Effect Visuals (FPS Friendly)",
    Tooltip = "Preserves recognizable score-effect particles, lights, beams, trails, glow, and textures from Anti-Lag changes. Does not force Roblox engine graphics to maximum.",
    Default = false,
    Callback = function(value)
      _G.LOCOPANI_PRESERVE_SCORE_EFFECTS = value == true
      -- FPS-friendly mode: never raise global Roblox quality for a score.
      LOCOPANI_SCORE_QUALITY_ENABLED = false
      LOCOPANI_RestoreTemporaryScoreQuality()
      if value and v231 then
        -- Restore saved properties for recognizable score-effect assets that
        -- Anti-Lag already simplified. This is best-effort: Roblox's global
        -- rendering quality still controls engine-level particle fidelity.
        -- Collect first, then mutate v231 safely after iteration.
        local restoreList = {}
        for instance, savedProperties in pairs(v231) do
          local ancestor = instance
          local isScoreEffect = false
          for _ = 1, 12 do
            if not ancestor then break end
            local lowerName = string.lower(ancestor.Name)
            if string.find(lowerName, "score", 1, true)
              or string.find(lowerName, "effect", 1, true)
              or string.find(lowerName, "supernova", 1, true)
              or string.find(lowerName, "groundhit", 1, true)
              or string.find(lowerName, "impact", 1, true)
              or string.find(lowerName, "point", 1, true)
              or string.find(lowerName, "vfx", 1, true)
              or string.find(lowerName, "particle", 1, true)
              or string.find(lowerName, "aura", 1, true)
              or string.find(lowerName, "burst", 1, true)
              or string.find(lowerName, "celebration", 1, true)
              or string.find(lowerName, "hitindicator", 1, true)
              or string.find(lowerName, "spike", 1, true)
              or string.find(lowerName, "shockwave", 1, true)
              or string.find(lowerName, "ring", 1, true)
              or string.find(lowerName, "glow", 1, true)
              or string.find(lowerName, "flash", 1, true)
              or string.find(lowerName, "spark", 1, true)
              or string.find(lowerName, "explosion", 1, true)
              or string.find(lowerName, "nova", 1, true)
              or string.find(lowerName, "charge", 1, true)
              or string.find(lowerName, "trail", 1, true)
              or string.find(lowerName, "beam", 1, true) then
              isScoreEffect = true
              break
            end
            ancestor = ancestor.Parent
          end
          if isScoreEffect then
            table.insert(restoreList, {instance = instance, properties = savedProperties})
          end
        end

        for _, entry in ipairs(restoreList) do
          for property, originalValue in pairs(entry.properties) do
            pcall(function() entry.instance[property] = originalValue end)
          end
          v231[entry.instance] = nil
        end
      end
    end,
  })

  -- Keep the V9 optimizer profiles but place them in Graphics.
  do
    local LOCOPANI_GRAPHICS_PROFILE = "Balanced Graphics"
    local LOCOPANI_GRAPHICS_APPLYING = false
    local LOCOPANI_GRAPHICS_ORIGINAL_QUALITY = nil
    local LOCOPANI_GRAPHICS_ORIGINAL_SAVED_QUALITY = nil
    v546.GraphicsGroup:AddDropdown("graphicsquality", {
      Text = "Graphics Optimizer",
      Tooltip = "Choose a local graphics profile. Higher quality may reduce FPS on weaker PCs.",
      Values = {"Balanced Graphics", "Ultra Graphics", "FPS Boost", "Restore Default"},
      Default = "Balanced Graphics",
      Callback = function(profile)
        if LOCOPANI_GRAPHICS_APPLYING or type(profile) ~= "string" then return end
        LOCOPANI_GRAPHICS_APPLYING = true
        local ok, err = pcall(function()
          if LOCOPANI_GRAPHICS_ORIGINAL_QUALITY == nil then
            f119()
            local rendering = settings().Rendering
            local userGameSettings = UserSettings():GetService("UserGameSettings")
            LOCOPANI_GRAPHICS_ORIGINAL_QUALITY = rendering.QualityLevel
            pcall(function()
              LOCOPANI_GRAPHICS_ORIGINAL_SAVED_QUALITY = userGameSettings.SavedQualityLevel
            end)
          else
            f119()
          end

          if profile == "FPS Boost" then
            f120()
            LOCOPANI_GRAPHICS_PROFILE = profile
            v174:Notify("Graphics Optimizer: FPS Boost enabled")
          elseif profile == "Balanced Graphics" or profile == "Ultra Graphics" then
            local rendering = settings().Rendering
            local userGameSettings = UserSettings():GetService("UserGameSettings")
            local target = profile == "Ultra Graphics" and Enum.QualityLevel.Level10 or Enum.QualityLevel.Level06
            rendering.QualityLevel = target
            pcall(function()
              userGameSettings.SavedQualityLevel = profile == "Ultra Graphics"
                and Enum.SavedQualitySetting.QualityLevel10
                or Enum.SavedQualitySetting.QualityLevel6
            end)
            LOCOPANI_GRAPHICS_PROFILE = profile
            v174:Notify(profile .. " enabled. FPS depends on your PC and game settings.")
          elseif profile == "Restore Default" then
            local rendering = settings().Rendering
            rendering.QualityLevel = LOCOPANI_GRAPHICS_ORIGINAL_QUALITY
            pcall(function()
              if LOCOPANI_GRAPHICS_ORIGINAL_SAVED_QUALITY ~= nil then
                UserSettings():GetService("UserGameSettings").SavedQualityLevel = LOCOPANI_GRAPHICS_ORIGINAL_SAVED_QUALITY
              end
            end)
            LOCOPANI_GRAPHICS_ORIGINAL_QUALITY = nil
            LOCOPANI_GRAPHICS_ORIGINAL_SAVED_QUALITY = nil
            LOCOPANI_GRAPHICS_PROFILE = profile
            v174:Notify("Graphics quality restored to its original setting")
          end
        end)
        if not ok then
          warn("LOCOPANI Graphics Optimizer: " .. tostring(err))
          pcall(function() v174:Notify("Graphics profile could not be fully applied") end)
        end
        LOCOPANI_GRAPHICS_APPLYING = false
      end,
    })
  end
end -- Graphics category scope; keep module-level locals low

v546.MoveGroup = v545.Main:AddRightGroupbox("Movement")

v546.MoveGroup:AddToggle("desync", {
  Text = "Desync",
  Tooltip = "Desync movement",
  Default = false,
  Callback = function(value127)
    if value127 then
      f76()
    else
      f74()
    end
  end,
})

v546.MoveGroup:AddToggle("autoreceive", {
  Text = "Auto Receive",
  Tooltip = "Auto receive the ball when grounded and in range",
  Default = false,
  Callback = function(value128)
    v243.enabled = value128

    if value128 then
      v243.start()
    else
      v243.stop()
    end
  end,
})

v546.MoveGroup:AddSlider("autoreceiverange", {
  Text = "Receive Range",
  Default = 20,
  Min = 3,
  Max = 50,
  Rounding = 1,
  Callback = function(value129) v243.setRadius(value129) end,
})

v546.MoveGroup:AddLabel("Auto Receive bind"):AddKeyPicker("autoreceivebind", {
  Default = "X",
  Mode = "Press",
  Text = "Auto Receive",
  Callback = function()
    local autoreceive = toggles.autoreceive

    if autoreceive then
      autoreceive:SetValue(not autoreceive.Value)
    end
  end,
})

v546.MoveGroup:AddToggle("kisukidive", {
  Text = "Kisuki Dive",
  Tooltip = "Kisuki super dive",
  Default = false,
  Callback = function(value130)
    v440.enabled = value130

    if value130 then
      v440.install()
    end
  end,
})

v546.MoveGroup:AddSlider("kisukicharge", {
  Text = "Dive Charge",
  Tooltip = "Lerps Kimiro's real 19.5-45 power range, past 0.5 the FX go strong",
  Default = 1,
  Min = 0,
  Max = 1,
  Rounding = 2,
  Callback = function(value131) v440.charge = value131 end,
})

v546.MoveGroup:AddToggle("akaridash", {
  Text = "Akari Dash",
  Tooltip = "Dash into the ball",
  Default = false,
  Callback = function(value132)
    v191 = value132

    if textButton3 then
      textButton3.Visible = value132
    end
  end,
})

v546.MoveGroup:AddLabel("Akari Dash bind"):AddKeyPicker("akaridashbind", {
  Default = "F",
  Mode = "Press",
  Text = "Akari Dash",
  Callback = function() f79() end,
})

v546.MoveGroup:AddToggle("leadfeet", {
  Text = "Lead Feet",
  Tooltip = "Slams you down at the ability's own -10000 acceleration",
  Default = false,
  Callback = function(value133)
    v192 = value133

    if textButton6 then
      textButton6.Visible = value133
    end
  end,
})

v546.MoveGroup:AddLabel("Lead Feet bind"):AddKeyPicker("leadfeetbind", {
  Default = "G",
  Mode = "Press",
  Text = "Lead Feet",
  Callback = function() f102() end,
})

v546.MaxServeGroup = v545.Main:AddLeftGroupbox("Max Serve")

v546.MaxServeGroup:AddToggle("maxserve", {
  Text = "Max Serve",
  Tooltip = "Max serve power",
  Default = false,
  Callback = function(value134)
    if value134 then
      f101()
    else
      f100()
    end
  end,
})

v546.MaxServeGroup:AddToggle("esp", {
  Text = "Jump ESP",
  Tooltip = "Highlight enemies while they are jumping",
  Default = false,
  Callback = function(value135)
    v193 = value135

    if not value135 then
      for key21 in pairs(v194) do
        f96(key21)
      end
    end
  end,
})

v546.DataGroup = v545.Main:AddRightGroupbox("Data")

v546.DataGroup:AddButton({
  Text = "Data Rollback",
  Func = function()
    replicatedStorage:WaitForChild("Packages"):WaitForChild("_Index"):WaitForChild("sleitnick_knit@1.7.0"):WaitForChild("knit"):WaitForChild("Services"):WaitForChild("SettingsService"):WaitForChild("RF"):WaitForChild("UpdateKeybind"):InvokeServer(
      "MouseButton1", true, "Spike​\143"
    )

    teleportService:Teleport(game.PlaceId)
  end,
})

v546.CharAttrGroup = v545.Character:AddLeftGroupbox("Attributes")

v546.CharAttrGroup:AddInput("divespeed", {
  Default = "",
  Numeric = true,
  Finished = true,
  Text = "Dive Speed",
  Placeholder = "0.95",
  Callback = function(value136)
    local ToNumber_2 = tonumber(value136)

    if ToNumber_2 then
      localPlayer2:SetAttribute("Multiplier_DiveSpeed", ToNumber_2)
    end
  end,
})

v546.CharAttrGroup:AddInput("jumppower", {
  Default = "",
  Numeric = true,
  Finished = true,
  Text = "Jump Power",
  Placeholder = "1.1",
  Callback = function(value137)
    local ToNumber_3 = tonumber(value137)

    if ToNumber_3 then
      localPlayer2:SetAttribute("Multiplier_JumpPower", ToNumber_3)
    end
  end,
})

v546.CharAttrGroup:AddInput("speed", {
  Default = "",
  Numeric = true,
  Finished = true,
  Text = "Speed",
  Placeholder = "0.85",
  Callback = function(value138)
    local ToNumber_4 = tonumber(value138)

    if ToNumber_4 then
      localPlayer2:SetAttribute("Multiplier_Speed", ToNumber_4)
    end
  end,
})

v546.BallESPGroup = v545.Character:AddLeftGroupbox("Ball ESP")

v546.BallESPGroup:AddToggle("ballesp", {
  Text = "Ball ESP",
  Tooltip = "Highlights the player who last touched the ball",
  Default = false,
  Callback = function(value139)
    v242.enabled = value139

    if value139 then
      v242.start()
    else
      v242.stop()
    end
  end,
})

v546.BallESPGroup:AddDropdown("ballespcolor", {
  Values = { "Red", "Green", "Blue", "Yellow", "Purple", "Orange", "Pink", "Cyan", "White" },
  Default = "Red",
  Text = "ESP Color",
  Callback = function(value140)
    local v551 = ({
      Red = Color3.fromRGB(255, 0, 0),
      Green = Color3.fromRGB(0, 255, 0),
      Blue = Color3.fromRGB(0, 0, 255),
      Yellow = Color3.fromRGB(255, 255, 0),
      Purple = Color3.fromRGB(128, 0, 128),
      Orange = Color3.fromRGB(255, 165, 0),
      Pink = Color3.fromRGB(255, 105, 180),
      Cyan = Color3.fromRGB(0, 255, 255),
      White = Color3.fromRGB(255, 255, 255),
    })[value140]

    v242.setColor(v551 or Color3.fromRGB(255, 0, 0))
  end,
})

v546.CharMoveGroup = v545.Character:AddRightGroupbox("Movement")

v546.CharMoveGroup:AddToggle("airmove", {
  Text = "Air Movement",
  Tooltip = "Move in the air",
  Default = false,
  Callback = function(value141)
    local v552 = not value141
    v199 = value141

    if v552 and bodyVelocity then
      bodyVelocity:Destroy()
      bodyVelocity = nil
    end
  end,
})

v546.CharMoveGroup:AddSlider("airspeed", {
  Text = "Air Movement Speed",
  Default = 16,
  Min = 0,
  Max = 100,
  Rounding = 0,
  Callback = function(value142) v200 = value142 end,
})

v546.CharMoveGroup:AddToggle("autoshiftlock", {
  Text = "Auto Shift Lock",
  Tooltip = "Auto rotate to camera when jumping",
  Default = false,
  Callback = function(value143) f112(value143) end,
})

v546.CharMoveGroup:AddLabel("Auto Shift Lock bind"):AddKeyPicker("autoshiftlockbind", {
  Default = "V",
  Mode = "Press",
  Text = "Auto Shift Lock",
  Callback = function()
    local autoshiftlock = toggles.autoshiftlock

    if autoshiftlock then
      autoshiftlock:SetValue(not autoshiftlock.Value)
    end
  end,
})

do
-- LOCOPANI: Copy Skin (visual local). Digite o username de qualquer jogador do Roblox
-- e a aparência dele é aplicada no seu personagem, só na sua tela.
local CS = {}
CS.group = v545.Character:AddLeftGroupbox("Copy Skin")
CS.original = nil
CS.copied = nil

function CS.skinLog(message)
  warn("[LOCOPANI Copy Skin] " .. tostring(message))
end

function CS.getMyHumanoid()
  local character = localPlayer2 and localPlayer2.Character
  return character and character:FindFirstChildOfClass("Humanoid")
end

-- 1) jogador no servidor, 2) API oficial, 3) request do executor.
function CS.fetchUserId(name)
  local lowered = string.lower(name)
  for _, plr in ipairs(players:GetPlayers()) do
    if string.lower(plr.Name) == lowered or string.lower(plr.DisplayName) == lowered then
      return plr.UserId
    end
  end

  local okId, id = pcall(function() return players:GetUserIdFromNameAsync(name) end)
  if okId and id then
    return id
  end
  CS.skinLog("GetUserIdFromNameAsync falhou: " .. tostring(id))

  local req = request or http_request
  if type(req) ~= "function" then
    local env = _G
    if type(getgenv) == "function" then
      local envOK, executorEnv = pcall(getgenv)
      if envOK and type(executorEnv) == "table" then env = executorEnv end
    end
    req = env.request or env.http_request
      or (type(env.syn) == "table" and env.syn.request)
      or (type(env.http) == "table" and env.http.request)
      or (type(env.fluxus) == "table" and env.fluxus.request)
  end
  if req then
    local okReq, res = pcall(function()
      return req({
        Url = "https://users.roblox.com/v1/usernames/users",
        Method = "POST",
        Headers = { ["Content-Type"] = "application/json" },
        Body = game:GetService("HttpService"):JSONEncode({ usernames = { name }, excludeBannedUsers = false }),
      })
    end)
    if okReq and res and res.Body then
      local okJson, data = pcall(function() return game:GetService("HttpService"):JSONDecode(res.Body) end)
      if okJson and data and data.data and data.data[1] and data.data[1].id then
        return data.data[1].id
      end
    else
      CS.skinLog("request falhou: " .. tostring(res))
    end
  end

  return nil
end

function CS.loadAsset(assetId)
  local ok, objects = pcall(function()
    return game:GetObjects("rbxassetid://" .. tostring(assetId))
  end)
  if ok and type(objects) == "table" and objects[1] then
    return objects[1]
  end
  local reason = ok and "asset vazio" or tostring(objects)
  CS.lastError = reason
  CS.skinLog("GetObjects falhou para " .. tostring(assetId) .. ": " .. reason)
  return nil
end

-- Lista os ids de acessórios da descrição (GetAccessories ou campos de texto).
function CS.collectAccessoryIds(description)
  local ids = {}
  local seen = {}
  local function add(id)
    id = tonumber(id)
    if id and id > 0 and not seen[id] then
      seen[id] = true
      table.insert(ids, id)
    end
  end

  local okAcc, accessories = pcall(function() return description:GetAccessories(true) end)
  if okAcc and type(accessories) == "table" then
    for _, info in ipairs(accessories) do add(info.AssetId) end
  end

  if #ids == 0 then
    for _, field in ipairs({
      "HatAccessory", "HairAccessory", "FaceAccessory", "NeckAccessory",
      "ShouldersAccessory", "FrontAccessory", "BackAccessory", "WaistAccessory",
    }) do
      local okField, value = pcall(function() return description[field] end)
      if okField and type(value) == "string" then
        for id in string.gmatch(value, "%d+") do add(id) end
      end
    end
  end

  return ids
end

-- Encaixa o acessório no personagem (AddAccessory; se não soldar, solda pelo Attachment).
function CS.attachAccessory(character, humanoid, accessory)
  pcall(function() humanoid:AddAccessory(accessory) end)
  if accessory.Parent ~= character then
    accessory.Parent = character
  end

  local handle = accessory:FindFirstChild("Handle")
  if not handle then
    return accessory.Parent == character
  end

  local welded = false
  for _, child in ipairs(handle:GetChildren()) do
    if child:IsA("JointInstance") or child:IsA("WeldConstraint") then
      welded = true
      break
    end
  end

  if not welded then
    local handleAttachment = handle:FindFirstChildOfClass("Attachment")
    local characterAttachment = nil
    if handleAttachment then
      for _, part in ipairs(character:GetChildren()) do
        if part:IsA("BasePart") then
          local found = part:FindFirstChild(handleAttachment.Name)
          if found and found:IsA("Attachment") then
            characterAttachment = found
            break
          end
        end
      end
    end

    local weld = Instance.new("Weld")
    weld.Name = "AccessoryWeld"
    if handleAttachment and characterAttachment then
      weld.Part0 = characterAttachment.Parent
      weld.C0 = characterAttachment.CFrame
      weld.C1 = handleAttachment.CFrame
    else
      local head = character:FindFirstChild("Head")
      if not head then
        return false
      end
      weld.Part0 = head
      weld.C0 = CFrame.new(0, head.Size.Y / 2, 0)
      weld.C1 = accessory.AttachmentPoint
    end
    weld.Part1 = handle
    weld.Parent = handle
  end

  pcall(function()
    handle.Anchored = false
    handle.CanCollide = false
    handle.Massless = true
  end)
  return true
end

-- Baixa todos os acessórios primeiro; só troca os atuais se algum baixar.
-- Retorna (colocados, total).
function CS.attachAccessories(character, humanoid, description)
  local ids = CS.collectAccessoryIds(description)

  if #ids == 0 then
    for _, child in ipairs(character:GetChildren()) do
      if child:IsA("Accessory") then child:Destroy() end
    end
    return 0, 0
  end

  local loaded = {}
  for _, id in ipairs(ids) do
    local obj = CS.loadAsset(id)
    local accessory = nil
    if obj then
      accessory = obj:IsA("Accessory") and obj or obj:FindFirstChildWhichIsA("Accessory", true)
      if not accessory then
        CS.lastError = "asset " .. tostring(id) .. " não é um Accessory"
        CS.skinLog(CS.lastError)
      end
    end
    if accessory then
      table.insert(loaded, accessory)
    end
  end

  if #loaded == 0 then
    return 0, #ids
  end

  for _, child in ipairs(character:GetChildren()) do
    if child:IsA("Accessory") then child:Destroy() end
  end

  local attached = 0
  for _, accessory in ipairs(loaded) do
    local okAttach, result = pcall(CS.attachAccessory, character, humanoid, accessory)
    if okAttach and result then
      attached = attached + 1
    else
      CS.lastError = tostring(result)
      CS.skinLog("não encaixou o acessório: " .. tostring(result))
    end
  end

  return attached, #ids
end

-- Plano B: monta a aparência manualmente (cores, roupas, rosto e acessórios).
function CS.manualApply(character, humanoid, description)
  local bodyColors = character:FindFirstChildOfClass("BodyColors")
  if bodyColors then
    pcall(function()
      bodyColors.HeadColor3 = description.HeadColor
      bodyColors.TorsoColor3 = description.TorsoColor
      bodyColors.LeftArmColor3 = description.LeftArmColor
      bodyColors.RightArmColor3 = description.RightArmColor
      bodyColors.LeftLegColor3 = description.LeftLegColor
      bodyColors.RightLegColor3 = description.RightLegColor
    end)
  end

  local function setClothing(className, assetId)
    for _, child in ipairs(character:GetChildren()) do
      if child:IsA(className) then child:Destroy() end
    end
    if assetId and assetId ~= 0 then
      local obj = CS.loadAsset(assetId)
      if obj and obj:IsA(className) then obj.Parent = character end
    end
  end

  setClothing("Shirt", description.Shirt)
  setClothing("Pants", description.Pants)
  setClothing("ShirtGraphic", description.GraphicTShirt)

  local head = character:FindFirstChild("Head")
  if head and description.Face and description.Face ~= 0 then
    local face = CS.loadAsset(description.Face)
    if face and face:IsA("Decal") then
      local oldFace = head:FindFirstChildOfClass("Decal")
      if oldFace then oldFace:Destroy() end
      face.Parent = head
    end
  end

end

function CS.applyDescription(description)
  local humanoid = CS.getMyHumanoid()
  if not humanoid or not description then
    return false, "personagem não carregado"
  end
  local character = humanoid.Parent
  CS.lastError = nil

  local before = {}
  for _, child in ipairs(character:GetChildren()) do
    if child:IsA("Accessory") then before[child] = true end
  end

  local ok, err = pcall(function() humanoid:ApplyDescription(description) end)
  if not ok then
    CS.skinLog("ApplyDescription falhou: " .. tostring(err))
    local ok2, err2 = pcall(CS.manualApply, character, humanoid, description)
    if not ok2 then
      CS.skinLog("Aplicação manual falhou: " .. tostring(err2))
      return false, tostring(err)
    end
  end

  task.wait(0.5)

  -- Se o ApplyDescription já trouxe os acessórios novos, não mexe mais.
  local total = #CS.collectAccessoryIds(description)
  local fresh = 0
  for _, child in ipairs(character:GetChildren()) do
    if child:IsA("Accessory") and not before[child] then fresh = fresh + 1 end
  end
  if total > 0 and fresh >= total then
    return true, nil, fresh, total
  end

  local okAcc, attached, total2 = pcall(CS.attachAccessories, character, humanoid, description)
  if okAcc then
    return true, nil, attached, total2
  end
  CS.lastError = tostring(attached)
  CS.skinLog("acessórios falharam: " .. tostring(attached))
  return true, nil, 0, total
end

CS.group:AddInput("copyskinname", {
  Default = "",
  Text = "Roblox Username",
  Placeholder = "Nome do jogador",
  Callback = function() end,
})

CS.group:AddButton({
  Text = "Copy Skin",
  Func = function()
    local name = ""
    pcall(function() name = tostring(options.copyskinname.Value or "") end)
    name = name:gsub("^%s+", ""):gsub("%s+$", "")

    if name == "" then
      v174:Notify("Digite o nome de um jogador primeiro")
      return
    end

    task.spawn(function()
      local userId = CS.fetchUserId(name)
      if not userId then
        v174:Notify("Não achei o jogador: " .. name)
        return
      end

      local humanoid = CS.getMyHumanoid()
      if not humanoid then
        v174:Notify("Seu personagem ainda não carregou")
        return
      end

      -- Guarda a sua aparência original só na primeira cópia.
      if not CS.original then
        local okOrig, orig = pcall(function() return humanoid:GetAppliedDescription() end)
        if okOrig and orig then
          CS.original = orig
        else
          pcall(function()
            CS.original = players:GetHumanoidDescriptionFromUserId(localPlayer2.UserId)
          end)
        end
      end

      local okDesc, description = pcall(function()
        return players:GetHumanoidDescriptionFromUserId(userId)
      end)
      if not okDesc or not description then
        CS.skinLog("GetHumanoidDescriptionFromUserId falhou: " .. tostring(description))
        v174:Notify("Não consegui carregar a skin de " .. name .. ": " .. tostring(description))
        return
      end

      local applied, reason, attached, total = CS.applyDescription(description)
      if applied then
        CS.copied = description
        local note = "Skin copiada: " .. name .. " (acessórios " .. tostring(attached or 0) .. "/" .. tostring(total or 0) .. ")"
        if (attached or 0) < (total or 0) and CS.lastError then
          note = note .. " - " .. tostring(CS.lastError)
        end
        v174:Notify(note)
      else
        v174:Notify("Falhou ao aplicar: " .. tostring(reason))
      end
    end)
  end,
})

CS.group:AddButton({
  Text = "Restore My Skin",
  Func = function()
    CS.copied = nil
    task.spawn(function()
      if CS.original and CS.applyDescription(CS.original) then
        v174:Notify("Skin original restaurada")
      else
        v174:Notify("Nada para restaurar")
      end
    end)
  end,
})

-- Reaplica a skin copiada quando você renascer.
if localPlayer2 then
  localPlayer2.CharacterAdded:Connect(function(character)
    if not CS.copied then
      return
    end
    local humanoid = character:WaitForChild("Humanoid", 10)
    if humanoid then
      task.wait(1)
      if CS.copied then
        CS.applyDescription(CS.copied)
      end
    end
  end)
end
end -- end Copy Skin

do
-- Character Enemy/Team Line: draw a forward-facing line from each character.
-- The attachments are parented to HumanoidRootPart, so the line follows its facing direction.
local LOCOPANI_CharacterLines = {
  Enabled = false,
  Distance = 50,
  Thickness = 0.09,
  EnemyColor = Color3.fromRGB(255, 70, 70),
  TeamColor = Color3.fromRGB(70, 170, 255),
  Connection = nil,
}

local function LOCOPANI_RemoveCharacterLine(player)
  local record = v229[player]
  if record then
    if record.Beam then pcall(function() record.Beam:Destroy() end) end
    if record.Start then pcall(function() record.Start:Destroy() end) end
    if record.Finish then pcall(function() record.Finish:Destroy() end) end
    v229[player] = nil
  end
end

local function LOCOPANI_UpdateCharacterLine(player)
  if player == localPlayer2 or not LOCOPANI_CharacterLines.Enabled then
    LOCOPANI_RemoveCharacterLine(player)
    return
  end

  local character = player.Character
  local root = character and character:FindFirstChild("HumanoidRootPart")
  local humanoid = character and character:FindFirstChildOfClass("Humanoid")
  if not root or not humanoid or humanoid.Health <= 0 then
    LOCOPANI_RemoveCharacterLine(player)
    return
  end

  local localTeam = localPlayer2.Team
  local otherTeam = player.Team
  local lineColor
  if localTeam and otherTeam then
    lineColor = (localTeam == otherTeam)
      and LOCOPANI_CharacterLines.TeamColor
      or LOCOPANI_CharacterLines.EnemyColor
  else
    -- If Team objects are unavailable, use the enemy color as a consistent fallback.
    lineColor = LOCOPANI_CharacterLines.EnemyColor
  end

  local record = v229[player]
  if not record or record.Root ~= root or not record.Beam or not record.Beam.Parent then
    LOCOPANI_RemoveCharacterLine(player)

    local startAttachment = Instance.new("Attachment")
    startAttachment.Name = "LOCOPANI_CharacterLineStart"
    startAttachment.Position = Vector3.new(0, 0, 0)
    startAttachment.Parent = root

    local endAttachment = Instance.new("Attachment")
    endAttachment.Name = "LOCOPANI_CharacterLineEnd"
    endAttachment.Position = Vector3.new(0, 0, -LOCOPANI_CharacterLines.Distance)
    endAttachment.Parent = root

    local beam = Instance.new("Beam")
    beam.Name = "LOCOPANI_CharacterAimLine"
    beam.Attachment0 = startAttachment
    beam.Attachment1 = endAttachment
    beam.FaceCamera = true
    beam.Width0 = LOCOPANI_CharacterLines.Thickness
    beam.Width1 = LOCOPANI_CharacterLines.Thickness * 0.5
    beam.LightEmission = 0.7
    beam.Transparency = NumberSequence.new(0.12)
    beam.Color = ColorSequence.new(lineColor)
    beam.Parent = root

    record = { Root = root, Start = startAttachment, Finish = endAttachment, Beam = beam }
    v229[player] = record
  end

  record.Finish.Position = Vector3.new(0, 0, -LOCOPANI_CharacterLines.Distance)
  record.Beam.Width0 = LOCOPANI_CharacterLines.Thickness
  record.Beam.Width1 = LOCOPANI_CharacterLines.Thickness * 0.5
  record.Beam.Color = ColorSequence.new(lineColor)
end

local function LOCOPANI_SetCharacterLines(enabled)
  LOCOPANI_CharacterLines.Enabled = enabled and true or false
  if LOCOPANI_CharacterLines.Connection then
    LOCOPANI_CharacterLines.Connection:Disconnect()
    LOCOPANI_CharacterLines.Connection = nil
  end

  if not LOCOPANI_CharacterLines.Enabled then
    for player in pairs(v229) do
      LOCOPANI_RemoveCharacterLine(player)
    end
    return
  end

  for _, player in ipairs(players:GetPlayers()) do
    LOCOPANI_UpdateCharacterLine(player)
  end
  LOCOPANI_CharacterLines.Connection = runService.Heartbeat:Connect(function()
    for _, player in ipairs(players:GetPlayers()) do
      LOCOPANI_UpdateCharacterLine(player)
    end
    for player in pairs(v229) do
      if not player.Parent then LOCOPANI_RemoveCharacterLine(player) end
    end
  end)
end

v546.CharMoveGroup:AddToggle("characterlines", {
  Text = "Character Enemy/Team Line",
  Tooltip = "Show colored beams to enemies",
  Default = false,
  Callback = function(value144)
    LOCOPANI_SetCharacterLines(value144)
  end,
})

v546.CharMoveGroup:AddSlider("linethickness", {
  Text = "Line Thickness",
  Default = 0.09,
  Min = 0.01,
  Max = 0.5,
  Rounding = 2,
  Callback = function(value145)
    LOCOPANI_CharacterLines.Thickness = tonumber(value145) or 0.09
    if LOCOPANI_CharacterLines.Enabled then
      for _, player in ipairs(players:GetPlayers()) do
        LOCOPANI_UpdateCharacterLine(player)
      end
    end
  end,
})

v546.CharMoveGroup:AddColorPicker("lineenemycolor", {
  Text = "Enemy Line Color",
  Default = Color3.fromRGB(255, 70, 70),
  Callback = function(color, alpha)
    if typeof(color) == "Color3" then
      LOCOPANI_CharacterLines.EnemyColor = color
      if LOCOPANI_CharacterLines.Enabled then
        for _, player in ipairs(players:GetPlayers()) do LOCOPANI_UpdateCharacterLine(player) end
      end
    end
  end,
})

v546.CharMoveGroup:AddColorPicker("lineteamcolor", {
  Text = "Team Line Color",
  Default = Color3.fromRGB(70, 170, 255),
  Callback = function(color, alpha)
    if typeof(color) == "Color3" then
      LOCOPANI_CharacterLines.TeamColor = color
      if LOCOPANI_CharacterLines.Enabled then
        for _, player in ipairs(players:GetPlayers()) do LOCOPANI_UpdateCharacterLine(player) end
      end
    end
  end,
})

v546.CharMoveGroup:AddSlider("linedistance", {
  Text = "Line Distance",
  Default = 50,
  Min = 10,
  Max = 200,
  Rounding = 1,
  Callback = function(value146)
    LOCOPANI_CharacterLines.Distance = tonumber(value146) or 50
    if LOCOPANI_CharacterLines.Enabled then
      for _, player in ipairs(players:GetPlayers()) do
        LOCOPANI_UpdateCharacterLine(player)
      end
    end
  end,
})

end

v545.Visuals:AddRightGroupbox("Ball Prediction"):AddToggle("ballmarker", {
  Text = "Landing Marker",
  Tooltip = "Predict where the ball land and say if it's out or not",
  Default = false,
  Callback = function(value146)
    v495.enabled = value146

    if not value146 then
      v495.clear()
    end
  end,
})

-- Visual-only level override: changes local PlayerGui text only, never server data.
LOCOPANI_VisualLevel = {
  Enabled = false,
  Value = "1000",
  Records = {},
  AddedConn = nil,
  CharacterConn = nil,
  CharacterAddedConn = nil,
}

function LOCOPANI_VisualLevel:IsLevelLabel(label)
  if not label or not (label:IsA("TextLabel") or label:IsA("TextButton")) then
    return false
  end
  local name = string.lower(tostring(label.Name or ""))
  local currentText = tostring(label.Text or "")
  local lowerText = string.lower(currentText)
  -- Never treat streak/win-streak UI as a level, even when nested under a shared BillboardGui.
  if string.find(name, "streak", 1, true) or string.find(name, "win", 1, true) and string.find(name, "streak", 1, true) or
    string.find(lowerText, "streak", 1, true) then
    return false
  end
  local namedAsLevel = string.find(name, "level", 1, true) or string.find(name, "lvl", 1, true)
  local textHasLevel = string.find(lowerText, "level", 1, true) or
    string.find(lowerText, "lvl", 1, true) or
    string.find(lowerText, "lv.", 1, true) or
    string.match(lowerText, "^%s*lv%s*%d+")
  local isJustNumber = string.match(currentText, "^%s*%d+%s*$") ~= nil

  -- Inspeciona os nomes dos ancestrais para localizar labels que realmente
  -- representam level. Nao classifica todo numero de um BillboardGui como level,
  -- pois ali tambem podem aparecer streaks e outras estatisticas.
  local ancestor = label.Parent
  local ancestorHintsLevel = false
  while ancestor do
    local ancestorName = string.lower(tostring(ancestor.Name or ""))
    if string.find(ancestorName, "streak", 1, true) then
      return false
    end
    if string.find(ancestorName, "level", 1, true) or string.find(ancestorName, "lvl", 1, true) then
      ancestorHintsLevel = true
    end
    ancestor = ancestor.Parent
  end

  -- Do not infer that a numeric label is a level merely because a shared parent
  -- contains the word "level"; this is what can accidentally capture the streak.
  return namedAsLevel ~= nil or textHasLevel ~= nil or
    (isJustNumber and string.find(name, "exp", 1, true) ~= nil)
end

function LOCOPANI_VisualLevel:MakeSpoofedText(label, sourceText)
  local desired = tostring(math.max(0, math.floor(tonumber(self.Value) or 1000)))
  local original = tostring(sourceText or "")
  local lower = string.lower(original)
  if string.match(original, "^%s*%d+%s*$") and
    (string.find(string.lower(label.Name), "level", 1, true) or string.find(string.lower(label.Name), "lvl", 1, true)) then
    return string.gsub(original, "%d+", desired, 1)
  end
  if string.find(lower, "level", 1, true) or string.find(lower, "lvl", 1, true) or string.find(lower, "lv.", 1, true) or string.match(lower, "^%s*lv%s*%d+") then
    local replaced, count = string.gsub(original, "%d+", desired, 1)
    if count > 0 then return replaced end
  end
  return nil
end

function LOCOPANI_VisualLevel:Watch(label)
  if not self.Enabled or not self:IsLevelLabel(label) then return end
  if self.Records[label] then
    local record = self.Records[label]
    if record.busy then return end
    local nowText = tostring(label.Text or "")
    if nowText ~= record.spoofed then
      record.original = nowText
      local spoofed = self:MakeSpoofedText(label, record.original)
      if spoofed then
        record.spoofed = spoofed
        record.busy = true
        label.Text = spoofed
        record.busy = false
      end
    end
    return
  end

  local original = tostring(label.Text or "")
  local spoofed = self:MakeSpoofedText(label, original)
  if not spoofed then return end
  local record = { original = original, spoofed = spoofed, busy = true, connection = nil }
  self.Records[label] = record
  label.Text = spoofed
  record.busy = false
  record.connection = label:GetPropertyChangedSignal("Text"):Connect(function()
    if not self.Enabled or record.busy or not label.Parent then return end
    local current = tostring(label.Text or "")
    if current == record.spoofed then return end
    record.original = current
    local updated = self:MakeSpoofedText(label, record.original)
    if updated then
      record.spoofed = updated
      record.busy = true
      label.Text = updated
      record.busy = false
    end
  end)
end

function LOCOPANI_VisualLevel:WatchContainer(container)
  if not container then return end
  for _, item in ipairs(container:GetDescendants()) do
    if item:IsA("TextLabel") or item:IsA("TextButton") then
      self:Watch(item)
    end
  end
  if container:IsA("Model") and container:FindFirstChildOfClass("Humanoid") then
    -- The level over the character is normally in a BillboardGui under the
    -- character/head, outside PlayerGui. Only scan the local character.
    for _, item in ipairs(container:GetDescendants()) do
      if item:IsA("BillboardGui") then
        for _, guiItem in ipairs(item:GetDescendants()) do
          if guiItem:IsA("TextLabel") or guiItem:IsA("TextButton") then
            self:Watch(guiItem)
          end
        end
      end
    end
  end
end

function LOCOPANI_VisualLevel:Apply()
  if not self.Enabled then return end
  local player = localPlayer2 or game:GetService("Players").LocalPlayer
  if not player then return end
  local playerGui = player:FindFirstChildOfClass("PlayerGui")
  if playerGui then
    self:WatchContainer(playerGui)
    if not self.AddedConn then
      self.AddedConn = playerGui.DescendantAdded:Connect(function(item)
        if self.Enabled and (item:IsA("TextLabel") or item:IsA("TextButton")) then
          task.defer(function() self:Watch(item) end)
        end
      end)
    end
  end

  local function bindCharacter(character)
    if not self.Enabled or not character then return end
    if self.CharacterConn then
      self.CharacterConn:Disconnect()
      self.CharacterConn = nil
    end
    self:WatchContainer(character)
    self.CharacterConn = character.DescendantAdded:Connect(function(item)
      if self.Enabled and (item:IsA("TextLabel") or item:IsA("TextButton")) then
        task.defer(function() self:Watch(item) end)
      elseif self.Enabled and item:IsA("BillboardGui") then
        task.defer(function() self:WatchContainer(item) end)
      end
    end)
  end

  if player.Character then bindCharacter(player.Character) end
  if not self.CharacterAddedConn then
    self.CharacterAddedConn = player.CharacterAdded:Connect(function(character)
      task.defer(function() bindCharacter(character) end)
    end)
  end
end

function LOCOPANI_VisualLevel:SetEnabled(enabled)
  self.Enabled = enabled == true
  if self.Enabled then
    self:Apply()
    return
  end
  if self.AddedConn then
    self.AddedConn:Disconnect()
    self.AddedConn = nil
  end
  if self.CharacterConn then
    self.CharacterConn:Disconnect()
    self.CharacterConn = nil
  end
  if self.CharacterAddedConn then
    self.CharacterAddedConn:Disconnect()
    self.CharacterAddedConn = nil
  end
  for label, record in pairs(self.Records) do
    if record.connection then record.connection:Disconnect() end
    if label and label.Parent then
      record.busy = true
      label.Text = record.original
      record.busy = false
    end
    self.Records[label] = nil
  end
end


-- Independent visual streak override; it cannot modify level text or game data.
LOCOPANI_VisualStreak = {
  Enabled = false,
  Value = "0",
  Records = {},
  AddedConn = nil,
  CharacterConn = nil,
  CharacterAddedConn = nil,
}

function LOCOPANI_VisualStreak:IsStreakLabel(label)
  if not label or not (label:IsA("TextLabel") or label:IsA("TextButton")) then
    return false
  end
  local name = string.lower(tostring(label.Name or ""))
  local currentText = tostring(label.Text or "")
  local lowerText = string.lower(currentText)
  local namedAsStreak = string.find(name, "streak", 1, true) or string.find(name, "win", 1, true) and string.find(name, "series", 1, true)
  local textHasStreak = string.find(lowerText, "streak", 1, true) or
    string.find(lowerText, "win streak", 1, true) or
    string.match(lowerText, "^%s*st%s*[:%.%-]?%s*%d+")
  -- Neste jogo o streak do overhead pode aparecer apenas como um icone de fogo
  -- seguido do numero (ex.: 🔥6767), sem a palavra "streak" no nome/texto.
  local hasFireIcon = string.find(currentText, "🔥", 1, true) ~= nil
  local isJustNumber = string.match(currentText, "^%s*%d+%s*$") ~= nil

  -- Detecta labels pelo nome e contexto dos ancestrais.
  local ancestor = label.Parent
  local ancestorHintsStreak = false
  local insideBillboard = false
  local insideCharacterModel = false
  local player = localPlayer2 or game:GetService("Players").LocalPlayer
  while ancestor do
    local ancestorName = string.lower(tostring(ancestor.Name or ""))
    if string.find(ancestorName, "streak", 1, true) or string.find(ancestorName, "winstreak", 1, true) then
      ancestorHintsStreak = true
    end
    if ancestor:IsA("BillboardGui") then
      insideBillboard = true
    end
    if ancestor:IsA("Model") and ancestor:FindFirstChildOfClass("Humanoid") then
      insideCharacterModel = true
      break
    end
    ancestor = ancestor.Parent
  end

  -- No overhead mostrado pelo LOCOPANI, o fogo é um ícone separado e o
  -- streak é apenas um número ("4"). O nível fica em outro label ("Lvl 232 - ..."),
  -- portanto só aceita número isolado no BillboardGui do personagem local.
  local isLocalCharacter = player and player.Character and label:IsDescendantOf(player.Character)
  local numericOverheadStreak = isJustNumber and insideBillboard and insideCharacterModel and isLocalCharacter

  return namedAsStreak ~= nil or textHasStreak ~= nil or ancestorHintsStreak or hasFireIcon or numericOverheadStreak
end

function LOCOPANI_VisualStreak:MakeSpoofedText(label, sourceText)
  local desired = tostring(math.max(0, math.floor(tonumber(self.Value) or 1000)))
  local original = tostring(sourceText or "")
  local lower = string.lower(original)
  -- IsStreakLabel já validou o contexto antes de chegar aqui; número isolado
  -- nesse label é o streak do overhead.
  if string.match(original, "^%s*%d+%s*$") then
    return string.gsub(original, "%d+", desired, 1)
  end
  -- Altera somente o numero de labels identificados como streak, inclusive o
  -- formato visual de fogo + numero usado no overhead do personagem.
  if string.find(lower, "streak", 1, true) or string.find(lower, "win streak", 1, true) or
    string.match(lower, "^%s*st%s*[:%.%-]?%s*%d+") or string.find(original, "🔥", 1, true) then
    local replaced, count = string.gsub(original, "%d+", desired, 1)
    if count > 0 then return replaced end
  end
  return nil
end

function LOCOPANI_VisualStreak:Watch(label)
  if not self.Enabled or not self:IsStreakLabel(label) then return end
  if self.Records[label] then
    local record = self.Records[label]
    if record.busy then return end
    local nowText = tostring(label.Text or "")
    if nowText ~= record.spoofed then
      record.original = nowText
      local spoofed = self:MakeSpoofedText(label, record.original)
      if spoofed then
        record.spoofed = spoofed
        record.busy = true
        label.Text = spoofed
        record.busy = false
      end
    end
    return
  end

  local original = tostring(label.Text or "")
  local spoofed = self:MakeSpoofedText(label, original)
  if not spoofed then return end
  local record = { original = original, spoofed = spoofed, busy = true, connection = nil }
  self.Records[label] = record
  label.Text = spoofed
  record.busy = false
  record.connection = label:GetPropertyChangedSignal("Text"):Connect(function()
    if not self.Enabled or record.busy or not label.Parent then return end
    local current = tostring(label.Text or "")
    if current == record.spoofed then return end
    record.original = current
    local updated = self:MakeSpoofedText(label, record.original)
    if updated then
      record.spoofed = updated
      record.busy = true
      label.Text = updated
      record.busy = false
    end
  end)
end

function LOCOPANI_VisualStreak:WatchContainer(container)
  if not container then return end
  for _, item in ipairs(container:GetDescendants()) do
    if item:IsA("TextLabel") or item:IsA("TextButton") then
      self:Watch(item)
    end
  end
  if container:IsA("Model") and container:FindFirstChildOfClass("Humanoid") then
    -- The streak over the character is normally in a BillboardGui under the
    -- character/head, outside PlayerGui. Only scan the local character.
    for _, item in ipairs(container:GetDescendants()) do
      if item:IsA("BillboardGui") then
        for _, guiItem in ipairs(item:GetDescendants()) do
          if guiItem:IsA("TextLabel") or guiItem:IsA("TextButton") then
            self:Watch(guiItem)
          end
        end
      end
    end
  end
end

function LOCOPANI_VisualStreak:Apply()
  if not self.Enabled then return end
  local player = localPlayer2 or game:GetService("Players").LocalPlayer
  if not player then return end
  local playerGui = player:FindFirstChildOfClass("PlayerGui")
  if playerGui then
    self:WatchContainer(playerGui)
    if not self.AddedConn then
      self.AddedConn = playerGui.DescendantAdded:Connect(function(item)
        if self.Enabled and (item:IsA("TextLabel") or item:IsA("TextButton")) then
          task.defer(function() self:Watch(item) end)
        end
      end)
    end
  end

  local function bindCharacter(character)
    if not self.Enabled or not character then return end
    if self.CharacterConn then
      self.CharacterConn:Disconnect()
      self.CharacterConn = nil
    end
    self:WatchContainer(character)
    self.CharacterConn = character.DescendantAdded:Connect(function(item)
      if self.Enabled and (item:IsA("TextLabel") or item:IsA("TextButton")) then
        task.defer(function() self:Watch(item) end)
      elseif self.Enabled and item:IsA("BillboardGui") then
        task.defer(function() self:WatchContainer(item) end)
      end
    end)
  end

  if player.Character then bindCharacter(player.Character) end
  if not self.CharacterAddedConn then
    self.CharacterAddedConn = player.CharacterAdded:Connect(function(character)
      task.defer(function() bindCharacter(character) end)
    end)
  end
end

function LOCOPANI_VisualStreak:SetEnabled(enabled)
  self.Enabled = enabled == true
  if self.Enabled then
    self:Apply()
    return
  end
  if self.AddedConn then
    self.AddedConn:Disconnect()
    self.AddedConn = nil
  end
  if self.CharacterConn then
    self.CharacterConn:Disconnect()
    self.CharacterConn = nil
  end
  if self.CharacterAddedConn then
    self.CharacterAddedConn:Disconnect()
    self.CharacterAddedConn = nil
  end
  for label, record in pairs(self.Records) do
    if record.connection then record.connection:Disconnect() end
    if label and label.Parent then
      record.busy = true
      label.Text = record.original
      record.busy = false
    end
    self.Records[label] = nil
  end
end


-- Inventário Controlado: selections are tracked independently for each category.
-- Isolated in its own function to avoid Luau's 200-register limit in the main setup function.
-- Works with native table-based multiselect dropdowns and older single-value dropdown callbacks.
v451.SetupControlledInventory = function()
  local inventoryControlGroup = v545["Inventário Controlado"]:AddLeftGroupbox("Controle do Inventário")
  -- Build title choices from the game's Item definitions.
  v451.titleNames = {}
  do
    local content = replicatedStorage:FindFirstChild("Content")
    local itemFolder = content and content:FindFirstChild("Item")
    local entities = itemFolder and itemFolder:FindFirstChild("Entities")
    local seenTitles = {}
    if entities then
      for _, module in ipairs(entities:GetChildren()) do
        if module:IsA("ModuleScript") then
          local okItem, itemData = pcall(require, module)
          if okItem and type(itemData) == "table" and itemData.Type == "Title" and not seenTitles[module.Name] then
            seenTitles[module.Name] = true
            table.insert(v451.titleNames, module.Name)
          end
        end
      end
    end
    table.sort(v451.titleNames)
  end
  -- Jerseys are sourced from the same list used by Jersey Changer.
  v451.jerseyNames = {}
  do
    local seenJerseys = {}
    for _, name in ipairs(v211 or {}) do
      if type(name) == "string" and not seenJerseys[name] then
        seenJerseys[name] = true
        table.insert(v451.jerseyNames, name)
      end
    end
    table.sort(v451.jerseyNames)
  end

  v451.controlSelections = v451.controlSelections or {
    Cards = {},
    Balls = {},
    ScoreEffects = {},
    Titles = {},
    Jerseys = {},
  }
  v451.controlSelections.Jerseys = v451.controlSelections.Jerseys or {}

  local function rebuildSelectedItems()
    v451.selectedItems = {}
    for _, category in pairs(v451.controlSelections) do
      for itemName, enabled in pairs(category) do
        if enabled then v451.selectedItems[itemName] = true end
      end
    end
  end

  local function applySelection(categoryName, selected, validNames)
    local current = v451.controlSelections[categoryName] or {}
    local valid = {}
    for _, itemName in ipairs(validNames or {}) do valid[itemName] = true end

    if type(selected) == "table" then
      local nextSelection = {}
      -- Accept either { [name] = true } or an array { "name1", "name2" }.
      for key, value in pairs(selected) do
        if type(key) == "number" and type(value) == "string" then
          if valid[value] then nextSelection[value] = true end
        elseif type(key) == "string" and value == true and valid[key] then
          nextSelection[key] = true
        end
      end
      v451.controlSelections[categoryName] = nextSelection
    elseif type(selected) == "string" and valid[selected] then
      -- Fallback for Gen2 dropdowns that still return only one string:
      -- each choice toggles that item while preserving previous selections.
      current[selected] = not current[selected] or nil
      v451.controlSelections[categoryName] = current
    end

    rebuildSelectedItems()
    v451.mark("ControlledInventorySelection", false)
  end

  inventoryControlGroup:AddToggle("controlledinventoryenabled", {
    Text = "Ativar inventário controlado",
    Tooltip = "Quando ativado, controla localmente quais Cards, Balls, Score Effects, Titles e Jerseys aparecem no inventário.",
    Default = false,
    Callback = function(enabled)
      v451.controlEnabled = enabled == true
      v451.mark("ControlledInventory", enabled == true)
    end,
  })

  local storeGroupCard = v545["Inventário Controlado"]:AddLeftGroupbox("Card Changer")
  storeGroupCard:AddDropdown("storescamcards", {
    Values = v210,
    Default = {},
    Multi = true,
    Text = "Cards que aparecem no inventário",
    Callback = function(selected)
      applySelection("Cards", selected, v210)
    end,
  })

  local storeGroupBall = v545["Inventário Controlado"]:AddRightGroupbox("Ball Changer")
  storeGroupBall:AddDropdown("storescamballs", {
    Values = v212,
    Default = {},
    Multi = true,
    Text = "Bolas que aparecem no inventário",
    Callback = function(selected)
      applySelection("Balls", selected, v212)
    end,
  })

  local storeGroupScore = v545["Inventário Controlado"]:AddLeftGroupbox("Score Effect Changer")
  storeGroupScore:AddDropdown("storescamscoreeffects", {
    Values = v205,
    Default = {},
    Multi = true,
    Text = "Score Effects que aparecem no inventário",
    Callback = function(selected)
      applySelection("ScoreEffects", selected, v205)
    end,
  })

  local storeGroupTitle = v545["Inventário Controlado"]:AddRightGroupbox("Title Changer")
  storeGroupTitle:AddDropdown("storescamtitles", {
    Values = v451.titleNames,
    Default = {},
    Multi = true,
    Text = "Titles que aparecem no inventário",
    Callback = function(selected)
      applySelection("Titles", selected, v451.titleNames)
    end,
  })

  local storeGroupJersey = v545["Inventário Controlado"]:AddRightGroupbox("Jersey Changer")
  storeGroupJersey:AddDropdown("storescamjerseys", {
    Values = v451.jerseyNames,
    Default = {},
    Multi = true,
    Text = "Jerseys visíveis (não equipa)",
    Callback = function(selected)
      applySelection("Jerseys", selected, v451.jerseyNames)
    end,
  })
end
v451.SetupControlledInventory()

v546.VisualScoreGroup = v545.Visuals:AddLeftGroupbox("Score Effect")

v546.VisualScoreGroup:AddDropdown("effectselect", {
  Values = v205,
  Default = v205[1] or "SupernovaScoreEffect",
  Text = "Select Score Effect",
  Callback = function(value147)
    if value147 then
      scoreEffect = value147
      v174:Notify("Selected Effect: " .. value147)
    end
  end,
})

v546.VisualScoreGroup:AddToggle("scoreeffect", {
  Text = "ScoreEffect Changer",
  Tooltip = "Change score effect",
  Default = false,
  Callback = function(value148)
    v202 = value148

    if value148 then
      f113()
    else
      f115()
    end

    v451.mark("ScoreEffect", value148)
  end,
})

v546.VisualScoreGroup:AddToggle("randomeffect", {
  Text = "Random Effect",
  Tooltip = "Sorteia um dos efeitos favoritos a cada pontuação. Sem favoritos, usa todos.",
  Default = false,
  Callback = function(value149)
    v238.EffectEnabled = value149

    -- O sorteio precisa do hook do ScoreEffect Changer ativo.
    if value149 and not v202 then
      v202 = true
      f113()
    elseif not value149 then
      local changerOn = false
      pcall(function() changerOn = toggles.scoreeffect.Value == true end)
      if not changerOn and v202 then
        v202 = false
        f115()
      end
    end
  end,
})

v546.VisualScoreGroup:AddDropdown("randomeffectpool", {
  Values = v205,
  Default = {},
  Multi = true,
  Text = "Favoritos do sorteio (vazio = todos os efeitos)",
  Callback = function(selected)
    local pool = {}
    if type(selected) == "table" then
      for key, value in pairs(selected) do
        if type(key) == "string" and value == true then pool[key] = true
        elseif type(key) == "number" and type(value) == "string" then pool[value] = true end
      end
    end
    LOCOPANI_RandomPool.ScoreEffect = pool
  end,
})

v546.VisualProtectGroup = v545.Visuals:AddRightGroupbox("Protection")

v546.VisualProtectGroup:AddToggle("protect", {
  Text = "Protect",
  Tooltip = "Enable/Disable all protection features",
  Default = true,
  Callback = function(value150) f49(value150) end,
})

v546.VisualProtectGroup:AddToggle("tshanimation", {
  Text = "TSH Animation",
  Tooltip = "PowerSpike + SpecialChargeSpikeVFX on spike",
  Default = false,
  Callback = function(value151) v222 = value151 end,
})

v546.VisualProtectGroup:AddToggle("hidarianimation", {
  Text = "Hidari Animation",
  Tooltip = "PowerSpike + HidariSpikeVFX on spike",
  Default = false,
  Callback = function(value152) v223 = value152 end,
})

v546.VisualProtectGroup:AddToggle("kazanabluejump", {
  Text = "Kazana Blue Jump",
  Tooltip = "Fires KazanaBlue on jump",
  Default = false,
  Callback = function(value153) v224 = value153 end,
})

v546.VisualProtectGroup:AddToggle("kazanawhitejump", {
  Text = "Kazana White Jump",
  Tooltip = "Fires KazanaWhite on jump",
  Default = false,
  Callback = function(value154) v225 = value154 end,
})

-- Custom title shown alongside the user's name when they speak in chat.
do
  local chatTitleGroup = v545.Visuals:AddLeftGroupbox("Custom Chat Title")
  local chatTitleState = _G.LOCOPANI_CustomChatTitle

  chatTitleGroup:AddToggle("customchattitleenabled", {
    Text = "Custom Title Changer",
    Tooltip = "Personaliza o título exibido quando você fala no chat.",
    Default = chatTitleState.Enabled,
    Callback = function(enabled)
      chatTitleState.Enabled = enabled and true or false
      _G.LOCOPANI_ApplyUserTitle()
    end,
  })

  chatTitleGroup:AddInput("customchattitletext", {
    Default = chatTitleState.Text,
    Text = "Título do chat",
    Placeholder = "Digite o título que deseja",
    Callback = function(value)
      chatTitleState.Text = tostring(value or "")
      if chatTitleState.Enabled then _G.LOCOPANI_ApplyUserTitle() end
    end,
  })

  chatTitleGroup:AddColorPicker("customchattitlecolor", {
    Text = "Cor do título",
    Default = chatTitleState.Color,
    Callback = function(color, alpha)
      if typeof(color) == "Color3" then
        chatTitleState.Color = color
        if chatTitleState.Enabled then _G.LOCOPANI_ApplyUserTitle() end
      end
    end,
  })

  chatTitleGroup:AddButton({
    Text = "Aplicar título do chat",
    Func = function()
      _G.LOCOPANI_ApplyUserTitle()
      if v174 and v174.Notify then v174:Notify("Título do chat aplicado") end
    end,
  })
end

v546.CustomProtectGroup = v545.Visuals:AddLeftGroupbox("Custom Protect")

v546.CustomProtectGroup:AddToggle("customprotect", {
  Text = "Custom Protect",
  Tooltip = "Independent protect with your own name and title",
  Default = false,
  Callback = function(value155) v235.toggle(value155) end,
})

v546.CustomProtectGroup:AddInput("customprotectname", {
  Default = "CUSTOM NAME",
  Text = "Name",
  Placeholder = "CUSTOM NAME",
  Callback = function(value156) v235.setName(value156) end,
})

v546.CustomProtectGroup:AddInput("customprotecttitle", {
  Default = "<font color='#00FF00'><b>Custom</b></font>",
  Text = "Title (rich text OK)",
  Placeholder = "<font color='#00FF00'><b>Custom</b></font>",
  Callback = function(value157) v235.setTitle(value157) end,
})

v546.CustomProtectGroup:AddButton({
  Text = "Apply now",
  Func = function()
    v235.setName(options.customprotectname.Value)
    v235.setTitle(options.customprotecttitle.Value)

    if v235.Enabled then
      v235.updateNametag()
      v235.updateTitle()
      v235.protectPlayerCard()
      if v235.refreshLeaderboardMask then
        v235.refreshLeaderboardMask()
      end

      v174:Notify("Custom Protect applied")
    else
      v174:Notify("Turn the toggle on first")
    end
  end,
})

v546.PlayerCardGroup = v545.Visuals:AddLeftGroupbox("Player Card")


task.spawn(function()
-- LOCOPANI Custom Card Image (local visual only).
-- Replace the example asset IDs below with your own Roblox image/decal IDs.
local LOCOPANI_CUSTOM_CARD_IMAGES = {
  ["Roxo"] = "rbxassetid://0",
  ["Fogo"] = "rbxassetid://0",
  ["Gelo"] = "rbxassetid://0",
}
local LOCOPANI_CustomCardEnabled = false
local LOCOPANI_CustomCardSelection = "Roxo"
local LOCOPANI_CustomCardConnections = {}
local LOCOPANI_CustomCardOriginalImages = setmetatable({}, { __mode = "k" })

local function LOCOPANI_GetCustomCardImage(asset)
  if type(asset) ~= "string" then return nil end
  local digits = asset:match("rbxassetid://(%d+)") or asset:match("(%d+)")
  if not digits or digits == "0" then return nil end
  return "rbxassetid://" .. digits
end

local function LOCOPANI_FindCardArtwork(frame)
  local best, bestScore = nil, -1
  for _, obj in ipairs(frame:GetDescendants()) do
    if (obj:IsA("ImageLabel") or obj:IsA("ImageButton")) and obj.Visible then
      local size = obj.AbsoluteSize
      local area = (size and size.X or 0) * (size and size.Y or 0)
      local name = string.lower(obj.Name or "")
      local bonus = 0
      if string.find(name, "card", 1, true) then bonus = bonus + 10000 end
      if string.find(name, "background", 1, true) or string.find(name, "art", 1, true)
        or string.find(name, "image", 1, true) then bonus = bonus + 5000 end
      local score = area + bonus
      if score > bestScore then
        best, bestScore = obj, score
      end
    end
  end
  return best
end

local function LOCOPANI_ApplyCustomCardToFrame(frame)
  if not LOCOPANI_CustomCardEnabled or not frame or not frame.Parent then return end
  if frame.Name ~= "FlashPlayerCardFrame" then return end
  local image = LOCOPANI_GetCustomCardImage(LOCOPANI_CUSTOM_CARD_IMAGES[LOCOPANI_CustomCardSelection])
  if not image then return end

  task.delay(0.12, function()
    if not LOCOPANI_CustomCardEnabled or not frame.Parent then return end
    local artwork = LOCOPANI_FindCardArtwork(frame)
    if not artwork then return end
    if LOCOPANI_CustomCardOriginalImages[artwork] == nil then
      LOCOPANI_CustomCardOriginalImages[artwork] = artwork.Image
    end
    artwork.Image = image
    artwork.ImageTransparency = 0
  end)
end

local function LOCOPANI_RestoreCustomCardImages()
  for object, originalImage in pairs(LOCOPANI_CustomCardOriginalImages) do
    pcall(function()
      if object and object.Parent then object.Image = originalImage end
    end)
    LOCOPANI_CustomCardOriginalImages[object] = nil
  end
end

local function LOCOPANI_StopCustomCardWatcher()
  for _, connection in ipairs(LOCOPANI_CustomCardConnections) do
    pcall(function() connection:Disconnect() end)
  end
  table.clear(LOCOPANI_CustomCardConnections)
end

local function LOCOPANI_StartCustomCardWatcher()
  LOCOPANI_StopCustomCardWatcher()
  local playerGui = localPlayer2:FindFirstChildOfClass("PlayerGui")
  if not playerGui then return end

  local function attachPersistent(persistent)
    if not persistent then return end
    for _, child in ipairs(persistent:GetChildren()) do
      if child.Name == "FlashPlayerCardFrame" then
        LOCOPANI_ApplyCustomCardToFrame(child)
      end
    end
    table.insert(LOCOPANI_CustomCardConnections, persistent.ChildAdded:Connect(function(child)
      if child.Name == "FlashPlayerCardFrame" then
        LOCOPANI_ApplyCustomCardToFrame(child)
      end
    end))
  end

  local function watchInterface(interface)
    if not interface then return end
    local persistent = interface:FindFirstChild("Persistent")
    if persistent then attachPersistent(persistent) end
    table.insert(LOCOPANI_CustomCardConnections, interface.ChildAdded:Connect(function(child)
      if child.Name == "Persistent" then attachPersistent(child) end
    end))
  end

  local interface = playerGui:FindFirstChild("Interface")
  if interface then watchInterface(interface) end
  table.insert(LOCOPANI_CustomCardConnections, playerGui.ChildAdded:Connect(function(child)
    if child.Name == "Interface" then
      task.delay(0.2, function()
        if LOCOPANI_CustomCardEnabled and child.Parent then watchInterface(child) end
      end)
    end
  end))
end

v546.PlayerCardGroup:AddToggle("customcardimageenabled", {
  Text = "Card Personalizado",
  Tooltip = "Troca a arte do card apenas na sua tela.",
  Default = false,
  Callback = function(enabled)
    LOCOPANI_CustomCardEnabled = enabled == true
    if LOCOPANI_CustomCardEnabled then
      LOCOPANI_StartCustomCardWatcher()
      local interface = localPlayer2:FindFirstChildOfClass("PlayerGui")
      interface = interface and interface:FindFirstChild("Interface")
      local persistent = interface and interface:FindFirstChild("Persistent")
      if persistent then
        for _, frame in ipairs(persistent:GetChildren()) do
          LOCOPANI_ApplyCustomCardToFrame(frame)
        end
      end
      local image = LOCOPANI_GetCustomCardImage(LOCOPANI_CUSTOM_CARD_IMAGES[LOCOPANI_CustomCardSelection])
      if not image then
        v174:Notify("Edite o ID da imagem no bloco LOCOPANI_CUSTOM_CARD_IMAGES do script.")
      end
    else
      LOCOPANI_StopCustomCardWatcher()
      LOCOPANI_RestoreCustomCardImages()
    end
  end,
})

local LOCOPANI_CustomCardNames = {}
for name in pairs(LOCOPANI_CUSTOM_CARD_IMAGES) do
  table.insert(LOCOPANI_CustomCardNames, name)
end
table.sort(LOCOPANI_CustomCardNames)

v546.PlayerCardGroup:AddDropdown("customcardimageselect", {
  Values = LOCOPANI_CustomCardNames,
  Default = LOCOPANI_CustomCardSelection,
  Text = "Imagem do Card",
  Callback = function(value)
    if value and LOCOPANI_CUSTOM_CARD_IMAGES[value] then
      LOCOPANI_CustomCardSelection = value
      if LOCOPANI_CustomCardEnabled then
        local playerGui = localPlayer2:FindFirstChildOfClass("PlayerGui")
        local interface = playerGui and playerGui:FindFirstChild("Interface")
        local persistent = interface and interface:FindFirstChild("Persistent")
        if persistent then
          for _, frame in ipairs(persistent:GetChildren()) do
            LOCOPANI_ApplyCustomCardToFrame(frame)
          end
        end
      end
    end
  end,
})

end)

v546.PlayerCardGroup:AddDropdown("cardselect", {
  Values = v210,
  Default = v210[1] or "UltimateChampionPlayerCard",
  Text = "Select Player Card",
  Callback = function(value158)
    if value158 then
      v207 = value158
      _G.PlayerCard.Apply(value158)
      v174:Notify("Selected Card: " .. value158)
    end
  end,
})

v546.PlayerCardGroup:AddToggle("playercard", {
  Text = "PlayerCard Changer",
  Tooltip = "Change player card",
  Default = false,
  Callback = function(value159)
    v206 = value159

    -- Add/remove PlayerCard items in the local inventory view while enabled.
    -- This is client-side only; it does not grant server-side ownership.
    pcall(function()
      if v451 and v451.mark then
        v451.mark("PlayerCard", value159)
      end
    end)

    if value159 then
      f58()
    elseif not v238.CardEnabled then
      f57()
    end
  end,
})

v546.PlayerCardGroup:AddToggle("randomcard", {
  Text = "Random Card",
  Tooltip = "Sorteia um dos cards favoritos quando o card for aplicado. Sem favoritos, usa todos.",
  Default = false,
  Callback = function(value160)
    v238.CardEnabled = value160

    if value160 then
      local f50_5 = f50("PlayerCard")

      if f50_5 then
        v207 = f50_5
        v174:Notify("Random Card: " .. f50_5)
      end

      if not v206 then
        f58()
      end
    elseif not v206 then
      f57()
    end
  end,
})

v546.PlayerCardGroup:AddDropdown("randomcardpool", {
  Values = v210,
  Default = {},
  Multi = true,
  Text = "Cards favoritos para sorteio (vazio = todos)",
  Callback = function(selected)
    local pool = {}
    if type(selected) == "table" then
      for key, value in pairs(selected) do
        if type(key) == "string" and value == true then pool[key] = true
        elseif type(key) == "number" and type(value) == "string" then pool[value] = true end
      end
    end
    LOCOPANI_RandomPool.PlayerCard = pool
  end,
})

v545.Visuals:AddRightGroupbox("Title Changer"):AddToggle("titleunlock", {
  Text = "Title Changer",
  Tooltip = "Change title",
  Default = false,
  Callback = function(value161) v451.mark("Title", value161) end,
})

v546.BallSkinGroup = v545.Visuals:AddLeftGroupbox("Ball Changer")

v546.BallSkinGroup:AddDropdown("ballskinselect", {
  Values = v212,
  Default = v212[1] or "ClassicBall",
  Text = "Select Ball Skin",
  Callback = function(value162)
    if value162 then
      ball = value162
      v174:Notify("Selected Ball Skin: " .. value162)
    end
  end,
})

v546.BallSkinGroup:AddToggle("autoapplyball", {
  Text = "Auto Apply Ball",
  Tooltip = "Automatically apply selected ball skin",
  Default = false,
  Callback = function(value163)
    v220 = value163
    f108()
    v451.mark("Ball", value163)
  end,
})

v546.BallSkinGroup:AddToggle("randomball", {
  Text = "Random Ball",
  Tooltip = "Pick random ball when ball spawns",
  Default = false,
  Callback = function(value164) v238.BallEnabled = value164 end,
})

v546.BallSkinGroup:AddDropdown("randomballpool", {
  Values = v212,
  Default = {},
  Multi = true,
  Text = "Random Ball: bolas sorteadas (vazio = todas)",
  Callback = function(selected)
    local pool = {}
    if type(selected) == "table" then
      for key, value in pairs(selected) do
        if type(key) == "string" and value == true then pool[key] = true
        elseif type(key) == "number" and type(value) == "string" then pool[value] = true end
      end
    end
    LOCOPANI_RandomPool.Ball = pool
  end,
})

v546.VisualLevelGroup = v545.Visuals:AddRightGroupbox("Visual Level")

v546.VisualLevelGroup:AddInput("visuallevelvalue", {
  Default = "1000",
  Text = "Displayed Level",
  Placeholder = "1000",
  Callback = function(value167)
    local numeric = tonumber(value167)
    if numeric and numeric >= 0 then
      LOCOPANI_VisualLevel.Value = tostring(math.floor(numeric))
      if LOCOPANI_VisualLevel.Enabled then
        LOCOPANI_VisualLevel:SetEnabled(false)
        LOCOPANI_VisualLevel:SetEnabled(true)
      end
    end
  end,
})

v546.VisualLevelGroup:AddToggle("visuallevel", {
  Text = "Change Level (Visual Only)",
  Tooltip = "Changes level text locally in your interface only; it does not change the real account level.",
  Default = false,
  Callback = function(value168)
    LOCOPANI_VisualLevel:SetEnabled(value168)
    v174:Notify(value168 and ("Visual level set to " .. LOCOPANI_VisualLevel.Value) or "Visual level disabled")
  end,
})

v546.VisualLevelGroup:AddButton({
  Text = "Apply Visual Level",
  Func = function()
    if LOCOPANI_VisualLevel.Enabled then
      LOCOPANI_VisualLevel:SetEnabled(false)
      LOCOPANI_VisualLevel:SetEnabled(true)
      v174:Notify("Visual level applied: " .. LOCOPANI_VisualLevel.Value)
    else
      v174:Notify("Enable Change Level (Visual Only) first")
    end
  end,
})

v546.VisualLevelGroup:AddInput("visualstreakvalue", {
  Default = "0",
  Text = "Displayed Streak",
  Placeholder = "0",
  Callback = function(value)
    local numeric = tonumber(value)
    if numeric and numeric >= 0 then
      LOCOPANI_VisualStreak.Value = tostring(math.floor(numeric))
      if LOCOPANI_VisualStreak.Enabled then
        LOCOPANI_VisualStreak:SetEnabled(false)
        LOCOPANI_VisualStreak:SetEnabled(true)
      end
    end
  end,
})

v546.VisualLevelGroup:AddToggle("visualstreak", {
  Text = "Streak Change (Visual Only)",
  Tooltip = "Changes streak text locally only; it does not change real wins or level.",
  Default = false,
  Callback = function(value)
    LOCOPANI_VisualStreak:SetEnabled(value)
    v174:Notify(value and ("Visual streak set to " .. LOCOPANI_VisualStreak.Value) or "Visual streak disabled")
  end,
})

v546.VisualLevelGroup:AddButton({
  Text = "Apply Visual Streak",
  Func = function()
    if LOCOPANI_VisualStreak.Enabled then
      LOCOPANI_VisualStreak:SetEnabled(false)
      LOCOPANI_VisualStreak:SetEnabled(true)
      v174:Notify("Visual streak applied: " .. LOCOPANI_VisualStreak.Value)
    else
      v174:Notify("Enable Streak Change (Visual Only) first")
    end
  end,
})

v546.JerseyGroup = v545.Visuals:AddRightGroupbox("Jersey Changer")

v546.JerseyGroup:AddDropdown("jerseyselect", {
  Values = v211,
  Default = v211[1] or "DragonTuxedoJersey",
  Text = "Select Jersey",
  Callback = function(value165)
    if value165 then
      jersey = value165
      v418 = nil
      v174:Notify("Selected Jersey: " .. value165)
    end
  end,
})

v546.JerseyGroup:AddToggle("unlockalljerseysinventory", {
  Text = "Unlock All Jerseys in Inventory",
  Tooltip = "Shows all jerseys in the local Misc inventory view only. Does not equip them or grant server ownership.",
  Default = false,
  Callback = function(enabled)
    v451.unlockAllJerseys = enabled == true
    -- Refresh the local inventory view. This does not touch Equipped.
    pcall(function()
      if v451 and v451.mark then
        v451.mark("Jersey", enabled == true)
      end
    end)
  end,
})

v546.JerseyGroup:AddToggle("autoapplyjersey", {
  Text = "Auto Apply Jersey",
  Tooltip = "Automatically apply the selected jersey to your character (visual only).",
  Default = false,
  Callback = function(value166)
    v219 = value166
    f105(jersey)
  end,
})

-- Jersey Number Changer: local-only number overlay on the character torso.
-- It does not modify the server's outfit or other players' view.
do
  local jerseyNumberValue = "10"
  local jerseyNumberEnabled = false
  local jerseyNumberRespawnConnection

  local function removeJerseyNumber(character)
    character = character or (localPlayer2 and localPlayer2.Character)
    -- GUIs are parented to PlayerGui, so searching only the character left old
    -- overlays alive and stacked a new number on top every time Apply was used.
    local roots = {}
    if character then table.insert(roots, character) end
    local playerGui = localPlayer2 and localPlayer2:FindFirstChildOfClass("PlayerGui")
    if playerGui then table.insert(roots, playerGui) end
    for _, root in ipairs(roots) do
      for _, guiName in ipairs({"LOCOPANI_JerseyNumberFront", "LOCOPANI_JerseyNumberBack"}) do
        local gui = root:FindFirstChild(guiName, true)
        while gui do
          gui:Destroy()
          gui = root:FindFirstChild(guiName, true)
        end
      end
    end
  end

  local function applyJerseyNumber()
    local character = localPlayer2 and localPlayer2.Character
    if not character then
      v174:Notify("Personagem ainda não carregou.")
      return false
    end

    local torso = character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")
    if not torso or not torso:IsA("BasePart") then
      v174:Notify("Não foi possível encontrar o torso do personagem.")
      return false
    end

    local number = tostring(jerseyNumberValue or ""):gsub("%s+", "")
    if number == "" or not number:match("^%d%d?%d?$") then
      v174:Notify("Digite um número de camisa de 0 a 999.")
      return false
    end

    removeJerseyNumber(character)

    local function createNumberGui(guiName, face)
      local surface = Instance.new("SurfaceGui")
      surface.Name = guiName
      surface.Adornee = torso
      surface.Face = face
      surface.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
      surface.PixelsPerStud = 100
      -- Render above the game's jersey SurfaceGui so the number is not hidden.
      surface.AlwaysOnTop = true
      surface.LightInfluence = 0

      local label = Instance.new("TextLabel")
      label.Name = "Number"
      label.BackgroundTransparency = 1
      label.Size = UDim2.new(0.72, 0, 0.42, 0)
      label.Position = UDim2.new(0.14, 0, 0.31, 0)
      label.Font = Enum.Font.GothamBlack
      label.Text = number
      label.TextScaled = true
      label.TextColor3 = Color3.fromRGB(255, 255, 255)
      label.TextStrokeColor3 = Color3.fromRGB(20, 20, 20)
      label.TextStrokeTransparency = 0.15
      label.Parent = surface
      -- Parenting to PlayerGui keeps this overlay separate from jersey cleanup code.
      local playerGui = localPlayer2:FindFirstChildOfClass("PlayerGui")
      surface.Parent = playerGui or character
    end

    createNumberGui("LOCOPANI_JerseyNumberFront", Enum.NormalId.Front)
    createNumberGui("LOCOPANI_JerseyNumberBack", Enum.NormalId.Back)
    v174:Notify("Número de camisa aplicado: " .. number)
    return true
  end

  v546.JerseyNumberGroup = v545.Visuals:AddRightGroupbox("Jersey Number")

  v546.JerseyNumberGroup:AddInput("jerseynumbervalue", {
    Text = "Número da camisa",
    Default = "10",
    Placeholder = "0 a 999",
    Numeric = true,
    Finished = true,
    Callback = function(value)
      jerseyNumberValue = tostring(value or "")
    end,
  })

  v546.JerseyNumberGroup:AddToggle("jerseynumberenabled", {
    Text = "Ativar número personalizado",
    Tooltip = "Mostra o número na frente e nas costas do seu personagem (visual local).",
    Default = false,
    Callback = function(enabled)
      jerseyNumberEnabled = enabled == true
      if jerseyNumberEnabled then
        applyJerseyNumber()
      else
        removeJerseyNumber()
      end
    end,
  })

  v546.JerseyNumberGroup:AddButton({
    Text = "Aplicar número",
    Func = function()
      local toggle = toggles.jerseynumberenabled
      if toggle and toggle.SetValue then
        if not toggle.Value then
          toggle:SetValue(true)
        else
          jerseyNumberEnabled = true
          applyJerseyNumber()
        end
      else
        jerseyNumberEnabled = true
        applyJerseyNumber()
      end
    end,
  })

  v546.JerseyNumberGroup:AddButton({
    Text = "Restaurar camisa",
    Func = function()
      jerseyNumberEnabled = false
      removeJerseyNumber()
      local toggle = toggles.jerseynumberenabled
      if toggle and toggle.SetValue and toggle.Value then
        toggle:SetValue(false)
      end
      v174:Notify("Número personalizado removido.")
    end,
  })

  if jerseyNumberRespawnConnection then
    pcall(function() jerseyNumberRespawnConnection:Disconnect() end)
  end
  jerseyNumberRespawnConnection = localPlayer2.CharacterAdded:Connect(function(character)
    task.wait(1)
    if jerseyNumberEnabled and character and character.Parent then
      pcall(applyJerseyNumber)
    end
  end)
end

v546.MiscFFlagsGroup = v545.Misc:AddLeftGroupbox("FFlags Applier")

v546.MiscFFlagsGroup:AddTextBox("fflagsbox", {
  Text = "Fflags JSON (risky)",
  Placeholder = '{ "DFIntTaskSchedulerTargetFps": "9999" }',
  Height = 170,
  Default = "",
})

v546.MiscFFlagsGroup:AddButton({
  Text = "Apply FFlags",
  Func = function()
    local GetValue = options.fflagsbox:GetValue()

    if GetValue == "" then
      v174:Notify("Paste some JSON first")
      return
    end

    v336.apply(GetValue)
  end,
})

v546.MiscFFlagsGroup:AddButton({
  Text = "Load Example",
  Func = function()
    options.fflagsbox:SetValue(v336.example())
    v174:Notify("Example loaded")
  end,
})

v546.MiscFFlagsGroup:AddButton({
  Text = "Clear",
  Func = function() options.fflagsbox:SetValue("") end,
})

v546.MiscStyleGroup = v545.Misc:AddLeftGroupbox("Auto Style Spin")

v546.MiscStyleGroup:AddToggle("autostyle", {
  Text = "Auto Style Spin",
  Tooltip = "Auto spin until target style obtained",
  Default = false,
  Callback = function(value167)
    v213 = value167

    if value167 then
      f130()
    end
  end,
})

v546.MiscStyleGroup:AddDropdown("spintype", {
  Values = { "Normal", "Lucky" },
  Default = "Normal",
  Text = "Spin Type",
  Callback = function(value168) v217 = value168 end,
})

v546.MiscStyleGroup:AddInput("targetstyle", {
  Default = "",
  Text = "Target Style (Type manually)",
  Placeholder = "Sanju",
  Callback = function(value169) v215 = { value169 } end,
})

v546.MiscStyleGroup:AddDropdown("stylelist", {
  Values = {
    "Ronin", "Hidari", "Jinko", "Timeskip Hinto", "Timeskip Kyamo", "Akuto", "Taichou", "Sanju",
    "Mikage", "Kazana", "Timeskip Okazu", "Kisuki", "Bakuri", "Kyamo", "Okazu", "Hirakumi",
    "Kozai", "Azmei", "Uchikai", "Yokai", "Yogan", "Sazuroku", "Kyoshin", "Yomosuke", "Oyatsu",
    "Tsuchiro", "Imaezi", "Tonkura", "Ninyoku", "Hinto", "Hakochi", "Yakisukai", "Sagumi",
    "Koshoti",
  },
  Default = "Ronin",
  Text = "Style List (Select to auto-fill)",
  Callback = function(value170)
    options.targetstyle:SetValue(value170)
    v215 = { value170 }
  end,
})

v546.MiscAbilityGroup = v545.Misc:AddRightGroupbox("Auto Ability Spin")

v546.MiscAbilityGroup:AddToggle("autoabilityspin", {
  Text = "Auto Ability Spin",
  Tooltip = "Auto spin until target ability obtained",
  Default = false,
  Callback = function(value171)
    v214 = value171

    if value171 then
      f118()
    end
  end,
})

v546.MiscAbilityGroup:AddDropdown("abilityspintype", {
  Values = { "Normal", "Lucky" },
  Default = "Normal",
  Text = "Ability Spin Type",
  Callback = function(value172) v218 = value172 end,
})

v546.MiscAbilityGroup:AddInput("targetability", {
  Default = "",
  Text = "Target Ability (Type manually)",
  Placeholder = "Shield Breaker",
  Callback = function(value173) v216 = { value173 } end,
})

v546.MiscAbilityGroup:AddDropdown("abilitylist", {
  Values = {
    "Shield Breaker", "Magnetic Pull", "Lead Feet", "Extra Touch", "Godly", "Redirection Jump",
    "Curve Spike", "Divine Strength", "Legendary", "Steel Block", "Zero Gravity Set", "Rare",
    "Boom Jump", "Moonball", "Common", "Super Sprint", "Team Spirit", "Rolling Thunder",
  },
  Default = "Shield Breaker",
  Text = "Ability List (Select to auto-fill)",
  Callback = function(value174)
    options.targetability:SetValue(value174)
    v216 = { value174 }
  end,
})

v546.MiscShopGroup = v545.Misc:AddRightGroupbox("Shop")

v546.MiscShopGroup:AddButton({
  Text = "Buy Emote",
  Func = function()
    local RF_4 = replicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.PackService.RF

    if RF_4 then
      local Open = RF_4:FindFirstChild("Open")

      if Open then
        Open:InvokeServer("Emote1")
      end
    end
  end,
})

v546.MiscShopGroup:AddButton({
  Text = "Buy Effect",
  Func = function()
    local RF_5 = replicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.PackService.RF

    if RF_5 then
      local Open_2 = RF_5:FindFirstChild("Open")

      if Open_2 then
        Open_2:InvokeServer("ScoreEffect1")
      end
    end
  end,
})

v546.MiscShopGroup:AddButton({
  Text = "Buy Extreme Ball",
  Func = function()
    local RF_6 = replicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.PackService.RF

    if RF_6 then
      local Open_3 = RF_6:FindFirstChild("Open")

      if Open_3 then
        Open_3:InvokeServer("Extreme")
      end
    end
  end,
})

v546.MiscShopGroup:AddButton({
  Text = "Buy Medium Ball",
  Func = function()
    local RF_7 = replicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.PackService.RF

    if RF_7 then
      local Open_4 = RF_7:FindFirstChild("Open")

      if Open_4 then
        Open_4:InvokeServer("Medium")
      end
    end
  end,
})

v546.MiscShopGroup:AddButton({
  Text = "Buy Basic Ball",
  Func = function()
    local RF_8 = replicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.PackService.RF

    if RF_8 then
      local Open_5 = RF_8:FindFirstChild("Open")

      if Open_5 then
        Open_5:InvokeServer("Basic")
      end
    end
  end,
})

v546.MiscClaimGroup = v545.Misc:AddRightGroupbox("Claim Rewards")

v546.MiscClaimGroup:AddButton({
  Text = "Claim Level Rewards",
  Func = function()
    local LevelService = replicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.LevelService

    if LevelService then
      local RF_9 = LevelService:FindFirstChild("RF")

      if RF_9 then
        local ClaimLevelRewards = RF_9:FindFirstChild("ClaimLevelRewards")

        if ClaimLevelRewards then
          ClaimLevelRewards:InvokeServer()
        end
      end
    end
  end,
})

v546.MiscClaimGroup:AddButton({
  Text = "Claim Quest Rewards",
  Func = function()
    local QuestService = replicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.QuestService

    if QuestService then
      local RF_10 = QuestService:FindFirstChild("RF")

      if RF_10 then
        local ClaimAll = RF_10:FindFirstChild("ClaimAll")

        if ClaimAll then
          ClaimAll:InvokeServer(true)
        end
      end
    end
  end,
})

do
  v546.MiscClaimGroup:AddButton({
    Text = "Redeem All Codes",
    Func = function()
      local function f131()
        local v553, v554 = pcall(function()
          return httpGet("https://beebom.com/haikyuu-legends-codes/")
        end)

        if not v553 or not v554 then
          return {}
        else
          local v555 = {}
          local v556 = {}

          for match in string.gmatch(v554, [[
[^
]+]]) do
            if string.find(match, "(NEW)") then
              local StringMatch_2 = string.match(match, "(%u+[%u%d_]+)")

              if StringMatch_2 and not v556[StringMatch_2] then
                v556[StringMatch_2] = true
                table.insert(v555, StringMatch_2)
              end
            end

            if #v555 >= 3 then
              break
            end
          end

          return v555
        end
      end

      local f131_2 = f131()

      if #f131_2 > 0 then
        for key23, value175 in pairs(f131_2) do
          local CodeService = replicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.CodeService

          if CodeService then
            local RF_11 = CodeService:FindFirstChild("RF")

            if RF_11 then
              local Redeem = RF_11:FindFirstChild("Redeem")

              if Redeem then
                Redeem:InvokeServer(value175)
              end
            end
          end

          task.wait(0.01)
        end
      end
    end,
  })

  v546.GameJoinGroup = v545.GameJoin:AddLeftGroupbox("Game Modes")

  for index90, value176 in ipairs({
    { "Chaos Mode", "ChaosMode" }, { "1v1 Mini Map", "OnesMini" }, { "2v2 Ranked", "Twos" },
    { "3v3 Ranked", "Threes" }, { "4v4 Ranked", "Fours" }, { "6v6 Ranked", "Sixes" },
    { "Training", "Training" },
  }) do
    local Value176 = value176

    v546.GameJoinGroup:AddButton({
      Text = Value176[1],
      Func = function()
        v174:Notify("Joining " .. Value176[1] .. "...")
        local RF_12 = replicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.PartyService.RF
        local requestTeleport

        if RF_12 then
          requestTeleport = RF_12:FindFirstChild("RequestTeleport")

          if requestTeleport then
            pcall(function()
              requestTeleport:InvokeServer(Value176[2])
              v174:Notify("Joined " .. Value176[1] .. "!")
            end)
          end
        end
      end,
    })
  end

  local AddLeftGroupbox = v545["UI Settings"]:AddLeftGroupbox("Menu")

  -- LOCOPANI: Idioma (dropdown com todos os idiomas)
  do
    local I18N = ((type(getgenv) == "function" and getgenv()) or _G).LOCOPANI_I18N
    if I18N then
      AddLeftGroupbox:AddDropdown("LOCOPANILanguage", {
        Values = I18N.GetDisplayNames(),
        Default = I18N.GetDisplayName(I18N.Lang),
        Text = I18N.T("Idioma"),
        Callback = function(value)
          local code = I18N.CodeFromDisplay(value)
          if code and code ~= I18N.Lang then
            I18N.SetLanguage(code)
            pcall(function() v174:Notify(I18N.T("Idioma alterado.")) end)
          end
        end,
      })
      AddLeftGroupbox:AddDivider()
    end
  end

  AddLeftGroupbox:AddToggle("KeybindMenuOpen", {
    Default = v174.KeybindFrame.Visible,
    Text = "Open Keybind Menu",
    Callback = function(value177) v174.KeybindFrame.Visible = value177 end,
  })

  AddLeftGroupbox:AddDropdown("NotificationSide", {
    Values = { "Left", "Right" },
    Default = "Right",
    Text = "Notification Side",
    Callback = function(value178) v174:SetNotifySide(value178) end,
  })

  AddLeftGroupbox:AddDropdown("DPIDropdown", {
    Values = { "50%", "75%", "100%", "125%", "150%", "175%", "200%" },
    Default = "100%",
    Text = "DPI Scale",
    Callback = function(value179) v174:SetDPIScale((tonumber((value179:gsub("%%", ""))))) end,
  })

  AddLeftGroupbox:AddSlider("UICornerSlider", {
    Text = "Corner Radius",
    Default = v174.CornerRadius,
    Min = 0,
    Max = 20,
    Rounding = 0,
    Callback = function(value180) LOCOPANIHUBWindow:SetCornerRadius(value180) end,
  })

  AddLeftGroupbox:AddDivider()

  AddLeftGroupbox:AddLabel("Menu bind"):AddKeyPicker("MenuKeybind", {
    Default = "RightShift",
    NoUI = true,
    Text = "Menu keybind",
  })

  AddLeftGroupbox:AddButton("Unload", function() v174:Unload() end)

  v174.ToggleKeybind = options.MenuKeybind
end


-- LOCOPANI CONFIG UI (isolated helper)
LOCOPANI_BuildConfigUI(v174, LOCOPANI_RAY_WINDOW, LOCOPANI_RayControl, LOCOPANI_ARGON)

do
  v174:SetConfigFolder("LOCOPANI")
  pcall(function() v174:LoadAutoloadConfig() end)

  -- O botao flutuante circular com "L" foi removido.
  -- A janela principal continua podendo ser aberta/fechada com RightShift.
  v174:Notify("LOCOPANI HUB Loaded Successfully! UPDATE V2.3")
  pcall(function() LOCOPANI_ARGON:Notify({ Title = "LOCOPANI", Content = "LOCOPANI carregado com sucesso! UPDATE V2.3", Duration = 3 }) end)
end

-- Global search: results include controls from every category, not just the active tab.
do
  local window = LOCOPANI_RAY_WINDOW and LOCOPANI_RAY_WINDOW._window
  if window and window.Sidebar and window.Tabs then
    local searchBox
    for _, item in ipairs(window.Sidebar:GetDescendants()) do
      if item:IsA("TextBox") and item.PlaceholderText == "Search this tab" then
        searchBox = item
        break
      end
    end
    if searchBox then
      searchBox.PlaceholderText = "Buscar em todas as categorias"
      local sidebar = window.Sidebar
      local resultPanel = Instance.new("Frame")
      resultPanel.Name = "LOCOPANI_GlobalSearchResults"
      resultPanel.BackgroundColor3 = Color3.fromRGB(17, 12, 27)
      resultPanel.BackgroundTransparency = 0.06
      resultPanel.BorderSizePixel = 0
      resultPanel.Position = UDim2.fromOffset(12, 114)
      resultPanel.Size = UDim2.new(1, -24, 1, -174)
      resultPanel.Visible = false
      resultPanel.ZIndex = 40
      resultPanel.ClipsDescendants = true
      resultPanel.Parent = sidebar
      local panelCorner = Instance.new("UICorner")
      panelCorner.CornerRadius = UDim.new(0, 10)
      panelCorner.Parent = resultPanel
      local panelStroke = Instance.new("UIStroke")
      panelStroke.Color = Color3.fromRGB(147, 92, 255)
      panelStroke.Transparency = 0.45
      panelStroke.Thickness = 1
      panelStroke.Parent = resultPanel
      local resultsScroll = Instance.new("ScrollingFrame")
      resultsScroll.Name = "Results"
      resultsScroll.Active = true
      resultsScroll.BackgroundTransparency = 1
      resultsScroll.BorderSizePixel = 0
      resultsScroll.Position = UDim2.fromOffset(5, 5)
      resultsScroll.Size = UDim2.new(1, -10, 1, -10)
      resultsScroll.CanvasSize = UDim2.fromOffset(0, 0)
      resultsScroll.ScrollBarThickness = 2
      resultsScroll.ScrollBarImageColor3 = Color3.fromRGB(165, 110, 255)
      resultsScroll.ZIndex = 41
      resultsScroll.Parent = resultPanel
      local resultLayout = Instance.new("UIListLayout")
      resultLayout.Padding = UDim.new(0, 5)
      resultLayout.SortOrder = Enum.SortOrder.LayoutOrder
      resultLayout.Parent = resultsScroll
      resultLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
        resultsScroll.CanvasSize = UDim2.fromOffset(0, resultLayout.AbsoluteContentSize.Y + 8)
      end)

      window._LOCOPANI_ClearSearchResults = function()
        for _, child in ipairs(resultsScroll:GetChildren()) do
          if child:IsA("TextButton") or child:IsA("TextLabel") then child:Destroy() end
        end
      end
      window._LOCOPANI_MakeSearchResultLabel = function(textValue, order)
        local label = Instance.new("TextLabel")
        label.BackgroundTransparency = 1
        label.LayoutOrder = order
        label.Size = UDim2.new(1, -8, 0, 38)
        label.Font = Enum.Font.Gotham
        label.Text = textValue
        label.TextColor3 = Color3.fromRGB(175, 164, 197)
        label.TextSize = 11
        label.TextWrapped = true
        label.ZIndex = 42
        label.Parent = resultsScroll
      end
      window._LOCOPANI_RebuildSearchResults = function(query)
        window._LOCOPANI_ClearSearchResults()
        query = tostring(query or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
        resultPanel.Visible = query ~= ""
        if query == "" then return end
        local count = 0
        for _, tab in ipairs(window.Tabs) do
          for _, section in ipairs(tab._sections or {}) do
            for _, element in ipairs(section.Elements or {}) do
              local name = tostring(element.Name or "Option")
              local sectionName = tostring(section.Name or "")
              local tabName = tostring(tab.Name or "")
              local searchable = (name .. " " .. sectionName .. " " .. tabName):lower()
              if searchable:find(query, 1, true) then
                count += 1
                if count <= 35 then
                  local button = Instance.new("TextButton")
                  button.Name = "LOCOPANI_SearchResult"
                  button.AutoButtonColor = false
                  button.BackgroundColor3 = Color3.fromRGB(35, 25, 51)
                  button.BackgroundTransparency = 0.12
                  button.BorderSizePixel = 0
                  button.LayoutOrder = count
                  button.Size = UDim2.new(1, -4, 0, 43)
                  button.Text = ""
                  button.ZIndex = 43
                  button.Parent = resultsScroll
                  local corner = Instance.new("UICorner")
                  corner.CornerRadius = UDim.new(0, 7)
                  corner.Parent = button
                  local title = Instance.new("TextLabel")
                  title.BackgroundTransparency = 1
                  title.Position = UDim2.fromOffset(8, 3)
                  title.Size = UDim2.new(1, -16, 0, 19)
                  title.Font = Enum.Font.GothamMedium
                  title.Text = name
                  title.TextColor3 = Color3.fromRGB(245, 240, 255)
                  title.TextSize = 11
                  title.TextXAlignment = Enum.TextXAlignment.Left
                  title.TextTruncate = Enum.TextTruncate.AtEnd
                  title.ZIndex = 44
                  title.Parent = button
                  local detail = Instance.new("TextLabel")
                  detail.BackgroundTransparency = 1
                  detail.Position = UDim2.fromOffset(8, 21)
                  detail.Size = UDim2.new(1, -16, 0, 16)
                  detail.Font = Enum.Font.Gotham
                  detail.Text = tabName .. "  /  " .. sectionName
                  detail.TextColor3 = Color3.fromRGB(170, 148, 206)
                  detail.TextSize = 9
                  detail.TextXAlignment = Enum.TextXAlignment.Left
                  detail.TextTruncate = Enum.TextTruncate.AtEnd
                  detail.ZIndex = 44
                  detail.Parent = button
                  button.MouseEnter:Connect(function() button.BackgroundTransparency = 0 end)
                  button.MouseLeave:Connect(function() button.BackgroundTransparency = 0.12 end)
                  button.MouseButton1Click:Connect(function()
                    resultPanel.Visible = false
                    searchBox.Text = ""
                    for _, otherTab in ipairs(window.Tabs) do
                      pcall(function() otherTab:_filter("") end)
                    end
                    window:_select(tab)
                    task.delay(0.28, function()
                      if element.Root and element.Root.Parent and tab.Page then
                        local y = element.Root.AbsolutePosition.Y - tab.Page.AbsolutePosition.Y + tab.Page.CanvasPosition.Y - 12
                        tab.Page.CanvasPosition = Vector2.new(0, math.max(0, y))
                      end
                    end)
                  end)
                end
              end
            end
          end
        end
        if count == 0 then
          window._LOCOPANI_MakeSearchResultLabel("Nenhuma opção encontrada.", 1)
        elseif count > 35 then
          window._LOCOPANI_MakeSearchResultLabel("Mostrando 35 de " .. tostring(count) .. " resultados.", 36)
        end
      end
      searchBox:GetPropertyChangedSignal("Text"):Connect(function()
        window._LOCOPANI_RebuildSearchResults(searchBox.Text)
      end)
      searchBox.FocusLost:Connect(function()
        if searchBox.Text == "" then resultPanel.Visible = false end
      end)
    end
  end
end

-- FIX SHIFTLOCK: se o shiftlock nativo do Roblox esta ligado (RotationType = CameraRelative)
-- e o menu esta fechado, garante que o cursor volte a ficar travado no centro.
-- (Abrir/fechar o menu liberava o mouse e ele nao voltava a travar.)
pcall(function()
  local uis = game:GetService("UserInputService")
  local rs = game:GetService("RunService")
  local gameSettings = UserSettings():GetService("UserGameSettings")
  local conn
  conn = rs.RenderStepped:Connect(function()
    if v174 and v174.Unloaded then
      conn:Disconnect()
      return
    end
    local win = LOCOPANI_RAY_WINDOW and LOCOPANI_RAY_WINDOW._window
    local menuOpen = win and win._visible
    if menuOpen or uis:GetFocusedTextBox() then return end
    if gameSettings.RotationType == Enum.RotationType.CameraRelative
      and uis.MouseBehavior ~= Enum.MouseBehavior.LockCenter then
      uis.MouseBehavior = Enum.MouseBehavior.LockCenter
    end
  end)
end)

pcall(function()
  local env = (type(getgenv) == "function" and getgenv()) or _G
  local L = env.LOCOPANI_LOADER
  local function finish() pcall(function() LOCOPANI_RAY_WINDOW._window:FinishLoading() end) end
  if L and L.OnReveal then L.OnReveal(finish) else finish() end
end)
pcall(function()
  local env = (type(getgenv) == "function" and getgenv()) or _G
  if env.LOCOPANI_LOADER then env.LOCOPANI_LOADER.Hide() end
end)

-- https://discord.gg/34P22Bgnbk
