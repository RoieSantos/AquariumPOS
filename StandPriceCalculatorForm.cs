using System;
using System.Drawing;
using System.Windows.Forms;

namespace AquariumPOS
{
    /// <summary>
    /// Stand Price Calculator form
    /// Assumptions (inferred):
    /// - Pricing is based on area per layer (Length x Width) times number of layers.
    /// - Base unit cost per square unit = 10 (currency units).
    /// - Stainless multiplier = 1.5 (50% more expensive).
    /// - Tubular size multipliers: "1x1" = 1.0, "1 1/2 x 1 1/2" = 1.2, "2x2" = 1.4.
    /// - All dimensions are integer input fields (units left to user: mm/cm/inches depending on shop conventions).
    /// These assumptions can be adjusted in CalculatePrice() easily.
    /// </summary>
    public class StandPriceCalculatorForm : Form
    {
        private readonly bool selectionOnly;

        private NumericUpDown? nudLength;
        private NumericUpDown? nudHeight;
        private NumericUpDown? nudWidth;
        private NumericUpDown? nudLayers;
        private CheckBox? chkStainless;
        private CheckBox? chkSumpHolder;
        private CheckBox? chkCabinet;
        private Label? lblSumpWidth;
        private NumericUpDown? nudSumpWidth;
        private GroupBox? gbTubular;
        private RadioButton? rbTubular1;
        private RadioButton? rbTubular15;
        private RadioButton? rbTubular2;
        private Button? btnCalculate;
        private Button? btnClose;
        private TextBox? lblResult;
        private ComboBox? unitComboBox;
        private ComboBox? stdSizeComboBox;
        private Label? lblVolume;
        private Label? lblEstimatedPrice;
        private Button? btnAddToSale;
        private bool suppressStdChange = false;
    private bool suppressTubularEnforcement = false;

        // Exposed after OK so caller (MainForm) can add to sale
        public decimal SelectedPrice { get; private set; }
        public string SelectedDescription { get; private set; } = string.Empty;
        public string SelectedBreakdown { get; private set; } = string.Empty;

        public decimal SelectedLength { get; private set; }
        public decimal SelectedWidth { get; private set; }
        public decimal SelectedHeight { get; private set; }
        public int SelectedLayers { get; private set; }
        public string SelectedTubular { get; private set; } = string.Empty;
        public string SelectedUnit { get; private set; } = string.Empty;

        // Retail rates (₱ per foot) for tubular sizes - adjust as needed
        private static readonly System.Collections.Generic.Dictionary<string, decimal> TubularRetailRates = new System.Collections.Generic.Dictionary<string, decimal>(System.StringComparer.OrdinalIgnoreCase)
    {
        // ASSUMPTIONS: you can change these to match shop pricing
        { "1x1", 46.0m },     // ₱46 per ft for 1 x 1
        { "1.5x1.5", 52.0m },// ₱52 per ft for 1 1/2 x 1 1/2
        { "2x2", 95.0m }     // ₱95 per ft for 2 x 2
    };

        // Standard aquarium presets keyed by aquarium gallons. Values are approximate dimensions (L x W x H) in INCHES.
        // These are common / approximate sizes — adjust as needed for your shop.
        private static readonly System.Collections.Generic.Dictionary<string, (int L, int W, int H)> StandardAquariumSizes = new System.Collections.Generic.Dictionary<string, (int, int, int)>
        {
             { "betta tank 4x6x8", (4, 6, 8) },
            { "betta tank 6x6x8", (6, 6, 8) },
            { "betta tank 6x6x6", (6, 6, 6) },
            { "betta tank 8x8x8", (8, 8, 8) },
            { "betta tank 10x10x10", (10, 10, 10) },
            { "betta tank 12x12x12", (12, 12, 12) },
            { "2.5g", (12, 6, 8) },
            { "5g",   (16, 8, 10) },
            { "10g",  (20, 10, 12) },
            { "15g",  (24, 12, 12) },
            { "20g",  (24, 12, 16) },
            { "25g",  (24, 12, 16) },
            { "30g",  (30, 12, 16) },
            { "35g",  (30, 18, 16) },
            { "50g",  (36, 18, 24) },
            { "75g",  (48, 18, 24) },
            { "90g",  (60, 20, 24) },
            { "100g", (72, 18, 20) },
            {"CUSTOM", (0,0,0)}


        };

        public StandPriceCalculatorForm() : this(false)
        {
        }

        public StandPriceCalculatorForm(bool selectionOnly)
        {
            this.selectionOnly = selectionOnly;
            this.Text = "Stand Price Calculator";
            // Make the form larger to match the Custom Aquarium dialog layout
            this.Size = new Size(900, 820);
            this.StartPosition = FormStartPosition.CenterParent;
            this.FormBorderStyle = FormBorderStyle.FixedDialog;
            this.MaximizeBox = false;
            InitializeComponent();
        }

        public void PrefillFootprintInInches(decimal lengthInInches, decimal widthInInches)
        {
            try
            {
                if (unitComboBox != null)
                {
                    try { unitComboBox.SelectedItem = "Inches"; } catch { }
                }

                try { SetStandardToCustom(); } catch { }

                if (nudLength != null)
                {
                    decimal vL = lengthInInches;
                    if (vL < nudLength.Minimum) vL = nudLength.Minimum;
                    if (vL > nudLength.Maximum) vL = nudLength.Maximum;
                    try
                    {
                        suppressStdChange = true;
                        nudLength.Value = vL;
                    }
                    finally { suppressStdChange = false; }
                }

                if (nudWidth != null)
                {
                    decimal vW = widthInInches;
                    if (vW < nudWidth.Minimum) vW = nudWidth.Minimum;
                    if (vW > nudWidth.Maximum) vW = nudWidth.Maximum;
                    try
                    {
                        suppressStdChange = true;
                        nudWidth.Value = vW;
                    }
                    finally { suppressStdChange = false; }
                }

                try { UpdateHeightFromLayers(); } catch { }
                try { EnforceTubularSafety(); } catch { }
                try { PerformCalculate(); } catch { }
            }
            catch { }
        }

