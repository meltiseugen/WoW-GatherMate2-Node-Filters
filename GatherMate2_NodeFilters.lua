local ADDON_NAME = ...

local addon = {}
_G.GatherMate2_NodeFilters = addon

local NODE_TYPES = {
	{key = "Herb Gathering", label = "Herbs"},
	{key = "Mining", label = "Mining"},
	{key = "Fishing", label = "Fishing"},
	{key = "Extract Gas", label = "Gas"},
	{key = "Treasure", label = "Treasure"},
	{key = "Archaeology", label = "Archaeology"},
	{key = "Logging", label = "Timber"},
}

local DEFAULTS = {
	currentMapOnly = true,
	enabledTypesOnly = true,
}

local DEFAULT_UNCHECKED_VERSION = 2
local MAP_BUTTON_LEFT_OFFSET = 3

local GM
local db
local panel
local mapButton
local mapButtonAnchor
local LibDD
local dropDown
local rows = {}
local typeButtons = {}
local selectedType
local selectedTypeIndex = 1
local initialized
local hookedWorldMapPositioning

local function CopyDefaults(target, defaults)
	for key, value in pairs(defaults) do
		if target[key] == nil then
			target[key] = value
		end
	end
end

local function GetGMProfile()
	return GM and GM.db and GM.db.profile
end

local function UpdateGatherMate()
	local config = GM and GM.GetModule and GM:GetModule("Config", true)
	if config and config.UpdateConfig then
		config:UpdateConfig()
	elseif GM and GM.SendMessage then
		GM:SendMessage("GatherMate2ConfigChanged")
	end
	if WorldMapFrame and WorldMapFrame.RefreshAllDataProviders then
		WorldMapFrame:RefreshAllDataProviders()
	end
end

local function GetFilterDB(nodeType)
	local profile = GetGMProfile()
	if not profile then return nil end
	profile.filter = profile.filter or {}
	profile.filter[nodeType] = profile.filter[nodeType] or {["*"] = false}
	return profile.filter[nodeType]
end

local function IsNodeEnabled(nodeType, nodeID)
	local filter = GetFilterDB(nodeType)
	if not filter then return true end
	local state = filter[nodeID]
	if state == nil then
		state = filter["*"]
	end
	return state ~= false
end

local function SetNodeEnabled(nodeType, nodeID, enabled)
	local filter = GetFilterDB(nodeType)
	if not filter then return end
	filter[nodeID] = enabled and true or false
	UpdateGatherMate()
end

local function SetAllNodesEnabled(nodeType, enabled, nodeList)
	local filter = GetFilterDB(nodeType)
	if not filter then return end
	for _, node in ipairs(nodeList) do
		filter[node.id] = enabled and true or false
	end
	UpdateGatherMate()
end

local function SetOnlyNodeEnabled(nodeType, nodeID, nodeList)
	local filter = GetFilterDB(nodeType)
	if not filter then return end
	for _, node in ipairs(nodeList) do
		filter[node.id] = node.id == nodeID
	end
	UpdateGatherMate()
end

local function IsNodeTypeFullyEnabled(nodeType, nodeList)
	if #nodeList == 0 then return false end
	for _, node in ipairs(nodeList) do
		if not IsNodeEnabled(nodeType, node.id) then
			return false
		end
	end
	return true
end

local function GetIconMarkup(texture, size)
	if not texture then return "" end
	size = size or 14
	return ("|T%s:%d:%d:0:0|t "):format(texture, size, size)
end

local function GetNodeTypeIcon(nodeType, nodeList)
	for _, node in ipairs(nodeList) do
		if node.texture then
			return node.texture
		end
	end
	return "Interface\\AddOns\\GatherMate2\\Artwork\\Icon.tga"
end

local function IsTypeShownInGatherMate(nodeType)
	local profile = GetGMProfile()
	if not profile then return false end
	return profile.show and profile.show[nodeType] ~= "never"
end

local function GetCurrentMapID()
	if not WorldMapFrame or not WorldMapFrame.GetMapID then return nil end
	local mapID = WorldMapFrame:GetMapID()
	if mapID and GM and GM.phasing and GM.phasing[mapID] then
		mapID = GM.phasing[mapID]
	end
	return mapID
end

