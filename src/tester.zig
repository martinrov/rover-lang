const std = @import("std");
const print = std.debug.print;
const expect = testing.expect;
const assert = std.debug.assert;
const eql = std.mem.eql;
const fields = std.meta.fields;
const testing = std.testing;
const allocator = testing.allocator;
const Allocator = std.mem.Allocator;

pub fn GenTestData(comptime Report: type) type {
    assert(@typeInfo(Report) == .@"union");

    return struct {
        expect: []const u8,
        reports: []const Report,
    };
}

pub fn GenericTester(
    foldername: []const u8,
    comptime Report: type,
    comptime get_test_data: fn ([:0]const u8, Allocator) anyerror!GenTestData(Report),
) type {
    return struct {
        const Section = enum { Code, Expect, Err, None };

        pub fn run() !void {
            const path = try std.fs.path.join(allocator, &[_][]const u8{
                "tests", foldername,
            });
            defer allocator.free(path);

            var cwd = try std.fs.cwd().openDir(path, .{ .iterate = true });
            defer cwd.close();

            var walker = try cwd.walk(allocator);
            defer walker.deinit();

            while (try walker.next()) |*entry| {
                if (std.mem.endsWith(u8, entry.basename, ".rvt")) {
                    try test_file(&cwd, entry.path);
                }
            }
        }

        fn test_file(dir: *std.fs.Dir, file_path: []const u8) !void {
            const file = try dir.openFile(file_path, .{ .mode = .read_only });
            defer file.close();

            const size = try file.getEndPos();
            const content = try allocator.alloc(u8, size + 1);
            defer allocator.free(content);

            _ = try file.readAll(content);
            content[size] = 0;

            var lines = std.mem.splitScalar(u8, content, '\n');

            var code = std.ArrayList(u8).init(allocator);
            defer code.deinit();
            var expects = std.ArrayList(u8).init(allocator);
            defer expects.deinit();
            var errors = std.ArrayList(u8).init(allocator);
            defer errors.deinit();

            var section: Section = .None;
            var test_count: usize = 0;

            while (lines.next()) |line| {
                if (line.len == 0 or std.mem.eql(u8, line, "\r")) continue;
                // If after removing the \r there is only spaces, we skip it
                if (std.mem.trimRight(u8, std.mem.trimRight(u8, line, "\r"), " ").len == 0) continue;

                if (std.mem.startsWith(u8, line, "code")) {
                    section = .Code;
                    continue;
                } else if (std.mem.startsWith(u8, line, "expect")) {
                    section = .Expect;
                    continue;
                } else if (std.mem.startsWith(u8, line, "error")) {
                    section = .Err;
                    continue;
                } else if (std.mem.startsWith(u8, line, "==")) {
                    try code.append(0);

                    run_test(code.items[0 .. code.items.len - 1 :0], expects.items, errors.items) catch |e| {
                        print("Error in test {} in file {s}\n\n", .{ test_count, file_path });
                        return e;
                    };

                    code.clearRetainingCapacity();
                    expects.clearRetainingCapacity();
                    errors.clearRetainingCapacity();
                    section = .None;
                    test_count += 1;
                    continue;
                }

                var writer = switch (section) {
                    .Code => code.writer(),
                    .Expect => expects.writer(),
                    .Err => errors.writer(),
                    .None => continue,
                };

                _ = try writer.write(std.mem.trimRight(u8, line, "\r"));
                _ = try writer.write("\n");
            }
        }

        pub fn run_test(source: [:0]const u8, exp: []const u8, errors: []const u8) !void {
            const test_data = try get_test_data(source, allocator);
            defer allocator.free(test_data.expect);
            defer allocator.free(test_data.reports);

            if (exp.len > 0) {
                expect(eql(u8, test_data.expect, exp)) catch |e| {
                    std.debug.print("expect:\n{s}\n", .{exp});
                    std.debug.print("got:\n{s}\n", .{test_data.expect});
                    return e;
                };
            } else if (errors.len > 0) {
                var all = std.mem.splitScalar(u8, errors, '\n');

                var i: usize = 0;
                while (all.next()) |err| : (i += 1) {
                    if (err.len == 0) continue;

                    var line = std.mem.splitScalar(u8, err, ',');
                    // There is at least one element, the error name
                    const err_name = line.next().?;

                    const report = test_data.reports[i];
                    const got_name = @tagName(report);
                    expect(eql(u8, err_name, got_name)) catch |e| {
                        print("expect error: {s}, got {s}\n", .{ err_name, got_name });
                        return e;
                    };

                    // We look for all the fields
                    inline for (fields(Report)) |field| {
                        // If we find the current and that it's a non-void (assuming it's a struct)
                        if (field.type != void and eql(u8, field.name, @tagName(std.meta.activeTag(report)))) {
                            const fv = @field(report, field.name);

                            // We check all the fields of the structure to test them
                            inline for (fields(field.type)) |subf| {
                                const subv = @field(fv, subf.name);

                                if (line.next()) |extra| {
                                    expect(eql(u8, std.mem.trimLeft(u8, extra, " "), subv)) catch |e| {
                                        print("expect error extra arg: {s}, got {s}\n", .{ subv, extra });
                                        return e;
                                    };
                                } else {
                                    print("expect extra argument '{s}' for report '{s}'\n", .{ subf.name, field.name });
                                    return error.TestUnexpectedResult;
                                }
                            }
                        }
                    }
                }
            } else {
                print("Error, no expect and no erros in test\n", .{});
            }
        }
    };
}
