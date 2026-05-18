using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;

namespace WinGrowl.App;

// Maps a localhost TCP client endpoint to the PID that owns it, by walking
// the OS's open-connections table via iphlpapi!GetExtendedTcpTable. Used to
// disambiguate which instance of a multi-instance app sent a GNTP NOTIFY —
// two Firestorms can't be told apart by process name, but each connection
// has a unique source port, and the kernel knows which PID opened it.
//
// For a connection where Firestorm (client) talks to WinGrowl (server),
// the OS's TCP table contains a row from the client's perspective:
//   dwLocalAddr/Port  = Firestorm side (the source IP:port we're handed
//                       as RemoteEndPoint on the accept side)
//   dwRemoteAddr/Port = WinGrowl side (loopback + 23053)
//   dwOwningPid       = Firestorm PID
//
// Returns null when the row isn't present (race with connection teardown),
// when the family isn't IPv4/IPv6, or when the P/Invoke fails. Callers
// must fall back to name-based matching in that case.
internal static class TcpPidResolver
{
    private const int AF_INET  = 2;
    private const int AF_INET6 = 23;
    private const int TCP_TABLE_OWNER_PID_ALL = 5;
    private const uint NO_ERROR = 0;
    private const uint ERROR_INSUFFICIENT_BUFFER = 122;

    [DllImport("iphlpapi.dll", SetLastError = true)]
    private static extern uint GetExtendedTcpTable(
        IntPtr pTcpTable, ref int pdwSize, bool bOrder, int ulAf,
        int TableClass, int Reserved);

    [StructLayout(LayoutKind.Sequential)]
    private struct MIB_TCPROW_OWNER_PID
    {
        public uint dwState;
        public uint dwLocalAddr;
        public uint dwLocalPort;
        public uint dwRemoteAddr;
        public uint dwRemotePort;
        public uint dwOwningPid;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MIB_TCP6ROW_OWNER_PID
    {
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 16)]
        public byte[] ucLocalAddr;
        public uint dwLocalScopeId;
        public uint dwLocalPort;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 16)]
        public byte[] ucRemoteAddr;
        public uint dwRemoteScopeId;
        public uint dwRemotePort;
        public uint dwState;
        public uint dwOwningPid;
    }

    public static int? ResolvePid(IPEndPoint clientEndPoint, int serverPort)
    {
        if (clientEndPoint?.Address is null) return null;
        int af = clientEndPoint.AddressFamily switch
        {
            AddressFamily.InterNetwork   => AF_INET,
            AddressFamily.InterNetworkV6 => AF_INET6,
            _ => 0
        };
        if (af == 0) return null;

        try
        {
            int bufSize = 0;
            var ret = GetExtendedTcpTable(IntPtr.Zero, ref bufSize, false, af, TCP_TABLE_OWNER_PID_ALL, 0);
            if (ret != NO_ERROR && ret != ERROR_INSUFFICIENT_BUFFER) return null;
            if (bufSize <= 0) return null;

            var buffer = Marshal.AllocHGlobal(bufSize);
            try
            {
                ret = GetExtendedTcpTable(buffer, ref bufSize, false, af, TCP_TABLE_OWNER_PID_ALL, 0);
                if (ret != NO_ERROR) return null;

                int rowCount = Marshal.ReadInt32(buffer);
                var cursor   = IntPtr.Add(buffer, 4);
                ushort wantClient = (ushort)clientEndPoint.Port;
                ushort wantServer = (ushort)serverPort;

                if (af == AF_INET)
                {
                    int rowSize = Marshal.SizeOf<MIB_TCPROW_OWNER_PID>();
                    var clientBytes = clientEndPoint.Address.GetAddressBytes();
                    uint clientAddr = BitConverter.ToUInt32(clientBytes, 0);
                    for (int i = 0; i < rowCount; i++)
                    {
                        var row = Marshal.PtrToStructure<MIB_TCPROW_OWNER_PID>(cursor);
                        if (PortBeToHost(row.dwLocalPort) == wantClient
                            && PortBeToHost(row.dwRemotePort) == wantServer
                            && row.dwLocalAddr == clientAddr)
                        {
                            return (int)row.dwOwningPid;
                        }
                        cursor = IntPtr.Add(cursor, rowSize);
                    }
                }
                else
                {
                    int rowSize = Marshal.SizeOf<MIB_TCP6ROW_OWNER_PID>();
                    var clientBytes = clientEndPoint.Address.GetAddressBytes();
                    for (int i = 0; i < rowCount; i++)
                    {
                        var row = Marshal.PtrToStructure<MIB_TCP6ROW_OWNER_PID>(cursor);
                        if (PortBeToHost(row.dwLocalPort) == wantClient
                            && PortBeToHost(row.dwRemotePort) == wantServer
                            && row.ucLocalAddr.SequenceEqual(clientBytes))
                        {
                            return (int)row.dwOwningPid;
                        }
                        cursor = IntPtr.Add(cursor, rowSize);
                    }
                }
                return null;
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }
        catch
        {
            return null;
        }
    }

    // Port is stored as network-order 16-bit in the low half of a DWORD;
    // on little-endian Windows that means byte0 = high byte, byte1 = low.
    private static ushort PortBeToHost(uint dwPort)
        => (ushort)(((dwPort & 0xFF) << 8) | ((dwPort >> 8) & 0xFF));
}
