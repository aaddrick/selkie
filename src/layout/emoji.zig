//! Emoji Shortcode Replacement
//!
//! Replaces GitHub-style emoji shortcodes (e.g., `:smile:`) with their Unicode equivalents.
//! Covers the full GitHub emoji shortcode set (~1,800+ entries) for GitHub Flavored Markdown.
//! Generated from the GitHub Emoji API (https://api.github.com/emojis).

const std = @import("std");

/// Map of shortcode names to UTF-8 emoji strings.
/// Sorted by name for binary search.
const EmojiEntry = struct {
    name: []const u8,
    emoji: []const u8,
};

/// Full GitHub emoji shortcode table, sorted alphabetically for binary search.
/// Contains 1913 entries covering the complete GitHub emoji set.
const emoji_table = [_]EmojiEntry{
    .{ .name = "+1", .emoji = "\xf0\x9f\x91\x8d" }, // 👍
    .{ .name = "-1", .emoji = "\xf0\x9f\x91\x8e" }, // 👎
    .{ .name = "100", .emoji = "\xf0\x9f\x92\xaf" }, // 💯
    .{ .name = "1234", .emoji = "\xf0\x9f\x94\xa2" }, // 🔢
    .{ .name = "1st_place_medal", .emoji = "\xf0\x9f\xa5\x87" }, // 🥇
    .{ .name = "2nd_place_medal", .emoji = "\xf0\x9f\xa5\x88" }, // 🥈
    .{ .name = "3rd_place_medal", .emoji = "\xf0\x9f\xa5\x89" }, // 🥉
    .{ .name = "8ball", .emoji = "\xf0\x9f\x8e\xb1" }, // 🎱
    .{ .name = "a", .emoji = "\xf0\x9f\x85\xb0" }, // 🅰
    .{ .name = "ab", .emoji = "\xf0\x9f\x86\x8e" }, // 🆎
    .{ .name = "abacus", .emoji = "\xf0\x9f\xa7\xae" }, // 🧮
    .{ .name = "abc", .emoji = "\xf0\x9f\x94\xa4" }, // 🔤
    .{ .name = "abcd", .emoji = "\xf0\x9f\x94\xa1" }, // 🔡
    .{ .name = "accept", .emoji = "\xf0\x9f\x89\x91" }, // 🉑
    .{ .name = "accordion", .emoji = "\xf0\x9f\xaa\x97" }, // 🪗
    .{ .name = "adhesive_bandage", .emoji = "\xf0\x9f\xa9\xb9" }, // 🩹
    .{ .name = "adult", .emoji = "\xf0\x9f\xa7\x91" }, // 🧑
    .{ .name = "aerial_tramway", .emoji = "\xf0\x9f\x9a\xa1" }, // 🚡
    .{ .name = "afghanistan", .emoji = "\xf0\x9f\x87\xa6\xf0\x9f\x87\xab" }, // 🇦🇫
    .{ .name = "airplane", .emoji = "\xe2\x9c\x88" }, // ✈
    .{ .name = "aland_islands", .emoji = "\xf0\x9f\x87\xa6\xf0\x9f\x87\xbd" }, // 🇦🇽
    .{ .name = "alarm_clock", .emoji = "\xe2\x8f\xb0" }, // ⏰
    .{ .name = "albania", .emoji = "\xf0\x9f\x87\xa6\xf0\x9f\x87\xb1" }, // 🇦🇱
    .{ .name = "alembic", .emoji = "\xe2\x9a\x97" }, // ⚗
    .{ .name = "algeria", .emoji = "\xf0\x9f\x87\xa9\xf0\x9f\x87\xbf" }, // 🇩🇿
    .{ .name = "alien", .emoji = "\xf0\x9f\x91\xbd" }, // 👽
    .{ .name = "ambulance", .emoji = "\xf0\x9f\x9a\x91" }, // 🚑
    .{ .name = "american_samoa", .emoji = "\xf0\x9f\x87\xa6\xf0\x9f\x87\xb8" }, // 🇦🇸
    .{ .name = "amphora", .emoji = "\xf0\x9f\x8f\xba" }, // 🏺
    .{ .name = "anatomical_heart", .emoji = "\xf0\x9f\xab\x80" }, // 🫀
    .{ .name = "anchor", .emoji = "\xe2\x9a\x93" }, // ⚓
    .{ .name = "andorra", .emoji = "\xf0\x9f\x87\xa6\xf0\x9f\x87\xa9" }, // 🇦🇩
    .{ .name = "angel", .emoji = "\xf0\x9f\x91\xbc" }, // 👼
    .{ .name = "anger", .emoji = "\xf0\x9f\x92\xa2" }, // 💢
    .{ .name = "angola", .emoji = "\xf0\x9f\x87\xa6\xf0\x9f\x87\xb4" }, // 🇦🇴
    .{ .name = "angry", .emoji = "\xf0\x9f\x98\xa0" }, // 😠
    .{ .name = "anguilla", .emoji = "\xf0\x9f\x87\xa6\xf0\x9f\x87\xae" }, // 🇦🇮
    .{ .name = "anguished", .emoji = "\xf0\x9f\x98\xa7" }, // 😧
    .{ .name = "ant", .emoji = "\xf0\x9f\x90\x9c" }, // 🐜
    .{ .name = "antarctica", .emoji = "\xf0\x9f\x87\xa6\xf0\x9f\x87\xb6" }, // 🇦🇶
    .{ .name = "antigua_barbuda", .emoji = "\xf0\x9f\x87\xa6\xf0\x9f\x87\xac" }, // 🇦🇬
    .{ .name = "apple", .emoji = "\xf0\x9f\x8d\x8e" }, // 🍎
    .{ .name = "aquarius", .emoji = "\xe2\x99\x92" }, // ♒
    .{ .name = "argentina", .emoji = "\xf0\x9f\x87\xa6\xf0\x9f\x87\xb7" }, // 🇦🇷
    .{ .name = "aries", .emoji = "\xe2\x99\x88" }, // ♈
    .{ .name = "armenia", .emoji = "\xf0\x9f\x87\xa6\xf0\x9f\x87\xb2" }, // 🇦🇲
    .{ .name = "arrow_backward", .emoji = "\xe2\x97\x80" }, // ◀
    .{ .name = "arrow_double_down", .emoji = "\xe2\x8f\xac" }, // ⏬
    .{ .name = "arrow_double_up", .emoji = "\xe2\x8f\xab" }, // ⏫
    .{ .name = "arrow_down", .emoji = "\xe2\xac\x87" }, // ⬇
    .{ .name = "arrow_down_small", .emoji = "\xf0\x9f\x94\xbd" }, // 🔽
    .{ .name = "arrow_forward", .emoji = "\xe2\x96\xb6" }, // ▶
    .{ .name = "arrow_heading_down", .emoji = "\xe2\xa4\xb5" }, // ⤵
    .{ .name = "arrow_heading_up", .emoji = "\xe2\xa4\xb4" }, // ⤴
    .{ .name = "arrow_left", .emoji = "\xe2\xac\x85" }, // ⬅
    .{ .name = "arrow_lower_left", .emoji = "\xe2\x86\x99" }, // ↙
    .{ .name = "arrow_lower_right", .emoji = "\xe2\x86\x98" }, // ↘
    .{ .name = "arrow_right", .emoji = "\xe2\x9e\xa1" }, // ➡
    .{ .name = "arrow_right_hook", .emoji = "\xe2\x86\xaa" }, // ↪
    .{ .name = "arrow_up", .emoji = "\xe2\xac\x86" }, // ⬆
    .{ .name = "arrow_up_down", .emoji = "\xe2\x86\x95" }, // ↕
    .{ .name = "arrow_up_small", .emoji = "\xf0\x9f\x94\xbc" }, // 🔼
    .{ .name = "arrow_upper_left", .emoji = "\xe2\x86\x96" }, // ↖
    .{ .name = "arrow_upper_right", .emoji = "\xe2\x86\x97" }, // ↗
    .{ .name = "arrows_clockwise", .emoji = "\xf0\x9f\x94\x83" }, // 🔃
    .{ .name = "arrows_counterclockwise", .emoji = "\xf0\x9f\x94\x84" }, // 🔄
    .{ .name = "art", .emoji = "\xf0\x9f\x8e\xa8" }, // 🎨
    .{ .name = "articulated_lorry", .emoji = "\xf0\x9f\x9a\x9b" }, // 🚛
    .{ .name = "artificial_satellite", .emoji = "\xf0\x9f\x9b\xb0" }, // 🛰
    .{ .name = "artist", .emoji = "\xf0\x9f\xa7\x91\xf0\x9f\x8e\xa8" }, // 🧑🎨
    .{ .name = "aruba", .emoji = "\xf0\x9f\x87\xa6\xf0\x9f\x87\xbc" }, // 🇦🇼
    .{ .name = "ascension_island", .emoji = "\xf0\x9f\x87\xa6\xf0\x9f\x87\xa8" }, // 🇦🇨
    .{ .name = "asterisk", .emoji = "\x2a\xe2\x83\xa3" }, // *⃣
    .{ .name = "astonished", .emoji = "\xf0\x9f\x98\xb2" }, // 😲
    .{ .name = "astronaut", .emoji = "\xf0\x9f\xa7\x91\xf0\x9f\x9a\x80" }, // 🧑🚀
    .{ .name = "athletic_shoe", .emoji = "\xf0\x9f\x91\x9f" }, // 👟
    .{ .name = "atm", .emoji = "\xf0\x9f\x8f\xa7" }, // 🏧
    .{ .name = "atom_symbol", .emoji = "\xe2\x9a\x9b" }, // ⚛
    .{ .name = "australia", .emoji = "\xf0\x9f\x87\xa6\xf0\x9f\x87\xba" }, // 🇦🇺
    .{ .name = "austria", .emoji = "\xf0\x9f\x87\xa6\xf0\x9f\x87\xb9" }, // 🇦🇹
    .{ .name = "auto_rickshaw", .emoji = "\xf0\x9f\x9b\xba" }, // 🛺
    .{ .name = "avocado", .emoji = "\xf0\x9f\xa5\x91" }, // 🥑
    .{ .name = "axe", .emoji = "\xf0\x9f\xaa\x93" }, // 🪓
    .{ .name = "azerbaijan", .emoji = "\xf0\x9f\x87\xa6\xf0\x9f\x87\xbf" }, // 🇦🇿
    .{ .name = "b", .emoji = "\xf0\x9f\x85\xb1" }, // 🅱
    .{ .name = "baby", .emoji = "\xf0\x9f\x91\xb6" }, // 👶
    .{ .name = "baby_bottle", .emoji = "\xf0\x9f\x8d\xbc" }, // 🍼
    .{ .name = "baby_chick", .emoji = "\xf0\x9f\x90\xa4" }, // 🐤
    .{ .name = "baby_symbol", .emoji = "\xf0\x9f\x9a\xbc" }, // 🚼
    .{ .name = "back", .emoji = "\xf0\x9f\x94\x99" }, // 🔙
    .{ .name = "bacon", .emoji = "\xf0\x9f\xa5\x93" }, // 🥓
    .{ .name = "badger", .emoji = "\xf0\x9f\xa6\xa1" }, // 🦡
    .{ .name = "badminton", .emoji = "\xf0\x9f\x8f\xb8" }, // 🏸
    .{ .name = "bagel", .emoji = "\xf0\x9f\xa5\xaf" }, // 🥯
    .{ .name = "baggage_claim", .emoji = "\xf0\x9f\x9b\x84" }, // 🛄
    .{ .name = "baguette_bread", .emoji = "\xf0\x9f\xa5\x96" }, // 🥖
    .{ .name = "bahamas", .emoji = "\xf0\x9f\x87\xa7\xf0\x9f\x87\xb8" }, // 🇧🇸
    .{ .name = "bahrain", .emoji = "\xf0\x9f\x87\xa7\xf0\x9f\x87\xad" }, // 🇧🇭
    .{ .name = "balance_scale", .emoji = "\xe2\x9a\x96" }, // ⚖
    .{ .name = "bald_man", .emoji = "\xf0\x9f\x91\xa8\xf0\x9f\xa6\xb2" }, // 👨🦲
    .{ .name = "bald_woman", .emoji = "\xf0\x9f\x91\xa9\xf0\x9f\xa6\xb2" }, // 👩🦲
    .{ .name = "ballet_shoes", .emoji = "\xf0\x9f\xa9\xb0" }, // 🩰
    .{ .name = "balloon", .emoji = "\xf0\x9f\x8e\x88" }, // 🎈
    .{ .name = "ballot_box", .emoji = "\xf0\x9f\x97\xb3" }, // 🗳
    .{ .name = "ballot_box_with_check", .emoji = "\xe2\x98\x91" }, // ☑
    .{ .name = "bamboo", .emoji = "\xf0\x9f\x8e\x8d" }, // 🎍
    .{ .name = "banana", .emoji = "\xf0\x9f\x8d\x8c" }, // 🍌
    .{ .name = "bangbang", .emoji = "\xe2\x80\xbc" }, // ‼
    .{ .name = "bangladesh", .emoji = "\xf0\x9f\x87\xa7\xf0\x9f\x87\xa9" }, // 🇧🇩
    .{ .name = "banjo", .emoji = "\xf0\x9f\xaa\x95" }, // 🪕
    .{ .name = "bank", .emoji = "\xf0\x9f\x8f\xa6" }, // 🏦
    .{ .name = "bar_chart", .emoji = "\xf0\x9f\x93\x8a" }, // 📊
    .{ .name = "barbados", .emoji = "\xf0\x9f\x87\xa7\xf0\x9f\x87\xa7" }, // 🇧🇧
    .{ .name = "barber", .emoji = "\xf0\x9f\x92\x88" }, // 💈
    .{ .name = "baseball", .emoji = "\xe2\x9a\xbe" }, // ⚾
    .{ .name = "basket", .emoji = "\xf0\x9f\xa7\xba" }, // 🧺
    .{ .name = "basketball", .emoji = "\xf0\x9f\x8f\x80" }, // 🏀
    .{ .name = "basketball_man", .emoji = "\xe2\x9b\xb9\xe2\x99\x82" }, // ⛹♂
    .{ .name = "basketball_woman", .emoji = "\xe2\x9b\xb9\xe2\x99\x80" }, // ⛹♀
    .{ .name = "bat", .emoji = "\xf0\x9f\xa6\x87" }, // 🦇
    .{ .name = "bath", .emoji = "\xf0\x9f\x9b\x80" }, // 🛀
    .{ .name = "bathtub", .emoji = "\xf0\x9f\x9b\x81" }, // 🛁
    .{ .name = "battery", .emoji = "\xf0\x9f\x94\x8b" }, // 🔋
    .{ .name = "beach_umbrella", .emoji = "\xf0\x9f\x8f\x96" }, // 🏖
    .{ .name = "beans", .emoji = "\xf0\x9f\xab\x98" }, // 🫘
    .{ .name = "bear", .emoji = "\xf0\x9f\x90\xbb" }, // 🐻
    .{ .name = "bearded_person", .emoji = "\xf0\x9f\xa7\x94" }, // 🧔
    .{ .name = "beaver", .emoji = "\xf0\x9f\xa6\xab" }, // 🦫
    .{ .name = "bed", .emoji = "\xf0\x9f\x9b\x8f" }, // 🛏
    .{ .name = "bee", .emoji = "\xf0\x9f\x90\x9d" }, // 🐝
    .{ .name = "beer", .emoji = "\xf0\x9f\x8d\xba" }, // 🍺
    .{ .name = "beers", .emoji = "\xf0\x9f\x8d\xbb" }, // 🍻
    .{ .name = "beetle", .emoji = "\xf0\x9f\xaa\xb2" }, // 🪲
    .{ .name = "beginner", .emoji = "\xf0\x9f\x94\xb0" }, // 🔰
    .{ .name = "belarus", .emoji = "\xf0\x9f\x87\xa7\xf0\x9f\x87\xbe" }, // 🇧🇾
    .{ .name = "belgium", .emoji = "\xf0\x9f\x87\xa7\xf0\x9f\x87\xaa" }, // 🇧🇪
    .{ .name = "belize", .emoji = "\xf0\x9f\x87\xa7\xf0\x9f\x87\xbf" }, // 🇧🇿
    .{ .name = "bell", .emoji = "\xf0\x9f\x94\x94" }, // 🔔
    .{ .name = "bell_pepper", .emoji = "\xf0\x9f\xab\x91" }, // 🫑
    .{ .name = "bellhop_bell", .emoji = "\xf0\x9f\x9b\x8e" }, // 🛎
    .{ .name = "benin", .emoji = "\xf0\x9f\x87\xa7\xf0\x9f\x87\xaf" }, // 🇧🇯
    .{ .name = "bento", .emoji = "\xf0\x9f\x8d\xb1" }, // 🍱
    .{ .name = "bermuda", .emoji = "\xf0\x9f\x87\xa7\xf0\x9f\x87\xb2" }, // 🇧🇲
    .{ .name = "beverage_box", .emoji = "\xf0\x9f\xa7\x83" }, // 🧃
    .{ .name = "bhutan", .emoji = "\xf0\x9f\x87\xa7\xf0\x9f\x87\xb9" }, // 🇧🇹
    .{ .name = "bicyclist", .emoji = "\xf0\x9f\x9a\xb4" }, // 🚴
    .{ .name = "bike", .emoji = "\xf0\x9f\x9a\xb2" }, // 🚲
    .{ .name = "biking_man", .emoji = "\xf0\x9f\x9a\xb4\xe2\x99\x82" }, // 🚴♂
    .{ .name = "biking_woman", .emoji = "\xf0\x9f\x9a\xb4\xe2\x99\x80" }, // 🚴♀
    .{ .name = "bikini", .emoji = "\xf0\x9f\x91\x99" }, // 👙
    .{ .name = "billed_cap", .emoji = "\xf0\x9f\xa7\xa2" }, // 🧢
    .{ .name = "biohazard", .emoji = "\xe2\x98\xa3" }, // ☣
    .{ .name = "bird", .emoji = "\xf0\x9f\x90\xa6" }, // 🐦
    .{ .name = "birthday", .emoji = "\xf0\x9f\x8e\x82" }, // 🎂
    .{ .name = "bison", .emoji = "\xf0\x9f\xa6\xac" }, // 🦬
    .{ .name = "biting_lip", .emoji = "\xf0\x9f\xab\xa6" }, // 🫦
    .{ .name = "black_bird", .emoji = "\xf0\x9f\x90\xa6\xe2\xac\x9b" }, // 🐦⬛
    .{ .name = "black_cat", .emoji = "\xf0\x9f\x90\x88\xe2\xac\x9b" }, // 🐈⬛
    .{ .name = "black_circle", .emoji = "\xe2\x9a\xab" }, // ⚫
    .{ .name = "black_flag", .emoji = "\xf0\x9f\x8f\xb4" }, // 🏴
    .{ .name = "black_heart", .emoji = "\xf0\x9f\x96\xa4" }, // 🖤
    .{ .name = "black_joker", .emoji = "\xf0\x9f\x83\x8f" }, // 🃏
    .{ .name = "black_large_square", .emoji = "\xe2\xac\x9b" }, // ⬛
    .{ .name = "black_medium_small_square", .emoji = "\xe2\x97\xbe" }, // ◾
    .{ .name = "black_medium_square", .emoji = "\xe2\x97\xbc" }, // ◼
    .{ .name = "black_nib", .emoji = "\xe2\x9c\x92" }, // ✒
    .{ .name = "black_small_square", .emoji = "\xe2\x96\xaa" }, // ▪
    .{ .name = "black_square_button", .emoji = "\xf0\x9f\x94\xb2" }, // 🔲
    .{ .name = "blond_haired_man", .emoji = "\xf0\x9f\x91\xb1\xe2\x99\x82" }, // 👱♂
    .{ .name = "blond_haired_person", .emoji = "\xf0\x9f\x91\xb1" }, // 👱
    .{ .name = "blond_haired_woman", .emoji = "\xf0\x9f\x91\xb1\xe2\x99\x80" }, // 👱♀
    .{ .name = "blonde_woman", .emoji = "\xf0\x9f\x91\xb1\xe2\x99\x80" }, // 👱♀
    .{ .name = "blossom", .emoji = "\xf0\x9f\x8c\xbc" }, // 🌼
    .{ .name = "blowfish", .emoji = "\xf0\x9f\x90\xa1" }, // 🐡
    .{ .name = "blue_book", .emoji = "\xf0\x9f\x93\x98" }, // 📘
    .{ .name = "blue_car", .emoji = "\xf0\x9f\x9a\x99" }, // 🚙
    .{ .name = "blue_heart", .emoji = "\xf0\x9f\x92\x99" }, // 💙
    .{ .name = "blue_square", .emoji = "\xf0\x9f\x9f\xa6" }, // 🟦
    .{ .name = "blueberries", .emoji = "\xf0\x9f\xab\x90" }, // 🫐
    .{ .name = "blush", .emoji = "\xf0\x9f\x98\x8a" }, // 😊
    .{ .name = "boar", .emoji = "\xf0\x9f\x90\x97" }, // 🐗
    .{ .name = "boat", .emoji = "\xe2\x9b\xb5" }, // ⛵
    .{ .name = "bolivia", .emoji = "\xf0\x9f\x87\xa7\xf0\x9f\x87\xb4" }, // 🇧🇴
    .{ .name = "bomb", .emoji = "\xf0\x9f\x92\xa3" }, // 💣
    .{ .name = "bone", .emoji = "\xf0\x9f\xa6\xb4" }, // 🦴
    .{ .name = "book", .emoji = "\xf0\x9f\x93\x96" }, // 📖
    .{ .name = "bookmark", .emoji = "\xf0\x9f\x94\x96" }, // 🔖
    .{ .name = "bookmark_tabs", .emoji = "\xf0\x9f\x93\x91" }, // 📑
    .{ .name = "books", .emoji = "\xf0\x9f\x93\x9a" }, // 📚
    .{ .name = "boom", .emoji = "\xf0\x9f\x92\xa5" }, // 💥
    .{ .name = "boomerang", .emoji = "\xf0\x9f\xaa\x83" }, // 🪃
    .{ .name = "boot", .emoji = "\xf0\x9f\x91\xa2" }, // 👢
    .{ .name = "bosnia_herzegovina", .emoji = "\xf0\x9f\x87\xa7\xf0\x9f\x87\xa6" }, // 🇧🇦
    .{ .name = "botswana", .emoji = "\xf0\x9f\x87\xa7\xf0\x9f\x87\xbc" }, // 🇧🇼
    .{ .name = "bouncing_ball_man", .emoji = "\xe2\x9b\xb9\xe2\x99\x82" }, // ⛹♂
    .{ .name = "bouncing_ball_person", .emoji = "\xe2\x9b\xb9" }, // ⛹
    .{ .name = "bouncing_ball_woman", .emoji = "\xe2\x9b\xb9\xe2\x99\x80" }, // ⛹♀
    .{ .name = "bouquet", .emoji = "\xf0\x9f\x92\x90" }, // 💐
    .{ .name = "bouvet_island", .emoji = "\xf0\x9f\x87\xa7\xf0\x9f\x87\xbb" }, // 🇧🇻
    .{ .name = "bow", .emoji = "\xf0\x9f\x99\x87" }, // 🙇
    .{ .name = "bow_and_arrow", .emoji = "\xf0\x9f\x8f\xb9" }, // 🏹
    .{ .name = "bowing_man", .emoji = "\xf0\x9f\x99\x87\xe2\x99\x82" }, // 🙇♂
    .{ .name = "bowing_woman", .emoji = "\xf0\x9f\x99\x87\xe2\x99\x80" }, // 🙇♀
    .{ .name = "bowl_with_spoon", .emoji = "\xf0\x9f\xa5\xa3" }, // 🥣
    .{ .name = "bowling", .emoji = "\xf0\x9f\x8e\xb3" }, // 🎳
    .{ .name = "boxing_glove", .emoji = "\xf0\x9f\xa5\x8a" }, // 🥊
    .{ .name = "boy", .emoji = "\xf0\x9f\x91\xa6" }, // 👦
    .{ .name = "brain", .emoji = "\xf0\x9f\xa7\xa0" }, // 🧠
    .{ .name = "brazil", .emoji = "\xf0\x9f\x87\xa7\xf0\x9f\x87\xb7" }, // 🇧🇷
    .{ .name = "bread", .emoji = "\xf0\x9f\x8d\x9e" }, // 🍞
    .{ .name = "breast_feeding", .emoji = "\xf0\x9f\xa4\xb1" }, // 🤱
    .{ .name = "bricks", .emoji = "\xf0\x9f\xa7\xb1" }, // 🧱
    .{ .name = "bride_with_veil", .emoji = "\xf0\x9f\x91\xb0\xe2\x99\x80" }, // 👰♀
    .{ .name = "bridge_at_night", .emoji = "\xf0\x9f\x8c\x89" }, // 🌉
    .{ .name = "briefcase", .emoji = "\xf0\x9f\x92\xbc" }, // 💼
    .{ .name = "british_indian_ocean_territory", .emoji = "\xf0\x9f\x87\xae\xf0\x9f\x87\xb4" }, // 🇮🇴
    .{ .name = "british_virgin_islands", .emoji = "\xf0\x9f\x87\xbb\xf0\x9f\x87\xac" }, // 🇻🇬
    .{ .name = "broccoli", .emoji = "\xf0\x9f\xa5\xa6" }, // 🥦
    .{ .name = "broken_heart", .emoji = "\xf0\x9f\x92\x94" }, // 💔
    .{ .name = "broom", .emoji = "\xf0\x9f\xa7\xb9" }, // 🧹
    .{ .name = "brown_circle", .emoji = "\xf0\x9f\x9f\xa4" }, // 🟤
    .{ .name = "brown_heart", .emoji = "\xf0\x9f\xa4\x8e" }, // 🤎
    .{ .name = "brown_square", .emoji = "\xf0\x9f\x9f\xab" }, // 🟫
    .{ .name = "brunei", .emoji = "\xf0\x9f\x87\xa7\xf0\x9f\x87\xb3" }, // 🇧🇳
    .{ .name = "bubble_tea", .emoji = "\xf0\x9f\xa7\x8b" }, // 🧋
    .{ .name = "bubbles", .emoji = "\xf0\x9f\xab\xa7" }, // 🫧
    .{ .name = "bucket", .emoji = "\xf0\x9f\xaa\xa3" }, // 🪣
    .{ .name = "bug", .emoji = "\xf0\x9f\x90\x9b" }, // 🐛
    .{ .name = "building_construction", .emoji = "\xf0\x9f\x8f\x97" }, // 🏗
    .{ .name = "bulb", .emoji = "\xf0\x9f\x92\xa1" }, // 💡
    .{ .name = "bulgaria", .emoji = "\xf0\x9f\x87\xa7\xf0\x9f\x87\xac" }, // 🇧🇬
    .{ .name = "bullettrain_front", .emoji = "\xf0\x9f\x9a\x85" }, // 🚅
    .{ .name = "bullettrain_side", .emoji = "\xf0\x9f\x9a\x84" }, // 🚄
    .{ .name = "burkina_faso", .emoji = "\xf0\x9f\x87\xa7\xf0\x9f\x87\xab" }, // 🇧🇫
    .{ .name = "burrito", .emoji = "\xf0\x9f\x8c\xaf" }, // 🌯
    .{ .name = "burundi", .emoji = "\xf0\x9f\x87\xa7\xf0\x9f\x87\xae" }, // 🇧🇮
    .{ .name = "bus", .emoji = "\xf0\x9f\x9a\x8c" }, // 🚌
    .{ .name = "business_suit_levitating", .emoji = "\xf0\x9f\x95\xb4" }, // 🕴
    .{ .name = "busstop", .emoji = "\xf0\x9f\x9a\x8f" }, // 🚏
    .{ .name = "bust_in_silhouette", .emoji = "\xf0\x9f\x91\xa4" }, // 👤
    .{ .name = "busts_in_silhouette", .emoji = "\xf0\x9f\x91\xa5" }, // 👥
    .{ .name = "butter", .emoji = "\xf0\x9f\xa7\x88" }, // 🧈
    .{ .name = "butterfly", .emoji = "\xf0\x9f\xa6\x8b" }, // 🦋
    .{ .name = "cactus", .emoji = "\xf0\x9f\x8c\xb5" }, // 🌵
    .{ .name = "cake", .emoji = "\xf0\x9f\x8d\xb0" }, // 🍰
    .{ .name = "calendar", .emoji = "\xf0\x9f\x93\x86" }, // 📆
    .{ .name = "call_me_hand", .emoji = "\xf0\x9f\xa4\x99" }, // 🤙
    .{ .name = "calling", .emoji = "\xf0\x9f\x93\xb2" }, // 📲
    .{ .name = "cambodia", .emoji = "\xf0\x9f\x87\xb0\xf0\x9f\x87\xad" }, // 🇰🇭
    .{ .name = "camel", .emoji = "\xf0\x9f\x90\xab" }, // 🐫
    .{ .name = "camera", .emoji = "\xf0\x9f\x93\xb7" }, // 📷
    .{ .name = "camera_flash", .emoji = "\xf0\x9f\x93\xb8" }, // 📸
    .{ .name = "cameroon", .emoji = "\xf0\x9f\x87\xa8\xf0\x9f\x87\xb2" }, // 🇨🇲
    .{ .name = "camping", .emoji = "\xf0\x9f\x8f\x95" }, // 🏕
    .{ .name = "canada", .emoji = "\xf0\x9f\x87\xa8\xf0\x9f\x87\xa6" }, // 🇨🇦
    .{ .name = "canary_islands", .emoji = "\xf0\x9f\x87\xae\xf0\x9f\x87\xa8" }, // 🇮🇨
    .{ .name = "cancer", .emoji = "\xe2\x99\x8b" }, // ♋
    .{ .name = "candle", .emoji = "\xf0\x9f\x95\xaf" }, // 🕯
    .{ .name = "candy", .emoji = "\xf0\x9f\x8d\xac" }, // 🍬
    .{ .name = "canned_food", .emoji = "\xf0\x9f\xa5\xab" }, // 🥫
    .{ .name = "canoe", .emoji = "\xf0\x9f\x9b\xb6" }, // 🛶
    .{ .name = "cape_verde", .emoji = "\xf0\x9f\x87\xa8\xf0\x9f\x87\xbb" }, // 🇨🇻
    .{ .name = "capital_abcd", .emoji = "\xf0\x9f\x94\xa0" }, // 🔠
    .{ .name = "capricorn", .emoji = "\xe2\x99\x91" }, // ♑
    .{ .name = "car", .emoji = "\xf0\x9f\x9a\x97" }, // 🚗
    .{ .name = "card_file_box", .emoji = "\xf0\x9f\x97\x83" }, // 🗃
    .{ .name = "card_index", .emoji = "\xf0\x9f\x93\x87" }, // 📇
    .{ .name = "card_index_dividers", .emoji = "\xf0\x9f\x97\x82" }, // 🗂
    .{ .name = "caribbean_netherlands", .emoji = "\xf0\x9f\x87\xa7\xf0\x9f\x87\xb6" }, // 🇧🇶
    .{ .name = "carousel_horse", .emoji = "\xf0\x9f\x8e\xa0" }, // 🎠
    .{ .name = "carpentry_saw", .emoji = "\xf0\x9f\xaa\x9a" }, // 🪚
    .{ .name = "carrot", .emoji = "\xf0\x9f\xa5\x95" }, // 🥕
    .{ .name = "cartwheeling", .emoji = "\xf0\x9f\xa4\xb8" }, // 🤸
    .{ .name = "cat", .emoji = "\xf0\x9f\x90\xb1" }, // 🐱
    .{ .name = "cat2", .emoji = "\xf0\x9f\x90\x88" }, // 🐈
    .{ .name = "cayman_islands", .emoji = "\xf0\x9f\x87\xb0\xf0\x9f\x87\xbe" }, // 🇰🇾
    .{ .name = "cd", .emoji = "\xf0\x9f\x92\xbf" }, // 💿
    .{ .name = "central_african_republic", .emoji = "\xf0\x9f\x87\xa8\xf0\x9f\x87\xab" }, // 🇨🇫
    .{ .name = "ceuta_melilla", .emoji = "\xf0\x9f\x87\xaa\xf0\x9f\x87\xa6" }, // 🇪🇦
    .{ .name = "chad", .emoji = "\xf0\x9f\x87\xb9\xf0\x9f\x87\xa9" }, // 🇹🇩
    .{ .name = "chains", .emoji = "\xe2\x9b\x93" }, // ⛓
    .{ .name = "chair", .emoji = "\xf0\x9f\xaa\x91" }, // 🪑
    .{ .name = "champagne", .emoji = "\xf0\x9f\x8d\xbe" }, // 🍾
    .{ .name = "chart", .emoji = "\xf0\x9f\x92\xb9" }, // 💹
    .{ .name = "chart_with_downwards_trend", .emoji = "\xf0\x9f\x93\x89" }, // 📉
    .{ .name = "chart_with_upwards_trend", .emoji = "\xf0\x9f\x93\x88" }, // 📈
    .{ .name = "checkered_flag", .emoji = "\xf0\x9f\x8f\x81" }, // 🏁
    .{ .name = "cheese", .emoji = "\xf0\x9f\xa7\x80" }, // 🧀
    .{ .name = "cherries", .emoji = "\xf0\x9f\x8d\x92" }, // 🍒
    .{ .name = "cherry_blossom", .emoji = "\xf0\x9f\x8c\xb8" }, // 🌸
    .{ .name = "chess_pawn", .emoji = "\xe2\x99\x9f" }, // ♟
    .{ .name = "chestnut", .emoji = "\xf0\x9f\x8c\xb0" }, // 🌰
    .{ .name = "chicken", .emoji = "\xf0\x9f\x90\x94" }, // 🐔
    .{ .name = "child", .emoji = "\xf0\x9f\xa7\x92" }, // 🧒
    .{ .name = "children_crossing", .emoji = "\xf0\x9f\x9a\xb8" }, // 🚸
    .{ .name = "chile", .emoji = "\xf0\x9f\x87\xa8\xf0\x9f\x87\xb1" }, // 🇨🇱
    .{ .name = "chipmunk", .emoji = "\xf0\x9f\x90\xbf" }, // 🐿
    .{ .name = "chocolate_bar", .emoji = "\xf0\x9f\x8d\xab" }, // 🍫
    .{ .name = "chopsticks", .emoji = "\xf0\x9f\xa5\xa2" }, // 🥢
    .{ .name = "christmas_island", .emoji = "\xf0\x9f\x87\xa8\xf0\x9f\x87\xbd" }, // 🇨🇽
    .{ .name = "christmas_tree", .emoji = "\xf0\x9f\x8e\x84" }, // 🎄
    .{ .name = "church", .emoji = "\xe2\x9b\xaa" }, // ⛪
    .{ .name = "cinema", .emoji = "\xf0\x9f\x8e\xa6" }, // 🎦
    .{ .name = "circus_tent", .emoji = "\xf0\x9f\x8e\xaa" }, // 🎪
    .{ .name = "city_sunrise", .emoji = "\xf0\x9f\x8c\x87" }, // 🌇
    .{ .name = "city_sunset", .emoji = "\xf0\x9f\x8c\x86" }, // 🌆
    .{ .name = "cityscape", .emoji = "\xf0\x9f\x8f\x99" }, // 🏙
    .{ .name = "cl", .emoji = "\xf0\x9f\x86\x91" }, // 🆑
    .{ .name = "clamp", .emoji = "\xf0\x9f\x97\x9c" }, // 🗜
    .{ .name = "clap", .emoji = "\xf0\x9f\x91\x8f" }, // 👏
    .{ .name = "clapper", .emoji = "\xf0\x9f\x8e\xac" }, // 🎬
    .{ .name = "classical_building", .emoji = "\xf0\x9f\x8f\x9b" }, // 🏛
    .{ .name = "climbing", .emoji = "\xf0\x9f\xa7\x97" }, // 🧗
    .{ .name = "climbing_man", .emoji = "\xf0\x9f\xa7\x97\xe2\x99\x82" }, // 🧗♂
    .{ .name = "climbing_woman", .emoji = "\xf0\x9f\xa7\x97\xe2\x99\x80" }, // 🧗♀
    .{ .name = "clinking_glasses", .emoji = "\xf0\x9f\xa5\x82" }, // 🥂
    .{ .name = "clipboard", .emoji = "\xf0\x9f\x93\x8b" }, // 📋
    .{ .name = "clipperton_island", .emoji = "\xf0\x9f\x87\xa8\xf0\x9f\x87\xb5" }, // 🇨🇵
    .{ .name = "clock1", .emoji = "\xf0\x9f\x95\x90" }, // 🕐
    .{ .name = "clock10", .emoji = "\xf0\x9f\x95\x99" }, // 🕙
    .{ .name = "clock1030", .emoji = "\xf0\x9f\x95\xa5" }, // 🕥
    .{ .name = "clock11", .emoji = "\xf0\x9f\x95\x9a" }, // 🕚
    .{ .name = "clock1130", .emoji = "\xf0\x9f\x95\xa6" }, // 🕦
    .{ .name = "clock12", .emoji = "\xf0\x9f\x95\x9b" }, // 🕛
    .{ .name = "clock1230", .emoji = "\xf0\x9f\x95\xa7" }, // 🕧
    .{ .name = "clock130", .emoji = "\xf0\x9f\x95\x9c" }, // 🕜
    .{ .name = "clock2", .emoji = "\xf0\x9f\x95\x91" }, // 🕑
    .{ .name = "clock230", .emoji = "\xf0\x9f\x95\x9d" }, // 🕝
    .{ .name = "clock3", .emoji = "\xf0\x9f\x95\x92" }, // 🕒
    .{ .name = "clock330", .emoji = "\xf0\x9f\x95\x9e" }, // 🕞
    .{ .name = "clock4", .emoji = "\xf0\x9f\x95\x93" }, // 🕓
    .{ .name = "clock430", .emoji = "\xf0\x9f\x95\x9f" }, // 🕟
    .{ .name = "clock5", .emoji = "\xf0\x9f\x95\x94" }, // 🕔
    .{ .name = "clock530", .emoji = "\xf0\x9f\x95\xa0" }, // 🕠
    .{ .name = "clock6", .emoji = "\xf0\x9f\x95\x95" }, // 🕕
    .{ .name = "clock630", .emoji = "\xf0\x9f\x95\xa1" }, // 🕡
    .{ .name = "clock7", .emoji = "\xf0\x9f\x95\x96" }, // 🕖
    .{ .name = "clock730", .emoji = "\xf0\x9f\x95\xa2" }, // 🕢
    .{ .name = "clock8", .emoji = "\xf0\x9f\x95\x97" }, // 🕗
    .{ .name = "clock830", .emoji = "\xf0\x9f\x95\xa3" }, // 🕣
    .{ .name = "clock9", .emoji = "\xf0\x9f\x95\x98" }, // 🕘
    .{ .name = "clock930", .emoji = "\xf0\x9f\x95\xa4" }, // 🕤
    .{ .name = "closed_book", .emoji = "\xf0\x9f\x93\x95" }, // 📕
    .{ .name = "closed_lock_with_key", .emoji = "\xf0\x9f\x94\x90" }, // 🔐
    .{ .name = "closed_umbrella", .emoji = "\xf0\x9f\x8c\x82" }, // 🌂
    .{ .name = "cloud", .emoji = "\xe2\x98\x81" }, // ☁
    .{ .name = "cloud_with_lightning", .emoji = "\xf0\x9f\x8c\xa9" }, // 🌩
    .{ .name = "cloud_with_lightning_and_rain", .emoji = "\xe2\x9b\x88" }, // ⛈
    .{ .name = "cloud_with_rain", .emoji = "\xf0\x9f\x8c\xa7" }, // 🌧
    .{ .name = "cloud_with_snow", .emoji = "\xf0\x9f\x8c\xa8" }, // 🌨
    .{ .name = "clown_face", .emoji = "\xf0\x9f\xa4\xa1" }, // 🤡
    .{ .name = "clubs", .emoji = "\xe2\x99\xa3" }, // ♣
    .{ .name = "cn", .emoji = "\xf0\x9f\x87\xa8\xf0\x9f\x87\xb3" }, // 🇨🇳
    .{ .name = "coat", .emoji = "\xf0\x9f\xa7\xa5" }, // 🧥
    .{ .name = "cockroach", .emoji = "\xf0\x9f\xaa\xb3" }, // 🪳
    .{ .name = "cocktail", .emoji = "\xf0\x9f\x8d\xb8" }, // 🍸
    .{ .name = "coconut", .emoji = "\xf0\x9f\xa5\xa5" }, // 🥥
    .{ .name = "cocos_islands", .emoji = "\xf0\x9f\x87\xa8\xf0\x9f\x87\xa8" }, // 🇨🇨
    .{ .name = "coffee", .emoji = "\xe2\x98\x95" }, // ☕
    .{ .name = "coffin", .emoji = "\xe2\x9a\xb0" }, // ⚰
    .{ .name = "coin", .emoji = "\xf0\x9f\xaa\x99" }, // 🪙
    .{ .name = "cold_face", .emoji = "\xf0\x9f\xa5\xb6" }, // 🥶
    .{ .name = "cold_sweat", .emoji = "\xf0\x9f\x98\xb0" }, // 😰
    .{ .name = "collision", .emoji = "\xf0\x9f\x92\xa5" }, // 💥
    .{ .name = "colombia", .emoji = "\xf0\x9f\x87\xa8\xf0\x9f\x87\xb4" }, // 🇨🇴
    .{ .name = "comet", .emoji = "\xe2\x98\x84" }, // ☄
    .{ .name = "comoros", .emoji = "\xf0\x9f\x87\xb0\xf0\x9f\x87\xb2" }, // 🇰🇲
    .{ .name = "compass", .emoji = "\xf0\x9f\xa7\xad" }, // 🧭
    .{ .name = "computer", .emoji = "\xf0\x9f\x92\xbb" }, // 💻
    .{ .name = "computer_mouse", .emoji = "\xf0\x9f\x96\xb1" }, // 🖱
    .{ .name = "confetti_ball", .emoji = "\xf0\x9f\x8e\x8a" }, // 🎊
    .{ .name = "confounded", .emoji = "\xf0\x9f\x98\x96" }, // 😖
    .{ .name = "confused", .emoji = "\xf0\x9f\x98\x95" }, // 😕
    .{ .name = "congo_brazzaville", .emoji = "\xf0\x9f\x87\xa8\xf0\x9f\x87\xac" }, // 🇨🇬
    .{ .name = "congo_kinshasa", .emoji = "\xf0\x9f\x87\xa8\xf0\x9f\x87\xa9" }, // 🇨🇩
    .{ .name = "congratulations", .emoji = "\xe3\x8a\x97" }, // ㊗
    .{ .name = "construction", .emoji = "\xf0\x9f\x9a\xa7" }, // 🚧
    .{ .name = "construction_worker", .emoji = "\xf0\x9f\x91\xb7" }, // 👷
    .{ .name = "construction_worker_man", .emoji = "\xf0\x9f\x91\xb7\xe2\x99\x82" }, // 👷♂
    .{ .name = "construction_worker_woman", .emoji = "\xf0\x9f\x91\xb7\xe2\x99\x80" }, // 👷♀
    .{ .name = "control_knobs", .emoji = "\xf0\x9f\x8e\x9b" }, // 🎛
    .{ .name = "convenience_store", .emoji = "\xf0\x9f\x8f\xaa" }, // 🏪
    .{ .name = "cook", .emoji = "\xf0\x9f\xa7\x91\xf0\x9f\x8d\xb3" }, // 🧑🍳
    .{ .name = "cook_islands", .emoji = "\xf0\x9f\x87\xa8\xf0\x9f\x87\xb0" }, // 🇨🇰
    .{ .name = "cookie", .emoji = "\xf0\x9f\x8d\xaa" }, // 🍪
    .{ .name = "cool", .emoji = "\xf0\x9f\x86\x92" }, // 🆒
    .{ .name = "cop", .emoji = "\xf0\x9f\x91\xae" }, // 👮
    .{ .name = "copyright", .emoji = "\xc2\xa9" }, // ©
    .{ .name = "coral", .emoji = "\xf0\x9f\xaa\xb8" }, // 🪸
    .{ .name = "corn", .emoji = "\xf0\x9f\x8c\xbd" }, // 🌽
    .{ .name = "costa_rica", .emoji = "\xf0\x9f\x87\xa8\xf0\x9f\x87\xb7" }, // 🇨🇷
    .{ .name = "cote_divoire", .emoji = "\xf0\x9f\x87\xa8\xf0\x9f\x87\xae" }, // 🇨🇮
    .{ .name = "couch_and_lamp", .emoji = "\xf0\x9f\x9b\x8b" }, // 🛋
    .{ .name = "couple", .emoji = "\xf0\x9f\x91\xab" }, // 👫
    .{ .name = "couple_with_heart", .emoji = "\xf0\x9f\x92\x91" }, // 💑
    .{ .name = "couple_with_heart_man_man", .emoji = "\xf0\x9f\x91\xa8\xe2\x9d\xa4\xf0\x9f\x91\xa8" }, // 👨❤👨
    .{ .name = "couple_with_heart_woman_man", .emoji = "\xf0\x9f\x91\xa9\xe2\x9d\xa4\xf0\x9f\x91\xa8" }, // 👩❤👨
    .{ .name = "couple_with_heart_woman_woman", .emoji = "\xf0\x9f\x91\xa9\xe2\x9d\xa4\xf0\x9f\x91\xa9" }, // 👩❤👩
    .{ .name = "couplekiss", .emoji = "\xf0\x9f\x92\x8f" }, // 💏
    .{ .name = "couplekiss_man_man", .emoji = "\xf0\x9f\x91\xa8\xe2\x9d\xa4\xf0\x9f\x92\x8b\xf0\x9f\x91\xa8" }, // 👨❤💋👨
    .{ .name = "couplekiss_man_woman", .emoji = "\xf0\x9f\x91\xa9\xe2\x9d\xa4\xf0\x9f\x92\x8b\xf0\x9f\x91\xa8" }, // 👩❤💋👨
    .{ .name = "couplekiss_woman_woman", .emoji = "\xf0\x9f\x91\xa9\xe2\x9d\xa4\xf0\x9f\x92\x8b\xf0\x9f\x91\xa9" }, // 👩❤💋👩
    .{ .name = "cow", .emoji = "\xf0\x9f\x90\xae" }, // 🐮
    .{ .name = "cow2", .emoji = "\xf0\x9f\x90\x84" }, // 🐄
    .{ .name = "cowboy_hat_face", .emoji = "\xf0\x9f\xa4\xa0" }, // 🤠
    .{ .name = "crab", .emoji = "\xf0\x9f\xa6\x80" }, // 🦀
    .{ .name = "crayon", .emoji = "\xf0\x9f\x96\x8d" }, // 🖍
    .{ .name = "credit_card", .emoji = "\xf0\x9f\x92\xb3" }, // 💳
    .{ .name = "crescent_moon", .emoji = "\xf0\x9f\x8c\x99" }, // 🌙
    .{ .name = "cricket", .emoji = "\xf0\x9f\xa6\x97" }, // 🦗
    .{ .name = "cricket_game", .emoji = "\xf0\x9f\x8f\x8f" }, // 🏏
    .{ .name = "croatia", .emoji = "\xf0\x9f\x87\xad\xf0\x9f\x87\xb7" }, // 🇭🇷
    .{ .name = "crocodile", .emoji = "\xf0\x9f\x90\x8a" }, // 🐊
    .{ .name = "croissant", .emoji = "\xf0\x9f\xa5\x90" }, // 🥐
    .{ .name = "crossed_fingers", .emoji = "\xf0\x9f\xa4\x9e" }, // 🤞
    .{ .name = "crossed_flags", .emoji = "\xf0\x9f\x8e\x8c" }, // 🎌
    .{ .name = "crossed_swords", .emoji = "\xe2\x9a\x94" }, // ⚔
    .{ .name = "crown", .emoji = "\xf0\x9f\x91\x91" }, // 👑
    .{ .name = "crutch", .emoji = "\xf0\x9f\xa9\xbc" }, // 🩼
    .{ .name = "cry", .emoji = "\xf0\x9f\x98\xa2" }, // 😢
    .{ .name = "crying_cat_face", .emoji = "\xf0\x9f\x98\xbf" }, // 😿
    .{ .name = "crystal_ball", .emoji = "\xf0\x9f\x94\xae" }, // 🔮
    .{ .name = "cuba", .emoji = "\xf0\x9f\x87\xa8\xf0\x9f\x87\xba" }, // 🇨🇺
    .{ .name = "cucumber", .emoji = "\xf0\x9f\xa5\x92" }, // 🥒
    .{ .name = "cup_with_straw", .emoji = "\xf0\x9f\xa5\xa4" }, // 🥤
    .{ .name = "cupcake", .emoji = "\xf0\x9f\xa7\x81" }, // 🧁
    .{ .name = "cupid", .emoji = "\xf0\x9f\x92\x98" }, // 💘
    .{ .name = "curacao", .emoji = "\xf0\x9f\x87\xa8\xf0\x9f\x87\xbc" }, // 🇨🇼
    .{ .name = "curling_stone", .emoji = "\xf0\x9f\xa5\x8c" }, // 🥌
    .{ .name = "curly_haired_man", .emoji = "\xf0\x9f\x91\xa8\xf0\x9f\xa6\xb1" }, // 👨🦱
    .{ .name = "curly_haired_woman", .emoji = "\xf0\x9f\x91\xa9\xf0\x9f\xa6\xb1" }, // 👩🦱
    .{ .name = "curly_loop", .emoji = "\xe2\x9e\xb0" }, // ➰
    .{ .name = "currency_exchange", .emoji = "\xf0\x9f\x92\xb1" }, // 💱
    .{ .name = "curry", .emoji = "\xf0\x9f\x8d\x9b" }, // 🍛
    .{ .name = "cursing_face", .emoji = "\xf0\x9f\xa4\xac" }, // 🤬
    .{ .name = "custard", .emoji = "\xf0\x9f\x8d\xae" }, // 🍮
    .{ .name = "customs", .emoji = "\xf0\x9f\x9b\x83" }, // 🛃
    .{ .name = "cut_of_meat", .emoji = "\xf0\x9f\xa5\xa9" }, // 🥩
    .{ .name = "cyclone", .emoji = "\xf0\x9f\x8c\x80" }, // 🌀
    .{ .name = "cyprus", .emoji = "\xf0\x9f\x87\xa8\xf0\x9f\x87\xbe" }, // 🇨🇾
    .{ .name = "czech_republic", .emoji = "\xf0\x9f\x87\xa8\xf0\x9f\x87\xbf" }, // 🇨🇿
    .{ .name = "dagger", .emoji = "\xf0\x9f\x97\xa1" }, // 🗡
    .{ .name = "dancer", .emoji = "\xf0\x9f\x92\x83" }, // 💃
    .{ .name = "dancers", .emoji = "\xf0\x9f\x91\xaf" }, // 👯
    .{ .name = "dancing_men", .emoji = "\xf0\x9f\x91\xaf\xe2\x99\x82" }, // 👯♂
    .{ .name = "dancing_women", .emoji = "\xf0\x9f\x91\xaf\xe2\x99\x80" }, // 👯♀
    .{ .name = "dango", .emoji = "\xf0\x9f\x8d\xa1" }, // 🍡
    .{ .name = "dark_sunglasses", .emoji = "\xf0\x9f\x95\xb6" }, // 🕶
    .{ .name = "dart", .emoji = "\xf0\x9f\x8e\xaf" }, // 🎯
    .{ .name = "dash", .emoji = "\xf0\x9f\x92\xa8" }, // 💨
    .{ .name = "date", .emoji = "\xf0\x9f\x93\x85" }, // 📅
    .{ .name = "de", .emoji = "\xf0\x9f\x87\xa9\xf0\x9f\x87\xaa" }, // 🇩🇪
    .{ .name = "deaf_man", .emoji = "\xf0\x9f\xa7\x8f\xe2\x99\x82" }, // 🧏♂
    .{ .name = "deaf_person", .emoji = "\xf0\x9f\xa7\x8f" }, // 🧏
    .{ .name = "deaf_woman", .emoji = "\xf0\x9f\xa7\x8f\xe2\x99\x80" }, // 🧏♀
    .{ .name = "deciduous_tree", .emoji = "\xf0\x9f\x8c\xb3" }, // 🌳
    .{ .name = "deer", .emoji = "\xf0\x9f\xa6\x8c" }, // 🦌
    .{ .name = "denmark", .emoji = "\xf0\x9f\x87\xa9\xf0\x9f\x87\xb0" }, // 🇩🇰
    .{ .name = "department_store", .emoji = "\xf0\x9f\x8f\xac" }, // 🏬
    .{ .name = "derelict_house", .emoji = "\xf0\x9f\x8f\x9a" }, // 🏚
    .{ .name = "desert", .emoji = "\xf0\x9f\x8f\x9c" }, // 🏜
    .{ .name = "desert_island", .emoji = "\xf0\x9f\x8f\x9d" }, // 🏝
    .{ .name = "desktop_computer", .emoji = "\xf0\x9f\x96\xa5" }, // 🖥
    .{ .name = "detective", .emoji = "\xf0\x9f\x95\xb5" }, // 🕵
    .{ .name = "diamond_shape_with_a_dot_inside", .emoji = "\xf0\x9f\x92\xa0" }, // 💠
    .{ .name = "diamonds", .emoji = "\xe2\x99\xa6" }, // ♦
    .{ .name = "diego_garcia", .emoji = "\xf0\x9f\x87\xa9\xf0\x9f\x87\xac" }, // 🇩🇬
    .{ .name = "disappointed", .emoji = "\xf0\x9f\x98\x9e" }, // 😞
    .{ .name = "disappointed_relieved", .emoji = "\xf0\x9f\x98\xa5" }, // 😥
    .{ .name = "disguised_face", .emoji = "\xf0\x9f\xa5\xb8" }, // 🥸
    .{ .name = "diving_mask", .emoji = "\xf0\x9f\xa4\xbf" }, // 🤿
    .{ .name = "diya_lamp", .emoji = "\xf0\x9f\xaa\x94" }, // 🪔
    .{ .name = "dizzy", .emoji = "\xf0\x9f\x92\xab" }, // 💫
    .{ .name = "dizzy_face", .emoji = "\xf0\x9f\x98\xb5" }, // 😵
    .{ .name = "djibouti", .emoji = "\xf0\x9f\x87\xa9\xf0\x9f\x87\xaf" }, // 🇩🇯
    .{ .name = "dna", .emoji = "\xf0\x9f\xa7\xac" }, // 🧬
    .{ .name = "do_not_litter", .emoji = "\xf0\x9f\x9a\xaf" }, // 🚯
    .{ .name = "dodo", .emoji = "\xf0\x9f\xa6\xa4" }, // 🦤
    .{ .name = "dog", .emoji = "\xf0\x9f\x90\xb6" }, // 🐶
    .{ .name = "dog2", .emoji = "\xf0\x9f\x90\x95" }, // 🐕
    .{ .name = "dollar", .emoji = "\xf0\x9f\x92\xb5" }, // 💵
    .{ .name = "dolls", .emoji = "\xf0\x9f\x8e\x8e" }, // 🎎
    .{ .name = "dolphin", .emoji = "\xf0\x9f\x90\xac" }, // 🐬
    .{ .name = "dominica", .emoji = "\xf0\x9f\x87\xa9\xf0\x9f\x87\xb2" }, // 🇩🇲
    .{ .name = "dominican_republic", .emoji = "\xf0\x9f\x87\xa9\xf0\x9f\x87\xb4" }, // 🇩🇴
    .{ .name = "donkey", .emoji = "\xf0\x9f\xab\x8f" }, // 🫏
    .{ .name = "door", .emoji = "\xf0\x9f\x9a\xaa" }, // 🚪
    .{ .name = "dotted_line_face", .emoji = "\xf0\x9f\xab\xa5" }, // 🫥
    .{ .name = "doughnut", .emoji = "\xf0\x9f\x8d\xa9" }, // 🍩
    .{ .name = "dove", .emoji = "\xf0\x9f\x95\x8a" }, // 🕊
    .{ .name = "dragon", .emoji = "\xf0\x9f\x90\x89" }, // 🐉
    .{ .name = "dragon_face", .emoji = "\xf0\x9f\x90\xb2" }, // 🐲
    .{ .name = "dress", .emoji = "\xf0\x9f\x91\x97" }, // 👗
    .{ .name = "dromedary_camel", .emoji = "\xf0\x9f\x90\xaa" }, // 🐪
    .{ .name = "drooling_face", .emoji = "\xf0\x9f\xa4\xa4" }, // 🤤
    .{ .name = "drop_of_blood", .emoji = "\xf0\x9f\xa9\xb8" }, // 🩸
    .{ .name = "droplet", .emoji = "\xf0\x9f\x92\xa7" }, // 💧
    .{ .name = "drum", .emoji = "\xf0\x9f\xa5\x81" }, // 🥁
    .{ .name = "duck", .emoji = "\xf0\x9f\xa6\x86" }, // 🦆
    .{ .name = "dumpling", .emoji = "\xf0\x9f\xa5\x9f" }, // 🥟
    .{ .name = "dvd", .emoji = "\xf0\x9f\x93\x80" }, // 📀
    .{ .name = "e-mail", .emoji = "\xf0\x9f\x93\xa7" }, // 📧
    .{ .name = "eagle", .emoji = "\xf0\x9f\xa6\x85" }, // 🦅
    .{ .name = "ear", .emoji = "\xf0\x9f\x91\x82" }, // 👂
    .{ .name = "ear_of_rice", .emoji = "\xf0\x9f\x8c\xbe" }, // 🌾
    .{ .name = "ear_with_hearing_aid", .emoji = "\xf0\x9f\xa6\xbb" }, // 🦻
    .{ .name = "earth_africa", .emoji = "\xf0\x9f\x8c\x8d" }, // 🌍
    .{ .name = "earth_americas", .emoji = "\xf0\x9f\x8c\x8e" }, // 🌎
    .{ .name = "earth_asia", .emoji = "\xf0\x9f\x8c\x8f" }, // 🌏
    .{ .name = "ecuador", .emoji = "\xf0\x9f\x87\xaa\xf0\x9f\x87\xa8" }, // 🇪🇨
    .{ .name = "egg", .emoji = "\xf0\x9f\xa5\x9a" }, // 🥚
    .{ .name = "eggplant", .emoji = "\xf0\x9f\x8d\x86" }, // 🍆
    .{ .name = "egypt", .emoji = "\xf0\x9f\x87\xaa\xf0\x9f\x87\xac" }, // 🇪🇬
    .{ .name = "eight", .emoji = "\x38\xe2\x83\xa3" }, // 8⃣
    .{ .name = "eight_pointed_black_star", .emoji = "\xe2\x9c\xb4" }, // ✴
    .{ .name = "eight_spoked_asterisk", .emoji = "\xe2\x9c\xb3" }, // ✳
    .{ .name = "eject_button", .emoji = "\xe2\x8f\x8f" }, // ⏏
    .{ .name = "el_salvador", .emoji = "\xf0\x9f\x87\xb8\xf0\x9f\x87\xbb" }, // 🇸🇻
    .{ .name = "electric_plug", .emoji = "\xf0\x9f\x94\x8c" }, // 🔌
    .{ .name = "elephant", .emoji = "\xf0\x9f\x90\x98" }, // 🐘
    .{ .name = "elevator", .emoji = "\xf0\x9f\x9b\x97" }, // 🛗
    .{ .name = "elf", .emoji = "\xf0\x9f\xa7\x9d" }, // 🧝
    .{ .name = "elf_man", .emoji = "\xf0\x9f\xa7\x9d\xe2\x99\x82" }, // 🧝♂
    .{ .name = "elf_woman", .emoji = "\xf0\x9f\xa7\x9d\xe2\x99\x80" }, // 🧝♀
    .{ .name = "email", .emoji = "\xf0\x9f\x93\xa7" }, // 📧
    .{ .name = "empty_nest", .emoji = "\xf0\x9f\xaa\xb9" }, // 🪹
    .{ .name = "end", .emoji = "\xf0\x9f\x94\x9a" }, // 🔚
    .{ .name = "england", .emoji = "\xf0\x9f\x8f\xb4\xf3\xa0\x81\xa7\xf3\xa0\x81\xa2\xf3\xa0\x81\xa5\xf3\xa0\x81\xae\xf3\xa0\x81\xa7\xf3\xa0\x81\xbf" }, // 🏴󠁧󠁢󠁥󠁮󠁧󠁿
    .{ .name = "envelope", .emoji = "\xe2\x9c\x89" }, // ✉
    .{ .name = "envelope_with_arrow", .emoji = "\xf0\x9f\x93\xa9" }, // 📩
    .{ .name = "equatorial_guinea", .emoji = "\xf0\x9f\x87\xac\xf0\x9f\x87\xb6" }, // 🇬🇶
    .{ .name = "eritrea", .emoji = "\xf0\x9f\x87\xaa\xf0\x9f\x87\xb7" }, // 🇪🇷
    .{ .name = "es", .emoji = "\xf0\x9f\x87\xaa\xf0\x9f\x87\xb8" }, // 🇪🇸
    .{ .name = "estonia", .emoji = "\xf0\x9f\x87\xaa\xf0\x9f\x87\xaa" }, // 🇪🇪
    .{ .name = "ethiopia", .emoji = "\xf0\x9f\x87\xaa\xf0\x9f\x87\xb9" }, // 🇪🇹
    .{ .name = "eu", .emoji = "\xf0\x9f\x87\xaa\xf0\x9f\x87\xba" }, // 🇪🇺
    .{ .name = "euro", .emoji = "\xf0\x9f\x92\xb6" }, // 💶
    .{ .name = "european_castle", .emoji = "\xf0\x9f\x8f\xb0" }, // 🏰
    .{ .name = "european_post_office", .emoji = "\xf0\x9f\x8f\xa4" }, // 🏤
    .{ .name = "european_union", .emoji = "\xf0\x9f\x87\xaa\xf0\x9f\x87\xba" }, // 🇪🇺
    .{ .name = "evergreen_tree", .emoji = "\xf0\x9f\x8c\xb2" }, // 🌲
    .{ .name = "exclamation", .emoji = "\xe2\x9d\x97" }, // ❗
    .{ .name = "exploding_head", .emoji = "\xf0\x9f\xa4\xaf" }, // 🤯
    .{ .name = "expressionless", .emoji = "\xf0\x9f\x98\x91" }, // 😑
    .{ .name = "eye", .emoji = "\xf0\x9f\x91\x81" }, // 👁
    .{ .name = "eye_speech_bubble", .emoji = "\xf0\x9f\x91\x81\xf0\x9f\x97\xa8" }, // 👁🗨
    .{ .name = "eyeglasses", .emoji = "\xf0\x9f\x91\x93" }, // 👓
    .{ .name = "eyes", .emoji = "\xf0\x9f\x91\x80" }, // 👀
    .{ .name = "face_exhaling", .emoji = "\xf0\x9f\x98\xae\xf0\x9f\x92\xa8" }, // 😮💨
    .{ .name = "face_holding_back_tears", .emoji = "\xf0\x9f\xa5\xb9" }, // 🥹
    .{ .name = "face_in_clouds", .emoji = "\xf0\x9f\x98\xb6\xf0\x9f\x8c\xab" }, // 😶🌫
    .{ .name = "face_with_diagonal_mouth", .emoji = "\xf0\x9f\xab\xa4" }, // 🫤
    .{ .name = "face_with_head_bandage", .emoji = "\xf0\x9f\xa4\x95" }, // 🤕
    .{ .name = "face_with_open_eyes_and_hand_over_mouth", .emoji = "\xf0\x9f\xab\xa2" }, // 🫢
    .{ .name = "face_with_peeking_eye", .emoji = "\xf0\x9f\xab\xa3" }, // 🫣
    .{ .name = "face_with_spiral_eyes", .emoji = "\xf0\x9f\x98\xb5\xf0\x9f\x92\xab" }, // 😵💫
    .{ .name = "face_with_thermometer", .emoji = "\xf0\x9f\xa4\x92" }, // 🤒
    .{ .name = "facepalm", .emoji = "\xf0\x9f\xa4\xa6" }, // 🤦
    .{ .name = "facepunch", .emoji = "\xf0\x9f\x91\x8a" }, // 👊
    .{ .name = "factory", .emoji = "\xf0\x9f\x8f\xad" }, // 🏭
    .{ .name = "factory_worker", .emoji = "\xf0\x9f\xa7\x91\xf0\x9f\x8f\xad" }, // 🧑🏭
    .{ .name = "fairy", .emoji = "\xf0\x9f\xa7\x9a" }, // 🧚
    .{ .name = "fairy_man", .emoji = "\xf0\x9f\xa7\x9a\xe2\x99\x82" }, // 🧚♂
    .{ .name = "fairy_woman", .emoji = "\xf0\x9f\xa7\x9a\xe2\x99\x80" }, // 🧚♀
    .{ .name = "falafel", .emoji = "\xf0\x9f\xa7\x86" }, // 🧆
    .{ .name = "falkland_islands", .emoji = "\xf0\x9f\x87\xab\xf0\x9f\x87\xb0" }, // 🇫🇰
    .{ .name = "fallen_leaf", .emoji = "\xf0\x9f\x8d\x82" }, // 🍂
    .{ .name = "family", .emoji = "\xf0\x9f\x91\xaa" }, // 👪
    .{ .name = "family_man_boy", .emoji = "\xf0\x9f\x91\xa8\xf0\x9f\x91\xa6" }, // 👨👦
    .{ .name = "family_man_boy_boy", .emoji = "\xf0\x9f\x91\xa8\xf0\x9f\x91\xa6\xf0\x9f\x91\xa6" }, // 👨👦👦
    .{ .name = "family_man_girl", .emoji = "\xf0\x9f\x91\xa8\xf0\x9f\x91\xa7" }, // 👨👧
    .{ .name = "family_man_girl_boy", .emoji = "\xf0\x9f\x91\xa8\xf0\x9f\x91\xa7\xf0\x9f\x91\xa6" }, // 👨👧👦
    .{ .name = "family_man_girl_girl", .emoji = "\xf0\x9f\x91\xa8\xf0\x9f\x91\xa7\xf0\x9f\x91\xa7" }, // 👨👧👧
    .{ .name = "family_man_man_boy", .emoji = "\xf0\x9f\x91\xa8\xf0\x9f\x91\xa8\xf0\x9f\x91\xa6" }, // 👨👨👦
    .{ .name = "family_man_man_boy_boy", .emoji = "\xf0\x9f\x91\xa8\xf0\x9f\x91\xa8\xf0\x9f\x91\xa6\xf0\x9f\x91\xa6" }, // 👨👨👦👦
    .{ .name = "family_man_man_girl", .emoji = "\xf0\x9f\x91\xa8\xf0\x9f\x91\xa8\xf0\x9f\x91\xa7" }, // 👨👨👧
    .{ .name = "family_man_man_girl_boy", .emoji = "\xf0\x9f\x91\xa8\xf0\x9f\x91\xa8\xf0\x9f\x91\xa7\xf0\x9f\x91\xa6" }, // 👨👨👧👦
    .{ .name = "family_man_man_girl_girl", .emoji = "\xf0\x9f\x91\xa8\xf0\x9f\x91\xa8\xf0\x9f\x91\xa7\xf0\x9f\x91\xa7" }, // 👨👨👧👧
    .{ .name = "family_man_woman_boy", .emoji = "\xf0\x9f\x91\xa8\xf0\x9f\x91\xa9\xf0\x9f\x91\xa6" }, // 👨👩👦
    .{ .name = "family_man_woman_boy_boy", .emoji = "\xf0\x9f\x91\xa8\xf0\x9f\x91\xa9\xf0\x9f\x91\xa6\xf0\x9f\x91\xa6" }, // 👨👩👦👦
    .{ .name = "family_man_woman_girl", .emoji = "\xf0\x9f\x91\xa8\xf0\x9f\x91\xa9\xf0\x9f\x91\xa7" }, // 👨👩👧
    .{ .name = "family_man_woman_girl_boy", .emoji = "\xf0\x9f\x91\xa8\xf0\x9f\x91\xa9\xf0\x9f\x91\xa7\xf0\x9f\x91\xa6" }, // 👨👩👧👦
    .{ .name = "family_man_woman_girl_girl", .emoji = "\xf0\x9f\x91\xa8\xf0\x9f\x91\xa9\xf0\x9f\x91\xa7\xf0\x9f\x91\xa7" }, // 👨👩👧👧
    .{ .name = "family_woman_boy", .emoji = "\xf0\x9f\x91\xa9\xf0\x9f\x91\xa6" }, // 👩👦
    .{ .name = "family_woman_boy_boy", .emoji = "\xf0\x9f\x91\xa9\xf0\x9f\x91\xa6\xf0\x9f\x91\xa6" }, // 👩👦👦
    .{ .name = "family_woman_girl", .emoji = "\xf0\x9f\x91\xa9\xf0\x9f\x91\xa7" }, // 👩👧
    .{ .name = "family_woman_girl_boy", .emoji = "\xf0\x9f\x91\xa9\xf0\x9f\x91\xa7\xf0\x9f\x91\xa6" }, // 👩👧👦
    .{ .name = "family_woman_girl_girl", .emoji = "\xf0\x9f\x91\xa9\xf0\x9f\x91\xa7\xf0\x9f\x91\xa7" }, // 👩👧👧
    .{ .name = "family_woman_woman_boy", .emoji = "\xf0\x9f\x91\xa9\xf0\x9f\x91\xa9\xf0\x9f\x91\xa6" }, // 👩👩👦
    .{ .name = "family_woman_woman_boy_boy", .emoji = "\xf0\x9f\x91\xa9\xf0\x9f\x91\xa9\xf0\x9f\x91\xa6\xf0\x9f\x91\xa6" }, // 👩👩👦👦
    .{ .name = "family_woman_woman_girl", .emoji = "\xf0\x9f\x91\xa9\xf0\x9f\x91\xa9\xf0\x9f\x91\xa7" }, // 👩👩👧
    .{ .name = "family_woman_woman_girl_boy", .emoji = "\xf0\x9f\x91\xa9\xf0\x9f\x91\xa9\xf0\x9f\x91\xa7\xf0\x9f\x91\xa6" }, // 👩👩👧👦
    .{ .name = "family_woman_woman_girl_girl", .emoji = "\xf0\x9f\x91\xa9\xf0\x9f\x91\xa9\xf0\x9f\x91\xa7\xf0\x9f\x91\xa7" }, // 👩👩👧👧
    .{ .name = "farmer", .emoji = "\xf0\x9f\xa7\x91\xf0\x9f\x8c\xbe" }, // 🧑🌾
    .{ .name = "faroe_islands", .emoji = "\xf0\x9f\x87\xab\xf0\x9f\x87\xb4" }, // 🇫🇴
    .{ .name = "fast_forward", .emoji = "\xe2\x8f\xa9" }, // ⏩
    .{ .name = "fax", .emoji = "\xf0\x9f\x93\xa0" }, // 📠
    .{ .name = "fearful", .emoji = "\xf0\x9f\x98\xa8" }, // 😨
    .{ .name = "feather", .emoji = "\xf0\x9f\xaa\xb6" }, // 🪶
    .{ .name = "feet", .emoji = "\xf0\x9f\x90\xbe" }, // 🐾
    .{ .name = "female_detective", .emoji = "\xf0\x9f\x95\xb5\xe2\x99\x80" }, // 🕵♀
    .{ .name = "female_sign", .emoji = "\xe2\x99\x80" }, // ♀
    .{ .name = "ferris_wheel", .emoji = "\xf0\x9f\x8e\xa1" }, // 🎡
    .{ .name = "ferry", .emoji = "\xe2\x9b\xb4" }, // ⛴
    .{ .name = "field_hockey", .emoji = "\xf0\x9f\x8f\x91" }, // 🏑
    .{ .name = "fiji", .emoji = "\xf0\x9f\x87\xab\xf0\x9f\x87\xaf" }, // 🇫🇯
    .{ .name = "file_cabinet", .emoji = "\xf0\x9f\x97\x84" }, // 🗄
    .{ .name = "file_folder", .emoji = "\xf0\x9f\x93\x81" }, // 📁
    .{ .name = "film_projector", .emoji = "\xf0\x9f\x93\xbd" }, // 📽
    .{ .name = "film_strip", .emoji = "\xf0\x9f\x8e\x9e" }, // 🎞
    .{ .name = "finland", .emoji = "\xf0\x9f\x87\xab\xf0\x9f\x87\xae" }, // 🇫🇮
    .{ .name = "fire", .emoji = "\xf0\x9f\x94\xa5" }, // 🔥
    .{ .name = "fire_engine", .emoji = "\xf0\x9f\x9a\x92" }, // 🚒
    .{ .name = "fire_extinguisher", .emoji = "\xf0\x9f\xa7\xaf" }, // 🧯
    .{ .name = "firecracker", .emoji = "\xf0\x9f\xa7\xa8" }, // 🧨
    .{ .name = "firefighter", .emoji = "\xf0\x9f\xa7\x91\xf0\x9f\x9a\x92" }, // 🧑🚒
    .{ .name = "fireworks", .emoji = "\xf0\x9f\x8e\x86" }, // 🎆
    .{ .name = "first_quarter_moon", .emoji = "\xf0\x9f\x8c\x93" }, // 🌓
    .{ .name = "first_quarter_moon_with_face", .emoji = "\xf0\x9f\x8c\x9b" }, // 🌛
    .{ .name = "fish", .emoji = "\xf0\x9f\x90\x9f" }, // 🐟
    .{ .name = "fish_cake", .emoji = "\xf0\x9f\x8d\xa5" }, // 🍥
    .{ .name = "fishing_pole_and_fish", .emoji = "\xf0\x9f\x8e\xa3" }, // 🎣
    .{ .name = "fist", .emoji = "\xe2\x9c\x8a" }, // ✊
    .{ .name = "fist_left", .emoji = "\xf0\x9f\xa4\x9b" }, // 🤛
    .{ .name = "fist_oncoming", .emoji = "\xf0\x9f\x91\x8a" }, // 👊
    .{ .name = "fist_raised", .emoji = "\xe2\x9c\x8a" }, // ✊
    .{ .name = "fist_right", .emoji = "\xf0\x9f\xa4\x9c" }, // 🤜
    .{ .name = "five", .emoji = "\x35\xe2\x83\xa3" }, // 5⃣
    .{ .name = "flags", .emoji = "\xf0\x9f\x8e\x8f" }, // 🎏
    .{ .name = "flamingo", .emoji = "\xf0\x9f\xa6\xa9" }, // 🦩
    .{ .name = "flashlight", .emoji = "\xf0\x9f\x94\xa6" }, // 🔦
    .{ .name = "flat_shoe", .emoji = "\xf0\x9f\xa5\xbf" }, // 🥿
    .{ .name = "flatbread", .emoji = "\xf0\x9f\xab\x93" }, // 🫓
    .{ .name = "fleur_de_lis", .emoji = "\xe2\x9a\x9c" }, // ⚜
    .{ .name = "flight_arrival", .emoji = "\xf0\x9f\x9b\xac" }, // 🛬
    .{ .name = "flight_departure", .emoji = "\xf0\x9f\x9b\xab" }, // 🛫
    .{ .name = "flipper", .emoji = "\xf0\x9f\x90\xac" }, // 🐬
    .{ .name = "floppy_disk", .emoji = "\xf0\x9f\x92\xbe" }, // 💾
    .{ .name = "flower_playing_cards", .emoji = "\xf0\x9f\x8e\xb4" }, // 🎴
    .{ .name = "flushed", .emoji = "\xf0\x9f\x98\xb3" }, // 😳
    .{ .name = "flute", .emoji = "\xf0\x9f\xaa\x88" }, // 🪈
    .{ .name = "fly", .emoji = "\xf0\x9f\xaa\xb0" }, // 🪰
    .{ .name = "flying_disc", .emoji = "\xf0\x9f\xa5\x8f" }, // 🥏
    .{ .name = "flying_saucer", .emoji = "\xf0\x9f\x9b\xb8" }, // 🛸
    .{ .name = "fog", .emoji = "\xf0\x9f\x8c\xab" }, // 🌫
    .{ .name = "foggy", .emoji = "\xf0\x9f\x8c\x81" }, // 🌁
    .{ .name = "folding_hand_fan", .emoji = "\xf0\x9f\xaa\xad" }, // 🪭
    .{ .name = "fondue", .emoji = "\xf0\x9f\xab\x95" }, // 🫕
    .{ .name = "foot", .emoji = "\xf0\x9f\xa6\xb6" }, // 🦶
    .{ .name = "football", .emoji = "\xf0\x9f\x8f\x88" }, // 🏈
    .{ .name = "footprints", .emoji = "\xf0\x9f\x91\xa3" }, // 👣
    .{ .name = "fork_and_knife", .emoji = "\xf0\x9f\x8d\xb4" }, // 🍴
    .{ .name = "fortune_cookie", .emoji = "\xf0\x9f\xa5\xa0" }, // 🥠
    .{ .name = "fountain", .emoji = "\xe2\x9b\xb2" }, // ⛲
    .{ .name = "fountain_pen", .emoji = "\xf0\x9f\x96\x8b" }, // 🖋
    .{ .name = "four", .emoji = "\x34\xe2\x83\xa3" }, // 4⃣
    .{ .name = "four_leaf_clover", .emoji = "\xf0\x9f\x8d\x80" }, // 🍀
    .{ .name = "fox_face", .emoji = "\xf0\x9f\xa6\x8a" }, // 🦊
    .{ .name = "fr", .emoji = "\xf0\x9f\x87\xab\xf0\x9f\x87\xb7" }, // 🇫🇷
    .{ .name = "framed_picture", .emoji = "\xf0\x9f\x96\xbc" }, // 🖼
    .{ .name = "free", .emoji = "\xf0\x9f\x86\x93" }, // 🆓
    .{ .name = "french_guiana", .emoji = "\xf0\x9f\x87\xac\xf0\x9f\x87\xab" }, // 🇬🇫
    .{ .name = "french_polynesia", .emoji = "\xf0\x9f\x87\xb5\xf0\x9f\x87\xab" }, // 🇵🇫
    .{ .name = "french_southern_territories", .emoji = "\xf0\x9f\x87\xb9\xf0\x9f\x87\xab" }, // 🇹🇫
    .{ .name = "fried_egg", .emoji = "\xf0\x9f\x8d\xb3" }, // 🍳
    .{ .name = "fried_shrimp", .emoji = "\xf0\x9f\x8d\xa4" }, // 🍤
    .{ .name = "fries", .emoji = "\xf0\x9f\x8d\x9f" }, // 🍟
    .{ .name = "frog", .emoji = "\xf0\x9f\x90\xb8" }, // 🐸
    .{ .name = "frowning", .emoji = "\xf0\x9f\x98\xa6" }, // 😦
    .{ .name = "frowning_face", .emoji = "\xe2\x98\xb9" }, // ☹
    .{ .name = "frowning_man", .emoji = "\xf0\x9f\x99\x8d\xe2\x99\x82" }, // 🙍♂
    .{ .name = "frowning_person", .emoji = "\xf0\x9f\x99\x8d" }, // 🙍
    .{ .name = "frowning_woman", .emoji = "\xf0\x9f\x99\x8d\xe2\x99\x80" }, // 🙍♀
    .{ .name = "fu", .emoji = "\xf0\x9f\x96\x95" }, // 🖕
    .{ .name = "fuelpump", .emoji = "\xe2\x9b\xbd" }, // ⛽
    .{ .name = "full_moon", .emoji = "\xf0\x9f\x8c\x95" }, // 🌕
    .{ .name = "full_moon_with_face", .emoji = "\xf0\x9f\x8c\x9d" }, // 🌝
    .{ .name = "funeral_urn", .emoji = "\xe2\x9a\xb1" }, // ⚱
    .{ .name = "gabon", .emoji = "\xf0\x9f\x87\xac\xf0\x9f\x87\xa6" }, // 🇬🇦
    .{ .name = "gambia", .emoji = "\xf0\x9f\x87\xac\xf0\x9f\x87\xb2" }, // 🇬🇲
    .{ .name = "game_die", .emoji = "\xf0\x9f\x8e\xb2" }, // 🎲
    .{ .name = "garlic", .emoji = "\xf0\x9f\xa7\x84" }, // 🧄
    .{ .name = "gb", .emoji = "\xf0\x9f\x87\xac\xf0\x9f\x87\xa7" }, // 🇬🇧
    .{ .name = "gear", .emoji = "\xe2\x9a\x99" }, // ⚙
    .{ .name = "gem", .emoji = "\xf0\x9f\x92\x8e" }, // 💎
    .{ .name = "gemini", .emoji = "\xe2\x99\x8a" }, // ♊
    .{ .name = "genie", .emoji = "\xf0\x9f\xa7\x9e" }, // 🧞
    .{ .name = "genie_man", .emoji = "\xf0\x9f\xa7\x9e\xe2\x99\x82" }, // 🧞♂
    .{ .name = "genie_woman", .emoji = "\xf0\x9f\xa7\x9e\xe2\x99\x80" }, // 🧞♀
    .{ .name = "georgia", .emoji = "\xf0\x9f\x87\xac\xf0\x9f\x87\xaa" }, // 🇬🇪
    .{ .name = "ghana", .emoji = "\xf0\x9f\x87\xac\xf0\x9f\x87\xad" }, // 🇬🇭
    .{ .name = "ghost", .emoji = "\xf0\x9f\x91\xbb" }, // 👻
    .{ .name = "gibraltar", .emoji = "\xf0\x9f\x87\xac\xf0\x9f\x87\xae" }, // 🇬🇮
    .{ .name = "gift", .emoji = "\xf0\x9f\x8e\x81" }, // 🎁
    .{ .name = "gift_heart", .emoji = "\xf0\x9f\x92\x9d" }, // 💝
    .{ .name = "ginger_root", .emoji = "\xf0\x9f\xab\x9a" }, // 🫚
    .{ .name = "giraffe", .emoji = "\xf0\x9f\xa6\x92" }, // 🦒
    .{ .name = "girl", .emoji = "\xf0\x9f\x91\xa7" }, // 👧
    .{ .name = "globe_with_meridians", .emoji = "\xf0\x9f\x8c\x90" }, // 🌐
    .{ .name = "gloves", .emoji = "\xf0\x9f\xa7\xa4" }, // 🧤
    .{ .name = "goal_net", .emoji = "\xf0\x9f\xa5\x85" }, // 🥅
    .{ .name = "goat", .emoji = "\xf0\x9f\x90\x90" }, // 🐐
    .{ .name = "goggles", .emoji = "\xf0\x9f\xa5\xbd" }, // 🥽
    .{ .name = "golf", .emoji = "\xe2\x9b\xb3" }, // ⛳
    .{ .name = "golfing", .emoji = "\xf0\x9f\x8f\x8c" }, // 🏌
    .{ .name = "golfing_man", .emoji = "\xf0\x9f\x8f\x8c\xe2\x99\x82" }, // 🏌♂
    .{ .name = "golfing_woman", .emoji = "\xf0\x9f\x8f\x8c\xe2\x99\x80" }, // 🏌♀
    .{ .name = "goose", .emoji = "\xf0\x9f\xaa\xbf" }, // 🪿
    .{ .name = "gorilla", .emoji = "\xf0\x9f\xa6\x8d" }, // 🦍
    .{ .name = "grapes", .emoji = "\xf0\x9f\x8d\x87" }, // 🍇
    .{ .name = "greece", .emoji = "\xf0\x9f\x87\xac\xf0\x9f\x87\xb7" }, // 🇬🇷
    .{ .name = "green_apple", .emoji = "\xf0\x9f\x8d\x8f" }, // 🍏
    .{ .name = "green_book", .emoji = "\xf0\x9f\x93\x97" }, // 📗
    .{ .name = "green_circle", .emoji = "\xf0\x9f\x9f\xa2" }, // 🟢
    .{ .name = "green_heart", .emoji = "\xf0\x9f\x92\x9a" }, // 💚
    .{ .name = "green_salad", .emoji = "\xf0\x9f\xa5\x97" }, // 🥗
    .{ .name = "green_square", .emoji = "\xf0\x9f\x9f\xa9" }, // 🟩
    .{ .name = "greenland", .emoji = "\xf0\x9f\x87\xac\xf0\x9f\x87\xb1" }, // 🇬🇱
    .{ .name = "grenada", .emoji = "\xf0\x9f\x87\xac\xf0\x9f\x87\xa9" }, // 🇬🇩
    .{ .name = "grey_exclamation", .emoji = "\xe2\x9d\x95" }, // ❕
    .{ .name = "grey_heart", .emoji = "\xf0\x9f\xa9\xb6" }, // 🩶
    .{ .name = "grey_question", .emoji = "\xe2\x9d\x94" }, // ❔
    .{ .name = "grimacing", .emoji = "\xf0\x9f\x98\xac" }, // 😬
    .{ .name = "grin", .emoji = "\xf0\x9f\x98\x81" }, // 😁
    .{ .name = "grinning", .emoji = "\xf0\x9f\x98\x80" }, // 😀
    .{ .name = "guadeloupe", .emoji = "\xf0\x9f\x87\xac\xf0\x9f\x87\xb5" }, // 🇬🇵
    .{ .name = "guam", .emoji = "\xf0\x9f\x87\xac\xf0\x9f\x87\xba" }, // 🇬🇺
    .{ .name = "guard", .emoji = "\xf0\x9f\x92\x82" }, // 💂
    .{ .name = "guardsman", .emoji = "\xf0\x9f\x92\x82\xe2\x99\x82" }, // 💂♂
    .{ .name = "guardswoman", .emoji = "\xf0\x9f\x92\x82\xe2\x99\x80" }, // 💂♀
    .{ .name = "guatemala", .emoji = "\xf0\x9f\x87\xac\xf0\x9f\x87\xb9" }, // 🇬🇹
    .{ .name = "guernsey", .emoji = "\xf0\x9f\x87\xac\xf0\x9f\x87\xac" }, // 🇬🇬
    .{ .name = "guide_dog", .emoji = "\xf0\x9f\xa6\xae" }, // 🦮
    .{ .name = "guinea", .emoji = "\xf0\x9f\x87\xac\xf0\x9f\x87\xb3" }, // 🇬🇳
    .{ .name = "guinea_bissau", .emoji = "\xf0\x9f\x87\xac\xf0\x9f\x87\xbc" }, // 🇬🇼
    .{ .name = "guitar", .emoji = "\xf0\x9f\x8e\xb8" }, // 🎸
    .{ .name = "gun", .emoji = "\xf0\x9f\x94\xab" }, // 🔫
    .{ .name = "guyana", .emoji = "\xf0\x9f\x87\xac\xf0\x9f\x87\xbe" }, // 🇬🇾
    .{ .name = "hair_pick", .emoji = "\xf0\x9f\xaa\xae" }, // 🪮
    .{ .name = "haircut", .emoji = "\xf0\x9f\x92\x87" }, // 💇
    .{ .name = "haircut_man", .emoji = "\xf0\x9f\x92\x87\xe2\x99\x82" }, // 💇♂
    .{ .name = "haircut_woman", .emoji = "\xf0\x9f\x92\x87\xe2\x99\x80" }, // 💇♀
    .{ .name = "haiti", .emoji = "\xf0\x9f\x87\xad\xf0\x9f\x87\xb9" }, // 🇭🇹
    .{ .name = "hamburger", .emoji = "\xf0\x9f\x8d\x94" }, // 🍔
    .{ .name = "hammer", .emoji = "\xf0\x9f\x94\xa8" }, // 🔨
    .{ .name = "hammer_and_pick", .emoji = "\xe2\x9a\x92" }, // ⚒
    .{ .name = "hammer_and_wrench", .emoji = "\xf0\x9f\x9b\xa0" }, // 🛠
    .{ .name = "hamsa", .emoji = "\xf0\x9f\xaa\xac" }, // 🪬
    .{ .name = "hamster", .emoji = "\xf0\x9f\x90\xb9" }, // 🐹
    .{ .name = "hand", .emoji = "\xe2\x9c\x8b" }, // ✋
    .{ .name = "hand_over_mouth", .emoji = "\xf0\x9f\xa4\xad" }, // 🤭
    .{ .name = "hand_with_index_finger_and_thumb_crossed", .emoji = "\xf0\x9f\xab\xb0" }, // 🫰
    .{ .name = "handbag", .emoji = "\xf0\x9f\x91\x9c" }, // 👜
    .{ .name = "handball_person", .emoji = "\xf0\x9f\xa4\xbe" }, // 🤾
    .{ .name = "handshake", .emoji = "\xf0\x9f\xa4\x9d" }, // 🤝
    .{ .name = "hankey", .emoji = "\xf0\x9f\x92\xa9" }, // 💩
    .{ .name = "hash", .emoji = "\x23\xe2\x83\xa3" }, // #⃣
    .{ .name = "hatched_chick", .emoji = "\xf0\x9f\x90\xa5" }, // 🐥
    .{ .name = "hatching_chick", .emoji = "\xf0\x9f\x90\xa3" }, // 🐣
    .{ .name = "headphones", .emoji = "\xf0\x9f\x8e\xa7" }, // 🎧
    .{ .name = "headstone", .emoji = "\xf0\x9f\xaa\xa6" }, // 🪦
    .{ .name = "health_worker", .emoji = "\xf0\x9f\xa7\x91\xe2\x9a\x95" }, // 🧑⚕
    .{ .name = "hear_no_evil", .emoji = "\xf0\x9f\x99\x89" }, // 🙉
    .{ .name = "heard_mcdonald_islands", .emoji = "\xf0\x9f\x87\xad\xf0\x9f\x87\xb2" }, // 🇭🇲
    .{ .name = "heart", .emoji = "\xe2\x9d\xa4" }, // ❤
    .{ .name = "heart_decoration", .emoji = "\xf0\x9f\x92\x9f" }, // 💟
    .{ .name = "heart_eyes", .emoji = "\xf0\x9f\x98\x8d" }, // 😍
    .{ .name = "heart_eyes_cat", .emoji = "\xf0\x9f\x98\xbb" }, // 😻
    .{ .name = "heart_hands", .emoji = "\xf0\x9f\xab\xb6" }, // 🫶
    .{ .name = "heart_on_fire", .emoji = "\xe2\x9d\xa4\xf0\x9f\x94\xa5" }, // ❤🔥
    .{ .name = "heartbeat", .emoji = "\xf0\x9f\x92\x93" }, // 💓
    .{ .name = "heartpulse", .emoji = "\xf0\x9f\x92\x97" }, // 💗
    .{ .name = "hearts", .emoji = "\xe2\x99\xa5" }, // ♥
    .{ .name = "heavy_check_mark", .emoji = "\xe2\x9c\x94" }, // ✔
    .{ .name = "heavy_division_sign", .emoji = "\xe2\x9e\x97" }, // ➗
    .{ .name = "heavy_dollar_sign", .emoji = "\xf0\x9f\x92\xb2" }, // 💲
    .{ .name = "heavy_equals_sign", .emoji = "\xf0\x9f\x9f\xb0" }, // 🟰
    .{ .name = "heavy_exclamation_mark", .emoji = "\xe2\x9d\x97" }, // ❗
    .{ .name = "heavy_heart_exclamation", .emoji = "\xe2\x9d\xa3" }, // ❣
    .{ .name = "heavy_minus_sign", .emoji = "\xe2\x9e\x96" }, // ➖
    .{ .name = "heavy_multiplication_x", .emoji = "\xe2\x9c\x96" }, // ✖
    .{ .name = "heavy_plus_sign", .emoji = "\xe2\x9e\x95" }, // ➕
    .{ .name = "hedgehog", .emoji = "\xf0\x9f\xa6\x94" }, // 🦔
    .{ .name = "helicopter", .emoji = "\xf0\x9f\x9a\x81" }, // 🚁
    .{ .name = "herb", .emoji = "\xf0\x9f\x8c\xbf" }, // 🌿
    .{ .name = "hibiscus", .emoji = "\xf0\x9f\x8c\xba" }, // 🌺
    .{ .name = "high_brightness", .emoji = "\xf0\x9f\x94\x86" }, // 🔆
    .{ .name = "high_heel", .emoji = "\xf0\x9f\x91\xa0" }, // 👠
    .{ .name = "hiking_boot", .emoji = "\xf0\x9f\xa5\xbe" }, // 🥾
    .{ .name = "hindu_temple", .emoji = "\xf0\x9f\x9b\x95" }, // 🛕
    .{ .name = "hippopotamus", .emoji = "\xf0\x9f\xa6\x9b" }, // 🦛
    .{ .name = "hocho", .emoji = "\xf0\x9f\x94\xaa" }, // 🔪
    .{ .name = "hole", .emoji = "\xf0\x9f\x95\xb3" }, // 🕳
    .{ .name = "honduras", .emoji = "\xf0\x9f\x87\xad\xf0\x9f\x87\xb3" }, // 🇭🇳
    .{ .name = "honey_pot", .emoji = "\xf0\x9f\x8d\xaf" }, // 🍯
    .{ .name = "honeybee", .emoji = "\xf0\x9f\x90\x9d" }, // 🐝
    .{ .name = "hong_kong", .emoji = "\xf0\x9f\x87\xad\xf0\x9f\x87\xb0" }, // 🇭🇰
    .{ .name = "hook", .emoji = "\xf0\x9f\xaa\x9d" }, // 🪝
    .{ .name = "horse", .emoji = "\xf0\x9f\x90\xb4" }, // 🐴
    .{ .name = "horse_racing", .emoji = "\xf0\x9f\x8f\x87" }, // 🏇
    .{ .name = "hospital", .emoji = "\xf0\x9f\x8f\xa5" }, // 🏥
    .{ .name = "hot_face", .emoji = "\xf0\x9f\xa5\xb5" }, // 🥵
    .{ .name = "hot_pepper", .emoji = "\xf0\x9f\x8c\xb6" }, // 🌶
    .{ .name = "hotdog", .emoji = "\xf0\x9f\x8c\xad" }, // 🌭
    .{ .name = "hotel", .emoji = "\xf0\x9f\x8f\xa8" }, // 🏨
    .{ .name = "hotsprings", .emoji = "\xe2\x99\xa8" }, // ♨
    .{ .name = "hourglass", .emoji = "\xe2\x8c\x9b" }, // ⌛
    .{ .name = "hourglass_flowing_sand", .emoji = "\xe2\x8f\xb3" }, // ⏳
    .{ .name = "house", .emoji = "\xf0\x9f\x8f\xa0" }, // 🏠
    .{ .name = "house_with_garden", .emoji = "\xf0\x9f\x8f\xa1" }, // 🏡
    .{ .name = "houses", .emoji = "\xf0\x9f\x8f\x98" }, // 🏘
    .{ .name = "hugs", .emoji = "\xf0\x9f\xa4\x97" }, // 🤗
    .{ .name = "hungary", .emoji = "\xf0\x9f\x87\xad\xf0\x9f\x87\xba" }, // 🇭🇺
    .{ .name = "hushed", .emoji = "\xf0\x9f\x98\xaf" }, // 😯
    .{ .name = "hut", .emoji = "\xf0\x9f\x9b\x96" }, // 🛖
    .{ .name = "hyacinth", .emoji = "\xf0\x9f\xaa\xbb" }, // 🪻
    .{ .name = "ice_cream", .emoji = "\xf0\x9f\x8d\xa8" }, // 🍨
    .{ .name = "ice_cube", .emoji = "\xf0\x9f\xa7\x8a" }, // 🧊
    .{ .name = "ice_hockey", .emoji = "\xf0\x9f\x8f\x92" }, // 🏒
    .{ .name = "ice_skate", .emoji = "\xe2\x9b\xb8" }, // ⛸
    .{ .name = "icecream", .emoji = "\xf0\x9f\x8d\xa6" }, // 🍦
    .{ .name = "iceland", .emoji = "\xf0\x9f\x87\xae\xf0\x9f\x87\xb8" }, // 🇮🇸
    .{ .name = "id", .emoji = "\xf0\x9f\x86\x94" }, // 🆔
    .{ .name = "identification_card", .emoji = "\xf0\x9f\xaa\xaa" }, // 🪪
    .{ .name = "ideograph_advantage", .emoji = "\xf0\x9f\x89\x90" }, // 🉐
    .{ .name = "imp", .emoji = "\xf0\x9f\x91\xbf" }, // 👿
    .{ .name = "inbox_tray", .emoji = "\xf0\x9f\x93\xa5" }, // 📥
    .{ .name = "incoming_envelope", .emoji = "\xf0\x9f\x93\xa8" }, // 📨
    .{ .name = "index_pointing_at_the_viewer", .emoji = "\xf0\x9f\xab\xb5" }, // 🫵
    .{ .name = "india", .emoji = "\xf0\x9f\x87\xae\xf0\x9f\x87\xb3" }, // 🇮🇳
    .{ .name = "indonesia", .emoji = "\xf0\x9f\x87\xae\xf0\x9f\x87\xa9" }, // 🇮🇩
    .{ .name = "infinity", .emoji = "\xe2\x99\xbe" }, // ♾
    .{ .name = "information_desk_person", .emoji = "\xf0\x9f\x92\x81" }, // 💁
    .{ .name = "information_source", .emoji = "\xe2\x84\xb9" }, // ℹ
    .{ .name = "innocent", .emoji = "\xf0\x9f\x98\x87" }, // 😇
    .{ .name = "interrobang", .emoji = "\xe2\x81\x89" }, // ⁉
    .{ .name = "iphone", .emoji = "\xf0\x9f\x93\xb1" }, // 📱
    .{ .name = "iran", .emoji = "\xf0\x9f\x87\xae\xf0\x9f\x87\xb7" }, // 🇮🇷
    .{ .name = "iraq", .emoji = "\xf0\x9f\x87\xae\xf0\x9f\x87\xb6" }, // 🇮🇶
    .{ .name = "ireland", .emoji = "\xf0\x9f\x87\xae\xf0\x9f\x87\xaa" }, // 🇮🇪
    .{ .name = "isle_of_man", .emoji = "\xf0\x9f\x87\xae\xf0\x9f\x87\xb2" }, // 🇮🇲
    .{ .name = "israel", .emoji = "\xf0\x9f\x87\xae\xf0\x9f\x87\xb1" }, // 🇮🇱
    .{ .name = "it", .emoji = "\xf0\x9f\x87\xae\xf0\x9f\x87\xb9" }, // 🇮🇹
    .{ .name = "izakaya_lantern", .emoji = "\xf0\x9f\x8f\xae" }, // 🏮
    .{ .name = "jack_o_lantern", .emoji = "\xf0\x9f\x8e\x83" }, // 🎃
    .{ .name = "jamaica", .emoji = "\xf0\x9f\x87\xaf\xf0\x9f\x87\xb2" }, // 🇯🇲
    .{ .name = "japan", .emoji = "\xf0\x9f\x97\xbe" }, // 🗾
    .{ .name = "japanese_castle", .emoji = "\xf0\x9f\x8f\xaf" }, // 🏯
    .{ .name = "japanese_goblin", .emoji = "\xf0\x9f\x91\xba" }, // 👺
    .{ .name = "japanese_ogre", .emoji = "\xf0\x9f\x91\xb9" }, // 👹
    .{ .name = "jar", .emoji = "\xf0\x9f\xab\x99" }, // 🫙
    .{ .name = "jeans", .emoji = "\xf0\x9f\x91\x96" }, // 👖
    .{ .name = "jellyfish", .emoji = "\xf0\x9f\xaa\xbc" }, // 🪼
    .{ .name = "jersey", .emoji = "\xf0\x9f\x87\xaf\xf0\x9f\x87\xaa" }, // 🇯🇪
    .{ .name = "jigsaw", .emoji = "\xf0\x9f\xa7\xa9" }, // 🧩
    .{ .name = "jordan", .emoji = "\xf0\x9f\x87\xaf\xf0\x9f\x87\xb4" }, // 🇯🇴
    .{ .name = "joy", .emoji = "\xf0\x9f\x98\x82" }, // 😂
    .{ .name = "joy_cat", .emoji = "\xf0\x9f\x98\xb9" }, // 😹
    .{ .name = "joystick", .emoji = "\xf0\x9f\x95\xb9" }, // 🕹
    .{ .name = "jp", .emoji = "\xf0\x9f\x87\xaf\xf0\x9f\x87\xb5" }, // 🇯🇵
    .{ .name = "judge", .emoji = "\xf0\x9f\xa7\x91\xe2\x9a\x96" }, // 🧑⚖
    .{ .name = "juggling_person", .emoji = "\xf0\x9f\xa4\xb9" }, // 🤹
    .{ .name = "kaaba", .emoji = "\xf0\x9f\x95\x8b" }, // 🕋
    .{ .name = "kangaroo", .emoji = "\xf0\x9f\xa6\x98" }, // 🦘
    .{ .name = "kazakhstan", .emoji = "\xf0\x9f\x87\xb0\xf0\x9f\x87\xbf" }, // 🇰🇿
    .{ .name = "kenya", .emoji = "\xf0\x9f\x87\xb0\xf0\x9f\x87\xaa" }, // 🇰🇪
    .{ .name = "key", .emoji = "\xf0\x9f\x94\x91" }, // 🔑
    .{ .name = "keyboard", .emoji = "\xe2\x8c\xa8" }, // ⌨
    .{ .name = "keycap_ten", .emoji = "\xf0\x9f\x94\x9f" }, // 🔟
    .{ .name = "khanda", .emoji = "\xf0\x9f\xaa\xaf" }, // 🪯
    .{ .name = "kick_scooter", .emoji = "\xf0\x9f\x9b\xb4" }, // 🛴
    .{ .name = "kimono", .emoji = "\xf0\x9f\x91\x98" }, // 👘
    .{ .name = "kiribati", .emoji = "\xf0\x9f\x87\xb0\xf0\x9f\x87\xae" }, // 🇰🇮
    .{ .name = "kiss", .emoji = "\xf0\x9f\x92\x8b" }, // 💋
    .{ .name = "kissing", .emoji = "\xf0\x9f\x98\x97" }, // 😗
    .{ .name = "kissing_cat", .emoji = "\xf0\x9f\x98\xbd" }, // 😽
    .{ .name = "kissing_closed_eyes", .emoji = "\xf0\x9f\x98\x9a" }, // 😚
    .{ .name = "kissing_heart", .emoji = "\xf0\x9f\x98\x98" }, // 😘
    .{ .name = "kissing_smiling_eyes", .emoji = "\xf0\x9f\x98\x99" }, // 😙
    .{ .name = "kite", .emoji = "\xf0\x9f\xaa\x81" }, // 🪁
    .{ .name = "kiwi_fruit", .emoji = "\xf0\x9f\xa5\x9d" }, // 🥝
    .{ .name = "kneeling_man", .emoji = "\xf0\x9f\xa7\x8e\xe2\x99\x82" }, // 🧎♂
    .{ .name = "kneeling_person", .emoji = "\xf0\x9f\xa7\x8e" }, // 🧎
    .{ .name = "kneeling_woman", .emoji = "\xf0\x9f\xa7\x8e\xe2\x99\x80" }, // 🧎♀
    .{ .name = "knife", .emoji = "\xf0\x9f\x94\xaa" }, // 🔪
    .{ .name = "knot", .emoji = "\xf0\x9f\xaa\xa2" }, // 🪢
    .{ .name = "koala", .emoji = "\xf0\x9f\x90\xa8" }, // 🐨
    .{ .name = "koko", .emoji = "\xf0\x9f\x88\x81" }, // 🈁
    .{ .name = "kosovo", .emoji = "\xf0\x9f\x87\xbd\xf0\x9f\x87\xb0" }, // 🇽🇰
    .{ .name = "kr", .emoji = "\xf0\x9f\x87\xb0\xf0\x9f\x87\xb7" }, // 🇰🇷
    .{ .name = "kuwait", .emoji = "\xf0\x9f\x87\xb0\xf0\x9f\x87\xbc" }, // 🇰🇼
    .{ .name = "kyrgyzstan", .emoji = "\xf0\x9f\x87\xb0\xf0\x9f\x87\xac" }, // 🇰🇬
    .{ .name = "lab_coat", .emoji = "\xf0\x9f\xa5\xbc" }, // 🥼
    .{ .name = "label", .emoji = "\xf0\x9f\x8f\xb7" }, // 🏷
    .{ .name = "lacrosse", .emoji = "\xf0\x9f\xa5\x8d" }, // 🥍
    .{ .name = "ladder", .emoji = "\xf0\x9f\xaa\x9c" }, // 🪜
    .{ .name = "lady_beetle", .emoji = "\xf0\x9f\x90\x9e" }, // 🐞
    .{ .name = "lantern", .emoji = "\xf0\x9f\x8f\xae" }, // 🏮
    .{ .name = "laos", .emoji = "\xf0\x9f\x87\xb1\xf0\x9f\x87\xa6" }, // 🇱🇦
    .{ .name = "large_blue_circle", .emoji = "\xf0\x9f\x94\xb5" }, // 🔵
    .{ .name = "large_blue_diamond", .emoji = "\xf0\x9f\x94\xb7" }, // 🔷
    .{ .name = "large_orange_diamond", .emoji = "\xf0\x9f\x94\xb6" }, // 🔶
    .{ .name = "last_quarter_moon", .emoji = "\xf0\x9f\x8c\x97" }, // 🌗
    .{ .name = "last_quarter_moon_with_face", .emoji = "\xf0\x9f\x8c\x9c" }, // 🌜
    .{ .name = "latin_cross", .emoji = "\xe2\x9c\x9d" }, // ✝
    .{ .name = "latvia", .emoji = "\xf0\x9f\x87\xb1\xf0\x9f\x87\xbb" }, // 🇱🇻
    .{ .name = "laughing", .emoji = "\xf0\x9f\x98\x86" }, // 😆
    .{ .name = "leafy_green", .emoji = "\xf0\x9f\xa5\xac" }, // 🥬
    .{ .name = "leaves", .emoji = "\xf0\x9f\x8d\x83" }, // 🍃
    .{ .name = "lebanon", .emoji = "\xf0\x9f\x87\xb1\xf0\x9f\x87\xa7" }, // 🇱🇧
    .{ .name = "ledger", .emoji = "\xf0\x9f\x93\x92" }, // 📒
    .{ .name = "left_luggage", .emoji = "\xf0\x9f\x9b\x85" }, // 🛅
    .{ .name = "left_right_arrow", .emoji = "\xe2\x86\x94" }, // ↔
    .{ .name = "left_speech_bubble", .emoji = "\xf0\x9f\x97\xa8" }, // 🗨
    .{ .name = "leftwards_arrow_with_hook", .emoji = "\xe2\x86\xa9" }, // ↩
    .{ .name = "leftwards_hand", .emoji = "\xf0\x9f\xab\xb2" }, // 🫲
    .{ .name = "leftwards_pushing_hand", .emoji = "\xf0\x9f\xab\xb7" }, // 🫷
    .{ .name = "leg", .emoji = "\xf0\x9f\xa6\xb5" }, // 🦵
    .{ .name = "lemon", .emoji = "\xf0\x9f\x8d\x8b" }, // 🍋
    .{ .name = "leo", .emoji = "\xe2\x99\x8c" }, // ♌
    .{ .name = "leopard", .emoji = "\xf0\x9f\x90\x86" }, // 🐆
    .{ .name = "lesotho", .emoji = "\xf0\x9f\x87\xb1\xf0\x9f\x87\xb8" }, // 🇱🇸
    .{ .name = "level_slider", .emoji = "\xf0\x9f\x8e\x9a" }, // 🎚
    .{ .name = "liberia", .emoji = "\xf0\x9f\x87\xb1\xf0\x9f\x87\xb7" }, // 🇱🇷
    .{ .name = "libra", .emoji = "\xe2\x99\x8e" }, // ♎
    .{ .name = "libya", .emoji = "\xf0\x9f\x87\xb1\xf0\x9f\x87\xbe" }, // 🇱🇾
    .{ .name = "liechtenstein", .emoji = "\xf0\x9f\x87\xb1\xf0\x9f\x87\xae" }, // 🇱🇮
    .{ .name = "light_blue_heart", .emoji = "\xf0\x9f\xa9\xb5" }, // 🩵
    .{ .name = "light_rail", .emoji = "\xf0\x9f\x9a\x88" }, // 🚈
    .{ .name = "link", .emoji = "\xf0\x9f\x94\x97" }, // 🔗
    .{ .name = "lion", .emoji = "\xf0\x9f\xa6\x81" }, // 🦁
    .{ .name = "lips", .emoji = "\xf0\x9f\x91\x84" }, // 👄
    .{ .name = "lipstick", .emoji = "\xf0\x9f\x92\x84" }, // 💄
    .{ .name = "lithuania", .emoji = "\xf0\x9f\x87\xb1\xf0\x9f\x87\xb9" }, // 🇱🇹
    .{ .name = "lizard", .emoji = "\xf0\x9f\xa6\x8e" }, // 🦎
    .{ .name = "llama", .emoji = "\xf0\x9f\xa6\x99" }, // 🦙
    .{ .name = "lobster", .emoji = "\xf0\x9f\xa6\x9e" }, // 🦞
    .{ .name = "lock", .emoji = "\xf0\x9f\x94\x92" }, // 🔒
    .{ .name = "lock_with_ink_pen", .emoji = "\xf0\x9f\x94\x8f" }, // 🔏
    .{ .name = "lollipop", .emoji = "\xf0\x9f\x8d\xad" }, // 🍭
    .{ .name = "long_drum", .emoji = "\xf0\x9f\xaa\x98" }, // 🪘
    .{ .name = "loop", .emoji = "\xe2\x9e\xbf" }, // ➿
    .{ .name = "lotion_bottle", .emoji = "\xf0\x9f\xa7\xb4" }, // 🧴
    .{ .name = "lotus", .emoji = "\xf0\x9f\xaa\xb7" }, // 🪷
    .{ .name = "lotus_position", .emoji = "\xf0\x9f\xa7\x98" }, // 🧘
    .{ .name = "lotus_position_man", .emoji = "\xf0\x9f\xa7\x98\xe2\x99\x82" }, // 🧘♂
    .{ .name = "lotus_position_woman", .emoji = "\xf0\x9f\xa7\x98\xe2\x99\x80" }, // 🧘♀
    .{ .name = "loud_sound", .emoji = "\xf0\x9f\x94\x8a" }, // 🔊
    .{ .name = "loudspeaker", .emoji = "\xf0\x9f\x93\xa2" }, // 📢
    .{ .name = "love_hotel", .emoji = "\xf0\x9f\x8f\xa9" }, // 🏩
    .{ .name = "love_letter", .emoji = "\xf0\x9f\x92\x8c" }, // 💌
    .{ .name = "love_you_gesture", .emoji = "\xf0\x9f\xa4\x9f" }, // 🤟
    .{ .name = "low_battery", .emoji = "\xf0\x9f\xaa\xab" }, // 🪫
    .{ .name = "low_brightness", .emoji = "\xf0\x9f\x94\x85" }, // 🔅
    .{ .name = "luggage", .emoji = "\xf0\x9f\xa7\xb3" }, // 🧳
    .{ .name = "lungs", .emoji = "\xf0\x9f\xab\x81" }, // 🫁
    .{ .name = "luxembourg", .emoji = "\xf0\x9f\x87\xb1\xf0\x9f\x87\xba" }, // 🇱🇺
    .{ .name = "lying_face", .emoji = "\xf0\x9f\xa4\xa5" }, // 🤥
    .{ .name = "m", .emoji = "\xe2\x93\x82" }, // Ⓜ
    .{ .name = "macau", .emoji = "\xf0\x9f\x87\xb2\xf0\x9f\x87\xb4" }, // 🇲🇴
    .{ .name = "macedonia", .emoji = "\xf0\x9f\x87\xb2\xf0\x9f\x87\xb0" }, // 🇲🇰
    .{ .name = "madagascar", .emoji = "\xf0\x9f\x87\xb2\xf0\x9f\x87\xac" }, // 🇲🇬
    .{ .name = "mag", .emoji = "\xf0\x9f\x94\x8d" }, // 🔍
    .{ .name = "mag_right", .emoji = "\xf0\x9f\x94\x8e" }, // 🔎
    .{ .name = "mage", .emoji = "\xf0\x9f\xa7\x99" }, // 🧙
    .{ .name = "mage_man", .emoji = "\xf0\x9f\xa7\x99\xe2\x99\x82" }, // 🧙♂
    .{ .name = "mage_woman", .emoji = "\xf0\x9f\xa7\x99\xe2\x99\x80" }, // 🧙♀
    .{ .name = "magic_wand", .emoji = "\xf0\x9f\xaa\x84" }, // 🪄
    .{ .name = "magnet", .emoji = "\xf0\x9f\xa7\xb2" }, // 🧲
    .{ .name = "mahjong", .emoji = "\xf0\x9f\x80\x84" }, // 🀄
    .{ .name = "mailbox", .emoji = "\xf0\x9f\x93\xab" }, // 📫
    .{ .name = "mailbox_closed", .emoji = "\xf0\x9f\x93\xaa" }, // 📪
    .{ .name = "mailbox_with_mail", .emoji = "\xf0\x9f\x93\xac" }, // 📬
    .{ .name = "mailbox_with_no_mail", .emoji = "\xf0\x9f\x93\xad" }, // 📭
    .{ .name = "malawi", .emoji = "\xf0\x9f\x87\xb2\xf0\x9f\x87\xbc" }, // 🇲🇼
    .{ .name = "malaysia", .emoji = "\xf0\x9f\x87\xb2\xf0\x9f\x87\xbe" }, // 🇲🇾
    .{ .name = "maldives", .emoji = "\xf0\x9f\x87\xb2\xf0\x9f\x87\xbb" }, // 🇲🇻
    .{ .name = "male_detective", .emoji = "\xf0\x9f\x95\xb5\xe2\x99\x82" }, // 🕵♂
    .{ .name = "male_sign", .emoji = "\xe2\x99\x82" }, // ♂
    .{ .name = "mali", .emoji = "\xf0\x9f\x87\xb2\xf0\x9f\x87\xb1" }, // 🇲🇱
    .{ .name = "malta", .emoji = "\xf0\x9f\x87\xb2\xf0\x9f\x87\xb9" }, // 🇲🇹
    .{ .name = "mammoth", .emoji = "\xf0\x9f\xa6\xa3" }, // 🦣
    .{ .name = "man", .emoji = "\xf0\x9f\x91\xa8" }, // 👨
    .{ .name = "man_artist", .emoji = "\xf0\x9f\x91\xa8\xf0\x9f\x8e\xa8" }, // 👨🎨
    .{ .name = "man_astronaut", .emoji = "\xf0\x9f\x91\xa8\xf0\x9f\x9a\x80" }, // 👨🚀
    .{ .name = "man_beard", .emoji = "\xf0\x9f\xa7\x94\xe2\x99\x82" }, // 🧔♂
    .{ .name = "man_cartwheeling", .emoji = "\xf0\x9f\xa4\xb8\xe2\x99\x82" }, // 🤸♂
    .{ .name = "man_cook", .emoji = "\xf0\x9f\x91\xa8\xf0\x9f\x8d\xb3" }, // 👨🍳
    .{ .name = "man_dancing", .emoji = "\xf0\x9f\x95\xba" }, // 🕺
    .{ .name = "man_facepalming", .emoji = "\xf0\x9f\xa4\xa6\xe2\x99\x82" }, // 🤦♂
    .{ .name = "man_factory_worker", .emoji = "\xf0\x9f\x91\xa8\xf0\x9f\x8f\xad" }, // 👨🏭
    .{ .name = "man_farmer", .emoji = "\xf0\x9f\x91\xa8\xf0\x9f\x8c\xbe" }, // 👨🌾
    .{ .name = "man_feeding_baby", .emoji = "\xf0\x9f\x91\xa8\xf0\x9f\x8d\xbc" }, // 👨🍼
    .{ .name = "man_firefighter", .emoji = "\xf0\x9f\x91\xa8\xf0\x9f\x9a\x92" }, // 👨🚒
    .{ .name = "man_health_worker", .emoji = "\xf0\x9f\x91\xa8\xe2\x9a\x95" }, // 👨⚕
    .{ .name = "man_in_manual_wheelchair", .emoji = "\xf0\x9f\x91\xa8\xf0\x9f\xa6\xbd" }, // 👨🦽
    .{ .name = "man_in_motorized_wheelchair", .emoji = "\xf0\x9f\x91\xa8\xf0\x9f\xa6\xbc" }, // 👨🦼
    .{ .name = "man_in_tuxedo", .emoji = "\xf0\x9f\xa4\xb5\xe2\x99\x82" }, // 🤵♂
    .{ .name = "man_judge", .emoji = "\xf0\x9f\x91\xa8\xe2\x9a\x96" }, // 👨⚖
    .{ .name = "man_juggling", .emoji = "\xf0\x9f\xa4\xb9\xe2\x99\x82" }, // 🤹♂
    .{ .name = "man_mechanic", .emoji = "\xf0\x9f\x91\xa8\xf0\x9f\x94\xa7" }, // 👨🔧
    .{ .name = "man_office_worker", .emoji = "\xf0\x9f\x91\xa8\xf0\x9f\x92\xbc" }, // 👨💼
    .{ .name = "man_pilot", .emoji = "\xf0\x9f\x91\xa8\xe2\x9c\x88" }, // 👨✈
    .{ .name = "man_playing_handball", .emoji = "\xf0\x9f\xa4\xbe\xe2\x99\x82" }, // 🤾♂
    .{ .name = "man_playing_water_polo", .emoji = "\xf0\x9f\xa4\xbd\xe2\x99\x82" }, // 🤽♂
    .{ .name = "man_scientist", .emoji = "\xf0\x9f\x91\xa8\xf0\x9f\x94\xac" }, // 👨🔬
    .{ .name = "man_shrugging", .emoji = "\xf0\x9f\xa4\xb7\xe2\x99\x82" }, // 🤷♂
    .{ .name = "man_singer", .emoji = "\xf0\x9f\x91\xa8\xf0\x9f\x8e\xa4" }, // 👨🎤
    .{ .name = "man_student", .emoji = "\xf0\x9f\x91\xa8\xf0\x9f\x8e\x93" }, // 👨🎓
    .{ .name = "man_teacher", .emoji = "\xf0\x9f\x91\xa8\xf0\x9f\x8f\xab" }, // 👨🏫
    .{ .name = "man_technologist", .emoji = "\xf0\x9f\x91\xa8\xf0\x9f\x92\xbb" }, // 👨💻
    .{ .name = "man_with_gua_pi_mao", .emoji = "\xf0\x9f\x91\xb2" }, // 👲
    .{ .name = "man_with_probing_cane", .emoji = "\xf0\x9f\x91\xa8\xf0\x9f\xa6\xaf" }, // 👨🦯
    .{ .name = "man_with_turban", .emoji = "\xf0\x9f\x91\xb3\xe2\x99\x82" }, // 👳♂
    .{ .name = "man_with_veil", .emoji = "\xf0\x9f\x91\xb0\xe2\x99\x82" }, // 👰♂
    .{ .name = "mandarin", .emoji = "\xf0\x9f\x8d\x8a" }, // 🍊
    .{ .name = "mango", .emoji = "\xf0\x9f\xa5\xad" }, // 🥭
    .{ .name = "mans_shoe", .emoji = "\xf0\x9f\x91\x9e" }, // 👞
    .{ .name = "mantelpiece_clock", .emoji = "\xf0\x9f\x95\xb0" }, // 🕰
    .{ .name = "manual_wheelchair", .emoji = "\xf0\x9f\xa6\xbd" }, // 🦽
    .{ .name = "maple_leaf", .emoji = "\xf0\x9f\x8d\x81" }, // 🍁
    .{ .name = "maracas", .emoji = "\xf0\x9f\xaa\x87" }, // 🪇
    .{ .name = "marshall_islands", .emoji = "\xf0\x9f\x87\xb2\xf0\x9f\x87\xad" }, // 🇲🇭
    .{ .name = "martial_arts_uniform", .emoji = "\xf0\x9f\xa5\x8b" }, // 🥋
    .{ .name = "martinique", .emoji = "\xf0\x9f\x87\xb2\xf0\x9f\x87\xb6" }, // 🇲🇶
    .{ .name = "mask", .emoji = "\xf0\x9f\x98\xb7" }, // 😷
    .{ .name = "massage", .emoji = "\xf0\x9f\x92\x86" }, // 💆
    .{ .name = "massage_man", .emoji = "\xf0\x9f\x92\x86\xe2\x99\x82" }, // 💆♂
    .{ .name = "massage_woman", .emoji = "\xf0\x9f\x92\x86\xe2\x99\x80" }, // 💆♀
    .{ .name = "mate", .emoji = "\xf0\x9f\xa7\x89" }, // 🧉
    .{ .name = "mauritania", .emoji = "\xf0\x9f\x87\xb2\xf0\x9f\x87\xb7" }, // 🇲🇷
    .{ .name = "mauritius", .emoji = "\xf0\x9f\x87\xb2\xf0\x9f\x87\xba" }, // 🇲🇺
    .{ .name = "mayotte", .emoji = "\xf0\x9f\x87\xbe\xf0\x9f\x87\xb9" }, // 🇾🇹
    .{ .name = "meat_on_bone", .emoji = "\xf0\x9f\x8d\x96" }, // 🍖
    .{ .name = "mechanic", .emoji = "\xf0\x9f\xa7\x91\xf0\x9f\x94\xa7" }, // 🧑🔧
    .{ .name = "mechanical_arm", .emoji = "\xf0\x9f\xa6\xbe" }, // 🦾
    .{ .name = "mechanical_leg", .emoji = "\xf0\x9f\xa6\xbf" }, // 🦿
    .{ .name = "medal_military", .emoji = "\xf0\x9f\x8e\x96" }, // 🎖
    .{ .name = "medal_sports", .emoji = "\xf0\x9f\x8f\x85" }, // 🏅
    .{ .name = "medical_symbol", .emoji = "\xe2\x9a\x95" }, // ⚕
    .{ .name = "mega", .emoji = "\xf0\x9f\x93\xa3" }, // 📣
    .{ .name = "melon", .emoji = "\xf0\x9f\x8d\x88" }, // 🍈
    .{ .name = "melting_face", .emoji = "\xf0\x9f\xab\xa0" }, // 🫠
    .{ .name = "memo", .emoji = "\xf0\x9f\x93\x9d" }, // 📝
    .{ .name = "men_wrestling", .emoji = "\xf0\x9f\xa4\xbc\xe2\x99\x82" }, // 🤼♂
    .{ .name = "mending_heart", .emoji = "\xe2\x9d\xa4\xf0\x9f\xa9\xb9" }, // ❤🩹
    .{ .name = "menorah", .emoji = "\xf0\x9f\x95\x8e" }, // 🕎
    .{ .name = "mens", .emoji = "\xf0\x9f\x9a\xb9" }, // 🚹
    .{ .name = "mermaid", .emoji = "\xf0\x9f\xa7\x9c\xe2\x99\x80" }, // 🧜♀
    .{ .name = "merman", .emoji = "\xf0\x9f\xa7\x9c\xe2\x99\x82" }, // 🧜♂
    .{ .name = "merperson", .emoji = "\xf0\x9f\xa7\x9c" }, // 🧜
    .{ .name = "metal", .emoji = "\xf0\x9f\xa4\x98" }, // 🤘
    .{ .name = "metro", .emoji = "\xf0\x9f\x9a\x87" }, // 🚇
    .{ .name = "mexico", .emoji = "\xf0\x9f\x87\xb2\xf0\x9f\x87\xbd" }, // 🇲🇽
    .{ .name = "microbe", .emoji = "\xf0\x9f\xa6\xa0" }, // 🦠
    .{ .name = "micronesia", .emoji = "\xf0\x9f\x87\xab\xf0\x9f\x87\xb2" }, // 🇫🇲
    .{ .name = "microphone", .emoji = "\xf0\x9f\x8e\xa4" }, // 🎤
    .{ .name = "microscope", .emoji = "\xf0\x9f\x94\xac" }, // 🔬
    .{ .name = "middle_finger", .emoji = "\xf0\x9f\x96\x95" }, // 🖕
    .{ .name = "military_helmet", .emoji = "\xf0\x9f\xaa\x96" }, // 🪖
    .{ .name = "milk_glass", .emoji = "\xf0\x9f\xa5\x9b" }, // 🥛
    .{ .name = "milky_way", .emoji = "\xf0\x9f\x8c\x8c" }, // 🌌
    .{ .name = "minibus", .emoji = "\xf0\x9f\x9a\x90" }, // 🚐
    .{ .name = "minidisc", .emoji = "\xf0\x9f\x92\xbd" }, // 💽
    .{ .name = "mirror", .emoji = "\xf0\x9f\xaa\x9e" }, // 🪞
    .{ .name = "mirror_ball", .emoji = "\xf0\x9f\xaa\xa9" }, // 🪩
    .{ .name = "mobile_phone_off", .emoji = "\xf0\x9f\x93\xb4" }, // 📴
    .{ .name = "moldova", .emoji = "\xf0\x9f\x87\xb2\xf0\x9f\x87\xa9" }, // 🇲🇩
    .{ .name = "monaco", .emoji = "\xf0\x9f\x87\xb2\xf0\x9f\x87\xa8" }, // 🇲🇨
    .{ .name = "money_mouth_face", .emoji = "\xf0\x9f\xa4\x91" }, // 🤑
    .{ .name = "money_with_wings", .emoji = "\xf0\x9f\x92\xb8" }, // 💸
    .{ .name = "moneybag", .emoji = "\xf0\x9f\x92\xb0" }, // 💰
    .{ .name = "mongolia", .emoji = "\xf0\x9f\x87\xb2\xf0\x9f\x87\xb3" }, // 🇲🇳
    .{ .name = "monkey", .emoji = "\xf0\x9f\x90\x92" }, // 🐒
    .{ .name = "monkey_face", .emoji = "\xf0\x9f\x90\xb5" }, // 🐵
    .{ .name = "monocle_face", .emoji = "\xf0\x9f\xa7\x90" }, // 🧐
    .{ .name = "monorail", .emoji = "\xf0\x9f\x9a\x9d" }, // 🚝
    .{ .name = "montenegro", .emoji = "\xf0\x9f\x87\xb2\xf0\x9f\x87\xaa" }, // 🇲🇪
    .{ .name = "montserrat", .emoji = "\xf0\x9f\x87\xb2\xf0\x9f\x87\xb8" }, // 🇲🇸
    .{ .name = "moon", .emoji = "\xf0\x9f\x8c\x94" }, // 🌔
    .{ .name = "moon_cake", .emoji = "\xf0\x9f\xa5\xae" }, // 🥮
    .{ .name = "moose", .emoji = "\xf0\x9f\xab\x8e" }, // 🫎
    .{ .name = "morocco", .emoji = "\xf0\x9f\x87\xb2\xf0\x9f\x87\xa6" }, // 🇲🇦
    .{ .name = "mortar_board", .emoji = "\xf0\x9f\x8e\x93" }, // 🎓
    .{ .name = "mosque", .emoji = "\xf0\x9f\x95\x8c" }, // 🕌
    .{ .name = "mosquito", .emoji = "\xf0\x9f\xa6\x9f" }, // 🦟
    .{ .name = "motor_boat", .emoji = "\xf0\x9f\x9b\xa5" }, // 🛥
    .{ .name = "motor_scooter", .emoji = "\xf0\x9f\x9b\xb5" }, // 🛵
    .{ .name = "motorcycle", .emoji = "\xf0\x9f\x8f\x8d" }, // 🏍
    .{ .name = "motorized_wheelchair", .emoji = "\xf0\x9f\xa6\xbc" }, // 🦼
    .{ .name = "motorway", .emoji = "\xf0\x9f\x9b\xa3" }, // 🛣
    .{ .name = "mount_fuji", .emoji = "\xf0\x9f\x97\xbb" }, // 🗻
    .{ .name = "mountain", .emoji = "\xe2\x9b\xb0" }, // ⛰
    .{ .name = "mountain_bicyclist", .emoji = "\xf0\x9f\x9a\xb5" }, // 🚵
    .{ .name = "mountain_biking_man", .emoji = "\xf0\x9f\x9a\xb5\xe2\x99\x82" }, // 🚵♂
    .{ .name = "mountain_biking_woman", .emoji = "\xf0\x9f\x9a\xb5\xe2\x99\x80" }, // 🚵♀
    .{ .name = "mountain_cableway", .emoji = "\xf0\x9f\x9a\xa0" }, // 🚠
    .{ .name = "mountain_railway", .emoji = "\xf0\x9f\x9a\x9e" }, // 🚞
    .{ .name = "mountain_snow", .emoji = "\xf0\x9f\x8f\x94" }, // 🏔
    .{ .name = "mouse", .emoji = "\xf0\x9f\x90\xad" }, // 🐭
    .{ .name = "mouse2", .emoji = "\xf0\x9f\x90\x81" }, // 🐁
    .{ .name = "mouse_trap", .emoji = "\xf0\x9f\xaa\xa4" }, // 🪤
    .{ .name = "movie_camera", .emoji = "\xf0\x9f\x8e\xa5" }, // 🎥
    .{ .name = "moyai", .emoji = "\xf0\x9f\x97\xbf" }, // 🗿
    .{ .name = "mozambique", .emoji = "\xf0\x9f\x87\xb2\xf0\x9f\x87\xbf" }, // 🇲🇿
    .{ .name = "mrs_claus", .emoji = "\xf0\x9f\xa4\xb6" }, // 🤶
    .{ .name = "muscle", .emoji = "\xf0\x9f\x92\xaa" }, // 💪
    .{ .name = "mushroom", .emoji = "\xf0\x9f\x8d\x84" }, // 🍄
    .{ .name = "musical_keyboard", .emoji = "\xf0\x9f\x8e\xb9" }, // 🎹
    .{ .name = "musical_note", .emoji = "\xf0\x9f\x8e\xb5" }, // 🎵
    .{ .name = "musical_score", .emoji = "\xf0\x9f\x8e\xbc" }, // 🎼
    .{ .name = "mute", .emoji = "\xf0\x9f\x94\x87" }, // 🔇
    .{ .name = "mx_claus", .emoji = "\xf0\x9f\xa7\x91\xf0\x9f\x8e\x84" }, // 🧑🎄
    .{ .name = "myanmar", .emoji = "\xf0\x9f\x87\xb2\xf0\x9f\x87\xb2" }, // 🇲🇲
    .{ .name = "nail_care", .emoji = "\xf0\x9f\x92\x85" }, // 💅
    .{ .name = "name_badge", .emoji = "\xf0\x9f\x93\x9b" }, // 📛
    .{ .name = "namibia", .emoji = "\xf0\x9f\x87\xb3\xf0\x9f\x87\xa6" }, // 🇳🇦
    .{ .name = "national_park", .emoji = "\xf0\x9f\x8f\x9e" }, // 🏞
    .{ .name = "nauru", .emoji = "\xf0\x9f\x87\xb3\xf0\x9f\x87\xb7" }, // 🇳🇷
    .{ .name = "nauseated_face", .emoji = "\xf0\x9f\xa4\xa2" }, // 🤢
    .{ .name = "nazar_amulet", .emoji = "\xf0\x9f\xa7\xbf" }, // 🧿
    .{ .name = "necktie", .emoji = "\xf0\x9f\x91\x94" }, // 👔
    .{ .name = "negative_squared_cross_mark", .emoji = "\xe2\x9d\x8e" }, // ❎
    .{ .name = "nepal", .emoji = "\xf0\x9f\x87\xb3\xf0\x9f\x87\xb5" }, // 🇳🇵
    .{ .name = "nerd_face", .emoji = "\xf0\x9f\xa4\x93" }, // 🤓
    .{ .name = "nest_with_eggs", .emoji = "\xf0\x9f\xaa\xba" }, // 🪺
    .{ .name = "nesting_dolls", .emoji = "\xf0\x9f\xaa\x86" }, // 🪆
    .{ .name = "netherlands", .emoji = "\xf0\x9f\x87\xb3\xf0\x9f\x87\xb1" }, // 🇳🇱
    .{ .name = "neutral_face", .emoji = "\xf0\x9f\x98\x90" }, // 😐
    .{ .name = "new", .emoji = "\xf0\x9f\x86\x95" }, // 🆕
    .{ .name = "new_caledonia", .emoji = "\xf0\x9f\x87\xb3\xf0\x9f\x87\xa8" }, // 🇳🇨
    .{ .name = "new_moon", .emoji = "\xf0\x9f\x8c\x91" }, // 🌑
    .{ .name = "new_moon_with_face", .emoji = "\xf0\x9f\x8c\x9a" }, // 🌚
    .{ .name = "new_zealand", .emoji = "\xf0\x9f\x87\xb3\xf0\x9f\x87\xbf" }, // 🇳🇿
    .{ .name = "newspaper", .emoji = "\xf0\x9f\x93\xb0" }, // 📰
    .{ .name = "newspaper_roll", .emoji = "\xf0\x9f\x97\x9e" }, // 🗞
    .{ .name = "next_track_button", .emoji = "\xe2\x8f\xad" }, // ⏭
    .{ .name = "ng", .emoji = "\xf0\x9f\x86\x96" }, // 🆖
    .{ .name = "ng_man", .emoji = "\xf0\x9f\x99\x85\xe2\x99\x82" }, // 🙅♂
    .{ .name = "ng_woman", .emoji = "\xf0\x9f\x99\x85\xe2\x99\x80" }, // 🙅♀
    .{ .name = "nicaragua", .emoji = "\xf0\x9f\x87\xb3\xf0\x9f\x87\xae" }, // 🇳🇮
    .{ .name = "niger", .emoji = "\xf0\x9f\x87\xb3\xf0\x9f\x87\xaa" }, // 🇳🇪
    .{ .name = "nigeria", .emoji = "\xf0\x9f\x87\xb3\xf0\x9f\x87\xac" }, // 🇳🇬
    .{ .name = "night_with_stars", .emoji = "\xf0\x9f\x8c\x83" }, // 🌃
    .{ .name = "nine", .emoji = "\x39\xe2\x83\xa3" }, // 9⃣
    .{ .name = "ninja", .emoji = "\xf0\x9f\xa5\xb7" }, // 🥷
    .{ .name = "niue", .emoji = "\xf0\x9f\x87\xb3\xf0\x9f\x87\xba" }, // 🇳🇺
    .{ .name = "no_bell", .emoji = "\xf0\x9f\x94\x95" }, // 🔕
    .{ .name = "no_bicycles", .emoji = "\xf0\x9f\x9a\xb3" }, // 🚳
    .{ .name = "no_entry", .emoji = "\xe2\x9b\x94" }, // ⛔
    .{ .name = "no_entry_sign", .emoji = "\xf0\x9f\x9a\xab" }, // 🚫
    .{ .name = "no_good", .emoji = "\xf0\x9f\x99\x85" }, // 🙅
    .{ .name = "no_good_man", .emoji = "\xf0\x9f\x99\x85\xe2\x99\x82" }, // 🙅♂
    .{ .name = "no_good_woman", .emoji = "\xf0\x9f\x99\x85\xe2\x99\x80" }, // 🙅♀
    .{ .name = "no_mobile_phones", .emoji = "\xf0\x9f\x93\xb5" }, // 📵
    .{ .name = "no_mouth", .emoji = "\xf0\x9f\x98\xb6" }, // 😶
    .{ .name = "no_pedestrians", .emoji = "\xf0\x9f\x9a\xb7" }, // 🚷
    .{ .name = "no_smoking", .emoji = "\xf0\x9f\x9a\xad" }, // 🚭
    .{ .name = "non-potable_water", .emoji = "\xf0\x9f\x9a\xb1" }, // 🚱
    .{ .name = "norfolk_island", .emoji = "\xf0\x9f\x87\xb3\xf0\x9f\x87\xab" }, // 🇳🇫
    .{ .name = "north_korea", .emoji = "\xf0\x9f\x87\xb0\xf0\x9f\x87\xb5" }, // 🇰🇵
    .{ .name = "northern_mariana_islands", .emoji = "\xf0\x9f\x87\xb2\xf0\x9f\x87\xb5" }, // 🇲🇵
    .{ .name = "norway", .emoji = "\xf0\x9f\x87\xb3\xf0\x9f\x87\xb4" }, // 🇳🇴
    .{ .name = "nose", .emoji = "\xf0\x9f\x91\x83" }, // 👃
    .{ .name = "notebook", .emoji = "\xf0\x9f\x93\x93" }, // 📓
    .{ .name = "notebook_with_decorative_cover", .emoji = "\xf0\x9f\x93\x94" }, // 📔
    .{ .name = "notes", .emoji = "\xf0\x9f\x8e\xb6" }, // 🎶
    .{ .name = "nut_and_bolt", .emoji = "\xf0\x9f\x94\xa9" }, // 🔩
    .{ .name = "o", .emoji = "\xe2\xad\x95" }, // ⭕
    .{ .name = "o2", .emoji = "\xf0\x9f\x85\xbe" }, // 🅾
    .{ .name = "ocean", .emoji = "\xf0\x9f\x8c\x8a" }, // 🌊
    .{ .name = "octopus", .emoji = "\xf0\x9f\x90\x99" }, // 🐙
    .{ .name = "oden", .emoji = "\xf0\x9f\x8d\xa2" }, // 🍢
    .{ .name = "office", .emoji = "\xf0\x9f\x8f\xa2" }, // 🏢
    .{ .name = "office_worker", .emoji = "\xf0\x9f\xa7\x91\xf0\x9f\x92\xbc" }, // 🧑💼
    .{ .name = "oil_drum", .emoji = "\xf0\x9f\x9b\xa2" }, // 🛢
    .{ .name = "ok", .emoji = "\xf0\x9f\x86\x97" }, // 🆗
    .{ .name = "ok_hand", .emoji = "\xf0\x9f\x91\x8c" }, // 👌
    .{ .name = "ok_man", .emoji = "\xf0\x9f\x99\x86\xe2\x99\x82" }, // 🙆♂
    .{ .name = "ok_person", .emoji = "\xf0\x9f\x99\x86" }, // 🙆
    .{ .name = "ok_woman", .emoji = "\xf0\x9f\x99\x86\xe2\x99\x80" }, // 🙆♀
    .{ .name = "old_key", .emoji = "\xf0\x9f\x97\x9d" }, // 🗝
    .{ .name = "older_adult", .emoji = "\xf0\x9f\xa7\x93" }, // 🧓
    .{ .name = "older_man", .emoji = "\xf0\x9f\x91\xb4" }, // 👴
    .{ .name = "older_woman", .emoji = "\xf0\x9f\x91\xb5" }, // 👵
    .{ .name = "olive", .emoji = "\xf0\x9f\xab\x92" }, // 🫒
    .{ .name = "om", .emoji = "\xf0\x9f\x95\x89" }, // 🕉
    .{ .name = "oman", .emoji = "\xf0\x9f\x87\xb4\xf0\x9f\x87\xb2" }, // 🇴🇲
    .{ .name = "on", .emoji = "\xf0\x9f\x94\x9b" }, // 🔛
    .{ .name = "oncoming_automobile", .emoji = "\xf0\x9f\x9a\x98" }, // 🚘
    .{ .name = "oncoming_bus", .emoji = "\xf0\x9f\x9a\x8d" }, // 🚍
    .{ .name = "oncoming_police_car", .emoji = "\xf0\x9f\x9a\x94" }, // 🚔
    .{ .name = "oncoming_taxi", .emoji = "\xf0\x9f\x9a\x96" }, // 🚖
    .{ .name = "one", .emoji = "\x31\xe2\x83\xa3" }, // 1⃣
    .{ .name = "one_piece_swimsuit", .emoji = "\xf0\x9f\xa9\xb1" }, // 🩱
    .{ .name = "onion", .emoji = "\xf0\x9f\xa7\x85" }, // 🧅
    .{ .name = "open_book", .emoji = "\xf0\x9f\x93\x96" }, // 📖
    .{ .name = "open_file_folder", .emoji = "\xf0\x9f\x93\x82" }, // 📂
    .{ .name = "open_hands", .emoji = "\xf0\x9f\x91\x90" }, // 👐
    .{ .name = "open_mouth", .emoji = "\xf0\x9f\x98\xae" }, // 😮
    .{ .name = "open_umbrella", .emoji = "\xe2\x98\x82" }, // ☂
    .{ .name = "ophiuchus", .emoji = "\xe2\x9b\x8e" }, // ⛎
    .{ .name = "orange", .emoji = "\xf0\x9f\x8d\x8a" }, // 🍊
    .{ .name = "orange_book", .emoji = "\xf0\x9f\x93\x99" }, // 📙
    .{ .name = "orange_circle", .emoji = "\xf0\x9f\x9f\xa0" }, // 🟠
    .{ .name = "orange_heart", .emoji = "\xf0\x9f\xa7\xa1" }, // 🧡
    .{ .name = "orange_square", .emoji = "\xf0\x9f\x9f\xa7" }, // 🟧
    .{ .name = "orangutan", .emoji = "\xf0\x9f\xa6\xa7" }, // 🦧
    .{ .name = "orthodox_cross", .emoji = "\xe2\x98\xa6" }, // ☦
    .{ .name = "otter", .emoji = "\xf0\x9f\xa6\xa6" }, // 🦦
    .{ .name = "outbox_tray", .emoji = "\xf0\x9f\x93\xa4" }, // 📤
    .{ .name = "owl", .emoji = "\xf0\x9f\xa6\x89" }, // 🦉
    .{ .name = "ox", .emoji = "\xf0\x9f\x90\x82" }, // 🐂
    .{ .name = "oyster", .emoji = "\xf0\x9f\xa6\xaa" }, // 🦪
    .{ .name = "package", .emoji = "\xf0\x9f\x93\xa6" }, // 📦
    .{ .name = "page_facing_up", .emoji = "\xf0\x9f\x93\x84" }, // 📄
    .{ .name = "page_with_curl", .emoji = "\xf0\x9f\x93\x83" }, // 📃
    .{ .name = "pager", .emoji = "\xf0\x9f\x93\x9f" }, // 📟
    .{ .name = "paintbrush", .emoji = "\xf0\x9f\x96\x8c" }, // 🖌
    .{ .name = "pakistan", .emoji = "\xf0\x9f\x87\xb5\xf0\x9f\x87\xb0" }, // 🇵🇰
    .{ .name = "palau", .emoji = "\xf0\x9f\x87\xb5\xf0\x9f\x87\xbc" }, // 🇵🇼
    .{ .name = "palestinian_territories", .emoji = "\xf0\x9f\x87\xb5\xf0\x9f\x87\xb8" }, // 🇵🇸
    .{ .name = "palm_down_hand", .emoji = "\xf0\x9f\xab\xb3" }, // 🫳
    .{ .name = "palm_tree", .emoji = "\xf0\x9f\x8c\xb4" }, // 🌴
    .{ .name = "palm_up_hand", .emoji = "\xf0\x9f\xab\xb4" }, // 🫴
    .{ .name = "palms_up_together", .emoji = "\xf0\x9f\xa4\xb2" }, // 🤲
    .{ .name = "panama", .emoji = "\xf0\x9f\x87\xb5\xf0\x9f\x87\xa6" }, // 🇵🇦
    .{ .name = "pancakes", .emoji = "\xf0\x9f\xa5\x9e" }, // 🥞
    .{ .name = "panda_face", .emoji = "\xf0\x9f\x90\xbc" }, // 🐼
    .{ .name = "paperclip", .emoji = "\xf0\x9f\x93\x8e" }, // 📎
    .{ .name = "paperclips", .emoji = "\xf0\x9f\x96\x87" }, // 🖇
    .{ .name = "papua_new_guinea", .emoji = "\xf0\x9f\x87\xb5\xf0\x9f\x87\xac" }, // 🇵🇬
    .{ .name = "parachute", .emoji = "\xf0\x9f\xaa\x82" }, // 🪂
    .{ .name = "paraguay", .emoji = "\xf0\x9f\x87\xb5\xf0\x9f\x87\xbe" }, // 🇵🇾
    .{ .name = "parasol_on_ground", .emoji = "\xe2\x9b\xb1" }, // ⛱
    .{ .name = "parking", .emoji = "\xf0\x9f\x85\xbf" }, // 🅿
    .{ .name = "parrot", .emoji = "\xf0\x9f\xa6\x9c" }, // 🦜
    .{ .name = "part_alternation_mark", .emoji = "\xe3\x80\xbd" }, // 〽
    .{ .name = "partly_sunny", .emoji = "\xe2\x9b\x85" }, // ⛅
    .{ .name = "partying_face", .emoji = "\xf0\x9f\xa5\xb3" }, // 🥳
    .{ .name = "passenger_ship", .emoji = "\xf0\x9f\x9b\xb3" }, // 🛳
    .{ .name = "passport_control", .emoji = "\xf0\x9f\x9b\x82" }, // 🛂
    .{ .name = "pause_button", .emoji = "\xe2\x8f\xb8" }, // ⏸
    .{ .name = "paw_prints", .emoji = "\xf0\x9f\x90\xbe" }, // 🐾
    .{ .name = "pea_pod", .emoji = "\xf0\x9f\xab\x9b" }, // 🫛
    .{ .name = "peace_symbol", .emoji = "\xe2\x98\xae" }, // ☮
    .{ .name = "peach", .emoji = "\xf0\x9f\x8d\x91" }, // 🍑
    .{ .name = "peacock", .emoji = "\xf0\x9f\xa6\x9a" }, // 🦚
    .{ .name = "peanuts", .emoji = "\xf0\x9f\xa5\x9c" }, // 🥜
    .{ .name = "pear", .emoji = "\xf0\x9f\x8d\x90" }, // 🍐
    .{ .name = "pen", .emoji = "\xf0\x9f\x96\x8a" }, // 🖊
    .{ .name = "pencil", .emoji = "\xf0\x9f\x93\x9d" }, // 📝
    .{ .name = "pencil2", .emoji = "\xe2\x9c\x8f" }, // ✏
    .{ .name = "penguin", .emoji = "\xf0\x9f\x90\xa7" }, // 🐧
    .{ .name = "pensive", .emoji = "\xf0\x9f\x98\x94" }, // 😔
    .{ .name = "people_holding_hands", .emoji = "\xf0\x9f\xa7\x91\xf0\x9f\xa4\x9d\xf0\x9f\xa7\x91" }, // 🧑🤝🧑
    .{ .name = "people_hugging", .emoji = "\xf0\x9f\xab\x82" }, // 🫂
    .{ .name = "performing_arts", .emoji = "\xf0\x9f\x8e\xad" }, // 🎭
    .{ .name = "persevere", .emoji = "\xf0\x9f\x98\xa3" }, // 😣
    .{ .name = "person_bald", .emoji = "\xf0\x9f\xa7\x91\xf0\x9f\xa6\xb2" }, // 🧑🦲
    .{ .name = "person_curly_hair", .emoji = "\xf0\x9f\xa7\x91\xf0\x9f\xa6\xb1" }, // 🧑🦱
    .{ .name = "person_feeding_baby", .emoji = "\xf0\x9f\xa7\x91\xf0\x9f\x8d\xbc" }, // 🧑🍼
    .{ .name = "person_fencing", .emoji = "\xf0\x9f\xa4\xba" }, // 🤺
    .{ .name = "person_in_manual_wheelchair", .emoji = "\xf0\x9f\xa7\x91\xf0\x9f\xa6\xbd" }, // 🧑🦽
    .{ .name = "person_in_motorized_wheelchair", .emoji = "\xf0\x9f\xa7\x91\xf0\x9f\xa6\xbc" }, // 🧑🦼
    .{ .name = "person_in_tuxedo", .emoji = "\xf0\x9f\xa4\xb5" }, // 🤵
    .{ .name = "person_red_hair", .emoji = "\xf0\x9f\xa7\x91\xf0\x9f\xa6\xb0" }, // 🧑🦰
    .{ .name = "person_white_hair", .emoji = "\xf0\x9f\xa7\x91\xf0\x9f\xa6\xb3" }, // 🧑🦳
    .{ .name = "person_with_crown", .emoji = "\xf0\x9f\xab\x85" }, // 🫅
    .{ .name = "person_with_probing_cane", .emoji = "\xf0\x9f\xa7\x91\xf0\x9f\xa6\xaf" }, // 🧑🦯
    .{ .name = "person_with_turban", .emoji = "\xf0\x9f\x91\xb3" }, // 👳
    .{ .name = "person_with_veil", .emoji = "\xf0\x9f\x91\xb0" }, // 👰
    .{ .name = "peru", .emoji = "\xf0\x9f\x87\xb5\xf0\x9f\x87\xaa" }, // 🇵🇪
    .{ .name = "petri_dish", .emoji = "\xf0\x9f\xa7\xab" }, // 🧫
    .{ .name = "philippines", .emoji = "\xf0\x9f\x87\xb5\xf0\x9f\x87\xad" }, // 🇵🇭
    .{ .name = "phone", .emoji = "\xe2\x98\x8e" }, // ☎
    .{ .name = "pick", .emoji = "\xe2\x9b\x8f" }, // ⛏
    .{ .name = "pickup_truck", .emoji = "\xf0\x9f\x9b\xbb" }, // 🛻
    .{ .name = "pie", .emoji = "\xf0\x9f\xa5\xa7" }, // 🥧
    .{ .name = "pig", .emoji = "\xf0\x9f\x90\xb7" }, // 🐷
    .{ .name = "pig2", .emoji = "\xf0\x9f\x90\x96" }, // 🐖
    .{ .name = "pig_nose", .emoji = "\xf0\x9f\x90\xbd" }, // 🐽
    .{ .name = "pill", .emoji = "\xf0\x9f\x92\x8a" }, // 💊
    .{ .name = "pilot", .emoji = "\xf0\x9f\xa7\x91\xe2\x9c\x88" }, // 🧑✈
    .{ .name = "pinata", .emoji = "\xf0\x9f\xaa\x85" }, // 🪅
    .{ .name = "pinched_fingers", .emoji = "\xf0\x9f\xa4\x8c" }, // 🤌
    .{ .name = "pinching_hand", .emoji = "\xf0\x9f\xa4\x8f" }, // 🤏
    .{ .name = "pineapple", .emoji = "\xf0\x9f\x8d\x8d" }, // 🍍
    .{ .name = "ping_pong", .emoji = "\xf0\x9f\x8f\x93" }, // 🏓
    .{ .name = "pink_heart", .emoji = "\xf0\x9f\xa9\xb7" }, // 🩷
    .{ .name = "pirate_flag", .emoji = "\xf0\x9f\x8f\xb4\xe2\x98\xa0" }, // 🏴☠
    .{ .name = "pisces", .emoji = "\xe2\x99\x93" }, // ♓
    .{ .name = "pitcairn_islands", .emoji = "\xf0\x9f\x87\xb5\xf0\x9f\x87\xb3" }, // 🇵🇳
    .{ .name = "pizza", .emoji = "\xf0\x9f\x8d\x95" }, // 🍕
    .{ .name = "placard", .emoji = "\xf0\x9f\xaa\xa7" }, // 🪧
    .{ .name = "place_of_worship", .emoji = "\xf0\x9f\x9b\x90" }, // 🛐
    .{ .name = "plate_with_cutlery", .emoji = "\xf0\x9f\x8d\xbd" }, // 🍽
    .{ .name = "play_or_pause_button", .emoji = "\xe2\x8f\xaf" }, // ⏯
    .{ .name = "playground_slide", .emoji = "\xf0\x9f\x9b\x9d" }, // 🛝
    .{ .name = "pleading_face", .emoji = "\xf0\x9f\xa5\xba" }, // 🥺
    .{ .name = "plunger", .emoji = "\xf0\x9f\xaa\xa0" }, // 🪠
    .{ .name = "point_down", .emoji = "\xf0\x9f\x91\x87" }, // 👇
    .{ .name = "point_left", .emoji = "\xf0\x9f\x91\x88" }, // 👈
    .{ .name = "point_right", .emoji = "\xf0\x9f\x91\x89" }, // 👉
    .{ .name = "point_up", .emoji = "\xe2\x98\x9d" }, // ☝
    .{ .name = "point_up_2", .emoji = "\xf0\x9f\x91\x86" }, // 👆
    .{ .name = "poland", .emoji = "\xf0\x9f\x87\xb5\xf0\x9f\x87\xb1" }, // 🇵🇱
    .{ .name = "polar_bear", .emoji = "\xf0\x9f\x90\xbb\xe2\x9d\x84" }, // 🐻❄
    .{ .name = "police_car", .emoji = "\xf0\x9f\x9a\x93" }, // 🚓
    .{ .name = "police_officer", .emoji = "\xf0\x9f\x91\xae" }, // 👮
    .{ .name = "policeman", .emoji = "\xf0\x9f\x91\xae\xe2\x99\x82" }, // 👮♂
    .{ .name = "policewoman", .emoji = "\xf0\x9f\x91\xae\xe2\x99\x80" }, // 👮♀
    .{ .name = "poodle", .emoji = "\xf0\x9f\x90\xa9" }, // 🐩
    .{ .name = "poop", .emoji = "\xf0\x9f\x92\xa9" }, // 💩
    .{ .name = "popcorn", .emoji = "\xf0\x9f\x8d\xbf" }, // 🍿
    .{ .name = "portugal", .emoji = "\xf0\x9f\x87\xb5\xf0\x9f\x87\xb9" }, // 🇵🇹
    .{ .name = "post_office", .emoji = "\xf0\x9f\x8f\xa3" }, // 🏣
    .{ .name = "postal_horn", .emoji = "\xf0\x9f\x93\xaf" }, // 📯
    .{ .name = "postbox", .emoji = "\xf0\x9f\x93\xae" }, // 📮
    .{ .name = "potable_water", .emoji = "\xf0\x9f\x9a\xb0" }, // 🚰
    .{ .name = "potato", .emoji = "\xf0\x9f\xa5\x94" }, // 🥔
    .{ .name = "potted_plant", .emoji = "\xf0\x9f\xaa\xb4" }, // 🪴
    .{ .name = "pouch", .emoji = "\xf0\x9f\x91\x9d" }, // 👝
    .{ .name = "poultry_leg", .emoji = "\xf0\x9f\x8d\x97" }, // 🍗
    .{ .name = "pound", .emoji = "\xf0\x9f\x92\xb7" }, // 💷
    .{ .name = "pouring_liquid", .emoji = "\xf0\x9f\xab\x97" }, // 🫗
    .{ .name = "pout", .emoji = "\xf0\x9f\x98\xa1" }, // 😡
    .{ .name = "pouting_cat", .emoji = "\xf0\x9f\x98\xbe" }, // 😾
    .{ .name = "pouting_face", .emoji = "\xf0\x9f\x99\x8e" }, // 🙎
    .{ .name = "pouting_man", .emoji = "\xf0\x9f\x99\x8e\xe2\x99\x82" }, // 🙎♂
    .{ .name = "pouting_woman", .emoji = "\xf0\x9f\x99\x8e\xe2\x99\x80" }, // 🙎♀
    .{ .name = "pray", .emoji = "\xf0\x9f\x99\x8f" }, // 🙏
    .{ .name = "prayer_beads", .emoji = "\xf0\x9f\x93\xbf" }, // 📿
    .{ .name = "pregnant_man", .emoji = "\xf0\x9f\xab\x83" }, // 🫃
    .{ .name = "pregnant_person", .emoji = "\xf0\x9f\xab\x84" }, // 🫄
    .{ .name = "pregnant_woman", .emoji = "\xf0\x9f\xa4\xb0" }, // 🤰
    .{ .name = "pretzel", .emoji = "\xf0\x9f\xa5\xa8" }, // 🥨
    .{ .name = "previous_track_button", .emoji = "\xe2\x8f\xae" }, // ⏮
    .{ .name = "prince", .emoji = "\xf0\x9f\xa4\xb4" }, // 🤴
    .{ .name = "princess", .emoji = "\xf0\x9f\x91\xb8" }, // 👸
    .{ .name = "printer", .emoji = "\xf0\x9f\x96\xa8" }, // 🖨
    .{ .name = "probing_cane", .emoji = "\xf0\x9f\xa6\xaf" }, // 🦯
    .{ .name = "puerto_rico", .emoji = "\xf0\x9f\x87\xb5\xf0\x9f\x87\xb7" }, // 🇵🇷
    .{ .name = "punch", .emoji = "\xf0\x9f\x91\x8a" }, // 👊
    .{ .name = "purple_circle", .emoji = "\xf0\x9f\x9f\xa3" }, // 🟣
    .{ .name = "purple_heart", .emoji = "\xf0\x9f\x92\x9c" }, // 💜
    .{ .name = "purple_square", .emoji = "\xf0\x9f\x9f\xaa" }, // 🟪
    .{ .name = "purse", .emoji = "\xf0\x9f\x91\x9b" }, // 👛
    .{ .name = "pushpin", .emoji = "\xf0\x9f\x93\x8c" }, // 📌
    .{ .name = "put_litter_in_its_place", .emoji = "\xf0\x9f\x9a\xae" }, // 🚮
    .{ .name = "qatar", .emoji = "\xf0\x9f\x87\xb6\xf0\x9f\x87\xa6" }, // 🇶🇦
    .{ .name = "question", .emoji = "\xe2\x9d\x93" }, // ❓
    .{ .name = "rabbit", .emoji = "\xf0\x9f\x90\xb0" }, // 🐰
    .{ .name = "rabbit2", .emoji = "\xf0\x9f\x90\x87" }, // 🐇
    .{ .name = "raccoon", .emoji = "\xf0\x9f\xa6\x9d" }, // 🦝
    .{ .name = "racehorse", .emoji = "\xf0\x9f\x90\x8e" }, // 🐎
    .{ .name = "racing_car", .emoji = "\xf0\x9f\x8f\x8e" }, // 🏎
    .{ .name = "radio", .emoji = "\xf0\x9f\x93\xbb" }, // 📻
    .{ .name = "radio_button", .emoji = "\xf0\x9f\x94\x98" }, // 🔘
    .{ .name = "radioactive", .emoji = "\xe2\x98\xa2" }, // ☢
    .{ .name = "rage", .emoji = "\xf0\x9f\x98\xa1" }, // 😡
    .{ .name = "railway_car", .emoji = "\xf0\x9f\x9a\x83" }, // 🚃
    .{ .name = "railway_track", .emoji = "\xf0\x9f\x9b\xa4" }, // 🛤
    .{ .name = "rainbow", .emoji = "\xf0\x9f\x8c\x88" }, // 🌈
    .{ .name = "rainbow_flag", .emoji = "\xf0\x9f\x8f\xb3\xf0\x9f\x8c\x88" }, // 🏳🌈
    .{ .name = "raised_back_of_hand", .emoji = "\xf0\x9f\xa4\x9a" }, // 🤚
    .{ .name = "raised_eyebrow", .emoji = "\xf0\x9f\xa4\xa8" }, // 🤨
    .{ .name = "raised_hand", .emoji = "\xe2\x9c\x8b" }, // ✋
    .{ .name = "raised_hand_with_fingers_splayed", .emoji = "\xf0\x9f\x96\x90" }, // 🖐
    .{ .name = "raised_hands", .emoji = "\xf0\x9f\x99\x8c" }, // 🙌
    .{ .name = "raising_hand", .emoji = "\xf0\x9f\x99\x8b" }, // 🙋
    .{ .name = "raising_hand_man", .emoji = "\xf0\x9f\x99\x8b\xe2\x99\x82" }, // 🙋♂
    .{ .name = "raising_hand_woman", .emoji = "\xf0\x9f\x99\x8b\xe2\x99\x80" }, // 🙋♀
    .{ .name = "ram", .emoji = "\xf0\x9f\x90\x8f" }, // 🐏
    .{ .name = "ramen", .emoji = "\xf0\x9f\x8d\x9c" }, // 🍜
    .{ .name = "rat", .emoji = "\xf0\x9f\x90\x80" }, // 🐀
    .{ .name = "razor", .emoji = "\xf0\x9f\xaa\x92" }, // 🪒
    .{ .name = "receipt", .emoji = "\xf0\x9f\xa7\xbe" }, // 🧾
    .{ .name = "record_button", .emoji = "\xe2\x8f\xba" }, // ⏺
    .{ .name = "recycle", .emoji = "\xe2\x99\xbb" }, // ♻
    .{ .name = "red_car", .emoji = "\xf0\x9f\x9a\x97" }, // 🚗
    .{ .name = "red_circle", .emoji = "\xf0\x9f\x94\xb4" }, // 🔴
    .{ .name = "red_envelope", .emoji = "\xf0\x9f\xa7\xa7" }, // 🧧
    .{ .name = "red_haired_man", .emoji = "\xf0\x9f\x91\xa8\xf0\x9f\xa6\xb0" }, // 👨🦰
    .{ .name = "red_haired_woman", .emoji = "\xf0\x9f\x91\xa9\xf0\x9f\xa6\xb0" }, // 👩🦰
    .{ .name = "red_square", .emoji = "\xf0\x9f\x9f\xa5" }, // 🟥
    .{ .name = "registered", .emoji = "\xc2\xae" }, // ®
    .{ .name = "relaxed", .emoji = "\xe2\x98\xba" }, // ☺
    .{ .name = "relieved", .emoji = "\xf0\x9f\x98\x8c" }, // 😌
    .{ .name = "reminder_ribbon", .emoji = "\xf0\x9f\x8e\x97" }, // 🎗
    .{ .name = "repeat", .emoji = "\xf0\x9f\x94\x81" }, // 🔁
    .{ .name = "repeat_one", .emoji = "\xf0\x9f\x94\x82" }, // 🔂
    .{ .name = "rescue_worker_helmet", .emoji = "\xe2\x9b\x91" }, // ⛑
    .{ .name = "restroom", .emoji = "\xf0\x9f\x9a\xbb" }, // 🚻
    .{ .name = "reunion", .emoji = "\xf0\x9f\x87\xb7\xf0\x9f\x87\xaa" }, // 🇷🇪
    .{ .name = "revolving_hearts", .emoji = "\xf0\x9f\x92\x9e" }, // 💞
    .{ .name = "rewind", .emoji = "\xe2\x8f\xaa" }, // ⏪
    .{ .name = "rhinoceros", .emoji = "\xf0\x9f\xa6\x8f" }, // 🦏
    .{ .name = "ribbon", .emoji = "\xf0\x9f\x8e\x80" }, // 🎀
    .{ .name = "rice", .emoji = "\xf0\x9f\x8d\x9a" }, // 🍚
    .{ .name = "rice_ball", .emoji = "\xf0\x9f\x8d\x99" }, // 🍙
    .{ .name = "rice_cracker", .emoji = "\xf0\x9f\x8d\x98" }, // 🍘
    .{ .name = "rice_scene", .emoji = "\xf0\x9f\x8e\x91" }, // 🎑
    .{ .name = "right_anger_bubble", .emoji = "\xf0\x9f\x97\xaf" }, // 🗯
    .{ .name = "rightwards_hand", .emoji = "\xf0\x9f\xab\xb1" }, // 🫱
    .{ .name = "rightwards_pushing_hand", .emoji = "\xf0\x9f\xab\xb8" }, // 🫸
    .{ .name = "ring", .emoji = "\xf0\x9f\x92\x8d" }, // 💍
    .{ .name = "ring_buoy", .emoji = "\xf0\x9f\x9b\x9f" }, // 🛟
    .{ .name = "ringed_planet", .emoji = "\xf0\x9f\xaa\x90" }, // 🪐
    .{ .name = "robot", .emoji = "\xf0\x9f\xa4\x96" }, // 🤖
    .{ .name = "rock", .emoji = "\xf0\x9f\xaa\xa8" }, // 🪨
    .{ .name = "rocket", .emoji = "\xf0\x9f\x9a\x80" }, // 🚀
    .{ .name = "rofl", .emoji = "\xf0\x9f\xa4\xa3" }, // 🤣
    .{ .name = "roll_eyes", .emoji = "\xf0\x9f\x99\x84" }, // 🙄
    .{ .name = "roll_of_paper", .emoji = "\xf0\x9f\xa7\xbb" }, // 🧻
    .{ .name = "roller_coaster", .emoji = "\xf0\x9f\x8e\xa2" }, // 🎢
    .{ .name = "roller_skate", .emoji = "\xf0\x9f\x9b\xbc" }, // 🛼
    .{ .name = "romania", .emoji = "\xf0\x9f\x87\xb7\xf0\x9f\x87\xb4" }, // 🇷🇴
    .{ .name = "rooster", .emoji = "\xf0\x9f\x90\x93" }, // 🐓
    .{ .name = "rose", .emoji = "\xf0\x9f\x8c\xb9" }, // 🌹
    .{ .name = "rosette", .emoji = "\xf0\x9f\x8f\xb5" }, // 🏵
    .{ .name = "rotating_light", .emoji = "\xf0\x9f\x9a\xa8" }, // 🚨
    .{ .name = "round_pushpin", .emoji = "\xf0\x9f\x93\x8d" }, // 📍
    .{ .name = "rowboat", .emoji = "\xf0\x9f\x9a\xa3" }, // 🚣
    .{ .name = "rowing_man", .emoji = "\xf0\x9f\x9a\xa3\xe2\x99\x82" }, // 🚣♂
    .{ .name = "rowing_woman", .emoji = "\xf0\x9f\x9a\xa3\xe2\x99\x80" }, // 🚣♀
    .{ .name = "ru", .emoji = "\xf0\x9f\x87\xb7\xf0\x9f\x87\xba" }, // 🇷🇺
    .{ .name = "rugby_football", .emoji = "\xf0\x9f\x8f\x89" }, // 🏉
    .{ .name = "runner", .emoji = "\xf0\x9f\x8f\x83" }, // 🏃
    .{ .name = "running", .emoji = "\xf0\x9f\x8f\x83" }, // 🏃
    .{ .name = "running_man", .emoji = "\xf0\x9f\x8f\x83\xe2\x99\x82" }, // 🏃♂
    .{ .name = "running_shirt_with_sash", .emoji = "\xf0\x9f\x8e\xbd" }, // 🎽
    .{ .name = "running_woman", .emoji = "\xf0\x9f\x8f\x83\xe2\x99\x80" }, // 🏃♀
    .{ .name = "rwanda", .emoji = "\xf0\x9f\x87\xb7\xf0\x9f\x87\xbc" }, // 🇷🇼
    .{ .name = "sa", .emoji = "\xf0\x9f\x88\x82" }, // 🈂
    .{ .name = "safety_pin", .emoji = "\xf0\x9f\xa7\xb7" }, // 🧷
    .{ .name = "safety_vest", .emoji = "\xf0\x9f\xa6\xba" }, // 🦺
    .{ .name = "sagittarius", .emoji = "\xe2\x99\x90" }, // ♐
    .{ .name = "sailboat", .emoji = "\xe2\x9b\xb5" }, // ⛵
    .{ .name = "sake", .emoji = "\xf0\x9f\x8d\xb6" }, // 🍶
    .{ .name = "salt", .emoji = "\xf0\x9f\xa7\x82" }, // 🧂
    .{ .name = "saluting_face", .emoji = "\xf0\x9f\xab\xa1" }, // 🫡
    .{ .name = "samoa", .emoji = "\xf0\x9f\x87\xbc\xf0\x9f\x87\xb8" }, // 🇼🇸
    .{ .name = "san_marino", .emoji = "\xf0\x9f\x87\xb8\xf0\x9f\x87\xb2" }, // 🇸🇲
    .{ .name = "sandal", .emoji = "\xf0\x9f\x91\xa1" }, // 👡
    .{ .name = "sandwich", .emoji = "\xf0\x9f\xa5\xaa" }, // 🥪
    .{ .name = "santa", .emoji = "\xf0\x9f\x8e\x85" }, // 🎅
    .{ .name = "sao_tome_principe", .emoji = "\xf0\x9f\x87\xb8\xf0\x9f\x87\xb9" }, // 🇸🇹
    .{ .name = "sari", .emoji = "\xf0\x9f\xa5\xbb" }, // 🥻
    .{ .name = "sassy_man", .emoji = "\xf0\x9f\x92\x81\xe2\x99\x82" }, // 💁♂
    .{ .name = "sassy_woman", .emoji = "\xf0\x9f\x92\x81\xe2\x99\x80" }, // 💁♀
    .{ .name = "satellite", .emoji = "\xf0\x9f\x93\xa1" }, // 📡
    .{ .name = "satisfied", .emoji = "\xf0\x9f\x98\x86" }, // 😆
    .{ .name = "saudi_arabia", .emoji = "\xf0\x9f\x87\xb8\xf0\x9f\x87\xa6" }, // 🇸🇦
    .{ .name = "sauna_man", .emoji = "\xf0\x9f\xa7\x96\xe2\x99\x82" }, // 🧖♂
    .{ .name = "sauna_person", .emoji = "\xf0\x9f\xa7\x96" }, // 🧖
    .{ .name = "sauna_woman", .emoji = "\xf0\x9f\xa7\x96\xe2\x99\x80" }, // 🧖♀
    .{ .name = "sauropod", .emoji = "\xf0\x9f\xa6\x95" }, // 🦕
    .{ .name = "saxophone", .emoji = "\xf0\x9f\x8e\xb7" }, // 🎷
    .{ .name = "scarf", .emoji = "\xf0\x9f\xa7\xa3" }, // 🧣
    .{ .name = "school", .emoji = "\xf0\x9f\x8f\xab" }, // 🏫
    .{ .name = "school_satchel", .emoji = "\xf0\x9f\x8e\x92" }, // 🎒
    .{ .name = "scientist", .emoji = "\xf0\x9f\xa7\x91\xf0\x9f\x94\xac" }, // 🧑🔬
    .{ .name = "scissors", .emoji = "\xe2\x9c\x82" }, // ✂
    .{ .name = "scorpion", .emoji = "\xf0\x9f\xa6\x82" }, // 🦂
    .{ .name = "scorpius", .emoji = "\xe2\x99\x8f" }, // ♏
    .{ .name = "scotland", .emoji = "\xf0\x9f\x8f\xb4\xf3\xa0\x81\xa7\xf3\xa0\x81\xa2\xf3\xa0\x81\xb3\xf3\xa0\x81\xa3\xf3\xa0\x81\xb4\xf3\xa0\x81\xbf" }, // 🏴󠁧󠁢󠁳󠁣󠁴󠁿
    .{ .name = "scream", .emoji = "\xf0\x9f\x98\xb1" }, // 😱
    .{ .name = "scream_cat", .emoji = "\xf0\x9f\x99\x80" }, // 🙀
    .{ .name = "screwdriver", .emoji = "\xf0\x9f\xaa\x9b" }, // 🪛
    .{ .name = "scroll", .emoji = "\xf0\x9f\x93\x9c" }, // 📜
    .{ .name = "seal", .emoji = "\xf0\x9f\xa6\xad" }, // 🦭
    .{ .name = "seat", .emoji = "\xf0\x9f\x92\xba" }, // 💺
    .{ .name = "secret", .emoji = "\xe3\x8a\x99" }, // ㊙
    .{ .name = "see_no_evil", .emoji = "\xf0\x9f\x99\x88" }, // 🙈
    .{ .name = "seedling", .emoji = "\xf0\x9f\x8c\xb1" }, // 🌱
    .{ .name = "selfie", .emoji = "\xf0\x9f\xa4\xb3" }, // 🤳
    .{ .name = "senegal", .emoji = "\xf0\x9f\x87\xb8\xf0\x9f\x87\xb3" }, // 🇸🇳
    .{ .name = "serbia", .emoji = "\xf0\x9f\x87\xb7\xf0\x9f\x87\xb8" }, // 🇷🇸
    .{ .name = "service_dog", .emoji = "\xf0\x9f\x90\x95\xf0\x9f\xa6\xba" }, // 🐕🦺
    .{ .name = "seven", .emoji = "\x37\xe2\x83\xa3" }, // 7⃣
    .{ .name = "sewing_needle", .emoji = "\xf0\x9f\xaa\xa1" }, // 🪡
    .{ .name = "seychelles", .emoji = "\xf0\x9f\x87\xb8\xf0\x9f\x87\xa8" }, // 🇸🇨
    .{ .name = "shaking_face", .emoji = "\xf0\x9f\xab\xa8" }, // 🫨
    .{ .name = "shallow_pan_of_food", .emoji = "\xf0\x9f\xa5\x98" }, // 🥘
    .{ .name = "shamrock", .emoji = "\xe2\x98\x98" }, // ☘
    .{ .name = "shark", .emoji = "\xf0\x9f\xa6\x88" }, // 🦈
    .{ .name = "shaved_ice", .emoji = "\xf0\x9f\x8d\xa7" }, // 🍧
    .{ .name = "sheep", .emoji = "\xf0\x9f\x90\x91" }, // 🐑
    .{ .name = "shell", .emoji = "\xf0\x9f\x90\x9a" }, // 🐚
    .{ .name = "shield", .emoji = "\xf0\x9f\x9b\xa1" }, // 🛡
    .{ .name = "shinto_shrine", .emoji = "\xe2\x9b\xa9" }, // ⛩
    .{ .name = "ship", .emoji = "\xf0\x9f\x9a\xa2" }, // 🚢
    .{ .name = "shirt", .emoji = "\xf0\x9f\x91\x95" }, // 👕
    .{ .name = "shit", .emoji = "\xf0\x9f\x92\xa9" }, // 💩
    .{ .name = "shoe", .emoji = "\xf0\x9f\x91\x9e" }, // 👞
    .{ .name = "shopping", .emoji = "\xf0\x9f\x9b\x8d" }, // 🛍
    .{ .name = "shopping_cart", .emoji = "\xf0\x9f\x9b\x92" }, // 🛒
    .{ .name = "shorts", .emoji = "\xf0\x9f\xa9\xb3" }, // 🩳
    .{ .name = "shower", .emoji = "\xf0\x9f\x9a\xbf" }, // 🚿
    .{ .name = "shrimp", .emoji = "\xf0\x9f\xa6\x90" }, // 🦐
    .{ .name = "shrug", .emoji = "\xf0\x9f\xa4\xb7" }, // 🤷
    .{ .name = "shushing_face", .emoji = "\xf0\x9f\xa4\xab" }, // 🤫
    .{ .name = "sierra_leone", .emoji = "\xf0\x9f\x87\xb8\xf0\x9f\x87\xb1" }, // 🇸🇱
    .{ .name = "signal_strength", .emoji = "\xf0\x9f\x93\xb6" }, // 📶
    .{ .name = "singapore", .emoji = "\xf0\x9f\x87\xb8\xf0\x9f\x87\xac" }, // 🇸🇬
    .{ .name = "singer", .emoji = "\xf0\x9f\xa7\x91\xf0\x9f\x8e\xa4" }, // 🧑🎤
    .{ .name = "sint_maarten", .emoji = "\xf0\x9f\x87\xb8\xf0\x9f\x87\xbd" }, // 🇸🇽
    .{ .name = "six", .emoji = "\x36\xe2\x83\xa3" }, // 6⃣
    .{ .name = "six_pointed_star", .emoji = "\xf0\x9f\x94\xaf" }, // 🔯
    .{ .name = "skateboard", .emoji = "\xf0\x9f\x9b\xb9" }, // 🛹
    .{ .name = "ski", .emoji = "\xf0\x9f\x8e\xbf" }, // 🎿
    .{ .name = "skier", .emoji = "\xe2\x9b\xb7" }, // ⛷
    .{ .name = "skull", .emoji = "\xf0\x9f\x92\x80" }, // 💀
    .{ .name = "skull_and_crossbones", .emoji = "\xe2\x98\xa0" }, // ☠
    .{ .name = "skunk", .emoji = "\xf0\x9f\xa6\xa8" }, // 🦨
    .{ .name = "sled", .emoji = "\xf0\x9f\x9b\xb7" }, // 🛷
    .{ .name = "sleeping", .emoji = "\xf0\x9f\x98\xb4" }, // 😴
    .{ .name = "sleeping_bed", .emoji = "\xf0\x9f\x9b\x8c" }, // 🛌
    .{ .name = "sleepy", .emoji = "\xf0\x9f\x98\xaa" }, // 😪
    .{ .name = "slightly_frowning_face", .emoji = "\xf0\x9f\x99\x81" }, // 🙁
    .{ .name = "slightly_smiling_face", .emoji = "\xf0\x9f\x99\x82" }, // 🙂
    .{ .name = "slot_machine", .emoji = "\xf0\x9f\x8e\xb0" }, // 🎰
    .{ .name = "sloth", .emoji = "\xf0\x9f\xa6\xa5" }, // 🦥
    .{ .name = "slovakia", .emoji = "\xf0\x9f\x87\xb8\xf0\x9f\x87\xb0" }, // 🇸🇰
    .{ .name = "slovenia", .emoji = "\xf0\x9f\x87\xb8\xf0\x9f\x87\xae" }, // 🇸🇮
    .{ .name = "small_airplane", .emoji = "\xf0\x9f\x9b\xa9" }, // 🛩
    .{ .name = "small_blue_diamond", .emoji = "\xf0\x9f\x94\xb9" }, // 🔹
    .{ .name = "small_orange_diamond", .emoji = "\xf0\x9f\x94\xb8" }, // 🔸
    .{ .name = "small_red_triangle", .emoji = "\xf0\x9f\x94\xba" }, // 🔺
    .{ .name = "small_red_triangle_down", .emoji = "\xf0\x9f\x94\xbb" }, // 🔻
    .{ .name = "smile", .emoji = "\xf0\x9f\x98\x84" }, // 😄
    .{ .name = "smile_cat", .emoji = "\xf0\x9f\x98\xb8" }, // 😸
    .{ .name = "smiley", .emoji = "\xf0\x9f\x98\x83" }, // 😃
    .{ .name = "smiley_cat", .emoji = "\xf0\x9f\x98\xba" }, // 😺
    .{ .name = "smiling_face_with_tear", .emoji = "\xf0\x9f\xa5\xb2" }, // 🥲
    .{ .name = "smiling_face_with_three_hearts", .emoji = "\xf0\x9f\xa5\xb0" }, // 🥰
    .{ .name = "smiling_imp", .emoji = "\xf0\x9f\x98\x88" }, // 😈
    .{ .name = "smirk", .emoji = "\xf0\x9f\x98\x8f" }, // 😏
    .{ .name = "smirk_cat", .emoji = "\xf0\x9f\x98\xbc" }, // 😼
    .{ .name = "smoking", .emoji = "\xf0\x9f\x9a\xac" }, // 🚬
    .{ .name = "snail", .emoji = "\xf0\x9f\x90\x8c" }, // 🐌
    .{ .name = "snake", .emoji = "\xf0\x9f\x90\x8d" }, // 🐍
    .{ .name = "sneezing_face", .emoji = "\xf0\x9f\xa4\xa7" }, // 🤧
    .{ .name = "snowboarder", .emoji = "\xf0\x9f\x8f\x82" }, // 🏂
    .{ .name = "snowflake", .emoji = "\xe2\x9d\x84" }, // ❄
    .{ .name = "snowman", .emoji = "\xe2\x9b\x84" }, // ⛄
    .{ .name = "snowman_with_snow", .emoji = "\xe2\x98\x83" }, // ☃
    .{ .name = "soap", .emoji = "\xf0\x9f\xa7\xbc" }, // 🧼
    .{ .name = "sob", .emoji = "\xf0\x9f\x98\xad" }, // 😭
    .{ .name = "soccer", .emoji = "\xe2\x9a\xbd" }, // ⚽
    .{ .name = "socks", .emoji = "\xf0\x9f\xa7\xa6" }, // 🧦
    .{ .name = "softball", .emoji = "\xf0\x9f\xa5\x8e" }, // 🥎
    .{ .name = "solomon_islands", .emoji = "\xf0\x9f\x87\xb8\xf0\x9f\x87\xa7" }, // 🇸🇧
    .{ .name = "somalia", .emoji = "\xf0\x9f\x87\xb8\xf0\x9f\x87\xb4" }, // 🇸🇴
    .{ .name = "soon", .emoji = "\xf0\x9f\x94\x9c" }, // 🔜
    .{ .name = "sos", .emoji = "\xf0\x9f\x86\x98" }, // 🆘
    .{ .name = "sound", .emoji = "\xf0\x9f\x94\x89" }, // 🔉
    .{ .name = "south_africa", .emoji = "\xf0\x9f\x87\xbf\xf0\x9f\x87\xa6" }, // 🇿🇦
    .{ .name = "south_georgia_south_sandwich_islands", .emoji = "\xf0\x9f\x87\xac\xf0\x9f\x87\xb8" }, // 🇬🇸
    .{ .name = "south_sudan", .emoji = "\xf0\x9f\x87\xb8\xf0\x9f\x87\xb8" }, // 🇸🇸
    .{ .name = "space_invader", .emoji = "\xf0\x9f\x91\xbe" }, // 👾
    .{ .name = "spades", .emoji = "\xe2\x99\xa0" }, // ♠
    .{ .name = "spaghetti", .emoji = "\xf0\x9f\x8d\x9d" }, // 🍝
    .{ .name = "sparkle", .emoji = "\xe2\x9d\x87" }, // ❇
    .{ .name = "sparkler", .emoji = "\xf0\x9f\x8e\x87" }, // 🎇
    .{ .name = "sparkles", .emoji = "\xe2\x9c\xa8" }, // ✨
    .{ .name = "sparkling_heart", .emoji = "\xf0\x9f\x92\x96" }, // 💖
    .{ .name = "speak_no_evil", .emoji = "\xf0\x9f\x99\x8a" }, // 🙊
    .{ .name = "speaker", .emoji = "\xf0\x9f\x94\x88" }, // 🔈
    .{ .name = "speaking_head", .emoji = "\xf0\x9f\x97\xa3" }, // 🗣
    .{ .name = "speech_balloon", .emoji = "\xf0\x9f\x92\xac" }, // 💬
    .{ .name = "speedboat", .emoji = "\xf0\x9f\x9a\xa4" }, // 🚤
    .{ .name = "spider", .emoji = "\xf0\x9f\x95\xb7" }, // 🕷
    .{ .name = "spider_web", .emoji = "\xf0\x9f\x95\xb8" }, // 🕸
    .{ .name = "spiral_calendar", .emoji = "\xf0\x9f\x97\x93" }, // 🗓
    .{ .name = "spiral_notepad", .emoji = "\xf0\x9f\x97\x92" }, // 🗒
    .{ .name = "sponge", .emoji = "\xf0\x9f\xa7\xbd" }, // 🧽
    .{ .name = "spoon", .emoji = "\xf0\x9f\xa5\x84" }, // 🥄
    .{ .name = "squid", .emoji = "\xf0\x9f\xa6\x91" }, // 🦑
    .{ .name = "sri_lanka", .emoji = "\xf0\x9f\x87\xb1\xf0\x9f\x87\xb0" }, // 🇱🇰
    .{ .name = "st_barthelemy", .emoji = "\xf0\x9f\x87\xa7\xf0\x9f\x87\xb1" }, // 🇧🇱
    .{ .name = "st_helena", .emoji = "\xf0\x9f\x87\xb8\xf0\x9f\x87\xad" }, // 🇸🇭
    .{ .name = "st_kitts_nevis", .emoji = "\xf0\x9f\x87\xb0\xf0\x9f\x87\xb3" }, // 🇰🇳
    .{ .name = "st_lucia", .emoji = "\xf0\x9f\x87\xb1\xf0\x9f\x87\xa8" }, // 🇱🇨
    .{ .name = "st_martin", .emoji = "\xf0\x9f\x87\xb2\xf0\x9f\x87\xab" }, // 🇲🇫
    .{ .name = "st_pierre_miquelon", .emoji = "\xf0\x9f\x87\xb5\xf0\x9f\x87\xb2" }, // 🇵🇲
    .{ .name = "st_vincent_grenadines", .emoji = "\xf0\x9f\x87\xbb\xf0\x9f\x87\xa8" }, // 🇻🇨
    .{ .name = "stadium", .emoji = "\xf0\x9f\x8f\x9f" }, // 🏟
    .{ .name = "standing_man", .emoji = "\xf0\x9f\xa7\x8d\xe2\x99\x82" }, // 🧍♂
    .{ .name = "standing_person", .emoji = "\xf0\x9f\xa7\x8d" }, // 🧍
    .{ .name = "standing_woman", .emoji = "\xf0\x9f\xa7\x8d\xe2\x99\x80" }, // 🧍♀
    .{ .name = "star", .emoji = "\xe2\xad\x90" }, // ⭐
    .{ .name = "star2", .emoji = "\xf0\x9f\x8c\x9f" }, // 🌟
    .{ .name = "star_and_crescent", .emoji = "\xe2\x98\xaa" }, // ☪
    .{ .name = "star_of_david", .emoji = "\xe2\x9c\xa1" }, // ✡
    .{ .name = "star_struck", .emoji = "\xf0\x9f\xa4\xa9" }, // 🤩
    .{ .name = "stars", .emoji = "\xf0\x9f\x8c\xa0" }, // 🌠
    .{ .name = "station", .emoji = "\xf0\x9f\x9a\x89" }, // 🚉
    .{ .name = "statue_of_liberty", .emoji = "\xf0\x9f\x97\xbd" }, // 🗽
    .{ .name = "steam_locomotive", .emoji = "\xf0\x9f\x9a\x82" }, // 🚂
    .{ .name = "stethoscope", .emoji = "\xf0\x9f\xa9\xba" }, // 🩺
    .{ .name = "stew", .emoji = "\xf0\x9f\x8d\xb2" }, // 🍲
    .{ .name = "stop_button", .emoji = "\xe2\x8f\xb9" }, // ⏹
    .{ .name = "stop_sign", .emoji = "\xf0\x9f\x9b\x91" }, // 🛑
    .{ .name = "stopwatch", .emoji = "\xe2\x8f\xb1" }, // ⏱
    .{ .name = "straight_ruler", .emoji = "\xf0\x9f\x93\x8f" }, // 📏
    .{ .name = "strawberry", .emoji = "\xf0\x9f\x8d\x93" }, // 🍓
    .{ .name = "stuck_out_tongue", .emoji = "\xf0\x9f\x98\x9b" }, // 😛
    .{ .name = "stuck_out_tongue_closed_eyes", .emoji = "\xf0\x9f\x98\x9d" }, // 😝
    .{ .name = "stuck_out_tongue_winking_eye", .emoji = "\xf0\x9f\x98\x9c" }, // 😜
    .{ .name = "student", .emoji = "\xf0\x9f\xa7\x91\xf0\x9f\x8e\x93" }, // 🧑🎓
    .{ .name = "studio_microphone", .emoji = "\xf0\x9f\x8e\x99" }, // 🎙
    .{ .name = "stuffed_flatbread", .emoji = "\xf0\x9f\xa5\x99" }, // 🥙
    .{ .name = "sudan", .emoji = "\xf0\x9f\x87\xb8\xf0\x9f\x87\xa9" }, // 🇸🇩
    .{ .name = "sun_behind_large_cloud", .emoji = "\xf0\x9f\x8c\xa5" }, // 🌥
    .{ .name = "sun_behind_rain_cloud", .emoji = "\xf0\x9f\x8c\xa6" }, // 🌦
    .{ .name = "sun_behind_small_cloud", .emoji = "\xf0\x9f\x8c\xa4" }, // 🌤
    .{ .name = "sun_with_face", .emoji = "\xf0\x9f\x8c\x9e" }, // 🌞
    .{ .name = "sunflower", .emoji = "\xf0\x9f\x8c\xbb" }, // 🌻
    .{ .name = "sunglasses", .emoji = "\xf0\x9f\x98\x8e" }, // 😎
    .{ .name = "sunny", .emoji = "\xe2\x98\x80" }, // ☀
    .{ .name = "sunrise", .emoji = "\xf0\x9f\x8c\x85" }, // 🌅
    .{ .name = "sunrise_over_mountains", .emoji = "\xf0\x9f\x8c\x84" }, // 🌄
    .{ .name = "superhero", .emoji = "\xf0\x9f\xa6\xb8" }, // 🦸
    .{ .name = "superhero_man", .emoji = "\xf0\x9f\xa6\xb8\xe2\x99\x82" }, // 🦸♂
    .{ .name = "superhero_woman", .emoji = "\xf0\x9f\xa6\xb8\xe2\x99\x80" }, // 🦸♀
    .{ .name = "supervillain", .emoji = "\xf0\x9f\xa6\xb9" }, // 🦹
    .{ .name = "supervillain_man", .emoji = "\xf0\x9f\xa6\xb9\xe2\x99\x82" }, // 🦹♂
    .{ .name = "supervillain_woman", .emoji = "\xf0\x9f\xa6\xb9\xe2\x99\x80" }, // 🦹♀
    .{ .name = "surfer", .emoji = "\xf0\x9f\x8f\x84" }, // 🏄
    .{ .name = "surfing_man", .emoji = "\xf0\x9f\x8f\x84\xe2\x99\x82" }, // 🏄♂
    .{ .name = "surfing_woman", .emoji = "\xf0\x9f\x8f\x84\xe2\x99\x80" }, // 🏄♀
    .{ .name = "suriname", .emoji = "\xf0\x9f\x87\xb8\xf0\x9f\x87\xb7" }, // 🇸🇷
    .{ .name = "sushi", .emoji = "\xf0\x9f\x8d\xa3" }, // 🍣
    .{ .name = "suspension_railway", .emoji = "\xf0\x9f\x9a\x9f" }, // 🚟
    .{ .name = "svalbard_jan_mayen", .emoji = "\xf0\x9f\x87\xb8\xf0\x9f\x87\xaf" }, // 🇸🇯
    .{ .name = "swan", .emoji = "\xf0\x9f\xa6\xa2" }, // 🦢
    .{ .name = "swaziland", .emoji = "\xf0\x9f\x87\xb8\xf0\x9f\x87\xbf" }, // 🇸🇿
    .{ .name = "sweat", .emoji = "\xf0\x9f\x98\x93" }, // 😓
    .{ .name = "sweat_drops", .emoji = "\xf0\x9f\x92\xa6" }, // 💦
    .{ .name = "sweat_smile", .emoji = "\xf0\x9f\x98\x85" }, // 😅
    .{ .name = "sweden", .emoji = "\xf0\x9f\x87\xb8\xf0\x9f\x87\xaa" }, // 🇸🇪
    .{ .name = "sweet_potato", .emoji = "\xf0\x9f\x8d\xa0" }, // 🍠
    .{ .name = "swim_brief", .emoji = "\xf0\x9f\xa9\xb2" }, // 🩲
    .{ .name = "swimmer", .emoji = "\xf0\x9f\x8f\x8a" }, // 🏊
    .{ .name = "swimming_man", .emoji = "\xf0\x9f\x8f\x8a\xe2\x99\x82" }, // 🏊♂
    .{ .name = "swimming_woman", .emoji = "\xf0\x9f\x8f\x8a\xe2\x99\x80" }, // 🏊♀
    .{ .name = "switzerland", .emoji = "\xf0\x9f\x87\xa8\xf0\x9f\x87\xad" }, // 🇨🇭
    .{ .name = "symbols", .emoji = "\xf0\x9f\x94\xa3" }, // 🔣
    .{ .name = "synagogue", .emoji = "\xf0\x9f\x95\x8d" }, // 🕍
    .{ .name = "syria", .emoji = "\xf0\x9f\x87\xb8\xf0\x9f\x87\xbe" }, // 🇸🇾
    .{ .name = "syringe", .emoji = "\xf0\x9f\x92\x89" }, // 💉
    .{ .name = "t-rex", .emoji = "\xf0\x9f\xa6\x96" }, // 🦖
    .{ .name = "taco", .emoji = "\xf0\x9f\x8c\xae" }, // 🌮
    .{ .name = "tada", .emoji = "\xf0\x9f\x8e\x89" }, // 🎉
    .{ .name = "taiwan", .emoji = "\xf0\x9f\x87\xb9\xf0\x9f\x87\xbc" }, // 🇹🇼
    .{ .name = "tajikistan", .emoji = "\xf0\x9f\x87\xb9\xf0\x9f\x87\xaf" }, // 🇹🇯
    .{ .name = "takeout_box", .emoji = "\xf0\x9f\xa5\xa1" }, // 🥡
    .{ .name = "tamale", .emoji = "\xf0\x9f\xab\x94" }, // 🫔
    .{ .name = "tanabata_tree", .emoji = "\xf0\x9f\x8e\x8b" }, // 🎋
    .{ .name = "tangerine", .emoji = "\xf0\x9f\x8d\x8a" }, // 🍊
    .{ .name = "tanzania", .emoji = "\xf0\x9f\x87\xb9\xf0\x9f\x87\xbf" }, // 🇹🇿
    .{ .name = "taurus", .emoji = "\xe2\x99\x89" }, // ♉
    .{ .name = "taxi", .emoji = "\xf0\x9f\x9a\x95" }, // 🚕
    .{ .name = "tea", .emoji = "\xf0\x9f\x8d\xb5" }, // 🍵
    .{ .name = "teacher", .emoji = "\xf0\x9f\xa7\x91\xf0\x9f\x8f\xab" }, // 🧑🏫
    .{ .name = "teapot", .emoji = "\xf0\x9f\xab\x96" }, // 🫖
    .{ .name = "technologist", .emoji = "\xf0\x9f\xa7\x91\xf0\x9f\x92\xbb" }, // 🧑💻
    .{ .name = "teddy_bear", .emoji = "\xf0\x9f\xa7\xb8" }, // 🧸
    .{ .name = "telephone", .emoji = "\xe2\x98\x8e" }, // ☎
    .{ .name = "telephone_receiver", .emoji = "\xf0\x9f\x93\x9e" }, // 📞
    .{ .name = "telescope", .emoji = "\xf0\x9f\x94\xad" }, // 🔭
    .{ .name = "tennis", .emoji = "\xf0\x9f\x8e\xbe" }, // 🎾
    .{ .name = "tent", .emoji = "\xe2\x9b\xba" }, // ⛺
    .{ .name = "test_tube", .emoji = "\xf0\x9f\xa7\xaa" }, // 🧪
    .{ .name = "thailand", .emoji = "\xf0\x9f\x87\xb9\xf0\x9f\x87\xad" }, // 🇹🇭
    .{ .name = "thermometer", .emoji = "\xf0\x9f\x8c\xa1" }, // 🌡
    .{ .name = "thinking", .emoji = "\xf0\x9f\xa4\x94" }, // 🤔
    .{ .name = "thong_sandal", .emoji = "\xf0\x9f\xa9\xb4" }, // 🩴
    .{ .name = "thought_balloon", .emoji = "\xf0\x9f\x92\xad" }, // 💭
    .{ .name = "thread", .emoji = "\xf0\x9f\xa7\xb5" }, // 🧵
    .{ .name = "three", .emoji = "\x33\xe2\x83\xa3" }, // 3⃣
    .{ .name = "thumbsdown", .emoji = "\xf0\x9f\x91\x8e" }, // 👎
    .{ .name = "thumbsup", .emoji = "\xf0\x9f\x91\x8d" }, // 👍
    .{ .name = "ticket", .emoji = "\xf0\x9f\x8e\xab" }, // 🎫
    .{ .name = "tickets", .emoji = "\xf0\x9f\x8e\x9f" }, // 🎟
    .{ .name = "tiger", .emoji = "\xf0\x9f\x90\xaf" }, // 🐯
    .{ .name = "tiger2", .emoji = "\xf0\x9f\x90\x85" }, // 🐅
    .{ .name = "timer_clock", .emoji = "\xe2\x8f\xb2" }, // ⏲
    .{ .name = "timor_leste", .emoji = "\xf0\x9f\x87\xb9\xf0\x9f\x87\xb1" }, // 🇹🇱
    .{ .name = "tipping_hand_man", .emoji = "\xf0\x9f\x92\x81\xe2\x99\x82" }, // 💁♂
    .{ .name = "tipping_hand_person", .emoji = "\xf0\x9f\x92\x81" }, // 💁
    .{ .name = "tipping_hand_woman", .emoji = "\xf0\x9f\x92\x81\xe2\x99\x80" }, // 💁♀
    .{ .name = "tired_face", .emoji = "\xf0\x9f\x98\xab" }, // 😫
    .{ .name = "tm", .emoji = "\xe2\x84\xa2" }, // ™
    .{ .name = "togo", .emoji = "\xf0\x9f\x87\xb9\xf0\x9f\x87\xac" }, // 🇹🇬
    .{ .name = "toilet", .emoji = "\xf0\x9f\x9a\xbd" }, // 🚽
    .{ .name = "tokelau", .emoji = "\xf0\x9f\x87\xb9\xf0\x9f\x87\xb0" }, // 🇹🇰
    .{ .name = "tokyo_tower", .emoji = "\xf0\x9f\x97\xbc" }, // 🗼
    .{ .name = "tomato", .emoji = "\xf0\x9f\x8d\x85" }, // 🍅
    .{ .name = "tonga", .emoji = "\xf0\x9f\x87\xb9\xf0\x9f\x87\xb4" }, // 🇹🇴
    .{ .name = "tongue", .emoji = "\xf0\x9f\x91\x85" }, // 👅
    .{ .name = "toolbox", .emoji = "\xf0\x9f\xa7\xb0" }, // 🧰
    .{ .name = "tooth", .emoji = "\xf0\x9f\xa6\xb7" }, // 🦷
    .{ .name = "toothbrush", .emoji = "\xf0\x9f\xaa\xa5" }, // 🪥
    .{ .name = "top", .emoji = "\xf0\x9f\x94\x9d" }, // 🔝
    .{ .name = "tophat", .emoji = "\xf0\x9f\x8e\xa9" }, // 🎩
    .{ .name = "tornado", .emoji = "\xf0\x9f\x8c\xaa" }, // 🌪
    .{ .name = "tr", .emoji = "\xf0\x9f\x87\xb9\xf0\x9f\x87\xb7" }, // 🇹🇷
    .{ .name = "trackball", .emoji = "\xf0\x9f\x96\xb2" }, // 🖲
    .{ .name = "tractor", .emoji = "\xf0\x9f\x9a\x9c" }, // 🚜
    .{ .name = "traffic_light", .emoji = "\xf0\x9f\x9a\xa5" }, // 🚥
    .{ .name = "train", .emoji = "\xf0\x9f\x9a\x8b" }, // 🚋
    .{ .name = "train2", .emoji = "\xf0\x9f\x9a\x86" }, // 🚆
    .{ .name = "tram", .emoji = "\xf0\x9f\x9a\x8a" }, // 🚊
    .{ .name = "transgender_flag", .emoji = "\xf0\x9f\x8f\xb3\xe2\x9a\xa7" }, // 🏳⚧
    .{ .name = "transgender_symbol", .emoji = "\xe2\x9a\xa7" }, // ⚧
    .{ .name = "triangular_flag_on_post", .emoji = "\xf0\x9f\x9a\xa9" }, // 🚩
    .{ .name = "triangular_ruler", .emoji = "\xf0\x9f\x93\x90" }, // 📐
    .{ .name = "trident", .emoji = "\xf0\x9f\x94\xb1" }, // 🔱
    .{ .name = "trinidad_tobago", .emoji = "\xf0\x9f\x87\xb9\xf0\x9f\x87\xb9" }, // 🇹🇹
    .{ .name = "tristan_da_cunha", .emoji = "\xf0\x9f\x87\xb9\xf0\x9f\x87\xa6" }, // 🇹🇦
    .{ .name = "triumph", .emoji = "\xf0\x9f\x98\xa4" }, // 😤
    .{ .name = "troll", .emoji = "\xf0\x9f\xa7\x8c" }, // 🧌
    .{ .name = "trolleybus", .emoji = "\xf0\x9f\x9a\x8e" }, // 🚎
    .{ .name = "trophy", .emoji = "\xf0\x9f\x8f\x86" }, // 🏆
    .{ .name = "tropical_drink", .emoji = "\xf0\x9f\x8d\xb9" }, // 🍹
    .{ .name = "tropical_fish", .emoji = "\xf0\x9f\x90\xa0" }, // 🐠
    .{ .name = "truck", .emoji = "\xf0\x9f\x9a\x9a" }, // 🚚
    .{ .name = "trumpet", .emoji = "\xf0\x9f\x8e\xba" }, // 🎺
    .{ .name = "tshirt", .emoji = "\xf0\x9f\x91\x95" }, // 👕
    .{ .name = "tulip", .emoji = "\xf0\x9f\x8c\xb7" }, // 🌷
    .{ .name = "tumbler_glass", .emoji = "\xf0\x9f\xa5\x83" }, // 🥃
    .{ .name = "tunisia", .emoji = "\xf0\x9f\x87\xb9\xf0\x9f\x87\xb3" }, // 🇹🇳
    .{ .name = "turkey", .emoji = "\xf0\x9f\xa6\x83" }, // 🦃
    .{ .name = "turkmenistan", .emoji = "\xf0\x9f\x87\xb9\xf0\x9f\x87\xb2" }, // 🇹🇲
    .{ .name = "turks_caicos_islands", .emoji = "\xf0\x9f\x87\xb9\xf0\x9f\x87\xa8" }, // 🇹🇨
    .{ .name = "turtle", .emoji = "\xf0\x9f\x90\xa2" }, // 🐢
    .{ .name = "tuvalu", .emoji = "\xf0\x9f\x87\xb9\xf0\x9f\x87\xbb" }, // 🇹🇻
    .{ .name = "tv", .emoji = "\xf0\x9f\x93\xba" }, // 📺
    .{ .name = "twisted_rightwards_arrows", .emoji = "\xf0\x9f\x94\x80" }, // 🔀
    .{ .name = "two", .emoji = "\x32\xe2\x83\xa3" }, // 2⃣
    .{ .name = "two_hearts", .emoji = "\xf0\x9f\x92\x95" }, // 💕
    .{ .name = "two_men_holding_hands", .emoji = "\xf0\x9f\x91\xac" }, // 👬
    .{ .name = "two_women_holding_hands", .emoji = "\xf0\x9f\x91\xad" }, // 👭
    .{ .name = "u5272", .emoji = "\xf0\x9f\x88\xb9" }, // 🈹
    .{ .name = "u5408", .emoji = "\xf0\x9f\x88\xb4" }, // 🈴
    .{ .name = "u55b6", .emoji = "\xf0\x9f\x88\xba" }, // 🈺
    .{ .name = "u6307", .emoji = "\xf0\x9f\x88\xaf" }, // 🈯
    .{ .name = "u6708", .emoji = "\xf0\x9f\x88\xb7" }, // 🈷
    .{ .name = "u6709", .emoji = "\xf0\x9f\x88\xb6" }, // 🈶
    .{ .name = "u6e80", .emoji = "\xf0\x9f\x88\xb5" }, // 🈵
    .{ .name = "u7121", .emoji = "\xf0\x9f\x88\x9a" }, // 🈚
    .{ .name = "u7533", .emoji = "\xf0\x9f\x88\xb8" }, // 🈸
    .{ .name = "u7981", .emoji = "\xf0\x9f\x88\xb2" }, // 🈲
    .{ .name = "u7a7a", .emoji = "\xf0\x9f\x88\xb3" }, // 🈳
    .{ .name = "uganda", .emoji = "\xf0\x9f\x87\xba\xf0\x9f\x87\xac" }, // 🇺🇬
    .{ .name = "uk", .emoji = "\xf0\x9f\x87\xac\xf0\x9f\x87\xa7" }, // 🇬🇧
    .{ .name = "ukraine", .emoji = "\xf0\x9f\x87\xba\xf0\x9f\x87\xa6" }, // 🇺🇦
    .{ .name = "umbrella", .emoji = "\xe2\x98\x94" }, // ☔
    .{ .name = "unamused", .emoji = "\xf0\x9f\x98\x92" }, // 😒
    .{ .name = "underage", .emoji = "\xf0\x9f\x94\x9e" }, // 🔞
    .{ .name = "unicorn", .emoji = "\xf0\x9f\xa6\x84" }, // 🦄
    .{ .name = "united_arab_emirates", .emoji = "\xf0\x9f\x87\xa6\xf0\x9f\x87\xaa" }, // 🇦🇪
    .{ .name = "united_nations", .emoji = "\xf0\x9f\x87\xba\xf0\x9f\x87\xb3" }, // 🇺🇳
    .{ .name = "unlock", .emoji = "\xf0\x9f\x94\x93" }, // 🔓
    .{ .name = "up", .emoji = "\xf0\x9f\x86\x99" }, // 🆙
    .{ .name = "upside_down_face", .emoji = "\xf0\x9f\x99\x83" }, // 🙃
    .{ .name = "uruguay", .emoji = "\xf0\x9f\x87\xba\xf0\x9f\x87\xbe" }, // 🇺🇾
    .{ .name = "us", .emoji = "\xf0\x9f\x87\xba\xf0\x9f\x87\xb8" }, // 🇺🇸
    .{ .name = "us_outlying_islands", .emoji = "\xf0\x9f\x87\xba\xf0\x9f\x87\xb2" }, // 🇺🇲
    .{ .name = "us_virgin_islands", .emoji = "\xf0\x9f\x87\xbb\xf0\x9f\x87\xae" }, // 🇻🇮
    .{ .name = "uzbekistan", .emoji = "\xf0\x9f\x87\xba\xf0\x9f\x87\xbf" }, // 🇺🇿
    .{ .name = "v", .emoji = "\xe2\x9c\x8c" }, // ✌
    .{ .name = "vampire", .emoji = "\xf0\x9f\xa7\x9b" }, // 🧛
    .{ .name = "vampire_man", .emoji = "\xf0\x9f\xa7\x9b\xe2\x99\x82" }, // 🧛♂
    .{ .name = "vampire_woman", .emoji = "\xf0\x9f\xa7\x9b\xe2\x99\x80" }, // 🧛♀
    .{ .name = "vanuatu", .emoji = "\xf0\x9f\x87\xbb\xf0\x9f\x87\xba" }, // 🇻🇺
    .{ .name = "vatican_city", .emoji = "\xf0\x9f\x87\xbb\xf0\x9f\x87\xa6" }, // 🇻🇦
    .{ .name = "venezuela", .emoji = "\xf0\x9f\x87\xbb\xf0\x9f\x87\xaa" }, // 🇻🇪
    .{ .name = "vertical_traffic_light", .emoji = "\xf0\x9f\x9a\xa6" }, // 🚦
    .{ .name = "vhs", .emoji = "\xf0\x9f\x93\xbc" }, // 📼
    .{ .name = "vibration_mode", .emoji = "\xf0\x9f\x93\xb3" }, // 📳
    .{ .name = "video_camera", .emoji = "\xf0\x9f\x93\xb9" }, // 📹
    .{ .name = "video_game", .emoji = "\xf0\x9f\x8e\xae" }, // 🎮
    .{ .name = "vietnam", .emoji = "\xf0\x9f\x87\xbb\xf0\x9f\x87\xb3" }, // 🇻🇳
    .{ .name = "violin", .emoji = "\xf0\x9f\x8e\xbb" }, // 🎻
    .{ .name = "virgo", .emoji = "\xe2\x99\x8d" }, // ♍
    .{ .name = "volcano", .emoji = "\xf0\x9f\x8c\x8b" }, // 🌋
    .{ .name = "volleyball", .emoji = "\xf0\x9f\x8f\x90" }, // 🏐
    .{ .name = "vomiting_face", .emoji = "\xf0\x9f\xa4\xae" }, // 🤮
    .{ .name = "vs", .emoji = "\xf0\x9f\x86\x9a" }, // 🆚
    .{ .name = "vulcan_salute", .emoji = "\xf0\x9f\x96\x96" }, // 🖖
    .{ .name = "waffle", .emoji = "\xf0\x9f\xa7\x87" }, // 🧇
    .{ .name = "wales", .emoji = "\xf0\x9f\x8f\xb4\xf3\xa0\x81\xa7\xf3\xa0\x81\xa2\xf3\xa0\x81\xb7\xf3\xa0\x81\xac\xf3\xa0\x81\xb3\xf3\xa0\x81\xbf" }, // 🏴󠁧󠁢󠁷󠁬󠁳󠁿
    .{ .name = "walking", .emoji = "\xf0\x9f\x9a\xb6" }, // 🚶
    .{ .name = "walking_man", .emoji = "\xf0\x9f\x9a\xb6\xe2\x99\x82" }, // 🚶♂
    .{ .name = "walking_woman", .emoji = "\xf0\x9f\x9a\xb6\xe2\x99\x80" }, // 🚶♀
    .{ .name = "wallis_futuna", .emoji = "\xf0\x9f\x87\xbc\xf0\x9f\x87\xab" }, // 🇼🇫
    .{ .name = "waning_crescent_moon", .emoji = "\xf0\x9f\x8c\x98" }, // 🌘
    .{ .name = "waning_gibbous_moon", .emoji = "\xf0\x9f\x8c\x96" }, // 🌖
    .{ .name = "warning", .emoji = "\xe2\x9a\xa0" }, // ⚠
    .{ .name = "wastebasket", .emoji = "\xf0\x9f\x97\x91" }, // 🗑
    .{ .name = "watch", .emoji = "\xe2\x8c\x9a" }, // ⌚
    .{ .name = "water_buffalo", .emoji = "\xf0\x9f\x90\x83" }, // 🐃
    .{ .name = "water_polo", .emoji = "\xf0\x9f\xa4\xbd" }, // 🤽
    .{ .name = "watermelon", .emoji = "\xf0\x9f\x8d\x89" }, // 🍉
    .{ .name = "wave", .emoji = "\xf0\x9f\x91\x8b" }, // 👋
    .{ .name = "wavy_dash", .emoji = "\xe3\x80\xb0" }, // 〰
    .{ .name = "waxing_crescent_moon", .emoji = "\xf0\x9f\x8c\x92" }, // 🌒
    .{ .name = "waxing_gibbous_moon", .emoji = "\xf0\x9f\x8c\x94" }, // 🌔
    .{ .name = "wc", .emoji = "\xf0\x9f\x9a\xbe" }, // 🚾
    .{ .name = "weary", .emoji = "\xf0\x9f\x98\xa9" }, // 😩
    .{ .name = "wedding", .emoji = "\xf0\x9f\x92\x92" }, // 💒
    .{ .name = "weight_lifting", .emoji = "\xf0\x9f\x8f\x8b" }, // 🏋
    .{ .name = "weight_lifting_man", .emoji = "\xf0\x9f\x8f\x8b\xe2\x99\x82" }, // 🏋♂
    .{ .name = "weight_lifting_woman", .emoji = "\xf0\x9f\x8f\x8b\xe2\x99\x80" }, // 🏋♀
    .{ .name = "western_sahara", .emoji = "\xf0\x9f\x87\xaa\xf0\x9f\x87\xad" }, // 🇪🇭
    .{ .name = "whale", .emoji = "\xf0\x9f\x90\xb3" }, // 🐳
    .{ .name = "whale2", .emoji = "\xf0\x9f\x90\x8b" }, // 🐋
    .{ .name = "wheel", .emoji = "\xf0\x9f\x9b\x9e" }, // 🛞
    .{ .name = "wheel_of_dharma", .emoji = "\xe2\x98\xb8" }, // ☸
    .{ .name = "wheelchair", .emoji = "\xe2\x99\xbf" }, // ♿
    .{ .name = "white_check_mark", .emoji = "\xe2\x9c\x85" }, // ✅
    .{ .name = "white_circle", .emoji = "\xe2\x9a\xaa" }, // ⚪
    .{ .name = "white_flag", .emoji = "\xf0\x9f\x8f\xb3" }, // 🏳
    .{ .name = "white_flower", .emoji = "\xf0\x9f\x92\xae" }, // 💮
    .{ .name = "white_haired_man", .emoji = "\xf0\x9f\x91\xa8\xf0\x9f\xa6\xb3" }, // 👨🦳
    .{ .name = "white_haired_woman", .emoji = "\xf0\x9f\x91\xa9\xf0\x9f\xa6\xb3" }, // 👩🦳
    .{ .name = "white_heart", .emoji = "\xf0\x9f\xa4\x8d" }, // 🤍
    .{ .name = "white_large_square", .emoji = "\xe2\xac\x9c" }, // ⬜
    .{ .name = "white_medium_small_square", .emoji = "\xe2\x97\xbd" }, // ◽
    .{ .name = "white_medium_square", .emoji = "\xe2\x97\xbb" }, // ◻
    .{ .name = "white_small_square", .emoji = "\xe2\x96\xab" }, // ▫
    .{ .name = "white_square_button", .emoji = "\xf0\x9f\x94\xb3" }, // 🔳
    .{ .name = "wilted_flower", .emoji = "\xf0\x9f\xa5\x80" }, // 🥀
    .{ .name = "wind_chime", .emoji = "\xf0\x9f\x8e\x90" }, // 🎐
    .{ .name = "wind_face", .emoji = "\xf0\x9f\x8c\xac" }, // 🌬
    .{ .name = "window", .emoji = "\xf0\x9f\xaa\x9f" }, // 🪟
    .{ .name = "wine_glass", .emoji = "\xf0\x9f\x8d\xb7" }, // 🍷
    .{ .name = "wing", .emoji = "\xf0\x9f\xaa\xbd" }, // 🪽
    .{ .name = "wink", .emoji = "\xf0\x9f\x98\x89" }, // 😉
    .{ .name = "wireless", .emoji = "\xf0\x9f\x9b\x9c" }, // 🛜
    .{ .name = "wolf", .emoji = "\xf0\x9f\x90\xba" }, // 🐺
    .{ .name = "woman", .emoji = "\xf0\x9f\x91\xa9" }, // 👩
    .{ .name = "woman_artist", .emoji = "\xf0\x9f\x91\xa9\xf0\x9f\x8e\xa8" }, // 👩🎨
    .{ .name = "woman_astronaut", .emoji = "\xf0\x9f\x91\xa9\xf0\x9f\x9a\x80" }, // 👩🚀
    .{ .name = "woman_beard", .emoji = "\xf0\x9f\xa7\x94\xe2\x99\x80" }, // 🧔♀
    .{ .name = "woman_cartwheeling", .emoji = "\xf0\x9f\xa4\xb8\xe2\x99\x80" }, // 🤸♀
    .{ .name = "woman_cook", .emoji = "\xf0\x9f\x91\xa9\xf0\x9f\x8d\xb3" }, // 👩🍳
    .{ .name = "woman_dancing", .emoji = "\xf0\x9f\x92\x83" }, // 💃
    .{ .name = "woman_facepalming", .emoji = "\xf0\x9f\xa4\xa6\xe2\x99\x80" }, // 🤦♀
    .{ .name = "woman_factory_worker", .emoji = "\xf0\x9f\x91\xa9\xf0\x9f\x8f\xad" }, // 👩🏭
    .{ .name = "woman_farmer", .emoji = "\xf0\x9f\x91\xa9\xf0\x9f\x8c\xbe" }, // 👩🌾
    .{ .name = "woman_feeding_baby", .emoji = "\xf0\x9f\x91\xa9\xf0\x9f\x8d\xbc" }, // 👩🍼
    .{ .name = "woman_firefighter", .emoji = "\xf0\x9f\x91\xa9\xf0\x9f\x9a\x92" }, // 👩🚒
    .{ .name = "woman_health_worker", .emoji = "\xf0\x9f\x91\xa9\xe2\x9a\x95" }, // 👩⚕
    .{ .name = "woman_in_manual_wheelchair", .emoji = "\xf0\x9f\x91\xa9\xf0\x9f\xa6\xbd" }, // 👩🦽
    .{ .name = "woman_in_motorized_wheelchair", .emoji = "\xf0\x9f\x91\xa9\xf0\x9f\xa6\xbc" }, // 👩🦼
    .{ .name = "woman_in_tuxedo", .emoji = "\xf0\x9f\xa4\xb5\xe2\x99\x80" }, // 🤵♀
    .{ .name = "woman_judge", .emoji = "\xf0\x9f\x91\xa9\xe2\x9a\x96" }, // 👩⚖
    .{ .name = "woman_juggling", .emoji = "\xf0\x9f\xa4\xb9\xe2\x99\x80" }, // 🤹♀
    .{ .name = "woman_mechanic", .emoji = "\xf0\x9f\x91\xa9\xf0\x9f\x94\xa7" }, // 👩🔧
    .{ .name = "woman_office_worker", .emoji = "\xf0\x9f\x91\xa9\xf0\x9f\x92\xbc" }, // 👩💼
    .{ .name = "woman_pilot", .emoji = "\xf0\x9f\x91\xa9\xe2\x9c\x88" }, // 👩✈
    .{ .name = "woman_playing_handball", .emoji = "\xf0\x9f\xa4\xbe\xe2\x99\x80" }, // 🤾♀
    .{ .name = "woman_playing_water_polo", .emoji = "\xf0\x9f\xa4\xbd\xe2\x99\x80" }, // 🤽♀
    .{ .name = "woman_scientist", .emoji = "\xf0\x9f\x91\xa9\xf0\x9f\x94\xac" }, // 👩🔬
    .{ .name = "woman_shrugging", .emoji = "\xf0\x9f\xa4\xb7\xe2\x99\x80" }, // 🤷♀
    .{ .name = "woman_singer", .emoji = "\xf0\x9f\x91\xa9\xf0\x9f\x8e\xa4" }, // 👩🎤
    .{ .name = "woman_student", .emoji = "\xf0\x9f\x91\xa9\xf0\x9f\x8e\x93" }, // 👩🎓
    .{ .name = "woman_teacher", .emoji = "\xf0\x9f\x91\xa9\xf0\x9f\x8f\xab" }, // 👩🏫
    .{ .name = "woman_technologist", .emoji = "\xf0\x9f\x91\xa9\xf0\x9f\x92\xbb" }, // 👩💻
    .{ .name = "woman_with_headscarf", .emoji = "\xf0\x9f\xa7\x95" }, // 🧕
    .{ .name = "woman_with_probing_cane", .emoji = "\xf0\x9f\x91\xa9\xf0\x9f\xa6\xaf" }, // 👩🦯
    .{ .name = "woman_with_turban", .emoji = "\xf0\x9f\x91\xb3\xe2\x99\x80" }, // 👳♀
    .{ .name = "woman_with_veil", .emoji = "\xf0\x9f\x91\xb0\xe2\x99\x80" }, // 👰♀
    .{ .name = "womans_clothes", .emoji = "\xf0\x9f\x91\x9a" }, // 👚
    .{ .name = "womans_hat", .emoji = "\xf0\x9f\x91\x92" }, // 👒
    .{ .name = "women_wrestling", .emoji = "\xf0\x9f\xa4\xbc\xe2\x99\x80" }, // 🤼♀
    .{ .name = "womens", .emoji = "\xf0\x9f\x9a\xba" }, // 🚺
    .{ .name = "wood", .emoji = "\xf0\x9f\xaa\xb5" }, // 🪵
    .{ .name = "woozy_face", .emoji = "\xf0\x9f\xa5\xb4" }, // 🥴
    .{ .name = "world_map", .emoji = "\xf0\x9f\x97\xba" }, // 🗺
    .{ .name = "worm", .emoji = "\xf0\x9f\xaa\xb1" }, // 🪱
    .{ .name = "worried", .emoji = "\xf0\x9f\x98\x9f" }, // 😟
    .{ .name = "wrench", .emoji = "\xf0\x9f\x94\xa7" }, // 🔧
    .{ .name = "wrestling", .emoji = "\xf0\x9f\xa4\xbc" }, // 🤼
    .{ .name = "writing_hand", .emoji = "\xe2\x9c\x8d" }, // ✍
    .{ .name = "x", .emoji = "\xe2\x9d\x8c" }, // ❌
    .{ .name = "x_ray", .emoji = "\xf0\x9f\xa9\xbb" }, // 🩻
    .{ .name = "yarn", .emoji = "\xf0\x9f\xa7\xb6" }, // 🧶
    .{ .name = "yawning_face", .emoji = "\xf0\x9f\xa5\xb1" }, // 🥱
    .{ .name = "yellow_circle", .emoji = "\xf0\x9f\x9f\xa1" }, // 🟡
    .{ .name = "yellow_heart", .emoji = "\xf0\x9f\x92\x9b" }, // 💛
    .{ .name = "yellow_square", .emoji = "\xf0\x9f\x9f\xa8" }, // 🟨
    .{ .name = "yemen", .emoji = "\xf0\x9f\x87\xbe\xf0\x9f\x87\xaa" }, // 🇾🇪
    .{ .name = "yen", .emoji = "\xf0\x9f\x92\xb4" }, // 💴
    .{ .name = "yin_yang", .emoji = "\xe2\x98\xaf" }, // ☯
    .{ .name = "yo_yo", .emoji = "\xf0\x9f\xaa\x80" }, // 🪀
    .{ .name = "yum", .emoji = "\xf0\x9f\x98\x8b" }, // 😋
    .{ .name = "zambia", .emoji = "\xf0\x9f\x87\xbf\xf0\x9f\x87\xb2" }, // 🇿🇲
    .{ .name = "zany_face", .emoji = "\xf0\x9f\xa4\xaa" }, // 🤪
    .{ .name = "zap", .emoji = "\xe2\x9a\xa1" }, // ⚡
    .{ .name = "zebra", .emoji = "\xf0\x9f\xa6\x93" }, // 🦓
    .{ .name = "zero", .emoji = "\x30\xe2\x83\xa3" }, // 0⃣
    .{ .name = "zimbabwe", .emoji = "\xf0\x9f\x87\xbf\xf0\x9f\x87\xbc" }, // 🇿🇼
    .{ .name = "zipper_mouth_face", .emoji = "\xf0\x9f\xa4\x90" }, // 🤐
    .{ .name = "zombie", .emoji = "\xf0\x9f\xa7\x9f" }, // 🧟
    .{ .name = "zombie_man", .emoji = "\xf0\x9f\xa7\x9f\xe2\x99\x82" }, // 🧟♂
    .{ .name = "zombie_woman", .emoji = "\xf0\x9f\xa7\x9f\xe2\x99\x80" }, // 🧟♀
    .{ .name = "zzz", .emoji = "\xf0\x9f\x92\xa4" }, // 💤
};

