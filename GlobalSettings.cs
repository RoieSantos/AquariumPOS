using System;
using System.Drawing;

namespace AquariumPOS
{
    /// <summary>
    /// Global settings and configuration for the AquariumPOS application
    /// </summary>
    public static class GlobalSettings
    {
        /// <summary>
        /// Database connection string for the application
        /// </summary>
        public static string ConnectionString { get; } =
        //"Server=DESKTOP-7708OTB;Database=RSPETSTOP;Trusted_Connection=True;Connection Timeout=30;";
        //"Server=DESKTOP-7708OTB;Database=RSPETSTOP_TEST;Trusted_Connection=True;Connection Timeout=30;";
        //"Server=DESKTOP-16K2CUK;Database=RSPETSTOP;Trusted_Connection=True;Connection Timeout=30;";
        //Testing Server
        
        //LOCAL
        "Server=LAPTOP-20MJVLDK;Database=RSPETSTOPQ12026updated;Trusted_Connection=True;Connection Timeout=30;";
        //GRACE
        //"Server=DESKTOP-E6ELCK2;Database=RSPETSTOP;Trusted_Connection=True;Connection Timeout=30;";
        
        
        
        //"Server=LAPTOP-20MJVLDK;Database=RSPETSTOPJan22;Trusted_Connection=True;Connection Timeout=30;";
        //"Server=LAPTOP-20MJVLDK;Database=RSPETSTOP;Trusted_Connection=True;Connection Timeout=30;";
        //GMA SERVER
        //"Server=DESKTOP-FVL15KG;Database=RSPETSTOP;Trusted_Connection=True;Connection Timeout=30;";
        /// <summary>
        /// Default store number
        /// </summary>
        public static string DefaultStoreNo { get; } = "001";

        /// <summary>
        /// Default POS terminal number
        /// </summary>
        public static string DefaultPosTerminalNo { get; } = "001";

        /// <summary>
        /// Application name
        /// </summary>
        public static string ApplicationName { get; } = "RS PET STOP - AquariumPOS";

        /// <summary>
        /// Company information for receipts
        /// </summary>
        public static string CompanyName { get; } = "RS PET STOP";
        public static string CompanyTagline { get; } = "AQUARIUM PRODUCTS & SOLUTIONS";

        /// <summary>
        /// Receipt printing settings - 58mm thermal printer
        /// </summary>
        public static int ReceiptWidth { get; } = 32; // Characters for 58mm paper
        public static string ReceiptFont { get; } = "Courier New";
        public static int ReceiptFontSize { get; } = 8;

        /// <summary>
        /// Whether printed output should use bold font. Toggle to false to print regular weight.
        /// </summary>
        public static bool PrintBold { get; } = true;

        /// <summary>
        /// Helper to provide the FontStyle used for receipt/print fonts based on configuration.
        /// </summary>
        public static FontStyle ReceiptFontStyle => PrintBold ? FontStyle.Bold : FontStyle.Regular;

        /// <summary>
        /// Paper size settings for 58mm thermal printer
        /// </summary>
        public static float PaperWidthInches { get; } = 2.23f; // 58mm = 2.28 inches
        public static float PaperHeightInches { get; } = 11.0f; // Standard height
        public static float LeftMarginInches { get; } = 0.0f;
        public static float TopMarginInches { get; } = 0.1f;

        /// <summary>
        /// Optional: explicit POS printer name to target for direct printing. If empty, the app
        /// will try to heuristically find a POS58-like printer from installed printers.
        /// </summary>
        public static string PosPrinterName { get; } = string.Empty;