local function GetMapCanvasContainer()
	if WorldMapFrame and WorldMapFrame.GetCanvasContainer then
		local canvasContainer = WorldMapFrame:GetCanvasContainer()
		if canvasContainer then
			return canvasContainer
		end
	end
	return WorldMapFrame and (WorldMapFrame.ScrollContainer or WorldMapFrame)
end

local function GetMapButtonAnchor()
	local canvasContainer = GetMapCanvasContainer()
	if not canvasContainer then return nil end

	if not mapButtonAnchor then
		mapButtonAnchor = CreateFrame("Frame", nil, canvasContainer)
		mapButtonAnchor:SetSize(1, 1)
	end

	mapButtonAnchor:SetParent(canvasContainer)
	mapButtonAnchor:ClearAllPoints()
	mapButtonAnchor:SetPoint("TOPRIGHT", canvasContainer, "TOPRIGHT", -MAP_BUTTON_LEFT_OFFSET, 0)
	return mapButtonAnchor
end

local function GetWorldMapButtonStack()
	if LibStub then
		local stack = LibStub("Krowi_WorldMapButtons-1.4", true)
		if stack and stack.IsMainline and stack.SetPoints then
			return stack
		end
	end
	return nil
end

local function JoinWorldMapButtonStack(button)
	local stack = GetWorldMapButtonStack()
	if not stack then
		return false
	end

	stack.Buttons = stack.Buttons or {}
	if button.GM2NFButtonStack ~= stack then
		for _, stackedButton in next, stack.Buttons do
			if stackedButton == button then
				button.GM2NFButtonStack = stack
				button.relativeFrame = GetMapButtonAnchor()
				button:ClearAllPoints()
				stack.SetPoints()
				return true
			end
		end

		button.GM2NFButtonStack = stack
		button.relativeFrame = GetMapButtonAnchor()
		tinsert(stack.Buttons, button)
	end

	button.relativeFrame = GetMapButtonAnchor()
	button:ClearAllPoints()
	stack.SetPoints()
	return true
end

local function PositionMapButton()
	if not mapButton or not WorldMapFrame then return end

	if JoinWorldMapButtonStack(mapButton) then
		return
	end

	local canvasContainer = GetMapCanvasContainer()
	if not canvasContainer then return end
	mapButton:ClearAllPoints()
	mapButton:SetPoint("TOPRIGHT", canvasContainer, "TOPRIGHT", -4 - MAP_BUTTON_LEFT_OFFSET, -2)
end

local function GetNodeTexture(nodeType, nodeID)
	return GM and GM.nodeTextures and GM.nodeTextures[nodeType] and GM.nodeTextures[nodeType][nodeID]
end

local function AddNode(nodes, seen, nodeType, nodeID, name)
	nodeID = (GM.nodeIDReplacementMap and GM.nodeIDReplacementMap[nodeID]) or nodeID
	if nodeID and name and not seen[nodeID] then
		seen[nodeID] = true
		nodes[#nodes + 1] = {
			id = nodeID,
			name = name,
			texture = GetNodeTexture(nodeType, nodeID),
		}
	end
end

local function GetNodesForType(nodeType)
	local nodes = {}
	local seen = {}

	if db.currentMapOnly then
		local mapID = GetCurrentMapID()
		if mapID and GM.GetNodesForZone then
			for _, nodeID in GM:GetNodesForZone(mapID, nodeType, true) do
				local normalizedID = (GM.nodeIDReplacementMap and GM.nodeIDReplacementMap[nodeID]) or nodeID
				local name = GM:GetNameForNode(nodeType, normalizedID)
				AddNode(nodes, seen, nodeType, normalizedID, name)
			end
		end
	else
		local nodeIDs = GM.nodeIDs and GM.nodeIDs[nodeType]
		if nodeIDs then
			for name, nodeID in pairs(nodeIDs) do
				AddNode(nodes, seen, nodeType, nodeID, name)
			end
		end
	end

	table.sort(nodes, function(a, b)
		return a.name < b.name
	end)

	return nodes
end

