import std.io;
import std.mem;

enum ChunkType : u32 {
    SIMI,
    HOUS,
    FLRm,
    WALm,
    Arry,
    objt,
    ObjM,
    THMB,
    BMP_,
    rsmp, // Resource Map
    unknown
};

fn GetChunkType (str s) {
    ChunkType type = ChunkType::unknown;
  match (s) {
    ("SIMI"): type = ChunkType::SIMI;
    ("HOUS"): type = ChunkType::HOUS;
    ("FLRm"): type = ChunkType::FLRm;
    ("WALm"): type = ChunkType::WALm;
    ("Arry"): type = ChunkType::Arry;
    ("objt"): type = ChunkType::objt;
    ("ObjM"): type = ChunkType::ObjM;
    ("THMB"): type = ChunkType::THMB;
    ("BMP_"): type = ChunkType::BMP_;
    ("rsmp"): type = ChunkType::rsmp;
  }
  return type;
};

fn ChunkTypeLabel (ChunkType c) {
    str s = "Unknown Data Type";
  match (c) {
    (ChunkType::SIMI): s = "SIMI";
    (ChunkType::HOUS): s = "HOUS";
    (ChunkType::FLRm): s = "FLRm";
    (ChunkType::WALm): s = "WALm";
    (ChunkType::Arry): s = "Arry";
    (ChunkType::objt): s = "objt";
    (ChunkType::ObjM): s = "ObjM";
    (ChunkType::THMB): s = "THMB";
    (ChunkType::BMP_): s = "BMP_";
    (ChunkType::rsmp): s = "rsmp";
  }
  return s;
};

fn LabelTypeStr (str c) {
    str s = "Unknown Data Type";
  match (c) {
    ("SIMI"): s = "SIMI";
    ("HOUS"): s = "HOUS";
    ("FLRm"): s = "FLRm";
    ("WALm"): s = "WALm";
    ("Arry"): s = "Arry";
    ("objt"): s = "objt";
    ("ObjM"): s = "ObjM";
    ("THMB"): s = "THMB";
    ("BMP_"): s = "BMP_";
    ("rsmp"): s = "rsmp";
  }
  return s;
};

struct NullTerminatedString {
    char data[while(std::mem::read_unsigned($, 1) != 0x00)];
    char terminator;
    
    if ($ % 2 == 1) {
        padding[1];
    }
};

struct FileHeader {
    char foreword[60];
    be u32 map_offset; // big-endian
};


struct RsmpHeader {
    u32 reserved;
    be u32 version;
    char magic[4];
    u32 size;
    u32 typeCount;
};
struct RsmpChunkHead {
    u32 type;   // byte swapped, denotes chunk type this entry refers to
    u32 count;  // denotes how many chunks of this type this record will reference
};
struct RsmpChunkBody {
    u32 offset; // position in file
    u16 chunkID; // may change size depending on RSMP version
    u16 flags; // byte swapped flags for chunk
    str label; // null terminated string
};
struct RsmpChunk {
    RsmpChunkHead header;
    RsmpChunkBody body[header.count];
};

struct ResourceMap {
    RsmpHeader header;
    RsmpChunk types[header.typeCount];
};

struct objtEntry {
    u16 r1;
    u16 r2;
    u16 r3;
    u16 r4;
    u16 r5;
    u16 r6;
    u16 count;
    u16 r8;
    NullTerminatedString label;
} [[name(std::format("{}: {}", count, label.data))]];

struct objtBody<auto End> {
    u32 body1;
    u32 body2;
    char body3[4];
    objtEntry entries[while($ + 16 < End)];
};

struct altitudeArryEntry {
    u8 x;
    u8 y;
    u16 altitude;
} [[name(std::format("({}, {}): {}", x, y, altitude))]];

struct altitudeArry<auto End> {
    u32 r1;
    u32 t2;
    u32 t3;
    u32 t4;
    u32 t5;
    altitudeArryEntry entries[while($ + 8 < End)];
};

struct objectsArryEntry {
    u64 start = $;
    bool refsSet = false;
    
    u16 kind;
    
    if ((kind % 2) == 1 && kind < 0x8000) {
        u16 refs[(kind + 1) / 2];
        refsSet = true;
    }
    if ((kind % 2) == 0 && kind < 0x8000) {
        u16 refs[(kind) / 2];
        refsSet = true;
    }
    
    if (refsSet) {
        
    } 
    
    u16 identifier;
    u16 terminator;
};

struct objectsArry<auto End> {
    u32 r1;
    u32 r2;
    u32 r3;
    u32 r4;
    objectsArryEntry entries[while($ + 16 < End)];
};

struct ChunkHeader {
    char type[4];
    be u32 size;
    u16 id;
    u16 flags;
    char label[64];
};

struct DataChunk {
    u64 chunkStart = $;
    
    ChunkHeader header;
    
    str chunkLabel = LabelTypeStr(header.type);
    
    u64 payloadStart = $;
    u64 chunkEnd = chunkStart + header.size;
    
    if (header.type == "objt") {
        objtBody<chunkEnd> body;
    }
    if (header.type == "Arry") {
        chunkLabel = std::format("{} - {}", chunkLabel, header.label);
        if(header.id == 0) {    // altitude
            altitudeArry<chunkEnd> body;
        }
        if(header.id == 768) {  // objects
            objectsArry<chunkEnd> body;
        }
    }
    
    if (chunkEnd <= std::mem::size() && chunkEnd >= $)
    {
        padding[chunkEnd - $];
    }
} [[name(chunkLabel)]];




FileHeader file_header @ 0x00;
DataChunk chunks[while($ + sizeof(ChunkHeader) <= std::mem::size())] @ sizeof(file_header);