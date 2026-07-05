using System.Collections.Concurrent;
using LibreMetaverse;

namespace DSCollar.SmokeTest;

/// <summary>One captured line of chat as seen by this agent.</summary>
public sealed record ChatLine(
    DateTime When,
    ChatType Type,
    ChatSourceType SourceType,
    UUID SourceId,
    UUID OwnerId,
    string FromName,
    string Message);

/// <summary>A script dialog held for inspection until a test answers or
/// discards it.</summary>
public sealed class PendingDialog
{
    public required DateTime When { get; init; }
    public required UUID ObjectId { get; init; }
    public required string ObjectName { get; init; }
    public required int Channel { get; init; }
    public required string Message { get; init; }
    public required List<string> Buttons { get; init; }
    public bool Consumed { get; set; }

    public override string ToString() =>
        $"[{ObjectName} chan {Channel}] \"{Truncate(Message, 80)}\" buttons: {string.Join(" | ", Buttons)}";

    private static string Truncate(string s, int n) =>
        s.Length <= n ? s.Replace('\n', ' ') : s[..n].Replace('\n', ' ') + "…";
}

/// <summary>
/// Wraps one logged-in scripted agent. Captures chat (including RLV
/// OwnerSay), script dialogs, and inventory offers; provides the primitives
/// the scenarios are written in: say, touch, long-touch, wait-for-dialog,
/// click-button, wait-for-chat, walk.
/// </summary>
public sealed class BotAgent : IDisposable
{
    public GridClient Client { get; } = new();
    public string Tag { get; }
    public UUID AgentId => Client.Self.AgentID;
    public string UserName { get; }

    private readonly List<ChatLine> _chat = new();
    private readonly List<PendingDialog> _dialogs = new();
    private readonly object _lock = new();

    /// <summary>All OwnerSay lines beginning with '@' — the RLV command
    /// stream the collar (and relay) emits to this agent's "viewer".</summary>
    public IReadOnlyList<ChatLine> RlvCommands
    {
        get { lock (_lock) return _chat.Where(c => c.Type == ChatType.OwnerSay && c.Message.StartsWith('@')).ToList(); }
    }

    /// <summary>When true, answer the collar's RLV probe (@versionnew=chan)
    /// like an RLV viewer would, so RLV-gated features activate.</summary>
    public bool EmulateRlv { get; set; }

    /// <summary>Inventory offers received (object name lines); offers are
    /// auto-declined so bot inventories stay clean, but tests can assert one
    /// arrived.</summary>
    public IReadOnlyList<string> InventoryOffers
    {
        get { lock (_lock) return _offers.ToList(); }
    }
    private readonly List<string> _offers = new();

    public event Action<string>? Log;

    public BotAgent(string tag, string firstName)
    {
        Tag = tag;
        UserName = firstName.ToLowerInvariant();

        Client.Settings.Agent.MultipleSims = false;
        Client.Settings.World.TrackObjects = true;
        Client.Settings.World.TrackAvatars = true;
        Client.Settings.World.AlwaysDecodeObjects = true;
        Client.Settings.World.AlwaysRequestObjects = true;

        Client.Self.ChatFromSimulator += OnChat;
        Client.Self.ScriptDialog += OnScriptDialog;
        Client.Inventory.InventoryObjectOffered += OnInventoryOffered;
    }

    private void Note(string msg) => Log?.Invoke($"[{Tag}] {msg}");

    /* ---------------- login / logout ---------------- */

    public async Task<bool> LoginAsync(SmokeConfig cfg, BotAccount acct, CancellationToken ct)
    {
        Client.Settings.Connection.LoginServer = cfg.LoginUri;
        Note($"logging in {acct.FirstName} {acct.LastName} → {cfg.LoginUri}");
        var ok = await Client.Network.LoginAsync(
            acct.FirstName, acct.LastName, acct.Password,
            "DSCollarSmokeTest", cfg.StartLocation, "1.0", ct);
        if (!ok)
        {
            Note($"LOGIN FAILED: {Client.Network.LoginErrorKey} — {Client.Network.LoginMessage}");
            return false;
        }
        Note($"logged in; region {Client.Network.CurrentSim?.Name}, pos {Client.Self.SimPosition}");
        return true;
    }

    public void Logout()
    {
        if (Client.Network.Connected)
        {
            Note("logging out");
            Client.Network.Logout();
        }
    }

    /* ---------------- event capture ---------------- */

