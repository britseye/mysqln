module connect;

import sha1;

import std.socket;
import std.exception;
import std.stdio;
import std.string;
import std.conv;
import std.variant;
import std.datetime;

class MySQLException: Exception
{
   this(string msg, string file, uint line) { super(msg, file, line); }
}
alias MySQLException MYX;

/**
 * A MySQL time column can store either a time-of-day or a time difference.
 * D's std.datetime does not have a type that is closely compatible with the MySQL
 * interpretation of a time difference, so we define a struct here to hold such
 * values.
 *
 */
struct TimeDiff
{
   bool negative;
   int days;
   ubyte hours, minutes, seconds;
}

// This function is used to extract a time difference from a binary encoded row
TimeDiff toTimeDiff(ubyte[] a)
{
   enforceEx!MYX(a.length, "Supplied byte array is zero length");
   TimeDiff td;
   uint l = a[0];
   enforceEx!MYX(l == 0 || l == 5 || l == 8 || l == 12, "Bad Time length in binary row.");
   if (l == 5)
   {
      td.negative = (a[1]  != 0);
      td.days = (a[5] << 24) + (a[4] << 16) + (a[3] << 8) + a[2];
   }
   else if (l > 5)
   {
      td.negative = (a[1]  != 0);
      td.days = (a[5] << 24) + (a[4] << 16) + (a[3] << 8) + a[2];
      td.hours = a[6];
      td.minutes = a[7];
      td.seconds = a[8];
   }
   // Note that the fractional seconds part is not stored by MtSQL
   return td;
}

// This function is used to extract a time difference from a string encoded row
TimeDiff toTimeDiff(string s)
{
   TimeDiff td;
   int t = parse!int(s);
   if (t < 0)
   {
      td.negative = true;
      t = -t;
   }
   td.hours = t%24;
   td.days = t/24;
   munch(s, ":");
   td.minutes = parse!ubyte(s);
   munch(s, ":");
   td.seconds = parse!ubyte(s);
   return td;
}

// This function is used to extract a time of day from a binary encoded row
TimeOfDay toTimeOfDay(ubyte[] a)
{
   enforceEx!MYX(a.length, "Supplied byte array is zero length");
   TimeOfDay tod;
   uint l = a[0];
   enforceEx!MYX(l == 0 || l == 5 || l == 8 || l == 12, "Bad Time length in binary row.");

   enforceEx!MYX(l >= 8, "Time column value is not in a time-of-day format");
   tod.hour = a[6];
   tod.minute = a[7];
   tod.second = a[8];
   return tod;
}

// This function is used to extract a time of day from a string encoded row
TimeOfDay toTimeOfDay(string s)
{
   TimeOfDay tod;
   tod.hour = parse!int(s);
   enforceEx!MYX(tod.hour <= 24 && tod.hour >= 0, "Time column value is in time difference form");
   munch(s, ":");
   tod.minute = parse!ubyte(s);
   munch(s, ":");
   tod.second = parse!ubyte(s);
   return tod;
}

ubyte[] pack(TimeOfDay tod)
{
   ubyte[] rv;
   if (tod == TimeOfDay.init)
   {
      rv.length = 1;
      rv[0] = 0;
      return rv;
   }
   rv.length = 9;
   rv[0] = 8;
   rv[6] = tod.hour;
   rv[7] = tod.minute;
   rv[8] = tod.second;
   return rv;
}

Date toDate(ubyte[] a)
{
   enforceEx!MYX(a.length, "Supplied byte array is zero length");
   if (a[0] == 0)
      return Date(0,0,0);
   enforceEx!MYX(a[0] >= 4, "Binary date representation is too short");
   int year = (a[2]  << 8) + a[1];
   int month = cast(int) a[3];
   int day = cast(int) a[4];
   return Date(year, month, day);
}

Date toDate(string s)
{
   int year = parse!(ushort)(s);
   munch(s, "-");
   int month = parse!(ubyte)(s);
   munch(s, "-");
   int day = parse!(ubyte)(s);
   return Date(year, month, day);
}

ubyte[] pack(Date dt)
{
   ubyte[] rv;
   if (dt.year < 0)
   {
      rv.length = 1;
      rv[0] = 0;
      return rv;
   }
   rv.length = 4;
   rv[1] = cast(ubyte) (dt.year & 0xff);
   rv[2] = cast(ubyte) ((dt.year >> 8) & 0xff);
   rv[3] = cast(ubyte) dt.month;
   rv[4] = cast(ubyte) dt.day;
   rv[0] = 4;
   return rv;
}

DateTime toDateTime(ubyte[] a)
{
   enforceEx!MYX(a.length, "Supplied byte array is zero length");
   DateTime dt;
   if (a[0] == 0)
      return dt;
   enforceEx!MYX(a[0] >= 4, "Supplied ubyte[] is not long enough");
   int year = (a[2] << 8) + a[1];
   int month = a[3];
   int day = a[4];
   if (a[0] == 4)
   {
      dt = DateTime(year, month, day);
      return dt;
   }
   enforceEx!MYX(a[0] >= 7, "Supplied ubyte[] is not long enough");
   int hour = a[5];
   int minute = a[6];
   int second = a[7];
   dt = DateTime(year, month, day, hour, minute, second);
   return dt;
}

DateTime toDateTime(string s)
{
   int year = parse!(ushort)(s);
   munch(s, "-");
   int month = parse!(ubyte)(s);
   munch(s, "-");
   int day = parse!(ubyte)(s);
   munch(s, " ");
   int hour = parse!(ubyte)(s);
   munch(s, ":");
   int minute = parse!(ubyte)(s);
   munch(s, ":");
   int second = parse!(ubyte)(s);
   return DateTime(year, month, day, hour, minute, second);
}

DateTime toDateTime(ulong x)
{
   int second = cast(int) x%100;
   x /= 100;
   int minute = cast(int) x%100;
   x /=100;
   int hour = cast(int) x%100;
   x /=100;
   int day = cast(int) x%100;
   x /=100;
   int month = cast(int) x%100;
   x /=100;
   int year = cast(int) x%10000;
   // 2038-01-19 03:14:07
   enforceEx!MYX(year >= 1970 &&  year < 2039, "Date/time out of range for 2 bit timestamp");
   enforceEx!MYX(year == 2038 && (month > 1 || day > 19 || hour > 3 || minute > 14 || second > 7),
                  "Date/time out of range for 2 bit timestamp");
   return DateTime(year, month, day, hour, minute, second);
}

immutable(uint)[4] dtLengths = [ 1, 5, 8, 12 ];
ubyte[] pack(DateTime dt)
{
   uint len = 1;
   if (dt.year || dt.month || dt.day) len = 5;
   if (dt.hour || dt.minute|| dt.second) len = 8;
   ubyte[] rv;
   rv.length = len;
   if (len == 1)
   {
      rv[0] = 0;
      return rv;
   }
   rv[1] = cast(ubyte) (dt.year & 0xff);
   rv[2] = cast(ubyte) ((dt.year >> 8) & 0xff);
   rv[3] = cast(ubyte) dt.month;
   rv[4] = cast(ubyte) dt.day;
   if (len == 5)
   {
      rv[0] = 4;
      return rv;
   }
   rv[5] = cast(ubyte) dt.hour;
   rv[6] = cast(ubyte) dt.minute;
   rv[7] = cast(ubyte) dt.second;
   rv[0] = 7;
   return rv;
}

// It is assumed that insertion of timestamp values will not be common, since in general,
// TIMETPAMP columns are used for recording the time of a row insertion, and are filled in
// automatically by the server. If you want to force a timestamp value in a prepared insert,
//  set it into a timestamp struct as an unsigned long in the format YYYYMMDDHHMMSS
// When it is retrieved as part of a result set it will be as  DateTime struct.
struct Timestamp
{
   ulong rep;
}

//alias VariantN!(maxSize!(creal, char[], void delegate(),
//                                Time, Date, DateTime, Timestamp)) MyVariant;
alias Variant MyVariant;

enum SvrCapFlags: uint
{
    SECURE_PWD = 1,
    FOUND_NOT_AFFECTED =	2,
    ALL_COLUMN_FLAGS =	4,
    WITH_DB	= 8,
    NO_SCHEMA = 16,
    CAN_COMPRESS	= 32,
    ODBC = 64,
    LOCAL_FILES = 128,
    IGNORE_SPACE = 256,
    PROTOCOL41 = 512,
    INTERACTIVE = 1024,
    SSL  = 2048,
    IGNORE_SIGPIPE  = 4096,
    TRANSACTIONS = 8192,
    RESERVED = 16384,
    SECURE_CONNECTION = 32768,
    MULTI_STATEMENTS = 65536,
    MULTI_RESULTS = 131072
}

enum SQLType
{
   DEFAULT =          -1,
   DECIMAL =         0x00,
   TINY =               0x01,
   SHORT =            0x02,
   INT =                0x03,
   FLOAT =            0x04,
   DOUBLE =          0x05,
   NULL =              0x06,
   TIMESTAMP =     0x07,
   LONGLONG =      0x08,
   INT24 =             0x09,
   DATE =              0x0a,
   TIME =              0x0b,
   DATETIME =       0x0c,
   YEAR =              0x0d,
   NEWDATE =       0x0e,
   VARCHAR =        0x0f,        // new in MySQL 5.0
   BIT =                0x10,       // new in MySQL 5.0
   NEWDECIMAL =  0xf6,        // new in MYSQL 5.0
   ENUM =            0xf7,
   SET =               0xf8,
   TINYBLOB =       0xf9,
   MEDIUMBLOB =  0xfa,
   LONGBLOB =      0xfb,
   BLOB =             0xfc,
   VARSTRING =    0xfd,
   STRING =         0xfe,
   GEOMETRY =     0xff
}

enum RefreshFlags
{
   GRANT =      1,
   LOG =          2,
   TABLES =     4,
   HOSTS =      8,
   STATUS =   16,
   THREADS = 32,
   SLAVE =     64,
   MASTER = 128
}

ushort getShort(ref ubyte* ubp)
{
   ushort us;
   us |= ubp[1];
   us <<= 8;
   us |= ubp[0];
   ubp += 2;
   return us;
}


uint getInt(ref ubyte* ubp)
{
   uint rv = (ubp[3] << 24) + (ubp[2] << 16) + (ubp[1] << 8) + ubp[0];
   ubp += 4;
   return rv;
}

uint getInt24(ref ubyte* ubp)
{
   uint rv = (ubp[2] << 16) + (ubp[1] << 8) + ubp[0];
   ubp += 3;
   return rv;
}

ulong parseLCB(ref ubyte* ubp, out bool nullFlag)
{
   nullFlag = false;
   if (*ubp < 251)
   {
      return cast(ulong) *ubp++;
   }
   ulong t;
   switch (*ubp)
   {
      case 251:
         nullFlag = true;
         ubp++;
         return 0;
      case 252:
         t |= ubp[2];
         t <<= 8;
         t |= ubp[1];
         ubp += 3;
         return t;
      case 253:
         t |= ubp[3];
         t <<= 8;
         t |= ubp[2];
         t <<= 8;
         t |= ubp[1];
         ubp += 4;
         return t;
      case 254:
         t |= ubp[8];
         t <<= 8;
         t |= ubp[7];
         t <<= 8;
         t |= ubp[6];
         t <<= 8;
         t |= ubp[5];
         t <<= 8;
         t |= ubp[4];
         t <<= 8;
         t |= ubp[3];
         t <<= 8;
         t |= ubp[2];
         t <<= 8;
         t |= ubp[1];
         ubp += 9;
         return t;
      case 255:
      default:
         throw new MYX("The input value corresponds to an error packet.", __FILE__, __LINE__);
   }
}
/+
ulong parseLCB2(ref ubyte* ubp, ubyte* ep, out bool nullFlag, out bool incomplete)
{
   nullFlag = false;
   if (ubp >= ep)
   {
      incomplete  = true;
      return 0;
   }
   if (*ubp < 251)
   {
      return cast(ulong) *ubp++;
   }
   ulong t;
   switch (*ubp)
   {
      case 251:
         nullFlag = true;
         ubp++;
         return 0;
      case 252:
         if (ep-ubp < 3)
         {
            incomplete = true;
            return 0;
         }
         t |= ubp[2];
         t <<= 8;
         t |= ubp[1];
         ubp += 3;
         return t;
      case 253:
         if (ep-ubp < 4)
         {
            incomplete = true;
            return 0;
         }
         t |= ubp[3];
         t <<= 8;
         t |= ubp[2];
         t <<= 8;
         t |= ubp[1];
         ubp += 4;
         return t;
      case 254:
         if (ep-ubp < 9)
         {
            incomplete = true;
            return 0;
         }
         t |= ubp[8];
         t <<= 8;
         t |= ubp[7];
         t <<= 8;
         t |= ubp[6];
         t <<= 8;
         t |= ubp[5];
         t <<= 8;
         t |= ubp[4];
         t <<= 8;
         t |= ubp[3];
         t <<= 8;
         t |= ubp[2];
         t <<= 8;
         t |= ubp[1];
         ubp += 9;
         return t;
      case 255:
      default:
         throw new MYX("A length code value corresponds to an error packet.", __FILE__, __LINE__);
   }
}
+/
ubyte[] parseLCS(ref ubyte* ubp, out bool nullFlag)
{
   ubyte[] mt;
   ulong ul = parseLCB(ubp, nullFlag);
   if (nullFlag)
      return null;
   if (ul == 0)
      return mt;
   enforceEx!MYX(ul <= uint.max, "Protocol Length Coded String is too long");
   uint len = cast(uint) ul;
   ubyte* t = ubp;
   ubp += len;
   return t[0..len].dup;
}