local function GetVisibleNodeTypes()
	local visible = {}
	for _, nodeTypeInfo in ipairs(NODE_TYPES) do
		if not db.enabledTypesOnly or IsTypeShownInGatherMate(nodeTypeInfo.key) then
			visible[#visible + 1] = nodeTypeInfo
		end
	end
	return visible
end

local function ApplyDefaultUncheckedFilters()
	if db.defaultUncheckedVersion == DEFAULT_UNCHECKED_VERSION then return end

	for _, nodeTypeInfo in ipairs(NODE_TYPES) do
		local nodeType = nodeTypeInfo.key
		local filter = GetFilterDB(nodeType)
		if filter then
			filter["*"] = false

			local nodeIDs = GM.nodeIDs and GM.nodeIDs[nodeType]
			if nodeIDs then
				for _, nodeID in pairs(nodeIDs) do
					local normalizedID = (GM.nodeIDReplacementMap and GM.nodeIDReplacementMap[nodeID]) or nodeID
					filter[normalizedID] = false
				end
			end
		end
	end

	db.defaultUncheckedVersion = DEFAULT_UNCHECKED_VERSION
	UpdateGatherMate()
end

local function ClearRows()
	for _, row in ipairs(rows) do
		row:Hide()
	end
end

local function SetRow(row, nodeType, node, nodeList, y)
	row.nodeType = nodeType
	row.nodeID = node.id
	row:ClearAllPoints()
	row:SetPoint("TOPLEFT", panel.content, "TOPLEFT", 0, y)
	row:SetPoint("TOPRIGHT", panel.content, "TOPRIGHT", -4, y)

	row.check:SetChecked(IsNodeEnabled(nodeType, node.id))
	row.icon:SetTexture(node.texture or "Interface\\Icons\\INV_Misc_Herb_07")
	row.text:SetText(node.name)
	row.only:SetScript("OnClick", function()
		SetOnlyNodeEnabled(nodeType, node.id, nodeList)
		addon:RefreshRows()
	end)
	row.check:SetScript("OnClick", function(self)
		SetNodeEnabled(nodeType, node.id, self:GetChecked())
	end)
	row:Show()
end

local function AcquireRow(index)
	if rows[index] then return rows[index] end

	local row = CreateFrame("Frame", nil, panel.content)
	row:SetHeight(24)

	local check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
	check:SetSize(22, 22)
	check:SetPoint("LEFT", row, "LEFT", 0, 0)
	row.check = check

	local icon = row:CreateTexture(nil, "ARTWORK")
	icon:SetSize(18, 18)
	icon:SetPoint("LEFT", check, "RIGHT", 2, 0)
	row.icon = icon

	local text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	text:SetPoint("LEFT", icon, "RIGHT", 6, 0)
	text:SetPoint("RIGHT", row, "RIGHT", -52, 0)
	text:SetJustifyH("LEFT")
	row.text = text

	local only = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
	only:SetSize(44, 20)
	only:SetText("Only")
	only:SetPoint("RIGHT", row, "RIGHT", 0, 0)
	row.only = only

	rows[index] = row
	return row
end

function addon:RefreshTypeButtons()
	local visibleTypes = GetVisibleNodeTypes()
	if not visibleTypes[1] then
		selectedType = nil
	else
		selectedTypeIndex = math.min(selectedTypeIndex, #visibleTypes)
		selectedType = visibleTypes[selectedTypeIndex].key
	end

	for _, button in ipairs(typeButtons) do
		button:Hide()
	end

	for index, nodeTypeInfo in ipairs(visibleTypes) do
		local button = typeButtons[index]
		if not button then
			button = CreateFrame("Button", nil, panel.typeList, "UIPanelButtonTemplate")
			button:SetSize(108, 22)
			typeButtons[index] = button
		end

		button:SetPoint("TOPLEFT", panel.typeList, "TOPLEFT", 0, -((index - 1) * 25))
		button:SetText(nodeTypeInfo.label)
		button:SetScript("OnClick", function()
			selectedTypeIndex = index
			selectedType = nodeTypeInfo.key
			addon:RefreshRows()
			addon:RefreshTypeButtons()
		end)
		if nodeTypeInfo.key == selectedType then
			button:LockHighlight()
		else
			button:UnlockHighlight()
		end
		button:Show()
	end
end

function addon:RefreshRows()
	ClearRows()

	local nodeType = selectedType
	if not nodeType then
		panel.title:SetText("No enabled GatherMate2 node types")
		panel.content:SetHeight(1)
		return
	end

	local nodeList = GetNodesForType(nodeType)
	panel.title:SetText(nodeType .. " (" .. #nodeList .. ")")

	if #nodeList == 0 then
		panel.empty:Show()
		panel.content:SetHeight(26)
		return
	end

	panel.empty:Hide()
	local y = -2
	for index, node in ipairs(nodeList) do
		local row = AcquireRow(index)
		SetRow(row, nodeType, node, nodeList, y)
		y = y - 24
	end
	panel.content:SetHeight(math.max(1, #nodeList * 24 + 8))
end

function addon:Refresh()
	if not panel then return end
	self:RefreshTypeButtons()
	self:RefreshRows()
end

local function CreatePanel()
	if panel then return end

	panel = CreateFrame("Frame", "GatherMate2NodeFiltersPanel", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
	panel:SetSize(440, 520)
	panel:SetFrameStrata("DIALOG")
	panel:SetClampedToScreen(true)
	panel:EnableMouse(true)
	if panel.SetBackdrop then
		panel:SetBackdrop({
			bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
			edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
			tile = true,
			tileSize = 32,
			edgeSize = 32,
			insets = {left = 8, right = 8, top = 8, bottom = 8},
		})
	end
	panel:Hide()
	tinsert(UISpecialFrames, panel:GetName())

	local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", panel, "TOPLEFT", 18, -16)
	title:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -44, -16)
	title:SetJustifyH("LEFT")
	title:SetText("GatherMate2 Node Filters")

	local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -5, -5)

	local typeList = CreateFrame("Frame", nil, panel)
	typeList:SetPoint("TOPLEFT", panel, "TOPLEFT", 18, -54)
	typeList:SetSize(112, 400)
	panel.typeList = typeList

	local listTitle = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	listTitle:SetPoint("TOPLEFT", panel, "TOPLEFT", 144, -54)
	listTitle:SetText("")
	panel.title = listTitle

	local allButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	allButton:SetSize(76, 22)
	allButton:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -102, -50)
	allButton:SetText("All")
	allButton:SetScript("OnClick", function()
		if selectedType then
			SetAllNodesEnabled(selectedType, true, GetNodesForType(selectedType))
			addon:RefreshRows()
		end
	end)

	local noneButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	noneButton:SetSize(76, 22)
	noneButton:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -22, -50)
	noneButton:SetText("None")
	noneButton:SetScript("OnClick", function()
		if selectedType then
			SetAllNodesEnabled(selectedType, false, GetNodesForType(selectedType))
			addon:RefreshRows()
		end
	end)

	local scroll = CreateFrame("ScrollFrame", "GatherMate2NodeFiltersScrollFrame", panel, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 142, -78)
	scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -32, 18)
	panel.scroll = scroll

	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(260, 1)
	scroll:SetScrollChild(content)
	panel.content = content

	local empty = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	empty:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -4)
	empty:SetText("No nodes found for this selection.")
	empty:Hide()
	panel.empty = empty
