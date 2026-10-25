using System.Windows.Media.Media3D;

namespace ZMFTheaters.Cinema;

/// Building layout shared with the iPhone app (same coordinates and sizes).
/// +Y up; +Z runs from the lobby entrance (z=0) up the hall (z=20…111).
/// Rooms 01–06 open off the west side (x&lt;0), 07–12 off the east side.
/// Each auditorium is authored in local space (x=0 screen wall … x=25.8 back
/// wall, z=0…14) and mapped to world space by <see cref="RoomXf"/>.
public static class World
{
    public const double LobbyX0 = -16, LobbyX1 = 16, LobbyZ0 = 0, LobbyZ1 = 20;
    public const double HallHalf = 4, HallZ0 = 20, RoomSpacing = 15, FirstRoomZ = 21;
    public static double HallZ1 => FirstRoomZ + 6 * RoomSpacing;
    public const double RoomDepth = 25.8, RoomWidth = 14, RoomCeiling = 6.5, RoomFloorMin = -2.4;
    public const double LobbyCeiling = 9, HallCeiling = 4.5;
    public const double DoorZ0 = 6, DoorZ1 = 8, DoorHeight = 2.6;
    public const double EyeHeight = 1.65;
    public const double ScreenW = 12, ScreenH = 5.2;

    public static double RowX(int r) => 8 + r * 1.6;
    public static double RowFloor(int r) => -(7 - r) * 0.3;
    public static double SeatZ(int s) => 7 + (s - 3.5) * 1.2;

    public static double LocalGround(double lx)
    {
        if (lx >= 20) return 0;
        if (lx < 7.2) return RoomFloorMin;
        var r = Math.Clamp((int)((lx - 7.2) / 1.6), 0, 7);
        return RowFloor(r);
    }

    public static double RoomBaseZ(int id) => FirstRoomZ + ((id - 1) % 6) * RoomSpacing;

    public readonly record struct RoomXf(double OriginX, double SignX, double OriginZ)
    {
        public Point3D P(double x, double y, double z) => new(OriginX + SignX * x, y, OriginZ + z);
        public Vector3D N(double x, double y, double z) => new(SignX * x, y, z);
    }

    public static RoomXf Xf(int id) => id <= 6 ? new RoomXf(-30, 1, RoomBaseZ(id)) : new RoomXf(30, -1, RoomBaseZ(id));

    public static (double x0, double x1, double z0, double z1) RoomRect(int id)
    {
        var z0 = RoomBaseZ(id);
        return id <= 6 ? (-30, -4.2, z0, z0 + RoomWidth) : (4.2, 30, z0, z0 + RoomWidth);
    }

    public static (double x, double z) ToLocal(double x, double z, int id)
    {
        var t = Xf(id);
        return ((x - t.OriginX) * t.SignX, z - t.OriginZ);
    }

    public static (double x, double z) DoorFront(int id) => (id <= 6 ? -3.0 : 3.0, RoomBaseZ(id) + (DoorZ0 + DoorZ1) / 2);
    public static Point3D SeatPosition(int room, int row, int seat) => Xf(room).P(RowX(row), RowFloor(row), SeatZ(seat));
    public static double ScreenYaw(int room) => room <= 6 ? -Math.PI / 2 : Math.PI / 2;

    /// 0 = lobby, -1 = hall, 1…12 = auditorium.
    public static int Zone(double x, double z)
    {
        for (int id = 1; id <= 12; id++)
        {
            var r = RoomRect(id);
            if (x >= r.x0 && x <= r.x1 && z >= r.z0 && z <= r.z1) return id;
        }
        return z >= HallZ0 && Math.Abs(x) <= HallHalf + 0.5 ? -1 : 0;
    }

    public static double GroundHeight(double x, double z)
    {
        var zone = Zone(x, z);
        return zone > 0 ? LocalGround(ToLocal(x, z, zone).x) : 0;
    }

    static readonly (double x0, double x1, double z0, double z1)[] Obstacles =
    {
        (-14.5, -7.5, 8.6, 10.4), (7.5, 14.5, 8.6, 10.4), (-6.5, -5.5, 13.5, 14.5), (5.5, 6.5, 13.5, 14.5),
        (-8.5, -7.5, 2.5, 3.5), (7.5, 8.5, 2.5, 3.5),
    };

    static bool In(double x, double z, double x0, double x1, double z0, double z1, double inset) =>
        x >= x0 + inset && x <= x1 - inset && z >= z0 + inset && z <= z1 - inset;

    public static bool Walkable(double x, double z, Func<int, bool> doorOpen, double r = 0.3)
    {
        foreach (var o in Obstacles) if (In(x, z, o.x0, o.x1, o.z0, o.z1, -r)) return false;
        if (In(x, z, LobbyX0, LobbyX1, LobbyZ0, LobbyZ1, r)) return true;
        if (In(x, z, -HallHalf, HallHalf, HallZ0 - 1, HallZ1, r)) return true;
        for (int id = 1; id <= 12; id++)
        {
            var rr = RoomRect(id);
            var (x0, x1) = id <= 6 ? (rr.x0 + 1.4, rr.x1) : (rr.x0, rr.x1 - 1.4);
            if (In(x, z, x0, x1, rr.z0, rr.z1, r)) return true;
            if (doorOpen(id))
            {
                var dz0 = rr.z0 + DoorZ0 + r; var dz1 = rr.z0 + DoorZ1 - r;
                var (sx0, sx1) = id <= 6 ? (-5.2, -3.0) : (3.0, 5.2);
                if (x >= sx0 && x <= sx1 && z >= dz0 && z <= dz1) return true;
            }
        }
        return false;
    }
}