ubyte[] packLength(uint l, out uint offset)
{
   ubyte[] t;
   if (!l)
   {
      t.length = 1;
      t[0] = 0;
      return t;
   }
   if (l <= 250)
   {
      t.length = 1+l;
      t[0] = cast(ubyte) l;
      offset = 1;
      return t;
   }
   else if (l <= 0xffff)
   {
      t.length = 3+l;
      t[0] = 252;
      t[1] = cast(ubyte) (l & 0xff);
      t[2] = cast(ubyte) ((l >> 8) & 0xff);
      offset = 3;
      return t;
   }
   else if (l < 0xffffff)
   {
      t.length = 4+l;
      t[0] = 253;
      t[1] = cast(ubyte) (l & 0xff);
      t[2] = cast(ubyte) ((l >> 8) & 0xff);
      t[3] = cast(ubyte) ((l >> 16) & 0xff);
      offset = 4;
      return t;
   }
   else
   {
      ulong u = cast(ulong) l;
      t.length = 9+l;
      t[0] = 254;
      t[1] = cast(ubyte) (u & 0xff);
      t[2] = cast(ubyte) ((u >> 8) & 0xff);
      t[3] = cast(ubyte) ((u >> 16) & 0xff);
      t[4] = cast(ubyte) ((u >> 24) & 0xff);
      t[5] = cast(ubyte) ((u >> 32) & 0xff);
      t[6] = cast(ubyte) ((u >> 40) & 0xff);
      t[7] = cast(ubyte) ((u >> 48) & 0xff);
      t[8] = cast(ubyte) ((u >> 56) & 0xff);
      offset = 9;
      return t;
   }
}

ubyte[] packLCS(void[] a)
{
   uint offset;
   ubyte[] t = packLength(a.length, offset);
   if (t[0])
      t[offset..$] = (cast(ubyte[]) a)[0..$];
   return t;
}

unittest
{
   bool isnull;
   ubyte[] uba = [ 0xde, 0xcc, 0xbb, 0xaa, 0x99, 0x88, 0x77, 0x66, 0x55, 0x01, 0x00 ];
   ubyte* ps = uba.ptr;
   ubyte* ubp = uba.ptr;
   ulong ul = parseLCB(ubp, isnull);
   assert(ul == 0xde && !isnull && ubp == ps+1);
   ubp = ps;
   uba[0] = 251;
   ul = parseLCB(ubp, isnull);
   assert(ul == 0 && isnull && ubp == ps+1);
   ubp = ps;
   uba[0] = 252;
   ul = parseLCB(ubp, isnull);
   assert(ul == 0xbbcc && !isnull && ubp == ps+3);
   ubp = ps;
   uba[0] = 253;
   ul = parseLCB(ubp, isnull);
   assert(ul == 0xaabbcc && !isnull && ubp == ps+4);
   ubp = ps;
   uba[0] = 254;
   ul = parseLCB(ubp, isnull);
   assert(ul == 0x5566778899aabbcc && !isnull && ubp == ps+9);
   ubyte[] buf;
   buf.length = 0x2000200;
   buf[] = '\x01';
   buf[0] = 250;
   buf[1] = '<';
   buf[249] = '!';
   buf[250] = '>';
   ubp = buf.ptr;
   ubyte[] x = parseLCS(ubp, isnull);
   assert(x.length == 250 && x[0] == '<' && x[249] == '>');
   buf[] = '\x01';
   buf[0] = 252;
   buf[1] = 0xff;
   buf[2] = 0xff;
   buf[3] = '<';
   buf[0x10000] = '*';
   buf[0x10001] = '>';
   ubp = buf.ptr;
   x = parseLCS(ubp, isnull);
   assert(x.length == 0xffff && x[0] == '<' && x[0xfffe] == '>');
   buf[] = '\x01';
   buf[0] = 253;
   buf[1] = 0xff;
   buf[2] = 0xff;
   buf[3] = 0xff;
   buf[4] = '<';
   buf[0x1000001] = '*';
   buf[0x1000002] = '>';
   ubp = buf.ptr;
   x = parseLCS(ubp, isnull);
   assert(x.length == 0xffffff && x[0] == '<' && x[0xfffffe] == '>');
   buf[] = '\x01';
   buf[0] = 254;
   buf[1] = 0xff;
   buf[2] = 0x00;
   buf[3] = 0x00;
   buf[4] = 0x02;
   buf[5] = 0x00;
   buf[6] = 0x00;
   buf[7] = 0x00;
   buf[8] = 0x00;
   buf[9] = '<';
   buf[0x2000106] = '!';
   buf[0x2000107] = '>';
   ubp = buf.ptr;
   x = parseLCS(ubp, isnull);
   assert(x.length == 0x20000ff && x[0] == '<' && x[0x20000fe] == '>');
}

struct OKPacket      // Used for error also
{
   bool error;
   bool nullFlag;
   ulong affected;
   ulong insertID;
   ushort serverStatus;
   ushort warnings;
   char[5] sqlState;
   char[] message;

   this(ubyte* ubp, uint length)
   {
      ubyte* ps = ubp;     // note packet start
      ubyte* pe = ps+length;
      if (*ubp)
      {
         error = true;
         // it's not OK
         enforceEx!MYX(*ubp == 255, "Malformed OK/Error packet");
         ubp++;

         enforceEx!MYX(ubp+2 < pe, "Malformed OK/Error packet");
         serverStatus = getShort(ubp);      // error code into server state
         if (*ubp == cast(ubyte) '#')
         {
            //4.1+ error packet
            ubp++;
            enforceEx!MYX(ubp+5 < pe, "Malformed OK/Error packet");
            sqlState[] = cast(char[]) ubp[0..5];
            ubp += 5;
         }
         uint rem = pe-ubp;
         if (rem)
         {
            message.length = rem;
            message[] = cast(char[]) ubp[0..rem];
         }
      }
      else
      {
         // It's OK - get supplied data
         bool gash;
         enforceEx!MYX(ubp+1 < pe, "Malformed OK/Error packet");
         ubp++;
         affected = parseLCB(ubp, gash);
         enforceEx!MYX(ubp+1 < pe, "Malformed OK/Error packet");
         insertID = parseLCB(ubp, gash);
         enforceEx!MYX(ubp+2 < pe, "Malformed OK/Error packet");
         serverStatus = getShort(ubp);
         enforceEx!MYX(ubp+2 <= pe, "Malformed OK/Error packet");
         warnings = getShort(ubp);
         uint rem = pe-ubp;
         if (rem)
         {
            message.length = rem;
            message[] = cast(char[]) ubp[0..rem];
         }
      }
   }
}

struct FieldDescription
{
private:
   string _db;
   string _table;
   string _originalTable;
   string _name;
   string _originalName;
   ushort _charSet;
   uint _length;
   uint _actualLength;
   ushort _type;
   ushort _flags;
   ubyte _scale;
   ulong _deflt;
   uint chunkSize;
   void delegate(ubyte[], bool) chunkDelegate;

public:
   this(ubyte[] packet)
   {
      ubyte* sp = packet.ptr;
      ubyte* ep = sp+packet.length;
      ubyte* ubp = sp+4;     // Skip catalog - it's always 'def'
      bool isnull;
      _db = cast(string) parseLCS(ubp, isnull);
      _table = cast(string) parseLCS(ubp, isnull);
      _originalTable = cast(string) parseLCS(ubp, isnull);
      _name = cast(string) parseLCS(ubp, isnull);
      _originalName = cast(string) parseLCS(ubp, isnull);
      enforceEx!MYX(ep-ubp >= 13, "Malformed field specification packet");
      ubp++;   // one byte of filler here
      _charSet = getShort(ubp);
      _length = getInt(ubp);
      _type = *ubp++;
      _flags = getShort(ubp);
      _scale = *ubp++;
      ubp += 2;      // 2 bytes filler here
      if (ubp < ep)
      {
         ubp++;      // one byte filler
         _deflt = parseLCB(ubp, isnull);
      }
   }
   @property string db() { return _db; }
   @property string table() { return _table; }
   @property string originalTable() { return _originalTable; }
   @property string name() { return _name; }
   @property string originalName() { return _originalName; }
   @property ushort charSet() { return _charSet; }
   @property uint length() { return _length; }
   @property ushort type() { return _type; }
   @property ushort flags() { return _flags; }
   @property ubyte scale() { return _scale; }
   @property bool notNull() { return (_flags & 1) != 0; }
   @property bool unsigned() { return (_flags & 0x20) != 0; }
   @property bool binary() { return (_flags & 0x80) != 0; }
   @property bool isenum() { return (_flags & 0x100) != 0; }
   @property bool isset() { return (_flags & 0x800) != 0; }

   void show()
   {
      writefln("%s %d %x %016b", _name, _length, _type, _flags);
   }
}

struct ParamDescription
{
private:
   ushort _type;
   ushort _flags;
   ubyte _scale;
   uint _length;
public:
   this(ubyte[] packet)
   {
      ubyte* ubp = packet.ptr;
      _type = getShort(ubp);
      _flags = getShort(ubp);
      _scale = *ubp++;
      _length = getInt(ubp);
   }
   @property uint length() { return _length; }
   @property ushort type() { return _type; }
   @property ushort flags() { return _flags; }
   @property ubyte scale() { return _scale; }
   @property bool notNull() { return (_flags & 1) != 0; }
   @property bool unsigned() { return (_flags & 0x20) != 0; }
}

struct EOFPacket
{
private:
   ushort _warnings;
   ushort _serverStatus;
public:
   this(ubyte[] packet)
   {
      ubyte* ubp = packet.ptr;
      ubyte* ep = ubp+packet.length;
      assert(*ubp == 0xfe && ep-ubp == 5);
      _warnings = getShort(ubp);
      _serverStatus = getShort(ubp);
   }
}

struct ResultSetHeaders
{
private:
   uint _fieldCount;
   FieldDescription[] _fieldDescriptions;
   string[] _fieldNames;
   ushort _warnings;

public:
   this(Connection con, uint fieldCount)
   {
      ubyte[] packet;
      ubyte* ubp;
      uint pl, n;
      ubyte pn;
      _fieldCount = fieldCount;
      _fieldDescriptions.length = _fieldCount;
      _fieldNames.length = _fieldCount;
      for (int i = 0; i < _fieldCount; i++)
      {
         packet = con.getPacket(pl);
         FieldDescription t = FieldDescription(packet);
         _fieldDescriptions[i] = FieldDescription(packet);
         _fieldNames[i] = _fieldDescriptions[i]._name;
      }
      packet = con.getPacket(pl);
      ubp = packet.ptr;
      enforceEx!MYX(*ubp == 0xfe && pl < 9,  "Expected EOF packet in result header sequence");   // check signature for EOF packet
      EOFPacket eof = EOFPacket(packet);
      con._serverStatus = eof._serverStatus;
      _warnings = eof._warnings;
   }

   void addSpecializations(ColumnSpecialization[] csa)
   {
      foreach(CSN csn; csa)
      {
         enforceEx!MYX(csn.cIndex < _fieldCount && _fieldDescriptions[csn.cIndex].type == csn.type,
                                       "Column specialization index or type does not match the corresponding column.");
         _fieldDescriptions[csn.cIndex].chunkSize = csn.chunkSize;
         _fieldDescriptions[csn.cIndex].chunkDelegate = csn.chunkDelegate;
      }
   }

   FieldDescription opIndex(size_t i) { return _fieldDescriptions[i]; }

   @property fieldCount() { return _fieldCount; }
   @property ushort warnings() { return _warnings; }
   @property string[] fieldNames() { return _fieldNames; }

   void show()
   {
      foreach (FieldDescription fd; _fieldDescriptions)
         fd.show();
   }
}

struct PreparedStmtHeaders
{
private:
   Connection _con;
   ushort _colCount, _paramCount;
   FieldDescription[] _colDescriptions;
   ParamDescription[] _paramDescriptions;
   ushort _warnings;

   bool getEOFPacket()
   {
      ubyte[] packet;
      uint pl;
      packet = _con.getPacket(pl);
      ubyte* ubp = packet.ptr;
      if (*ubp != 0xfe) //signature for EOF packet
         return false;
      EOFPacket eof = EOFPacket(packet);
      _con._serverStatus = eof._serverStatus;
      _warnings += eof._warnings;
      return true;
   }

public:
   this(Connection con, ushort cols, ushort params)
   {
      _con = con;
      _colCount = cols;
      _paramCount = params;
      _colDescriptions.length = cols;
      _paramDescriptions.length = params;
      ubyte[] packet;
      int i = 0;
      // The order in which fields are sent is params first, followed by EOF, then cols followed by EOF
      // The parameter specs are useless - they are all the same. This observation is coroborated
      // by the fact that the C API does not have any information about parameter types either.
      // WireShark gives up on these records also.
      for (; i < _paramCount; i++)
      {
         uint pl;
         _con.getPacket(pl);  // just eat them - they are not useful
      }
      if (_paramCount)
         enforceEx!MYX(getEOFPacket(), "Expected EOF packet in result header sequence");
      for (i = 0; i < _colCount; i++)
      {
         uint pl;
         packet = _con.getPacket(pl);
        _colDescriptions[i] = FieldDescription(packet);
      }
      if (_colCount)
         enforceEx!MYX(getEOFPacket(), "Expected EOF packet in result header sequence");
   }

   ParamDescription param(size_t i) { return _paramDescriptions[i]; }
   FieldDescription col(size_t i) { return _colDescriptions[i]; }

   @property paramCount() { return _paramCount; }
   @property ushort warnings() { return _warnings; }

   void showCols()
   {
      writefln("%d columns", _colCount);
      foreach (FieldDescription fd; _colDescriptions)
      {
         writefln("%10s %10s %10s %10s %10s %d %d %02x %016b %d",
                   fd._db, fd._table, fd._originalTable, fd._name, fd._originalName, fd._charSet, fd._length, fd._type, fd._flags, fd._scale);
      }
   }
}

class Connection
{
protected:
   Socket _socket;
   int _open;
   ubyte[] _packet;
   ubyte[4] _hdr;
   uint _sCaps, _sThread, _cCaps;
   uint _rbs, _sbs;
   ushort _serverStatus;
   ubyte _sCharSet, _protocol;
   ubyte[] _authBuf;
   ushort _pl;

   // This tiny thing here is pretty critical. Pay great attention to it's maintenance, otherwise
   // you'll get the dreaded "packet out of order" message. It, and the socket connection are
   // the reason why most other objects require a connection object for their construction.
   ubyte _cpn;
   string _serverVersion;
   string _host, _user, _pwd, _db;
   ubyte[] _token;

   @property pktNumber() { return _cpn; }
   void bumpPacket() { _cpn++; }
   void resetPacket() { _cpn = 0; }

   ubyte[] getPacket(out uint pl)
   {
      _socket.receive(_hdr);
      pl = (_hdr[2] << 16) + (_hdr[1] << 8) + _hdr[0];
      ubyte pn = _hdr[3];
      enforceEx!MYX(pn == _cpn, "Server packet out of order");
      _cpn++;
      _packet.length = pl;
      ubyte[] buf;
      buf.length = (pl > _rbs)? _rbs: pl;
      uint got = 0;
      uint n = _socket.receive(buf);
      for (;;)
      {
         _packet[got..got+n] = buf[0..n];
         got += n;
         if (got >= pl)
            break;
         if (pl-got < _rbs)
         buf.length = pl-got;
         n =_socket.receive(buf);
      }
      return _packet.dup;
   }