        public void ForceTubular(string tubular, bool lockSelection)
        {
            try
            {
                if (rbTubular1 == null || rbTubular15 == null || rbTubular2 == null) return;

                bool is1 = string.Equals(tubular, "1x1", StringComparison.OrdinalIgnoreCase);
                bool is15 = string.Equals(tubular, "1.5x1.5", StringComparison.OrdinalIgnoreCase)
                    || string.Equals(tubular, "1 1/2 x 1 1/2", StringComparison.OrdinalIgnoreCase);
                bool is2 = string.Equals(tubular, "2x2", StringComparison.OrdinalIgnoreCase);

                try
                {
                    suppressTubularEnforcement = true;

                    if (is1) rbTubular1.Checked = true;
                    else if (is15) rbTubular15.Checked = true;
                    else if (is2) rbTubular2.Checked = true;
                }
                finally
                {
                    suppressTubularEnforcement = false;
                }

                if (lockSelection)
                {
                    rbTubular1.Enabled = is1;
                    rbTubular15.Enabled = is15;
                    rbTubular2.Enabled = is2;
                }
                else
                {
                    rbTubular1.Enabled = true;
                    rbTubular15.Enabled = true;
                    rbTubular2.Enabled = true;
                }

                try { UpdateHeightFromLayers(); } catch { }
                try { PerformCalculate(); } catch { }
            }
            catch { }
        }

