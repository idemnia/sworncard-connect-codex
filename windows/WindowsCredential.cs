using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Diagnostics;
using System.Web.Script.Serialization;

// One generic credential per RU connection, local to this user's logon on this computer.
internal static class WindowsCredential {
    const string Prefix = "SwornCard Connect/https://connect.sworncard.ru/mcp/";
    static readonly Regex Connection = new Regex(@"\Apc_[A-Za-z0-9_-]{43}\z");
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct Credential {
        public uint Flags, Type;
        public string TargetName, Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint BlobSize;
        public IntPtr Blob;
        public uint Persist, AttributeCount;
        public IntPtr Attributes;
        public string TargetAlias, UserName;
    }
    [DllImport("advapi32", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredWrite(ref Credential credential, uint flags);
    [DllImport("advapi32", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredRead(string target, uint type, uint flags, out IntPtr value);
    [DllImport("advapi32")] static extern void CredFree(IntPtr value);

    internal static void Save(string id, string token) {
        if (!Connection.IsMatch(id)) throw new ArgumentException();
        byte[] bytes = Encoding.UTF8.GetBytes(token);
        var pin = GCHandle.Alloc(bytes, GCHandleType.Pinned);
        try {
            var credential = new Credential {Type = 1, TargetName = Prefix + id, UserName = id,
                Persist = 2, Blob = pin.AddrOfPinnedObject(), BlobSize = (uint)bytes.Length};
            if (!CredWrite(ref credential, 0)) throw new IOException("Windows credential store unavailable");
        } finally { Array.Clear(bytes, 0, bytes.Length); pin.Free(); }
    }

    // Codex's native HTTP header provider runs the command under System32\cmd.exe
    // and consumes a pipe. Never return a bearer to a terminal or ordinary invocation.
    [StructLayout(LayoutKind.Sequential)]
    struct ProcessInfo { public IntPtr Status, Peb, Affinity, Priority, Pid, Parent; }
    [DllImport("ntdll")] static extern int NtQueryInformationProcess(IntPtr process, int infoClass,
        out ProcessInfo info, int size, out int returned);
    [DllImport("kernel32")] static extern IntPtr GetStdHandle(int handle);
    [DllImport("kernel32")] static extern uint GetFileType(IntPtr handle);

    static Process Parent(Process child) {
        ProcessInfo info; int returned;
        if (NtQueryInformationProcess(child.Handle, 0, out info, Marshal.SizeOf(typeof(ProcessInfo)), out returned) != 0)
            throw new InvalidOperationException();
        var parent = Process.GetProcessById(info.Parent.ToInt32());
        if (parent.StartTime > child.StartTime) { parent.Dispose(); throw new InvalidOperationException(); }
        return parent;
    }
    static bool SameImage(Process p, string path) {
        return String.Equals(p.MainModule.FileName, path, StringComparison.OrdinalIgnoreCase);
    }
    internal static int Supply(string id) {
        if (!Connection.IsMatch(id) || GetFileType(GetStdHandle(-11)) != 3) return 2;
        try {
            using (var self = Process.GetCurrentProcess())
            using (var shell = Parent(self))
            using (var client = Parent(shell)) {
                if (!SameImage(shell, Path.Combine(Environment.SystemDirectory, "cmd.exe")) ||
                    !SameImage(client, Setup.DesktopBinary())) return 2;
            }
            IntPtr handle;
            if (!CredRead(Prefix + id, 1, 0, out handle)) return 1;
            try {
                var item = (Credential)Marshal.PtrToStructure(handle, typeof(Credential));
                if (item.BlobSize != 97 || item.Blob == IntPtr.Zero) return 1;
                var bytes = new byte[item.BlobSize];
                try {
                    Marshal.Copy(item.Blob, bytes, 0, bytes.Length);
                    var token = Encoding.UTF8.GetString(bytes);
                    var match = Setup.Token.Match(token);
                    if (!match.Success || match.Groups[1].Value != id) return 1;
                    var json = new JavaScriptSerializer().Serialize(new {Authorization = "Bearer " + token});
                    using (var stream = Console.OpenStandardOutput())
                    using (var writer = new StreamWriter(stream, new UTF8Encoding(false))) writer.Write(json);
                    return 0;
                } finally { Array.Clear(bytes, 0, bytes.Length); }
            } finally { CredFree(handle); }
        } catch { return 1; }
    }
}
