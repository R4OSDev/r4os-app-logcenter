//! LOGCENTER owns non-kernel sources. Even All/export queries select only
//! these sources; kernel records are exclusively available through Spectra.
const std = @import("std");
const r4os = @import("r4os");
const abi = r4os.abi;
const sources = [_]u32{
    abi.log_service_source_driver,      abi.log_service_source_protocol,
    abi.log_service_source_application, abi.log_service_source_service,
    abi.log_service_source_console,     abi.log_service_source_diagnostic,
    abi.log_service_source_file,
};
var records: [abi.log_service_max_records]abi.LogServiceRecord = undefined;

pub fn allowed(id: u32) bool {
    for (sources) |source| if (id == source) return true;
    return false;
}

fn before(_: void, a: abi.LogServiceRecord, b: abi.LogServiceRecord) bool {
    return a.sequence < b.sequence;
}

pub fn read(sys: *const r4os.r4sys.Context, query: *const abi.LogServiceRecordQuery, out: *abi.LogServiceRecordPage) i32 {
    if (query.source_id != abi.log_service_source_any) {
        if (!allowed(query.source_id)) return -1;
        return sys.logServiceRecords(query, out);
    }
    var revision: u32 = 0;
    const count = capture(sys, query, &records, &revision) orelse return -1;
    out.* = .{ .start_index = query.start_index, .total_matches = @intCast(count), .revision = revision };
    const start = @min(@as(usize, query.start_index), count);
    const length = @min(count - start, @min(@as(usize, query.max_records), out.records.len));
    @memcpy(out.records[0..length], records[start..][0..length]);
    out.count = @intCast(length);
    out.next_index = @intCast(start + length);
    if (start + length < count) out.flags |= abi.log_service_page_flag_more;
    return abi.service_api_result_ok;
}

/// Capture the complete selected view before publishing any export bytes.
/// Each caller owns its storage; a changing service revision retries the whole
/// capture and can never produce a successful mixture of different revisions.
pub fn capture(sys: anytype, query: *const abi.LogServiceRecordQuery, storage: []abi.LogServiceRecord, revision_out: *u32) ?usize {
    if (query.source_id != abi.log_service_source_any and !allowed(query.source_id)) return null;
    for (0..3) |_| {
        var count: usize = 0;
        var revision: ?u32 = null;
        var stable = true;
        for (sources) |source| {
            if (query.source_id != abi.log_service_source_any and query.source_id != source) continue;
            var part = query.*;
            part.source_id = source;
            part.start_index = 0;
            part.max_records = abi.log_service_records_per_page;
            var source_total: ?u32 = null;
            while (true) {
                var page: abi.LogServiceRecordPage = .{};
                if (sys.logServiceRecords(&part, &page) != abi.service_api_result_ok) return null;
                if (revision) |expected| {
                    if (page.revision != expected) {
                        stable = false;
                        break;
                    }
                } else revision = page.revision;
                if (page.count > page.records.len or page.count > storage.len - count) return null;
                if (page.start_index != part.start_index or page.total_matches > abi.log_service_max_records or
                    page.next_index != part.start_index + page.count or page.next_index > page.total_matches) return null;
                if (source_total) |expected| {
                    if (page.total_matches != expected) return null;
                } else source_total = page.total_matches;
                for (page.records[0..page.count]) |record| if (record.source_id != source) return null;
                @memcpy(storage[count..][0..page.count], page.records[0..page.count]);
                count += page.count;
                if (page.flags & abi.log_service_page_flag_more == 0) {
                    if (page.next_index != page.total_matches) return null;
                    break;
                }
                if (page.count == 0 or page.next_index <= part.start_index or page.next_index > abi.log_service_max_records) return null;
                part.start_index = page.next_index;
            }
            if (!stable) break;
        }
        if (!stable) continue;
        std.mem.sort(abi.LogServiceRecord, storage[0..count], {}, before);
        revision_out.* = revision orelse 0;
        return count;
    }
    return null;
}