/// Look up an emoji shortcode name (without colons).
/// Returns the UTF-8 emoji string, or null if not found.
pub fn lookupShortcode(name: []const u8) ?[]const u8 {
    var low: usize = 0;
    var high: usize = emoji_table.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const cmp = std.mem.order(u8, emoji_table[mid].name, name);
        switch (cmp) {
            .lt => low = mid + 1,
            .gt => high = mid,
            .eq => return emoji_table[mid].emoji,
        }
    }
    return null;
}

/// Replace all emoji shortcodes in `text` with their Unicode equivalents.
/// Allocates the result with the given arena allocator.
/// Returns null if no shortcodes were found (caller can use original text).
pub fn replaceShortcodes(arena: std.mem.Allocator, text: []const u8) ?[]const u8 {
    // Quick scan: does the text contain any colons?
    if (std.mem.indexOfScalar(u8, text, ':') == null) return null;

    var result = std.ArrayList(u8).init(arena);
    var found_any = false;
    var i: usize = 0;

    while (i < text.len) {
        if (text[i] == ':') {
            // Look for closing colon
            if (i + 1 < text.len) {
                if (std.mem.indexOfScalar(u8, text[i + 1 ..], ':')) |end_offset| {
                    const name = text[i + 1 .. i + 1 + end_offset];
                    // Shortcode names are alphanumeric + underscore + hyphen + digits
                    if (isValidShortcodeName(name)) {
                        if (lookupShortcode(name)) |emoji_val| {
                            // Arena OOM during emoji replacement is non-fatal; return unmodified text
                            result.appendSlice(emoji_val) catch return null;
                            found_any = true;
                            i += end_offset + 2; // Skip past closing colon
                            continue;
                        }
                    }
                }
            }
        }
        result.append(text[i]) catch return null; // Arena OOM; non-fatal
        i += 1;
    }

    if (!found_any) return null;
    return result.items;
}