   void send(ubyte[] packet)
   {
      _socket.send(packet);
   }
   void sendCmd(ubyte cmd, string s)
   {
      _cpn  = 0;
      uint pl =s.length+1;
      _packet.length = pl+4;
      _packet[0] = cast(ubyte) (pl & 0xff);
      _packet[1] = cast(ubyte) ((pl >> 8) & 0xff);
      _packet[2] = cast(ubyte) ((pl >> 16) & 0xff);
      _packet[3] = 0;
      _packet[4] = cmd;
      _packet[5 .. s.length+5] = (cast(ubyte[]) s)[0..$];
      _cpn++;
      enforceEx!MYX(_socket.send(_packet) != -1, "Socket send failed");
   }

   OKPacket getCmdResponse(bool asString = false)
   {
      uint pl;
      getPacket(pl);
      ubyte* ubp = _packet.ptr;
      OKPacket okp = OKPacket(ubp, pl);
      enforceEx!MYX(!okp.error, "MySQL error: " ~ cast(string) okp.message);
      _serverStatus = okp.serverStatus;
      return okp;
   }

   uint buildAuthPacket()
   {
      _packet[] = 0;
      ubyte* p = _packet.ptr+4;
      // Set the default capabilities required by the client into the first four bytes
      *p++ = cast(ubyte) (_cCaps & 0xff);
      *p++ = cast(ubyte) ((_cCaps >> 8)  & 0xff);
      *p++ = cast(ubyte) ((_cCaps >> 16)  & 0xff);
      *p++ = cast(ubyte) ((_cCaps >> 24)  & 0xff);
      // Request a conventional maximum packet length.
      *p++ = 0;
      *p++ = 0;
      *p++ = 0;
      *p++ = 1;
      // Request utf-8 as default charSet
      *p++ = 33;
      // There's a statutory block of zero bytes here - fill them in.
      for (int i = 0; i < 23; i++)
         *p++ = 0;
      // Add the user name as a null terminated string
      for (int i = 0; i < _user.length; i++)
         *p++ = _user[i];
      *p++ = 0;
      // Add our calculated authentication token as a length prefixed string. It is basically a
      // SHA1 hash, so we know how long is is.
      *p++ = 20;
      for (int i = 0; i < 20; i++)
         *p++ = _token[i];
      // if the default database is being set, add this finally as a null terminated string.
      if (_db.length)
      {
         for (int i = 0; i < _db.length; i++)
            *p++ = _db[i];
         *p++ = 0;
      }
      // Now we can determine the size of the packet and trim the array to that length.
      uint pl = p - _packet.ptr;
      _packet.length = pl;
      // Back to the beginning of the packet
      p = _packet.ptr;
      // The calculated length is from the packet start as opposed to the content start,
      // so allow for the packet header before we fill it in.
      pl -= 4;
      // The server sent us a greeting with packet number 0, so we send the auth packet
      // back with the next number.
      p[3] = _cpn++;
      // Fill in the logical packet length. We can skip the most significant byte, since at the worst
      // it is a short packet.
      p[2] = 0;
      p[1] = cast(ubyte) ((pl >> 8) & 0xff);
      p[0] = cast(ubyte) (pl & 0xff);
      // Hopefully at this point it is ready to send.
      return pl;
   }

   void getServerInfo(ref ubyte* p)
   {
      _sCaps = (p[6] << 24) + (p[5] << 16) + (p[1] << 8) + p[0];
      _sCharSet = p[2];
      _serverStatus = (p[4] << 8) + p[3];
      p += 7;
   }

   void parseGreeting()
   {
      ubyte* p = _packet.ptr+4;
      _protocol = *p++;
      uint len, offset;
      ubyte* q = p;
      offset = q-_packet.ptr;
      while (*p) p++;
      len = p-q;
      _serverVersion = cast(string) _packet[offset..offset+len].idup;
      p++;
      _sThread = getInt(p);
      _authBuf.length = 255;
      for (int i = 0; i < 8; i++)
         _authBuf[i] = *p++;
      assert(*p == 0);
      p++;
      getServerInfo(p);
      p++;             // this byte supposed to be scramble length, but is actually zero
      p += 10;       // skip 10 bytes of filler
      len = 8;
      for (int i = 0; *p; i++, len++)
         _authBuf[8+i] = *p++;
      _authBuf.length = len;
      assert(*p == 0);
   }

   void init_connection()
   {
      _socket = new TcpSocket();
      Address a = new InternetAddress("localhost", InternetAddress.PORT_ANY);
      _socket.bind(a);
      a = new InternetAddress(_host, 3306);
      _socket.setOption(SocketOptionLevel.SOCKET,
                                SocketOption.RCVBUF, (1 << 24)-1);
      int rbs;
      _socket.getOption(SocketOptionLevel.SOCKET, SocketOption.RCVBUF, rbs);
      _rbs = rbs;
      _socket.connect(a);
      _packet.length = 255;
      _socket.receive(_packet);
      _cpn++;
   }

   ubyte[] makeToken()
   {
      SHA1 sha1;
      sha1.reset();
      ubyte[] pass1;
      ubyte[] pass2;
      ubyte[] cat;
      ubyte[] result;
      sha1.input(cast(const(ubyte)*) _pwd.ptr, _pwd.length);
      pass1 = sha1.result();
      sha1.reset();
      sha1.input(pass1.ptr, pass1.length);
      pass2 = sha1.result();
      sha1.reset();
      sha1.input(_authBuf.ptr, _authBuf.length);
      sha1.input(pass2.ptr, pass2.length);
      result = sha1.result();
      for (int i = 0; i < 20; i++)
         result[i] = result[i] ^ pass1[i];
      return result;
   }

   void setClientFlags()
   {
      _cCaps |= SvrCapFlags.SECURE_PWD;
      _cCaps |= SvrCapFlags.ALL_COLUMN_FLAGS;
      _cCaps |= SvrCapFlags.WITH_DB;
      _cCaps |= SvrCapFlags.PROTOCOL41;
      _cCaps |= SvrCapFlags.SECURE_CONNECTION;
      _cCaps |= SvrCapFlags.MULTI_STATEMENTS;
      _cCaps |= SvrCapFlags.MULTI_RESULTS;
   }

   static string[] parseConnectionString(string cs)
   {
      string[] rv;
      rv.length = 4;
      string[] a = split(cs, ";");
      foreach (s; a)
      {
         string[] a2 = split(s, "=");
         if (a2.length != 2)
            throw new Exception("Bad connection string: " ~ cs);
         string name = strip(a2[0]);
         string val = strip(a2[1]);
         val ~= "\0";
         switch (name)
         {
            case "host":
               rv[0] = val;
               break;
            case "user":
               rv[1] = val;
               break;
            case "pwd":
               rv[2] = val;
               break;
            case "db":
               rv[3] = val;
               break;
            default:
               throw new Exception("Bad connection string: " ~ cs);
               break;
         }
      }
      return rv;
   }

   ~this() { if (_open) close(); }

public:

   this(string host, string user, string pwd, string db)
   {
      _host = host;
      _user = user;
      _pwd = pwd;
      _db = db;
      init_connection();
      parseGreeting();
      _open = 1;
   }

   this(string cs)
   {
      string[] a = parseConnectionString(cs);
      _host = a[0];
      _user = a[1];
      _pwd = a[2];
      _db = a[3];
      init_connection();
      parseGreeting();
      _open = 1;
   }

   bool open()
   {
      _token = makeToken();
      setClientFlags();
      buildAuthPacket();
      _socket.send(_packet);
      uint pl;
      getPacket(pl);
      ubyte* ubp = _packet.ptr;
      OKPacket okp = OKPacket(ubp, pl);
      enforceEx!MYX(!okp.error, "Authentication failure: " ~ cast(string) okp.message);
      _open = 2;
      return true;
   }

   void close()
   {
      if (_open > 1)
      {
         _packet.length = 5;
         _packet[] = [1, 0, 0, 0, 1 ];
         _socket.send(_packet);
         _open--;
      }
      if (_open)
      {
         _socket.shutdown(SocketShutdown.BOTH);
         _socket.close();
      }
      _open = 0;
      _cpn = 0;
   }

   void selectDB(string dbName)
   {
      sendCmd(2, dbName);
      getCmdResponse();
   }

   OKPacket pingServer()
   {
      sendCmd(0x0e, "");
      return getCmdResponse();
   }

   OKPacket refreshServer(int flags)
   {
      ubyte[] t;
      t.length = 1;
      t[0] = cast(ubyte) flags;
      sendCmd(0x07, cast(string) t);
      return getCmdResponse();
   }

   string serverStats()
   {
      sendCmd(0x09, "");
      uint pl;
      getPacket(pl);
      return cast(string) _packet;
   }

   void enableMultiStatements(bool on)
   {
      ubyte[] t;
      t.length = 2;
      t[0] = on? 0: 1;
      t[1] = 0;
      sendCmd(0x1b, cast(string) t);

      // For some reason this command gets an EOF packet as response
      uint pl;
      getPacket(pl);
      enforceEx!MYX(_packet[0] == 254 && pl == 5, "Unexpected response to SET_OPTION command");
   }

   @property socket() { return _socket; }
   @property protocol() { return _protocol; }
   @property serverVersion() { return _serverVersion; }
   @property serverCapabilities() { return _sCaps; }
   @property serverStatus() { return _serverStatus; }
   @property charSet() { return _sCharSet; }
   @property currentDB() { return _db; }
}

unittest
{
   Connection c;
   try
   {
      c = new Connection("localhost", "user", "password", "mysqld");
      c.open();
      scope(exit) c.close();
      // These may vary according to the server setup
      assert(c.protocol == 10);
      assert(c.serverVersion == "5.1.54-1ubuntu4");
      assert(c.serverCapabilities == 0b1111011111111111);
      assert(c.serverStatus == 2);
      assert(c.charSet == 8);
      try {
         c.selectDB("rabbit");
      }
      catch (Exception x)
      {
         assert(x.msg.indexOf("Access denied") > 0);
      }
      OKPacket okp = c.pingServer();
      assert(okp.serverStatus == 2);
      try {
         okp = c.refreshServer(RefreshFlags.GRANT);
      }
      catch (Exception x)
      {
         assert(x.msg.indexOf("Access denied") > 0);
      }
      string stats = c.serverStats();
      assert(stats.indexOf("Uptime") == 0);
      c.enableMultiStatements(true);   // Need to be tested later with a prepared "CALL"
      c.enableMultiStatements(false);
      c.close();
   }
   catch (Exception x)
   {
      writefln("(%s: %s) %s", x.file, x.line, x.msg);
   }
   writeln("Connection unit tests done");
}

typedef void[] delegate(ref uint) InChunkDelegate;
typedef void delegate(void[], ulong) OutChunkDelegate;

struct ParameterSpecialization
{
   uint pIndex;    //parameter number 0 - number of params-1
   bool isNull;
   SQLType type = SQLType.DEFAULT;
   // If you need to send large objects to the database it might be convenient to
   // send them in pieces. These two variables allow for this. If both are provided
   // then the corresponding column will be populated by calling the delegate repeatedly.
   // the source should fill the indicated slice with data and arrange for the delegate to
   // return the length of the data supplied. Af that is less than the length of the slice
   // then the chunk will be assumed to be the last one.
   uint chunkSize;
   uint delegate(ubyte[]) chunkDelegate;
}
alias ParameterSpecialization PSN;

struct ColumnSpecialization
{
   uint cIndex;    //parameter number 0 - number of params-1
   ushort type;
   // If you are executing a query that will include result columns that are large objects
   // it may be expedient to deal with the data as it is received rather than first buffering
   // it to some sort of byte array. These two variables allow for this. If both are provided
   // then the corresponding column will be fed to the stipulated delegate in chunks of
   // chunkSize, with the possible exception of the last chunk, which may be smaller.
   // The 'finished' argument will be set to true when the last chunk is set.
   //
   // Be aware when specifying types for column specializations that for some reason the
   // field descriptions returned for a resultset have all of the types TINYTEXT, MEDIUMTEXT,
   // TEXT, LONGTEXT, TINYBLOB, MEDIUMBLOB, BLOB, and LONGBLOB lumped as type 0xfc
   // contrary to what it says in the protocol documentation.
   uint chunkSize;
   void delegate(ubyte[] chunk, bool finished) chunkDelegate;
}
alias ColumnSpecialization CSN;

struct Row
{
private:
   MyVariant[] _uva;
   bool[] _nulls;
   bool _valid;

   T fromBytes(T, int N = 0)(ref uint p, ubyte[] packet, out bool incomplete) if (is(T: ulong))
   {
      ulong ac = 0;
      uint len = N? N: T.sizeof;
      if (p+len >= packet.length-1)
         incomplete = true;
      else
      {
         for (uint i = p+len-1; i >= p; i--) { ac <<= 8; ac |= packet[i];  }
         p += len;
      }
      return cast(T) ac;
   }

   // This is to decode the bitmap in a binary result row. First two bits are skipped
   static bool[] decodeBitmap(ubyte[] bits, uint cols)
   {
      bool[] rv;
      rv.length = cols;
      uint next = 1;
      uint rem = 6;
      ubyte src = bits[0] >> 2;
      uint n = 0;
      for (;;)
      {
         if (n >= cols)
            break;
         if (!rem)
         {
            src = bits[next++];
            rem = 8;
         }
         rv[n++] = (src & 1) != 0;
         src >>= 1;
         rem--;
      }
      return rv;
   }

public:

   this(Connection con, ubyte[] packet, ResultSetHeaders rh, bool binary)
   {
      uint fc = rh._fieldCount;
      _uva.length = fc;
      _nulls.length = fc;
      uint p = 0;
      uint pl = packet.length;
      uint tl;
      bool nullFlag, incomplete, gotPrefix;
      ulong lc;

      // This is used to decode byte array length prefixes, which may be from 1 to 9 bytes.
      // Either the prefix or the following bytes may be incomplete - truncated by the end of the packet.
      // We distinguish between these cases.
      ulong parseLCB()
      {
         incomplete = gotPrefix = false;
         nullFlag = false;
         lc = 0;
         if (p > pl-1)
         {
            incomplete  = true;
            return 0;
         }
         switch (packet[p])
         {
            case 251:
               nullFlag = true;
               p++;
               break;
            case 252:
               if (pl-p < 3)
               {
                  incomplete = true;
                  return 0;
               }
               for (uint i = p+2; i > p; i--) { lc <<= 8; lc |= packet[i];  }
               p += 3;
               break;
            case 253:
               if (pl-p < 4)
               {
                  incomplete = true;
                  return 0;
               }
               for (uint i = p+3; i > p; i--) { lc <<= 8; lc |= packet[i];  }
               p += 4;
               break;
            case 254:
               if (pl-p < 9)
               {
                  incomplete = true;
                  return 0;
               }
               for (uint i = p+8; i > p; i--) { lc <<= 8; lc |= packet[i];  }
               p += 9;
               break;
            case 255:
               throw new MYX("Unexpected error packet prefix.", __FILE__, __LINE__);
            default:
               lc = packet[p++];
               break;
         }
         gotPrefix = true;
         if (pl-p < lc)
            incomplete = true;
         return lc;
      }


      if (binary)
      {
         // There's a null byte header on a binary result sequence, followed by some bytes of bitmap
         // indicating which columns are null
         enforceEx!MYX(packet[p++] == 0, "Expected null header byte for binary result row");
         uint bml = (fc+7+2)/8;
         _nulls = decodeBitmap(packet[p..p+bml], fc);
         p += bml;
      }

      for (int i = 0; i < fc; i++)
      {
         FieldDescription fd = rh[i];
         bool isnull = false;
         bool chunked = (fd.chunkSize > 0);
         bool uns = fd.unsigned;
         uint checkpoint = p;

         if (binary)
         {
            // Prepared statement result sets are packed differently than traditional MySQL result sets.
            // Most types come in their normal memory layout (little-endian). Strings are prefixed by a coded length
            // that could in theory be up to ulong.max, but since the largest blob is currently uint.max
            // that's all we'll use.
            if (_nulls[i])
               continue;      // The bitmap said this column is NULL, so there will be no data for it and we skip to the next.
            switch (fd.type)
            {
               case  0x01:  // TINYINT
                  ubyte ub = fromBytes!ubyte(p, packet, incomplete);
                  if (incomplete) break;  // The packet we ar looking at does not contain the entire result row - we must fetch another
                  if (uns)
                     _uva[i] = ub;
                  else
                     _uva[i] = cast(byte) ub;
                  break;
               case 0x02:  // SHORT
                  ushort us =  fromBytes!ushort(p, packet, incomplete);
                  if (incomplete) break;
                  if (uns)
                     _uva[i] = us;
                  else
                     _uva[i] = cast(short) us;
                  break;
               case 0x03:  // INT
                  uint ui =  fromBytes!uint(p, packet, incomplete);
                  if (incomplete) break;
                  if (uns)
                     _uva[i] = ui;
                  else
                     _uva[i] = cast(int) ui;
                  break;
               case 0x04:  // FLOAT
                  if (pl-p < 4)
                  {
                     incomplete = true;
                     break;
                  }
                  float f = 0;
                  ubyte* fp = cast(ubyte*) &f;
                  fp[0..4] = packet[p..p+4];
                  p += 4;
                  _uva[i] = f;
                  break;
               case 0x05:  // DOUBLE
                  if (pl-p < 8)
                  {
                     incomplete = true;
                     break;
                  }
                  double d = 0;
                  ubyte* dp = cast(ubyte*) &d;
                  dp[0..8] = packet[p..p+8];
                  p += 8;
                  _uva[i] = d;
                  break;
               case 0x06:  // NULL
                  _nulls[i] = true;
                  break;
               case 0x07:  // TIMESTAMP
                  // The length of all the time/date types can be indicated by a byte
                  tl = packet[p];
                  if (pl-p < tl+1)
                  {
                     incomplete = true;
                     break;
                  }
                  _uva[i] = toDateTime(packet[p..p+tl+1]);
                  p += tl+1;
                  break;
               case 0x08:  // LONGLONG
                  ulong ul =  fromBytes!ulong(p, packet, incomplete);
                  if (uns)
                     _uva[i] = ul;
                  else
                     _uva[i] = cast(long) ul;
                  break;
               case 0x09:  // INT24
                  uint ui24 =  fromBytes!(uint, 3)(p, packet, incomplete);
                  if (incomplete) break;
                  if (uns)
                     _uva[i] = ui24;
                  else
                     _uva[i] = cast(int) ui24;
                  break;
               case 0x10:  // BIT - equated here to bool
                  if (pl-p < 2)
                  {
                     incomplete = true;
                     break;
                  }
                  enforceEx!MYX(packet[p++] == 1, "Expected single bit for bool column");
                  bool bv = (packet[p++] == 1);
                  _uva[i] = bv;
                  break;
               case 0x0a:  // DATE
                  tl = packet[p];
                  if (pl-p < tl+1)
                  {
                     incomplete = true;
                     break;
                  }
                  _uva[i] = toDate(packet[p..p+tl+1]);
                  p += tl+1;
                  break;
               case 0x0b:  // TIME
                  tl = packet[p];
                  if (pl-p < packet[p]+1)
                  {
                     incomplete = true;
                     break;
                  }
                  _uva[i] = toTimeOfDay(packet[p..p+tl+1]);
                  p += tl+1;
                  break;
               case 0x0c:  // DATETIME
                  tl = packet[p];
                  if (pl-p < tl+1)
                  {
                     incomplete = true;
                     break;
                  }
                  _uva[i] = toDateTime(packet[p..p+tl+1]);
                  p += tl+1;
                  break;
               case 0x0d:  // YEAR - appears to be an unsigned short
                  ushort y =  fromBytes!ushort(p, packet, incomplete);
                  if (incomplete) break;
                  _uva[i] = y;
                  break;
               case 0x0f:   // VARCHAR
               case 0xf7:   // ENUM          both this and SET actually get sent by the protocol as BLOB - 0xfe
               case 0xf8:   // SET
               case 0xfd:   // VAR_STRING
               case 0xfe:   // STRING
                  uint sl = cast(uint) parseLCB();
                  if (incomplete) break;
                  _uva[i] = cast(string) packet[p..p+sl];
                  p += sl;
                  break;
               case 0xf9:   // TINY_BLOB
               case 0xfa:   // MEDIUM_BLOB
               case 0xfb:   // LONG_BLOB
                  uint sl = cast(uint) parseLCB();
                  if (incomplete) break;
                  _uva[i] = cast(ubyte[]) packet[p..p+sl];
                  p += sl;
                  break;
               case 0xfc:   // BLOB
                  uint sl = cast(uint) parseLCB();
                  if (incomplete) break;
                  if (fd.binary)
                     _uva[i] = cast(ubyte[]) packet[p..p+sl];
                  else
                     _uva[i] = packet[p..p+sl];
                  p += sl;
                  break;
               default:
                  throw new MYX("Unsupported type in row - " ~ to!string(fd.type), __FILE__, __LINE__);
                  break;
            }
         }
         else
         {
            // This is a traditional MySQL row with all the data represented as byte strings. Ideally it should be possible
            // to tell a V5.x server to send all results in the same format, but this does not appear to be possible at this point
            string val;
            // We make the test for sufficient data remaining in the packet as we get the string length.
            uint sl = cast(uint) parseLCB();
            if (incomplete) goto Incomplete;
            val = cast(string) packet[p..p+sl];
            p += sl;
            if (nullFlag)
            {
               // In this data sequence, null columns are indicated by a single 251 byte, so we construct the _nulls array
               // as we go along, skipping the null columnns
               _nulls[i] = true;
               continue;
            }
            switch (fd.type)
            {
               case  0x01:  // TINYINT
                  if (uns)
                     _uva[i] = to!ubyte(val);
                  else
                     _uva[i] = to!byte(val);
                  break;
               case 0x02:  // SHORT
                  if (uns)
                     _uva[i] = to!ushort(val);
                  else
                     _uva[i] = to!short(val);
                  break;
               case 0x03:  // INT
               case 0x09:
                  if (uns)
                     _uva[i] = to!uint(val);
                  else
                     _uva[i] = to!int(val);
                  break;
               case 0x04:  // FLOAT
                  _uva[i] = to!float(val);
                  break;
               case 0x05:  // DOUBLE
                  _uva[i] = to!double(val);
                  break;
               case 0x06:  // NULL
                  _nulls[i] = true;
                  break;
               case 0x07:  // TIMESTAMP
                  _uva[i] = toDateTime(val);
                  break;
               case 0x08:  // LONGLONG
                  if (uns)
                     _uva[i] = to!ulong(val);
                  else
                     _uva[i] = to!long(val);
                  break;
               case 0x10:  // BIT - equated here to bool
                  val = val[0]? "true": "false";
                  _uva[i] = to!bool(val);
                  break;
               case 0x0a:  // DATE
                  _uva[i] = toDate(val);
                  break;
               case 0x0b:  // TIME
                  _uva[i] = toTimeOfDay(val);
                  break;
               case 0x0c:  // DATETIME
                  _uva[i] = toDateTime(val);
                  break;
               case 0x0d:  // YEAR - treat as unsigned short to match the prepared case
                  _uva[i] = to!ushort(val);
                  break;
               case 0x0f:   // VARCHAR - new in 5.0, but does not appear for a VARCHAR column
               case 0xf7:   // ENUM          both this and SET actually get sent by the protocol as BLOB - 0xfe
               case 0xf8:   // SET
               // For some reason column type TINYTEXT TEXT MEDIUMTEXT LONGTEXT all appear as BLOB - 0xfc
               // They don't even have values in the list of protocol types
               case 0xfd:   // VAR_STRING
               case 0xfe:   // STRING
                  _uva[i] = val;
                  break;
               case 0xf9:   // TINY_BLOB
               case 0xfa:   // MEDIUM_BLOB
               case 0xfb:   // LONG_BLOB
                  _uva[i] = cast(ubyte[]) val;
                  break;
               case 0xfc:   // Covers a multitude of sins  - TINYTEXT TEXT MEDIUMTEXT LONGTEXT all appear as BLOB - 0xfc
                  if (fd.binary)
                     _uva[i] = cast(ubyte[]) val;
                  else
                     _uva[i] = val;
                  break;
               default:
                  throw new MYX("Unsupported type in row - " ~ to!string(fd.type), __FILE__, __LINE__);
                  break;
            }
         }
      Incomplete:
      /+
         if (incomplete)
         {
            // The server wil have sent the maximum logical packet, and will follow that with further
            // packets containing the remaining data for the row. So if we have determined that the data
            // for a column is incomplete, we must now now fetch at least the next one.
            // We take the opportunity to save memory here by chopping off the part of the current packet
            // that we have already used
            uint npl;
            ubyte[] more = con.getPacket(npl);
            packet = packet[checkpoint..pl] ~ more;
            p = 0;   // previous stuff now gone
            checkpoint = p;
            pl = packet.length;
            i--;  // backtrack and try again to get the column where we failed. This could cause
                  // further logical packets to be fetched in the case of a long blob.
            incomplete = false;
         }
         +/
         if (incomplete)
         {
            // The server wil have sent the maximum logical packet, and will follow that with further
            // packets containing the remaining data for the row. So if we have determined that the data
            // for a column is incomplete, we must now now fetch at least the next one.
            // We take the opportunity to save memory here by chopping off the part of the current packet
            // that we have already used. If the column is specialized to be chunked, we also nibble off
            // as much as possible before getting the next packet
            uint npl;
            if (gotPrefix && chunked)
            {
               // We know how long the byte stream is, and we are going to chunk it, so we can read packets
               // until we've got the required length and dispose of the bytes via the delegate.
               uint remaining = cast(uint) lc;
               uint cs = fd.chunkSize;
               checkpoint = p;
               void delegate(ubyte[], bool) dg = fd.chunkDelegate;

               // First get rid of the bytes in the existing packet
               while (pl-checkpoint > cs)
               {
                  dg(packet[checkpoint..checkpoint+cs], false);
                  checkpoint += cs;
                  remaining -= cs;
               }
               ubyte[] more = con.getPacket(npl);
               packet = packet[checkpoint..pl] ~ more;
               pl = packet.length;
               p = 0;

               eatPackets:
               for (;;)
               {
                  while (pl-p >= cs)
                  {
                     if (remaining <= cs)
                     {
                        dg(packet[p..p+remaining], true);
                        p += remaining;
                        break eatPackets;
                     }
                     dg(packet[p..p+cs], false);
                     p += cs;
                     remaining -= cs;
                  }
                  more = con.getPacket(npl);
                  packet = packet[p..pl] ~ more;
                  pl = packet.length;
                  p = 0;
               }
               // At this point we should be good to process the next column
            }
            else
            {
               // Process without chunking - pull in more packets uintil we have enough data
               // to get the incomplete column.
               ubyte[] more = con.getPacket(npl);
               packet = packet[checkpoint..pl] ~ more;
               p = 0;   // previous stuff now gone
               checkpoint = p;
               pl = packet.length;
               i--;  // backtrack and try again to get the column where we failed. This could cause
                     // further logical packets to be fetched in the case of a long blob.
            }
            incomplete = false;
         }
      }
      _valid = true;
   }

   MyVariant opIndex(uint i) { return _uva[i]; }
   @property bool isNull(uint i) { return _nulls[i]; }

   /**
    * Move the content of the row into a compatible struct
    *
    */
   void toStruct(S)(ref S s) if (is(S == struct))
   {
      foreach (i, dummy; s.tupleof)
      {
         enforceEx!MYX(_uva[i].convertsTo!(typeof(s.tupleof[i]))(),
                       "At col "~to!string(i)~" the value is not implicitly convertible to the structure type");
         s.tupleof[i] = _nulls[i]? typeof(s.tupleof[i]).init: _uva[i].get!(typeof(s.tupleof[i]));
      }
   }

   void show()
   {
      foreach(MyVariant v; _uva)
         writef("%s, ", v.toString());
      writeln("");
   }
}

struct Column
{
   MyVariant val;
   bool isNull;
}

struct ResultSet
{
private:
   Row[] _ra;
   string[] _colNames;
   size_t[] _rb;  // Current span of the range
   size_t _rc;

