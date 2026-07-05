# Aquarium Shop POS System

This is a C# console-based Point of Sale (POS) system for an aquarium shop. The project is structured for future expansion, including modules for inventory management, sales, customer management, and reporting.

## Getting Started

- Make sure you have the .NET SDK installed.
- To run the application, use:
  ```powershell
  dotnet run
  ```
d
## Project Structure
- `Program.cs`: Entry point for the application.
- Future modules will be added for inventory, sales, customers, and reporting.

## Desktop shortcut

If you want a convenient Desktop shortcut to the built application, there's a helper PowerShell script included at the project root:

- `create_desktop_shortcut.ps1` — searches the project for the built executable (e.g. in `bin\Debug\net7.0-windows` or `bin\Release\net7.0-windows` or `publish`) and creates a `.lnk` on the current user's Desktop.

Usage:

1. Build the project:
  ```powershell
  dotnet build
  ```
2. From the project root run:
  ```powershell
  .\create_desktop_shortcut.ps1
  ```

Note: If you have an execution policy that blocks scripts, run PowerShell with the appropriate permission (for example, use the Bypass flag for a single invocation):

```powershell
powershell -ExecutionPolicy Bypass -File .\create_desktop_shortcut.ps1
```

## Next Steps
- Expand the system with additional modules as needed.