fn isValidShortcodeName(name: []const u8) bool {
    if (name.len == 0 or name.len > 50) return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-' and c != '+') return false;
    }
    return true;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "lookupShortcode finds known emoji" {
    try testing.expect(lookupShortcode("smile") != null);
    try testing.expect(lookupShortcode("rocket") != null);
    try testing.expect(lookupShortcode("heart") != null);
    try testing.expect(lookupShortcode("+1") != null);
    try testing.expect(lookupShortcode("fire") != null);
    try testing.expect(lookupShortcode("tada") != null);
    try testing.expect(lookupShortcode("octocat") == null); // Custom GitHub emoji, not Unicode
}

test "lookupShortcode returns null for unknown" {
    try testing.expectEqual(@as(?[]const u8, null), lookupShortcode("nonexistent_emoji"));
    try testing.expectEqual(@as(?[]const u8, null), lookupShortcode(""));
}

test "lookupShortcode returns correct emoji" {
    // Rocket is U+1F680 = F0 9F 9A 80 in UTF-8
    const rocket = lookupShortcode("rocket").?;
    try testing.expectEqualStrings("\xf0\x9f\x9a\x80", rocket);
}

test "lookupShortcode covers full GitHub set" {
    // Verify table size covers the full GitHub emoji set
    try testing.expect(emoji_table.len >= 1800);
}