end

local function ShowPanel(anchor)
	CreatePanel()
	panel:ClearAllPoints()
	panel:SetPoint("TOPRIGHT", anchor or UIParent, "BOTTOMRIGHT", 0, -6)
	addon:Refresh()
	panel:Show()
end

local function TogglePanel(anchor)
	CreatePanel()
	if panel:IsShown() then
		panel:Hide()
	else
		ShowPanel(anchor)
	end
end

local function RefreshDropDown()
	if LibDD and dropDown then
		LibDD:UIDropDownMenu_RefreshAll(dropDown)
	end
end

local function SetAllVisibleNodesEnabled(enabled)
	for _, nodeTypeInfo in ipairs(GetVisibleNodeTypes()) do
		local nodeList = GetNodesForType(nodeTypeInfo.key)
		if #nodeList > 0 then
			SetAllNodesEnabled(nodeTypeInfo.key, enabled, nodeList)
		end
	end
	RefreshDropDown()
end

local function AddDropDownTitle(text, level)
	LibDD:UIDropDownMenu_AddButton({
		text = text,
		isTitle = true,
		notCheckable = true,
	}, level)
end

local function AddLevelOneDropDown(level)
	AddDropDownTitle("GatherMate2 Node Filters", level)

	LibDD:UIDropDownMenu_AddSeparator(level)

	local hasAnyType = false
	for _, nodeTypeInfo in ipairs(GetVisibleNodeTypes()) do
		local nodeType = nodeTypeInfo.key
		local label = nodeTypeInfo.label
		local nodeList = GetNodesForType(nodeType)
		if #nodeList > 0 then
			hasAnyType = true
			local icon = GetNodeTypeIcon(nodeType, nodeList)
			LibDD:UIDropDownMenu_AddButton({
				text = GetIconMarkup(icon, 14) .. label,
				isNotRadio = true,
				keepShownOnClick = true,
				hasArrow = true,
				value = nodeType,
				checked = function()
					return IsNodeTypeFullyEnabled(nodeType, nodeList)
				end,
				arg1 = nodeType,
				arg2 = nodeList,
				func = function(button, selectedNodeType, selectedNodeList, checked)
					SetAllNodesEnabled(selectedNodeType, checked, selectedNodeList)
					if panel and panel:IsShown() then
						addon:RefreshRows()
					end
					RefreshDropDown()
				end,
			}, level)
		end
	end

	if not hasAnyType then
		LibDD:UIDropDownMenu_AddButton({
			text = "No nodes found for this selection",
			disabled = true,
			notCheckable = true,
		}, level)
	end

	LibDD:UIDropDownMenu_AddSeparator(level)

	LibDD:UIDropDownMenu_AddButton({
		text = "Show all",
		notCheckable = true,
		keepShownOnClick = true,
		func = function()
			SetAllVisibleNodesEnabled(true)
			if panel and panel:IsShown() then
				addon:RefreshRows()
			end
		end,
	}, level)

	LibDD:UIDropDownMenu_AddButton({
		text = "Hide all",
		notCheckable = true,
		keepShownOnClick = true,
		func = function()
			SetAllVisibleNodesEnabled(false)
			if panel and panel:IsShown() then
				addon:RefreshRows()
			end
		end,
	}, level)

