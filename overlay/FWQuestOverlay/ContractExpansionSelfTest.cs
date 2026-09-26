namespace FWQuestOverlay;

internal static class ContractExpansionSelfTest
{
    public static void Run()
    {
        foreach (var surface in new[] { HubSurface.Contracts, HubSurface.WaterTrader })
        {
            if (!HubActionInputPolicy.CanCloseEscape(surface,surface,true,3,3) ||
                HubActionInputPolicy.CanCloseEscape(surface,surface,true,4,3) ||
                HubActionInputPolicy.CanCloseEscape(surface,surface,false,3,3) ||
                HubActionInputPolicy.CanCloseEscape(HubSurface.None,surface,true,3,3))
                throw new Exception("surface_escape_lifetime");
        }
        if (HubActionInputPolicy.CanCloseEscape(HubSurface.Contracts,HubSurface.WaterTrader,true,3,3))
            throw new Exception("escape_cross_surface");
        if (!ContractBoardInputPolicy.CanWrite(false,true,false,"session",true) ||
            !ContractBoardInputPolicy.CanWrite(false,false,true,"session",false) ||
            ContractBoardInputPolicy.CanWrite(false,false,false,"session",true) ||
            ContractBoardInputPolicy.CanWrite(false,true,true,"session",true) ||
            ContractBoardInputPolicy.CanWrite(true,true,false,"session",true) ||
            ContractBoardInputPolicy.CanWrite(false,true,false,"",false))
            throw new Exception("board_input_lifecycle");
        // Space/Ctrl/C/Escape must be consumed; unrelated foreground windows
        // and menu shortcuts F7/F8/F9/F10 must retain their normal routing.
        foreach (uint key in new uint[] {0x20,0x11,0xA2,0xA3,0x43,0x1B})
            if (!HubActionInputPolicy.ShouldSuppress(key)) throw new Exception("action_key_leak");
        foreach (uint key in new uint[] {0x76,0x77,0x78,0x79})
            if (HubActionInputPolicy.ShouldSuppress(key)) throw new Exception("menu_shortcut_blocked");
        if (HubActionInputPolicy.IsForegroundInScope(new IntPtr(9),new IntPtr(1),new IntPtr(2)))
            throw new Exception("foreign_window_input_blocked");
        var old = QuestSnapshot.Preview();
        var contracts = old.Contracts.ToList();
        var exemplar = old.Contracts[0];
        contracts.Add(exemplar with { Id = "heavy_metal", Title = "Heavy Metal" });
        var four = new[] {
            new ContractObjective("medicine", "ASSORTED MEDICINE", 3, 3),
            new ContractObjective("blood", "BLOOD PACKS", 2, 2),
            new ContractObjective("cigarettes", "HINOKO CIGARETTES", 2, 2),
            new ContractObjective("medical", "MEDICAL SUPPLIES (ANY MIX)", 7, 8)
        };
        contracts.Add(exemplar with { Id = "last_relief_clinic", Title = "The Last Relief Clinic", ObjectiveList = four });
        contracts.Add(exemplar with { Id = "keep_the_lights_on", Title = "Keep the Lights On", ObjectiveList = four });
        var board = old with { Contracts = contracts };
        var raid = board with { RaidInProgress = true, HubAvailable = false,
            Contracts = contracts.Select(c => c with { Status = "active", Accepted = true }).ToArray() };
        foreach (var size in new[] { new Size(1280,720), new Size(1920,1080), new Size(2560,1440),
            new Size(3440,1440), new Size(3840,2160), new Size(5120,1440) })
        {
            var list = ContractBoardLayout.ListBounds(size);
            Rectangle previous = Rectangle.Empty;
            for (var i = 0; i < 6; i++)
            {
                var card = ContractBoardLayout.ContractCard(size, i, 6);
                if (!list.Contains(card) || previous.IntersectsWith(card)) throw new Exception("six_card_bounds");
                previous = card;
                if (OverlayHitTesting.HitTest(OverlayMode.ContractBoard, size,
                    new Point(card.Left+3,card.Top+3), board, WaterVendorSnapshot.Waiting(), null, false)
                    != OverlayHitTarget.ContractAt(i)) throw new Exception("six_card_hit_test");
            }
            var placement = QuestPanelLayout.Place(new Rectangle(Point.Empty,size),raid);
            if (!new Rectangle(Point.Empty,size).Contains(placement.Bounds)) throw new Exception("six_tracker_overflow");
            var expectedHeight = raid.VisibleRaidContracts.Sum(QuestPanelLayout.ContractHeight) +
                QuestPanelLayout.RaidPanelGap * 5 + 16;
            if (QuestPanelLayout.WindowSize(raid).Height != expectedHeight) throw new Exception("four_objective_height");
        }
        var payload = "format=fwif.contracts.overlay.v1\nrevision=1\ncontract_count=1\n" +
            "contract_1_id=clinic\ncontract_1_objective_count=4\ncomplete=1\n";
        for (var i=1;i<=4;i++) payload += $"contract_1_objective_{i}_id=o{i}\n" +
            $"contract_1_objective_{i}_label=SUPPLY {i}\ncontract_1_objective_{i}_current=0\ncontract_1_objective_{i}_target=2\n";
        if (!QuestSnapshot.TryParse(payload,out var parsed) || parsed.Selected.Objectives.Count!=4)
            throw new Exception("four_objective_parse");
        if (QuestSnapshot.TryParse(payload.Replace("contract_1_objective_4_target=2\n",""),out _))
            throw new Exception("partial_objective_accepted");
        if (QuestSnapshot.TryParse(payload.Replace("contract_1_objective_4_current=0","contract_1_objective_4_current=3"),out _))
            throw new Exception("invalid_objective_accepted");

        using var bitmap = new Bitmap(420, 100);
        using var graphics = Graphics.FromImage(bitmap);
        using var fittedTitle = QuestPanelRenderer.TitleFont(
            graphics, "INTELLIGENCE RECONNAISSANCE", 350);
        if (graphics.MeasureString("INTELLIGENCE RECONNAISSANCE", fittedTitle).Width > 351)
            throw new Exception("long_contract_title_overflow");
        using var shortTitle = QuestPanelRenderer.TitleFont(graphics, "HEAVY METAL", 350);
        if (shortTitle.Size < 19.4f)
            throw new Exception("short_contract_title_unnecessarily_reduced");
    }
}
