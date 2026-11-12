const source_view = @import("source_view.zig");
const r4os = @import("r4os");
const std = @import("std");

const AppApi = struct {
    app: *const r4os.App2,
    sys: r4os.r4sys.Context,
    desk: r4os.r4desk.Context,
    draw: r4os.r4draw.Context,

    fn init(r4_app: *r4os.App2) ?AppApi {
        return .{
            .app = r4_app,
            .sys = r4_app.system(),
            .desk = r4_app.desktop() orelse return null,
            .draw = r4_app.drawing() orelse return null,
        };
    }
};

const bg: u32 = 0xD8D0C8;
const panel: u32 = 0xFFFFFF;
const panel_shadow: u32 = 0x808080;
const panel_light: u32 = 0xFFFFFF;
const header_bg: u32 = 0x0A246A;
const header_text: u32 = 0xFFFFFF;
const selected_bg: u32 = 0x0A246A;
const selected_text: u32 = 0xFFFFFF;
const text: u32 = 0x000000;
const muted: u32 = 0x606060;
const warn_text: u32 = 0x806000;
const danger: u32 = 0xA00000;
const ok_green: u32 = 0x007020;
const toolbar_h: i32 = 42;
const status_h: i32 = 22;
const details_h: i32 = 116;
const row_h: i32 = 20;
const source_w: i32 = 190;
const gutter: i32 = 8;
const default_export_path = "C:\\LOGCTR.TXT";
const rdp_trace_export_path = "C:\\TEMP\\RDPTRACE.TXT";

const Action = enum(u8) {
    refresh,
    live,
    prev,
    next,
    export_view,
    severity_all,
    severity_info,
    severity_warn,
    severity_error,
};

const RunMode = enum { gui, export_view, rdp_trace, selftest };

pub fn r4_app_main(r4_app: *r4os.App2) i32 {
    var ctx = AppApi.init(r4_app) orelse return r4os.abi.err_no_group;
    var app = App{ .ctx = &ctx };
    return app.run();
}