test "replaceShortcodes replaces known shortcodes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = replaceShortcodes(arena.allocator(), "Hello :rocket: world").?;
    try testing.expect(std.mem.indexOf(u8, result, "\xf0\x9f\x9a\x80") != null);
    try testing.expect(std.mem.indexOf(u8, result, ":rocket:") == null);
}

test "replaceShortcodes returns null when no shortcodes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(?[]const u8, null), replaceShortcodes(arena.allocator(), "No emoji here"));
}

test "replaceShortcodes returns null when no colons" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(?[]const u8, null), replaceShortcodes(arena.allocator(), "plain text"));
}

test "replaceShortcodes preserves unknown shortcodes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = replaceShortcodes(arena.allocator(), "Hello :unknown_code: world");
    // No known shortcode found, returns null
    try testing.expectEqual(@as(?[]const u8, null), result);
}

test "replaceShortcodes handles multiple shortcodes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = replaceShortcodes(arena.allocator(), ":fire: and :rocket:").?;
    // Should contain both emoji
    try testing.expect(std.mem.indexOf(u8, result, "\xf0\x9f\x94\xa5") != null); // fire
    try testing.expect(std.mem.indexOf(u8, result, "\xf0\x9f\x9a\x80") != null); // rocket
}

test "replaceShortcodes handles colon in non-shortcode context" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = replaceShortcodes(arena.allocator(), "time: 12:30 :smile:");
    // Should still find and replace :smile: even with other colons
    try testing.expect(result != null);
    if (result) |r| {
        try testing.expect(std.mem.indexOf(u8, r, "\xf0\x9f\x98\x84") != null); // smile
    }
}