        /// <summary>
        /// Pricing for custom stickers (per square inch) - reads OnlinefunctionsEvents.PricingCache
        /// (Supabase-synced, see supabase_pricing_setup_tables.sql / SyncPricingFromSupabaseAsync),
        /// which is itself pre-populated with these same values so a terminal that's never
        /// successfully synced still prices correctly. Portal's Pricing Setup page is where these
        /// should actually be edited now, not here.
        /// </summary>
        public static decimal pricePerSqInchPlain => OnlinefunctionsEvents.PricingCache.PlainStickerPricePerSqFt;
        public static decimal pricePerSqInchTiles => OnlinefunctionsEvents.PricingCache.TilesStickerPricePerSqFt;
        /// <summary>
        /// Pricing for rubber matting stickers (per square inch) - base/fallback rate, used when
        /// thickness is unknown/blank. Per-thickness tiers live in GetRubberPricePerSqInch below.
        /// </summary>
        public static decimal pricePerSqInchRubberMatting => OnlinefunctionsEvents.PricingCache.RubberMattingBasePricePerSqFt;

        /// <summary>
        /// Pricing for glass stickers (per square inch) - base/fallback ONLY, used when thickness
        /// doesn't match one of the known tiers below at all (malformed input) - not itself synced,
        /// since GlassPricingSetup has no "unknown thickness" row of its own.
        /// </summary>
        public static decimal pricePerSqInchGlass { get; } = 120m; // P120.00 per sq inch for Glass stickers
                                                                   // Pricing for Acrylic stickers (per square foot)
        public static decimal pricePerSqInchAcrylicHighStrip => OnlinefunctionsEvents.PricingCache.AcrylicPricePerSqFt;

        /// <summary>
        /// Return a price per square inch for Rubber Matting based on thickness (3mm/6mm/10mm/12mm).
        /// If thickness is unknown or empty, returns the base <see cref="pricePerSqInchRubberMatting"/>.
        /// </summary>
        public static decimal GetRubberPricePerSqInch(string thickness)
        {
            if (string.IsNullOrWhiteSpace(thickness)) return pricePerSqInchRubberMatting;
            var key = thickness.Trim().ToLowerInvariant();
            if (OnlinefunctionsEvents.PricingCache.RubberMattingPricePerSqFt.TryGetValue(key, out var cached)) return cached;
            return key switch
            {
                "3mm" => 26m,
                "6mm" => 32m,
                "10mm" => 45m,
                "12mm" => 60m,
                _ => pricePerSqInchRubberMatting
            };
        }

        /// <summary>
        /// Return a price per square inch for Glass based on thickness (3mm/6mm/10mm/12mm/18mm).
        /// If thickness is unknown or empty, returns the base <see cref="pricePerSqInchGlass"/>.
        /// </summary>
        public static decimal GetGlassPricePerSqInch(string thickness)
        {
            if (string.IsNullOrWhiteSpace(thickness)) return pricePerSqInchGlass;
            var key = thickness.Trim().ToLowerInvariant();
            if (OnlinefunctionsEvents.PricingCache.GlassPricePerSqFt.TryGetValue(key, out var cached)) return cached;
            return key switch
            {
                "3mm" => 85m,
                "6mm" => 185m,
                "10mm" => 290m,
                "12mm" => 350m,
                _ => pricePerSqInchGlass
            };
        }

        // Online Orders API configuration
        public static string OnlineOrdersApiBaseUrl { get; } = "https://pos.pages.fm/api/v1";
        public static string OnlineOrdersApiKey { get; } = "e611861d2fc84607bfbbe1428a432447";
        public static string OnlineOrdersShopId { get; } = "1328301944";

        // Public API configuration (user-provided)
        public static string PublicURL { get; } = "https://pages.fm/api/public_api/v1";
        public static string PublicApiKey { get; } = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpZCI6IjE5NTcxNjY0NDQxMDgyOSIsInRpbWVzdGFtcCI6MTc2MDc4NzE3NX0.AsYdKZrGA1F4_Pln6wlz_eS-EmGWG9RythyjTDWEEq8";