const App = struct {
    ctx: *AppApi,
    w: i32 = 820,
    h: i32 = 480,
    should_exit: bool = false,
    service_available: bool = false,
    live: bool = true,
    selected_source_id: u32 = r4os.abi.log_service_source_any,
    selected_record: usize = 0,
    record_start: u32 = 0,
    severity_min: u8 = r4os.abi.log_severity_debug,
    mouse_down_action: ?Action = null,
    search_focused: bool = false,
    search: r4os.gui.TextField(r4os.abi.log_service_search_bytes) = .{},
    status_line: [160]u8 = .{0} ** 160,
    service_status: r4os.abi.LogServiceStatus = .{},
    source_count: usize = 0,
    sources: [r4os.abi.log_service_sources_per_page]r4os.abi.LogServiceSourceInfo = .{r4os.abi.LogServiceSourceInfo{}} ** r4os.abi.log_service_sources_per_page,
    record_count: usize = 0,
    total_matches: u32 = 0,
    next_index: u32 = 0,
    has_more: bool = false,
    records: [r4os.abi.log_service_records_per_page]r4os.abi.LogServiceRecord = .{r4os.abi.LogServiceRecord{}} ** r4os.abi.log_service_records_per_page,
    export_path: [128]u8 = .{0} ** 128,
    saver: r4os.document_save.Saver = .{},
    clipboard: r4os.gui.TextClipboard = .{},

    fn run(self: *App) i32 {
        defer _ = self.clipboard.close();
        setZ(self.export_path[0..], default_export_path);
        const mode = self.applyArgs(self.ctx.app.args()) orelse return 2;
        if (mode == .selftest) return self.selfTest();
        if (mode == .rdp_trace) {
            self.configureRdpTraceExport();
            self.reload();
            const ok = self.exportCurrentView();
            self.printExportStatus();
            return if (ok) 0 else 1;
        }
        if (mode == .export_view) {
            self.reload();
            const ok = self.exportCurrentView();
            self.printExportStatus();
            return if (ok) 0 else 1;
        }
        if (self.ctx.desk.programWindowId() >= 0) {
            return self.runHosted();
        }
        self.ctx.sys.println("LOGCENTER is a desktop GUI application.");
        self.ctx.sys.println("Use /SELFTEST, /EXPORT or /RDPTRACE for console mode.");
        return 0;
    }

    fn configureRdpTraceExport(self: *App) void {
        self.selected_source_id = r4os.abi.log_service_source_service;
        self.severity_min = r4os.abi.log_severity_info;
        self.search.set("RDPSVC");
        setZ(self.export_path[0..], rdp_trace_export_path);
    }

    fn applyArgs(self: *App, args: []const u8) ?RunMode {
        var failure: r4os.arguments.Failure = .{};
        var cursor = r4os.arguments.ArgCursor.init(args, .{ .switches = r4os.arguments.slash | r4os.arguments.dash }, &failure) catch {
            self.ctx.sys.println("LOGCENTER: invalid argument text.");
            return null;
        };
        var mode: RunMode = .gui;
        while (cursor.next() catch {
            self.ctx.sys.println("LOGCENTER: invalid argument quoting.");
            return null;
        }) |token| {
            const bytes = token.bytes(args) catch return null;
            const name = trimArgPrefix(bytes);
            if (sameIgnoreCase(name, "SELFTEST")) {
                mode = .selftest;
            } else if (sameIgnoreCase(name, "RDPTRACE")) {
                if (mode != .selftest) mode = .rdp_trace;
            } else if (sameIgnoreCase(name, "EXPORT")) {
                if (mode == .gui) mode = .export_view;
            } else if (argValue(bytes, "SOURCE")) |value| {
                self.selected_source_id = sourceIdFromArg(value) orelse {
                    self.ctx.sys.println("LOGCENTER: unknown source; kernel logs use SPECTRA LOGS.");
                    return null;
                };
            } else if (argValue(bytes, "MIN")) |value| {
                self.severity_min = severityFromArg(value) orelse {
                    self.ctx.sys.println("LOGCENTER: unknown minimum severity.");
                    return null;
                };
            } else if (argValue(bytes, "SEARCH")) |value| {
                if (value.len >= self.search.buffer.len) {
                    self.ctx.sys.println("LOGCENTER: search exceeds the search capacity.");
                    return null;
                }
                self.search.set(value);
            } else if (argValue(bytes, "OUT")) |value| {
                if (value.len >= self.export_path.len) {
                    self.ctx.sys.println("LOGCENTER: output path exceeds the path capacity.");
                    return null;
                }
                if (value.len != 0) setZ(self.export_path[0..], value);
            }
        }
        return mode;
    }

    fn printExportStatus(self: *App) void {
        self.ctx.sys.println(spanZ(self.status_line[0..]));
    }

    fn runHosted(self: *App) i32 {
        _ = self.ctx.desk.guiSetTitle("Log Center");
        _ = self.ctx.desk.guiSetMinSize(760, 420);
        self.updateMetrics();
        self.reload();
        self.render();

        var timers: [1]r4os.Timer = .{.{}};
        var events = r4os.EventLoop.init(self.ctx.sys, self.ctx.desk, &timers);
        while (!self.ctx.sys.programShouldClose() and !self.should_exit) {
            if (self.live and !timers[0].active) {
                if (!timers[0].start(&self.ctx.sys, .{ .value = 1 }, .{ .nanoseconds = 1_000_000_000 }, true)) return -1;
            } else if (!self.live) timers[0].cancel();
            var dirty = false;
            switch (events.wait(r4os.time_contract.timeoutForever())) {
                .message => |message| {
                    if (message == .timer) {
                        self.reload();
                        self.render();
                        continue;
                    }
                    const event = message.guiEvent() orelse continue;
                    const kind: r4os.abi.GuiEventKind = @enumFromInt(event.kind);
                    switch (kind) {
                        .close => return 0,
                        .resize, .font_changed => {
                            self.updateMetrics();
                            dirty = true;
                        },
                        .input_reset, .focus_lost => {
                            const repaint = self.mouse_down_action != null;
                            self.mouse_down_action = null;
                            if (repaint) self.render();
                        },
                        .mouse_down => self.handleMouseDown(event.x, event.y),
                        .mouse_up => self.handleMouseUp(event.x, event.y),
                        .key_down => self.handleKey(event.key),
                        else => {},
                    }
                },
                .failure => |raw| return raw,
                .timed_out => {},
            }
            if (dirty) self.render();
        }
        return 0;
    }

    fn updateMetrics(self: *App) void {
        var info: r4os.abi.GuiWindowInfo = .{};
        _ = self.ctx.desk.guiWindowInfo(&info);
        const canvas = r4os.gui.Canvas.init(&self.ctx.draw, info);
        self.w = @max(canvas.w, 760);
        self.h = @max(canvas.h, 420);
    }

    fn reload(self: *App) void {
        self.service_available = false;
        self.source_count = 0;
        self.record_count = 0;
        self.total_matches = 0;
        self.next_index = 0;
        self.has_more = false;

        var client = switch (source_view.Client.open(self.ctx.sys)) {
            .client => |value| value,
            .failure => |raw| {
                self.setUnavailableStatus(raw);
                return;
            },
        };
        defer _ = client.close();
        for (0..3) |_| {
            var status: r4os.abi.LogServiceStatus = .{};
            const status_rc = client.logServiceStatus(&status);
            if (status_rc != r4os.abi.service_api_result_ok) {
                self.setUnavailableStatus(status_rc);
                return;
            }
            var candidates: [r4os.abi.log_service_source_count]r4os.abi.LogServiceSourceInfo = undefined;
            var source_revision: u32 = 0;
            const count = source_view.captureSources(&client, &candidates, &source_revision) orelse continue;
            var query = self.makeRecordQuery();
            var page: r4os.abi.LogServiceRecordPage = .{};
            if (source_view.read(&client, &query, &page) != r4os.abi.service_api_result_ok) continue;
            if (page.count == 0 and self.record_start > 0) {
                query.start_index = 0;
                if (source_view.read(&client, &query, &page) != r4os.abi.service_api_result_ok) continue;
            }
            var after: r4os.abi.LogServiceStatus = .{};
            if (client.logServiceStatus(&after) != r4os.abi.service_api_result_ok) break;
            if (status.revision != source_revision or page.revision != source_revision or after.revision != source_revision) continue;
            self.service_status = after;
            self.service_status.record_count = 0;
            self.service_status.total_records = 0;
            self.service_status.dropped_records = 0;
            for (candidates[0..count]) |source| {
                if (!source_view.allowed(source.id)) continue;
                if (self.source_count == self.sources.len) {
                    self.setErrorStatus("Source capacity", r4os.abi.service_api_result_buffer_too_small);
                    return;
                }
                self.sources[self.source_count] = source;
                self.source_count += 1;
                self.service_status.record_count += source.stored_records;
                self.service_status.total_records += source.total_records;
                self.service_status.dropped_records += source.dropped_records;
            }
            self.record_start = query.start_index;
            self.record_count = page.count;
            self.total_matches = page.total_matches;
            self.next_index = page.next_index;
            self.has_more = page.flags & r4os.abi.log_service_page_flag_more != 0;
            @memcpy(self.records[0..self.record_count], page.records[0..self.record_count]);
            self.selected_record = if (self.record_count == 0) 0 else @min(self.selected_record, self.record_count - 1);
            self.service_available = true;
            self.setReadyStatus();
            return;
        }
        if (client.last_error) |raw| {
            self.setErrorStatus("Complete log snapshot", raw);
        } else {
            self.setStatus("Log snapshot changed or invalid. Refresh to retry.");
        }
    }

    fn makeRecordQuery(self: *const App) r4os.abi.LogServiceRecordQuery {
        var query = r4os.abi.LogServiceRecordQuery{
            .start_index = self.record_start,
            .max_records = r4os.abi.log_service_records_per_page,
            .source_id = self.selected_source_id,
            .severity_min = self.severity_min,
        };
        copyFixedZ(query.search[0..], self.search.value());
        return query;
    }

    fn render(self: *App) void {
        var paint = switch (r4os.app_gui.beginPaintForSize(&self.ctx.draw, self.w, self.h)) {
            .paint => |value| value,
            .failure => return,
        };
        defer paint.discard();
        const canvas = paint.canvas;
        var scratch: [256]u8 = .{0} ** 256;
        _ = canvas.clear(bg);
        self.drawToolbar(canvas, scratch[0..]);
        if (!self.service_available) {
            self.drawUnavailable(canvas, scratch[0..]);
        } else {
            self.drawSources(canvas, scratch[0..]);
            self.drawRecords(canvas, scratch[0..]);
            self.drawDetails(canvas, scratch[0..]);
        }
        self.drawStatus(canvas, scratch[0..]);
        _ = paint.present();
    }

    fn drawToolbar(self: *App, canvas: r4os.gui.Canvas, scratch: []u8) void {
        self.search.focused = self.search_focused;
        _ = canvas.rect(.{ .x = 0, .y = 0, .w = self.w, .h = toolbar_h }, bg);
        self.drawActionButton(canvas, scratch, .refresh, "Refresh");
        self.drawActionButton(canvas, scratch, .live, if (self.live) "Pause" else "Live");
        self.drawActionButton(canvas, scratch, .prev, "Prev");
        self.drawActionButton(canvas, scratch, .next, "Next");
        self.drawActionButton(canvas, scratch, .export_view, "Export");
        self.drawActionButton(canvas, scratch, .severity_all, "All");
        self.drawActionButton(canvas, scratch, .severity_info, "Info");
        self.drawActionButton(canvas, scratch, .severity_warn, "Warn");
        self.drawActionButton(canvas, scratch, .severity_error, "Error");
        _ = canvas.label(.{ .rect = .{ .x = 536, .y = 13, .w = 46, .h = 16 }, .text = "Search:", .alignment = .right, .fg = text, .bg = bg }, scratch);
        _ = self.search.draw(canvas, self.searchRect(), scratch);
    }

    fn drawActionButton(self: *App, canvas: r4os.gui.Canvas, scratch: []u8, action: Action, label: []const u8) void {
        const selected = (action == .severity_all and self.severity_min == r4os.abi.log_severity_debug) or
            (action == .severity_info and self.severity_min == r4os.abi.log_severity_info) or
            (action == .severity_warn and self.severity_min == r4os.abi.log_severity_warn) or
            (action == .severity_error and self.severity_min == r4os.abi.log_severity_error);
        _ = canvas.button(.{
            .rect = self.actionRect(action),
            .text = label,
            .state = if (self.actionDisabled(action)) .disabled else if (selected or (self.mouse_down_action != null and self.mouse_down_action.? == action)) .pressed else .normal,
        }, scratch);
    }

    fn drawUnavailable(self: *App, canvas: r4os.gui.Canvas, scratch: []u8) void {
        const rect = self.contentRect();
        _ = canvas.groupBox(.{ .rect = rect, .title = "Log Service" }, scratch);
        _ = canvas.textClipped(rect.x + 14, rect.y + 28, rect.w - 28, scratch, spanZ(self.status_line[0..]), danger, bg);
        _ = canvas.textClipped(rect.x + 14, rect.y + 50, rect.w - 28, scratch, "LOGCENTER only reads from LOGSVC. No fallback log store is used.", muted, bg);
    }

    fn drawSources(self: *App, canvas: r4os.gui.Canvas, scratch: []u8) void {
        const rect = self.sourceRect();
        _ = canvas.rect(rect, panel_shadow);
        _ = canvas.rect(.{ .x = rect.x + 1, .y = rect.y + 1, .w = rect.w - 2, .h = rect.h - 2 }, panel);
        _ = canvas.rect(self.sourceHeaderRect(), header_bg);
        _ = canvas.text(self.sourceHeaderRect().x + 6, self.sourceHeaderRect().y + 5, "Sources", header_text, header_bg);
        self.drawSourceRow(canvas, scratch, 0, r4os.abi.log_service_source_any, "All", self.service_status.record_count, self.service_status.total_records, self.service_status.dropped_records);
        var i: usize = 0;
        while (i < self.source_count) : (i += 1) {
            const source = &self.sources[i];
            self.drawSourceRow(canvas, scratch, i + 1, source.id, spanZ(source.name[0..]), source.stored_records, source.total_records, source.dropped_records);
        }
    }

    fn drawSourceRow(self: *App, canvas: r4os.gui.Canvas, scratch: []u8, row: usize, source_id: u32, name: []const u8, stored: u32, total: u64, dropped: u64) void {
        const rect = self.sourceRowRect(row);
        if (rect.y + rect.h > self.sourceRect().bottom() - 1) return;
        const selected_row = source_id == self.selected_source_id;
        const bg_color = if (selected_row) selected_bg else panel;
        const fg_color = if (selected_row) selected_text else text;
        _ = canvas.rect(rect, bg_color);
        _ = canvas.textClipped(rect.x + 6, rect.y + 4, 92, scratch, name, fg_color, bg_color);
        numberText(scratch, stored);
        _ = canvas.textClipped(rect.x + 102, rect.y + 4, 34, scratch, spanZ(scratch), fg_color, bg_color);
        numberText(scratch, total);
        _ = canvas.textClipped(rect.x + 138, rect.y + 4, 42, scratch, spanZ(scratch), if (dropped > 0) danger else fg_color, bg_color);
    }

    fn drawRecords(self: *App, canvas: r4os.gui.Canvas, scratch: []u8) void {
        const rect = self.recordRect();
        _ = canvas.rect(rect, panel_shadow);
        _ = canvas.rect(.{ .x = rect.x + 1, .y = rect.y + 1, .w = rect.w - 2, .h = rect.h - 2 }, panel);
        const header = self.recordHeaderRect();
        _ = canvas.rect(header, header_bg);
        _ = canvas.text(header.x + 6, header.y + 5, "Seq", header_text, header_bg);
        _ = canvas.text(header.x + 70, header.y + 5, "Level", header_text, header_bg);
        _ = canvas.text(header.x + 122, header.y + 5, "Source", header_text, header_bg);
        _ = canvas.text(header.x + 214, header.y + 5, "Type", header_text, header_bg);
        _ = canvas.text(header.x + 340, header.y + 5, "Origin", header_text, header_bg);
        _ = canvas.text(header.x + 446, header.y + 5, "Message", header_text, header_bg);
        var row: usize = 0;
        const rows = @min(self.visibleRecordRows(), self.record_count);
        while (row < rows) : (row += 1) self.drawRecordRow(canvas, scratch, row);
        if (self.record_count == 0) {
            _ = canvas.textClipped(rect.x + 10, header.bottom() + 10, rect.w - 20, scratch, "No matching records.", muted, panel);
        }
    }

    fn drawRecordRow(self: *App, canvas: r4os.gui.Canvas, scratch: []u8, row: usize) void {
        const record = &self.records[row];
        const rect = self.recordRowRect(row);
        const selected_row = row == self.selected_record;
        const bg_color = if (selected_row) selected_bg else panel;
        const fg_color = if (selected_row) selected_text else text;
        _ = canvas.rect(rect, bg_color);
        numberText(scratch, record.sequence);
        _ = canvas.textClipped(rect.x + 6, rect.y + 4, 58, scratch, spanZ(scratch), fg_color, bg_color);
        _ = canvas.textClipped(rect.x + 70, rect.y + 4, 48, scratch, severityName(record.severity), severityColor(record.severity, fg_color), bg_color);
        _ = canvas.textClipped(rect.x + 122, rect.y + 4, 86, scratch, self.sourceName(record.source_id), fg_color, bg_color);
        _ = canvas.textClipped(rect.x + 214, rect.y + 4, 120, scratch, recordTypeName(record.record_type), fg_color, bg_color);
        _ = canvas.textClipped(rect.x + 340, rect.y + 4, 100, scratch, recordOrigin(record), fg_color, bg_color);
        _ = canvas.textClipped(rect.x + 446, rect.y + 4, rect.w - 452, scratch, recordText(record), fg_color, bg_color);
    }

    fn drawDetails(self: *App, canvas: r4os.gui.Canvas, scratch: []u8) void {
        const rect = self.detailsRect();
        _ = canvas.groupBox(.{ .rect = rect, .title = "Details" }, scratch);
        if (self.record_count == 0) {
            _ = canvas.text(rect.x + 12, rect.y + 28, "No record selected.", muted, bg);
            return;
        }
        const record = &self.records[self.selected_record];
        var line: [220]u8 = .{0} ** 220;
        setZ(line[0..], "Source: ");
        appendZ(line[0..], self.sourceName(record.source_id));
        appendZ(line[0..], "   Type: ");
        appendZ(line[0..], recordTypeName(record.record_type));
        appendZ(line[0..], "   Severity: ");
        appendZ(line[0..], severityName(record.severity));
        appendZ(line[0..], "   Seq: ");
        appendDec(line[0..], record.sequence);
        _ = canvas.textClipped(rect.x + 12, rect.y + 24, rect.w - 24, scratch, spanZ(line[0..]), text, bg);

        setZ(line[0..], "Origin: ");
        appendZ(line[0..], recordOrigin(record));
        appendZ(line[0..], "   Ticks: ");
        appendDec(line[0..], record.ticks);
        appendZ(line[0..], "   Flags: ");
        appendZ(line[0..], flagText(record.flags));
        _ = canvas.textClipped(rect.x + 12, rect.y + 44, rect.w - 24, scratch, spanZ(line[0..]), text, bg);

        setZ(line[0..], "Text: ");
        appendZ(line[0..], recordText(record));
        _ = canvas.textClipped(rect.x + 12, rect.y + 64, rect.w - 24, scratch, spanZ(line[0..]), text, bg);
        if ((record.flags & r4os.abi.log_service_record_flag_truncated) != 0) {
            _ = canvas.textClipped(rect.x + 12, rect.y + 84, rect.w - 24, scratch, "This record is truncated by the LOGSVC record-size contract.", danger, bg);
        }
    }

    fn drawStatus(self: *App, canvas: r4os.gui.Canvas, scratch: []u8) void {
        const rect = self.statusRect();
        _ = canvas.rect(rect, 0xC0C0C0);
        _ = canvas.rect(.{ .x = rect.x + 1, .y = rect.y + 1, .w = rect.w - 2, .h = rect.h - 2 }, bg);
        _ = canvas.textClipped(rect.x + 6, rect.y + 5, rect.w - 12, scratch, spanZ(self.status_line[0..]), text, bg);
    }

    fn handleMouseDown(self: *App, x: i32, y: i32) void {
        self.mouse_down_action = null;
        if (self.searchRect().contains(x, y)) {
            self.search_focused = true;
            self.render();
            return;
        }
        self.search_focused = false;
        if (self.actionAt(x, y)) |action| {
            if (!self.actionDisabled(action)) {
                self.mouse_down_action = action;
                self.render();
            }
            return;
        }
        if (self.service_available and self.selectSourceAt(x, y)) return;
        if (self.service_available and self.selectRecordAt(x, y)) return;
        self.render();
    }

    fn handleMouseUp(self: *App, x: i32, y: i32) void {
        if (self.mouse_down_action) |action| {
            const hit = self.actionRect(action).contains(x, y);
            self.mouse_down_action = null;
            if (hit and !self.actionDisabled(action)) self.activate(action);
            self.render();
        }
    }

    fn handleSearchKey(self: *App, codepoint: u32) bool {
        if (codepoint != r4os.gui.Key.ctrl_c and codepoint != r4os.gui.Key.ctrl_x and codepoint != r4os.gui.Key.ctrl_v)
            return self.search.handleCodepointChecked(codepoint);
        const connected = self.clipboard.connect(&self.ctx.sys);
        if (connected != 0) {
            self.setErrorStatus("Clipboard", connected);
            self.render();
            return false;
        }
        const range = self.search.selectionRange();
        if (codepoint == r4os.gui.Key.ctrl_c or codepoint == r4os.gui.Key.ctrl_x) {
            const selected = if (self.search.hasSelection()) self.search.value()[range.start..range.end] else self.search.value();
            const copied = self.clipboard.copy(selected);
            if (copied != 0) {
                self.setErrorStatus("Clipboard", copied);
                self.render();
                return false;
            }
            if (codepoint == r4os.gui.Key.ctrl_c) return false;
            if (self.search.hasSelection()) return self.search.handleKey(r4os.gui.Key.delete);
            self.search.clear();
            return true;
        }
        var scratch: [r4os.abi.log_service_search_bytes]u8 = undefined;
        const result = self.clipboard.read(&scratch);
        if (result < 0) {
            self.setErrorStatus("Clipboard", result);
            self.render();
            return false;
        }
        const count: usize = @intCast(result);
        const capacity = self.search.buffer.len - 1 - self.search.len + range.end - range.start;
        if (count > capacity) {
            self.setStatus("Clipboard search text exceeds the search capacity.");
            self.render();
            return false;
        }
        for (scratch[0..count]) |byte| {
            if (byte < 0x20 or byte == 0x7f) {
                self.setStatus("Clipboard search text contains a control character.");
                self.render();
                return false;
            }
        }
        return self.search.pasteSlice(scratch[0..count]);
    }

    fn handleKey(self: *App, codepoint: u32) void {
        const key: u8 = if (codepoint <= 0xff) @intCast(codepoint) else 0;
        if (self.search_focused) {
            if (key == r4os.gui.Key.escape or key == r4os.gui.Key.tab) {
                self.search_focused = false;
                self.render();
                return;
            }
            if (key == r4os.gui.Key.enter) {
                self.record_start = 0;
                self.reload();
                self.render();
                return;
            }
            if (self.handleSearchKey(codepoint)) {
                self.record_start = 0;
                self.reload();
                self.render();
            }
            return;
        }
        switch (codepoint) {
            r4os.gui.Key.escape => self.should_exit = true,
            r4os.gui.Key.tab => {
                self.search_focused = true;
                self.render();
            },
            r4os.gui.Key.up => {
                if (self.selected_record > 0) self.selected_record -= 1;
                self.render();
            },
            r4os.gui.Key.down => {
                if (self.selected_record + 1 < self.record_count) self.selected_record += 1;
                self.render();
            },
            r4os.gui.Key.page_up, r4os.gui.Key.left => {
                self.previousPage();
                self.render();
            },
            r4os.gui.Key.page_down, r4os.gui.Key.right => {
                self.nextPageAction();
                self.render();
            },
            r4os.gui.Key.home => {
                self.record_start = 0;
                self.reload();
                self.render();
            },
            r4os.gui.Key.end => {
                self.lastPage();
                self.render();
            },
            'r', 'R' => {
                self.reload();
                self.render();
            },
            'p', 'P' => {
                self.live = !self.live;
                self.setReadyStatus();
                self.render();
            },
            'e', 'E' => {
                _ = self.exportCurrentView();
                self.render();
            },
            else => {},
        }
    }

    fn activate(self: *App, action: Action) void {
        switch (action) {
            .refresh => self.reload(),
            .live => {
                self.live = !self.live;
                self.setReadyStatus();
            },
            .prev => self.previousPage(),
            .next => self.nextPageAction(),
            .export_view => _ = self.exportCurrentView(),
            .severity_all => self.setSeverity(r4os.abi.log_severity_debug),
            .severity_info => self.setSeverity(r4os.abi.log_severity_info),
            .severity_warn => self.setSeverity(r4os.abi.log_severity_warn),
            .severity_error => self.setSeverity(r4os.abi.log_severity_error),
        }
    }

    fn setSeverity(self: *App, severity: u8) void {
        self.severity_min = severity;
        self.record_start = 0;
        self.selected_record = 0;
        self.reload();
    }

    fn previousPage(self: *App) void {
        const page: u32 = @intCast(r4os.abi.log_service_records_per_page);
        self.record_start = if (self.record_start > page) self.record_start - page else 0;
        self.selected_record = 0;
        self.reload();
    }

    fn nextPageAction(self: *App) void {
        if (!self.has_more) return;
        self.record_start = self.next_index;
        self.selected_record = 0;
        self.reload();
    }

    fn lastPage(self: *App) void {
        const page: u32 = @intCast(r4os.abi.log_service_records_per_page);
        self.record_start = if (self.total_matches > page) self.total_matches - page else 0;
        self.selected_record = 0;
        self.reload();
    }

    fn exportCurrentView(self: *App) bool {
        if (!self.service_available) {
            self.setStatus("Cannot export: LOGSVC is unavailable.");
            return false;
        }
        const allocator = self.ctx.sys.allocator();
        const snapshot = allocator.alloc(r4os.abi.LogServiceRecord, r4os.abi.log_service_max_records) catch {
            self.setStatus("Export failed: not enough memory.");
            return false;
        };
        defer allocator.free(snapshot);
        var revision: u32 = 0;
        const query = self.makeRecordQuery();
        var client = switch (source_view.Client.open(self.ctx.sys)) {
            .client => |value| value,
            .failure => |raw| {
                self.setErrorStatus("Export endpoint", raw);
                return false;
            },
        };
        defer _ = client.close();
        const count = source_view.capture(&client, &query, snapshot, &revision) orelse {
            self.setStatus("Export failed: no stable log snapshot.");
            return false;
        };
        if (count == 0) {
            self.setStatus("No matching records to export.");
            return false;
        }
        // Bounded record strings plus ample space for all numeric fields and
        // labels. Both buffers belong to this process, never its small stack.
        const bytes = allocator.alloc(u8, count * (@sizeOf(r4os.abi.LogServiceRecord) + 192)) catch {
            self.setStatus("Export failed: not enough memory.");
            return false;
        };
        defer allocator.free(bytes);
        var total_bytes: usize = 0;
        for (snapshot[0..count]) |record| {
            const formatted = source_view.formatRecord(record, bytes[total_bytes..]) orelse {
                self.setStatus("Export failed: record too long.");
                return false;
            };
            total_bytes += formatted.len;
        }
        const saved = self.saver.save(.{ .sys = self.ctx.sys }, .{ .ptr = zptr(self.export_path[0..]), .len = @intCast(spanZ(self.export_path[0..]).len) }, bytes[0..total_bytes], false);
        if (!saved.committed()) {
            self.setStatus(saved.message());
            return false;
        }
        var line: [160]u8 = .{0} ** 160;
        setZ(line[0..], "Exported ");
        appendDec(line[0..], total_bytes);
        appendZ(line[0..], " bytes to ");
        appendZ(line[0..], spanZ(self.export_path[0..]));
        if (saved == .saved_backup_retained) appendZ(line[0..], " (backup retained)");
        self.setStatus(spanZ(line[0..]));
        return true;
    }

    fn selfTest(self: *App) i32 {
        self.ctx.sys.println("LOGCENTER selftest");
        const fixtures = [_]struct { source: u32, record_type: u8, text: []const u8 }{
            .{ .source = r4os.abi.log_service_source_driver, .record_type = r4os.abi.log_record_type_status_snapshot, .text = "selftest driver snapshot" },
            .{ .source = r4os.abi.log_service_source_protocol, .record_type = r4os.abi.log_record_type_status_snapshot, .text = "selftest protocol snapshot" },
            .{ .source = r4os.abi.log_service_source_application, .record_type = r4os.abi.log_record_type_event, .text = "selftest application event" },
            .{ .source = r4os.abi.log_service_source_service, .record_type = r4os.abi.log_record_type_status_snapshot, .text = "selftest service snapshot" },
            .{ .source = r4os.abi.log_service_source_console, .record_type = r4os.abi.log_record_type_console_output, .text = "selftest console output" },
            .{ .source = r4os.abi.log_service_source_diagnostic, .record_type = r4os.abi.log_record_type_diagnostic_snapshot, .text = "selftest diagnostic snapshot" },
            .{ .source = r4os.abi.log_service_source_file, .record_type = r4os.abi.log_record_type_file_record, .text = "selftest file record" },
        };
        for (fixtures) |fixture| {
            if (self.ctx.sys.logServiceWriteRecord(fixture.source, fixture.record_type, r4os.abi.log_severity_info, "LOGCENTER", fixture.text) != r4os.abi.service_api_result_ok)
                return self.fail("fixture-write");
        }

        self.reload();
        if (!self.service_available) return self.fail("status");
        if (!self.hasAllSources()) return self.fail("sources");
        self.ctx.sys.println("LOGCENTER sources: OK");
        if (self.record_count == 0 or self.total_matches == 0) return self.fail("records");
        if (!self.queryHasRecords(r4os.abi.log_service_source_driver) or
            !self.queryHasRecords(r4os.abi.log_service_source_protocol) or
            !self.queryHasRecords(r4os.abi.log_service_source_service) or
            !self.queryHasRecords(r4os.abi.log_service_source_console) or
            !self.queryHasRecords(r4os.abi.log_service_source_diagnostic) or
            !self.queryHasRecords(r4os.abi.log_service_source_file))
        {
            return self.fail("multi-source-records");
        }
        self.ctx.sys.println("LOGCENTER records: OK");

        self.selected_source_id = r4os.abi.log_service_source_service;
        self.severity_min = r4os.abi.log_severity_info;
        self.search.set("TIMESVC");
        self.record_start = 0;
        self.reload();
        if (self.total_matches == 0) return self.fail("filters");
        self.ctx.sys.println("LOGCENTER filters: OK");

        if (!self.exportCurrentView()) return self.fail("export");
        self.ctx.sys.println("LOGCENTER export: OK");

        if (!self.unavailableStateSelfTest()) return self.fail("unavailable");
        self.ctx.sys.println("LOGCENTER unavailable state: OK");
        self.ctx.sys.println("LOGCENTER selftest: OK");
        return 0;
    }

    fn unavailableStateSelfTest(self: *App) bool {
        var info: r4os.abi.ServiceInfo = .{};
        const stop_rc = self.ctx.sys.serviceStop("LOGSVC", &info, 80);
        if (stop_rc != r4os.abi.service_api_result_ok and stop_rc != r4os.abi.service_api_result_not_running) return false;
        self.ctx.sys.sleepTicks(8);
        self.reload();
        const unavailable_ok = !self.service_available and spanZ(self.status_line[0..]).len > 0;
        const start_rc = self.ctx.sys.serviceStart("LOGSVC", &info);
        if (start_rc != r4os.abi.service_api_result_ok and start_rc != r4os.abi.service_api_result_running) return false;
        var tries: u32 = 0;
        while (tries < 40) : (tries += 1) {
            var status: r4os.abi.LogServiceStatus = .{};
            if (self.ctx.sys.logServiceStatus(&status) == r4os.abi.service_api_result_ok) {
                self.reload();
                return unavailable_ok;
            }
            self.ctx.sys.sleepTicks(5);
        }
        return false;
    }

    fn hasAllSources(self: *const App) bool {
        return self.hasSource(r4os.abi.log_service_source_driver) and
            self.hasSource(r4os.abi.log_service_source_protocol) and
            self.hasSource(r4os.abi.log_service_source_application) and
            self.hasSource(r4os.abi.log_service_source_service) and
            self.hasSource(r4os.abi.log_service_source_console) and
            self.hasSource(r4os.abi.log_service_source_diagnostic) and
            self.hasSource(r4os.abi.log_service_source_file);
    }

    fn hasSource(self: *const App, source_id: u32) bool {
        var i: usize = 0;
        while (i < self.source_count) : (i += 1) {
            if (self.sources[i].id == source_id) return true;
        }
        return false;
    }

    fn queryHasRecords(self: *App, source_id: u32) bool {
        var query = r4os.abi.LogServiceRecordQuery{
            .source_id = source_id,
            .severity_min = r4os.abi.log_severity_debug,
            .max_records = r4os.abi.log_service_records_per_page,
        };
        var page: r4os.abi.LogServiceRecordPage = .{};
        var client = switch (source_view.Client.open(self.ctx.sys)) {
            .client => |value| value,
            .failure => return false,
        };
        defer _ = client.close();
        return source_view.read(&client, &query, &page) == r4os.abi.service_api_result_ok and page.total_matches > 0;
    }

    fn fail(self: *App, label: []const u8) i32 {
        self.ctx.sys.write("LOGCENTER selftest FAILED: ");
        self.ctx.sys.println(label);
        const status = spanZ(self.status_line[0..]);
        if (status.len > 0) {
            self.ctx.sys.write("LOGCENTER status: ");
            self.ctx.sys.println(status);
        }
        return 1;
    }

    fn setUnavailableStatus(self: *App, rc: i32) void {
        var line: [160]u8 = .{0} ** 160;
        setZ(line[0..], "Log service unavailable: ");
        appendZ(line[0..], resultName(rc));
        appendZ(line[0..], ". Start LOGSVC.R4X to view records.");
        self.setStatus(spanZ(line[0..]));
    }

    fn setErrorStatus(self: *App, label: []const u8, rc: i32) void {
        var line: [160]u8 = undefined;
        const message = std.fmt.bufPrint(&line, "{s} failed: {s} ({d})", .{ label, resultName(rc), rc }) catch "Log operation failed";
        self.setStatus(message);
    }

    fn setReadyStatus(self: *App) void {
        var line: [160]u8 = .{0} ** 160;
        setZ(line[0..], if (self.live) "Live" else "Paused");
        appendZ(line[0..], " | ");
        appendDec(line[0..], self.record_count);
        appendZ(line[0..], " shown of ");
        appendDec(line[0..], self.total_matches);
        appendZ(line[0..], " matching | source=");
        appendZ(line[0..], if (self.selected_source_id == r4os.abi.log_service_source_any) "All" else self.sourceName(self.selected_source_id));
        appendZ(line[0..], " | min=");
        appendZ(line[0..], severityName(self.severity_min));
        appendZ(line[0..], " | dropped=");
        appendDec(line[0..], self.service_status.dropped_records);
        self.setStatus(spanZ(line[0..]));
    }

    fn setStatus(self: *App, value: []const u8) void {
        setZ(self.status_line[0..], value);
    }

    fn sourceName(self: *const App, source_id: u32) []const u8 {
        var i: usize = 0;
        while (i < self.source_count) : (i += 1) {
            if (self.sources[i].id == source_id) return spanZ(self.sources[i].name[0..]);
        }
        return builtinSourceName(source_id);
    }

    fn actionAt(self: *const App, x: i32, y: i32) ?Action {
        inline for (action_order) |action| {
            if (self.actionRect(action).contains(x, y)) return action;
        }
        return null;
    }

    fn actionDisabled(self: *const App, action: Action) bool {
        return switch (action) {
            .refresh, .live => false,
            .prev => !self.service_available or self.record_start == 0,
            .next => !self.service_available or !self.has_more,
            .export_view => !self.service_available or self.total_matches == 0,
            .severity_all, .severity_info, .severity_warn, .severity_error => !self.service_available,
        };
    }

    fn selectSourceAt(self: *App, x: i32, y: i32) bool {
        if (!self.sourceRect().contains(x, y) or y < self.firstSourceRowY()) return false;
        const row: usize = @intCast(@divTrunc(y - self.firstSourceRowY(), row_h));
        if (row == 0) {
            self.selected_source_id = r4os.abi.log_service_source_any;
        } else if (row - 1 < self.source_count) {
            self.selected_source_id = self.sources[row - 1].id;
        } else {
            return false;
        }
        self.record_start = 0;
        self.selected_record = 0;
        self.reload();
        self.render();
        return true;
    }

    fn selectRecordAt(self: *App, x: i32, y: i32) bool {
        if (!self.recordRect().contains(x, y) or y < self.firstRecordRowY()) return false;
        const row: usize = @intCast(@divTrunc(y - self.firstRecordRowY(), row_h));
        if (row >= self.record_count or row >= self.visibleRecordRows()) return false;
        self.selected_record = row;
        self.render();
        return true;
    }

    fn contentRect(self: *const App) r4os.gui.Rect {
        return .{ .x = 8, .y = toolbar_h, .w = self.w - 16, .h = self.h - toolbar_h - status_h - 8 };
    }

    fn sourceRect(self: *const App) r4os.gui.Rect {
        return .{ .x = 8, .y = toolbar_h, .w = source_w, .h = self.h - toolbar_h - details_h - status_h - 12 };
    }

    fn sourceHeaderRect(self: *const App) r4os.gui.Rect {
        const rect = self.sourceRect();
        return .{ .x = rect.x + 1, .y = rect.y + 1, .w = rect.w - 2, .h = row_h };
    }

    fn firstSourceRowY(self: *const App) i32 {
        return self.sourceHeaderRect().bottom();
    }

    fn sourceRowRect(self: *const App, row: usize) r4os.gui.Rect {
        const rect = self.sourceRect();
        return .{ .x = rect.x + 1, .y = self.firstSourceRowY() + @as(i32, @intCast(row)) * row_h, .w = rect.w - 2, .h = row_h };
    }

    fn recordRect(self: *const App) r4os.gui.Rect {
        const src = self.sourceRect();
        return .{ .x = src.right() + gutter, .y = toolbar_h, .w = self.w - src.right() - gutter - 8, .h = src.h };
    }

    fn recordHeaderRect(self: *const App) r4os.gui.Rect {
        const rect = self.recordRect();
        return .{ .x = rect.x + 1, .y = rect.y + 1, .w = rect.w - 2, .h = row_h };
    }

    fn firstRecordRowY(self: *const App) i32 {
        return self.recordHeaderRect().bottom();
    }

    fn recordRowRect(self: *const App, row: usize) r4os.gui.Rect {
        const rect = self.recordRect();
        return .{ .x = rect.x + 1, .y = self.firstRecordRowY() + @as(i32, @intCast(row)) * row_h, .w = rect.w - 2, .h = row_h };
    }

    fn visibleRecordRows(self: *const App) usize {
        const rows = @divTrunc(self.recordRect().h - row_h - 2, row_h);
        return if (rows <= 0) 0 else @intCast(rows);
    }

    fn detailsRect(self: *const App) r4os.gui.Rect {
        return .{ .x = 8, .y = self.h - details_h - status_h - 4, .w = self.w - 16, .h = details_h };
    }

    fn statusRect(self: *const App) r4os.gui.Rect {
        return .{ .x = 8, .y = self.h - status_h - 4, .w = self.w - 16, .h = status_h };
    }

    fn searchRect(self: *const App) r4os.gui.Rect {
        return .{ .x = 588, .y = 10, .w = @max(120, self.w - 596), .h = 22 };
    }

    fn actionRect(self: *const App, action: Action) r4os.gui.Rect {
        _ = self;
        return switch (action) {
            .refresh => .{ .x = 8, .y = 9, .w = 64, .h = 22 },
            .live => .{ .x = 78, .y = 9, .w = 58, .h = 22 },
            .prev => .{ .x = 142, .y = 9, .w = 48, .h = 22 },
            .next => .{ .x = 196, .y = 9, .w = 48, .h = 22 },
            .export_view => .{ .x = 250, .y = 9, .w = 60, .h = 22 },
            .severity_all => .{ .x = 318, .y = 9, .w = 42, .h = 22 },
            .severity_info => .{ .x = 366, .y = 9, .w = 46, .h = 22 },
            .severity_warn => .{ .x = 418, .y = 9, .w = 50, .h = 22 },
            .severity_error => .{ .x = 474, .y = 9, .w = 52, .h = 22 },
        };
    }
};