   this (Row[] ra, string[] colNames)
   {
      _ra = ra;
      _rc = ra.length;
      _colNames = colNames;
      _rb.length = _ra.length;
      for (int i = 0; i < _ra.length; i++)
         _rb[i] = i;
   }

public:
   /**
    * Make the ResultSet behave as a random access range - empty
    *
    */
   @property bool empty() { return (_rb.length == 0); }
   /**
    * Make the ResultSet behave as a random access range - save
    *
    */
   @property ResultSet save()
   {
      return this;
   }
   /**
    * Make the ResultSet behave as a random access range - front
    *
    * Gets the first row in whatever remains of the Range.
    */
   @property Row front()
   {
      enforceEx!MYX(_rb.length, "Attempted 'front' on empty ResultSet range.");
      return _ra[_rb[0]];
   }
   /**
    * Make the ResultSet behave as a random access range - back
    *
    * Gets the last row in whatever remains of the Range.
    */
   @property Row back()
   {
      enforceEx!MYX(_rb.length, "Attempted 'back' on empty ResultSet range.");
      return _ra[_rb[$-1]];
   }
   /**
    * Make the ResultSet behave as a random access range - popFront()
    *
    */
   void popFront()
   {
      if (!_rb.length)
         throw new Exception("Attempted 'popFront' on empty ResultSet range.");
      _rb= _rb[1 .. $];
   }
   /**
    * Make the ResultSet behave as a random access range - popBack
    *
    */
   void popBack()
   {
      enforceEx!MYX(_rb.length, "Attempted 'popBack' on empty ResultSet range.");
      // Fetch the required row
      _rb= _rb[0 .. $-1];
   }
   /**
    * Make the ResultSet behave as a random access range - opIndex
    *
    * Gets the i'th row of whatever remains of the range
    */
   Row opIndex(size_t i)
   {
      enforceEx!MYX(_rb.length, "Attempted to index into an empty ResultSet range.");
      enforceEx!MYX(i < _rb.length, "Requested range index out of range");
      return _ra[_rb[i]];
   }
   /**
    * Make the ResultSet behave as a random access range - length
    *
    */
   @property size_t length() { return _rb.length; }

   /**
    * Restore the range to its original span
    *
    */
   void revert()
   {
       _rb.length = _ra.length;
      for (int i = 0; i < _ra.length; i++)
         _rb[i] = i;
  }

   /**
    * Get a row as an associative array by column name
    *
    */
    Column[string] colsByName(Row r)
    {
       Column[string] aa;
       foreach (uint i, string s; _colNames)
       {
          Column c;
          c.val = r._uva[i];
          c.isNull = r._nulls[i];
          aa[s] = c;
       }
       return aa;
    }
}

struct Command
{
private:
   Connection _con;
   Socket _socket;
   string _sql;
   uint _hStmt;
   ulong _insertID;
   bool _rowsPending, _headersPending, _pendingBinary, _rebound;
   ushort _psParams, _psWarnings, _fieldCount;
   ResultSetHeaders _rsh;
   PreparedStmtHeaders _psh;
   MyVariant[] _inParams;
   ParameterSpecialization[] _psa;

   bool sendCmd(ubyte cmd)
   {
      enforceEx!MYX(!(_headersPending || _rowsPending), "There are result set elements pending - purgeResult() required.");
      _con.resetPacket();
      ubyte[] packet;
      uint pl = _sql.length+1;
      packet.length = pl+4;
      ubyte* ubp = packet.ptr;
      packet[0] = cast(ubyte) (pl & 0xff);
      packet[1] = cast(ubyte) ((pl >> 8) & 0xff);
      packet[2] = cast(ubyte) ((pl >> 16) & 0xff);
      packet[3] = 0;
      packet[4] = cmd;
      packet[5 .. _sql.length+5] = (cast(ubyte[]) _sql)[0..$];
      _fieldCount = 0;
      _con.bumpPacket();
      _con.send(packet);
      return true;
   }

   static ubyte[] makeBitmap(ParameterSpecialization[] psa)
   {
      uint bml = (psa.length+7)/8;
      ubyte[] bma;
      bma.length = bml;
      foreach (uint i, PSN psn; psa)
      {
         if (!psn.isNull)
            continue;
         uint bn = i/8;
         uint bb = i%8;
         ubyte sr = 1;
         sr <<= bb;
         bma[bn] |= sr;
      }
      return bma;
   }

   ubyte[] makePSPrefix(ubyte flags = 0)
   {
      ubyte[] prefix;
      prefix.length = 14;

      prefix[4] = 0x17;
      prefix[5] = cast(ubyte) (_hStmt & 0xff);
      prefix[6] = cast(ubyte) ((_hStmt >> 8) & 0xff);
      prefix[7] = cast(ubyte) ((_hStmt >> 16) & 0xff);
      prefix[8] = cast(ubyte) ((_hStmt >> 24) & 0xff);
      prefix[9] = flags;   // flags, no cursor
      prefix[10] = 1; // iteration count - currently always 1
      prefix[11] = 0;
      prefix[12] = 0;
      prefix[13] = 0;

      return prefix;
   }

   ubyte[] analyseParams(out ubyte[] vals, out bool longData)
   {
      uint pc = _inParams.length;
      ubyte[] types;
      types.length = pc*2;
      uint alloc = pc*20;
      vals.length = alloc;
      uint vcl = 0, len;
      int ct = 0;

      void reAlloc(uint n)
      {
         if (vcl+n < alloc)
            return;
         uint inc = (alloc*3)/2;
         if (inc <  n)
            inc = n;
         alloc += inc;
         vals.length = alloc;
      }

      for (int i = 0; i < pc; i++)
      {
         if (_psa[i].chunkSize)
            longData= true;
         bool isnull = _psa[i].isNull;
         MyVariant v = _inParams[i];
         SQLType ext = _psa[i].type;
         switch (v.type.toString())
         {
            case "bool":
               if (ext == SQLType.DEFAULT)
                  types[ct++] = 0x10;  // BIT
               else
                  types[ct++] = cast(ubyte) ext;
               types[ct++] = 0;
               if (isnull) break;
               reAlloc(2);
               vals[vcl++] = 1;
               vals[vcl++] = (v == true)? 0x31: 0x30;
               break;
            case "byte":   // TINY
               types[ct++] = 0x01;
               types[ct++] = 0;
               if (isnull) break;
               reAlloc(1);
               vals[vcl++] = v.get!(byte);
               break;
            case "ubyte":  // TINY UNSIGNED
               types[ct++] = 0x01;
               types[ct++] = 0x80;
               if (isnull) break;
               reAlloc(1);
               vals[vcl++] = v.get!(ubyte);
               break;
            case "short":
               types[ct++] = 0x02;
               types[ct++] = 0;
               if (isnull) break;
               reAlloc(2);
               short si = v.get!(short);
               vals[vcl++] = cast(ubyte) (si & 0xff);
               vals[vcl++] = cast(ubyte) ((si >> 8) & 0xff);
               break;
            case "ushort":
               types[ct++] = 0x02;
               types[ct++] = 0x80;
               reAlloc(2);
               ushort us = v.get!(ushort);
               vals[vcl++] = cast(ubyte) (us & 0xff);
               vals[vcl++] = cast(ubyte) ((us >> 8) & 0xff);
               break;
            case "int":
               types[ct++] = 0x03;
               types[ct++] = 0;
               if (isnull) break;
               reAlloc(4);
               int ii = v.get!(int);
               vals[vcl++] = cast(ubyte) (ii & 0xff);
               vals[vcl++] = cast(ubyte) ((ii >> 8) & 0xff);
               vals[vcl++] = cast(ubyte) ((ii >> 16) & 0xff);
               vals[vcl++] = cast(ubyte) ((ii >> 24) & 0xff);
               break;
            case "uint":
               types[ct++] = 0x03;
               types[ct++] = 0x80;
               if (isnull) break;
               reAlloc(4);
               uint ui = v.get!(uint);
               vals[vcl++] = cast(ubyte) (ui & 0xff);
               vals[vcl++] = cast(ubyte) ((ui >> 8) & 0xff);
               vals[vcl++] = cast(ubyte) ((ui >> 16) & 0xff);
               vals[vcl++] = cast(ubyte) ((ui >> 24) & 0xff);
               break;
            case "long":
               types[ct++] = 0x08;
               types[ct++] = 0;
               if (isnull) break;
               reAlloc(8);
               long li = v.get!(long);
               vals[vcl++] = cast(ubyte) (li & 0xff);
               vals[vcl++] = cast(ubyte) ((li >> 8) & 0xff);
               vals[vcl++] = cast(ubyte) ((li >> 16) & 0xff);
               vals[vcl++] = cast(ubyte) ((li >> 24) & 0xff);
               vals[vcl++] = cast(ubyte) ((li >> 32) & 0xff);
               vals[vcl++] = cast(ubyte) ((li >> 40) & 0xff);
               vals[vcl++] = cast(ubyte) ((li >> 48) & 0xff);
               vals[vcl++] = cast(ubyte) ((li >> 56) & 0xff);
               break;
            case "ulong":
               types[ct++] = 0x08;
               types[ct++] = 0x80;
               if (isnull) break;
               reAlloc(8);
               ulong ul = v.get!(ulong);
               vals[vcl++] = cast(ubyte) (ul & 0xff);
               vals[vcl++] = cast(ubyte) ((ul >> 8) & 0xff);
               vals[vcl++] = cast(ubyte) ((ul >> 16) & 0xff);
               vals[vcl++] = cast(ubyte) ((ul >> 24) & 0xff);
               vals[vcl++] = cast(ubyte) ((ul >> 32) & 0xff);
               vals[vcl++] = cast(ubyte) ((ul >> 40) & 0xff);
               vals[vcl++] = cast(ubyte) ((ul >> 48) & 0xff);
               vals[vcl++] = cast(ubyte) ((ul >> 56) & 0xff);
               break;
            case "float":
               types[ct++] = 0x04;
               types[ct++] = 0;
               if (isnull) break;
               reAlloc(4);
               ubyte* ubp = cast(ubyte*) v.peek!(float);
               vals[vcl++] = *ubp++;
               vals[vcl++] = *ubp++;
               vals[vcl++] = *ubp++;
               vals[vcl++] = *ubp;
               break;
            case "double":
               types[ct++] = 0x05;
               types[ct++] = 0;
               if (isnull) break;
               reAlloc(8);
               ubyte* ubp = cast(ubyte*) v.peek!(double);
               vals[vcl++] = *ubp++;
               vals[vcl++] = *ubp++;
               vals[vcl++] = *ubp++;
               vals[vcl++] = *ubp++;
               vals[vcl++] = *ubp++;
               vals[vcl++] = *ubp++;
               vals[vcl++] = *ubp++;
               vals[vcl++] = *ubp;
               break;
            case "std.datetime.Date":
               types[ct++] = 0x0a;
               types[ct++] = 0;
               Date date = v.get!(Date);
               ubyte[] da = pack(date);
               uint l = da.length;
               if (isnull) break;
               reAlloc(l);
               vals[vcl..vcl+l] = da[];
               vcl += l;
               break;
            case "std.datetime.Time":
               types[ct++] = 0x0b;
               types[ct++] = 0;
               TimeOfDay time = v.get!(TimeOfDay);
               ubyte[] ta = pack(time);
               uint l = ta.length;
               if (isnull) break;
               reAlloc(l);
               vals[vcl..vcl+l] = ta[];
               vcl += l;
               break;
            case "std.datetime.DateTime":
               types[ct++] = 0x0c;
               types[ct++] = 0;
               DateTime dt = v.get!(DateTime);
               ubyte[] da = pack(dt);
               uint l = da.length;
               if (isnull) break;
               reAlloc(l);
               vals[vcl..vcl+l] = da[];
               vcl += l;
               break;
            case "connect.Timestamp":
               types[ct++] = 0x07;
               types[ct++] = 0;
               Timestamp ts = v.get!(Timestamp);
               DateTime dt = toDateTime(ts.rep);
               ubyte[] da = pack(dt);
               uint l = da.length;
               if (isnull) break;
               reAlloc(l);
               vals[vcl..vcl+l] = da[];
               vcl += l;
               break;
            case "immutable(char)[]":
               if (ext == SQLType.DEFAULT)
                  types[ct++] = 0x0f;
               else
                  types[ct++] = cast(ubyte) ext;
               types[ct++] = 0;
               if (isnull) break;
               ubyte[] packed = packLCS(cast(void[]) v.get!(string));
               reAlloc(packed.length);
               vals[vcl..vcl+packed.length] = packed[];
               vcl += packed.length;
               break;
            case "char[]":
               if (ext == SQLType.DEFAULT)
                  types[ct++] = 0x0f;
               else
                  types[ct++] = cast(ubyte) ext;
               types[ct++] = 0;
               if (isnull) break;
               ubyte[] packed = packLCS(cast(void[]) v.get!(char[]));
               reAlloc(packed.length);
               vals[vcl..vcl+packed.length] = packed[];
               vcl += packed.length;
               break;
            case "byte[]":
               if (ext == SQLType.DEFAULT)
                  types[ct++] = 0x59;     // TINYBLOB by default
               else
                  types[ct++] = cast(ubyte) ext;
               types[ct++] = 0;
               if (isnull) break;
               ubyte[] packed = packLCS(cast(void[]) v.get!(byte[]));
               reAlloc(packed.length);
               vals[vcl..vcl+packed.length] = packed[];
               vcl += packed.length;
               break;
            case "ubyte[]":
               if (ext == SQLType.DEFAULT)
                  types[ct++] = 0xf9;     // TINYBLOB by default
               else
                  types[ct++] = cast(ubyte) ext;
               types[ct++] = 0;
               if (isnull) break;
               ubyte[] packed = packLCS(cast(void[]) v.get!(ubyte[]));
               reAlloc(packed.length);
               vals[vcl..vcl+packed.length] = packed[];
               vcl += packed.length;
               break;
            default:
               throw new MYX("Unsupported parameter type", __FILE__, __LINE__);
               break;
         }
      }
      vals.length = vcl;
      return types;
   }

