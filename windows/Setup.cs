using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

internal static class Setup {
    const string Endpoint = "https://connect.sworncard.ru/mcp";
    const string Plugin = "sworncard-connect@sworncard-connect";
    const string Title = "SwornCard · Подключение к Codex";
    static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = 8 * 1024 * 1024 };
    static readonly Regex Token = new Regex(@"\Ascpat1\.(pc_[A-Za-z0-9_-]{43})\.[A-Za-z0-9_-]{43}\z");

    sealed class SetupError : Exception { public SetupError(string text) : base(text) {} }

    static object Get(object obj, params string[] keys) {
        foreach (string key in keys) {
            var map = obj as IDictionary<string, object>;
            if (map == null || !map.TryGetValue(key, out obj)) return null;
        }
        return obj;
    }

    // Use the registered OpenAI Desktop package, never an executable from the active project or PATH.
    static async Task<string> DesktopBinary() {
        string shell = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
        const string query = "[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); " +
            "(Get-AppxPackage -Name OpenAI.Codex | Where-Object PackageFamilyName -eq 'OpenAI.Codex_2p2nqsd0c76g0').InstallLocation";
        using (var p = Start(shell, "-NoLogo -NoProfile -NonInteractive -Command \"" + query + "\"")) {
            try {
                string root = (await Within(p.StandardOutput.ReadToEndAsync())).Trim();
                string path = Path.Combine(root, @"app\resources\codex.exe");
                if (!Path.IsPathRooted(root) || root.Contains("\n") || !File.Exists(path))
                    throw new SetupError("Не найден установленный Codex Desktop для Windows.");
                return path;
            } finally { Stop(p); }
        }
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

    static async Task<T> Within<T>(Task<T> task) {
        if (await Task.WhenAny(task, Task.Delay(25000)) != task)
            throw new SetupError("Codex не ответил вовремя. Попробуйте подключение ещё раз.");
        return await task;
    }

    static void CheckProfile() {
        string user = Path.GetFullPath(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));
        string home = Environment.GetEnvironmentVariable("CODEX_HOME") ?? Path.Combine(user, ".codex");
        if (!Path.IsPathRooted(home)) throw new SetupError("Нужен локальный личный профиль Codex.");
        home = Path.GetFullPath(home);
        if (home.StartsWith(@"\\") || !home.StartsWith(user.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase))
            throw new SetupError("Для личного PAT нужен профиль Codex в каталоге вашего пользователя Windows.");
        // A plugin install has already created the home. Reject redirects into shared storage.
        for (var d = new DirectoryInfo(home); d != null; d = d.Parent) {
            if ((d.Attributes & FileAttributes.ReparsePoint) != 0) throw new SetupError("Профиль Codex находится за файловой ссылкой.");
            if (String.Equals(d.FullName, user, StringComparison.OrdinalIgnoreCase)) break;
        }
        string config = Path.Combine(home, "config.toml");
        var trusted = new HashSet<string> { WindowsIdentity.GetCurrent().User.Value, "S-1-5-18", "S-1-5-32-544", "S-1-3-0", "S-1-3-4" };
        CheckAcl(Directory.GetAccessControl(home), trusted);
        if (File.Exists(config)) {
            if ((File.GetAttributes(config) & FileAttributes.ReparsePoint) != 0) throw new SetupError("Файл настроек является ссылкой.");
            CheckAcl(File.GetAccessControl(config), trusted);
        }
    }

    static void CheckAcl(FileSystemSecurity acl, HashSet<string> trusted) {
        if (!trusted.Contains(acl.GetOwner(typeof(SecurityIdentifier)).Value))
            throw new SetupError("Проверьте владельца личного профиля Codex.");
        foreach (FileSystemAccessRule rule in acl.GetAccessRules(true, true, typeof(SecurityIdentifier))) {
            if (rule.AccessControlType == AccessControlType.Allow && !trusted.Contains(rule.IdentityReference.Value) &&
                (rule.FileSystemRights & (FileSystemRights.ReadData | FileSystemRights.WriteData | FileSystemRights.AppendData |
                    FileSystemRights.Delete | FileSystemRights.DeleteSubdirectoriesAndFiles | FileSystemRights.ChangePermissions |
                    FileSystemRights.TakeOwnership)) != 0)
                throw new SetupError("Другим пользователям предоставлен доступ к профилю Codex. PAT не сохранён.");
        }
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

    static async Task WriteSettings(Process p, string server, string secret) {
        await Rpc(p, 1, "initialize", new {clientInfo = new {name = "sworncard-setup", version = "1"}});
        await p.StandardInput.WriteLineAsync("{\"method\":\"initialized\"}");
        object read = await Rpc(p, 2, "config/read", new {includeLayers = true});
        var layers = ((IEnumerable)Get(read, "layers")).Cast<object>().ToList();
        object personal = layers.Single(layer => Equals(Get(layer, "name", "type"), "user"));
        string version = Get(personal, "version") as string;
        if (String.IsNullOrEmpty(version)) throw new SetupError("Codex не подтвердил версию личного профиля.");
        foreach (object layer in layers) {
            object entry = Get(layer, "config", "mcp_servers", server);
            if (entry == null) continue;
            var map = entry as IDictionary<string, object>;
            var headers = Get(entry, "http_headers") as IDictionary<string, object>;
            if (layer != personal || map == null || map.Count != 2 || !Equals(Get(entry, "url"), Endpoint) ||
                headers == null || headers.Count != 1 || !headers.ContainsKey("Authorization"))
                throw new SetupError("У этого подключения уже есть другие настройки MCP. Они сохранены.");
        }
        var edits = new List<object> { new {
            keyPath = "mcp_servers." + server, mergeStrategy = "replace",
            value = new { url = Endpoint, http_headers = new {Authorization = "Bearer " + secret} }
        }};
        object plugin = Get(personal, "config", "plugins", Plugin);
        if (Equals(Get(plugin, "enabled"), true) && Get(plugin, "mcp_servers", "sworncard", "enabled") == null &&
            Environment.GetEnvironmentVariable("SWORNCARD_CONNECT_PAT") == null)
            edits.Add(new {keyPath = "plugins." + Plugin + ".mcp_servers.sworncard.enabled", value = false, mergeStrategy = "replace"});
        object written = await Rpc(p, 3, "config/batchWrite", new {edits, expectedVersion = version});
        if (!Equals(Get(written, "status"), "ok")) throw new SetupError("Личная настройка переопределена политикой Codex.");
    }

    static async Task Save(string secret) {
        var match = Token.Match(secret);
        if (!match.Success) throw new SetupError("Скопируйте весь PAT из кабинета Idemnia.");
        CheckProfile();
        string binary = await DesktopBinary();
        using (var p = Start(binary, "app-server --listen stdio://")) {
            try {
                var work = WriteSettings(p, "sworncard_" + match.Groups[1].Value, secret);
                if (await Task.WhenAny(work, Task.Delay(25000)) != work)
                    throw new SetupError("Codex не ответил вовремя. Можно повторить настройку.");
                await work;
            }
            finally { Stop(p); }
        }
    }

    [STAThread]
    static int Main(string[] args) {
        if (args.Length != 0 || !Environment.UserInteractive) return 2;
        Application.EnableVisualStyles();
        using (var form = new Form {Text = Title, StartPosition = FormStartPosition.CenterScreen,
                FormBorderStyle = FormBorderStyle.FixedDialog, MinimizeBox = false, MaximizeBox = false,
                ClientSize = new Size(466,220), AutoScaleMode = AutoScaleMode.Font}) {
            var prompt = new Label {Text = "Вставьте PAT подключения из кабинета Idemnia.\r\nСервер: " + Endpoint, AutoSize = true, Left = 16, Top = 15};
            var token = new TextBox {Name = "PersonalAccessToken", AccessibleName = "PAT", UseSystemPasswordChar = true, Left = 16, Top = 62, Width = 430};
            var status = new Label {Name = "Status", Text = "Токен будет сохранён в личных настройках Codex на этом компьютере.", Left = 16, Top = 99, Width = 430, Height = 60};
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
