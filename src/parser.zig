const std = @import("std");
const command = @import("command.zig");
const help = @import("./help.zig");
const Allocator = std.mem.Allocator;
const ArgIterator = std.process.ArgIterator;

var help_option = command.Option{
    .long_name = "help",
    .help = "Show this help output.",
    .short_alias = 'h',
    .value = command.OptionValue{ .bool = false },
};

const Parser = struct {
    alloc: Allocator,
    arg_iterator: *ArgIterator,
    current_command: *const command.Command,
    command_path: std.ArrayList(*const command.Command),
    captured_arguments: std.ArrayList([]const u8),

    const Self = @This();

    const ArgParseResult = union(enum) {
        command: *const command.Command,
        option: *command.Option,
        arg: []u8,
    };

    fn init(cmd: *const command.Command, it: *ArgIterator, alloc: Allocator) !*Self {
        var s = try alloc.create(Parser);
        s.alloc = alloc;
        s.arg_iterator = it;
        s.current_command = cmd;
        s.command_path = try std.ArrayList(*const command.Command).initCapacity(alloc, 16);
        s.captured_arguments = try std.ArrayList([]const u8).initCapacity(alloc, 16);
        return s;
    }

    fn deinit(self: *Self) void {
        self.captured_arguments.deinit();
        self.command_path.deinit();
        self.alloc.destroy(self);
    }

    fn parse(self: *Self) anyerror!ParseResult {
        validate_command(self.current_command);
        _ = self.arg_iterator.next(self.alloc);
        while (self.arg_iterator.next(self.alloc)) |arg| {
            var b = try arg;
            if (self.parse_arg(b)) |parsed_arg| {
                try self.process_arg(parsed_arg);
            }
        }
        var args = self.captured_arguments.toOwnedSlice();
        if (self.current_command.action) |action| {
            return ParseResult{ .action = action, .args = args };
        } else {
            fail("command '{s}': no subcommand provided", .{self.current_command.name});
            unreachable;
        }
    }

    fn process_arg(self: *Self, arg: ArgParseResult) !void {
        switch (arg) {
            .command => |cmd| {
                validate_command(cmd);
                try self.command_path.append(self.current_command);
                self.current_command = cmd;
            },
            .option => |option| {
                try self.process_option(option);
            },
            .arg => |val| {
                try self.captured_arguments.append(val);
            },
        }
    }

    fn process_option(self: *Self, option: *command.Option) !void {
        if (option == &help_option) {
            try help.print_command_help(self.current_command, self.command_path.toOwnedSlice());
            std.os.exit(0);
            unreachable;
        }

        option.value = switch (option.value) {
            .bool => command.OptionValue{ .bool = true },
            else => self.parse_option_value(option),
        };
    }

    fn parse_option_value(self: *const Self, option: *const command.Option) command.OptionValue {
        if (self.arg_iterator.next(self.alloc)) |arg| {
            var str = arg catch unreachable;
            switch (option.value) {
                .bool => unreachable,
                .string => return command.OptionValue{ .string = str },
                .int => {
                    if (std.fmt.parseInt(i64, str, 10)) |iv| {
                        return command.OptionValue{ .int = iv };
                    } else |_| {
                        fail("option({s}): cannot parse int value", .{option.long_name});
                        unreachable;
                    }
                },
                .float => {
                    if (std.fmt.parseFloat(f64, str)) |fv| {
                        return command.OptionValue{ .float = fv };
                    } else |_| {
                        fail("option({s}): cannot parse float value", .{option.long_name});
                        unreachable;
                    }
                },
            }
        } else {
            fail("missing argument for {s}", .{option.long_name});
            unreachable;
        }
    }

    fn parse_arg(self: *const Self, arg: []u8) ?ArgParseResult {
        if (arg.len == 0) return null;
        if (arg[0] == '-') {
            if (arg.len == 1) return ArgParseResult{ .arg = arg };
            if (arg[1] == '-') {
                return self.parse_long_name(arg);
            } else {
                return self.parse_short_alias(arg);
            }
        } else if (self.current_command.subcommands) |_| {
            if (find_subcommand(self.current_command, arg)) |sc| {
                return ArgParseResult{ .command = sc };
            } else {
                fail("no such subcommand '{s}'", .{arg});
                unreachable;
            }
        } else {
            return ArgParseResult{ .arg = arg };
        }
    }

    fn parse_long_name(self: *const Self, arg: []u8) ArgParseResult {
        if (arg.len == 2) {
            return ArgParseResult{ .arg = arg };
        } else if (find_option_by_name(self.current_command, arg[2..])) |option| {
            return ArgParseResult{ .option = option };
        } else {
            fail("unknown option {s}", .{arg});
            unreachable;
        }
    }

    fn parse_short_alias(self: *const Self, arg: []u8) ArgParseResult {
        if (arg.len == 1) {
            return ArgParseResult{ .arg = arg };
        } else if (arg.len > 2) {
            fail("illegal short option {s}", .{arg});
            unreachable;
        } else if (find_option_by_alias(self.current_command, arg[1])) |option| {
            return ArgParseResult{ .option = option };
        } else {
            fail("unknown option {s}", .{arg});
            unreachable;
        }
    }
};

fn fail(comptime fmt: []const u8, args: anytype) void {
    var w = std.io.getStdErr().writer();
    std.fmt.format(w, "ERROR: ", .{}) catch unreachable;
    std.fmt.format(w, fmt, args) catch unreachable;
    std.fmt.format(w, "\n", .{}) catch unreachable;
    std.os.exit(1);
}

const ParseResult = struct {
    action: command.Action,
    args: []const []const u8,
};

pub fn run(cmd: *const command.Command, alloc: Allocator) anyerror!void {
    var it = std.process.args();
    var cr = try Parser.init(cmd, &it, alloc);
    var result = try cr.parse();
    cr.deinit();
    it.deinit();

    return result.action(result.args);
}

fn find_subcommand(cmd: *const command.Command, subcommand_name: []u8) ?*const command.Command {
    if (cmd.subcommands) |sc_list| {
        for (sc_list) |sc| {
            if (std.mem.eql(u8, sc.name, subcommand_name)) {
                return sc;
            }
        }
    }
    return null;
}
fn find_option_by_name(cmd: *const command.Command, option_name: []u8) ?*command.Option {
    if (std.mem.eql(u8, "help", option_name)) {
        return &help_option;
    }
    if (cmd.options) |option_list| {
        for (option_list) |option| {
            if (std.mem.eql(u8, option.long_name, option_name)) {
                return option;
            }
        }
    }
    return null;
}
fn find_option_by_alias(cmd: *const command.Command, option_alias: u8) ?*command.Option {
    if (option_alias == 'h') {
        return &help_option;
    }
    if (cmd.options) |option_list| {
        for (option_list) |option| {
            if (option.short_alias) |alias| {
                if (alias == option_alias) {
                    return option;
                }
            }
        }
    }
    return null;
}

fn validate_command(cmd: *const command.Command) void {
    if (cmd.subcommands == null) {
        if (cmd.action == null) {
            fail("command '{s}' has neither subcommands no an aciton assigned", .{cmd.name});
        }
    } else {
        if (cmd.action != null) {
            fail("command '{s}' has subcommands and an action assigned. Commands with subcommands are not allowed to have action.", .{cmd.name});
        }
    }
}
