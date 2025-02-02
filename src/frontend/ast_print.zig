const std = @import("std");
const Allocator = std.mem.Allocator;
const print = std.debug.print;
const Ast = @import("ast.zig");
const Node = Ast.Node;
const NullNode = Ast.NullNode;
// const Expr = Ast.Expr;
// const Stmt = Ast.Stmt;
const Token = @import("lexer.zig").Token;
const Span = @import("lexer.zig").Span;

pub const AstPrinter = struct {
    source: [:0]const u8,
    token_tags: []const Token.Tag,
    token_spans: []const Span,
    node_tags: []const Node.Tag,
    node_roots: []const Ast.TokenIndex,
    node_data: []const Node.Data,
    node_idx: usize,
    main_nodes: []const usize,
    indent_level: u8 = 0,
    tree: std.ArrayList(u8),

    const indent_size: u8 = 4;
    const spaces: [1024]u8 = [_]u8{' '} ** 1024;

    const Error = Allocator.Error || std.fmt.BufPrintError;
    const Self = @This();

    pub fn init(
        allocator: Allocator,
        source: [:0]const u8,
        token_tags: []const Token.Tag,
        token_spans: []const Span,
        node_tags: []const Node.Tag,
        node_roots: []const Ast.TokenIndex,
        node_data: []const Node.Data,
        main_nodes: []const usize,
    ) Self {
        return .{
            .source = source,
            .token_tags = token_tags,
            .token_spans = token_spans,
            .node_tags = node_tags,
            .node_roots = node_roots,
            .node_data = node_data,
            .main_nodes = main_nodes,
            .node_idx = 0,
            .indent_level = 0,
            .tree = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.tree.deinit();
    }

    pub fn display(self: *const Self) void {
        print("\n--- AST ---\n{s}", .{self.tree.items});
    }

    fn indent(self: *Self) !void {
        try self.tree.appendSlice(Self.spaces[0 .. self.indent_level * Self.indent_size]);
    }

    pub fn parse_ast(self: *Self) !void {
        while (self.node_idx < self.main_nodes.len) : (self.node_idx += 1) {
            try self.parse_node(self.main_nodes[self.node_idx]);
        }
    }

    fn parse_node(self: *Self, index: Node.Index) !void {
        try switch (self.node_tags[index]) {
            .Add, .Div, .Mul, .Sub => self.binop_expr(index),
            .Assignment => self.assignment(index),
            .Block => self.block_expr(index),
            .Bool => self.literal("Bool literal", index),
            .Discard => self.discard(index),
            .Float => self.literal("Float literal", index),
            .Grouping => self.grouping(index),
            .Identifier => self.literal("Identifier", index),
            .Int => self.literal("Int literal", index),
            .Null => self.null_(),
            .Print => self.print_stmt(index),
            .Return => self.return_expr(index),
            .String => self.literal("String literal", index),
            .Type => unreachable,
            .Unary => self.unary_expr(index),
            .Use => self.use_stmt(index),
            .VarDecl => self.var_decl(index),
            .While => self.while_stmt(index),
        };
    }

    fn assignment(self: *Self, index: Node.Index) Error!void {
        try self.indent();
        try self.tree.appendSlice("[Assignment\n");
        self.indent_level += 1;
        try self.indent();
        try self.tree.appendSlice("assigne:\n");
        try self.parse_node(self.node_data[index].lhs);
        try self.indent();
        try self.tree.appendSlice("value:\n");
        try self.parse_node(self.node_data[index].rhs);

        self.indent_level -= 1;
        try self.indent();
        try self.tree.appendSlice("]\n");
    }

    fn binop_expr(self: *Self, index: Node.Index) Error!void {
        try self.indent();

        var writer = self.tree.writer();
        try writer.print("[Binop {s}]\n", .{switch (self.node_tags[index]) {
            .Add => "+",
            .Div => "/",
            .Mul => "*",
            .Sub => "-",
            else => unreachable,
        }});

        const data = self.node_data[index];

        self.indent_level += 1;
        try self.parse_node(data.lhs);
        try self.parse_node(data.rhs);
        self.indent_level -= 1;
    }

    fn block_expr(self: *Self, index: Node.Index) Error!void {
        try self.indent();
        try self.tree.appendSlice("[Block]\n");

        self.indent_level += 1;

        for (0..self.node_data[index].lhs) |_| {
            self.node_idx += 1;
            try self.parse_node(self.main_nodes[self.node_idx]);
        }
        // for (expr.stmts) |*s| try self.statement(s);

        self.indent_level -= 1;
    }

    fn discard(self: *Self, index: Node.Index) Error!void {
        try self.indent();
        try self.tree.appendSlice("[Discard\n");
        self.indent_level += 1;
        try self.parse_node(self.node_data[index].lhs);
        self.indent_level -= 1;
        try self.indent();
        try self.tree.appendSlice("]\n");
    }

    fn grouping(self: *Self, index: Node.Index) Error!void {
        try self.indent();
        try self.tree.appendSlice("[Grouping]\n");

        self.indent_level += 1;
        try self.parse_node(self.node_data[index].lhs);
        self.indent_level -= 1;
    }

    fn literal(self: *Self, text: []const u8, index: Node.Index) Error!void {
        try self.indent();
        var writer = self.tree.writer();
        const span = self.token_spans[self.node_roots[index]];
        try writer.print("[{s} {s}]\n", .{ text, self.source[span.start..span.end] });
    }

    fn null_(self: *Self) Error!void {
        try self.indent();
        try self.tree.appendSlice("[Null literal]\n");
    }

    fn print_stmt(self: *Self, index: Node.Index) Error!void {
        try self.indent();
        try self.tree.appendSlice("[Print]\n");
        self.indent_level += 1;
        try self.parse_node(self.node_data[index].lhs);
        self.indent_level -= 1;
    }

    fn return_expr(self: *Self, index: Node.Index) Error!void {
        try self.indent();
        try self.tree.appendSlice("[Return");
        const expr_node = self.node_data[index].lhs;

        if (expr_node != NullNode) {
            try self.tree.appendSlice("\n");
            self.indent_level += 1;
            try self.parse_node(expr_node);
            self.indent_level -= 1;
        }

        try self.tree.appendSlice("]\n");
    }

    fn unary_expr(self: *Self, index: Node.Index) Error!void {
        try self.indent();
        var writer = self.tree.writer();
        const span = self.token_spans[self.node_roots[index]];
        try writer.print("[Unary {s}]\n", .{self.source[span.start..span.end]});

        self.indent_level += 1;
        try self.parse_node(self.node_data[index].lhs);
        self.indent_level -= 1;
    }

    fn var_decl(self: *Self, index: Node.Index) Error!void {
        const node = self.node_data[index];
        try self.indent();
        var writer = self.tree.writer();

        const name_span = self.token_spans[self.node_roots[index]];

        try writer.print(
            "[Var declaration {s}, type {s}, value\n",
            .{
                self.source[name_span.start..name_span.end],
                self.print_type(node.lhs),
            },
        );

        self.indent_level += 1;

        if (node.rhs != NullNode) {
            try self.parse_node(node.rhs);
        } else {
            try self.indent();
            try self.tree.appendSlice("none\n");
        }

        self.indent_level -= 1;
        try self.indent();
        try self.tree.appendSlice("]\n");

        // const type_name = if (stmt.type_) |t| self.print_type(t) else "void";
        // const written = try std.fmt.bufPrint(
        //     &buf,
        //     "[Var declaration {s}, type {s}, value\n",
        //     .{ stmt.name.text, type_name },
        // );
        // try self.tree.appendSlice(written);
        //
        // self.indent_level += 1;
        //
        // if (stmt.value) |v| {
        //     try self.expression(v);
        // } else {
        //     try self.indent();
        //     try self.tree.appendSlice("none\n");
        // }
        //
        // self.indent_level -= 1;
        // try self.indent();
        // try self.tree.appendSlice("]\n");
    }

    fn print_type(self: *Self, index: Node.Index) []const u8 {
        if (index == NullNode) return "void";

        return switch (self.node_tags[index]) {
            .Type => {
                const span = self.token_spans[self.node_roots[index]];
                return self.source[span.start..span.end];
            },
            else => unreachable,
        };
    }

    fn use_stmt(self: *Self, index: Node.Index) !void {
        try self.indent();
        try self.tree.appendSlice("[Use ");
        var writer = self.tree.writer();

        const data = self.node_data[index];

        for (data.lhs..data.rhs) |i| {
            const ident = self.token_spans[self.node_roots[i]];
            try writer.print("{s}", .{self.source[ident.start..ident.end]});

            if (i < data.rhs - 1) {
                try writer.print(" ", .{});
            }
        }
        try writer.print("]\n", .{});
    }

    fn while_stmt(self: *Self, index: Node.Index) Error!void {
        try self.indent();
        try self.tree.appendSlice("[While\n");
        self.indent_level += 1;
        try self.indent();
        try self.tree.appendSlice("condition:\n");
        // try self.expression(stmt.condition);
        try self.parse_node(self.node_data[index].lhs);
        try self.indent();
        try self.tree.appendSlice("body:\n");
        try self.parse_node(self.node_data[index].rhs);
        // try self.statement(stmt.body);

        self.indent_level -= 1;
        try self.indent();
        try self.tree.appendSlice("]\n");
    }

    // fn statement(self: *Self, stmt: *const Ast.Stmt) !void {
    //     try switch (stmt.*) {
    //         .Assignment => |*s| self.assignment(s),
    //         .Discard => |*s| self.discard(s),
    //         .FnDecl => |*s| self.fn_decl(s),
    //         .Print => |*s| self.print_stmt(s),
    //         .Use => |*s| self.use_stmt(s),
    //         .VarDecl => |*s| self.var_decl(s),
    //         .While => |*s| self.while_stmt(s),
    //         .Expr => |s| self.expression(s),
    //     };
    // }

    // fn assignment(self: *Self, stmt: *const Ast.Assignment) !void {
    //     try self.indent();
    //     try self.tree.appendSlice("[Assignment\n");
    //     self.indent_level += 1;
    //     try self.indent();
    //     try self.tree.appendSlice("assigne:\n");
    //     try self.expression(stmt.assigne);
    //     try self.indent();
    //     try self.tree.appendSlice("value:\n");
    //     try self.expression(stmt.value);
    //
    //     self.indent_level -= 1;
    //     try self.indent();
    //     try self.tree.appendSlice("]\n");
    // }

    // fn discard(self: *Self, stmt: *const Ast.Discard) !void {
    //     try self.indent();
    //     try self.tree.appendSlice("[Discard\n");
    //     self.indent_level += 1;
    //     try self.expression(stmt.expr);
    //     self.indent_level -= 1;
    //     try self.indent();
    //     try self.tree.appendSlice("]\n");
    // }

    // fn fn_decl(self: *Self, stmt: *const Ast.FnDecl) !void {
    //     try self.indent();
    //
    //     const return_type = if (stmt.return_type) |rt|
    //         self.print_type(rt)
    //     else
    //         "void";
    //
    //     var buf: [100]u8 = undefined;
    //     var written = try std.fmt.bufPrint(
    //         &buf,
    //         "[Fn declaration {s}, type {s}, arity {}\n",
    //         .{ stmt.name.text, return_type, stmt.arity },
    //     );
    //     try self.tree.appendSlice(written);
    //     self.indent_level += 1;
    //     try self.indent();
    //     try self.tree.appendSlice("params:\n");
    //     self.indent_level += 1;
    //
    //     for (0..stmt.arity) |i| {
    //         try self.indent();
    //         written = try std.fmt.bufPrint(
    //             &buf,
    //             "{s}, type {s}\n",
    //             .{ stmt.params[i].name.text, self.print_type(stmt.params[i].type_) },
    //         );
    //         try self.tree.appendSlice(written);
    //     }
    //     self.indent_level -= 1;
    //
    //     try self.indent();
    //     try self.tree.appendSlice("body:\n");
    //     self.indent_level += 1;
    //     try self.block_expr(&stmt.body);
    //     self.indent_level -= 1;
    //
    //     self.indent_level -= 1;
    //     try self.indent();
    //     try self.tree.appendSlice("]\n");
    // }

    // fn print_stmt(self: *Self, stmt: *const Ast.Print) !void {
    //     try self.indent();
    //     try self.tree.appendSlice("[Print]\n");
    //     self.indent_level += 1;
    //     try self.expression(stmt.expr);
    //     self.indent_level -= 1;
    // }

    // fn use_stmt(self: *Self, stmt: *const Ast.Use) !void {
    //     try self.indent();
    //     var writer = self.tree.writer();
    //     try writer.print("[Use ", .{});
    //
    //     for (stmt.module, 0..) |m, i| {
    //         try writer.print("{s}", .{m.text});
    //
    //         if (i < stmt.module.len - 1) {
    //             try writer.print(" ", .{});
    //         }
    //     }
    //     try writer.print("]\n", .{});
    // }

    // fn var_decl(self: *Self, stmt: *const Ast.VarDecl) !void {
    //     try self.indent();
    //     var buf: [100]u8 = undefined;
    //
    //     const type_name = if (stmt.type_) |t| self.print_type(t) else "void";
    //     const written = try std.fmt.bufPrint(
    //         &buf,
    //         "[Var declaration {s}, type {s}, value\n",
    //         .{ stmt.name.text, type_name },
    //     );
    //     try self.tree.appendSlice(written);
    //
    //     self.indent_level += 1;
    //
    //     if (stmt.value) |v| {
    //         try self.expression(v);
    //     } else {
    //         try self.indent();
    //         try self.tree.appendSlice("none\n");
    //     }
    //
    //     self.indent_level -= 1;
    //     try self.indent();
    //     try self.tree.appendSlice("]\n");
    // }

    // fn while_stmt(self: *Self, stmt: *const Ast.While) Error!void {
    //     try self.indent();
    //     try self.tree.appendSlice("[While\n");
    //     self.indent_level += 1;
    //     try self.indent();
    //     try self.tree.appendSlice("condition:\n");
    //     try self.expression(stmt.condition);
    //     try self.indent();
    //     try self.tree.appendSlice("body:\n");
    //     try self.statement(stmt.body);
    //
    //     self.indent_level -= 1;
    //     try self.indent();
    //     try self.tree.appendSlice("]\n");
    // }

    // fn expression(self: *Self, expr: *const Expr) Error!void {
    //     try switch (expr.*) {
    //         .Block => |*e| self.block_expr(e),
    //         .BinOp => |*e| self.binop_expr(e),
    //         .BoolLit => |*e| self.bool_expr(e),
    //         .FnCall => |*e| self.fn_call(e),
    //         .FloatLit => |*e| self.float_expr(e),
    //         .Grouping => |*e| self.grouping_expr(e),
    //         .Identifier => |*e| self.ident_expr(e),
    //         .If => |*e| self.if_expr(e),
    //         .IntLit => |*e| self.int_expr(e),
    //         .NullLit => self.null_expr(),
    //         .Return => |*e| self.return_expr(e),
    //         .StringLit => |*e| self.string_expr(e),
    //         .Unary => |*e| self.unary_expr(e),
    //     };
    // }

    // fn block_expr(self: *Self, expr: *const Ast.Block) Error!void {
    //     try self.indent();
    //     try self.tree.appendSlice("[Block]\n");
    //
    //     self.indent_level += 1;
    //
    //     for (expr.stmts) |*s| try self.statement(s);
    //
    //     self.indent_level -= 1;
    // }

    // fn float_expr(self: *Self, expr: *const Ast.FloatLit) Error!void {
    //     try self.indent();
    //     var buf: [100]u8 = undefined;
    //     const written = try std.fmt.bufPrint(&buf, "[Float literal {d}]\n", .{expr.value});
    //     try self.tree.appendSlice(written);
    // }

    // fn fn_call(self: *Self, expr: *const Ast.FnCall) Error!void {
    //     try self.indent();
    //     try self.tree.appendSlice("[Fn call\n");
    //     self.indent_level += 1;
    //
    //     try self.indent();
    //     try self.tree.appendSlice("callee:\n");
    //     try self.expression(expr.callee);
    //     try self.indent();
    //     try self.tree.appendSlice("args:\n");
    //
    //     for (0..expr.arity) |i| {
    //         try self.expression(expr.args[i]);
    //     }
    //
    //     self.indent_level -= 1;
    //     try self.indent();
    //     try self.tree.appendSlice("]\n");
    // }

    // fn grouping_expr(self: *Self, expr: *const Ast.Grouping) Error!void {
    //     try self.indent();
    //     try self.tree.appendSlice("[Grouping]\n");
    //
    //     self.indent_level += 1;
    //     try self.expression(expr.expr);
    //     self.indent_level -= 1;
    // }

    // fn ident_expr(self: *Self, expr: *const Ast.Identifier) Error!void {
    //     try self.indent();
    //     var buf: [100]u8 = undefined;
    //     const written = try std.fmt.bufPrint(&buf, "[Identifier {s}]\n", .{expr.name});
    //     try self.tree.appendSlice(written);
    // }

    // fn if_expr(self: *Self, expr: *const Ast.If) Error!void {
    //     try self.indent();
    //
    //     try self.tree.appendSlice("[If\n");
    //     self.indent_level += 1;
    //     try self.indent();
    //     try self.tree.appendSlice("condition:\n");
    //     try self.expression(expr.condition);
    //     try self.indent();
    //     try self.tree.appendSlice("then body:\n");
    //     try self.statement(&expr.then_body);
    //     try self.indent();
    //     try self.tree.appendSlice("else body:\n");
    //     if (expr.else_body) |*body| {
    //         try self.statement(body);
    //     } else {
    //         try self.indent();
    //         try self.tree.appendSlice("none\n");
    //     }
    //
    //     self.indent_level -= 1;
    //     try self.indent();
    //     try self.tree.appendSlice("]\n");
    // }

    // fn int_expr(self: *Self, expr: *const Ast.IntLit) Error!void {
    //     try self.indent();
    //     var buf: [100]u8 = undefined;
    //     const written = try std.fmt.bufPrint(&buf, "[Int literal {}]\n", .{expr.value});
    //     try self.tree.appendSlice(written);
    // }

    // fn null_expr(self: *Self) Error!void {
    //     try self.indent();
    //     try self.tree.appendSlice("[Null literal]\n");
    // }

    // fn return_expr(self: *Self, expr: *const Ast.Return) Error!void {
    //     try self.indent();
    //     try self.tree.appendSlice("[Return");
    //
    //     if (expr.expr) |e| {
    //         self.indent_level += 1;
    //         try self.expression(e);
    //         self.indent_level -= 1;
    //     }
    //
    //     try self.tree.appendSlice("]\n");
    // }

    // fn string_expr(self: *Self, expr: *const Ast.StringLit) Error!void {
    //     try self.indent();
    //     var buf: [100]u8 = undefined;
    //     const written = try std.fmt.bufPrint(&buf, "[String literal {s}]\n", .{expr.value});
    //     try self.tree.appendSlice(written);
    // }

    // fn unary_expr(self: *Self, expr: *const Ast.Unary) Error!void {
    //     try self.indent();
    //
    //     var buf: [100]u8 = undefined;
    //     const written = try std.fmt.bufPrint(&buf, "[Unary {s}]\n", .{expr.op.symbol()});
    //     try self.tree.appendSlice(written);
    //
    //     self.indent_level += 1;
    //     try self.expression(expr.rhs);
    //     self.indent_level -= 1;
    // }
};