const action_order = [_]Action{ .refresh, .live, .prev, .next, .export_view, .severity_all, .severity_info, .severity_warn, .severity_error };

fn recordText(record: *const r4os.abi.LogServiceRecord) []const u8 {
    return record.text[0..@min(@as(usize, record.text_len), record.text.len)];
}

fn recordOrigin(record: *const r4os.abi.LogServiceRecord) []const u8 {
    return record.origin[0..@min(@as(usize, record.origin_len), record.origin.len)];
}

fn builtinSourceName(source_id: u32) []const u8 {
    return switch (source_id) {
        r4os.abi.log_service_source_driver => "Driver",
        r4os.abi.log_service_source_protocol => "Protocol",
        r4os.abi.log_service_source_application => "Application",
        r4os.abi.log_service_source_service => "Service",
        r4os.abi.log_service_source_console => "Console",
        r4os.abi.log_service_source_diagnostic => "Diagnostic",
        r4os.abi.log_service_source_file => "File",
        else => "All",
    };
}

fn recordTypeName(record_type: u8) []const u8 {
    return switch (record_type) {
        r4os.abi.log_record_type_event => "Event",
        r4os.abi.log_record_type_status_snapshot => "StatusSnapshot",
        r4os.abi.log_record_type_console_output => "ConsoleOutput",
        r4os.abi.log_record_type_diagnostic_snapshot => "DiagnosticSnapshot",
        r4os.abi.log_record_type_file_record => "FileRecord",
        else => "Unknown",
    };
}

