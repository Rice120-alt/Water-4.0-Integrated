namespace FWQuestOverlay;

internal static class WaterBrokerContentSelfTest
{
    private const string ItemKey =
        "/Game/Blueprints/Data/ItemDetailsData.ItemDetailsData:RareLoot_133_PowerCell";

    private static string Payload(int quantity = 1, int price = 2, int maxUnits = 99,
        int grantLimit = 999, int waterLimit = 1_000_000)
    {
        return string.Join("\n", new[]
        {
            "format=fwif.water_vendor.overlay.v2", "revision=7", "session_id=content-session",
            "vendor_id=independent_water_vendor", "vendor_title=Water%20Broker",
            "hub_available=1", "command_enabled=1", "water_known=1", "water_balance=1000000",
            "rotation_index=10", "stock_band_id=abundant", "weapons_allowed=1",
            "special_items_allowed=1", "weapon_unlock_water=0", "special_item_unlock_water=0",
            "refresh_deadline=2000000000", "storefront_status=available", "blocking_reason=none",
            "transaction_id=", "transaction_status=none", "last_result_code=", "last_result_message=",
            "offer_count=1", "selected_offer_index=1", "selected_offer_id=player_power_cell",
            "offer_1_id=player_power_cell", "offer_1_display_name=My%20Power%20Cell",
            "offer_1_category=resource", "offer_1_inventory_kind=item",
            $"offer_1_unit_water_cost={price}", $"offer_1_grant_quantity_per_unit={quantity}",
            $"offer_1_max_purchase_units={maxUnits}", "offer_1_initial_stock=999", "offer_1_remaining=999",
            "offer_1_purchase_ready=1", "offer_1_purchase_block_reason=none",
            "offer_1_fulfillment_evidence=HYPOTHESIS", "offer_1_quote_fingerprint=fixture-route-quote",
            $"offer_1_item_key={ItemKey}", "offer_1_icon_key=power_cell",
            "offer_1_route_id=broker:power_cell:v1", $"offer_1_max_grant_quantity={grantLimit}",
            $"offer_1_max_total_water_cost={waterLimit}", "last_reason=test", "complete=1", ""
        });
    }

    private static WaterVendorSnapshot Parse(string payload)
    {
        if (!WaterVendorSnapshot.TryParse(payload, out var snapshot))
            throw new InvalidOperationException("broker_content_valid_snapshot_rejected");
        return snapshot;
    }

    private static void Reject(string payload)
    {
        if (WaterVendorSnapshot.TryParse(payload, out _))
            throw new InvalidOperationException("broker_content_invalid_snapshot_accepted");
    }

