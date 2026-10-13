//! LOGCENTER owns non-kernel sources. Even All/export queries select only
//! these sources; kernel records are exclusively available through Spectra.
const std = @import("std");
const r4os = @import("r4os");
const abi = r4os.abi;
const sources = [_]u32{
    abi.log_service_source_driver, abi.log_service_source_protocol,
    abi.log_service_source_application, abi.log_service_source_service,
    abi.log_service_source_console, abi.log_service_source_diagnostic,
    abi.log_service_source_file,
};
var records: [abi.log_service_max_records]abi.LogServiceRecord = undefined;

pub fn allowed(id: u32) bool {
    for (sources) |source| if (id == source) return true;
    return false;
}

fn before(_: void, a: abi.LogServiceRecord, b: abi.LogServiceRecord) bool { return a.sequence < b.sequence; }

pub fn read(sys: *const r4os.r4sys.Context, query: *const abi.LogServiceRecordQuery, out: *abi.LogServiceRecordPage) i32 {
    if (query.source_id != abi.log_service_source_any) {
        if (!allowed(query.source_id)) return -1;
        return sys.logServiceRecords(query, out);
    }
    for (0..3) |_| {
        var count: usize = 0;
        var revision: ?u32 = null;
        var stable = true;
        for (sources) |source| {
            var part = query.*;
            part.source_id = source;
            part.start_index = 0;
            part.max_records = abi.log_service_records_per_page;
            while (true) {
                var page: abi.LogServiceRecordPage = .{};
                const rc = sys.logServiceRecords(&part, &page);
                if (rc != abi.service_api_result_ok) return rc;
                if (revision) |expected| { if (page.revision != expected) { stable = false; break; } } else revision = page.revision;
                if (page.count > page.records.len or count + page.count > records.len) return -1;
                @memcpy(records[count..][0..page.count], page.records[0..page.count]);
                count += page.count;
                if (page.flags & abi.log_service_page_flag_more == 0) break;
                if (page.next_index <= part.start_index) return -1;
                part.start_index = page.next_index;
            }
            if (!stable) break;
        }
        if (!stable) continue;
        std.mem.sort(abi.LogServiceRecord, records[0..count], {}, before);
        out.* = .{ .start_index = query.start_index, .total_matches = @intCast(count), .revision = revision orelse 0 };
        const start = @min(@as(usize, query.start_index), count);
        const length = @min(count - start, @min(@as(usize, query.max_records), out.records.len));
        @memcpy(out.records[0..length], records[start..][0..length]);
        out.count = @intCast(length);
        out.next_index = @intCast(start + length);
        if (start + length < count) out.flags |= abi.log_service_page_flag_more;
        return abi.service_api_result_ok;
    }
    return -1; // A changing set is never reported as a partial success.
}

pub fn exportPage(sys: *const r4os.r4sys.Context, query: *const abi.LogServiceRecordQuery, out: *abi.LogServiceExportPage) i32 {
    var page: abi.LogServiceRecordPage = .{};
    const rc = read(sys, query, &page);
    if (rc != abi.service_api_result_ok) return rc;
    out.* = .{ .revision = page.revision, .start_index = query.start_index, .total_matches = page.total_matches, .next_index = query.start_index };
    var used: usize = 0;
    for (page.records[0..page.count]) |record| {
        const line = std.fmt.bufPrint(out.text[used..], "seq={d} ticks={d} source={d} severity={d} flags={d} {s}: {s}\r\n", .{
            record.sequence, record.ticks, record.source_id, record.severity, record.flags,
            std.mem.sliceTo(&record.origin, 0), std.mem.sliceTo(&record.text, 0),
        }) catch break;
        used += line.len;
        out.next_index += 1;
    }
    out.bytes = @intCast(used);
    if (out.next_index < out.total_matches) out.flags |= abi.log_service_page_flag_more;
    if (page.count != 0 and used == 0) return -1;
    return abi.service_api_result_ok;
}
