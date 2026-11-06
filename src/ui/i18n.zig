//! Idioma da interface: português, inglês ou japonês.
//!
//! Cada texto leva as versões no lugar em que é usado, em vez de um
//! dicionário separado que fica desatualizado:
//!
//!     tr("Entrar", "Sign in", "ログイン")
//!     fmt(&buf, "Respondendo a {s}", "Replying to {s}", "{s}に返信中", .{nome})
//!
//! O japonês, quando não tem tradução no ponto de uso, mostra o inglês
//! (nunca o português): é o idioma intermediário deste projeto.
//!
//! O idioma é global e a thread de rede também lê (avisos, dados da
//! demonstração): por isso fica num valor atômico.
const std = @import("std");
const c = @import("c");

pub const Lang = enum(u8) { pt, en, ja };

var lang: std.atomic.Value(Lang) = .init(.pt);

pub fn set(l: Lang) void {
    lang.store(l, .release);
}

pub fn current() Lang {
    return lang.load(.acquire);
}

pub fn en() bool {
    return lang.load(.acquire) == .en;
}

pub fn ja() bool {
    return lang.load(.acquire) == .ja;
}

/// O japonês tem a sua versão no ponto de uso (senão cai no inglês).
fn pick(pt: []const u8, english: []const u8, japanese: ?[]const u8) []const u8 {
    return switch (lang.load(.acquire)) {
        .en => english,
        .ja => japanese orelse english,
        .pt => pt,
    };
}

pub fn tr(pt: []const u8, english: []const u8) []const u8 {
    return pick(pt, english, null);
}

/// Três idiomas: o japonês mostra o inglês quando não tem tradução.
pub fn tr3(pt: []const u8, english: []const u8, japanese: []const u8) []const u8 {
    return pick(pt, english, japanese);
}

pub fn trZ(pt: [:0]const u8, english: [:0]const u8) [:0]const u8 {
    return if (en() or ja()) english else pt;
}

/// Sem espaço, corta o texto (nunca no meio de um caractere) em vez de sumir.
pub fn fmt(buf: []u8, comptime pt: []const u8, comptime english: []const u8, args: anytype) []const u8 {
    var wr = std.Io.Writer.fixed(buf);
    // Japonês sem versão própria usa o inglês (nunca o português).
    (if (en() or ja()) wr.print(english, args) else wr.print(pt, args)) catch {};
    const out = wr.buffered();
    if (out.len < buf.len) return out;
    // Encheu: tira o último caractere se ele ficou pela metade.
    var k = out.len;
    while (k > 0 and (out[k - 1] & 0xC0) == 0x80) k -= 1;
    if (k > 0 and out[k - 1] >= 0xC0) {
        const want = std.unicode.utf8ByteSequenceLength(out[k - 1]) catch 1;
        if (out.len - (k - 1) < want) return out[0 .. k - 1];
    }
    return out;
}

pub fn fmtZ(buf: []u8, comptime pt: []const u8, comptime english: []const u8, args: anytype) [:0]const u8 {
    return (if (en() or ja()) std.fmt.bufPrintSentinel(buf, english, args, 0) else std.fmt.bufPrintSentinel(buf, pt, args, 0)) catch "";
}

pub fn allocPrint(gpa: std.mem.Allocator, comptime pt: []const u8, comptime english: []const u8, args: anytype) ![]u8 {
    return if (en() or ja()) std.fmt.allocPrint(gpa, english, args) else std.fmt.allocPrint(gpa, pt, args);
}

/// Idioma do sistema: português se a primeira preferência for "pt", japonês
/// se for "ja", inglês em qualquer outro caso.
pub fn system() Lang {
    var count: c_int = 0;
    const list = c.SDL_GetPreferredLocales(&count) orelse return .en;
    defer c.SDL_free(@ptrCast(list));
    if (count > 0) if (list[0]) |loc| {
        if (loc.*.language) |l| {
            const s = std.mem.span(l);
            if (std.mem.startsWith(u8, s, "pt")) return .pt;
            if (std.mem.startsWith(u8, s, "ja")) return .ja;
        }
    };
    return .en;
}

/// `language` das configurações: 0 = seguir o sistema, 1 = português,
/// 2 = inglês, 3 = japonês.
pub fn fromSetting(v: u8) Lang {
    return switch (v) {
        1 => .pt,
        2 => .en,
        3 => .ja,
        else => system(),
    };
}

test "idioma padrão e troca" {
    const old = current();
    defer set(old);
    set(.ja);
    try std.testing.expectEqualStrings("Sign in", tr("Entrar", "Sign in"));
    try std.testing.expectEqualStrings("ログイン", tr3("Entrar", "Sign in", "ログイン"));
    set(.pt);
    try std.testing.expectEqualStrings("Entrar", tr3("Entrar", "Sign in", "ログイン"));
    set(.en);
    try std.testing.expectEqualStrings("Sign in", tr3("Entrar", "Sign in", "ログイン"));
}

// O japonês sem tradução cai no inglês também no fmt (não no português).
test "fallback do japonês no fmt" {
    const old = lang.load(.acquire);
    defer lang.store(old, .release);
    lang.store(.ja, .release);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Message in #geral", fmt(&buf, "Conversar em #{s}", "Message in #{s}", .{"geral"}));
    lang.store(.pt, .release);
    try std.testing.expectEqualStrings("Conversar em #geral", fmt(&buf, "Conversar em #{s}", "Message in #{s}", .{"geral"}));
}
