using System;
using System.Data.SqlClient;
using System.Drawing;
using System.Windows.Forms;
using System.Collections.Generic;

namespace AquariumPOS
{
    public partial class LoginForm : Form
    {
        private string GetLocalIPAddress()
        {
            try
            {
                var host = System.Net.Dns.GetHostEntry(System.Net.Dns.GetHostName());
                foreach (var ip in host.AddressList)
                {
                    if (ip.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork)
                        return ip.ToString();
                }
            }
            catch { }
            return "";
        }

    private readonly string connectionString = GlobalSettings.ConnectionString;
        private Label titleLabel = null!;
        private Panel loginPanel = null!;
        private Label usernameLabel = null!;
        private Label passwordLabel = null!;
        private TextBox usernameTextBox = null!;
        private TextBox passwordTextBox = null!;
        private Button loginButton = null!;
        private Button floatEntryButton = null!;
        private Button exitButton = null!;
        private Label statusLabel = null!;

        public LoginForm()
        {
            KeyPreview = true;
            this.KeyDown += LoginForm_KeyDown;

            InitializeComponent();
            // Clear credentials whenever the login form is shown or becomes visible
            this.Shown += (s, e) => ClearLoginFields();
            this.VisibleChanged += (s, e) => { if (this.Visible) ClearLoginFields(); };
            CreateTables();
            CreateTransactionHeaderTable();
        }

        private void ClearLoginFields()
        {
            try
            {
                usernameTextBox.Text = "";
                passwordTextBox.Text = "";
                statusLabel.Text = "Please enter your credentials";
                statusLabel.ForeColor = Color.Gray;
                usernameTextBox.Focus();
            }
            catch { }
        }

        private void InitializeComponent()
        {
            this.Text = "RS Pet Stop - Login";
            this.Size = new Size(500, 400);
            this.StartPosition = FormStartPosition.CenterScreen;
            this.BackColor = Color.White;
            this.FormBorderStyle = FormBorderStyle.FixedDialog;
            this.MaximizeBox = false;
            this.MinimizeBox = false;

            // Title Label
            titleLabel = new Label
            {
                Text = "RS PET STOP - AQUARIUM POS",
                Location = new Point(50, 30),
                Size = new Size(400, 35),
                Font = new Font("Arial", 16, FontStyle.Bold),
                ForeColor = Color.DarkBlue,
                TextAlign = ContentAlignment.MiddleCenter
            };

            // Login Panel
            loginPanel = new Panel
            {
                Location = new Point(75, 80),
                Size = new Size(350, 200),
                BackColor = Color.LightGray,
                BorderStyle = BorderStyle.FixedSingle
            };

            // Username Label
            usernameLabel = new Label
            {
                Text = "Username:",
                Location = new Point(30, 30),
                Size = new Size(80, 25),
                Font = new Font("Arial", 10, FontStyle.Bold),
                TextAlign = ContentAlignment.MiddleLeft
            };

            // Username TextBox
            usernameTextBox = new TextBox
            {
                Location = new Point(120, 30),
                Size = new Size(200, 25),
                Font = new Font("Arial", 10)
            };

            // Password Label
            passwordLabel = new Label
            {
                Text = "Password:",
                Location = new Point(30, 70),
                Size = new Size(80, 25),
                Font = new Font("Arial", 10, FontStyle.Bold),
                TextAlign = ContentAlignment.MiddleLeft
            };

            // Password TextBox
            passwordTextBox = new TextBox
            {
                Location = new Point(120, 70),
                Size = new Size(200, 25),
                Font = new Font("Arial", 10),
                PasswordChar = '*'
            };

            // Login Button
            loginButton = new Button
            {
                Text = "Login",
                Location = new Point(120, 120),
                Size = new Size(80, 35),
                BackColor = Color.Green,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold)
            };
            loginButton.Click += LoginButton_Click;

            // Float Entry Button
            floatEntryButton = new Button
            {
                Text = "Float Entry",
                Location = new Point(210, 120),
                Size = new Size(80, 35),
                BackColor = Color.Blue,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold)
            };
            floatEntryButton.Click += FloatEntryButton_Click;