        // Transfer Header Supabase configuration
        public static string TransferHeaderSupabaseEndpoint { get; } = "https://hymcmesqgpliyyeghpgq.supabase.co/rest/v1/Transfer_Header";
        public static string TransferLineSupabaseEndpoint { get; } = "https://hymcmesqgpliyyeghpgq.supabase.co/rest/v1/Transfer_Line";
        public static string ItemSerialTrackingSupabaseEndpoint { get; } = "https://hymcmesqgpliyyeghpgq.supabase.co/rest/v1/ItemSerialTracking";
        public static string MonthEndHeaderSupabaseEndpoint { get; } = "https://hymcmesqgpliyyeghpgq.supabase.co/rest/v1/MonthEndHeader";
        public static string MonthEndLinesSupabaseEndpoint { get; } = "https://hymcmesqgpliyyeghpgq.supabase.co/rest/v1/MonthEndLines";
        public static string ExpenseReportHeaderSupabaseEndpoint { get; } = "https://hymcmesqgpliyyeghpgq.supabase.co/rest/v1/ExpenseReportHeader";
        public static string ExpenseReportLinesSupabaseEndpoint { get; } = "https://hymcmesqgpliyyeghpgq.supabase.co/rest/v1/ExpenseReportLines";
        // Individual posted Expense Entries (MainForm.PostPendingExpenses) - distinct from the
        // aggregated Expense Report endpoints above. See supabase_expense_entry_tables.sql.
        public static string ExpenseEntryHeaderSupabaseEndpoint { get; } = "https://hymcmesqgpliyyeghpgq.supabase.co/rest/v1/ExpenseEntryHeader";
        public static string ExpenseEntryLinesSupabaseEndpoint { get; } = "https://hymcmesqgpliyyeghpgq.supabase.co/rest/v1/ExpenseEntryLines";
        // Master data (Warehouses/Items) - synced one-way, desktop -> Supabase, via the same
        // secret-key POST/PATCH-if-exists pattern as the other endpoints above. Not exposed to
        // the Web Portal's anon key (see supabase_warehouses_items_tables.sql).
        public static string WarehousesSupabaseEndpoint { get; } = "https://hymcmesqgpliyyeghpgq.supabase.co/rest/v1/Warehouses";
        public static string ItemsSupabaseEndpoint { get; } = "https://hymcmesqgpliyyeghpgq.supabase.co/rest/v1/Items";
        // Online Orders / Advance Orders - synced one-way, desktop -> Supabase, same pattern as
        // Warehouses/Items above. Not exposed to the Web Portal's anon key directly - only via the
        // admin_list_* RPCs in supabase_orders_sync_tables.sql (customer PII, super users only).
        public static string OnlineOrdersSupabaseEndpoint { get; } = "https://hymcmesqgpliyyeghpgq.supabase.co/rest/v1/OnlineOrders";
        public static string OnlineOrderLinesSupabaseEndpoint { get; } = "https://hymcmesqgpliyyeghpgq.supabase.co/rest/v1/OnlineOrderLines";
        public static string AdvanceOrdersSupabaseEndpoint { get; } = "https://hymcmesqgpliyyeghpgq.supabase.co/rest/v1/AdvanceOrders";
        public static string AdvanceOrderLinesSupabaseEndpoint { get; } = "https://hymcmesqgpliyyeghpgq.supabase.co/rest/v1/AdvanceOrderLines";
        // Online Customers (Pancake customer/PSID records, mirrored from dbo.OnlineCustomers - see
        // OnlinefunctionsEvents.SyncCustomersAsync/SyncCustomersToSupabaseAsync) - same one-way
        // desktop -> Supabase pattern as everything else on this page. Not exposed to the Web
        // Portal's anon key (see supabase_online_customers_table.sql) - customer PII/PSIDs, staff
        // only, once a staff-facing lookup RPC is added.
        public static string OnlineCustomersSupabaseEndpoint { get; } = "https://hymcmesqgpliyyeghpgq.supabase.co/rest/v1/OnlineCustomers";
        public static string TransferHeaderSupabaseApiKey { get; } = "sb_publishable_QWDFggQ9ce9zm65xFEzmHA_rGaOUFQz";
        // Supabase SECRET key (bypasses Row Level Security - used for privileged desktop -> Supabase
        // REST calls). Deliberately NOT a literal here - GitHub's push protection blocks any commit
        // containing a live Supabase secret key, and a hardcoded value would just get re-leaked the
        // next time this file changes. Set via a Windows environment variable instead (System
        // Properties -> Environment Variables, on every machine running this app):
        //   AQUARIUMPOS_SUPABASE_SERVICE_ROLE_KEY = <the current secret key from the Supabase dashboard>
        public static string TransferHeaderSupabaseAuthorization { get; } =
            Environment.GetEnvironmentVariable("AQUARIUMPOS_SUPABASE_SERVICE_ROLE_KEY") ?? string.Empty;
        // Categories - pulled the OPPOSITE direction from everything else on this page (Supabase ->
        // desktop, not desktop -> Supabase). The Web Portal's Category Setup screen is the only place
        // staff can toggle "Production Category"/"Exclude In Transfer Orders" (writes to Supabase
        // public."Categories" via admin_update_category_flags); local dbo.Category otherwise only ever
        // gets Code/Description from the Pancake sync (see OnlinefunctionsEvents.SyncCategoriesAsync)
        // and never learns about those two portal-only flags on its own. See
        // OnlinefunctionsEvents.SyncCategoryProductionFlagsFromSupabaseAsync.
        public static string CategoriesSupabaseEndpoint { get; } = "https://hymcmesqgpliyyeghpgq.supabase.co/rest/v1/Categories";