test "isValidShortcodeName rejects empty" {
    try testing.expect(!isValidShortcodeName(""));
}

test "isValidShortcodeName accepts valid names" {
    try testing.expect(isValidShortcodeName("smile"));
    try testing.expect(isValidShortcodeName("+1"));
    try testing.expect(isValidShortcodeName("heart_eyes"));
    try testing.expect(isValidShortcodeName("ok_hand"));
}

test "isValidShortcodeName rejects names with spaces" {
    try testing.expect(!isValidShortcodeName("not valid"));
}

test "emoji_table is sorted" {
    for (1..emoji_table.len) |i| {
        const order = std.mem.order(u8, emoji_table[i - 1].name, emoji_table[i].name);
        try testing.expect(order == .lt);
    }
}

test "replaceShortcodes handles country flag emoji" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // :us: should resolve to the US flag emoji
    const result = replaceShortcodes(arena.allocator(), ":us:");
    try testing.expect(result != null);
}

test "replaceShortcodes handles skin tone variants" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Some emoji have skin tone suffixes
    if (lookupShortcode("wave")) |_| {
        const result = replaceShortcodes(arena.allocator(), ":wave:");
        try testing.expect(result != null);
    }
}

// =============================================================================
// Extended tests: common codes with verified UTF-8, edge cases, escaped colons
// =============================================================================