            // Exit Button
            exitButton = new Button
            {
                Text = "Exit",
                Location = new Point(200, 300),
                Size = new Size(100, 35),
                BackColor = Color.Red,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold)
            };
            exitButton.Click += (s, e) => Application.Exit();

            // Status Label
            statusLabel = new Label
            {
                Text = "Please enter your credentials",
                Location = new Point(50, 350),
                Size = new Size(400, 20),
                Font = new Font("Arial", 9, FontStyle.Italic),
                ForeColor = Color.Gray,
                TextAlign = ContentAlignment.MiddleCenter
            };

            // Add controls to login panel
            loginPanel.Controls.AddRange(new Control[] {
                usernameLabel, usernameTextBox, passwordLabel, passwordTextBox,
                loginButton, floatEntryButton
            });

            // Add controls to form
            this.Controls.AddRange(new Control[] {
                titleLabel, loginPanel, exitButton, statusLabel
            });

            // Set enter key behavior
            usernameTextBox.KeyPress += (s, e) => { if (e.KeyChar == (char)Keys.Enter) passwordTextBox.Focus(); };
            passwordTextBox.KeyPress += (s, e) => { if (e.KeyChar == (char)Keys.Enter) loginButton.PerformClick(); };

            // Ensure username textbox has initial focus when the form is shown
            try { this.ActiveControl = usernameTextBox; usernameTextBox.Focus(); } catch { }
        }

        private void CreateTables()
        {
            try
            {
                using (var connection = new SqlConnection(connectionString))
                {
                    connection.Open();

                    // Create UserSetup table
                    var createUserSetupTable = @"
                        IF NOT EXISTS (SELECT * FROM sysobjects WHERE name='UserSetup' AND xtype='U')
                        CREATE TABLE UserSetup (
                            ID NVARCHAR(50) PRIMARY KEY,
                            Password NVARCHAR(255) NOT NULL,
                            Name NVARCHAR(100),
                            Manager NVARCHAR(50),
                            SuperUser BIT DEFAULT 0,
                            IsActive BIT DEFAULT 1,
                            CreatedDate DATETIME DEFAULT GETDATE(),
                            LastLoginDate DATETIME
                        )";

                    using (var cmd = new SqlCommand(createUserSetupTable, connection))
                    {
                        cmd.ExecuteNonQuery();
                    }

                    // Create LoginLogs table with updated fields
                    var createLoginLogsTable = @"
                        IF NOT EXISTS (SELECT * FROM sysobjects WHERE name='LoginLogs' AND xtype='U')
                        CREATE TABLE LoginLogs (
                            EntryID INT IDENTITY(1,1) PRIMARY KEY,
                            LogID INT,
                            ID NVARCHAR(50),
                            UserName NVARCHAR(100),
                            LoginTime DATETIME,
                            LogoutTime DATETIME,
                            StoreNo NVARCHAR(20),
                            PosTerminalNo NVARCHAR(20),
                            IsSuccessful BIT,
                            IPAddress NVARCHAR(50),
                            Notes NVARCHAR(255)
                        )";

                    using (var cmd = new SqlCommand(createLoginLogsTable, connection))
                    {
                        cmd.ExecuteNonQuery();
                    }

                    // Check if EntryID column exists, if not add it and make it primary key
                    var checkEntryIDQuery = @"
                        IF NOT EXISTS (SELECT * FROM INFORMATION_SCHEMA.COLUMNS 
                                     WHERE TABLE_NAME = 'LoginLogs' AND COLUMN_NAME = 'EntryID')
                        BEGIN
                            -- Drop existing primary key constraint if it exists
                            IF EXISTS (SELECT * FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS 
                                     WHERE TABLE_NAME = 'LoginLogs' AND CONSTRAINT_TYPE = 'PRIMARY KEY')
                            BEGIN
                                ALTER TABLE LoginLogs DROP CONSTRAINT PK__LoginLogs__5E5499A80F3E0E11;
                            END
                            
                            -- Add EntryID column as identity and primary key
                            ALTER TABLE LoginLogs ADD EntryID INT IDENTITY(1,1) PRIMARY KEY;
                        END";

                    using (var checkCmd = new SqlCommand(checkEntryIDQuery, connection))
                    {
                        try
                        {
                            checkCmd.ExecuteNonQuery();
                        }
                        catch (Exception)
                        {
                            // If alter fails, it might be because the constraint name is different
                            // Try a more generic approach
                            var genericAlterQuery = @"
                                IF NOT EXISTS (SELECT * FROM INFORMATION_SCHEMA.COLUMNS 
                                             WHERE TABLE_NAME = 'LoginLogs' AND COLUMN_NAME = 'EntryID')
                                BEGIN
                                    ALTER TABLE LoginLogs ADD EntryID INT IDENTITY(1,1);
                                END";
                            using (var genericCmd = new SqlCommand(genericAlterQuery, connection))
                            {
                                genericCmd.ExecuteNonQuery();
                            }
                        }
                    }

                    // Create CashFloatLines table
                    var createCashFloatTable = @"
                        IF NOT EXISTS (SELECT * FROM sysobjects WHERE name='CashFloatLines' AND xtype='U')
                        CREATE TABLE CashFloatLines (
                            EntryNo INT IDENTITY(1,1) PRIMARY KEY,
                            Username NVARCHAR(50) NOT NULL,
                            Denomination DECIMAL(10,2) NOT NULL,
                            Count INT NOT NULL,
                            Total DECIMAL(10,2) NOT NULL,
                            EntryDate DATETIME NOT NULL DEFAULT GETDATE()
                        )";

                    using (var cmd = new SqlCommand(createCashFloatTable, connection))
                    {
                        cmd.ExecuteNonQuery();
                    }

                    // Insert default admin user if not exists
                    var checkAdminQuery = "SELECT COUNT(*) FROM UserSetup WHERE ID = 'admin'";
                    using (var checkCmd = new SqlCommand(checkAdminQuery, connection))
                    {
                        int count = (int)checkCmd.ExecuteScalar();
                        if (count == 0)
                        {
                            var insertAdminQuery = @"
                                INSERT INTO UserSetup (ID, Password, Name, Manager, SuperUser, IsActive)
                                VALUES ('admin', 'admin123', 'System Administrator', NULL, 1, 1)";

                            using (var insertCmd = new SqlCommand(insertAdminQuery, connection))
                            {
                                insertCmd.ExecuteNonQuery();
                            }
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Database initialization error: {ex.Message}\n\nDetails: {ex.InnerException?.Message}",
                              "Database Error", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
        }

        private void LoginButton_Click(object? sender, EventArgs e)
        {
            string username = usernameTextBox.Text.Trim();
            string password = passwordTextBox.Text;

            if (string.IsNullOrEmpty(username) || string.IsNullOrEmpty(password))
            {
                statusLabel.Text = "Please enter both username and password";
                statusLabel.ForeColor = Color.Red;
                return;
            }

            try
            {
                using (var connection = new SqlConnection(connectionString))
                {
                    connection.Open();

                    // NOTE: Float entry requirement is enforced after successful authentication
                    // so admin/super users can bypass float requirement.

                    var query = @"SELECT ID, Name, Manager, SuperUser, IsActive FROM UserSetup 
                                 WHERE ID = @username AND Password = @password";

                    using (var cmd = new SqlCommand(query, connection))
                    {
                        cmd.Parameters.AddWithValue("@username", username);
                        cmd.Parameters.AddWithValue("@password", password);

                        using (var reader = cmd.ExecuteReader())
                        {
                            if (reader.Read())
                            {
                                bool isActive = Convert.ToBoolean(reader["IsActive"]);
                                if (!isActive)
                                {
                                    statusLabel.Text = "Account is disabled. Contact administrator.";
                                    statusLabel.ForeColor = Color.Red;
                                    return;
                                }

                                // Set current user
                                CurrentUser.Username = reader["ID"].ToString() ?? "";
                                CurrentUser.FullName = reader["Name"].ToString() ?? "";
                                CurrentUser.IsManager = !string.IsNullOrEmpty(reader["Manager"].ToString());
                                CurrentUser.IsSuperUser = Convert.ToBoolean(reader["SuperUser"]);

                                // Store the username for later use
                                string currentUsername = CurrentUser.Username;
                                string currentFullName = CurrentUser.FullName;

                                reader.Close();

                                // Update last login time
                                var updateQuery = "UPDATE UserSetup SET LastLoginDate = GETDATE() WHERE ID = @username";
                                using (var updateCmd = new SqlCommand(updateQuery, connection))
                                {
                                    updateCmd.Parameters.AddWithValue("@username", username);
                                    updateCmd.ExecuteNonQuery();
                                }

                                // Log successful login
                                var logQuery = @"INSERT INTO LoginLogs (ID, UserName, LoginTime, IsSuccessful, IPAddress, Notes)
                                               VALUES (@id, @userName, @loginTime, @isSuccessful, @ipAddress, @notes)";
                                using (var logCmd = new SqlCommand(logQuery, connection))
                                {
                                    logCmd.Parameters.AddWithValue("@id", currentUsername);
                                    logCmd.Parameters.AddWithValue("@userName", currentFullName ?? "");
                                    logCmd.Parameters.AddWithValue("@loginTime", DateTime.Now);
                                    logCmd.Parameters.AddWithValue("@isSuccessful", true);
                                    logCmd.Parameters.AddWithValue("@ipAddress", GetLocalIPAddress());
                                    logCmd.Parameters.AddWithValue("@notes", "Login Success");
                                    logCmd.ExecuteNonQuery();
                                }

                                // After successful authentication, require Float Entry only for non-super users
                                if (!CurrentUser.IsSuperUser)
                                {
                                    // Check if user has transaction header entry today for Float_Entry
                                    var floatEntryQuery = @"SELECT COUNT(*) FROM TransactionHeader WHERE UserID = @username AND (EODID IS NULL OR EODID = '') AND Type = 'Float_Entry'";
                                    using (var floatCmd = new SqlCommand(floatEntryQuery, connection))
                                    {
                                        floatCmd.Parameters.AddWithValue("@username", currentUsername);
                                        int floatCount = (int)floatCmd.ExecuteScalar();
                                        if (floatCount == 0)
                                        {
                                            // Prompt user to perform float entry now
                                            var doFloat = MessageBox.Show("Float entry has not been recorded for today. Would you like to perform Float Entry now?", "Float Entry Required", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
                                            if (doFloat == DialogResult.Yes)
                                            {
                                                var floatForm = new FloatEntryForm(currentUsername, this);
                                                this.Hide();
                                                var dr = floatForm.ShowDialog(this);
                                                if (dr == DialogResult.OK)
                                                {
                                                    // After successful float entry open main form
                                                    var mf = new MainForm();
                                                    mf.FormClosed += (s2, args2) => this.Close();
                                                    mf.Show();
                                                    return;
                                                }
                                                else
                                                {
                                                    // Float entry was cancelled; show login form again
                                                    this.Show();
                                                    usernameTextBox.Text = "";
                                                    passwordTextBox.Text = "";
                                                    usernameTextBox.Focus();
                                                    return;
                                                }
                                            }
                                            else
                                            {
                                                // User chose not to do float entry: cancel login
                                                statusLabel.Text = "Float entry required to proceed.";
                                                statusLabel.ForeColor = Color.Red;
                                                usernameTextBox.Text = "";
                                                passwordTextBox.Text = "";
                                                usernameTextBox.Focus();
                                                return;
                                            }
                                        }
                                    }
                                }

                                // Open main form
                                var mainForm = new MainForm();
                                this.Hide();
                                mainForm.FormClosed += (s, args) => this.Close();
                                mainForm.Show();
                                return; // Exit the method after successful login
                            }
                        } // end using reader

                        // If we reach here, login failed
                        statusLabel.Text = "Invalid username or password";
                        statusLabel.ForeColor = Color.Red;

                        // Log failed login attempt
                        var failedLogQuery = @"INSERT INTO LoginLogs (ID, UserName, LoginTime, IsSuccessful, IPAddress, Notes)
                                             VALUES (@id, @userName, @loginTime, @isSuccessful, @ipAddress, @notes)";
                        using (var failedLogCmd = new SqlCommand(failedLogQuery, connection))
                        {
                            failedLogCmd.Parameters.AddWithValue("@id", username);
                            failedLogCmd.Parameters.AddWithValue("@userName", "");
                            failedLogCmd.Parameters.AddWithValue("@loginTime", DateTime.Now);
                            failedLogCmd.Parameters.AddWithValue("@isSuccessful", false);
                            failedLogCmd.Parameters.AddWithValue("@ipAddress", GetLocalIPAddress());
                            failedLogCmd.Parameters.AddWithValue("@notes", "Login Failed");
                            failedLogCmd.ExecuteNonQuery();
                        }
                        usernameTextBox.Text = "";
                        passwordTextBox.Text = "";
                        usernameTextBox.Focus();
                    } // end using cmd
                } // end using connection
            } // end try
            catch (Exception ex)
            {
                statusLabel.Text = $"Login error: {ex.Message}";
                statusLabel.ForeColor = Color.Red;

                // Show detailed error in a message box for debugging
                MessageBox.Show($"Login Error Details:\n\n{ex.Message}\n\nStack Trace:\n{ex.StackTrace}",
                               "Login Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void FloatEntryButton_Click(object? sender, EventArgs e)
        {
            string username = usernameTextBox.Text.Trim();
            string password = passwordTextBox.Text.Trim();
            bool isValid = false;
            try
            {
                using (var connection = new SqlConnection(connectionString))
                {
                    connection.Open();
                    var query = "SELECT COUNT(*) FROM UserSetup WHERE ID = @username AND Password = @password";
                    using (var cmd = new SqlCommand(query, connection))
                    {
                        cmd.Parameters.AddWithValue("@username", username);
                        cmd.Parameters.AddWithValue("@password", password);
                        int count = (int)cmd.ExecuteScalar();
                        isValid = count > 0;
                    }
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Error validating credentials: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }
            if (isValid)
                {
                    var floatForm = new FloatEntryForm(username, this);
                    floatForm.ShowDialog(this);
                }
            else
            {
                MessageBox.Show("Invalid username or password. Please enter valid credentials to access Float Entry.", "Access Denied", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
        }

        private void CreateTransactionHeaderTable()
        {
            try
            {
                using (var connection = new SqlConnection(connectionString))
                {
                    connection.Open();
                    var cmd = new SqlCommand(@"
                        IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'TransactionHeader')
                        BEGIN
                            CREATE TABLE TransactionHeader (
                                StoreNo NVARCHAR(20) NOT NULL,
                                POSTerminalNo NVARCHAR(20) NOT NULL,
                                TransactionNo INT NOT NULL,
                                ReceiptNo NVARCHAR(50),
                                Type NVARCHAR(20),
                                Quantity INT,
                                Price DECIMAL(18,2),
                                Discount DECIMAL(18,2),
                                GrossAmount DECIMAL(18,2),
                                NetAmount DECIMAL(18,2),
                                Date DATE,
                                Time TIME,
                                UserID NVARCHAR(50),
                                Description NVARCHAR(255),
                                ExpenseCategory NVARCHAR(100),
                                CONSTRAINT PK_TransactionHeader PRIMARY KEY (StoreNo, POSTerminalNo, TransactionNo)
                            )
                        END
                    ", connection);
                    cmd.ExecuteNonQuery();
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Error creating TransactionHeader table: {ex.Message}", "DB Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void LoginForm_KeyDown(object? sender, KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Escape)
            {
                Application.Exit();
            }
        }
    }
}