fn severityName(severity: u8) []const u8 {
    return switch (severity) {
        r4os.abi.log_severity_debug => "debug",
        r4os.abi.log_severity_info => "info",
        r4os.abi.log_severity_warn => "warn",
        r4os.abi.log_severity_error => "error",
        else => "fatal",
    };
}

fn severityColor(severity: u8, fallback: u32) u32 {
    return switch (severity) {
        r4os.abi.log_severity_warn => warn_text,
        r4os.abi.log_severity_error => danger,
        else => fallback,
    };
}

fn flagText(flags: u32) []const u8 {
    if ((flags & r4os.abi.log_service_record_flag_truncated) != 0 and (flags & r4os.abi.log_service_record_flag_imported) != 0) return "imported,truncated";
    if ((flags & r4os.abi.log_service_record_flag_truncated) != 0) return "truncated";
    if ((flags & r4os.abi.log_service_record_flag_imported) != 0) return "imported";
    return "none";
}

fn resultName(rc: i32) []const u8 {
    return switch (rc) {
        r4os.abi.service_api_result_ok => "OK",
        r4os.abi.service_api_result_not_found => "not-found",
        r4os.abi.service_api_result_not_running => "not-running",
        r4os.abi.service_api_result_no_endpoint => "no-endpoint",
        r4os.abi.service_api_result_timeout => "timeout",
        r4os.abi.service_api_result_bad_handle => "bad-handle",
        r4os.abi.service_api_result_full => "full",
        r4os.abi.service_api_result_duplicate => "duplicate",
        r4os.abi.service_api_result_bad_path => "bad-path",
        r4os.abi.service_api_result_config_io => "config-io",
        r4os.abi.service_api_result_running => "running",
        r4os.abi.service_api_result_disabled => "disabled",
        r4os.abi.service_api_result_spawn_failed => "spawn-failed",
        r4os.abi.service_api_result_stop_failed => "stop-failed",
        else => "unknown",
    };
}