end

local function AddNodeTypeDropDown(nodeType, level)
	local nodeList = GetNodesForType(nodeType)
	AddDropDownTitle(nodeType .. " (" .. #nodeList .. ")", level)

	if #nodeList == 0 then
		LibDD:UIDropDownMenu_AddButton({
			text = "No nodes found",
			disabled = true,
			notCheckable = true,
		}, level)
		return
	end

	LibDD:UIDropDownMenu_AddButton({
		text = "All",
		notCheckable = true,
		keepShownOnClick = true,
		arg1 = nodeType,
		arg2 = nodeList,
		func = function(_, selectedNodeType, selectedNodeList)
			SetAllNodesEnabled(selectedNodeType, true, selectedNodeList)
			if panel and panel:IsShown() then
				addon:RefreshRows()
			end
			RefreshDropDown()
		end,
	}, level)

	LibDD:UIDropDownMenu_AddButton({
		text = "None",
		notCheckable = true,
		keepShownOnClick = true,
		arg1 = nodeType,
		arg2 = nodeList,
		func = function(_, selectedNodeType, selectedNodeList)
			SetAllNodesEnabled(selectedNodeType, false, selectedNodeList)
			if panel and panel:IsShown() then
				addon:RefreshRows()
			end
			RefreshDropDown()
		end,
	}, level)

	LibDD:UIDropDownMenu_AddSeparator(level)

	for _, node in ipairs(nodeList) do
		local nodeID = node.id
		local name = node.name
		local icon = node.texture
		LibDD:UIDropDownMenu_AddButton({
			text = GetIconMarkup(icon, 14) .. name,
			isNotRadio = true,
			keepShownOnClick = true,
			checked = function()
				return IsNodeEnabled(nodeType, nodeID)
			end,
			arg1 = nodeType,
			arg2 = nodeID,
			func = function(button, selectedNodeType, selectedNodeID, checked)
				SetNodeEnabled(selectedNodeType, selectedNodeID, checked)
				if panel and panel:IsShown() then
					addon:RefreshRows()
				end
				RefreshDropDown()
			end,
		}, level)
	end
end

function addon:InitializeDropDown(level)
	level = level or 1
	if level == 1 then
		AddLevelOneDropDown(level)
	elseif level == 2 then
		local nodeType = L_UIDROPDOWNMENU_MENU_VALUE
		if nodeType then
			AddNodeTypeDropDown(nodeType, level)
		end
	end
end

local function EnsureDropDown(anchor)
	if dropDown then
		return true
	end
	if not LibDD then
		return false
	end

	dropDown = LibDD:Create_UIDropDownMenu("GatherMate2NodeFiltersDropDown", anchor or UIParent)
	LibDD:UIDropDownMenu_SetInitializeFunction(dropDown, function(_, level)
		addon:InitializeDropDown(level)
	end)
	LibDD:UIDropDownMenu_SetDisplayMode(dropDown, "MENU")
	return true
end

local function ToggleFilterMenu(anchor)
	if not EnsureDropDown(anchor) then
		TogglePanel(anchor)
		return
	end

	dropDown:SetParent(anchor or UIParent)
	local anchorFrame = anchor or mapButton or UIParent
	LibDD:ToggleDropDownMenu(1, nil, dropDown, anchorFrame, 0, -5)
end

SLASH_GATHERMATE2NODEFILTERS1 = "/gm2filters"
SLASH_GATHERMATE2NODEFILTERS2 = "/gm2nf"
SlashCmdList.GATHERMATE2NODEFILTERS = function()
	TogglePanel(_G.GatherMate2NodeFiltersButton or UIParent)
end

local function CreateMapButton()
	if _G.GatherMate2NodeFiltersButton or not WorldMapFrame then
		mapButton = _G.GatherMate2NodeFiltersButton
		PositionMapButton()
		return
	end

	local parent = WorldMapFrame
	local button = CreateFrame("Button", "GatherMate2NodeFiltersButton", parent)
	mapButton = button
	button:SetSize(30, 30)
	button:SetFrameStrata("DIALOG")
	button:SetFrameLevel((parent:GetFrameLevel() or 1) + 100)
	button:RegisterForClicks("LeftButtonUp")
	button.Refresh = PositionMapButton

	local background = button:CreateTexture(nil, "BACKGROUND")
	background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
	background:SetSize(25, 25)
	background:SetPoint("CENTER", button, "CENTER", 0, 0)

	local icon = button:CreateTexture(nil, "ARTWORK")
	icon:SetTexture("Interface\\AddOns\\GatherMate2\\Artwork\\Icon.tga")
	icon:SetSize(20, 20)
	icon:SetPoint("CENTER", button, "CENTER", 2, 0)

	local border = button:CreateTexture(nil, "OVERLAY")
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	border:SetSize(54, 54)
	border:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)

	button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight", "ADD")
	button:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("GatherMate2 Node Filters")
		GameTooltip:AddLine("Open node subtype filters.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	button:SetScript("OnClick", function(self)
		ToggleFilterMenu(self)
	end)

	PositionMapButton()