   void sendLongData()
   {
      foreach (uint i, PSN psn; _psa)
      {
         if (!psn.chunkSize) continue;
         uint cs = psn.chunkSize;
         uint delegate(ubyte[]) dg = psn.chunkDelegate;
         ubyte[] chunk;
         chunk.length = cs+11;
         uint pl = cs+7;
         // Packet header
         chunk[0] = cast(ubyte) (pl & 0xff);
         chunk[1] = cast(ubyte) ((pl >> 8) & 0xff);
         chunk[2] = cast(ubyte) ((pl >> 16) & 0xff);
         chunk[3] = 0;  // Each long data chunk is a separate command

         // Data chunk
         chunk[4] = 0x18;                                                     // command
         chunk[5] = cast(ubyte) (_hStmt & 0xff);                 // statement handle - 4 bytes
         chunk[6] = cast(ubyte) ((_hStmt >> 8) & 0xff);
         chunk[7] = cast(ubyte) ((_hStmt >> 16) & 0xff);
         chunk[8] = cast(ubyte) ((_hStmt >> 24) & 0xff);
         chunk[9] = cast(ubyte) (i & 0xff);                            // parameter number - 2 bytes
         chunk[10] = cast(ubyte) ((i >> 8) & 0xff);
         // byte 11 on is payload
         for (;;)
         {
            uint sent = dg(chunk[11..cs+11]);
            if (sent < cs)
            {
               if (sent == 0)    // data was exact multiple of chunk size - all sent
                  break;
               sent += 7;        // adjust for non-payload bytes
               chunk.length = chunk.length - (cs-sent);     // trim the chunk
               chunk[0] = cast(ubyte) (sent & 0xff);
               chunk[1] = cast(ubyte) ((sent >> 8) & 0xff);
               chunk[2] = cast(ubyte) ((sent >> 16) & 0xff);
               _con.send(chunk);
               break;
            }
            _con.send(chunk);
         }
      }
   }

public:

   this(Connection con, string sql)
   {
      _sql = sql;
      this(con);
   }

   this(Connection con)
   {
      _con = con;
      _con.resetPacket();
      _socket = _con.socket;
   }

   @property
   {
      string sql() { return _sql; }
      string sql(string sql)
      {
         purgeResult();
         _con.resetPacket();
         return _sql = sql;
      }
   }

   void prepare()
   {
      enforceEx!MYX(!(_headersPending || _rowsPending), "There are result set elements pending - purgeResult() required.");
      if (_hStmt)
         releaseStatement();
      _con.sendCmd(0x16, _sql);
      _fieldCount = 0;
      uint pl;
      ubyte[] packet = _con.getPacket(pl);
      ubyte* ubp = packet.ptr;
      if (*ubp == 0)
      {
         ubp++;
         _hStmt = getInt(ubp);
         _fieldCount = getShort(ubp);
         _psParams = getShort(ubp);
         _inParams.length = _psParams;
         _psa.length = _psParams;
         ubp++;      // one byte of filler
         _psWarnings = getShort(ubp);

         // At this point the server also sends field specs for parameters and columns if there were any of each
         _psh = PreparedStmtHeaders(_con, _fieldCount, _psParams);
      }
      else
      {
         OKPacket okp = OKPacket(ubp, pl);
         throw new MYX("MySQL Error: " ~ cast(string) okp.message, __FILE__, __LINE__);
      }
   }

   void releaseStatement()
   {
      ubyte[] packet;
      packet.length = 9;
      packet[0] = 5;
      packet[1] = 0;
      packet[2] = 0;
      packet[3] = 0;//_con.pktNumber;
      _con.bumpPacket();
      packet[4] = 0x19;
      packet[5] = cast(ubyte) (_hStmt & 0xff);
      packet[6] = cast(ubyte) ((_hStmt >> 8) & 0xff);
      packet[7] = cast(ubyte) ((_hStmt >> 16) & 0xff);
      packet[8] = cast(ubyte) ((_hStmt >> 24) & 0xff);
      purgeResult();
      _con.send(packet);
      // It seems that the server does not find it necessary to send a response
      // for this command.
      _hStmt = 0;
   }

   ulong purgeResult()
   {
      // If a command has been executed that produced a result set, there will be a queue of packets
      // in the protocol 'pipeline', and these have to be cleared out before another command can be
      // executed. In this case there are three variables to work with: _fieldCount, which will tell us how
      // Many packets of Field data are queued up, _headersPending, which will be set if they have not
      // been read, and _rowsPending which will be set if we have not used or wasted the rows.
      //
      // http://www.mysqlperformanceblog.com/2007/07/08/mysql-net_write_timeout-vs-wait_timeout-and-protocol-notes/
      ulong rows = 0;
      if (_fieldCount)
      {
         if (_headersPending)
         {
            for (int i = 0;; i++)
            {
               uint pl;
               ubyte[] packet = _con.getPacket(pl);
               ubyte* ubp = packet.ptr;
               if (pl < 9 && *ubp == 0xfe)
               {
                  // Found an EOF packet
                  _headersPending = false;
                  break;
               }
               enforceEx!MYX(i < _fieldCount, "Field header count exceeded but no EOF packet found.");
            }
         }
         if (_rowsPending)
         {
            for (;;  rows++)
            {
               uint pl;
               ubyte[] packet = _con.getPacket(pl);
               ubyte* ubp = packet.ptr;
               if (pl < 9 && *ubp == 0xfe)
               {
                  // Found an EOF packet
                  _rowsPending = _pendingBinary = false;
                  break;
               }
            }
         }
      }
      _fieldCount = 0;
      _con.resetPacket();
      return rows;
   }

   void bindParameter(T)(T val, uint pIndex, ParameterSpecialization psn)
   {
      // Now in theory we should be able to check the parameter type here, since the protocol is supposed
      // to send us type information for the parameters, but this capability seems to be broken. This assertion
      // is supported by the fact that the same information is not available via the MySQL C API either. It is up
      // to the programmer to ensure that appropriate type information is embodied in the variant array, or
      // provided explicitly. This sucks, but short of having a client side SQL parser I don't see what can be done.
      //
      // We require that the statement be prepared at this point so we can at least check that the parameter
      // number is within the required range
      enforceEx!MYX(_hStmt, "The statement must be prepared before parameters are bound.");
      enforceEx!MYX(pIndex < _psParams, "Parameter number is out of range for the prepared statement.");
      _inParams[pIndex] = val;
      psn.pIndex = pIndex;
      _psa[pIndex] = psn;
   }

   void bindParameters(MyVariant[] values, ParameterSpecialization[] psnList= null)
   {
      enforceEx!MYX(_hStmt, "The statement must be prepared before parameters are bound.");
      enforceEx!MYX(values.length == _psParams, "Param count supplied does not match prepared statement");
      _inParams[] = values[];
      if (psnList !is null)
      {
         foreach (PSN psn; psnList)
            _psa[psn.pIndex] = psn;
      }
   }

   void bindParameterTuple(T...)(T args)
   {
      enforceEx!MYX(_hStmt, "The statement must be prepared before parameters are bound.");
      enforceEx!MYX(args.length == _psParams, "Param count supplied does not match prepared statement");
      foreach (uint i, arg; args)
      {
         inParams[i] = arg;
      }
   }

   ref MyVariant param(uint index)
   {
      return _inParams[index];
   }

   bool execSQL(out ulong ra)
   {
      _con.sendCmd(0x03, _sql);
      _fieldCount = 0;
      uint pl;
      ubyte[] packet = _con.getPacket(pl);
      ubyte* ubp = packet.ptr;
      bool rv;
      if (*ubp == 0 || *ubp == 255)
      {
         _con.resetPacket();
         OKPacket okp = OKPacket(ubp, pl);
         enforceEx!MYX(!okp.error, "MySQL Error: " ~ cast(string) okp.message);
         ra = okp.affected;
         _con._serverStatus = okp.serverStatus;
         _insertID = okp.insertID;
         rv = false;
      }
      else
      {
         // There was presumably a result set
         _headersPending = _rowsPending = true;
         _pendingBinary = false;
         bool gash;
         _fieldCount = cast(ushort) parseLCB(ubp, gash);
         rv = true;
         ra = 0;
      }
      return rv;
   }

   ResultSet execSQLResult(ColumnSpecialization[] csa = null)
   {
      uint alloc = 20;
      Row[] rra;
      rra.length = alloc;
      uint cr = 0;
      ulong ra;
      enforceEx!MYX(execSQL(ra), "The executed query did not produce a result set.");
      _rsh = ResultSetHeaders(_con, _fieldCount);
      if (csa !is null)
         _rsh.addSpecializations(csa);

      _headersPending = false;
      ubyte[] packet;
      for (uint i = 0;; i++)
      {
         uint pl;
         packet = _con.getPacket(pl);
         ubyte* ubp = packet.ptr;
         if (*ubp == 0xfe && pl < 9)      // EOF packet
            break;

         Row row = Row(_con, packet, _rsh, false);
         if (cr >= alloc)
         {
            alloc = (alloc*3)/2;
            rra.length = alloc;
         }
         rra[cr++] = row;
      }
      _rowsPending = _pendingBinary = false;
      rra.length = cr;
      ResultSet rs = ResultSet(rra, _rsh.fieldNames);
      return rs;
   }

   void execSQLTuple(T...)(ref T args)
   {
      ulong ra;
      enforceEx!MYX(execSQL(ra), "The executed query did not produce a result set.");
      Row rr = getNextRow();
      enforceEx!MYX(rr._valid, "The result set was empty.");
      enforceEx!MYX(rr._uva.length == args.length, "Result column count does not match the target tuple.");
      foreach (uint i, dummy; args)
      {
         enforceEx!MYX(typeid(args[i]).toString() == rr._uva[i].type.toString(),
                     "Tuple "~to!string(i)~" type and column type are not compatible.");
         args[i] = rr._uva[i].get!(typeof(args[i]));
      }
      // If there were more rows, flush them away
      // Question: Should I check in purgeResult and throw if there were - it's very inefficient to
      // allow sloppy SQL that does not ensure just one row!
      purgeResult();
   }
/+
   bool execPrepared(out ulong ra)
   {
      enforceEx!MYX(_hStmt, "The statement has not been prepared.");
      ubyte[] prefix = makePSPrefix(0);
      uint len = prefix.length;
      ubyte[] packet;
      bool longData;
      if (_psh._paramCount)
      {
         ubyte[] one = [ 1 ];
         ubyte[] vals;
         ubyte[] types = analyseParams(vals, longData);
         ubyte[] nbm = makeBitmap(_psa);
         packet = prefix ~ nbm ~ one ~ types ~ vals;
      }
      else
         packet = prefix;
      uint pl = packet.length - 4;
      _con.resetPacket();
      packet[0] = cast(ubyte) (pl & 0xff);
      packet[1] = cast(ubyte) ((pl >> 8) & 0xff);
      packet[2] = cast(ubyte) ((pl >> 16) & 0xff);
      packet[3] = _con.pktNumber;
      _con.bumpPacket();
      _con.send(packet);
      packet = _con.getPacket(pl);
      ubyte* ubp = packet.ptr;
      bool rv;
      if (*ubp == 0 || *ubp == 255)
      {
         _con.resetPacket();
         OKPacket okp = OKPacket(ubp, pl);
         enforceEx!MYX(!okp.error, "MySQL Error: " ~ cast(string) okp.message);
         ra = okp.affected;
         _con._serverStatus = okp.serverStatus;
         _insertID = okp.insertID;
         rv = false;
      }
      else
      {
         // There was presumably a result set
         _headersPending = _rowsPending = _pendingBinary = true;
         bool gash;
         _fieldCount = cast(ushort) parseLCB(ubp, gash);
         rv = true;
      }
      return rv;
   }
+/
   bool execPrepared(out ulong ra)
   {
      if (!_hStmt)
         throw new Exception("The statement has not been prepared.");
      ubyte[] packet;
      _con.resetPacket();

      ubyte[] prefix = makePSPrefix(0);
      uint len = prefix.length;
      bool longData;

      if (_psh._paramCount)
      {
         ubyte[] one = [ 1 ];
         ubyte[] vals;
         ubyte[] types = analyseParams(vals, longData);
         ubyte[] nbm = makeBitmap(_psa);
         packet = prefix ~ nbm ~ one ~ types ~ vals;
      }
      else
         packet = prefix;

      if (longData)
         sendLongData();

      uint pl = packet.length - 4;
      packet[0] = cast(ubyte) (pl & 0xff);
      packet[1] = cast(ubyte) ((pl >> 8) & 0xff);
      packet[2] = cast(ubyte) ((pl >> 16) & 0xff);
      packet[3] = _con.pktNumber;
      _con.bumpPacket();
      _con.send(packet);
      packet = _con.getPacket(pl);
      ubyte* ubp = packet.ptr;
      bool rv;
      if (*ubp == 0 || *ubp == 255)
      {
         _con.resetPacket();
         OKPacket okp = OKPacket(ubp, pl);
         if (okp.error)
         {
            throw new Exception("MySQL Error: " ~ cast(string) okp.message);
         }
         ra = okp.affected;
         _con._serverStatus = okp.serverStatus;
         _insertID = okp.insertID;
         rv = false;
      }
      else
      {
         // There was presumably a result set
         _headersPending = _rowsPending = _pendingBinary = true;
         bool gash;
         _fieldCount = cast(ushort) parseLCB(ubp, gash);
         rv = true;
      }
      return rv;
   }

   ResultSet execPreparedResult()
   {
      ulong ra;
      enforceEx!MYX(execPrepared(ra), "The executed query did not produce a result set.");
      uint alloc = 20;
      Row[] rra;
      rra.length = alloc;
      uint cr = 0;
      _rsh = ResultSetHeaders(_con, _fieldCount);
      _headersPending = false;
      ubyte[] packet;
      for (uint i = 0;; i++)
      {
         uint pl;
         packet = _con.getPacket(pl);
         ubyte* ubp = packet.ptr;
         if (*ubp == 0xfe && pl < 9)      // EOF packet
            break;
         Row row = Row(_con, packet, _rsh, true);
         if (cr >= alloc)
         {
            alloc = (alloc*3)/2;
            rra.length = alloc;
         }
         rra[cr++] = row;
      }
      _rowsPending = _pendingBinary = false;
      rra.length = cr;
      ResultSet rs = ResultSet(rra, _rsh.fieldNames);
      return rs;
   }

   void execPreparedTuple(T...)(ref T args)
   {
      ulong ra;
      enforceEx!MYX(execPrepared(ra), "The executed query did not produce a result set.");
      Row rr = getNextRow();
      enforceEx!MYX(rr._valid, "The result set was empty.");
      enforceEx!MYX(rr._uva.length == args.length, "Result column count does not match the target tuple.");
      foreach (uint i, dummy; args)
      {
         enforceEx!MYX(typeid(args[i]).toString() == rr._uva[i].type.toString(),
                       "Tuple "~to!string(i)~" type and column type are not compatible.");
         args[i] = rr._uva[i].get!(typeof(args[i]));
      }
      // If there were more rows, flush them away
      // Question: Should I check in purgeResult and throw if there were - it's very inefficient to
      // allow sloppy SQL that does not ensure just one row!
      purgeResult();
   }