        private void InitializeComponent()
        {
            // Layout modeled after the existing Custom Aquarium dialog for visual parity
            var titleLabel = new Label
            {
                Text = "Stand Price Calculator",
                Font = new Font("Arial", 18, FontStyle.Bold),
                ForeColor = Color.DarkBlue,
                Location = new Point(20, 16),
                Size = new Size(860, 32)
            };
            this.Controls.Add(titleLabel);

            // Unit of measure (left-top)
            var unitLabel = new Label { Text = "Unit of Measure:", Location = new Point(20, 64), Size = new Size(140, 24), Font = new Font("Arial", 10, FontStyle.Bold) };
            unitComboBox = new ComboBox { Location = new Point(200, 62), Size = new Size(140, 26), Font = new Font("Arial", 12, FontStyle.Bold), DropDownStyle = ComboBoxStyle.DropDownList };
            unitComboBox.Items.AddRange(new string[] { "Inches", "CM", "Ft", "MM" });
            unitComboBox.SelectedIndex = 0;
            this.Controls.Add(unitLabel);
            this.Controls.Add(unitComboBox);

            // Stainless checkbox (right of unit)
            chkStainless = new CheckBox { Text = "Stainless", Location = new Point(380, 62), Size = new Size(140, 26), Font = new Font("Arial", 12, FontStyle.Bold), ForeColor = Color.DarkRed };
            this.Controls.Add(chkStainless);
            // Sump holder checkbox (beside Stainless)
            chkSumpHolder = new CheckBox { Text = "Sump holder", Location = new Point(540, 62), Size = new Size(160, 26), Font = new Font("Arial", 12, FontStyle.Bold), ForeColor = Color.DarkBlue };
            this.Controls.Add(chkSumpHolder);
            // Cabinet checkbox
            chkCabinet = new CheckBox { Text = "Cabinet", Location = new Point(720, 62), Size = new Size(140, 26), Font = new Font("Arial", 12, FontStyle.Bold), ForeColor = Color.DarkSlateBlue };
            this.Controls.Add(chkCabinet);

            // Sump width label and input (hidden by default)
            lblSumpWidth = new Label { Text = "Sump width:", Location = new Point(540, 96), Size = new Size(120, 24), Font = new Font("Arial", 12, FontStyle.Bold), Visible = false };
            nudSumpWidth = new NumericUpDown { Location = new Point(680, 94), Size = new Size(120, 28), Font = new Font("Arial", 14, FontStyle.Bold), Minimum = 0, Maximum = 10000, DecimalPlaces = 2, Value = 0, Visible = false };
            this.Controls.Add(lblSumpWidth);
            this.Controls.Add(nudSumpWidth);
            // Wire sump holder visibility and behavior
            chkSumpHolder.CheckedChanged += (s, e) =>
            {
                try
                {
                    bool show = chkSumpHolder!.Checked;
                    if (lblSumpWidth != null) lblSumpWidth.Visible = show;
                    if (nudSumpWidth != null) nudSumpWidth.Visible = show;
                    if (show && nudSumpWidth != null)
                    {
                        try { suppressStdChange = true; nudSumpWidth.Value = 0; } finally { suppressStdChange = false; }
                    }
                }
                catch { }
                PerformCalculate();
            };

            nudSumpWidth.ValueChanged += (s, e) => { if (!suppressStdChange) { try { SetStandardToCustom(); } catch { } } PerformCalculate(); };

            // Standard aquarium size selector (will populate presets)
            var stdLabel = new Label { Text = "Standard Aquarium size:", Location = new Point(20, 96), Size = new Size(160, 24), Font = new Font("Arial", 10, FontStyle.Bold) };
            stdSizeComboBox = new ComboBox { Location = new Point(200, 94), Size = new Size(240, 26), Font = new Font("Arial", 12, FontStyle.Bold), DropDownStyle = ComboBoxStyle.DropDownList };
            // Populate items from presets
            foreach (var k in StandardAquariumSizes.Keys)
                stdSizeComboBox.Items.Add(k);
            // // allow a custom entry option after the standard presets
            // stdSizeComboBox.Items.Add("Custom");
            // stdSizeComboBox.SelectedIndex = -1;
            this.Controls.Add(stdLabel);
            this.Controls.Add(stdSizeComboBox);

            // Length / Width / Height inputs (left column)
            int leftX = 20;
            int inputX = 170;
            int y = 140;
            var lblLength = new Label { Text = "Length:", Location = new Point(leftX, y), Size = new Size(140, 24), Font = new Font("Arial", 12, FontStyle.Bold) };
            nudLength = new NumericUpDown { Location = new Point(inputX, y - 4), Size = new Size(140, 30), Font = new Font("Arial", 14, FontStyle.Bold), Minimum = 0, Maximum = 100000, Value = 50 };
            this.Controls.Add(lblLength); this.Controls.Add(nudLength);

            y += 48;
            var lblWidth = new Label { Text = "Width:", Location = new Point(leftX, y), Size = new Size(140, 24), Font = new Font("Arial", 12, FontStyle.Bold) };
            nudWidth = new NumericUpDown { Location = new Point(inputX, y - 4), Size = new Size(140, 30), Font = new Font("Arial", 14, FontStyle.Bold), Minimum = 0, Maximum = 100000, Value = 40 };
            this.Controls.Add(lblWidth); this.Controls.Add(nudWidth);

            y += 48;
            var lblHeight = new Label { Text = "Height:", Location = new Point(leftX, y), Size = new Size(140, 24), Font = new Font("Arial", 12, FontStyle.Bold) };
            nudHeight = new NumericUpDown { Location = new Point(inputX, y - 4), Size = new Size(140, 30), Font = new Font("Arial", 14, FontStyle.Bold), Minimum = 0, Maximum = 100000, DecimalPlaces = 3, Increment = 125 / 1000m, Value = 0 };
            this.Controls.Add(lblHeight); this.Controls.Add(nudHeight);

            y += 48;
            var lblLayers = new Label { Text = "No. of Layers:", Location = new Point(leftX, y), Size = new Size(140, 24), Font = new Font("Arial", 12, FontStyle.Bold) };
            nudLayers = new NumericUpDown { Location = new Point(inputX, y - 4), Size = new Size(140, 30), Font = new Font("Arial", 14, FontStyle.Bold), Minimum = 2, Maximum = 100, Value = 2 };
            this.Controls.Add(lblLayers); this.Controls.Add(nudLayers);

            // Tubular group under inputs — made larger and bolder per request
            // Move the tubular group further down so the right-side buttons are not overlapped
            // Move tubular group slightly up to avoid overlap with right-side buttons
            gbTubular = new GroupBox { Text = "Tubular", Location = new Point(20, y + 80), Size = new Size(860, 96), Font = new Font("Arial", 13, FontStyle.Bold) };
            rbTubular1 = new RadioButton { Text = "1 x 1", Location = new Point(14, 26), Checked = true, AutoSize = true, Font = new Font("Arial", 13, FontStyle.Bold) };
            rbTubular15 = new RadioButton { Text = "1 1/2 x 1 1/2", Location = new Point(140, 26), AutoSize = true, Font = new Font("Arial", 13, FontStyle.Bold) };
            rbTubular2 = new RadioButton { Text = "2 x 2", Location = new Point(360, 26), AutoSize = true, Font = new Font("Arial", 13, FontStyle.Bold) };
            gbTubular.Controls.Add(rbTubular1);
            gbTubular.Controls.Add(rbTubular15);
            gbTubular.Controls.Add(rbTubular2);
            this.Controls.Add(gbTubular);

            // Right side action buttons
            btnCalculate = new Button { Text = "Calculate Price", Location = new Point(720, 160), Size = new Size(160, 56), BackColor = Color.RoyalBlue, ForeColor = Color.White, Font = new Font("Arial", 14, FontStyle.Bold) };
            btnCalculate.Click += BtnCalculate_Click;
            this.Controls.Add(btnCalculate);

            // Volume and Estimated Price labels (styled)
            lblVolume = new Label { Text = "Volume: 0 gallons", Location = new Point(20, 490), Size = new Size(860, 28), Font = new Font("Arial", 14, FontStyle.Bold), ForeColor = Color.DarkGreen };
            lblEstimatedPrice = new Label { Text = "Estimated Price: 0.00", Location = new Point(20, 530), Size = new Size(860, 36), Font = new Font("Arial", 16, FontStyle.Bold), ForeColor = Color.DarkRed };
            this.Controls.Add(lblVolume); this.Controls.Add(lblEstimatedPrice);

            // Add to Sale (green) and Close (gray)
            btnAddToSale = new Button { Text = selectionOnly ? "Use Stand" : "Add to Sale", Location = new Point(720, 230), Size = new Size(160, 56), BackColor = Color.ForestGreen, ForeColor = Color.White, Font = new Font("Arial", 14, FontStyle.Bold) };
            btnAddToSale.Click += BtnAddToSale_Click;
            this.Controls.Add(btnAddToSale);

            btnClose = new Button { Text = "Close", Location = new Point(720, 300), Size = new Size(160, 56), BackColor = Color.Gray, ForeColor = Color.White, Font = new Font("Arial", 14, FontStyle.Bold), DialogResult = DialogResult.Cancel };
            btnClose.Click += (s, e) => this.Close();
            this.Controls.Add(btnClose);

            // Result textbox for detailed breakdown (non-editable, scrollable)
            lblResult = new TextBox
            {
                Location = new Point(20, 580),
                Size = new Size(860, 110),
                BorderStyle = BorderStyle.FixedSingle,
                Multiline = true,
                ReadOnly = true,
                ScrollBars = ScrollBars.Vertical,
                Font = new Font("Consolas", 12, FontStyle.Bold),
                BackColor = Color.White
            };
            this.Controls.Add(lblResult);

            // Set initial (blank/default) states when the form opens
            // NumericUpDowns cannot be blank, so default to 0 for dimensions and 1 for layers
            nudLength!.Value = 0;
            nudWidth!.Value = 0;
            nudHeight!.Value = 0;
            nudLayers!.Value = 2;
            // Standard aquarium: none selected
            stdSizeComboBox!.SelectedIndex = -1;
            // Stainless default to false
            chkStainless!.Checked = false;
            chkCabinet!.Checked = false;

            // Clear result and price until user enters values or selects a preset
            lblEstimatedPrice!.Text = "Estimated Price: N/A";
            lblResult!.Text = string.Empty;
            lblVolume!.Text = string.Empty;

            // Wire change events so calculation runs automatically whenever any input changes
            nudLength.ValueChanged += (s, e) => { if (!suppressStdChange) { try { SetStandardToCustom(); } catch { } } try { EnforceTubularSafety(); } catch { } PerformCalculate(); };
            nudWidth.ValueChanged += (s, e) => { if (!suppressStdChange) { try { SetStandardToCustom(); } catch { } } PerformCalculate(); };
            nudHeight.ValueChanged += (s, e) => { if (!suppressStdChange) { try { SetStandardToCustom(); } catch { } } PerformCalculate(); };
            nudLayers.ValueChanged += (s, e) =>
            {
                try { UpdateHeightFromLayers(); } catch { }
                PerformCalculate();
            };
            chkStainless.CheckedChanged += (s, e) => PerformCalculate();
            chkCabinet.CheckedChanged += (s, e) => PerformCalculate();
            unitComboBox!.SelectedIndexChanged += (s, e) =>
            {
                try { UpdateHeightFromLayers(); } catch { }
                try { EnforceTubularSafety(); } catch { }
                PerformCalculate();
            };
            rbTubular1!.CheckedChanged += (s, e) => { try { UpdateHeightFromLayers(); } catch { }; try { EnforceTubularSafety(); } catch { }; PerformCalculate(); };
            rbTubular15!.CheckedChanged += (s, e) => { try { UpdateHeightFromLayers(); } catch { }; PerformCalculate(); };
            rbTubular2!.CheckedChanged += (s, e) => { try { UpdateHeightFromLayers(); } catch { }; PerformCalculate(); };
            stdSizeComboBox.SelectedIndexChanged += (s, e) =>
            {
                try
                {
                    if (stdSizeComboBox.SelectedItem == null) { return; }
                    var key = stdSizeComboBox.SelectedItem.ToString();
                    if (key == null) { return; }
                    // If the user selected CUSTOM (case-insensitive), do not override dimensions
                    if (string.Equals(key, "CUSTOM", StringComparison.OrdinalIgnoreCase))
                    {
                        // let user enter custom dims
                        return;
                    }
                    if (StandardAquariumSizes.TryGetValue(key, out var dims))
                    {
                        // clamp to min/max and assign
                        decimal vL = dims.L;
                        if (vL < nudLength.Minimum) vL = nudLength.Minimum;
                        if (vL > nudLength.Maximum) vL = nudLength.Maximum;

                        decimal vW = dims.W;
                        if (vW < nudWidth.Minimum) vW = nudWidth.Minimum;
                        if (vW > nudWidth.Maximum) vW = nudWidth.Maximum;

                        try
                        {
                            suppressStdChange = true;
                            nudLength.Value = vL;
                            nudWidth.Value = vW;
                        }
                        finally
                        {
                            suppressStdChange = false;
                        }

                        // Do NOT overwrite Height when selecting a standard aquarium.
                        // Height should remain driven by number of layers (UpdateHeightFromLayers).
                        try { UpdateHeightFromLayers(); } catch { }
                        PerformCalculate();
                    }
                }
                catch { /* swallow ui errors silently */ }
            };

            // Initialize computed controls based on defaults (layers/tubular/unit)
            try { UpdateHeightFromLayers(); } catch { }
        }

