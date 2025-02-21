const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const MultiArrayList = std.MultiArrayList;
const AutoHashMap = std.AutoHashMap;
const Interner = @import("../interner.zig").Interner;
// const Stmt = Ast.Stmt;
// const Expr = Ast.Expr;
// const Span = Ast.Span;
// const AstType = Ast.Type;
// const AnalyzedAst = @import("analyzed_ast.zig");
// const AnalyzedStmt = AnalyzedAst.AnalyzedStmt;
// const Scope = AnalyzedAst.Scope;
// const ReturnKind = AnalyzedAst.ReturnKind;
const Ast = @import("ast.zig");
const Token = @import("lexer.zig").Token;
const Span = @import("lexer.zig").Span;
const Node = @import("ast.zig").Node;
const Rir = @import("rir.zig");
const Scope = Rir.Scope;
const ReturnKind = Rir.ReturnKind;
const Instruction = Rir.Instruction;
const TypeSys = @import("type_system.zig");
const Type = TypeSys.Type;
const TypeInfo = TypeSys.TypeInfo;
// const SourceSlice = @import("../frontend/ast.zig").SourceSlice;
const AnalyzerMsg = @import("analyzer_msg.zig").AnalyzerMsg;
const GenReport = @import("../reporter.zig").GenReport;
const BA = @import("builtins_analyzer.zig");
const BuiltinAnalyzer = BA.BuiltinAnalyzer;
const FnDeclaration = BA.FnDeclaration;
const builtin_init = BA.init;

// Re-export constants
const Void = TypeSys.Void;
const Null = TypeSys.Null;
const Int = TypeSys.Int;
const Float = TypeSys.Float;
const Bool = TypeSys.Bool;
const Str = TypeSys.Str;

pub const TypeManager = struct {
    declared: std.AutoHashMap(usize, Type),
    type_infos: ArrayList(TypeInfo),
    builtins: BuiltinAnalyzer = builtin_init(),

    const Self = @This();
    const Error = error{TooManyTypes} || std.fmt.BufPrintError || Allocator.Error;

    pub fn init(allocator: Allocator) Self {
        return .{
            .declared = AutoHashMap(usize, Type).init(allocator),
            .type_infos = ArrayList(TypeInfo).init(allocator),
        };
    }

    pub fn init_builtins(self: *Self, interner: *Interner) !void {
        try self.declared.put(try interner.intern("void"), Void);
        try self.declared.put(try interner.intern("null"), Null);
        try self.declared.put(try interner.intern("bool"), Bool);
        try self.declared.put(try interner.intern("float"), Float);
        try self.declared.put(try interner.intern("int"), Int);
        try self.declared.put(try interner.intern("str"), Str);
        // try self.declared.put("null", Null);
        // try self.declared.put("bool", Bool);
        // try self.declared.put("float", Float);
        // try self.declared.put("int", Int);
        // try self.declared.put("str", Str);
    }

    pub fn deinit(self: *Self) void {
        self.declared.deinit();
        self.type_infos.deinit();
    }

    /// Adds information about a type. Requires the kind and extra info, the value (aka
    /// index in information array) is computed in the function.
    /// Returns the complete type
    pub fn reserve_info(self: *Self) !TypeSys.Value {
        try self.type_infos.append(undefined);
        const count = self.type_infos.items.len - 1;

        return if (count == std.math.maxInt(TypeSys.Value))
            error.TooManyTypes
        else
            @intCast(count);
    }

    /// Set type information at a specific index in list (index gave by *reserve_info* method)
    pub fn set_info(self: *Self, index: usize, info: TypeInfo) void {
        self.type_infos.items[index] = info;
    }

    /// Declares a new type built with `kind` and `extra` parameters and add the informations
    pub fn declare(
        self: *Self,
        name: usize,
        kind: TypeSys.Kind,
        extra: TypeSys.Extra,
        info: TypeInfo,
    ) !TypeSys.Type {
        const count = self.type_infos.items.len;

        // Error
        if (count == std.math.maxInt(TypeSys.Value)) return error.TooManyTypes;

        const type_ = TypeSys.create(kind, extra, @intCast(count));
        try self.type_infos.append(info);

        try self.declared.put(name, type_);

        return type_;
    }

    /// Use builtins function whose informations are gathered at compile time. Import the
    /// informations among other declared types
    pub fn import_builtins(self: *Self, name: []const u8) !?std.StaticStringMap(FnDeclaration) {
        return self.builtins.declarations.get(name);
    }

    // NOTE:
    // Used only in error mode, no need for performance. If used in
    // performance path, maybe use a ArrayHashMap to retreive with
    // index (as type == index) but every thing else is slow?
    pub fn idx(self: *const Self, type_: Type) usize {
        var iter = self.declared.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.* == type_) {
                return entry.key_ptr.*;
            }
        }
        unreachable;
    }
};

