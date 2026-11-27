package enum LosslessTileGrid {
    package static func rectangles(width: Int, height: Int) -> [PixelRect] {
        guard width >= 8, height >= 4 else { return [] }
        return (0..<32).map { index in
            let column = index % 8
            let row = index / 8
            let x = column * width / 8
            let y = row * height / 4
            return PixelRect(x: x, y: y, width: (column + 1) * width / 8 - x, height: (row + 1) * height / 4 - y)
        }
    }
}