        private void BtnCalculate_Click(object? sender, EventArgs e)
        {
            PerformCalculate();
        }

        /// <summary>
        /// Update the Height control based on current number of layers and selected unit.
        /// Uses the special mappings: 2 layers => 36 inches, 3 layers => 60 inches, otherwise a small per-layer default.
        /// </summary>
        private void UpdateHeightFromLayers()
        {
            if (nudLayers == null || nudHeight == null || unitComboBox == null) return;
            decimal layersVal = nudLayers.Value;
            // Formula: Height = H2 + (n-2) * DeltaH, where H2 and DeltaH are in inches
            decimal H2_in = 0m;
            decimal deltaH_in = 0m;

            var tubular = GetSelectedTubular();
            if (string.Equals(tubular, "1x1", StringComparison.OrdinalIgnoreCase))
            {
                H2_in = 30m;      // base dual stand height for 1x1
                deltaH_in = 16m;  // increment per additional layer
            }
            else if (string.Equals(tubular, "1.5x1.5", StringComparison.OrdinalIgnoreCase) || string.Equals(tubular, "1 1/2 x 1 1/2", StringComparison.OrdinalIgnoreCase))
            {
                H2_in = 36m;      // base dual stand height for 1.5x1.5
                deltaH_in = 24m;  // increment per additional layer
            }
            else
            {
                // default: use 30/16 as a sensible default
                H2_in = 36m;
                deltaH_in = 24m;
            }

            // layers >= 2 by UI constraints; compute height in inches
            decimal heightInInches = H2_in + (layersVal - 2m) * deltaH_in;

            var unit = unitComboBox.SelectedItem?.ToString() ?? "Inches";
            decimal heightInUnit;
            if (string.Equals(unit, "Inches", StringComparison.OrdinalIgnoreCase))
            {
                heightInUnit = heightInInches;
            }
            else if (string.Equals(unit, "CM", StringComparison.OrdinalIgnoreCase))
            {
                heightInUnit = heightInInches * 2.54m;
            }
            else if (string.Equals(unit, "MM", StringComparison.OrdinalIgnoreCase))
            {
                heightInUnit = heightInInches * 25.4m;
            }
            else if (string.Equals(unit, "Ft", StringComparison.OrdinalIgnoreCase))
            {
                // convert inches to feet for display
                heightInUnit = heightInInches / 12m;
            }
            else
            {
                heightInUnit = heightInInches;
            }

            decimal newHeight = heightInUnit;
            if (newHeight < nudHeight.Minimum) newHeight = nudHeight.Minimum;
            if (newHeight > nudHeight.Maximum) newHeight = nudHeight.Maximum;
            try
            {
                suppressStdChange = true;
                nudHeight.Value = newHeight;
            }
            finally
            {
                suppressStdChange = false;
            }
        }

