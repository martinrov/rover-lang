const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Ast = @import("../frontend/ast.zig");
const Stmt = Ast.Stmt;
const Expr = Ast.Expr;
const Chunk = @import("chunk.zig").Chunk;
const OpCode = @import("chunk.zig").OpCode;
const BinOpType = @import("chunk.zig").BinOpType;
const GenReport = @import("../reporter.zig").GenReport;
const Value = @import("../runtime/values.zig").Value;
const CompilerMsg = @import("compiler_msg.zig").CompilerMsg;
const BinopInfos = @import("../frontend/analyzer.zig").Analyzer.BinopInfos;
const UnsafeIter = @import("../unsafe_iter.zig").UnsafeIter;

pub const Compiler = struct {
    chunk: Chunk,
    errs: ArrayList(CompilerReport),
    binop_infos: UnsafeIter(BinopInfos),

    const Self = @This();
    const Error = Chunk.Error;

    const CompilerReport = GenReport(CompilerMsg);

    pub fn init(allocator: Allocator, binop_infos: []const BinopInfos) Self {
        return .{
            .chunk = Chunk.init(allocator),
            .errs = ArrayList(CompilerReport).init(allocator),
            .binop_infos = UnsafeIter(BinopInfos).init(binop_infos),
        };
    }

    pub fn deinit(self: *Self) void {
        self.chunk.deinit();
        self.errs.deinit();
    }

    fn write_op_and_byte(self: *Self, op: OpCode, byte: u8) !void {
        try self.chunk.write_op(op);
        try self.chunk.write_byte(byte);
    }

    fn emit_constant(self: *Self, value: Value) !void {
        self.write_op_and_byte(.Constant, try self.chunk.write_constant(value)) catch |err| {
            // The idea is to collect errors as TreeSpan index. It means the parser is
            // going to have to generate an array list of spans and we have to keep track
            // of which we are at current to let reporter take the index to have span
            // infos for report. For now, I'm gonna see if this is necessary as there
            // will probably not be that much of errors here at compile stage.
            // See if analyzer needs same mechanics?
            // const report = Report.err_at_tree_index(.TooManyConst, );
            // try self.errs.append(report);
            std.debug.print("Too many constants in chunk\n", .{});
            return err;
        };
    }

    pub fn compile(self: *Self, stmts: []const Stmt) !void {
        for (stmts) |*stmt| {
            try switch (stmt.*) {
                .VarDecl => @panic("not implemented yet"),
                .Expr => |expr| self.expression(expr),
            };
        }

        try self.chunk.write_op(.Return);
    }

    fn expression(self: *Self, expr: *const Expr) Error!void {
        try switch (expr.*) {
            .BoolLit => |*e| self.bool_lit(e),
            .BinOp => |*e| self.binop(e),
            .Grouping => |*e| self.grouping(e),
            .FloatLit => |*e| self.float_lit(e),
            .IntLit => |*e| self.int_lit(e),
            .NullLit => self.null_lit(),
            .Unary => |*e| self.unary(e),
        };
    }

    fn binop(self: *Self, expr: *const Ast.BinOp) !void {
        const infos = self.binop_infos.next();

        try self.expression(expr.lhs);

        if (infos.cast == .Lhs) {
            try self.chunk.write_op(.CastToFloat);
        }

        try self.expression(expr.rhs);

        if (infos.cast == .Rhs) {
            try self.chunk.write_op(.CastToFloat);
        }

        try switch (infos.res_type) {
            .Int => switch (expr.op) {
                .Plus => self.chunk.write_op(.AddInt),
                .Minus => self.chunk.write_op(.SubtractInt),
                .Star => self.chunk.write_op(.MultiplyInt),
                .Slash => self.chunk.write_op(.DivideInt),
                .EqualEqual => self.chunk.write_op(.EqualInt),
                .BangEqual => self.chunk.write_op(.DifferentInt),
                .Greater => self.chunk.write_op(.GreaterInt),
                .GreaterEqual => self.chunk.write_op(.GreaterEqualInt),
                .Less => self.chunk.write_op(.LessInt),
                .LessEqual => self.chunk.write_op(.LessEqualInt),
                else => unreachable,
            },
            .Float => switch (expr.op) {
                .Plus => self.chunk.write_op(.AddFloat),
                .Minus => self.chunk.write_op(.SubtractFloat),
                .Star => self.chunk.write_op(.MultiplyFloat),
                .Slash => self.chunk.write_op(.DivideFloat),
                .EqualEqual => self.chunk.write_op(.EqualFloat),
                .BangEqual => self.chunk.write_op(.DifferentFloat),
                .Greater => self.chunk.write_op(.GreaterFloat),
                .GreaterEqual => self.chunk.write_op(.GreaterEqualFloat),
                .Less => self.chunk.write_op(.LessFloat),
                .LessEqual => self.chunk.write_op(.LessEqualFloat),
                else => unreachable,
            },
            else => unreachable,
        };
    }

    fn grouping(self: *Self, expr: *const Ast.Grouping) !void {
        try self.expression(expr.expr);
    }

    fn bool_lit(self: *Self, expr: *const Ast.BoolLit) !void {
        const op: OpCode = if (expr.value) .True else .False;
        try self.chunk.write_op(op);
    }

    fn float_lit(self: *Self, expr: *const Ast.FloatLit) !void {
        try self.emit_constant(Value.float(expr.value));
    }

    fn int_lit(self: *Self, expr: *const Ast.IntLit) !void {
        try self.emit_constant(Value.int(expr.value));
    }

    fn null_lit(self: *Self) !void {
        try self.chunk.write_op(.Null);
    }

    fn unary(self: *Self, expr: *const Ast.Unary) !void {
        try self.expression(expr.rhs);

        if (expr.op == .Minus) {
            try switch (expr.type_) {
                .Int => self.chunk.write_op(.NegateInt),
                .Float => self.chunk.write_op(.NegateFloat),
                else => unreachable,
            };
        } else {
            try self.chunk.write_op(.Not);
        }
    }
};

// Tests
test Compiler {
    const GenericTester = @import("../tester.zig").GenericTester;
    const get_test_data = @import("test_compiler.zig").get_test_data;

    const Tester = GenericTester("compiler", CompilerMsg, get_test_data);
    try Tester.run();
}