    public static void Run()
    {
        var payload = Payload();
        var snapshot = Parse(payload);
        if (snapshot.Selected.Id != "player_power_cell" || snapshot.Selected.IconKey != "power_cell" ||
            snapshot.Selected.ItemKey != ItemKey || snapshot.Selected.RouteId != "broker:power_cell:v1" ||
            WaterBrokerOfferIcons.Resolve(snapshot.Selected.IconKey) is null ||
            WaterBrokerOfferIcons.Resolve(snapshot.Selected.Id) is not null ||
            !ReferenceEquals(WaterBrokerOfferIcons.Resolve(snapshot.Selected.IconKey),
                WaterBrokerOfferIcons.Resolve("power_cell")))
            throw new InvalidOperationException("broker_content_offer_identity_controls_portrait");

        foreach (var key in new[] { "high_frequency_radio", "cyborg_immunosuppressant", "weapon_gm6" })
            if (WaterBrokerOfferIcons.Resolve(key) is null)
                throw new InvalidOperationException("broker_content_missing_registered_portrait:" + key);

        var bundle = Parse(Payload(quantity: 999, maxUnits: 1));
        if (bundle.MaximumPurchaseUnits() != 1 || !bundle.CanPurchaseSelected(1, out _) ||
            bundle.CanPurchaseSelected(2, out _))
            throw new InvalidOperationException("broker_content_999_bundle_cap_failed");
        var confirmationRejected = false;
        try { WaterPurchaseConfirmation.Create(bundle, 2); }
        catch (ArgumentOutOfRangeException) { confirmationRejected = true; }
        if (!confirmationRejected)
            throw new InvalidOperationException("broker_content_confirmation_exceeded_route_cap");
        var boundedItems = Parse(Payload(quantity: 3, maxUnits: 6, grantLimit: 20));
        var boundedPrice = Parse(Payload(price: 250001, maxUnits: 3));
        var boundedRoutePrice = Parse(Payload(price: 3, maxUnits: 3, waterLimit: 10));
        if (boundedItems.MaximumPurchaseUnits() != 6 || boundedPrice.MaximumPurchaseUnits() != 3 ||
            boundedRoutePrice.MaximumPurchaseUnits() != 3 || boundedPrice.CanPurchaseSelected(4, out _) ||
            boundedItems.CanPurchaseSelected(7, out _) || boundedRoutePrice.CanPurchaseSelected(4, out _))
            throw new InvalidOperationException("broker_content_route_or_water_cap_failed");

        var lowWater = snapshot with { WaterBalance = 5 };
        var lowStock = snapshot with { Offers = new[] { snapshot.Selected with { Remaining = 1 } } };
        if (lowWater.MaximumPurchaseUnits() != 2 || lowStock.MaximumPurchaseUnits() != 1)
            throw new InvalidOperationException("broker_content_stock_or_affordability_cap_failed");

        Reject(Payload(quantity: 999, maxUnits: 2));
        Reject(Payload(price: 250001, maxUnits: 4));
        Reject(Payload(quantity: 21, maxUnits: 1, grantLimit: 20));
        Reject(Payload(grantLimit: 1000));
        Reject(payload.Replace("offer_1_icon_key=power_cell", "offer_1_icon_key=../power_cell.png"));
        Reject(payload.Replace("offer_1_icon_key=power_cell", "offer_1_icon_key=https://example.invalid/icon.png"));
        Reject(payload.Replace("offer_1_icon_key=power_cell", "offer_1_icon_key=unregistered"));
        Reject(payload.Replace($"offer_1_item_key={ItemKey}", "offer_1_item_key=RareLoot_133_PowerCell"));
        Reject(payload.Replace("offer_1_route_id=broker:power_cell:v1\n", ""));
        Reject(payload.Replace("format=fwif.water_vendor.overlay.v2", "format=fwif.water_vendor.overlay.v3"));

        var legacy = string.Join("\n", payload.Split('\n').Where(line =>
            !line.StartsWith("offer_1_item_key=") && !line.StartsWith("offer_1_icon_key=") &&
            !line.StartsWith("offer_1_route_id=") && !line.StartsWith("offer_1_max_grant_quantity=") &&
            !line.StartsWith("offer_1_max_total_water_cost=")))
            .Replace("format=fwif.water_vendor.overlay.v2", "format=fwif.water_vendor.overlay.v1")
            .Replace("player_power_cell", "power_cell");
        if (Parse(legacy).Selected.IconKey != "power_cell")
            throw new InvalidOperationException("broker_content_legacy_portrait_compatibility_failed");
        var legacyUnsafeCap = Parse(legacy.Replace("offer_1_grant_quantity_per_unit=1\n",
            "offer_1_grant_quantity_per_unit=999\n"));
        if (legacyUnsafeCap.MaximumPurchaseUnits() != 1 || legacyUnsafeCap.CanPurchaseSelected(2, out _))
            throw new InvalidOperationException("broker_content_legacy_route_cap_failed");

        // Optional fixture is generated by the real Lua publisher in the
        // cross-language test. This branch runs only under --self-test.
        var fixturePath = Environment.GetEnvironmentVariable("FW_BROKER_WIRE_FIXTURE");
        var commandPath = Environment.GetEnvironmentVariable("FW_BROKER_WIRE_COMMAND");
        if (!string.IsNullOrEmpty(fixturePath) || !string.IsNullOrEmpty(commandPath))
        {
            if (string.IsNullOrEmpty(fixturePath) || string.IsNullOrEmpty(commandPath))
                throw new InvalidOperationException("broker_content_roundtrip_paths_missing");
            var fixture = Parse(File.ReadAllText(fixturePath));
            if (!fixture.CanPurchaseSelected(fixture.MaximumPurchaseUnits(), out _))
                throw new InvalidOperationException("broker_content_roundtrip_not_purchasable");
            var quote = WaterPurchaseConfirmation.Create(fixture, fixture.MaximumPurchaseUnits());
            if (!fixture.Matches(quote) || !WaterVendorCommandFile.TryWrite(commandPath,
                    fixture.SessionId, 1, "purchase", quote, out _))
                throw new InvalidOperationException("broker_content_roundtrip_command_failed");
            Console.WriteLine("WATER_BROKER_LUA_WIRE_ROUNDTRIP_OK explicit_icon_key=" + fixture.Selected.IconKey);
        }

        Console.WriteLine("WATER_BROKER_CONTENT_SELF_TEST_OK snapshot_v2=true legacy_v1=true explicit_icon_key=true embedded_icons=55 route_caps=true");
    }
}