        /// <summary>
        /// When the user manually edits length/width/height, switch the standard aquarium selector to CUSTOM.
        /// </summary>
        private void SetStandardToCustom()
        {
            var combo = stdSizeComboBox;
            if (combo == null) return;

            var items = combo.Items;
            for (int i = 0; i < items.Count; i++)
            {
                var s = items[i]?.ToString();
                if (string.Equals(s, "CUSTOM", StringComparison.OrdinalIgnoreCase))
                {
                    if (combo.SelectedIndex != i)
                        combo.SelectedIndex = i;
                    return;
                }
            }
        }

        /// <summary>
        /// Return the current Length converted to inches based on selected unit.
        /// </summary>
        private decimal GetLengthInInches()
        {
            if (nudLength == null || unitComboBox == null) return 0m;
            decimal val = nudLength.Value;
            var unit = unitComboBox.SelectedItem?.ToString() ?? "Inches";
            if (string.Equals(unit, "Inches", StringComparison.OrdinalIgnoreCase)) return val;
            if (string.Equals(unit, "CM", StringComparison.OrdinalIgnoreCase)) return val / 2.54m;
            if (string.Equals(unit, "MM", StringComparison.OrdinalIgnoreCase)) return val / 25.4m;
            if (string.Equals(unit, "Ft", StringComparison.OrdinalIgnoreCase)) return val * 12m;
            return val;
        }