pub fn formatRecord(record: abi.LogServiceRecord, out: []u8) ?[]const u8 {
    return std.fmt.bufPrint(out, "seq={d} ticks={d} source={d} severity={d} flags={d} {s}: {s}\r\n", .{
        record.sequence,                    record.ticks,                     record.source_id, record.severity, record.flags,
        std.mem.sliceTo(&record.origin, 0), std.mem.sliceTo(&record.text, 0),
    }) catch null;
}

pub fn exportPage(sys: *const r4os.r4sys.Context, query: *const abi.LogServiceRecordQuery, out: *abi.LogServiceExportPage) i32 {
    var page: abi.LogServiceRecordPage = .{};
    const rc = read(sys, query, &page);
    if (rc != abi.service_api_result_ok) return rc;
    out.* = .{ .revision = page.revision, .start_index = query.start_index, .total_matches = page.total_matches, .next_index = query.start_index };
    var used: usize = 0;
    for (page.records[0..page.count]) |record| {
        const line = formatRecord(record, out.text[used..]) orelse break;
        used += line.len;
        out.next_index += 1;
    }
    out.bytes = @intCast(used);
    if (out.next_index < out.total_matches) out.flags |= abi.log_service_page_flag_more;
    if (page.count != 0 and used == 0) return -1;
    return abi.service_api_result_ok;
}

const ChangingService = struct {
    revision: u32 = 1,
    changed: bool = false,
    unstable: bool = false,
    calls: usize = 0,

    pub fn logServiceRecords(self: *ChangingService, query: *const abi.LogServiceRecordQuery, out: *abi.LogServiceRecordPage) i32 {
        self.calls += 1;
        if (query.start_index != 0 and (!self.changed or self.unstable)) {
            self.revision += 1;
            self.changed = true;
        }
        out.* = .{ .revision = self.revision, .start_index = query.start_index, .next_index = query.start_index };
        if (query.source_id != abi.log_service_source_application) return abi.service_api_result_ok;
        out.total_matches = 40;
        const start = @min(query.start_index, 40);
        const count = @min(@as(u32, out.records.len), 40 - start);
        for (out.records[0..count], 0..) |*record, i| {
            record.* = .{ .sequence = start + i + 1, .source_id = query.source_id };
            record.text[0] = if (self.changed) 'B' else 'A';
        }
        out.count = count;
        out.next_index = start + count;
        if (out.next_index < 40) out.flags |= abi.log_service_page_flag_more;
        return abi.service_api_result_ok;
    }
};

test "export snapshot retries all pages after a revision change" {
    var service: ChangingService = .{};
    var storage: [abi.log_service_max_records]abi.LogServiceRecord = undefined;
    var revision: u32 = 777;
    const query: abi.LogServiceRecordQuery = .{ .source_id = abi.log_service_source_any };
    const count = capture(&service, &query, &storage, &revision) orelse return error.CaptureFailed;
    try std.testing.expectEqual(@as(usize, 40), count);
    try std.testing.expectEqual(@as(u32, 2), revision);
    for (storage[0..count], 0..) |record, i| {
        try std.testing.expectEqual(@as(u64, i + 1), record.sequence);
        try std.testing.expectEqual(@as(u8, 'B'), record.text[0]);
        try std.testing.expectEqual(abi.log_service_source_application, record.source_id);
    }
}

test "unstable or undersized snapshot cannot publish and kernel source is refused" {
    var service: ChangingService = .{ .unstable = true };
    var storage: [abi.log_service_max_records]abi.LogServiceRecord = undefined;
    var revision: u32 = 777;
    var query: abi.LogServiceRecordQuery = .{ .source_id = abi.log_service_source_application };
    try std.testing.expectEqual(@as(?usize, null), capture(&service, &query, &storage, &revision));
    try std.testing.expectEqual(@as(u32, 777), revision);
    service = .{};
    try std.testing.expectEqual(@as(?usize, null), capture(&service, &query, storage[0..1], &revision));
    try std.testing.expectEqual(@as(u32, 777), revision);
    const calls = service.calls;
    query.source_id = abi.log_service_source_bootlog;
    try std.testing.expectEqual(@as(?usize, null), capture(&service, &query, &storage, &revision));
    try std.testing.expectEqual(calls, service.calls);
}