        // Centralized Glass/Stand-Tubular/Sticker pricing (see supabase_pricing_setup_tables.sql) -
        // Supabase -> desktop only, same direction as Categories above. The Web Portal's Pricing
        // Setup page is the only place staff should edit these now; OnlinefunctionsEvents.
        // SyncPricingFromSupabaseAsync (called from MasterDataSyncTimer_Tick) pulls them down into
        // OnlinefunctionsEvents.PricingCache / the local GlassPricingSetup table. These are plain
        // read-only RPCs granted to anon (just prices, no auth needed), called with the same
        // publishable apikey used everywhere else on this page.
        public static string GlassPricingRpcEndpoint { get; } = "https://hymcmesqgpliyyeghpgq.supabase.co/rest/v1/rpc/public_get_glass_pricing";
        public static string TubularPricingRpcEndpoint { get; } = "https://hymcmesqgpliyyeghpgq.supabase.co/rest/v1/rpc/public_get_tubular_pricing";
        public static string StickerPricingRpcEndpoint { get; } = "https://hymcmesqgpliyyeghpgq.supabase.co/rest/v1/rpc/public_get_sticker_pricing";

        /// <summary>
        /// Optional: Page ID and Conversation IDs to receive admin notifications via the Public API.
        /// If not configured (empty array or empty strings), admin notifications will be skipped.
        /// The Page ID is typically the same for all admin conversations; Conversation IDs can contain one or more targets.
        /// </summary>
        public static string AdminPageId { get; } = "195716644410829";
        public static string[] AdminConversationIds { get; } = new string[] {
            // Primary admin (Danilo)
            "195716644410829_25790301300559447",
            // Uncomment or add additional conversation IDs as needed:
             "195716644410829_10033055390104832", // Randy
             "195716644410829_24463219006608308", // Alfred
        };


        public static string ReceivedMessage { get; } =
                                "🎉 Hi {Customer Name}! Your order {Order ID} has been marked as received at RSPETSTOP {location}.\n" +
                                    "You can now proceed with the next steps.\n" +

                                    "{Payment}\n" +
                                    "\n" +
                                    "🧾 Heres what youll be receiving:\n" +
                                    "\n" +
                                    " {Items}\n" +
                                    "\n" +
                                    "\n" +
                                    "Swing by anytime during our store hours—your fish joy is just one finstep away! 🐠🦈\n" +
                                    "📍 Location: Amaya Dos Antero Soriano Highway Tanza Cavite or just Pin : RSPetStop Amaya \n" +
                                    "🕒 Hours: 8:00 am to 8:00 pm monday to sunday\n" +
                                    "For GMA Location, You can pickup your order on the next Delivery schedule. You can coordinate with us with this. Happy fish keeping. \n" +
                                    "You may call +63 997 189 1662 (GMA Branch) for any questions or assistance. We look forward to seeing you soon! 🐟❤️ \n" +