fn setZ(out: []u8, value: []const u8) void {
    @memset(out, 0);
    if (out.len == 0) return;
    const len = @min(out.len - 1, value.len);
    if (len > 0) @memcpy(out[0..len], value[0..len]);
}

fn appendZ(out: []u8, value: []const u8) void {
    const current = spanZ(out).len;
    if (current >= out.len) return;
    const len = @min(out.len - current - 1, value.len);
    if (len > 0) @memcpy(out[current .. current + len], value[0..len]);
}

fn appendDec(out: []u8, value: u64) void {
    var tmp: [32]u8 = .{0} ** 32;
    numberText(tmp[0..], value);
    appendZ(out, spanZ(tmp[0..]));
}

fn numberText(out: []u8, value: u64) void {
    @memset(out, 0);
    if (out.len == 0) return;
    var tmp: [32]u8 = undefined;
    var n = value;
    var pos: usize = tmp.len;
    if (n == 0) {
        pos -= 1;
        tmp[pos] = '0';
    } else {
        while (n > 0 and pos > 0) {
            pos -= 1;
            tmp[pos] = '0' + @as(u8, @intCast(n % 10));
            n /= 10;
        }
    }
    setZ(out, tmp[pos..]);
}

fn copyFixedZ(out: []u8, value: []const u8) void {
    @memset(out, 0);
    if (out.len == 0) return;
    const len = @min(out.len - 1, value.len);
    if (len > 0) @memcpy(out[0..len], value[0..len]);
}