        /// <summary>
        /// Enforce safety: if tubular selection is 1x1 and length > 30 inches, force tubular to 1.5x1.5.
        /// This prevents unsafe selection for long spans.
        /// </summary>
        private void EnforceTubularSafety()
        {
            if (suppressTubularEnforcement) return;
            if (rbTubular1 == null || rbTubular15 == null || nudLength == null || unitComboBox == null) return;
            try
            {
                suppressTubularEnforcement = true;
                decimal lengthInInches = GetLengthInInches();
                if (rbTubular1.Checked && lengthInInches > 30m)
                {
                    // Switch to 1.5 x 1.5 for safety
                    rbTubular15.Checked = true;
                    // Inform the user
                    try
                    {
                        MessageBox.Show(this, "Length is greater than 30 inches — switching tubular to 1 1/2 x 1 1/2 for safety.", "Tubular size adjusted", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    }
                    catch { }
                }
                // New rule: if Length > 50 inches AND Width > 18 inches -> mandatory 2x2
                try
                {
                    if (nudWidth != null)
                    {
                        decimal widthInInches = GetValueInInches(nudWidth);
                        if (lengthInInches >= 49 && widthInInches >= 18m && !rbTubular2.Checked)
                        {
                            rbTubular2.Checked = true;
                            try { MessageBox.Show(this, "Length > 50 in and Width > 18 in — tubular set to 2 x 2 (mandatory).", "Tubular size adjusted", MessageBoxButtons.OK, MessageBoxIcon.Warning); } catch { }
                        }
                    }
                }
                catch { }
            }
            finally
            {
                suppressTubularEnforcement = false;
            }
        }

        /// <summary>
        /// Convert the provided NumericUpDown value into inches based on the selected unit.
        /// </summary>
        private decimal GetValueInInches(System.Windows.Forms.NumericUpDown? nud)
        {
            if (nud == null || unitComboBox == null) return 0m;
            decimal val = nud.Value;
            var unit = unitComboBox.SelectedItem?.ToString() ?? "Inches";
            if (string.Equals(unit, "Inches", StringComparison.OrdinalIgnoreCase)) return val;
            if (string.Equals(unit, "CM", StringComparison.OrdinalIgnoreCase)) return val / 2.54m;
            if (string.Equals(unit, "MM", StringComparison.OrdinalIgnoreCase)) return val / 25.4m;
            if (string.Equals(unit, "Ft", StringComparison.OrdinalIgnoreCase)) return val * 12m;
            return val;
        }

        /// <summary>
        /// Read inputs, validate, compute and update UI. Safe to call on any input change.
        /// </summary>
        private void PerformCalculate()
        {
            try
            {
                // Ensure controls are initialized
                if (nudLength == null || nudWidth == null || nudHeight == null || nudLayers == null || unitComboBox == null || chkStainless == null)
                    return;

                var length = nudLength.Value;
                var height = nudHeight.Value;
                var width = nudWidth.Value;
                var layers = (int)nudLayers.Value;
                var stainless = chkStainless.Checked;
                var cabinet = chkCabinet != null && chkCabinet.Checked;
                var tubular = GetSelectedTubular();

                // Basic validation
                if (length <= 0 || width <= 0 || height <= 0)
                {
                    lblEstimatedPrice!.Text = "Estimated Price: N/A";
                    lblResult!.Text = "Please enter positive non-zero dimensions (Length, Width, Height).";
                    SelectedPrice = 0m;
                    return;
                }

                if (layers <= 0)
                {
                    lblEstimatedPrice!.Text = "Estimated Price: N/A";
                    lblResult!.Text = "Please enter at least 1 layer.";
                    SelectedPrice = 0m;
                    return;
                }

                // Compute volume in gallons for optional display (kept for reference)
                var unit = unitComboBox.SelectedItem?.ToString() ?? "Inches";
                double gallons = ConvertVolumeToGallons(length, width, height, unit);

                // Convert input dimensions to feet based on selected unit before computing
                decimal Lft, Wft, Hft;
                if (string.Equals(unit, "Inches", StringComparison.OrdinalIgnoreCase))
                {
                    Lft = length / 12m;
                    Wft = width / 12m;
                    Hft = height / 12m;
                }
                else if (string.Equals(unit, "CM", StringComparison.OrdinalIgnoreCase))
                {
                    // 1 foot = 30.48 cm
                    Lft = length / 30.48m;
                    Wft = width / 30.48m;
                    Hft = height / 30.48m;
                }
                else if (string.Equals(unit, "MM", StringComparison.OrdinalIgnoreCase))
                {
                    // 1 foot = 304.8 mm
                    Lft = length / 304.8m;
                    Wft = width / 304.8m;
                    Hft = height / 304.8m;
                }
                else if (string.Equals(unit, "Ft", StringComparison.OrdinalIgnoreCase))
                {
                    // Already in feet
                    Lft = length;
                    Wft = width;
                    Hft = height;
                }
                else
                {
                    // fallback assume inches
                    Lft = length / 12m;
                    Wft = width / 12m;
                    Hft = height / 12m;
                }

                // Compute sump width (if present) in feet
                decimal sumpWidthFt = 0m;
                if (chkSumpHolder != null && chkSumpHolder.Checked && nudSumpWidth != null && nudSumpWidth.Value > 0)
                {
                    if (string.Equals(unit, "Inches", StringComparison.OrdinalIgnoreCase))
                        sumpWidthFt = nudSumpWidth.Value / 12m;
                    else if (string.Equals(unit, "CM", StringComparison.OrdinalIgnoreCase))
                        sumpWidthFt = nudSumpWidth.Value / 30.48m;
                    else if (string.Equals(unit, "MM", StringComparison.OrdinalIgnoreCase))
                        sumpWidthFt = nudSumpWidth.Value / 304.8m;
                    else if (string.Equals(unit, "Ft", StringComparison.OrdinalIgnoreCase))
                        sumpWidthFt = nudSumpWidth.Value;
                    else
                        sumpWidthFt = nudSumpWidth.Value / 12m;
                }

                // Compute using the main formula (includes sump cost if sumpWidthFt > 0)
                var (price, breakdown, totalFeetConsumed) = ComputeStandRetailPrice(Lft, Wft, Hft, layers, tubular, stainless, sumpWidthFt);

                // Update UI
                var sumpText = string.Empty;
                if (chkSumpHolder != null && chkSumpHolder.Checked && nudSumpWidth != null)
                {
                    sumpText = $" -Sumpholder:(width: {nudSumpWidth.Value} {unit})";
                }
                var cabinetText = cabinet ? " - Cabinet: Yes" : string.Empty;
                lblVolume!.Text = $"Dim: {length} x {width} x {height} {unit}  - Tubular: {tubular}  - Layers: {layers} total{sumpText}{cabinetText}";
                lblEstimatedPrice!.Text = $"Estimated Price: ₱{price:0.00}";
                lblResult!.Text = breakdown + Environment.NewLine + $"Cabinet: {(cabinet ? "Yes" : "No")}";
                SelectedPrice = price;
                SelectedDescription = $"Stand {length}x{width}x{height} ({unit})";
                SelectedBreakdown = lblResult!.Text;

                SelectedLength = length;
                SelectedWidth = width;
                SelectedHeight = height;
                SelectedLayers = layers;
                SelectedTubular = tubular;
                SelectedUnit = unit;
            }
            catch (Exception ex)
            {
                lblEstimatedPrice!.Text = "Estimated Price: N/A";
                lblResult!.Text = $"Failed to calculate price: {ex.Message}";
                SelectedPrice = 0m;
                SelectedBreakdown = lblResult!.Text;

                SelectedLength = 0m;
                SelectedWidth = 0m;
                SelectedHeight = 0m;
                SelectedLayers = 0;
                SelectedTubular = string.Empty;
                SelectedUnit = string.Empty;
            }
        }

        private void BtnAddToSale_Click(object? sender, EventArgs e)
        {
            if (SelectedPrice <= 0)
            {
                MessageBox.Show(selectionOnly ? "Please calculate the price before selecting." : "Please calculate the price before adding to sale.", "Info", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            // Validate sump holder inputs: if sump holder is requested, ensure sump width > 0
            if (chkSumpHolder != null && chkSumpHolder.Checked)
            {
                var sw = nudSumpWidth != null ? nudSumpWidth.Value : 0;
                if (sw == 0)
                {
                    MessageBox.Show("cannot add to sale sump width is 0", "Invalid input", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    return;
                }
            }

            // Build a custom description with all dimensions and options
            try
            {
                var unit = unitComboBox?.SelectedItem?.ToString() ?? "Inches";
                var length = nudLength != null ? nudLength.Value : 0;
                var width = nudWidth != null ? nudWidth.Value : 0;
                var height = nudHeight != null ? nudHeight.Value : 0;
                var layers = nudLayers != null ? nudLayers.Value : 0;
                var tubular = GetSelectedTubular();
                bool isStainless = chkStainless != null && chkStainless.Checked;
                bool hasCabinet = chkCabinet != null && chkCabinet.Checked;

                // Build description and only include stainless/sump info when enabled
                var desc = $"{length}x{width}x{height} {unit} {layers} Layer {tubular}";
                if (isStainless)
                {
                    desc += " Stainless = true";
                }

                if (hasCabinet)
                {
                    desc += " Cabinet = true";
                }

                if (chkSumpHolder != null && chkSumpHolder.Checked)
                {
                    var sw = nudSumpWidth != null ? nudSumpWidth.Value : 0;
                    desc += $" Sump-Holder W-{sw} {unit}";
                }

                SelectedDescription = desc;
            }
            catch { /* ignore and fallback to existing SelectedDescription */ }

            this.DialogResult = DialogResult.OK;
            this.Close();
        }

        private string GetSelectedTubular()
        {
            if (rbTubular1!.Checked) return "1x1";
            if (rbTubular15!.Checked) return "1.5x1.5";
            if (rbTubular2!.Checked) return "2x2";
            return "1x1";
        }

        /// <summary>
        /// Calculate price using simple heuristics. Returns (price, breakdown string).
        /// You can change baseUnitCost and multipliers here to fit shop pricing.
        /// </summary>
        private (decimal price, string breakdown) CalculatePrice(int length, int height, int width, int layers, bool stainless, string tubular)
        {
            // Units: length/width in arbitrary units (e.g., cm). We'll compute area per layer = length * width.
            decimal baseUnitCost = 10.0m; // cost per square unit

            decimal areaPerLayer = (decimal)length * (decimal)width;
            decimal rawMaterialCost = areaPerLayer * layers * baseUnitCost;

            decimal stainlessMultiplier = stainless ? 1.5m : 1.0m;

            decimal tubularMultiplier = 1.0m;
            switch (tubular)
            {
                case "1x1": tubularMultiplier = 1.0m; break;
                case "1.5x1.5": tubularMultiplier = 1.2m; break;
                case "2x2": tubularMultiplier = 1.4m; break;
                default: tubularMultiplier = 1.0m; break;
            }

            // Height might affect complexity/extra material; apply a modest height factor
            decimal heightFactor = 1.0m + (Math.Max(0, height - 50) / 200m); // small increase for tall stands

            decimal subtotal = rawMaterialCost * stainlessMultiplier * tubularMultiplier * heightFactor;

            // Example additional fixed costs: fabrication, finish, tolerance
            decimal fabrication = Math.Max(5m, subtotal * 0.05m); // min 5
            decimal finish = Math.Max(2m, subtotal * 0.02m);

            decimal total = subtotal + fabrication + finish;

            var sb = new System.Text.StringBuilder();
            sb.AppendLine($"Length: {length}");
            sb.AppendLine($"Width: {width}");
            sb.AppendLine($"Height: {height}");
            sb.AppendLine($"Layers: {layers}");
            sb.AppendLine($"Tubular: {tubular}");
            sb.AppendLine($"Stainless: {(stainless ? "Yes" : "No")}");
            sb.AppendLine();
            sb.AppendLine($"Area per layer: {areaPerLayer:N0} sq.units");
            sb.AppendLine($"Raw material cost (area x layers x ₱{baseUnitCost:0.00}): ₱{rawMaterialCost:0.00}");
            sb.AppendLine($"Stainless multiplier: {stainlessMultiplier:0.##}");
            sb.AppendLine($"Tubular multiplier: {tubularMultiplier:0.##}");
            sb.AppendLine($"Height factor: {heightFactor:0.###}");
            sb.AppendLine($"Subtotal (after multipliers): ₱{subtotal:0.00}");
            sb.AppendLine($"Fabrication: ₱{fabrication:0.00}");
            sb.AppendLine($"Finish: ₱{finish:0.00}");

            return (decimal.Round(total, 2), sb.ToString());
        }

        /// <summary>
        /// Compute stand retail price following the requested formula.
        /// Inputs are in FEET (Lft, Wft, Hft) and n layers. Retail rate is selected by tubular size (₱/ft).
        /// Steps implemented:
        /// 1) Perimeter per layer (ft) = 2*(Lft+Wft)  -> total perimeter = per_layer * n
        /// 2) Uprights (ft) = 4 * Hft
        /// 3) Braces per frame = ceil(Lft / 3) (one brace per 3 ft)
        ///    Brace length per frame (ft) = braces_per_frame * Wft
        ///    Total brace length (ft) = brace_length_per_frame * n
        /// 4) Subtotal(ft) = total_perimeter + uprights + total_brace_length
        /// 5) Adjusted length = subtotal * 1.22 (wastage)
        /// 6) Retail price = adjusted_length * retail_rate (₱/ft)
        /// </summary>
        private (decimal price, string breakdown, decimal totalFeetConsumed) ComputeStandRetailPrice(decimal Lft, decimal Wft, decimal Hft, int n, string tubular, bool stainless, decimal sumpWidthFt)
        {
            // Step 1: perimeter per layer (ft)
            decimal perimeterPerLayerFt = 2m * (Lft + Wft);
            decimal totalPerimeterFt = perimeterPerLayerFt * n;

            // Step 2: uprights (4 uprights per frame, height already in ft)
            decimal uprightsFt = 4m * Hft;

            // Step 3: braces
            // braces per frame = ceil(Lft / 3) (3 ft per brace)
            int bracesPerFrame = (int)System.Math.Ceiling(Lft / 3m);
            decimal braceLengthPerFrameFt = bracesPerFrame * Wft;
            decimal totalBraceLengthFt = braceLengthPerFrameFt * n;

            // Step 4: subtotal
            decimal subtotalFt = totalPerimeterFt + uprightsFt + totalBraceLengthFt;

            // Step 5: wastage factor
            decimal adjustedFt = subtotalFt * 1.22m;

            // Step 6: retail rate lookup
            decimal ratePerFt = 0m;
            try
            {
                var key = tubular ?? "1x1";
                if (!TubularRetailRates.TryGetValue(key, out ratePerFt)) ratePerFt = TubularRetailRates["1x1"];
            }
            catch { ratePerFt = 80.0m; }

            // If stainless is requested, increase the rate by 3x
            if (stainless)
            {
                ratePerFt *= 3m;
            }

            decimal retailPrice = adjustedFt * ratePerFt;

            decimal totalAdjustedFeet = adjustedFt;

            var sb = new System.Text.StringBuilder();

            // Sump holder calculations (if sumpWidthFt > 0)
            if (sumpWidthFt > 0m)
            {
                // Following formulas provided (converted to feet since inputs here are feet):
                // P_sump = 2*(L + W_s) [ft]
                decimal P_sump = 2m * (Lft + sumpWidthFt);

                // U_sump = u * Hft (use u = 4 supports by default)
                int u = 2;
                decimal U_sump = u * Hft;

                // braces per frame: b = ceil(L_inches / 36) => in feet: ceil(Lft / 3)
                int b = (int)System.Math.Ceiling(Lft / 3m);
                decimal B_sump = b * sumpWidthFt;

                decimal T_sump = P_sump + U_sump + B_sump;
                decimal T_sump_adj = T_sump;// * 1.22m; // wastage same k

                decimal sumpRate = ratePerFt;
                if (stainless) sumpRate *= 3m;

                decimal costSump = T_sump_adj * sumpRate;

                // Add sump adjusted feet and cost to totals
                totalAdjustedFeet += T_sump_adj;
                retailPrice += costSump;

                sb.AppendLine();
                sb.AppendLine("Sump holder calculation:");
                sb.AppendLine($"Sump width: {sumpWidthFt:0.###} ft");
                sb.AppendLine($"Perimeter P_sump: {P_sump:0.###} ft");
                sb.AppendLine($"Uprights/supports U_sump: {U_sump:0.###} ft (u={u})");
                sb.AppendLine($"Braces per frame: {b}");
                sb.AppendLine($"Total brace length B_sump: {B_sump:0.###} ft");
                sb.AppendLine($"Subtotal T_sump: {T_sump:0.###} ft");
                sb.AppendLine($"Sump Cost = ₱{costSump:0.00}");
            }

            sb.AppendLine("Stand price calculation breakdown:");
            sb.AppendLine($"Length: {Lft:0.###} ft");
            sb.AppendLine($"Width : {Wft:0.###} ft");
            sb.AppendLine($"Height: {Hft:0.###} ft");
            sb.AppendLine($"Layers: {n}");
            sb.AppendLine($"Tubular size: {tubular}");
            sb.AppendLine($"Stainless: {(stainless ? "Yes" : "No")}");
            sb.AppendLine();
            sb.AppendLine($"Perimeter per layer: {perimeterPerLayerFt:0.###} ft");
            sb.AppendLine($"Total perimeter (all layers): {totalPerimeterFt:0.###} ft");
            sb.AppendLine($"Uprights (4 x H): {uprightsFt:0.###} ft");
            sb.AppendLine($"Braces per frame: {bracesPerFrame}");
            sb.AppendLine($"Brace length per frame: {braceLengthPerFrameFt:0.###} ft");
            sb.AppendLine($"Total brace length (all layers): {totalBraceLengthFt:0.###} ft");
            sb.AppendLine($"Subtotal tubular length: {subtotalFt:0.###} ft");
            sb.AppendLine($"Adjusted length {adjustedFt:0.###} ft");
            sb.AppendLine($"Retail price = ₱{retailPrice:0.00}");

            return (decimal.Round(retailPrice, 2), sb.ToString(), totalAdjustedFeet);
        }

        private double ConvertVolumeToGallons(decimal length, decimal width, decimal height, string unit)
        {
            double vol = (double)(length * width * height);
            if (string.Equals(unit, "Inches", StringComparison.OrdinalIgnoreCase))
            {
                // cubic inches -> gallons
                return vol / 231.0;
            }
            else if (string.Equals(unit, "CM", StringComparison.OrdinalIgnoreCase))
            {
                // cubic centimeters -> liters -> gallons
                double liters = vol / 1000.0;
                return liters * 0.264172;
            }
            else if (string.Equals(unit, "MM", StringComparison.OrdinalIgnoreCase))
            {
                // cubic millimeters -> cubic centimeters -> liters -> gallons
                double cm3 = vol / 1000.0;
                double liters = cm3 / 1000.0;
                return liters * 0.264172;
            }
            else if (string.Equals(unit, "Ft", StringComparison.OrdinalIgnoreCase))
            {
                // cubic feet to gallons (US): 1 cubic foot = 7.48052 gallons
                return vol * 7.48052;
            }
            return 0.0;
        }
    }
}