end

local function HookWorldMapPositioning()
	if hookedWorldMapPositioning or not WorldMapFrame then return end

	if WorldMapFrame.RefreshOverlayFrames then
		hooksecurefunc(WorldMapFrame, "RefreshOverlayFrames", PositionMapButton)
	elseif WorldMapFrame.OnMapChanged then
		hooksecurefunc(WorldMapFrame, "OnMapChanged", PositionMapButton)
	end

	WorldMapFrame:HookScript("OnShow", PositionMapButton)
	hookedWorldMapPositioning = true
end

local function RegisterGatherMateConfigModule()
	local config = GM and GM.GetModule and GM:GetModule("Config", true)
	if not config or not config.RegisterModule then return end

	config:RegisterModule("Node Filters", {
		type = "group",
		name = "Node Filters",
		args = {
			description = {
				type = "description",
				name = "Use the world map node-filter button to toggle GatherMate2 node subtypes quickly.",
				order = 1,
			},
		},
	})
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(_, event, addonName)
	if event == "ADDON_LOADED" then
		if initialized then
			CreateMapButton()
			HookWorldMapPositioning()
			PositionMapButton()
		end
		return
	end

	GM = _G.GatherMate2
	if not GM or not GM.db then return end

	GatherMate2NodeFiltersDB = GatherMate2NodeFiltersDB or {}
	db = GatherMate2NodeFiltersDB
	CopyDefaults(db, DEFAULTS)
	db.currentMapOnly = true
	db.enabledTypesOnly = true
	LibDD = LibStub and LibStub("LibUIDropDownMenu-4.0", true)
	ApplyDefaultUncheckedFilters()

	for _, nodeTypeInfo in ipairs(NODE_TYPES) do
		GetFilterDB(nodeTypeInfo.key)
	end

	initialized = true
	CreateMapButton()
	HookWorldMapPositioning()
	RegisterGatherMateConfigModule()
end)