test "lookupShortcode returns correct UTF-8 for common codes" {
    // :rocket: -> U+1F680 = F0 9F 9A 80
    try testing.expectEqualStrings("\xf0\x9f\x9a\x80", lookupShortcode("rocket").?);
    // :smile: -> U+1F604 = F0 9F 98 84
    try testing.expectEqualStrings("\xf0\x9f\x98\x84", lookupShortcode("smile").?);
    // :+1: -> U+1F44D = F0 9F 91 8D
    try testing.expectEqualStrings("\xf0\x9f\x91\x8d", lookupShortcode("+1").?);
    // :heart: -> U+2764 = E2 9D A4
    try testing.expectEqualStrings("\xe2\x9d\xa4", lookupShortcode("heart").?);
    // :thumbsup: -> U+1F44D = F0 9F 91 8D (alias for +1)
    try testing.expectEqualStrings("\xf0\x9f\x91\x8d", lookupShortcode("thumbsup").?);
    // :tada: -> U+1F389 = F0 9F 8E 89
    try testing.expectEqualStrings("\xf0\x9f\x8e\x89", lookupShortcode("tada").?);
    // :sparkles: -> U+2728 = E2 9C A8
    try testing.expectEqualStrings("\xe2\x9c\xa8", lookupShortcode("sparkles").?);
    // :warning: -> U+26A0 = E2 9A A0
    try testing.expectEqualStrings("\xe2\x9a\xa0", lookupShortcode("warning").?);
    // :eyes: -> U+1F440 = F0 9F 91 80
    try testing.expectEqualStrings("\xf0\x9f\x91\x80", lookupShortcode("eyes").?);
    // :star: -> U+2B50 = E2 AD 90
    try testing.expectEqualStrings("\xe2\xad\x90", lookupShortcode("star").?);
}