fn spanZ(buffer: []const u8) []const u8 {
    var len: usize = 0;
    while (len < buffer.len and buffer[len] != 0) : (len += 1) {}
    return buffer[0..len];
}

fn zSlice(ptr: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (ptr[len] != 0) : (len += 1) {}
    return ptr[0..len];
}

fn zptr(buffer: []const u8) [*:0]const u8 {
    return @ptrCast(buffer.ptr);
}

fn argValue(token: []const u8, name: []const u8) ?[]const u8 {
    const trimmed = trimArgPrefix(token);
    if (trimmed.len <= name.len or trimmed[name.len] != '=') return null;
    if (!sameIgnoreCase(trimmed[0..name.len], name)) return null;
    return trimmed[name.len + 1 ..];
}

fn sourceIdFromArg(value: []const u8) ?u32 {
    if (sameIgnoreCase(value, "ALL") or sameIgnoreCase(value, "ANY")) return r4os.abi.log_service_source_any;
    if (sameIgnoreCase(value, "DRIVER")) return r4os.abi.log_service_source_driver;
    if (sameIgnoreCase(value, "PROTOCOL")) return r4os.abi.log_service_source_protocol;
    if (sameIgnoreCase(value, "APPLICATION") or sameIgnoreCase(value, "APP")) return r4os.abi.log_service_source_application;
    if (sameIgnoreCase(value, "SERVICE") or sameIgnoreCase(value, "SVC")) return r4os.abi.log_service_source_service;
    if (sameIgnoreCase(value, "CONSOLE")) return r4os.abi.log_service_source_console;
    if (sameIgnoreCase(value, "DIAGNOSTIC") or sameIgnoreCase(value, "DIAG")) return r4os.abi.log_service_source_diagnostic;
    if (sameIgnoreCase(value, "FILE")) return r4os.abi.log_service_source_file;
    return null;
}

fn severityFromArg(value: []const u8) ?u8 {
    if (sameIgnoreCase(value, "DEBUG") or sameIgnoreCase(value, "ALL")) return r4os.abi.log_severity_debug;
    if (sameIgnoreCase(value, "INFO")) return r4os.abi.log_severity_info;
    if (sameIgnoreCase(value, "WARN") or sameIgnoreCase(value, "WARNING")) return r4os.abi.log_severity_warn;
    if (sameIgnoreCase(value, "ERROR")) return r4os.abi.log_severity_error;
    return null;
}

fn trimArgPrefix(s: []const u8) []const u8 {
    if (s.len > 0 and (s[0] == '/' or s[0] == '-')) return s[1..];
    return s;
}

fn sameIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (upper(a[i]) != upper(b[i])) return false;
    }
    return true;
}

fn upper(c: u8) u8 {
    return if (c >= 'a' and c <= 'z') c - 32 else c;
}
