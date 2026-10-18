using System;
using System.Windows.Forms;

namespace AquariumPOS
{
    /// <summary>
    /// Base for every POS window (and the small inline dialogs built with "new ThemedForm { ... }"):
    /// applies the portal look (UiTheme) right after Load - before the window is first shown - so
    /// controls built in the constructor or a Load handler are themed, and later ones via UiTheme's hooks.
    /// </summary>
    public class ThemedForm : Form
    {
        protected override void OnLoad(EventArgs e)
        {
            base.OnLoad(e);
            UiTheme.Apply(this);
        }
    }
}