test "lookupShortcode returns null for various unknown codes" {
    try testing.expectEqual(@as(?[]const u8, null), lookupShortcode("nonexistent"));
    try testing.expectEqual(@as(?[]const u8, null), lookupShortcode("ROCKET")); // case-sensitive
    try testing.expectEqual(@as(?[]const u8, null), lookupShortcode("Smile")); // case-sensitive
    try testing.expectEqual(@as(?[]const u8, null), lookupShortcode(" ")); // space not valid
    try testing.expectEqual(@as(?[]const u8, null), lookupShortcode("a_very_long_name_that_does_not_exist"));
}

test "replaceShortcodes leaves escaped/backslash colons unchanged" {
    // Backslash before colon: `\:smile\:` — the backslash is not valid in a shortcode name
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const input = "text \\:smile\\: more";
    const result = replaceShortcodes(arena.allocator(), input);
    // `\:smile\` between first `:` and second `:` contains backslashes,
    // which fail isValidShortcodeName, so no replacement happens.
    try testing.expectEqual(@as(?[]const u8, null), result);
}

test "replaceShortcodes handles single colon without closing pair" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // A trailing colon with no closing colon — no shortcode match possible
    const result = replaceShortcodes(arena.allocator(), "Note: this has a colon");
    try testing.expectEqual(@as(?[]const u8, null), result);
}

