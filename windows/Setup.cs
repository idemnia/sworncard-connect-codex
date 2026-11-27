using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

[assembly: System.Runtime.Versioning.TargetFramework(".NETFramework,Version=v4.8")]

internal static class Setup {
    const string Endpoint = "https://connect.sworncard.ru/mcp";
    const string Plugin = "sworncard-connect@sworncard-connect";
    const string Title = "SwornCard · Подключение к Codex";
    static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = 8 * 1024 * 1024 };
    internal static readonly Regex Token = new Regex(@"\Ascpat1\.(pc_[A-Za-z0-9_-]{43})\.[A-Za-z0-9_-]{43}\z");

    sealed class SetupError : Exception { public SetupError(string text) : base(text) {} }

    static object Get(object obj, params string[] keys) {
        foreach (string key in keys) {
            var map = obj as IDictionary<string, object>;
            if (map == null || !map.TryGetValue(key, out obj)) return null;
        }
        return obj;
    }

    [DllImport("kernel32", CharSet = CharSet.Unicode, ExactSpelling = true)]
    static extern int GetPackagesByPackageFamily(string family, ref int count, IntPtr names, ref int chars, IntPtr buffer);
    [DllImport("kernel32", CharSet = CharSet.Unicode, ExactSpelling = true)]
    static extern int GetPackagePathByFullName(string name, ref int count, StringBuilder path);

    // Windows resolves the registered publisher and package for the current user.
    internal static string DesktopBinary() {
        const string family = "OpenAI.Codex_2p2nqsd0c76g0";
        const int insufficientBuffer = 122;
        int count = 0, chars = 0;
        var missing = new SetupError("Не найден установленный Codex Desktop для Windows.");
        if (GetPackagesByPackageFamily(family, ref count, IntPtr.Zero, ref chars, IntPtr.Zero) != insufficientBuffer || count < 1) throw missing;
        IntPtr names = Marshal.AllocHGlobal(checked(count * IntPtr.Size));
        IntPtr buffer = Marshal.AllocHGlobal(checked(chars * 2));
        try {
            if (GetPackagesByPackageFamily(family, ref count, names, ref chars, buffer) != 0) throw missing;
            for (int i = 0; i < count; i++) {
                string fullName = Marshal.PtrToStringUni(Marshal.ReadIntPtr(names, i * IntPtr.Size));
                int length = 0;
                if (GetPackagePathByFullName(fullName, ref length, null) != insufficientBuffer) continue;
                var path = new StringBuilder(length);
                if (GetPackagePathByFullName(fullName, ref length, path) != 0) continue;
                string exe = Path.Combine(path.ToString(), @"app\resources\codex.exe");
                if (File.Exists(exe)) return exe;
            }
            throw missing;
        } finally { Marshal.FreeHGlobal(buffer); Marshal.FreeHGlobal(names); }
    }

    static Process Start(string exe, string arguments) {
        var info = new ProcessStartInfo(exe, arguments) {
            UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = Environment.SystemDirectory,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
            StandardOutputEncoding = new UTF8Encoding(false)
        };
        var env = info.EnvironmentVariables;
        env.Clear();
        foreach (string key in new[] {"SystemRoot","SystemDrive","TEMP","TMP","USERPROFILE","APPDATA","LOCALAPPDATA","PROGRAMDATA","CODEX_HOME"}) {
            string value = Environment.GetEnvironmentVariable(key);
            if (value != null) env[key] = value;
        }
        env["PATH"] = Environment.SystemDirectory;
        var p = Process.Start(info);
        p.StandardInput.AutoFlush = true;
        p.ErrorDataReceived += delegate { }; // Diagnostics may contain config. Do not forward them.
        p.BeginErrorReadLine();
        return p;
    }

    static void Stop(Process p) {
        try { p.StandardInput.Close(); if (!p.WaitForExit(1000)) p.Kill(); }
        catch (InvalidOperationException) { /* Already exited. */ }
    }

    static readonly HashSet<string> Trusted = new HashSet<string> {
        WindowsIdentity.GetCurrent().User.Value, "S-1-5-18", "S-1-5-32-544", "S-1-3-0", "S-1-3-4"
    };

    static void CheckAcl(FileSystemSecurity acl) {
        var descriptor = new RawSecurityDescriptor(acl.GetSecurityDescriptorBinaryForm(), 0);
        if (descriptor.DiscretionaryAcl == null || !Trusted.Contains(acl.GetOwner(typeof(SecurityIdentifier)).Value))
            throw new SetupError("Проверьте владельца и права записи в личном профиле Windows.");
        const FileSystemRights writes = FileSystemRights.Write | FileSystemRights.Delete |
            FileSystemRights.DeleteSubdirectoriesAndFiles | FileSystemRights.ChangePermissions | FileSystemRights.TakeOwnership;
        foreach (FileSystemAccessRule rule in acl.GetAccessRules(true, true, typeof(SecurityIdentifier))) {
            if (rule.AccessControlType == AccessControlType.Allow && !Trusted.Contains(rule.IdentityReference.Value) &&
                (rule.FileSystemRights & writes) != 0)
                throw new SetupError("Другой пользователь может менять настройки подключения. PAT не сохранён.");
        }
    }

    static void CheckDirectory(string directory) {
        string user = Path.GetFullPath(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)).TrimEnd('\\');
        if (!Path.IsPathRooted(directory)) throw new SetupError("Нужен локальный личный профиль Codex.");
        var path = new DirectoryInfo(directory);
        if (path.FullName.StartsWith(@"\\") || !path.FullName.StartsWith(user + "\\", StringComparison.OrdinalIgnoreCase))
            throw new SetupError("Нужен профиль в каталоге вашего пользователя Windows.");
        for (; path != null; path = path.Parent) {
            if ((path.Attributes & FileAttributes.ReparsePoint) != 0)
                throw new SetupError("Каталог личных настроек находится за файловой ссылкой.");
            CheckAcl(path.GetAccessControl());
            if (String.Equals(path.FullName, user, StringComparison.OrdinalIgnoreCase)) break;
        }
    }

    static void CheckFile(string path) {
        if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
            throw new SetupError("Файл личных настроек является ссылкой.");
        CheckAcl(File.GetAccessControl(path));
    }

    static void CheckProfile() {
        string home = Environment.GetEnvironmentVariable("CODEX_HOME") ??
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex");
        CheckDirectory(home);
        string config = Path.Combine(home, "config.toml");
        if (File.Exists(config)) CheckFile(config);
    }

    // A stable per-user path keeps existing connections working across plugin cache upgrades.
    static string InstallProvider() {
        string directory = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        CheckDirectory(directory);
        foreach (string part in new[]{"SwornCard", "Codex"}) {
            directory = Path.Combine(directory, part);
            Directory.CreateDirectory(directory);
            CheckDirectory(directory);
        }
        string destination = Path.Combine(directory, "SwornCardSetup.exe");
        if (destination.IndexOfAny(new[]{'%', '!', '"', '\r', '\n'}) >= 0)
            throw new SetupError("Путь к личной папке приложений несовместим с командой Codex.");
        string source = Application.ExecutablePath;
        if (File.Exists(destination)) {
            CheckFile(destination);
            using (var hash = SHA256.Create())
            using (var current = File.OpenRead(destination))
            using (var shipped = File.OpenRead(source))
                if (hash.ComputeHash(current).SequenceEqual(hash.ComputeHash(shipped))) return destination;
        }
        string temp = Path.Combine(directory, Guid.NewGuid().ToString("N") + ".tmp");
        try {
            File.Copy(source, temp);
            if (File.Exists(destination)) File.Replace(temp, destination, null);
            else File.Move(temp, destination);
            CheckFile(destination);
        } finally { if (File.Exists(temp)) File.Delete(temp); }
        return destination;
    }

    static async Task<object> Rpc(Process p, int id, string method, object args) {
        await p.StandardInput.WriteLineAsync(Json.Serialize(new {id, method, @params = args}));
        for (;;) {
            string line = await p.StandardOutput.ReadLineAsync();
            if (line == null) break;
            object reply = Json.DeserializeObject(line);
            if (!Equals(Get(reply, "id"), id)) continue;
            if (Get(reply, "error") != null) break;
            return Get(reply, "result");
        }
        throw new SetupError("Codex не подтвердил изменение. Можно повторить настройку.");
    }

    static async Task WriteSettings(Process p, string connection, string secret) {
        string server = "sworncard_" + connection;
        await Rpc(p, 1, "initialize", new {clientInfo = new {name = "sworncard-setup", version = "1"}});
        await p.StandardInput.WriteLineAsync("{\"method\":\"initialized\"}");
        object read = await Rpc(p, 2, "config/read", new {includeLayers = true});
        var layers = ((IEnumerable)Get(read, "layers")).Cast<object>().ToList();
        object personal = layers.Single(layer => Equals(Get(layer, "name", "type"), "user"));
        string version = Get(personal, "version") as string;
        if (String.IsNullOrEmpty(version)) throw new SetupError("Codex не подтвердил версию личного профиля.");
        string provider = "\"" + InstallProvider() + "\" --mcp-headers " + connection;
        foreach (object layer in layers) {
            object entry = Get(layer, "config", "mcp_servers", server);
            if (entry == null) continue;
            var map = entry as IDictionary<string, object>;
            var headers = Get(entry, "http_headers") as IDictionary<string, object>;
            var oldHeader = Get(headers, "Authorization") as string;
            bool previousHeader = headers != null && headers.Count == 1 && oldHeader != null &&
                oldHeader.StartsWith("Bearer ", StringComparison.Ordinal) &&
                Token.Match(oldHeader.Substring(7)).Groups[1].Value == connection;
            bool ownProvider = Equals(Get(entry, "http_headers_helper"), provider);
            if (layer != personal || map == null || map.Count != 2 || !Equals(Get(entry, "url"), Endpoint) ||
                (!previousHeader && !ownProvider))
                throw new SetupError("У этого подключения уже есть другие настройки MCP. Они сохранены.");
        }
        var edits = new List<object> { new {
            keyPath = "mcp_servers." + server, mergeStrategy = "replace",
            value = new { url = Endpoint, http_headers_helper = provider }
        }};
        object plugin = Get(personal, "config", "plugins", Plugin);
        string legacy = Environment.GetEnvironmentVariable("SWORNCARD_CONNECT_PAT");
        bool sameConnection = legacy != null && Token.Match(legacy).Success &&
            "sworncard_" + Token.Match(legacy).Groups[1].Value == server;
        if (Equals(Get(plugin, "enabled"), true) &&
            (sameConnection || (String.IsNullOrEmpty(legacy) && Get(plugin, "mcp_servers", "sworncard", "enabled") == null)))
            edits.Add(new {keyPath = "plugins." + Plugin + ".mcp_servers.sworncard.enabled", value = false, mergeStrategy = "replace"});
        // Staging a credential first preserves a working legacy configuration if the CAS fails.
        // A retry writes the same connection slot and finishes the same registration.
        try { WindowsCredential.Save(connection, secret); }
        catch (IOException) { throw new SetupError("Диспетчер учётных данных Windows не подтвердил сохранение PAT."); }
        object written = await Rpc(p, 3, "config/batchWrite", new {edits, expectedVersion = version});
        if (!Equals(Get(written, "status"), "ok")) throw new SetupError("Личная настройка переопределена политикой Codex.");
    }

    static async Task Save(string secret) {
        var match = Token.Match(secret);
        if (!match.Success) throw new SetupError("Скопируйте весь PAT из кабинета Idemnia.");
        CheckProfile();
        string binary = DesktopBinary();
        using (var p = Start(binary, "app-server --listen stdio://")) {
            try {
                var work = WriteSettings(p, match.Groups[1].Value, secret);
                if (await Task.WhenAny(work, Task.Delay(25000)) != work)
                    throw new SetupError("Codex не ответил вовремя. Можно повторить настройку.");
                await work;
            }
            finally { Stop(p); }
        }
    }

    [STAThread]
    static int Main(string[] args) {
        if (args.Length == 2 && args[0] == "--mcp-headers") return WindowsCredential.Supply(args[1]);
        if (args.Length != 0 || !Environment.UserInteractive) return 2;
        Application.EnableVisualStyles();
        try {
            string manifest = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, @"..\..\..\.mcp.json");
            if (!Equals(Get(Json.DeserializeObject(File.ReadAllText(manifest)), "mcpServers", "sworncard", "url"), Endpoint))
                throw new InvalidDataException();
        } catch {
            MessageBox.Show("Откройте настройку из установленного RU-плагина SwornCard.", Title);
            return 2;
        }
        using (var form = new Form {Text = Title, StartPosition = FormStartPosition.CenterScreen,
                FormBorderStyle = FormBorderStyle.FixedDialog, MinimizeBox = false, MaximizeBox = false,
                ClientSize = new Size(466,220), AutoScaleMode = AutoScaleMode.Font}) {
            var prompt = new Label {Text = "Вставьте PAT подключения из кабинета Idemnia.\r\nСервер: " + Endpoint, AutoSize = true, Left = 16, Top = 15};
            var token = new TextBox {Name = "PersonalAccessToken", AccessibleName = "PAT", UseSystemPasswordChar = true, Left = 16, Top = 62, Width = 430};
            var status = new Label {Name = "Status", Text = "Токен будет сохранён в Диспетчере учётных данных Windows для вашего пользователя.", Left = 16, Top = 99, Width = 430, Height = 60};
            var save = new Button {Name = "Save", Text = "Сохранить", Left = 233, Top = 174, Width = 105};
            var cancel = new Button {Name = "Cancel", Text = "Отмена", Left = 346, Top = 174, Width = 100, DialogResult = DialogResult.Cancel};
            form.Controls.AddRange(new Control[]{prompt, token, status, save, cancel});
            form.AcceptButton = save; form.CancelButton = cancel;
            int result = 1;
            bool busy = false;
            form.FormClosing += (s,e) => { if (busy) e.Cancel = true; };
            save.Click += async (s,e) => {
                if (result == 0) { form.Close(); return; }
                busy = true; save.Enabled = cancel.Enabled = token.Enabled = false;
                try {
                    await Save(token.Text);
                    result = 0; token.Clear(); token.Visible = cancel.Visible = false;
                    status.Text = "Настройка сохранена. В Codex запросите список сервисов SwornCard.";
                    save.Text = "Готово";
                } catch (SetupError error) { status.Text = error.Message; }
                  catch (Exception) { status.Text = "Не удалось подтвердить сохранение в Codex. Можно повторить настройку."; }
                finally {
                    busy = false; save.Enabled = true;
                    if (result != 0) { cancel.Enabled = token.Enabled = true; token.SelectAll(); token.Focus(); }
                }
            };
            form.Shown += (s,e) => token.Focus();
            form.ShowDialog(); return result;
        }
    }
}