pub const Analyzer = struct {
    source: []const u8,
    token_tags: []const Token.Tag,
    token_spans: []const Span,
    node_tags: []const Node.Tag,
    node_mains: []const Ast.TokenIndex,
    node_data: []const usize,
    node_idx: usize,

    instructions: MultiArrayList(Instruction),
    warns: ArrayList(AnalyzerReport),
    errs: ArrayList(AnalyzerReport),

    globals: ArrayList(Variable),
    locals: ArrayList(Variable),
    scope_depth: usize,
    // main: ?*const Ast.FnDecl,
    /// Offset updated at each fn call, emulate the frame pointer at runtime
    local_offset: usize,
    main: ?Node.Index,
    states: ArrayList(State),
    type_manager: TypeManager,
    interner: Interner,

    arena: std.heap.ArenaAllocator,
    allocator: Allocator,
    repl: bool,

    const Self = @This();
    const Error = error{ Err, Overflow } || TypeManager.Error || Allocator.Error;

    // Representation of a variable. Index is the declaration order
    // NOTE: use depth: isize = -1 as uninit? Saves a bool in struct. On passerait
    // de 48 à 47 bits, mais bon il y a padding
    // Voir si possible de faire autrement que de stocker le nom des vars
    const Variable = struct {
        index: usize = 0,
        type_: Type = Void,
        depth: usize,
        name: usize,
        initialized: bool = false,
    };

    const State = struct {
        /// in a context that allow partially returning a value
        allow_partial: bool = true,
        /// Current function's type
        fn_type: Type = Void,
        /// Flag to tell if last statement returned from scope
        returns: bool = false,
    };

    const AnalyzerReport = GenReport(AnalyzerMsg);

    pub fn init(self: *Self, allocator: Allocator, repl: bool) !void {
        self.arena = std.heap.ArenaAllocator.init(allocator);
        self.allocator = self.arena.allocator();

        self.instructions = MultiArrayList(Instruction){};
        self.warns = ArrayList(AnalyzerReport).init(self.allocator);
        self.errs = ArrayList(AnalyzerReport).init(self.allocator);
        self.globals = ArrayList(Variable).init(self.allocator);
        self.locals = ArrayList(Variable).init(self.allocator);
        self.node_idx = 0;
        self.scope_depth = 0;

        self.states = ArrayList(State).init(self.allocator);
        self.main = null;
        self.local_offset = 0;
        self.type_manager = TypeManager.init(self.allocator);
        self.interner = Interner.init(self.allocator);

        // We reserve slot 0 for 'main'
        _ = try self.interner.intern("main");
        // Slot 1 for std
        _ = try self.interner.intern("std");
        try self.type_manager.init_builtins(&self.interner);
        self.repl = repl;
    }

    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }

    pub fn analyze(
        self: *Self,
        source: []const u8,
        tokens: *const MultiArrayList(Token),
        nodes: *const MultiArrayList(Node),
    ) !void {
        self.source = source;
        self.token_tags = tokens.items(.tag);
        self.token_spans = tokens.items(.span);
        self.node_tags = nodes.items(.tag);
        self.node_mains = nodes.items(.main);
        self.node_data = nodes.items(.data);

        // HACK: to protect an -1 access
        try self.states.append(.{});

        while (self.node_idx < self.node_data.len) {
            const start = self.node_idx;

            const node_type = self.analyze_node(self.node_idx) catch |e| {
                switch (e) {
                    // If it's our own error, we continue
                    error.Err => continue,
                    error.TooManyTypes => return self.err(.TooManyTypes, self.to_span(self.node_idx)),
                    else => return e,
                }
            };

            if (node_type != Void) {
                self.err(.UnusedValue, self.to_span(start)) catch {};
            }
        }

        // for (stmts) |*stmt| {
        //     const stmt_type = self.statement(stmt) catch |e| {
        //         switch (e) {
        //             // If it's our own error, we continue
        //             error.Err => continue,
        //             error.TooManyTypes => return self.err(.TooManyTypes, stmt.span()),
        //             else => return e,
        //         }
        //     };
        //
        //     // If at this stage we have a type, it means that nobody
        //     // consumed it. It might be a standalone expression like:
        //     // 3+4
        //     if (stmt_type != Void) {
        //         self.err(.UnusedValue, stmt.Expr.span()) catch {};
        //     }
        // }

        // In REPL mode, no need for main function
        if (self.repl)
            return
        else if (self.main == null) self.err(.NoMain, .{ .start = 0, .end = 0 }) catch {};
    }

    fn to_span(self: *const Self, node: Node.Index) Span {
        return switch (self.node_tags[node]) {
            .Add, .And, .Div, .Mul, .Or, .Sub, .Eq, .Ge, .Gt, .Le, .Lt, .Ne => .{
                .start = self.token_spans[self.node_mains[node + 1]].start,
                .end = self.to_span(node + 2).end,
            },
            .Assignment => .{
                .start = self.token_spans[self.node_mains[node]].start,
                .end = self.token_spans[self.node_mains[node + 1]].end,
            },
            .Block => .{
                .start = self.token_spans[self.node_mains[node]].start,
                .end = self.token_spans[self.node_mains[node]].start + 1,
            },
            .Bool, .Float, .Identifier, .Int, .Null, .String => self.token_spans[self.node_mains[node]],
            .Discard => .{
                .start = self.token_spans[self.node_mains[node]].start,
                .end = self.token_spans[self.node_mains[node + 1]].end,
            },
            .Empty => unreachable,
            // TODO: real spans, here we underline only the function's name
            .FnDecl => self.token_spans[self.node_mains[node]],
            .FnCall => self.token_spans[self.node_mains[node + 1]],
            .Grouping => .{
                .start = self.token_spans[self.node_mains[node]].start,
                .end = self.token_spans[self.node_data[node]].end,
            },
            .If => self.token_spans[self.node_mains[node]],
            .Parameter => .{
                .start = self.token_spans[self.node_mains[node]].start,
                .end = self.token_spans[self.node_mains[node + 1]].end,
            },
            .Print => .{
                .start = self.token_spans[self.node_mains[node]].start,
                .end = self.to_span(node + 1).end,
            },
            //TODO: real span with return's expression
            .Return => self.token_spans[self.node_mains[node]],
            .Type => .{
                .start = self.token_spans[self.node_mains[node]].start,
                .end = self.token_spans[self.node_mains[node + 1]].end,
            },
            .Unary => .{
                .start = self.token_spans[self.node_mains[node]].start,
                .end = self.token_spans[self.node_mains[node + 1]].end,
            },
            .Use => .{
                .start = self.token_spans[self.node_mains[node]].start,
                .end = self.token_spans[self.node_mains[node + self.node_data[node]]].end,
            },
            .VarDecl => .{
                .start = self.token_spans[self.node_mains[node]].start,
                .end = self.token_spans[self.node_mains[node + self.node_data[node]]].end,
            },
            .While => self.token_spans[self.node_mains[node]],
        };
    }

    fn get_type_name(self: *const Self, type_: Type) []const u8 {
        const idx = self.type_manager.idx(type_);
        return self.interner.get_key(idx).?;
    }

    /// Adds a new instruction and add it's `start` field and returns its index.
    fn add_instr(self: *Self, instr: Instruction, main: usize) !Node.Index {
        try self.instructions.append(self.allocator, .{
            .tag = instr.tag,
            .data = instr.data,
            .start = self.token_spans[self.node_mains[main]].start,
        });
        return self.instructions.len - 1;
    }

    fn is_numeric(t: Type) bool {
        return t == Int or t == Float;
    }

    fn err(self: *Self, kind: AnalyzerMsg, span: Span) Error {
        try self.errs.append(AnalyzerReport.err(kind, span));
        return error.Err;
    }

    fn warn(self: *Self, kind: AnalyzerMsg, span: Span) !void {
        try self.warns.append(AnalyzerReport.warn(kind, span));
    }

    fn source_from_node(self: *const Self, node: Node.Index) []const u8 {
        const span = self.token_spans[self.node_mains[node]];
        return self.source[span.start..span.end];
    }

    fn last_state(self: *Self) *State {
        return &self.states.items[self.states.items.len - 1];
    }

    /// Unincrement scope depth, discards all locals and return the number
    /// of discarded locals
    fn end_scope(self: *Self) !usize {
        self.scope_depth -= 1;

        var pop_count: usize = 0;
        // Discards all the local variables
        if (self.locals.items.len > 0) {
            var i: usize = self.locals.items.len;

            while (i > 0 and self.locals.items[i - 1].depth > self.scope_depth) {
                i -= 1;
            }

            pop_count = self.locals.items.len - i;
            try self.locals.resize(i);
        }

        return pop_count;
    }

    /// Checks if the variable name is in local or global scope
    fn ident_in_scope(self: *const Self, name: usize) bool {
        if (self.scope_depth > 0) {
            if (self.locals.items.len == 0) return false;

            var idx = self.locals.items.len;

            while (idx > 0) : (idx -= 1) {
                const local = self.locals.items[idx - 1];

                if (local.depth < self.scope_depth) break;

                // First condition might fail first avoiding string comparison
                if (name == local.name) return true;
            }
        } else {
            if (self.globals.items.len == 0) return false;

            // TODO: reverse order, user tend to used recently declared variables
            for (self.globals.items) |*glob| {
                if (name == glob.name) return true;
            }
        }

        return false;
    }

    /// Checks if an identifier already exists in current scope and if it's type exists
    /// Returns the type of the variable, void if none provided
    fn check_name_and_type(
        self: *Self,
        name: usize,
        name_idx: Node.Index,
        type_idx: Node.Index,
    ) !Type {
        // Name check
        if (self.ident_in_scope(name)) {
            return self.err(
                .{ .AlreadyDeclared = .{ .name = self.interner.get_key(name).? } },
                self.to_span(name_idx),
            );
        }

        return if (self.node_tags[type_idx] != .Empty)
            self.type_manager.declared.get(
                try self.interner.intern(self.source_from_node(type_idx)),
            ) orelse
                return self.err(
                .{ .UndeclaredType = .{ .found = self.interner.get_key(type_idx).? } },
                self.to_span(type_idx),
            )
        else
            Void;
    }

    /// Checks if an identifier already exists in current scope and if it's type exists
    /// Returns the type of the variable, void if none provided
    // fn check_ident_and_type(self: *Self, ident: SourceSlice, type_: ?AstType) !Type {
    //     // Name check
    //     if (self.ident_in_scope(ident.text)) {
    //         return self.err(
    //             .{ .AlreadyDeclared = .{ .name = ident.text } },
    //             Span.from_source_slice(ident),
    //         );
    //     }
    //
    //     return if (type_) |t| switch (t) {
    //         .Entity => |entity| self.type_manager.declared.get(entity.text) orelse
    //             return self.err(
    //             .{ .UndeclaredType = .{ .found = entity.text } },
    //             Span.from_source_slice(entity),
    //         ),
    //         .Function => Void,
    //     } else Void;
    // }

    /// Declares a variable either in globals or in locals based on current scope depth
    fn declare_variable(self: *Self, name: usize, type_: Type, initialized: bool) !Instruction.Variable {
        var variable: Variable = .{
            .name = name,
            .type_ = type_,
            .depth = self.scope_depth,
            .initialized = initialized,
        };

        // Add the variable to the correct data structure
        if (self.scope_depth == 0) {
            const index = self.globals.items.len;
            variable.index = index;

            try self.globals.append(variable);
            return .{ .index = @intCast(index), .scope = .Global };
        } else {
            // Take function's frame into account
            const index = self.locals.items.len - self.local_offset;
            variable.index = index;

            try self.locals.append(variable);
            return .{ .index = @intCast(index), .scope = .Local };
        }
    }

    /// Declares a variable either in globals or in locals based on current scope depth
    // fn declare_variable(self: *Self, name: []const u8, type_: Type, initialized: bool) !AnalyzedAst.Variable {
    //     var variable: Variable = .{
    //         .name = name,
    //         .type_ = type_,
    //         .depth = self.scope_depth,
    //         .initialized = initialized,
    //     };
    //
    //     // Add the variable to the correct data structure
    //     if (self.scope_depth == 0) {
    //         const index = self.globals.items.len;
    //         variable.index = index;
    //
    //         try self.globals.append(variable);
    //         return .{ .index = index, .scope = .Global };
    //     } else {
    //         const index = self.locals.items.len - self.local_offset;
    //         variable.index = index;
    //
    //         try self.locals.append(variable);
    //         return .{ .index = index, .scope = .Local };
    //     }
    // }

    fn is_pure(self: *const Self, node: Node.Index) bool {
        // TODO: manage those
        // Block: Block,
        // FnCall: FnCall,
        // Identifier: Identifier,
        // If: If,
        return switch (self.node_tags[node]) {
            .Bool, .Float, .Int, .Null, .String => true,
            .Add, .Div, .Mul, .Sub, .And, .Or, .Eq, .Ge, .Gt, .Le, .Lt, .Ne => self.is_pure(node + 1) and self.is_pure(node + 2),
            .Grouping => self.is_pure(node + 1),
            .Unary => self.is_pure(node + 1),
            else => false,
        };
    }

    fn analyze_node(self: *Self, node: Node.Index) Error!Type {
        // if (self.scope_depth == 0 and !self.repl and !self.is_pure(node)) {
        //     return self.err(.UnpureInGlobal, self.to_span(node));
        // }

        var final: Type = Void;

        switch (self.node_tags[node]) {
            .Add, .And, .Div, .Mul, .Or, .Sub, .Eq, .Ge, .Gt, .Le, .Lt, .Ne => final = try self.binop(node),
            .Assignment => try self.assignment(node),
            .Block => final = try self.block(node),
            .Bool => final = try self.bool_lit(node),
            .Discard => try self.discard(node),
            .FnDecl => try self.fn_declaration(node),
            .Empty => self.node_idx += 1,
            .Float => final = try self.float_lit(node),
            .FnCall => final = try self.fn_call(node),
            .Grouping => {
                self.node_idx += 1;
                final = try self.analyze_node(self.node_idx);
            },
            .Identifier => final = (try self.identifier(node, true)).type_,
            .If => final = try self.if_expr(node),
            .Int => final = try self.int_lit(node),
            .Null => final = try self.null_lit(),
            .Print => try self.print(),
            .Return => final = try self.return_expr(node),
            .String => final = try self.string(node),
            .Unary => final = try self.unary(node),
            .Use => try self.use(node),
            .VarDecl => try self.var_decl(node),
            .While => try self.while_stmt(),
            else => unreachable,
        }

        return final;
    }

    fn assignment(self: *Self, _: Node.Index) !void {
        const state = self.last_state();
        const last = state.allow_partial;
        state.allow_partial = false;
        errdefer state.allow_partial = last;

        self.node_idx += 1;
        var cast = false;

        const assigne_idx = self.node_idx;
        const idx = try self.add_instr(.{ .tag = .Assignment, .data = undefined }, assigne_idx);

        switch (self.node_tags[assigne_idx]) {
            .Identifier => {
                const assigne = try self.resolve_identifier(assigne_idx, false);

                const value_idx = self.node_idx;
                const value_type = try self.analyze_node(value_idx);
                // Restore state
                state.allow_partial = last;

                if (value_type == Void) {
                    return self.err(.VoidAssignment, self.to_span(value_idx));
                }

                // If type is unknown, we update it
                if (assigne.type_ == Void) {
                    assigne.type_ = value_type;
                } else if (assigne.type_ != value_type) {
                    // One case in wich we can coerce; int -> float
                    if (assigne.type_ == Float and value_type == Int) {
                        cast = true;
                        _ = try self.add_instr(
                            .{ .tag = .Cast, .data = .{ .CastTo = .Float } },
                            assigne_idx,
                        );
                    } else {
                        return self.err(
                            .{ .InvalidAssignType = .{
                                .expect = self.get_type_name(assigne.type_),
                                .found = self.get_type_name(value_type),
                            } },
                            self.to_span(assigne_idx),
                        );
                    }
                }

                if (!assigne.initialized) assigne.initialized = true;

                self.instructions.items(.data)[idx] = .{ .Assignment = .{
                    .variable = .{
                        .index = @intCast(assigne.index),
                        .scope = if (assigne.depth > 0) .Local else .Global,
                    },
                    .cast = cast,
                } };
            },
            // Later, manage member, pointer, ...
            else => return self.err(.InvalidAssignTarget, self.to_span(self.node_idx)),
        }
    }

    fn binop(self: *Self, node: Node.Index) Error!Type {
        const op = self.node_tags[node];
        const idx = try self.add_instr(.{ .tag = .Binop }, node);

        self.node_idx += 1;
        const lhs_index = self.node_idx;
        const lhs = try self.analyze_node(lhs_index);

        const rhs_index = self.node_idx;
        const rhs = try self.analyze_node(rhs_index);

        var res = lhs;

        // String operations
        if (op == .Add and lhs == Str and rhs == Str) {
            self.instructions.items(.data)[idx] = .{ .Binop = .{ .op = .AddStr } };
            return Str;
        } else if (op == .Mul) {
            if ((lhs == Str and rhs == Int) or (lhs == Int and rhs == Str)) {
                self.instructions.items(.data)[idx] = .{ .Binop = .{
                    .cast = if (rhs == Int) .Rhs else .Lhs,
                    .op = .MulStr,
                } };

                return Str;
            }
        }

        // Error check
        switch (op) {
            .Add, .Div, .Mul, .Sub, .Ge, .Gt, .Le, .Lt => {
                if (!Analyzer.is_numeric(lhs)) {
                    return self.err(
                        AnalyzerMsg.invalid_arithmetic(self.get_type_name(lhs)),
                        self.to_span(lhs_index),
                    );
                }

                if (!Analyzer.is_numeric(rhs)) {
                    return self.err(
                        AnalyzerMsg.invalid_arithmetic(self.get_type_name(rhs)),
                        self.to_span(rhs_index),
                    );
                }
            },
            else => {},
        }

        var data: Instruction.Binop = .{ .op = undefined };

        switch (op) {
            // Arithmetic binop
            .Add, .Div, .Mul, .Sub => {
                switch (op) {
                    .Add => data.op = .AddFloat,
                    .Div => data.op = .DivFloat,
                    .Mul => data.op = .MulFloat,
                    .Sub => data.op = .SubFloat,
                    else => unreachable,
                }

                switch (lhs) {
                    Float => {
                        switch (rhs) {
                            Float => {},
                            Int => {
                                try self.warn(
                                    AnalyzerMsg.implicit_cast("right hand side", self.get_type_name(lhs)),
                                    self.to_span(rhs_index),
                                );

                                data.cast = .Rhs;
                            },
                            else => unreachable,
                        }
                    },
                    Int => {
                        switch (rhs) {
                            Float => {
                                try self.warn(
                                    AnalyzerMsg.implicit_cast("left hand side", self.get_type_name(rhs)),
                                    self.to_span(lhs_index),
                                );

                                data.cast = .Lhs;
                                res = Float;
                            },
                            Int => switch (op) {
                                .Add => data.op = .AddInt,
                                .Div => data.op = .DivInt,
                                .Mul => data.op = .MulInt,
                                .Sub => data.op = .SubInt,
                                else => unreachable,
                            },
                            else => unreachable,
                        }
                    },
                    else => unreachable,
                }
            },
            .Eq, .Ne => {
                // If different value types
                if (lhs != rhs) {
                    // Check for implicit casts
                    if ((lhs == Int and rhs == Float) or (lhs == Float and rhs == Int)) {
                        if (lhs == Int) {
                            data.cast = .Lhs;

                            try self.warn(.FloatEqualCast, self.to_span(lhs_index));
                        } else {
                            data.cast = .Rhs;

                            try self.warn(.FloatEqualCast, self.to_span(rhs_index));
                        }
                    } else {
                        return self.err(
                            AnalyzerMsg.invalid_cmp(
                                self.get_type_name(lhs),
                                self.get_type_name(rhs),
                            ),
                            self.to_span(node),
                        );
                    }
                } else {
                    // Check for unsafe float comparisons or int comparison
                    if (lhs == Float) {
                        try self.warn(.FloatEqual, self.to_span(node));
                    }
                }

                // TODO: Error handling for non int, float and str
                switch (op) {
                    .Eq => data.op = switch (lhs) {
                        Bool => .EqBool,
                        Float => .EqFloat,
                        Int => .EqInt,
                        else => .EqStr,
                    },
                    .Ne => data.op = switch (lhs) {
                        Bool => .NeBool,
                        Float => .NeFloat,
                        Int => .NeInt,
                        else => .NeStr,
                    },
                    else => unreachable,
                }
                res = Bool;
            },
            .Ge, .Gt, .Le, .Lt => {
                switch (op) {
                    .Ge => data.op = .GeFloat,
                    .Gt => data.op = .GtFloat,
                    .Le => data.op = .LeFloat,
                    .Lt => data.op = .LtFloat,
                    else => unreachable,
                }

                switch (lhs) {
                    Float => {
                        switch (rhs) {
                            Float => try self.warn(.FloatEqual, self.to_span(node)),
                            Int => {
                                try self.warn(.FloatEqualCast, self.to_span(rhs_index));

                                data.cast = .Rhs;
                            },
                            else => unreachable,
                        }
                    },
                    Int => {
                        switch (rhs) {
                            Float => {
                                try self.warn(.FloatEqualCast, self.to_span(lhs_index));

                                data.cast = .Lhs;
                            },
                            Int => switch (op) {
                                .Ge => data.op = .GeInt,
                                .Gt => data.op = .GtInt,
                                .Le => data.op = .LeInt,
                                .Lt => data.op = .LtInt,
                                else => unreachable,
                            },
                            else => unreachable,
                        }
                    },
                    else => unreachable,
                }

                res = Bool;
            },
            // Logical binop
            .And, .Or => {
                if (lhs != Bool) return self.err(.{ .InvalidLogical = .{
                    .found = self.get_type_name(lhs),
                } }, self.to_span(lhs_index));

                if (rhs != Bool) return self.err(.{ .InvalidLogical = .{
                    .found = self.get_type_name(rhs),
                } }, self.to_span(rhs_index));

                switch (op) {
                    .And => data.op = .And,
                    .Or => data.op = .Or,
                    else => unreachable,
                }
            },
            else => unreachable,
        }

        self.instructions.items(.data)[idx] = .{ .Binop = data };

        return res;
    }

    fn block(self: *Self, node: Node.Index) Error!Type {
        const length = self.node_data[node];

        self.scope_depth += 1;
        errdefer self.scope_depth -= 1;

        const idx = try self.add_instr(.{ .tag = .Block, .data = undefined }, node);

        var final: Type = Void;
        self.node_idx += 1;

        for (0..length) |i| {
            final = try self.analyze_node(self.node_idx);

            if (final != Void and i != length - 1) {
                return self.err(.UnusedValue, self.to_span(self.node_idx));
            }
        }

        self.instructions.items(.data)[idx] = .{ .Block = .{
            .length = length,
            .pop_count = @intCast(try self.end_scope()),
            .is_expr = if (final != Void) true else false,
        } };

        return final;
    }

    fn bool_lit(self: *Self, node: Node.Index) !Type {
        _ = try self.add_instr(.{ .tag = .Bool, .data = .{
            .Bool = if (self.token_tags[self.node_mains[node]] == .True) true else false,
        } }, node);

        self.node_idx += 1;

        return Bool;
    }

    fn discard(self: *Self, node: Node.Index) !void {
        _ = try self.add_instr(.{ .tag = .Discard, .data = undefined }, node);

        self.node_idx += 1;
        const discarded = try self.analyze_node(self.node_idx);

        if (discarded == Void) return self.err(.VoidDiscard, self.to_span(node));
    }

    fn float_lit(self: *Self, node: Node.Index) !Type {
        const value = std.fmt.parseFloat(f64, self.source_from_node(node)) catch blk: {
            // TODO: error handling, only one possible it's invalid char
            std.debug.print("Error parsing float\n", .{});
            break :blk 0.0;
        };

        _ = try self.add_instr(
            .{ .tag = .Float, .data = .{ .Float = value } },
            node,
        );
        self.node_idx += 1;

        return Float;
    }

    fn fn_call(self: *Self, node: Node.Index) Error!Type {
        const arity = self.node_data[node];
        self.node_idx += 1;

        const idx = try self.add_instr(.{ .tag = .FnCall, .data = .{ .FnCall = .{
            .arity = @intCast(arity),
            .builtin = undefined,
        } } }, node);

        // Resolve the callee
        const type_value = try self.expect_type_kind(self.node_idx, TypeSys.Fn);
        const type_info = self.type_manager.type_infos.items[type_value].Fn;

        if (type_info.arity != arity) {
            return self.err(
                try AnalyzerMsg.wrong_args_count(type_info.arity, arity),
                self.to_span(self.node_idx),
            );
        }

        self.instructions.items(.data)[idx].FnCall.builtin = type_info.builtin;

        for (0..arity) |i| {
            const arg_idx = self.node_idx;
            const arg_type = try self.analyze_node(arg_idx);

            if (arg_type != type_info.params[i]) {
                // If it's an implicit cast between int and float, save the
                // argument indices for compiler. Otherwise, error
                if (type_info.params[i] == Float and arg_type == Int) {
                    _ = try self.add_instr(
                        .{ .tag = .Cast, .data = .{ .CastTo = .Float } },
                        arg_idx,
                    );
                } else return self.err(
                    .{ .TypeMismatch = .{
                        .expect = self.get_type_name(type_info.params[i]),
                        .found = self.get_type_name(arg_type),
                    } },
                    self.to_span(arg_idx),
                );
            }
        }

        return type_info.return_type;
    }

    fn fn_declaration(self: *Self, node: Node.Index) Error!void {
        const name_idx = try self.interner.intern(self.source_from_node(node));

        if (self.main == null and self.scope_depth == 0 and name_idx == 0) {
            self.main = self.instructions.len;
        }

        // Check in current scope
        const arity = self.node_data[node];
        const return_type = try self.check_name_and_type(name_idx, node, node + 1 + arity * 2);
        const fn_idx = try self.add_instr(.{ .tag = .FnDecl, .data = undefined }, node);

        // We add function's name for runtime access
        _ = try self.add_instr(.{ .tag = .FnName, .data = .{ .Id = name_idx } }, node);

        // We declare before body for recursion. We need to correct type to check those recursions
        const type_idx = try self.type_manager.reserve_info();
        const fn_type = TypeSys.create(TypeSys.Fn, 0, type_idx);
        const fn_var = try self.declare_variable(name_idx, fn_type, true);

        _ = try self.add_instr(.{ .tag = .Identifier, .data = .{ .Variable = fn_var } }, node);

        self.scope_depth += 1;
        errdefer self.scope_depth -= 1;

        // Stores the previous offset
        const local_offset_save = self.local_offset;
        self.local_offset = self.locals.items.len;

        // Switch back to locals before function call
        errdefer self.local_offset = local_offset_save;

        // We add a empty variable to anticipate the function it self on the stack
        // it's the returned address for the function
        try self.locals.append(.{ .depth = self.scope_depth, .name = name_idx });

        // Skips function's node
        self.node_idx += 1;
        var params_type: [256]Type = undefined;

        for (0..arity) |i| {
            // Check on parameter
            const param_idx = try self.interner.intern(self.source_from_node(self.node_idx));

            // Skips param's name
            self.node_idx += 1;

            const param_type = self.check_name_and_type(
                param_idx,
                self.node_idx - 1,
                self.node_idx,
            ) catch |e| switch (e) {
                error.Err => {
                    // We replace the error with a more explicit one for parameters
                    if (self.errs.items[self.errs.items.len - 1].report == .AlreadyDeclared) {
                        self.errs.items[self.errs.items.len - 1] = AnalyzerReport.err(
                            .{ .DuplicateParam = .{ .name = self.source_from_node(self.node_idx - 1) } },
                            self.to_span(self.node_idx - 1),
                        );
                    }

                    return e;
                },
                else => return e,
            };

            if (param_type == Void) {
                return self.err(.VoidParam, self.to_span(self.node_idx - 1));
            }

            _ = try self.declare_variable(param_idx, param_type, true);
            params_type[i] = param_type;

            // Skips param's type
            self.node_idx += 1;
        }

        // Set all the informations now that we have every thing
        self.type_manager.set_info(type_idx, .{ .Fn = .{
            .arity = arity,
            .params = params_type,
            .return_type = return_type,
        } });

        // We skip the return type, it has already been analyzed
        self.node_idx += 1;

        // ------
        //  Body
        // ------
        try self.states.append(.{ .fn_type = return_type });
        const prev_state = self.last_state();

        var body_type: Type = Void;
        self.scope_depth += 1;
        errdefer self.scope_depth -= 1;

        const block_idx = self.node_idx;
        const length = self.node_data[block_idx];

        // We don't use block because we don't want to emit extra data from the block
        self.node_idx += 1;

        for (0..length) |i| {
            // If previous statement returned, it's only dead code now
            if (prev_state.returns) {
                try self.warn(.DeadCode, self.to_span(self.node_idx - 1));
            }

            // If last statement, we don't allow partial anymore (for return)
            // Usefull for 'if' for example, in this case we want all the branches
            // to return something
            if (i == length - 1) {
                prev_state.allow_partial = false;
            }

            // We try to analyze the whole body
            body_type = self.analyze_node(self.node_idx) catch |e| switch (e) {
                error.Err => continue,
                else => return e,
            };

            // If last expression produced a value and that it wasn't the last one and it
            // wasn't a return, error
            if (body_type != Void and i != length - 1 and !prev_state.returns) {
                self.err(.UnusedValue, self.to_span(self.node_idx)) catch {};
            }
        }

        if (body_type != return_type) {
            return self.err(
                .{ .IncompatibleFnType = .{
                    .expect = self.get_type_name(return_type),
                    .found = self.get_type_name(body_type),
                } },
                self.to_span(block_idx),
            );
        }

        // Two levels: 1 for function's name + params and another one for body
        _ = try self.end_scope();
        _ = try self.end_scope();

        // Switch back to locals before function call
        self.local_offset = local_offset_save;

        const state = self.states.pop();

        const return_kind: ReturnKind = if (state.returns)
            .Explicit
        else if (body_type == Void)
            .ImplicitVoid
        else
            .ImplicitValue;

        self.instructions.items(.data)[fn_idx] = .{ .FnDecl = .{
            .body_len = length,
            .return_kind = return_kind,
        } };
    }

    fn identifier(self: *Self, node: Node.Index, initialized: bool) Error!*Variable {
        const variable = try self.resolve_identifier(node, initialized);

        _ = try self.add_instr(.{ .tag = .Identifier, .data = .{ .Variable = .{
            .scope = if (variable.depth > 0) .Local else .Global,
            .index = @intCast(variable.index),
        } } }, node);

        return variable;
    }

    fn resolve_identifier(self: *Self, node: Node.Index, initialized: bool) Error!*Variable {
        self.node_idx += 1;
        const name = self.source_from_node(node);
        const name_idx = try self.interner.intern(name);

        // We first check in locals
        if (self.locals.items.len > 0) {
            var idx = self.locals.items.len;

            // while (idx > 0) : (idx -= 1) {
            // NOTE: for now, can't see outside function's frame
            while (idx > self.local_offset) : (idx -= 1) {
                const local = &self.locals.items[idx - 1];

                if (name_idx == local.name) {
                    // Checks the initialization if asked
                    if (initialized and !local.initialized) {
                        return self.err(
                            .{ .UseUninitVar = .{ .name = self.interner.get_key(name_idx).? } },
                            self.to_span(node),
                        );
                    }

                    return local;
                }
            }
        }

        // TODO: in reverse? People tend to use latest declared variables
        for (self.globals.items) |*glob| {
            if (name_idx == glob.name) {
                if (initialized and !glob.initialized) {
                    return self.err(
                        .{ .UseUninitVar = .{ .name = self.interner.get_key(name_idx).? } },
                        self.to_span(node),
                    );
                }

                return glob;
            }
        }

        // Else, it's undeclared
        return self.err(
            .{ .UndeclaredVar = .{ .name = self.interner.get_key(name_idx).? } },
            self.to_span(node),
        );
    }

    fn if_expr(self: *Self, node: Node.Index) Error!Type {
        const idx = try self.add_instr(.{ .tag = .If, .data = undefined }, node);
        self.node_idx += 1;
        var data: Instruction.If = .{ .cast = .None, .has_else = false };

        const cond_type = try self.analyze_node(self.node_idx);

        if (cond_type != Bool) return self.err(
            .{ .NonBoolCond = .{
                .what = "if",
                .found = self.get_type_name(cond_type),
            } },
            self.to_span(node),
        );

        var then_return: bool = false;
        var else_return: bool = false;

        const then_idx = self.node_idx;
        const then_type = try self.analyze_node(self.node_idx);
        var final_type = then_type;

        // State managment
        const state = self.last_state();

        // If we hit a return, we transfert it first to the then branch
        if (state.returns) {
            // Reset return  for else branch
            state.returns = false;
            then_return = true;
            // As we exit scope, we don't return any type
            final_type = Void;
        }

        var else_type: Type = Void;
        const else_idx = self.node_idx;

        if (self.node_tags[else_idx] != .Empty) {
            data.has_else = true;

            else_type = try self.analyze_node(else_idx);

            // If it returns
            if (state.returns) {
                else_return = true;
                // If not then, unmark as globally returning from scope
                if (!then_return) state.returns = false;
            } else if (then_return) {
                // If else only then branch returns, final_type becomes else branch
                final_type = else_type;
            }

            // Type coherence. If branches don't exit scope and branches have
            // diffrent types
            if (!then_return and !else_return and then_type != else_type) {
                if (then_type == Int and else_type == Float) {
                    data.cast = .Then;

                    try self.warn(
                        AnalyzerMsg.implicit_cast("then branch", "float"),
                        self.to_span(then_idx),
                    );
                } else if (then_type == Float and else_type == Int) {
                    data.cast = .Else;

                    // Safe unsafe access, if there is a non void type
                    // there is an else body
                    try self.warn(
                        AnalyzerMsg.implicit_cast("else branch", "float"),
                        self.to_span(else_idx),
                    );
                } else {
                    return self.err(
                        .{ .IncompatibleIfType = .{
                            .found1 = self.get_type_name(then_type),
                            .found2 = self.get_type_name(else_type),
                        } },
                        self.to_span(node),
                    );
                }
            }
        } else if (then_type != Void and !state.allow_partial) {
            return self.err(
                .{ .MissingElseClause = .{ .if_type = self.get_type_name(then_type) } },
                self.to_span(node),
            );
        }

        self.instructions.items(.data)[idx] = .{ .If = data };

        return final_type;
    }

    fn int_lit(self: *Self, node: Node.Index) !Type {
        const value = std.fmt.parseInt(isize, self.source_from_node(node), 10) catch blk: {
            // TODO: error handling, only one possible it's invalid char
            std.debug.print("Error parsing integer\n", .{});
            break :blk 0;
        };

        _ = try self.add_instr(.{ .tag = .Int, .data = .{ .Int = value } }, node);
        self.node_idx += 1;

        return Int;
    }

    fn null_lit(self: *Self) !Type {
        _ = try self.add_instr(.{ .tag = .Null, .data = undefined }, self.node_idx);
        self.node_idx += 1;

        return Null;
    }

    fn print(self: *Self) !void {
        _ = try self.add_instr(.{ .tag = .Print, .data = undefined }, self.node_idx);
        self.node_idx += 1;
        _ = try self.analyze_node(self.node_idx);
    }

    fn return_expr(self: *Self, node: Node.Index) Error!Type {
        self.node_idx += 1;
        var state = self.last_state();

        if (state.fn_type == Void) {
            return self.err(.ReturnOutsideFn, self.to_span(node));
        }

        const idx = try self.add_instr(.{ .tag = .Return, .data = .{ .Return = false } }, node);

        const return_type = if (self.node_tags[self.node_idx] != .Empty) blk: {
            self.instructions.items(.data)[idx].Return = true;
            break :blk try self.analyze_node(self.node_idx);
        } else Void;

        if (state.fn_type != return_type) {
            return self.err(
                .{ .IncompatibleFnType = .{
                    .expect = self.get_type_name(state.fn_type),
                    .found = self.get_type_name(return_type),
                } },
                self.to_span(node),
            );
        }

        state.returns = true;
        return return_type;
    }

    fn string(self: *Self, node: Node.Index) !Type {
        const source = self.source_from_node(node);
        // Removes the quotes
        const value = try self.interner.intern(source[1 .. source.len - 1]);
        _ = try self.add_instr(.{ .tag = .String, .data = .{ .Id = value } }, node);
        self.node_idx += 1;

        return Str;
    }

    fn unary(self: *Self, node: Node.Index) Error!Type {
        const op = self.token_tags[self.node_mains[node]];
        const idx = try self.add_instr(.{
            .tag = .Unary,
            .data = .{ .Unary = .{
                .op = if (op == .Not) .Bang else .Minus,
                .type_ = .Float,
            } },
        }, node);

        self.node_idx += 1;
        const rhs = try self.analyze_node(self.node_idx);

        if (op == .Not and rhs != Bool) {
            return self.err(
                .{ .InvalidUnary = .{ .found = self.get_type_name(rhs) } },
                self.to_span(node),
            );
        } else if (op == .Minus and rhs != Int and rhs != Float) {
            return self.err(
                AnalyzerMsg.invalid_arithmetic(self.get_type_name(rhs)),
                self.to_span(node),
            );
        }

        if (rhs == Int) self.instructions.items(.data)[idx].Unary.type_ = .Int;

        return rhs;
    }

    fn use(self: *Self, node: Node.Index) !void {
        const idx = try self.add_instr(.{ .tag = .Use, .data = undefined }, node);
        self.node_idx += 1;

        var count: usize = 0;
        var idx_unknown: usize = 0;

        const name = try self.interner.intern(self.source_from_node(self.node_idx));

        // For now, "std" is interned at initialization in slot 1
        if (name == 1) {
            self.node_idx += 1;

            // TODO: For now, il allows to keep synchronized the different arrays of
            // nodes/instructions
            _ = try self.add_instr(.{ .tag = .Null, .data = undefined, .start = 0 }, 0);

            // TODO: support real imports
            if (self.node_data[node] > 2) @panic("Use statements can't import more than std + one module");

            // 1 less because we parsed "std"
            for (0..self.node_data[node] - 1) |_| {
                if (try self.type_manager.import_builtins(self.source_from_node(self.node_idx))) |module| {
                    const all_fn_names = module.keys();

                    for (all_fn_names) |fn_name| {
                        const name_idx = try self.interner.intern(fn_name);

                        // TODO: Error handling
                        const func = module.get(fn_name).?;

                        const info: TypeInfo = .{ .Fn = .{
                            .arity = func.arity,
                            .params = func.params,
                            .return_type = func.return_type,
                            .builtin = true,
                        } };

                        // Declare the type and additional informations
                        const type_ = try self.type_manager.declare(name_idx, TypeSys.Fn, TypeSys.Builtin, info);
                        // Declare the variable
                        const variable = try self.declare_variable(name_idx, type_, true);

                        _ = try self.add_instr(.{ .tag = .Imported, .data = .{ .Imported = .{
                            .index = func.index,
                            .variable = variable,
                        } } }, node);

                        count += 1;
                    }

                    self.instructions.items(.data)[idx] = .{ .Use = count };
                    self.node_idx += 1;

                    return;
                } else idx_unknown = 1;
            }
        }

        return self.err(
            .{ .UnknownModule = .{ .name = self.source_from_node(node + idx_unknown) } },
            self.to_span(node + idx_unknown),
        );
    }

    fn var_decl(self: *Self, node: Node.Index) !void {
        // In case we propagate an error, we advance the counter to avoid
        // infinite loop
        // TODO: do as in block?
        self.node_idx += 1;
        const type_idx = self.node_idx;
        self.node_idx += 1;
        const value_idx = self.node_idx;

        const idx = try self.add_instr(.{ .tag = .VarDecl, .data = undefined }, node);

        const name = try self.interner.intern(self.source_from_node(node));
        var checked_type = try self.check_name_and_type(name, node, type_idx);

        var initialized = false;
        var cast = false;

        if (self.node_tags[value_idx] != .Empty) {
            const state = self.last_state();
            const last = state.allow_partial;
            state.allow_partial = false;

            const value_type = try self.analyze_node(value_idx);
            state.allow_partial = last;

            // Void assignment check
            if (value_type == Void) {
                return self.err(.VoidAssignment, self.to_span(value_idx));
            }

            // If no type declared, we infer the value type
            if (checked_type == Void) {
                checked_type = value_type;
                // Else, we check for coherence
            } else if (checked_type != value_type) {
                // One case in wich we can coerce, int -> float
                if (checked_type == Float and value_type == Int) {
                    cast = true;
                    _ = try self.add_instr(.{ .tag = .Cast, .data = .{ .CastTo = .Float } }, type_idx);
                } else {
                    return self.err(
                        .{ .InvalidAssignType = .{
                            .expect = self.get_type_name(checked_type),
                            .found = self.get_type_name(value_type),
                        } },
                        self.to_span(value_idx),
                    );
                }
            }

            initialized = true;
        } else {
            _ = try self.add_instr(.{ .tag = .Null }, node);
            self.node_idx += 1;
        }

        const variable = try self.declare_variable(name, checked_type, initialized);
        self.instructions.items(.data)[idx] = .{ .VarDecl = .{ .variable = variable, .cast = cast } };
    }

    fn while_stmt(self: *Self) Error!void {
        self.node_idx += 1;
        const cond_idx = self.node_idx;
        _ = try self.add_instr(.{ .tag = .While }, cond_idx);
        const cond_type = try self.analyze_node(cond_idx);

        if (cond_type != Bool) return self.err(
            .{ .NonBoolCond = .{
                .what = "while",
                .found = self.get_type_name(cond_type),
            } },
            self.to_span(cond_idx),
        );

        const body_idx = self.node_idx;
        const body_type = try self.analyze_node(body_idx);

        if (body_type != Void) return self.err(
            .{ .NonVoidWhile = .{
                .found = self.get_type_name(body_type),
            } },
            self.to_span(body_idx),
        );
    }

    // fn statement(self: *Self, stmt: *const Stmt) !Type {
    //     var final: Type = Void;
    //
    //     switch (stmt.*) {
    //         .Assignment => |*s| try self.assignment(s),
    //         .Discard => |*s| try self.discard(s),
    //         .FnDecl => |*s| try self.fn_declaration(s),
    //         .Print => |*s| _ = try self.expression(s.expr),
    //         .Use => |*s| try self.use(s),
    //         .VarDecl => |*s| try self.var_decl(s),
    //         .While => |*s| try self.while_stmt(s),
    //         .Expr => |e| final = try self.expression(e),
    //     }
    //
    //     return final;
    // }

    // fn assignment(self: *Self, stmt: *const Ast.Assignment) !void {
    //     const state = self.last_state();
    //     const last = state.allow_partial;
    //     state.allow_partial = false;
    //
    //     const value_type = try self.expression(stmt.value);
    //     state.allow_partial = last;
    //
    //     if (value_type == Void) {
    //         return self.err(.VoidAssignment, stmt.value.span());
    //     }
    //
    //     switch (stmt.assigne.*) {
    //         .Identifier => |*ident| {
    //             // Forward declaration to preserve order
    //             const idx = self.analyzed_stmts.items.len;
    //             try self.analyzed_stmts.append(.{ .Assignment = .{} });
    //
    //             const assigne = try self.identifier(ident, false);
    //
    //             // If type is unknown, we update it
    //             if (assigne.type_ == Void) {
    //                 assigne.type_ = value_type;
    //             } else if (assigne.type_ != value_type) {
    //                 // One case in wich we can coerce; int -> float
    //                 if (assigne.type_ == Float and value_type == Int) {
    //                     self.analyzed_stmts.items[idx].Assignment.cast = .Yes;
    //                 } else {
    //                     return self.err(
    //                         .{ .InvalidAssignType = .{
    //                             .expect = self.type_manager.str(assigne.type_),
    //                             .found = self.type_manager.str(value_type),
    //                         } },
    //                         ident.span,
    //                     );
    //                 }
    //             }
    //
    //             assigne.initialized = true;
    //         },
    //         // Later, manage member, pointer, ...
    //         else => |*expr| return self.err(.InvalidAssignTarget, expr.span()),
    //     }
    // }

    // fn fn_declaration(self: *Self, stmt: *const Ast.FnDecl) Error!void {
    //     // If we find a main function in global scope, we save it to analyze last
    //     // If there is another global scoped main function, it's going to be analyzed
    //     // and when we analyze the first one there will be an error anyway
    //     // NOTE: string comparison is slow, add a field in Ast node?
    //     if (self.main == null and self.scope_depth == 0 and std.mem.eql(u8, stmt.name.text, "main")) {
    //         self.main = stmt;
    //     }
    //
    //     const idx = try self.reserve_slot();
    //
    //     // Check in current scope
    //     const return_type = try self.check_ident_and_type(stmt.name, stmt.return_type);
    //
    //     // We declare before body for recursion. We need to correct type to check those recursions
    //     const type_idx = try self.type_manager.reserve_info();
    //     const fn_type = TypeSys.create(TypeSys.Fn, 0, type_idx);
    //     const fn_extra = try self.declare_variable(stmt.name.text, fn_type, true);
    //
    //     self.scope_depth += 1;
    //     errdefer self.scope_depth -= 1;
    //
    //     // Stores the previous offset
    //     const local_offset_save = self.local_offset;
    //     self.local_offset = self.locals.items.len;
    //
    //     // Switch back to locals before function call
    //     errdefer self.local_offset = local_offset_save;
    //
    //     // We add a empty variable to anticipate the function it self on the stack. Here,
    //     // it's declared in the outter scope to allow create a new function with the same name
    //     // in function's body but in real life the function itself is at the very beginning of
    //     // its stack window because it's the returned address for the function
    //     try self.locals.append(.{ .depth = self.scope_depth });
    //
    //     var params_type: [256]Type = undefined;
    //
    //     for (0..stmt.arity) |i| {
    //         // Check on parameter
    //         const param_type = self.check_ident_and_type(
    //             stmt.params[i].name,
    //             stmt.params[i].type_,
    //         ) catch |e| switch (e) {
    //             error.Err => {
    //                 // We replace the error with a more explicit one for parameters
    //                 if (self.errs.items[self.errs.items.len - 1].report == .AlreadyDeclared) {
    //                     const name = stmt.params[i].name;
    //
    //                     self.errs.items[self.errs.items.len - 1] = AnalyzerReport.err(
    //                         .{ .DuplicateParam = .{ .name = name.text } },
    //                         Span.from_source_slice(name),
    //                     );
    //                 }
    //
    //                 return e;
    //             },
    //             else => return e,
    //         };
    //
    //         if (param_type == Void) {
    //             return self.err(.VoidParam, Span.from_source_slice(stmt.params[i].name));
    //         }
    //
    //         _ = try self.declare_variable(stmt.params[i].name.text, param_type, true);
    //         params_type[i] = param_type;
    //     }
    //
    //     // Set all the informations now that we have every thing
    //     self.type_manager.set_info(type_idx, .{ .Fn = .{
    //         .arity = stmt.arity,
    //         .params = params_type,
    //         .return_type = return_type,
    //     } });
    //
    //     // ------
    //     //  Body
    //     // ------
    //     try self.states.append(.{ .fn_type = return_type });
    //     const prev_state = self.last_state();
    //
    //     var body_type: Type = Void;
    //     self.scope_depth += 1;
    //     errdefer self.scope_depth -= 1;
    //
    //     // We don't use block because we don't want to emit extra data from the block
    //     for (stmt.body.stmts, 0..) |*s, i| {
    //         // If previous statement returned, it's only dead code now
    //         if (prev_state.returns) {
    //             try self.warn(.DeadCode, stmt.body.stmts[i - 1].span());
    //         }
    //
    //         // If last statement, we don't allow partial anymore (for return)
    //         if (i == stmt.body.stmts.len - 1) {
    //             prev_state.allow_partial = false;
    //         }
    //
    //         // We try to analyze the whole body
    //         body_type = self.statement(s) catch |e| switch (e) {
    //             error.Err => continue,
    //             else => return e,
    //         };
    //
    //         // If last expression produced a value and that it wasn't the last one and it
    //         // wasn't a return, error
    //         if (body_type != Void and i != stmt.body.stmts.len - 1 and !prev_state.returns) {
    //             self.err(.UnusedValue, s.span()) catch {};
    //         }
    //     }
    //
    //     // We check before ending scopes otherwise the errdefer triggers when
    //     // we exited the 2 scopes
    //     if (body_type != return_type) {
    //         return self.err(
    //             .{ .IncompatibleFnType = .{
    //                 .expect = self.type_manager.str(return_type),
    //                 .found = self.type_manager.str(body_type),
    //             } },
    //             stmt.body.span,
    //         );
    //     }
    //
    //     // Two levels: 1 for function's name + params and another one for body
    //     _ = try self.end_scope();
    //     _ = try self.end_scope();
    //
    //     // Switch back to locals before function call
    //     self.local_offset = local_offset_save;
    //
    //     const state = self.states.pop();
    //
    //     const return_kind: ReturnKind = if (state.returns)
    //         .Explicit
    //     else if (body_type == Void)
    //         .ImplicitVoid
    //     else
    //         .ImplicitValue;
    //
    //     self.analyzed_stmts.items[idx] = .{
    //         .FnDecl = .{
    //             .variable = fn_extra,
    //             .return_kind = return_kind,
    //         },
    //     };
    // }

    // fn use_stmt(self: *Self, stmt: *const Ast.Use) !void {
    //     var idx_unknown: usize = 0;
    //
    //     // For now, can only import std modules
    //     if (std.mem.eql(u8, stmt.module[0].text, "std")) {
    //         if (try self.type_manager.import_builtins(stmt.module[1].text)) |module| {
    //             const all_fn_names = module.keys();
    //
    //             var all_ptr = try ArrayList(u8).initCapacity(self.allocator, all_fn_names.len);
    //             var all_var = try ArrayList(AnalyzedAst.Variable).initCapacity(self.allocator, all_fn_names.len);
    //
    //             for (all_fn_names) |fn_name| {
    //                 const func = module.get(fn_name).?;
    //
    //                 const info: TypeInfo = .{ .Fn = .{
    //                     .arity = func.arity,
    //                     .params = func.params,
    //                     .return_type = func.return_type,
    //                     .builtin = true,
    //                 } };
    //
    //                 // Declare the type and additional informations
    //                 const type_ = try self.type_manager.declare(fn_name, TypeSys.Fn, TypeSys.Builtin, info);
    //                 // Declare the variable
    //                 const variable = try self.declare_variable(fn_name, type_, true);
    //
    //                 // Save extra information for compiler (index of pointer to wrap in ObjNativeFn)
    //                 all_ptr.appendAssumeCapacity(@intCast(func.index));
    //                 all_var.appendAssumeCapacity(variable);
    //             }
    //
    //             try self.analyzed_stmts.append(.{ .Use = .{
    //                 .indices = all_ptr,
    //                 .variables = all_var,
    //             } });
    //
    //             return;
    //         } else idx_unknown = 1;
    //     }
    //
    //     return self.err(
    //         .{ .UnknownModule = .{ .name = stmt.module[idx_unknown].text } },
    //         Span.from_source_slice(
    //             stmt.module[idx_unknown],
    //         ),
    //     );
    // }

    // fn var_declaration(self: *Self, stmt: *const Ast.VarDecl) !void {
    //     var checked_type = try self.check_ident_and_type(stmt.name, stmt.type_);
    //
    //     var initialized = false;
    //
    //     if (stmt.value) |v| {
    //         const state = self.last_state();
    //         const last = state.allow_partial;
    //         state.allow_partial = false;
    //
    //         const value_type = try self.expression(v);
    //         state.allow_partial = last;
    //
    //         // Void assignment check
    //         if (value_type == Void) {
    //             return self.err(.VoidAssignment, v.span());
    //         }
    //
    //         var assign_extra: AnalyzedAst.Assignment = .{};
    //
    //         // If no type declared, we infer the value type
    //         if (checked_type == Void) {
    //             checked_type = value_type;
    //             // Else, we check for coherence
    //         } else if (checked_type != value_type) {
    //             // One case in wich we can coerce; int -> float
    //             if (checked_type == Float and value_type == Int) {
    //                 assign_extra.cast = .Yes;
    //             } else {
    //                 return self.err(
    //                     .{ .InvalidAssignType = .{
    //                         .expect = self.type_manager.str(checked_type),
    //                         .found = self.type_manager.str(value_type),
    //                     } },
    //                     v.span(),
    //                 );
    //             }
    //         }
    //
    //         initialized = true;
    //         try self.analyzed_stmts.append(.{ .Assignment = assign_extra });
    //     }
    //
    //     const extra = try self.declare_variable(stmt.name.text, checked_type, initialized);
    //     try self.analyzed_stmts.append(.{ .Variable = extra });
    // }

    // fn while_stmt(self: *Self, stmt: *const Ast.While) Error!void {
    //     const cond_type = try self.expression(stmt.condition);
    //
    //     if (cond_type != Bool) return self.err(
    //         .{ .NonBoolCond = .{
    //             .what = "while",
    //             .found = self.type_manager.str(cond_type),
    //         } },
    //         stmt.condition.span(),
    //     );
    //
    //     const body_type = try self.statement(stmt.body);
    //
    //     if (body_type != Void) return self.err(
    //         .{ .NonVoidWhile = .{
    //             .found = self.type_manager.str(body_type),
    //         } },
    //         stmt.body.span(),
    //     );
    // }

    // fn expression(self: *Self, expr: *const Expr) !Type {
    //     if (self.scope_depth == 0 and !self.repl and !is_pure(expr)) {
    //         return self.err(.UnpureInGlobal, expr.span());
    //     }
    //
    //     return switch (expr.*) {
    //         .Block => |*e| self.block(e),
    //         .BoolLit => Bool,
    //         .BinOp => |*e| self.binop(e),
    //         .FloatLit => Float,
    //         .FnCall => |*e| self.fn_call(e),
    //         .Grouping => |*e| self.grouping(e),
    //         .Identifier => |*e| {
    //             const res = try self.identifier(e, true);
    //             return res.type_;
    //         },
    //         .If => |*e| self.if_expr(e),
    //         .IntLit => Int,
    //         .NullLit => Null,
    //         .Return => |*e| self.return_expr(e),
    //         .StringLit => Str,
    //         .Unary => |*e| self.unary(e),
    //     };
    // }

    // fn block(self: *Self, expr: *const Ast.Block) Error!Type {
    //     const idx = try self.reserve_slot();
    //
    //     self.scope_depth += 1;
    //
    //     var final: Type = Void;
    //
    //     for (expr.stmts, 0..) |*s, i| {
    //         final = try self.statement(s);
    //
    //         if (final != Void and i != expr.stmts.len - 1) {
    //             return self.err(.UnusedValue, s.span());
    //         }
    //     }
    //
    //     self.analyzed_stmts.items[idx] = .{ .Block = .{
    //         .pop_count = try self.end_scope(),
    //         .is_expr = if (final != Void) true else false,
    //     } };
    //
    //     return final;
    // }

    /// Checks if an expression if of a certain type kind and returns the associated value or error
    fn expect_type_kind(self: *Self, node: Node.Index, kind: TypeSys.Kind) !TypeSys.Value {
        const expr_type = try self.analyze_node(node);

        return if (TypeSys.is(expr_type, kind))
            TypeSys.get_value(expr_type)
        else
            self.err(
                .{ .TypeMismatch = .{
                    .expect = TypeSys.str_kind(kind),
                    .found = TypeSys.str_kind(TypeSys.get_kind(expr_type)),
                } },
                self.to_span(node),
            );
    }

    // fn expect_type_kind(self: *Self, expr: *const Expr, kind: TypeSys.Kind) !TypeSys.Value {
    //     const expr_type = try self.expression(expr);
    //
    //     return if (TypeSys.is(expr_type, kind))
    //         TypeSys.get_value(expr_type)
    //     else
    //         self.err(
    //             .{ .TypeMismatch = .{
    //                 .expect = TypeSys.str_kind(kind),
    //                 .found = TypeSys.str_kind(TypeSys.get_kind(expr_type)),
    //             } },
    //             expr.span(),
    //         );
    // }

    // fn fn_call(self: *Self, expr: *const Ast.FnCall) Error!Type {
    //     // Resolve the callee
    //     const type_value = try self.expect_type_kind(expr.callee, TypeSys.Fn);
    //     const type_info = self.type_manager.type_infos.items[type_value].Fn;
    //
    //     if (type_info.arity != expr.arity) {
    //         return self.err(
    //             try AnalyzerMsg.wrong_args_count(type_info.arity, expr.arity),
    //             expr.span,
    //         );
    //     }
    //
    //     const idx = try self.reserve_slot();
    //     var casts = try std.BoundedArray(usize, 256).init(0);
    //
    //     for (0..expr.arity) |i| {
    //         const arg_type = try self.expression(expr.args[i]);
    //
    //         if (arg_type != type_info.params[i]) {
    //             // If it's an implicit cast between int and float, save the
    //             // argument indices for compiler. Otherwise, error
    //             if (type_info.params[i] == Float and arg_type == Int) {
    //                 casts.appendAssumeCapacity(i);
    //             } else return self.err(
    //                 .{ .TypeMismatch = .{
    //                     .expect = self.type_manager.str(type_info.params[i]),
    //                     .found = self.type_manager.str(arg_type),
    //                 } },
    //                 expr.args[i].span(),
    //             );
    //         }
    //     }
    //
    //     self.analyzed_stmts.items[idx] = .{ .FnCall = .{ .casts = casts, .builtin = type_info.builtin } };
    //
    //     return type_info.return_type;
    // }

    // fn grouping(self: *Self, expr: *const Ast.Grouping) Error!Type {
    //     return self.expression(expr.expr);
    // }

    // fn identifier(self: *Self, expr: *const Ast.Identifier, initialized: bool) Error!*Variable {
    //     // We first check in locals
    //     if (self.locals.items.len > 0) {
    //         var idx = self.locals.items.len;
    //
    //         // while (idx > 0) : (idx -= 1) {
    //         // NOTE: for now, can't see outside function's frame
    //         while (idx > self.local_offset) : (idx -= 1) {
    //             const local = &self.locals.items[idx - 1];
    //
    //             if (std.mem.eql(u8, local.name, expr.name)) {
    //                 // Checks the initialization if asked
    //                 if (initialized and !local.initialized) {
    //                     return self.err(.{ .UseUninitVar = .{ .name = expr.name } }, expr.span);
    //                 }
    //
    //                 try self.analyzed_stmts.append(.{
    //                     .Variable = .{ .scope = .Local, .index = local.index },
    //                 });
    //
    //                 return local;
    //             }
    //         }
    //     }
    //
    //     // TODO: in reverse? People tend to use latest declared variables
    //     for (self.globals.items) |*glob| {
    //         if (std.mem.eql(u8, glob.name, expr.name)) {
    //             if (initialized and !glob.initialized) {
    //                 return self.err(.{ .UseUninitVar = .{ .name = expr.name } }, expr.span);
    //             }
    //
    //             try self.analyzed_stmts.append(.{
    //                 .Variable = .{ .scope = .Global, .index = glob.index },
    //             });
    //
    //             return glob;
    //         }
    //     }
    //
    //     // Else, it's undeclared
    //     return self.err(
    //         .{ .UndeclaredVar = .{ .name = expr.name } },
    //         expr.span,
    //     );
    // }

    // fn if_expr(self: *Self, expr: *const Ast.If) Error!Type {
    //     // We reserve the slot because of recursion
    //     const idx = try self.reserve_slot();
    //     var extra: AnalyzedAst.If = .{};
    //
    //     const cond_type = try self.expression(expr.condition);
    //     if (cond_type != Bool) return self.err(
    //         .{ .NonBoolCond = .{
    //             .what = "if",
    //             .found = self.type_manager.str(cond_type),
    //         } },
    //         expr.condition.span(),
    //     );
    //
    //     var then_return: bool = false;
    //     var else_return: bool = false;
    //
    //     const then_type = try self.statement(&expr.then_body);
    //     var final_type = then_type;
    //
    //     // State managment
    //     const state = self.last_state();
    //
    //     // If we hit a return, we transfert it first to the then branch
    //     if (state.returns) {
    //         // Reset return  for else branch
    //         state.returns = false;
    //         then_return = true;
    //         // As we exit scope, we don't return any type (checked in return_expr)
    //         final_type = Void;
    //     }
    //
    //     var else_type: Type = Void;
    //     if (expr.else_body) |*body| {
    //         else_type = try self.statement(body);
    //
    //         // If it returns
    //         if (state.returns) {
    //             else_return = true;
    //             // If not then, unmark as globally returning from scope
    //             if (!then_return) state.returns = false;
    //         } else if (then_return) {
    //             // If else only then branch returns, final_type becomes else branch
    //             final_type = else_type;
    //         }
    //
    //         // Type coherence. If branches don't exit scope and branches have
    //         // diffrent types
    //         if (!then_return and !else_return and then_type != else_type) {
    //             if (then_type == Int and else_type == Float) {
    //                 extra.cast = .Then;
    //
    //                 try self.warn(
    //                     AnalyzerMsg.implicit_cast("then branch", "float"),
    //                     expr.then_body.span(),
    //                 );
    //             } else if (then_type == Float and else_type == Int) {
    //                 extra.cast = .Else;
    //
    //                 // Safe unsafe access, if there is a non void type
    //                 // there is an else body
    //                 try self.warn(
    //                     AnalyzerMsg.implicit_cast("else branch", "float"),
    //                     expr.else_body.?.span(),
    //                 );
    //             } else {
    //                 return self.err(
    //                     .{ .IncompatibleIfType = .{
    //                         .found1 = self.type_manager.str(then_type),
    //                         .found2 = self.type_manager.str(else_type),
    //                     } },
    //                     expr.span,
    //                 );
    //             }
    //         }
    //     } else if (then_type != Void and !state.allow_partial) {
    //         return self.err(
    //             .{ .MissingElseClause = .{ .if_type = self.type_manager.str(then_type) } },
    //             expr.span,
    //         );
    //     }
    //
    //     self.analyzed_stmts.items[idx] = .{ .If = extra };
    //
    //     return final_type;
    // }

    // fn return_expr(self: *Self, expr: *const Ast.Return) Error!Type {
    //     const return_type = if (expr.expr) |val| try self.expression(val) else Void;
    //     var state = self.last_state();
    //
    //     if (state.fn_type != return_type) {
    //         return self.err(
    //             .{ .IncompatibleFnType = .{
    //                 .expect = self.type_manager.str(state.fn_type),
    //                 .found = self.type_manager.str(return_type),
    //             } },
    //             expr.span,
    //         );
    //     }
    //
    //     state.returns = true;
    //     return return_type;
    // }
    //
    // fn unary(self: *Self, expr: *const Ast.Unary) Error!Type {
    //     const idx = try self.reserve_slot();
    //     var unary_extra: AnalyzedAst.Unary = .{ .type_ = Null };
    //
    //     const rhs = try self.expression(expr.rhs);
    //
    //     if (expr.op == .Not and rhs != Bool) {
    //         return self.err(
    //             .{ .InvalidUnary = .{ .found = self.type_manager.str(rhs) } },
    //             expr.rhs.span(),
    //         );
    //     } else if (expr.op == .Minus and rhs != Int and rhs != Float) {
    //         return self.err(
    //             AnalyzerMsg.invalid_arithmetic(self.type_manager.str(rhs)),
    //             expr.rhs.span(),
    //         );
    //     }
    //
    //     unary_extra.type_ = rhs;
    //
    //     self.analyzed_stmts.items[idx] = .{ .Unary = unary_extra };
    //     return rhs;
    // }

    // fn binop(self: *Self, expr: *const Ast.BinOp) Error!Type {
    //     // We reserve the slot because of recursion
    //     const idx = try self.reserve_slot();
    //     var binop_extra: AnalyzedAst.BinOp = .{ .type_ = Null };
    //
    //     const lhs = try self.expression(expr.lhs);
    //     const rhs = try self.expression(expr.rhs);
    //
    //     binop_extra.type_ = lhs;
    //     var res = lhs;
    //
    //     // String operations
    //     if (expr.op == .Plus and lhs == Str and rhs == Str) {
    //         self.analyzed_stmts.items[idx] = .{ .Binop = binop_extra };
    //         return Str;
    //     } else if (expr.op == .Star) {
    //         if ((lhs == Str and rhs == Int) or (lhs == Int and rhs == Str)) {
    //             binop_extra.type_ = Str;
    //
    //             // For string concatenation, we use the cast information to tell
    //             // on wich side is the integer (for the compiler)
    //             binop_extra.cast = if (rhs == Int) .Rhs else .Lhs;
    //             self.analyzed_stmts.items[idx] = .{ .Binop = binop_extra };
    //             return Str;
    //         }
    //     }
    //
    //     switch (expr.op) {
    //         // Arithmetic binop
    //         .Plus, .Minus, .Star, .Slash => {
    //             if (!Analyzer.is_numeric(lhs)) {
    //                 return self.err(
    //                     AnalyzerMsg.invalid_arithmetic(self.type_manager.str(lhs)),
    //                     expr.lhs.span(),
    //     );
    // }
    //
    // if (!Analyzer.is_numeric(rhs)) {
    //     return self.err(
    //         AnalyzerMsg.invalid_arithmetic(self.type_manager.str(rhs)),
    //         expr.rhs.span(),
    //     );
    // }
    //
    // switch (lhs) {
    //     Float => {
    //         switch (rhs) {
    //             Float => {},
    //             Int => {
    //                 try self.warn(
    //                     AnalyzerMsg.implicit_cast("right hand side", self.type_manager.str(lhs)),
    //                     expr.rhs.span(),
    //                 );
    //
    //                 binop_extra.cast = .Rhs;
    //             },
    //             else => unreachable,
    //         }
    //     },
    //     Int => {
    //         switch (rhs) {
    //             Float => {
    //                 try self.warn(
    //                     AnalyzerMsg.implicit_cast("left hand side", self.type_manager.str(rhs)),
    //                     expr.lhs.span(),
    //                 );
    //
    //                 binop_extra.type_ = Float;
    //                     binop_extra.cast = .Lhs;
    //                     res = Float;
    //                 },
    //                 Int => {},
    //                 else => unreachable,
    //             }
    //         },
    //         else => unreachable,
    //     }
    // },
    // .EqualEqual, .BangEqual => {
    //     // If different value types
    //     if (lhs != rhs) {
    //         // Check for implicit casts
    //         if ((lhs == Int and rhs == Float) or (lhs == Float and rhs == Int)) {
    //             if (lhs == Int) {
    //                 binop_extra.cast = .Lhs;
    //
    //                 try self.warn(.FloatEqualCast, expr.lhs.span());
    //             } else {
    //                 binop_extra.cast = .Rhs;
    //
    //                 try self.warn(.FloatEqualCast, expr.rhs.span());
    //             }
    //
    //             binop_extra.type_ = Float;
    //         } else {
    //             return self.err(
    //                 AnalyzerMsg.invalid_cmp(
    //                     self.type_manager.str(lhs),
    //                     self.type_manager.str(rhs),
    //                 ),
    //                 expr.span,
    //             );
    //         }
    //     } else {
    //         // Check for unsafe float comparisons
    //         if (lhs == Float) {
    //             try self.warn(.FloatEqual, expr.span);
    //         }
    //     }
    //
    //     res = Bool;
    // },
    //
    // .Greater, .GreaterEqual, .Less, .LessEqual => {
    //     if (!Analyzer.is_numeric(lhs)) {
    //         return self.err(
    //             AnalyzerMsg.invalid_arithmetic(self.type_manager.str(lhs)),
    //             expr.lhs.span(),
    //         );
    //     }
    //
    //     if (!Analyzer.is_numeric(rhs)) {
    //         return self.err(
    //             AnalyzerMsg.invalid_arithmetic(self.type_manager.str(rhs)),
    //             expr.rhs.span(),
    //         );
    //     }
    //
    //     switch (lhs) {
    //         Float => switch (rhs) {
    //             Float => try self.warn(.FloatEqual, expr.span),
    //             Int => {
    //                 try self.warn(.FloatEqualCast, expr.rhs.span());
    //
    //                 binop_extra.cast = .Rhs;
    //             },
    //                     else => unreachable,
    //                 },
    //                 Int => switch (rhs) {
    //                     Float => {
    //                         try self.warn(.FloatEqualCast, expr.lhs.span());
    //
    //                         binop_extra.cast = .Lhs;
    //                         binop_extra.type_ = Float;
    //                     },
    //                     Int => {},
    //                     else => unreachable,
    //                 },
    //                 else => unreachable,
    //             }
    //
    //             res = Bool;
    //         },
    //
    //         // Logical binop
    //         .And, .Or => {
    //             if (lhs != Bool) return self.err(.{ .InvalidLogical = .{
    //                 .found = self.type_manager.str(lhs),
    //             } }, expr.lhs.span());
    //
    //             if (rhs != Bool) return self.err(.{ .InvalidLogical = .{
    //                 .found = self.type_manager.str(rhs),
    //             } }, expr.rhs.span());
    //         },
    //         else => unreachable,
    //     }
    //
    //     self.analyzed_stmts.items[idx] = .{ .Binop = binop_extra };
    //     return res;
    // }
};

// Test
test Analyzer {
    const GenericTester = @import("../tester.zig").GenericTester;
    const get_test_data = @import("test_analyzer.zig").get_test_data;

    const Tester = GenericTester("analyzer", AnalyzerMsg, get_test_data);
    try Tester.run();
}