test "replaceShortcodes handles adjacent shortcodes without separator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = replaceShortcodes(arena.allocator(), ":fire::rocket::star:").?;
    try testing.expect(std.mem.indexOf(u8, result, "\xf0\x9f\x94\xa5") != null); // fire
    try testing.expect(std.mem.indexOf(u8, result, "\xf0\x9f\x9a\x80") != null); // rocket
    try testing.expect(std.mem.indexOf(u8, result, "\xe2\xad\x90") != null); // star
    // No colons should remain — all three shortcodes were valid
    try testing.expect(std.mem.indexOfScalar(u8, result, ':') == null);
}

test "replaceShortcodes preserves surrounding text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = replaceShortcodes(arena.allocator(), "Launch :rocket: now!").?;
    try testing.expect(std.mem.startsWith(u8, result, "Launch "));
    try testing.expect(std.mem.endsWith(u8, result, " now!"));
}

test "replaceShortcodes mixed known and unknown codes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = replaceShortcodes(arena.allocator(), ":smile: and :fake_code: end").?;
    // :smile: replaced, :fake_code: left as-is
    try testing.expect(std.mem.indexOf(u8, result, "\xf0\x9f\x98\x84") != null); // smile emoji
    try testing.expect(std.mem.indexOf(u8, result, ":fake_code:") != null); // unknown left verbatim
}

test "replaceShortcodes shortcode at start and end of text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result_start = replaceShortcodes(arena.allocator(), ":fire: begins").?;
    try testing.expect(std.mem.startsWith(u8, result_start, "\xf0\x9f\x94\xa5"));

    const result_end = replaceShortcodes(arena.allocator(), "ends :fire:").?;
    try testing.expect(std.mem.endsWith(u8, result_end, "\xf0\x9f\x94\xa5"));
}

test "replaceShortcodes only a shortcode with no surrounding text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = replaceShortcodes(arena.allocator(), ":rocket:").?;
    try testing.expectEqualStrings("\xf0\x9f\x9a\x80", result);
}

test "replaceShortcodes colons with invalid shortcode names" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Spaces inside colons — not a valid shortcode name
    const r1 = replaceShortcodes(arena.allocator(), ":not valid:");
    try testing.expectEqual(@as(?[]const u8, null), r1);

    // Empty between colons — not valid
    const r2 = replaceShortcodes(arena.allocator(), ":: empty");
    try testing.expectEqual(@as(?[]const u8, null), r2);
}

test "replaceShortcodes +1 and -1 shortcodes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = replaceShortcodes(arena.allocator(), ":+1: and :-1:").?;
    try testing.expect(std.mem.indexOf(u8, result, "\xf0\x9f\x91\x8d") != null); // thumbs up
    try testing.expect(std.mem.indexOf(u8, result, "\xf0\x9f\x91\x8e") != null); // thumbs down
}

test "isValidShortcodeName rejects special characters" {
    try testing.expect(!isValidShortcodeName("has.dot"));
    try testing.expect(!isValidShortcodeName("has/slash"));
    try testing.expect(!isValidShortcodeName("has:colon"));
    try testing.expect(!isValidShortcodeName("has@at"));
    try testing.expect(!isValidShortcodeName("has!bang"));
}

test "isValidShortcodeName accepts hyphens and plus" {
    try testing.expect(isValidShortcodeName("-1"));
    try testing.expect(isValidShortcodeName("+1"));
    try testing.expect(isValidShortcodeName("heavy-check"));
    try testing.expect(isValidShortcodeName("crossed_fingers"));
}

test "isValidShortcodeName rejects overly long names" {
    const long_name = "a" ** 51; // 51 chars exceeds the 50-char limit
    try testing.expect(!isValidShortcodeName(long_name));
    const max_name = "a" ** 50; // exactly 50 is ok
    try testing.expect(isValidShortcodeName(max_name));
}