                                    "We can also help you book a lalamove delivery partner\n" +
                                    "📦 Kindly send the following details\n" +
                                    "\n" +
                                    "• Full Name:\n" +
                                    "• Contact Number:\n" +
                                    "• Complete Address:\n" +
                                    "• Pin Location (Google Maps link or screenshot):\n" +
                                    "💬 Once received, well confirm your order and send the final details right away. Thank you\n" +
                                    "Thank you for choosing RSPetStop—We appreciate you always! and see you soon ❤️";


        public static string InTransitMessage { get; } =
                        "🎉 Hi {Customer Name}! Your order {Order ID} is on its way to RSPETSTOP {location}.\n" +
                            "We’ll notify you once it’s ready for pickup at the branch.\n" +

                            "{Payment}\n" +
                            "\n" +
                            "🧾 Heres what youll be receiving:\n" +
                            "\n" +
                            " {Items}\n" +
                            "\n" +
                            "\n" +
                            "Swing by anytime during our store hours—your fish joy is just one finstep away! 🐠🦈\n" +
                            "📍 Location: Amaya Dos Antero Soriano Highway Tanza Cavite or just Pin : RSPetStop Amaya \n" +
                            "🕒 Hours: 8:00 am to 8:00 pm monday to sunday\n" +
                            "For GMA Location, You can pickup your order on the next Delivery schedule. You can coordinate with us with this. Happy fish keeping. \n" +
                            "You may call +63 997 189 1662 (GMA Branch) for any questions or assistance. We look forward to seeing you soon! 🐟❤️ \n" +

                            "We can also help you book a lalamove delivery partner\n" +
                            "📦 Kindly send the following details\n" +
                            "\n" +
                            "• Full Name:\n" +
                            "• Contact Number:\n" +
                            "• Complete Address:\n" +
                            "• Pin Location (Google Maps link or screenshot):\n" +
                            "💬 Once received, well confirm your order and send the final details right away. Thank you\n" +
                            "Thank you for choosing RSPetStop—We appreciate you always! and see you soon ❤️";


        public static string ScheduledTransferReadyMessage { get; } =
                "🎉 Hi {Customer Name}! Your order {Order ID} is now finished and will be transferred to RSPETSTOP {location} location on our next delivery schedule.\n" +
                    "We’ll notify you once it’s ready for pickup at the branch.\n" +

                    "{Payment}\n" +
                    "\n" +
                    "🧾 Heres what youll be receiving:\n" +
                    "\n" +
                    " {Items}\n" +
                    "\n" +
                    "\n" +
                    "Swing by anytime during our store hours—your fish joy is just one finstep away! 🐠🦈\n" +
                    "📍Location: Amaya Dos Antero Soriano Highway Tanza Cavite or just Pin : RSPetStop Amaya \n" +
                    "📍Location:  Blk 2 Lot 53 Brgy. Granados, Gen. Mariano Alvarez, Cavite or Just Pin : RSPetStop GMA \n" +
                    "🕒 Hours: 8:00 am to 8:00 pm monday to sunday\n" +
                    " You can pickup your order on the next Delivery schedule. You can coordinate with us with this. Happy fish keeping. \n" +
                    " You may call +63 997 189 1662 (GMA Branch) +63 945 518 4066 (Amaya Branch) for any questions or assistance. We look forward to seeing you soon! 🐟❤️ \n" +

                    "We can also help you book a lalamove delivery partner\n" +
                    "📦 Kindly send the following details\n" +
                    "\n" +
                    "• Full Name:\n" +
                    "• Contact Number:\n" +
                    "• Complete Address:\n" +
                    "• Pin Location (Google Maps link or screenshot):\n" +
                    "💬 Once received, well confirm your order and send the final details right away. Thank you\n" +
                    "Thank you for choosing RSPetStop—We appreciate you always! and see you soon ❤️";

