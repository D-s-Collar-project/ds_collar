using System.Collections;
using System.Globalization;
using System.Text;

namespace WinGrowl.Core.Gntp;

public sealed class GntpHeaders : IEnumerable<KeyValuePair<string, string>>
{
    private readonly Dictionary<string, string> _values = new(StringComparer.OrdinalIgnoreCase);
    private readonly List<string> _order = new();

    public int Count => _values.Count;

    public string? this[string name]
    {
        get => _values.TryGetValue(name, out var v) ? v : null;
        set
        {
            if (value is null)
            {
                if (_values.Remove(name)) _order.RemoveAll(k => string.Equals(k, name, StringComparison.OrdinalIgnoreCase));
                return;
            }
            if (!_values.ContainsKey(name)) _order.Add(name);
            _values[name] = value;
        }
    }

    public bool TryGet(string name, out string value)
    {
        if (_values.TryGetValue(name, out var v)) { value = v; return true; }
        value = string.Empty;
        return false;
    }

    public string Require(string name)
    {
        if (!_values.TryGetValue(name, out var v))
            throw new GntpException(GntpErrorCode.RequiredHeaderMissing, $"Required header missing: {name}");
        return v;
    }

    public bool GetBool(string name, bool fallback = false)
    {
        if (!_values.TryGetValue(name, out var v)) return fallback;
        return v.Trim().Equals("true", StringComparison.OrdinalIgnoreCase)
            || v.Trim().Equals("yes", StringComparison.OrdinalIgnoreCase)
            || v.Trim() == "1";
    }

    public int GetInt(string name, int fallback = 0)
    {
        if (!_values.TryGetValue(name, out var v)) return fallback;
        return int.TryParse(v, NumberStyles.Integer, CultureInfo.InvariantCulture, out var i) ? i : fallback;
    }

    public IEnumerable<string> Keys => _order;

    public void WriteTo(StringBuilder sb)
    {
        foreach (var key in _order)
        {
            sb.Append(key).Append(": ").Append(_values[key]).Append("\r\n");
        }
    }

    public IEnumerator<KeyValuePair<string, string>> GetEnumerator()
    {
        foreach (var key in _order) yield return new KeyValuePair<string, string>(key, _values[key]);
    }

    IEnumerator IEnumerable.GetEnumerator() => GetEnumerator();
}