    private void OnChat(object? sender, ChatEventArgs e)
    {
        if (e.Message.Length == 0) return; // typing start/stop etc.
        var line = new ChatLine(DateTime.UtcNow, e.Type, e.SourceType, e.SourceID, e.OwnerID, e.FromName, e.Message);
        lock (_lock) _chat.Add(line);

        if (e.Type == ChatType.OwnerSay && e.Message.StartsWith('@'))
        {
            Note($"RLV << {e.Message}");
            if (EmulateRlv) AnswerRlvQueries(e.Message);
        }
    }

    /// <summary>Minimal RLV-viewer emulation: for each comma-separated
    /// behaviour of the form "@versionnew=&lt;chan&gt;" (or @version / @getstatus
    /// probes) reply on the given positive channel like a viewer would.
    /// Restriction commands (=n/=y/force) are just logged — enforcement is a
    /// viewer concern, and the smoketest asserts on emission, not effect.</summary>
    private void AnswerRlvQueries(string ownerSay)
    {
        foreach (var raw in ownerSay.Split(','))
        {
            var cmd = raw.Trim().TrimStart('@');
            var eq = cmd.LastIndexOf('=');
            if (eq < 0) continue;
            var behav = cmd[..eq];
            var param = cmd[(eq + 1)..];
            if (!int.TryParse(param, out var chan) || chan <= 0) continue;

            string? reply = behav switch
            {
                "versionnew" => "RestrainedLove viewer v3.4.3 (SmokeTest emulation)",
                "version" => "RestrainedLove viewer v1.23 (SmokeTest emulation)",
                "versionnum" => "2090000",
                "getstatus" => "",
                _ => null,
            };
            if (reply != null)
            {
                Note($"RLV >> chan {chan}: {reply}");
                Client.Self.Chat(reply, chan, ChatType.Normal, false);
            }
        }
    }

    private void OnScriptDialog(object? sender, ScriptDialogEventArgs e)
    {
        var d = new PendingDialog
        {
            When = DateTime.UtcNow,
            ObjectId = e.ObjectID,
            ObjectName = e.ObjectName,
            Channel = e.Channel,
            Message = e.Message,
            Buttons = e.ButtonLabels.ToList(),
        };
        lock (_lock) _dialogs.Add(d);
        Note($"dialog: {d}");
    }

    private void OnInventoryOffered(object? sender, InventoryObjectOfferedEventArgs e)
    {
        lock (_lock) _offers.Add(e.Offer.Message);
        Note($"inventory offer: {e.Offer.Message} (auto-declining)");
        e.Accept = false;
    }

    /* ---------------- actions ---------------- */

    public void Say(string message, int channel = 0)
    {
        Note($"say /{channel} {message}");
        Client.Self.Chat(message, channel, ChatType.Normal, false);
    }

    /// <summary>Send a collar chat command: "&lt;prefix&gt; &lt;cmd&gt;" on the
    /// configured collar channel.</summary>
    public void Command(SmokeConfig cfg, string cmd) =>
        Say($"{cfg.ChatPrefix} {cmd}", cfg.ChatChannel);

    public void Touch(uint localId)
    {
        Note($"touch {localId}");
        Client.Self.Touch(localId);
    }

    /// <summary>Hold a touch for the given duration (collar long-touch = SOS
    /// at ≥1.5s).</summary>
    public async Task LongTouch(uint localId, double seconds = 2.0)
    {
        Note($"long-touch {localId} for {seconds:0.0}s");
        Client.Self.Grab(localId);
        await Task.Delay(TimeSpan.FromSeconds(seconds));
        Client.Self.DeGrab(localId);
    }

    public Vector3 Position => Client.Self.SimPosition;

    public void WalkTo(Vector3 simLocal)
    {
        Note($"walk to {simLocal}");
        Client.Self.AutoPilotLocal((int)simLocal.X, (int)simLocal.Y, simLocal.Z);
    }

    public void StopWalking() => Client.Self.AutoPilotCancel();

    /* ---------------- waiting / querying ---------------- */

    /// <summary>UTC marker for "everything after now" filters.</summary>
    public static DateTime Now => DateTime.UtcNow;

    public async Task<ChatLine?> WaitForChat(Func<ChatLine, bool> match, TimeSpan timeout, DateTime? since = null)
    {
        var deadline = DateTime.UtcNow + timeout;
        var floor = since ?? DateTime.MinValue;
        while (DateTime.UtcNow < deadline)
        {
            lock (_lock)
            {
                var hit = _chat.FirstOrDefault(c => c.When >= floor && match(c));
                if (hit != null) return hit;
            }
            await Task.Delay(250);
        }
        return null;
    }