        /// <summary>                                       
        /// Default pickup-ready customer message template. Use String.Replace to fill placeholders:
        /// [Customer Name], [Order ID], [Store Address], [Store Hours]
        /// </summary>
        public static string PickupReadyMessage { get; } =
            "🎉 Hi {Customer Name}! Your order {Order ID} is now ready for pickup at RSPetStop.\n" +
            "{Payment}\n" +
            "\n" +
            "🧾 Heres what youll be receiving:\n" +
            "\n" +
            " {Items}\n" +
            "\n" +
            "\n" +
            "Swing by anytime during our store hours—your fish joy is just one finstep away! 🐠🦈\n" +
            "📍 Location: Amaya Dos Antero Soriano Highway Tanza Cavite or just Pin : RSPetStop Amaya \n" +
            "🕒 Hours: 8:00 am to 8:00 pm monday to sunday\n" +
            "For GMA Location, You can pickup your order on the next Delivery schedule. You can coordinate with us with this. Happy fish keeping. \n" +
            "You may call +63 997 189 1662 (GMA Branch) for any questions or assistance. We look forward to seeing you soon! 🐟❤️ \n" +

            "We can also help you book a lalamove delivery partner\n" +
            "📦 Kindly send the following details\n" +
            "\n" +
            "• Full Name:\n" +
            "• Contact Number:\n" +
            "• Complete Address:\n" +
            "• Pin Location (Google Maps link or screenshot):\n" +
            "💬 Once received, well confirm your order and send the final details right away. Thank you\n" +
            "Thank you for choosing RSPetStop—We appreciate you always! and see you soon ❤️";

        // External Lalamove API settings (hardcoded for local testing).
        // NOTE: These values are intentionally hardcoded for quick local testing as requested.
        // Replace with real values or restore environment-variable lookups for production.
        public static string LalamoveApiHostname { get; } = "rest.sandbox.lalamove.com"; // e.g. "api.lalamove.com"
        public static string LalamoveApiKey { get; } = "pk_test_6da6616fe203270a08d52c498ac20ee3";
        public static string LalamoveApiSecret { get; } = "sk_test_jeg3l5/6XKWcD+Y3v+TXM4WCNQC6AVOyqSaeNTTQ2E0BNfcI3D4CvtQBSTDffAeq";
        public static string LalamoveMarket { get; } = "PH"; // Market code, e.g. PH
        public static string LalamoveCountry { get; } = "PH"; // Country code
        public static string LalamoveOrderRef { get; } = "LOCAL_ORDER_001";
        public static string LalamoveOrderId { get; } = "LOCAL_ORDER_ID_001";
        public static string LalamoveDriverId { get; } = "LOCAL_DRIVER_001";
        public static string LalamoveQuotationId { get; } = "LOCAL_QUOTATION_001";
        // Stop ids (commonly stopId-0, stopId-1 in payloads). Keep as simple properties for quick access.
        public static string LalamoveStopId0 { get; } = "stop-0-id";
        public static string LalamoveStopId1 { get; } = "stop-1-id";

        // Last-request/response metadata (useful for diagnostics). These are updated at runtime by
        // the local proxy client and are not persisted across runs.
        public static string LastQuotationRequestBody { get; set; } = string.Empty;
        public static string LastQuotationSignature { get; set; } = string.Empty;
        public static string LastQuotationTime { get; set; } = string.Empty;
        public static string LastQuotationResponseBody { get; set; } = string.Empty;
        public static string LastQuotationTotalFee { get; set; } = string.Empty;
        public static string LastQuotationTotalFeeCurrency { get; set; } = string.Empty;

        /// <summary>
        /// Message shown when tender declaration is attempted during the restricted local-time window.
        /// </summary>
        public static string TenderDeclarationRestrictedMessage { get; } = "Tender within this hours are not allowed";

        /// <summary>
        /// Returns true when tender declaration is blocked for the specified local date/time.
        /// Restricted window: 7:00 PM inclusive up to 8:00 PM exclusive.
        /// </summary>
        public static bool IsTenderDeclarationRestrictedTime(DateTime localDateTime)
        {
            TimeSpan localTime = localDateTime.TimeOfDay;
            return localTime >= new TimeSpan(19, 0, 0) && localTime < new TimeSpan(20, 0, 0);
        }
    }
}
