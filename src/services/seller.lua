local Addon = select(2, ...) ---@type Addon
local B = Addon:GetModule("Blizzard")
local E = Addon:GetModule("Events")
local EventManager = Addon:GetModule("EventManager")
local GetCoinTextureString = C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString or GetCoinTextureString
local Items = Addon:GetModule("Items")
local JunkFilter = Addon:GetModule("JunkFilter")
local L = Addon:GetModule("Locale")
local StateManager = Addon:GetModule("StateManager")
local TickerManager = Addon:GetModule("TickerManager")

--- @class Seller
local Seller = Addon:GetModule("Seller")

local EMPTY_SCAN_LIMIT = 5
local sellableItems = {}

-- ============================================================================
-- Events
-- ============================================================================

EventManager:On(E.Wow.MerchantShow, function()
  TickerManager:After(0.1, function()
    local profileSettings = StateManager:GetProfileState().settings

    -- Auto repair.
    if profileSettings.autoRepair then
      local repairCost, canRepair = GetRepairAllCost()
      if canRepair and GetMoney() >= repairCost then
        RepairAllItems()
        PlaySound(SOUNDKIT.ITEM_REPAIR)
        Addon:Print(L.REPAIRED_ALL_ITEMS:format(GetCoinTextureString(repairCost)))
      end
    end

    -- Auto sell.
    if profileSettings.autoSell then
      Seller:Start(true)
    end
  end)
end)

EventManager:On(E.Wow.MerchantClosed, function()
  Seller:Stop()
end)

EventManager:On(E.Wow.UIErrorMessage, function(_, msg)
  if msg == B.Strings.VENDOR_DOESNT_BUY_ERROR_TEXT then
    Seller:Stop()
  end
end)

-- ============================================================================
-- Local Functions
-- ============================================================================

local function handlePopup(popup)
  if popup and popup:IsShown() and popup.which == "CONFIRM_MERCHANT_TRADE_TIMER_REMOVAL" then
    local button = popup.GetButton1 and popup:GetButton1() or popup.button1
    button:Click()
  end
end

local function handleStaticPopup()
  if (Addon.IS_VANILLA or Addon.IS_TBC) then return end

  if type(StaticPopup_ForEachShownDialog) == "function" then
    StaticPopup_ForEachShownDialog(handlePopup)
  else
    for i = 1, STATICPOPUP_NUMDIALOGS do
      local popup = _G["StaticPopup" .. i]
      handlePopup(popup)
    end
  end
end

local function handleItem(item)
  if not Items:IsItemStillInBags(item) then return false end
  if Items:IsItemLocked(item) then return false end

  C_Container.UseContainerItem(item.bag, item.slot)
  handleStaticPopup()

  EventManager:Fire(E.AttemptedToSellItem, item)
  return true
end

local function tickerCallback()
  -- Rebuild the list from the current bag cache on every tick. Items may appear
  -- after MERCHANT_SHOW while bags are still updating, and cached entries may
  -- become stale as items are sold.
  local items = JunkFilter:GetSellableJunkItems(sellableItems)

  if #items == 0 then
    Seller.emptyScans = Seller.emptyScans + 1
    if Seller.emptyScans >= EMPTY_SCAN_LIMIT then Seller:Stop() end
    return
  end

  Seller.emptyScans = 0

  -- Normal selling continues with the highest-value item. Safe Sell keeps the
  -- original lowest-value-first behavior.
  local item = Seller.safeSellRemaining and items[1] or items[#items]
  if not handleItem(item) then return end

  if Seller.safeSellRemaining then
    Seller.safeSellRemaining = Seller.safeSellRemaining - 1
    if Seller.safeSellRemaining <= 0 then Seller:Stop() end
  end
end

-- ============================================================================
-- Seller
-- ============================================================================

function Seller:Start(auto)
  -- Don't start if busy.
  if Addon:IsBusy() then return end
  -- Don't start without merchant.
  if not Addon:IsAtMerchant() then
    return Addon:Print(L.CANNOT_SELL_WITHOUT_MERCHANT)
  end

  -- Get filtered items.
  local items = JunkFilter:GetSellableJunkItems()

  -- Return if no items.
  if #items == 0 then
    if not auto then Addon:Print(L.NO_JUNK_ITEMS_TO_SELL) end
    return
  end

  -- Safe sell. A missing value means there is no per-run limit.
  self.safeSellRemaining = nil
  if StateManager:GetGlobalState().safeSell then
    self.safeSellRemaining = math.min(#items, 12)
  end

  -- Wait through several empty scans before stopping. This allows delayed BAG_UPDATE
  -- events and Dejunk's debounced cache refresh to catch up.
  self.emptyScans = 0

  -- Start ticker.
  self.ticker = TickerManager:NewTicker(Addon:GetLatency(), tickerCallback)
  EventManager:Fire(E.SellerStarted)
end

function Seller:Stop()
  if self:IsBusy() then
    self.ticker:Cancel()
    EventManager:Fire(E.SellerStopped)
  end
end

function Seller:HandleItem(item)
  if Addon:IsBusy() then return false end

  if not Addon:IsAtMerchant() then
    Addon:Print(L.CANNOT_SELL_WITHOUT_MERCHANT)
    return false
  end

  return handleItem(item)
end

function Seller:IsBusy()
  return self.ticker and not self.ticker:IsCancelled()
end