    /// <summary>Wait for an RLV command line (OwnerSay starting with '@')
    /// containing the given substring.</summary>
    public Task<ChatLine?> WaitForRlv(string contains, TimeSpan timeout, DateTime? since = null) =>
        WaitForChat(c => c.Type == ChatType.OwnerSay
                         && c.Message.StartsWith('@')
                         && c.Message.Contains(contains, StringComparison.OrdinalIgnoreCase),
                    timeout, since);

    public async Task<PendingDialog?> WaitForDialog(Func<PendingDialog, bool> match, TimeSpan timeout, DateTime? since = null)
    {
        var deadline = DateTime.UtcNow + timeout;
        var floor = since ?? DateTime.MinValue;
        while (DateTime.UtcNow < deadline)
        {
            lock (_lock)
            {
                var hit = _dialogs.FirstOrDefault(d => !d.Consumed && d.When >= floor && match(d));
                if (hit != null) return hit;
            }
            await Task.Delay(250);
        }
        return null;
    }

    /// <summary>Wait for any dialog whose body or buttons contain the given
    /// substring (case-insensitive).</summary>
    public Task<PendingDialog?> WaitForDialogContaining(string contains, TimeSpan timeout, DateTime? since = null) =>
        WaitForDialog(d => d.Message.Contains(contains, StringComparison.OrdinalIgnoreCase)
                           || d.Buttons.Any(b => b.Contains(contains, StringComparison.OrdinalIgnoreCase)),
                      timeout, since);

    /// <summary>Click a dialog button by exact label (falls back to first
    /// label containing the text). Returns false when no such button.</summary>
    public bool ClickButton(PendingDialog dialog, string label)
    {
        var idx = dialog.Buttons.FindIndex(b => b == label);
        if (idx < 0)
            idx = dialog.Buttons.FindIndex(b => b.Contains(label, StringComparison.OrdinalIgnoreCase));
        if (idx < 0)
        {
            Note($"no button '{label}' in {dialog}");
            return false;
        }
        dialog.Consumed = true;
        Note($"click '{dialog.Buttons[idx]}' on chan {dialog.Channel}");
        Client.Self.ReplyToScriptDialog(dialog.Channel, idx, dialog.Buttons[idx], dialog.ObjectId);
        return true;
    }

    /// <summary>Discard all pending (unconsumed) dialogs so a later wait sees
    /// only fresh ones.</summary>
    public void DrainDialogs()
    {
        lock (_lock) foreach (var d in _dialogs) d.Consumed = true;
    }

    /* ---------------- object lookup ---------------- */

    /// <summary>Find a prim attached to the given avatar whose object name
    /// contains <paramref name="nameContains"/> (case-insensitive). Requests
    /// object properties as needed. Returns 0 when not found.</summary>
    public async Task<uint> FindAttachment(UUID avatarId, string nameContains, TimeSpan timeout)
    {
        var sim = Client.Network.CurrentSim
                  ?? throw new InvalidOperationException("not connected");
        var deadline = DateTime.UtcNow + timeout;

        var named = new ConcurrentDictionary<uint, string>();
        void OnProps(object? s, ObjectPropertiesEventArgs e)
        {
            var prim = sim.ObjectsPrimitives.Values.FirstOrDefault(p => p.ID == e.Properties.ObjectID);
            if (prim != null) named[prim.LocalID] = e.Properties.Name;
        }
        Client.Objects.ObjectProperties += OnProps;
        try
        {
            while (DateTime.UtcNow < deadline)
            {
                // avatar's LocalID in *this* client's view
                var av = sim.ObjectsAvatars.Values.FirstOrDefault(a => a.ID == avatarId);
                if (av != null)
                {
                    var children = sim.ObjectsPrimitives.Values
                        .Where(p => p.ParentID == av.LocalID)
                        .ToList();

                    foreach (var p in children)
                    {
                        if (p.Properties != null) named.TryAdd(p.LocalID, p.Properties.Name);
                        if (!named.ContainsKey(p.LocalID))
                            Client.Objects.SelectObject(sim, p.LocalID, true);
                    }

                    var hit = children.FirstOrDefault(p =>
                        named.TryGetValue(p.LocalID, out var n) &&
                        n.Contains(nameContains, StringComparison.OrdinalIgnoreCase));
                    if (hit != null)
                    {
                        Note($"found attachment '{named[hit.LocalID]}' local {hit.LocalID} on {avatarId}");
                        return hit.LocalID;
                    }
                }
                await Task.Delay(500);
            }
        }
        finally
        {
            Client.Objects.ObjectProperties -= OnProps;
        }
        Note($"attachment '{nameContains}' NOT found on {avatarId}");
        return 0;
    }

    public void Dispose()
    {
        try { Logout(); } catch { /* already down */ }
    }
}
