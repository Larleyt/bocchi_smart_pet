public enum PlacementEngine {
    public static func choose(
        in screen: PetRect,
        avoiding obstacles: [PetRect],
        size: PetSize,
        previous: PetRect?,
        nearestTo: PetRect? = nil
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

        let origin = validCenter(of: nearestTo, size: size) ?? validCenter(of: previous, size: size)
        let middleY = screen.y + screen.height / 2
        let sideInset = min(24, (screen.width - size.width) / 2)
        let leftX = screen.x + size.width / 2 + sideInset
        let rightX = screen.maxX - size.width / 2 - sideInset
        let verticalTravel = screen.height - size.height
        let middleMinY = screen.y + min(72, verticalTravel / 3)
        let middleMaxY = screen.maxY - min(120, verticalTravel / 3)
        var best: (score: Double, rect: PetRect)?
        var reservedFallback: (score: Double, rect: PetRect)?

        for y in ys.indices {
            for x in xs.indices where difference[y * stride + x] == 0 {
                let centerX = xs[x] + size.width / 2
                let centerY = ys[y] + size.height / 2
                let score: Double
                if let origin {
                    score = squaredDistance(x: centerX, y: centerY, toX: origin.x, toY: origin.y)
                } else {
                    let vertical = centerY - middleY
                    let left = centerX - leftX
                    let right = centerX - rightX
                    // Mid-height is more valuable than hugging an occupied screen edge.
                    score = min(left * left, right * right) + vertical * vertical * 4
                }
                let candidate = PetRect(x: xs[x], y: ys[y], width: size.width, height: size.height)
                // Quartz y grows downward; reserve top/bottom control bands unless the middle is full.
                if origin == nil && (candidate.y < middleMinY || candidate.maxY > middleMaxY) {
                    if score < (reservedFallback?.score ?? .infinity) {
                        reservedFallback = (score, candidate)
                    }
                } else if score < (best?.score ?? .infinity) {
                    best = (score, candidate)
                }
            }
        }
        return best?.rect ?? reservedFallback?.rect
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

    private static func validCenter(of rect: PetRect?, size: PetSize) -> PetPoint? {
        guard let rect,
              rect.x.isFinite, rect.y.isFinite,
              rect.width == size.width, rect.height == size.height else { return nil }
        let x = rect.x + rect.width / 2
        let y = rect.y + rect.height / 2
        return x.isFinite && y.isFinite ? PetPoint(x: x, y: y) : nil
    }

    private static func squaredDistance(
        x: Double, y: Double, toX: Double, toY: Double
    ) -> Double {
        let dx = x - toX
        let dy = y - toY
        return dx * dx + dy * dy
    }
}