   Row getNextRow()
   {
      if (_headersPending)
      {
         _rsh = ResultSetHeaders(_con, _fieldCount);
         _headersPending = false;
      }
      ubyte[] packet;
      Row rr;
      uint pl;
      packet = _con.getPacket(pl);
      ubyte* ubp = packet.ptr;
      if (*ubp == 0xfe && pl < 9)      // EOF packet
      {
         _rowsPending = _pendingBinary = false;
         return rr;
      }
      if (_pendingBinary)
         rr = Row(_con, packet, _rsh, true);
      else
         rr = Row(_con, packet, _rsh, false);
      rr._valid = true;
      return rr;
   }

   @ property ulong lastInsertID() { return _insertID; }
}

unittest
{
    struct X
   {
      int a, b, c;
      string s;
      double d;
   }

   bool ok = true;
   Connection c = new Connection("localhost", "user", "password", "mysqld");
   c.open();
   scope(exit) c.close();
   try
   {

      ulong ra;
      Command c1 = Command(c);

      c1.sql = "delete from basetest";
      c1.execSQL(ra);

      c1.sql = "insert into basetest values(" ~
                     "1, -128, 255, -32768, 65535, 42, 4294967295, -9223372036854775808, 18446744073709551615, 'ABC', " ~
                     "'The quick brown fox', 0x000102030405060708090a0b0c0d0e0f, '2007-01-01', " ~
                     "'12:12:12', '2007-01-01 12:12:12', 1.234567890987654, 22.4, NULL)";
      c1.execSQL(ra);

      c1.sql = "select bytecol from basetest limit 1";
      ResultSet rs = c1.execSQLResult();
      assert(rs.length == 1);
      assert(rs[0][0] == -128);
      c1.sql = "select ubytecol from basetest limit 1";
      rs = c1.execSQLResult();
      assert(rs.length == 1);
      assert(rs.front[0] == 255);
      c1.sql = "select shortcol from basetest limit 1";
      rs = c1.execSQLResult();
      assert(rs.length == 1);
      assert(rs[0][0] == short.min);
      c1.sql = "select ushortcol from basetest limit 1";
      rs = c1.execSQLResult();
      assert(rs.length == 1);
      assert(rs[0][0] == ushort.max);
      c1.sql = "select intcol from basetest limit 1";
      rs = c1.execSQLResult();
      assert(rs.length == 1);
      assert(rs[0][0] == 42);
      c1.sql = "select uintcol from basetest limit 1";
      rs = c1.execSQLResult();
      assert(rs.length == 1);
      assert(rs[0][0] == uint.max);
      c1.sql = "select longcol from basetest limit 1";
      rs = c1.execSQLResult();
      assert(rs.length == 1);
      assert(rs[0][0] == long.min);
      c1.sql = "select ulongcol from basetest limit 1";
      rs = c1.execSQLResult();
      assert(rs.length == 1);
      assert(rs[0][0] == ulong.max);
      c1.sql = "select charscol from basetest limit 1";
      rs = c1.execSQLResult();
      assert(rs.length == 1);
      assert(rs[0][0].toString() == "ABC");
      c1.sql = "select stringcol from basetest limit 1";
      rs = c1.execSQLResult();
      assert(rs.length == 1);
      assert(rs[0][0].toString() == "The quick brown fox");
      c1.sql = "select bytescol from basetest limit 1";
      rs = c1.execSQLResult();
      assert(rs.length == 1);
      assert(rs[0][0].toString() == "[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]");
      c1.sql = "select datecol from basetest limit 1";
      rs = c1.execSQLResult();
      assert(rs.length == 1);
      Date d = rs[0][0].get!(Date);
      assert(d.year == 2007 && d.month == 1 && d.day == 1);
      c1.sql = "select timecol from basetest limit 1";
      rs = c1.execSQLResult();
      assert(rs.length == 1);
      TimeOfDay t = rs[0][0].get!(TimeOfDay);
      assert(t.hour == 12 && t.minute == 12 && t.second == 12);
      c1.sql = "select dtcol from basetest limit 1";
      rs = c1.execSQLResult();
      assert(rs.length == 1);
      DateTime dt = rs[0][0].get!(DateTime);
      assert(dt.year == 2007 && dt.month == 1 && dt.day == 1 && dt.hour == 12 && dt.minute == 12 && dt.second == 12);
      c1.sql = "select doublecol from basetest limit 1";
      rs = c1.execSQLResult();
      assert(rs.length == 1);
      assert(rs[0][0].toString() == "1.23457");
      c1.sql = "select floatcol from basetest limit 1";
      rs = c1.execSQLResult();
      assert(rs.length == 1);
      assert(rs[0][0].toString() == "22.4");

      c1.sql = "select * from basetest limit 1";
      rs = c1.execSQLResult();
      assert(rs.length == 1);
      assert(rs[0][0] == true);
      assert(rs[0][1] == -128);
      assert(rs[0][2] == 255);
      assert(rs[0][3] == short.min);
      assert(rs[0][4] == ushort.max);
      assert(rs[0][5] == 42);
      assert(rs[0][6] == uint.max);
      assert(rs[0][7] == long.min);
      assert(rs[0][8] == ulong.max);
      assert(rs[0][9].toString() == "ABC");
      assert(rs[0][10].toString() == "The quick brown fox");
      assert(rs[0][11].toString() == "[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]");
      d = rs[0][12].get!(Date);
      assert(d.year == 2007 && d.month == 1 && d.day == 1);
      t = rs[0][13].get!(TimeOfDay);
      assert(t.hour == 12 && t.minute == 12 && t.second == 12);
      dt = rs[0][14].get!(DateTime);
      assert(dt.year == 2007 && dt.month == 1 && dt.day == 1 && dt.hour == 12 && dt.minute == 12 && dt.second == 12);
      assert(rs[0][15].toString() == "1.23457");
      assert(rs[0]._uva[16].toString() == "22.4");
      assert(rs[0].isNull(17) == true);

      c1.sql = "select bytecol, ushortcol, intcol, charscol, floatcol from basetest limit 1";
      rs = c1.execSQLResult();
      X x;
      rs[0].toStruct(x);
      assert(x.a == -128 && x.b == 65535 && x.c == 42 && x.s == "ABC" && to!string(x.d) == "22.4");

      c1.sql = "select * from basetest limit 1";
      c1.prepare();
      rs = c1.execPreparedResult();
      assert(rs.length == 1);
      assert(rs[0][0] == true);
      assert(rs[0][1] == -128);
      assert(rs[0][2] == 255);
      assert(rs[0][3] == short.min);
      assert(rs[0][4] == ushort.max);
      assert(rs[0][5] == 42);
      assert(rs[0][6] == uint.max);
      assert(rs[0][7] == long.min);
      assert(rs[0][8] == ulong.max);
      assert(rs[0][9].toString() == "ABC");
      assert(rs[0][10].toString() == "The quick brown fox");
      assert(rs[0][11].toString() == "[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]");
      d = rs[0][12].get!(Date);
      assert(d.year == 2007 && d.month == 1 && d.day == 1);
      t = rs[0][13].get!(TimeOfDay);
      assert(t.hour == 12 && t.minute == 12 && t.second == 12);
      dt = rs[0][14].get!(DateTime);
      assert(dt.year == 2007 && dt.month == 1 && dt.day == 1 && dt.hour == 12 && dt.minute == 12 && dt.second == 12);
      assert(rs[0][15].toString() == "1.23457");
      assert(rs[0][16].toString() == "22.4");
      assert(rs[0]._nulls[17] == true);

      c1.sql = "insert into basetest (intcol, stringcol) values(?, ?)";
      c1.prepare();
      MyVariant[] va;
      va.length = 2;
      va[0] = 42;
      va[1] = "The quick brown fox x";
      c1.bindParameters(va);
      for (int i = 0; i < 20; i++)
      {
         c1.execPrepared(ra);
         c1.param(0) += 1;
         c1.param(1) ~= "x";
      }

      int a;
      string b;
      c1.sql = "select intcol, stringcol from basetest where bytecol=-128 limit 1";
      c1.execSQLTuple(a, b);
      assert(a == 42 && b == "The quick brown fox");

      c1.sql = "select intcol, stringcol from basetest where bytecol=? limit 1";
      c1.prepare();
      MyVariant[] va2;
      va2.length = 1;
      va2[0] = cast(byte) -128;
      c1.bindParameters(va2);
      a = 0;
      b = "";
      c1.execPreparedTuple(a, b);
      assert(a == 42 && b == "The quick brown fox");

      c1.sql = "delete from tblob";
      c1.execSQL(ra);
      c1.sql = "insert into tblob values(321, NULL, 22.4, NULL, '2011-11-05 11:52:00')";
      c1.execSQL(ra);

      uint delegate(ubyte[]) foo()
      {
         uint n = 20000000;
         uint cp = 0;

         void fill(ubyte[] a, uint m)
         {
            for (uint i = 0; i < m; i++)
            {
               a[i] = cast(ubyte) (cp & 0xff);
               cp++;
            }
         }

         uint dg(ubyte[] dest)
         {
            uint len = dest.length;
            if (n >= len)
            {
               fill(dest, len);
               n -= len;
               return len;
            }
            fill(dest, n);
            return n;
         }

         return &dg;
      }
/+
      c1.sql = "update tblob set lob=?, lob2=? where ikey=321";
      c1.prepare();
      ubyte[] uba;
      ubyte[] uba2;
      c1.bindParameter(uba, 0, PSN(0, false, SQLType.LONGBLOB, 10000, foo()));
      c1.bindParameter(uba2, 1, PSN(1, false, SQLType.LONGBLOB, 10000, foo()));
      c1.execPrepared(ra);

      uint got1, got2;
      bool verified1, verified2;
      void delegate(ubyte[], bool) bar1(ref uint got, ref bool  verified)
      {
         got = 0;
         verified = true;

         void dg(ubyte[] ba, bool finished)
         {
            for (uint i = 0; i < ba.length; i++)
            {
               if (verified && ba[i] != ((got+i) & 0xff))
                  verified = false;
            }
            got += ba.length;
         }
         return &dg;
      }

      void delegate(ubyte[], bool) bar2(ref uint got, ref bool  verified)
      {
         got = 0;
         verified = true;

         void dg(ubyte[] ba, bool finished)
         {
            for (uint i = 0; i < ba.length; i++)
            {
               if (verified && ba[i] != ((got+i) & 0xff))
                  verified = false;
            }
            got += ba.length;
         }
         return &dg;
      }
/*
      c1.sql = "select * from tblob limit 1";
      rs = c1.execSQLResult();
      ubyte[] blob = rs[0][1].get!(ubyte[]);
      ubyte[] blob2 = rs[0][3].get!(ubyte[]);
      DateTime dt4 = rs[0][4].get!(DateTime);
      writefln("blob. lengths %d %d", blob.length, blob2.length);
      writeln(to!string(dt4));
*/

      c1.sql = "select * from tblob limit 1";
      CSN[] csa = [ CSN(1, 0xfc, 100000, bar1(got1, verified1)), CSN(3, 0xfc, 100000, bar2(got2, verified2)) ];
      rs = c1.execSQLResult(csa);
      writefln("1) %d, %s", got1, verified1);
      writefln("2) %d, %s", got2, verified2);
      DateTime dt4 = rs[0][4].get!(DateTime);
      writeln(to!string(dt4));
+/
   }
   catch (Exception x)
   {
      writefln("(%s: %s) %s", x.file, x.line, x.msg);
      ok = false;
   }
   assert(ok);
   writeln("Command unit tests completed OK.");
}

/**
 * A struct to hold column metadata
 *
 */
struct MySQLColumn
{
   /// The database that the table having this column belongs to.
   string schema;
   /// The table that this column belongs to.
   string table;
   /// The name of the column.
   string name;
   /// Zero based index of the column within a table row.
   uint index;
   /// Is the default value NULL?
   bool defaultNull;
   /// The default value as a string if not NULL
   string defaultValue;
   /// Can the column value be set to NULL
   bool nullable;
   /// What type is the column - tinyint, char, varchar, blob, date etc
   string type;            // varchar tinyint etc
   /// Capacity in characters, -1L if not applicable
   long charsMax;
   /// Capacity in bytes - same as chars if not a unicode table definition, -1L if not applicable.
   long octetsMax;
   /// Presentation information for numerics, -1L if not applicable.
   short numericPrecision;
   /// Scale information for numerics or NULL, -1L if not applicable.
   short numericScale;
   /// Character set, "<NULL>" if not applicable.
   string charSet;
   /// Collation, "<NULL>" if not applicable.
   string collation;
   /// More detail about the column type, e.g. "int(10) unsigned".
   string colType;
   /// Information about the column's key status, blank if none.
   string key;
   /// Extra information.
   string extra;
   /// Privileges for logged in user.
   string privileges;
   /// Any comment that was set at table definition time.
   string comment;
}

/**
 * A struct to hold stored function metadata
 *
 */
struct MySQLProcedure
{
   string db;
   string name;
   string type;
   string definer;
   DateTime modified;
   DateTime created;
   string securityType;
   string comment;
   string charSetClient;
   string collationConnection;
   string collationDB;
}

/**
 * Facilities to recover meta-data from a connection
 *
 * It is important to bear in mind that the methods provided will only return the
 * information that is available to the connected user. This may well be quite limited.
 */
struct MetaData
{
private:
   Connection _con;
   ResultSet _rs;
   Command _mdc;

