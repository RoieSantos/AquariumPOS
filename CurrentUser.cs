namespace AquariumPOS
{
    public static class CurrentUser
    {
        public static string? Username { get; set; }
        public static string? FullName { get; set; }
        public static string? Role { get; set; }
        public static bool IsManager { get; set; } = false;
        public static bool IsSuperUser { get; set; } = false;

        public static string GetEffectiveUsername(string fallback = "SYSTEM")
        {
            string userName = Username?.Trim() ?? string.Empty;
            return string.IsNullOrWhiteSpace(userName) ? fallback : userName;
        }
    }
}
