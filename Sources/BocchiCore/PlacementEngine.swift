public enum PlacementEngine {
    public static func choose(
        in screen: PetRect,
        avoiding obstacles: [PetRect],
        size: PetSize,
        previous: PetRect?
    ) -> PetRect? {
        guard screen.x.isFinite, screen.y.isFinite,
              screen.width.isFinite, screen.height.isFinite,
              size.width.isFinite, size.height.isFinite,
              screen.width > 0, screen.height > 0,
              size.width > 0, size.height > 0,
              size.width <= screen.width, size.height <= screen.height else {
            return nil
        }

        let padding = 12.0
        let paddedObstacles = obstacles.compactMap { obstacle -> PetRect? in
            guard obstacle.x.isFinite, obstacle.y.isFinite,
                  obstacle.width.isFinite, obstacle.height.isFinite,
                  obstacle.width > 0, obstacle.height > 0 else { return nil }
            return PetRect(
                x: obstacle.x - padding,
                y: obstacle.y - padding,
                width: obstacle.width + padding * 2,
                height: obstacle.height + padding * 2
            )
        }

        if let previous,
           previous.width == size.width,
           previous.height == size.height,
           screen.contains(previous),
           !paddedObstacles.contains(where: { previous.intersects($0) }) {
            return previous
        }

        let xs = coordinates(from: screen.x, through: screen.maxX - size.width)
        let ys = coordinates(from: screen.y, through: screen.maxY - size.height)
        let stride = xs.count + 1
        var difference = [Int](repeating: 0, count: stride * (ys.count + 1))

        for obstacle in paddedObstacles {
            let firstX = insertionIndex(in: xs, for: obstacle.x - size.width, inclusive: false)
            let lastX = insertionIndex(in: xs, for: obstacle.maxX, inclusive: true)
            let firstY = insertionIndex(in: ys, for: obstacle.y - size.height, inclusive: false)
            let lastY = insertionIndex(in: ys, for: obstacle.maxY, inclusive: true)
            guard firstX < lastX, firstY < lastY else { continue }

            difference[firstY * stride + firstX] += 1
            difference[firstY * stride + lastX] -= 1
            difference[lastY * stride + firstX] -= 1
            difference[lastY * stride + lastX] += 1
        }

        for y in ys.indices {
            for x in xs.indices {
                let index = y * stride + x
                if x > 0 { difference[index] += difference[index - 1] }
                if y > 0 { difference[index] += difference[index - stride] }
                if x > 0, y > 0 { difference[index] -= difference[index - stride - 1] }
            }
        }

        for y in ys.indices.reversed() {
            for x in xs.indices.reversed() where difference[y * stride + x] == 0 {
                return PetRect(x: xs[x], y: ys[y], width: size.width, height: size.height)
            }
        }
        return nil
    }

    private static func coordinates(from minimum: Double, through maximum: Double) -> [Double] {
        let step = max(4, (maximum - minimum) / 1_024)
        var values = Array(stride(from: minimum, to: maximum, by: step))
        values.append(maximum)
        return values
    }

    private static func insertionIndex(in values: [Double], for value: Double, inclusive: Bool) -> Int {
        var lower = 0
        var upper = values.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if inclusive ? values[middle] < value : values[middle] <= value {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }
}