   MySQLProcedure[] stored(bool procs)
   {
      enforceEx!MYX(_con.currentDB.length, "There is no selected database");
      string query = procs? "show procedure status where db='": "show function status where db='";
      query ~= _con.currentDB ~ "'";

      _mdc = Command(_con, query);
      _rs = _mdc.execSQLResult();
      MySQLProcedure[] pa;
      uint n = _rs.length;
      pa.length = n;
      for (uint i = 0; i < n; i++)
      {
         MySQLProcedure foo;
         Row r = _rs[i];
         for (int j = 0; j < 11; j++)
         {
            string t;
            bool isNull = r.isNull(j);
            if (!isNull)
               t = r[j].toString();
            else
               continue;
            switch (j)
            {
               case 0:
                  foo.db = t;
                  break;
               case 1:
                  foo.name = t;
                  break;
               case 2:
                  foo.type = t;
                  break;
               case 3:
                  foo.definer = t;
                  break;
               case 4:
                  foo.modified = r[j].get!(DateTime);
                  break;
               case 5:
                  foo.created = r[j].get!(DateTime);
                  break;
               case 6:
                  foo.securityType = t;
                  break;
               case 7:
                  foo.comment = t;
                  break;
               case 8:
                  foo.charSetClient = t;
                  break;
               case 9:
                  foo.collationConnection = t;
                  break;
               case 10:
                  foo.collationDB = t;
                  break;
               default:
                  break;
            }
         }
         pa[i] = foo;
      }
      return pa;
   }

public:
   this(Connection con)
   {
      _con = con;
   }

   /**
    * List the available databases
    *
    * Note that if you have connected using the credentials of a user with limited permissions
    * you may not get many results.
    *
    * Returns:
    *    An array of strings
    */
   string[] databases()
   {
      string[] rv;
      _mdc = Command(_con, "show databases");
      _rs = _mdc.execSQLResult();
      uint n = _rs.length;
      for (uint i = 0; i < n; i++)
      {
         string s;
         Row r = _rs[i];
         rv ~= r[0].toString();
      }
      return rv;
   }

   /**
    * List the tables in the current database
    *
    * Returns:
    *    An array of strings
    */
   string[] tables()
   {
      string[] rv;
      _mdc = Command(_con, "show tables");
      _rs = _mdc.execSQLResult();
      uint n = _rs.length;
      for (uint i = 0; i < n; i++)
      {
         string s;
         Row r = _rs[i];
         rv ~= r[0].toString();
      }
      return rv;
   }

   /**
    * Get column metadata for a table in the current database
    *
    * Params:
    *    table = The table name
    * Returns:
    *    An array of MySQLColumn structs
    */
   MySQLColumn[] columns(string table)
   {
      string query = "select * from information_schema.COLUMNS where table_name='" ~ table ~ "'";
      _mdc = Command(_con, query);
      _rs = _mdc.execSQLResult();
      uint n = _rs.length;
      MySQLColumn[] ca;
      ca.length = n;
      for (uint i = 0; i < n; i++)
      {
         MySQLColumn col;
         Row r = _rs[i];
         for (int j = 1; j < 19; j++)
         {
            string t;
            bool isNull = r.isNull(j);
            if (!isNull)
               t = to!string(r[j]);
            switch (j)
            {
               case 1:
                  col.schema = t;
                  break;
               case 2:
                  col.table = t;
                  break;
               case 3:
                  col.name = t;
                  break;
               case 4:
                  col.index = cast(uint) r[j].get!(ulong)-1;
                  break;
               case 5:
                  if (isNull)
                     col.defaultNull = true;
                  else
                     col.defaultValue = t;
                  break;
               case 6:
                  if (t == "YES")
                     col.nullable = true;
                  break;
               case 7:
                  col.type = t;
                  break;
               case 8:
                  col.charsMax = isNull? -1L: cast(long) r[j].get!(ulong);
                  break;
               case 9:
                  col.octetsMax = isNull? -1L: cast(long) r[j].get!(ulong);
                  break;
               case 10:
                  col.numericPrecision = cast(short) (isNull? -1: r[j].get!(ulong));
                  break;
               case 11:
                  col.numericScale = cast(short) (isNull? -1: r[j].get!(ulong));
                  break;
               case 12:
                  col.charSet = isNull? "<NULL>": t;
                  break;
               case 13:
                  col.collation = isNull? "<NULL>": t;
                  break;
               case 14:
                  col.colType = t;
                  break;
               case 15:
                  col.key = t;
                  break;
               case 16:
                  col.extra = t;
                  break;
               case 17:
                  col.privileges = t;
                  break;
               case 18:
                  col.comment = t;
                  break;
               default:
                  break;
            }
         }
         ca[i] = col;
      }
      return ca;
   }

   /**
    * Get list of stored functions in the current database, and their properties
    *
    */
   MySQLProcedure[] functions()
   {
      return stored(false);
   }

   /**
    * Get list of stored procedures in the current database, and their properties
    *
    */
   MySQLProcedure[] procedures()
   {
      return stored(true);
   }
}

unittest
{
   immutable string constr = "host=localhost;user=user;pwd=password;db=mysqld";
   Connection c = new Connection("localhost", "user", "password", "mysqld");
   c.open();
   scope(exit) c.close();
   MetaData md = MetaData(c);
   string[] dbList = md.databases();
   int count = 0;
   foreach (string db; dbList)
   {
      if (db == "mysqld" || db == "information_schema")
         count++;
   }
   assert(count == 2);
   string[] tList = md.tables();
   count = 0;
   foreach (string t; tList)
   {
      if (t == "basetest" || t == "tblob")
         count++;
   }
   assert(count == 2);

   MySQLColumn[] ca = md.columns("basetest");
   assert(ca[0].schema == "mysqld" && ca[0].table == "basetest" && ca[0].name == "boolcol" && ca[0].index == 0 &&
              ca[0].defaultNull && ca[0].nullable && ca[0].type == "bit" && ca[0].charsMax == -1 && ca[0].octetsMax == -1 &&
              ca[0].numericPrecision == 1 && ca[0].numericScale == -1 && ca[0].charSet == "<NULL>" && ca[0].collation == "<NULL>"  &&
              ca[0].colType == "bit(1)");
   assert(ca[1].schema == "mysqld" && ca[1].table == "basetest" && ca[1].name == "bytecol" && ca[1].index == 1 &&
              ca[1].defaultNull && ca[1].nullable && ca[1].type == "tinyint" && ca[1].charsMax == -1 && ca[1].octetsMax == -1 &&
              ca[1].numericPrecision == 3 && ca[1].numericScale == 0 && ca[1].charSet == "<NULL>" && ca[1].collation == "<NULL>"  &&
              ca[1].colType == "tinyint(4)");
   assert(ca[2].schema == "mysqld" && ca[2].table == "basetest" && ca[2].name == "ubytecol" && ca[2].index == 2 &&
              ca[2].defaultNull && ca[2].nullable && ca[2].type == "tinyint" && ca[2].charsMax == -1 && ca[2].octetsMax == -1 &&
              ca[2].numericPrecision == 3 && ca[2].numericScale == 0 && ca[2].charSet == "<NULL>" && ca[2].collation == "<NULL>"  &&
              ca[2].colType == "tinyint(3) unsigned");
   assert(ca[3].schema == "mysqld" && ca[3].table == "basetest" && ca[3].name == "shortcol" && ca[3].index == 3 &&
              ca[3].defaultNull && ca[3].nullable && ca[3].type == "smallint" && ca[3].charsMax == -1 && ca[3].octetsMax == -1 &&
              ca[3].numericPrecision == 5 && ca[3].numericScale == 0 && ca[3].charSet == "<NULL>" && ca[3].collation == "<NULL>"  &&
              ca[3].colType == "smallint(6)");
   assert(ca[4].schema == "mysqld" && ca[4].table == "basetest" && ca[4].name == "ushortcol" && ca[4].index == 4 &&
              ca[4].defaultNull && ca[4].nullable && ca[4].type == "smallint" && ca[4].charsMax == -1 && ca[4].octetsMax == -1 &&
              ca[4].numericPrecision == 5 && ca[4].numericScale == 0 && ca[4].charSet == "<NULL>" && ca[4].collation == "<NULL>"  &&
              ca[4].colType == "smallint(5) unsigned");
   assert(ca[5].schema == "mysqld" && ca[5].table == "basetest" && ca[5].name == "intcol" && ca[5].index == 5 &&
              ca[5].defaultNull && ca[5].nullable && ca[5].type == "int" && ca[5].charsMax == -1 && ca[5].octetsMax == -1 &&
              ca[5].numericPrecision == 10 && ca[5].numericScale == 0 && ca[5].charSet == "<NULL>" && ca[5].collation == "<NULL>"  &&
              ca[5].colType == "int(11)");
   assert(ca[6].schema == "mysqld" && ca[6].table == "basetest" && ca[6].name == "uintcol" && ca[6].index == 6 &&
              ca[6].defaultNull && ca[6].nullable && ca[6].type == "int" && ca[6].charsMax == -1 && ca[6].octetsMax == -1 &&
              ca[6].numericPrecision == 10 && ca[6].numericScale == 0 && ca[6].charSet == "<NULL>" && ca[6].collation == "<NULL>"  &&
              ca[6].colType == "int(10) unsigned");
   assert(ca[7].schema == "mysqld" && ca[7].table == "basetest" && ca[7].name == "longcol" && ca[7].index == 7 &&
              ca[7].defaultNull && ca[7].nullable && ca[7].type == "bigint" && ca[7].charsMax == -1 && ca[7].octetsMax == -1 &&
              ca[7].numericPrecision == 19 && ca[7].numericScale == 0 && ca[7].charSet == "<NULL>" && ca[7].collation == "<NULL>"  &&
              ca[7].colType == "bigint(20)");
   assert(ca[8].schema == "mysqld" && ca[8].table == "basetest" && ca[8].name == "ulongcol" && ca[8].index == 8 &&
              ca[8].defaultNull && ca[8].nullable && ca[8].type == "bigint" && ca[8].charsMax == -1 && ca[8].octetsMax == -1 &&
              ca[8].numericPrecision == 20 && ca[8].numericScale == 0 && ca[8].charSet == "<NULL>" && ca[8].collation == "<NULL>"  &&
              ca[8].colType == "bigint(20) unsigned");
   assert(ca[9].schema == "mysqld" && ca[9].table == "basetest" && ca[9].name == "charscol" && ca[9].index == 9 &&
              ca[9].defaultNull && ca[9].nullable && ca[9].type == "char" && ca[9].charsMax == 10 && ca[9].octetsMax == 10 &&
              ca[9].numericPrecision == -1 && ca[9].numericScale == -1 && ca[9].charSet == "latin1" && ca[9].collation == "latin1_swedish_ci"  &&
              ca[9].colType == "char(10)");
   assert(ca[10].schema == "mysqld" && ca[10].table == "basetest" && ca[10].name == "stringcol" && ca[10].index == 10 &&
              ca[10].defaultNull && ca[10].nullable && ca[10].type == "varchar" && ca[10].charsMax == 50 && ca[10].octetsMax == 50 &&
              ca[10].numericPrecision == -1 && ca[10].numericScale == -1 && ca[10].charSet == "latin1" && ca[10].collation == "latin1_swedish_ci"  &&
              ca[10].colType == "varchar(50)");
   assert(ca[11].schema == "mysqld" && ca[11].table == "basetest" && ca[11].name == "bytescol" && ca[11].index == 11 &&
              ca[11].defaultNull && ca[11].nullable && ca[11].type == "tinyblob" && ca[11].charsMax == 255 && ca[11].octetsMax == 255 &&
              ca[11].numericPrecision == -1 && ca[11].numericScale == -1 && ca[11].charSet == "<NULL>" && ca[11].collation == "<NULL>"  &&
              ca[11].colType == "tinyblob");
   assert(ca[12].schema == "mysqld" && ca[12].table == "basetest" && ca[12].name == "datecol" && ca[12].index == 12 &&
              ca[12].defaultNull && ca[12].nullable && ca[12].type == "date" && ca[12].charsMax == -1 && ca[12].octetsMax == -1 &&
              ca[12].numericPrecision == -1 && ca[12].numericScale == -1 && ca[12].charSet == "<NULL>" && ca[12].collation == "<NULL>"  &&
              ca[12].colType == "date");
   assert(ca[13].schema == "mysqld" && ca[13].table == "basetest" && ca[13].name == "timecol" && ca[13].index == 13 &&
              ca[13].defaultNull && ca[13].nullable && ca[13].type == "time" && ca[13].charsMax == -1 && ca[13].octetsMax == -1 &&
              ca[13].numericPrecision == -1 && ca[13].numericScale == -1 && ca[13].charSet == "<NULL>" && ca[13].collation == "<NULL>"  &&
              ca[13].colType == "time");
   assert(ca[14].schema == "mysqld" && ca[14].table == "basetest" && ca[14].name == "dtcol" && ca[14].index == 14 &&
              ca[14].defaultNull && ca[14].nullable && ca[14].type == "datetime" && ca[14].charsMax == -1 && ca[14].octetsMax == -1 &&
              ca[14].numericPrecision == -1 && ca[14].numericScale == -1 && ca[14].charSet == "<NULL>" && ca[14].collation == "<NULL>"  &&
              ca[14].colType == "datetime");
   assert(ca[15].schema == "mysqld" && ca[15].table == "basetest" && ca[15].name == "doublecol" && ca[15].index == 15 &&
              ca[15].defaultNull && ca[15].nullable && ca[15].type == "double" && ca[15].charsMax == -1 && ca[15].octetsMax == -1 &&
              ca[15].numericPrecision == 22 && ca[15].numericScale == -1 && ca[15].charSet == "<NULL>" && ca[15].collation == "<NULL>"  &&
              ca[15].colType == "double");
   assert(ca[16].schema == "mysqld" && ca[16].table == "basetest" && ca[16].name == "floatcol" && ca[16].index == 16 &&
              ca[16].defaultNull && ca[16].nullable && ca[16].type == "float" && ca[16].charsMax == -1 && ca[16].octetsMax == -1 &&
              ca[16].numericPrecision == 12 && ca[16].numericScale == -1 && ca[16].charSet == "<NULL>" && ca[16].collation == "<NULL>"  &&
              ca[16].colType == "float");
   assert(ca[17].schema == "mysqld" && ca[17].table == "basetest" && ca[17].name == "nullcol" && ca[17].index == 17 &&
              ca[17].defaultNull && ca[17].nullable && ca[17].type == "int" && ca[17].charsMax == -1 && ca[17].octetsMax == -1 &&
              ca[17].numericPrecision == 10 && ca[17].numericScale == 0 && ca[17].charSet == "<NULL>" && ca[17].collation == "<NULL>"  &&
              ca[17].colType == "int(11)");
   MySQLProcedure[] pa = md.functions();
   assert(pa[0].db == "mysqld" && pa[0].name == "hello" && pa[0].type == "FUNCTION");
   pa = md.procedures();
   assert(pa[0].db == "mysqld" && pa[0].name == "insert2" && pa[0].type == "PROCEDURE");
}

void main()
{
}
