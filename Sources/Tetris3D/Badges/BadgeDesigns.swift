import MetaGame
import simd

/// A badge emblem: voxel pixel art built from the game's rounded cubes, standing on a medallion plate.
///
/// String art, top row first. A letter places one cube in that palette colour; an uppercase letter stacks a second
/// cube in front of it for relief. `.` leaves the cell empty.
struct BadgeDesign {
    var rows: [String]

    init(_ rows: String...) {
        self.rows = rows
    }

    static func color(_ code: Character) -> SIMD3<Float>? {
        switch code.lowercased() {
        case "c": GameScene.color(.i)
        case "y": GameScene.color(.o)
        case "p": GameScene.color(.t)
        case "g": GameScene.color(.s)
        case "r": GameScene.color(.z)
        case "b": GameScene.color(.j)
        case "o": GameScene.color(.l)
        case "m": [0.95, 0.20, 0.62]
        case "w": [0.62, 0.69, 0.84]
        case "x": [0.12, 0.13, 0.16]
        default: nil
        }
    }

    /// Shown in place of a secret achievement's emblem until it is unlocked.
    static let secret = BadgeDesign(
        ".www.",
        "w...w",
        "....w",
        "..ww.",
        "..w..",
        ".....",
        "..w.."
    )
}

extension Achievement {
    /// Plate trim and neon colour.
    var badgeTint: SIMD3<Float> {
        switch tier {
        case .bronze: [1.0, 0.42, 0.14]
        case .silver: [0.45, 0.78, 1.0]
        case .gold: [1.0, 0.72, 0.16]
        }
    }

    var badgeDesign: BadgeDesign {
        switch self {
        case .firstLine:
            // A sparkle over the first cleared line.
            BadgeDesign(
                "...w...",
                "..wWw..",
                "...w...",
                ".......",
                "rogcbpy"
            )
        case .tetris:
            // The I piece dropped into its well.
            BadgeDesign(
                "xxCxx",
                "xxCxx",
                "xxCxx",
                "xxCxx"
            )
        case .tSpin:
            // A T inside a turning arrow.
            BadgeDesign(
                "..www..",
                ".w...w.",
                "w....Ww",
                "w.PPP..",
                "w..P...",
                ".w...w.",
                "..www.."
            )
        case .tSpinDouble:
            BadgeDesign(
                "..PPP..",
                "...P...",
                "wwwwwww",
                ".......",
                "wwwwwww"
            )
        case .tSpinTriple:
            BadgeDesign(
                "..PPP..",
                "...P...",
                "wwwwwww",
                ".......",
                "wwwwwww",
                ".......",
                "wwwwwww"
            )
        case .backToBack:
            BadgeDesign(
                "....ccc",
                "......c",
                "w.w.ccc",
                ".W..c..",
                "w.w.ccc"
            )
        case .combo5:
            // Two interlocked chain links.
            BadgeDesign(
                "oooo...",
                "o..o...",
                "o..OOOO",
                "oooO..O",
                "...O..O",
                "...OOOO"
            )
        case .combo10:
            BadgeDesign(
                "...yy",
                "..yy.",
                ".yy..",
                "yYYYy",
                "..yy.",
                ".yy..",
                "yy..."
            )
        case .perfectClear:
            BadgeDesign(
                "...w...",
                "...w...",
                "wwwWwww",
                ".wWWWw.",
                "..www..",
                ".ww.ww.",
                "ww...ww"
            )
        case .level10:
            BadgeDesign(
                ".g..ggg",
                "gg..g.g",
                ".g..g.g",
                ".g..g.g",
                "ggg.ggg"
            )
        case .level15:
            // A flag planted on a snowy peak.
            BadgeDesign(
                "...wrr.",
                "...w...",
                "...w...",
                "..www..",
                ".bbbbb.",
                "bbbbbbb"
            )
        case .marathon:
            BadgeDesign(
                "wwxwxw",
                "wxwxwx",
                "wwxwxw",
                "wxwxwx",
                "w.....",
                "w....."
            )
        case .sprint:
            BadgeDesign(
                "gg.gg..",
                ".gg.gg.",
                "..gg.gg",
                ".gg.gg.",
                "gg.gg.."
            )
        case .sprintUnder60:
            BadgeDesign(
                "..www..",
                "...w...",
                ".wwwww.",
                "w..Y..w",
                "w..YY.w",
                "w.....w",
                ".wwwww."
            )
        case .ultra20k:
            // A die showing five.
            BadgeDesign(
                "rrrrrrr",
                "rWrrrWr",
                "rrrrrrr",
                "rrrWrrr",
                "rrrrrrr",
                "rWrrrWr",
                "rrrrrrr"
            )
        case .dig:
            // A shovel, handle up.
            BadgeDesign(
                ".....oo",
                ".....oo",
                "....o..",
                "..wo...",
                ".www...",
                "wwww...",
                ".ww...."
            )
        case .zen100:
            // A lotus on still water.
            BadgeDesign(
                "...m...",
                "..mMm..",
                "m.mMm.m",
                "mm.m.mm",
                ".mmmmm.",
                ".......",
                "ccccccc"
            )
        case .lines1000:
            BadgeDesign(
                ".cc...cc.",
                "c..c.c..c",
                "c...C...c",
                "c..c.c..c",
                ".cc...cc."
            )
        case .tetrises100:
            BadgeDesign(
                "Y..Y..Y",
                "yy.y.yy",
                "yyyyyyy",
                "yCyRyCy",
                "yyyyyyy"
            )
        case .explorer:
            // Map pin.
            BadgeDesign(
                ".bbb.",
                "bbbbb",
                "bb.bb",
                "bbbbb",
                ".bbb.",
                "..b.."
            )
        case .regular:
            // A player's heart.
            BadgeDesign(
                ".rr.rr.",
                "rWWrrrr",
                "rWrrrrr",
                ".rrrrr.",
                "..rrr..",
                "...r..."
            )
        case .closeCall:
            BadgeDesign(
                "...y...",
                "..yRy..",
                "..yRy..",
                ".yyRyy.",
                ".yyyyy.",
                "yyyRyyy",
                "yyyyyyy"
            )
        case .purist:
            // A flawless gem.
            BadgeDesign(
                ".CCCCC.",
                "ccccccc",
                ".ccccc.",
                "..ccc..",
                "...c..."
            )
        }
    }
}
