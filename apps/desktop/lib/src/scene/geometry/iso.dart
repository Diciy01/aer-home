import 'dart:math' as math;
import 'dart:ui';

/// Axis-aligned box in scene space (tiles). +x → screen down-right,
/// +y → screen down-left, +z → up.
class Box3 {
  const Box3(this.minX, this.minY, this.minZ, this.maxX, this.maxY, this.maxZ);

  final double minX, minY, minZ, maxX, maxY, maxZ;

  double get w => maxX - minX;
  double get d => maxY - minY;
  double get h => maxZ - minZ;

  /// Sort key for ties: centre depth towards the viewer.
  double get depthKey =>
      (minX + maxX) / 2 + (minY + maxY) / 2 + (minZ + maxZ) / 4;

  List<(double, double, double)> get corners => [
    for (final x in [minX, maxX])
      for (final y in [minY, maxY])
        for (final z in [minZ, maxZ]) (x, y, z),
  ];

  @override
  String toString() => 'Box3($minX,$minY,$minZ → $maxX,$maxY,$maxZ)';
}

/// 2:1 dimetric ("game isometric") projection, defined in docs/SCENE_FORMAT.md.
///
/// Scene point (x, y, z) in tiles maps to world pixels at zoom 1:
///   sx = (x − y) · tileWidth / 2
///   sy = (x + y) · tileHeight / 2 − z · zStep
abstract final class Iso {
  static const tileWidth = 64.0;
  static const tileHeight = 32.0;
  static const zStep = 36.0;

  static Offset project(double x, double y, [double z = 0]) =>
      Offset((x - y) * tileWidth / 2, (x + y) * tileHeight / 2 - z * zStep);

  /// Inverse of [project] on the horizontal plane at height [z].
  static (double, double) unproject(Offset p, {double z = 0}) {
    final a = p.dx / (tileWidth / 2);
    final b = (p.dy + z * zStep) / (tileHeight / 2);
    return ((a + b) / 2, (b - a) / 2);
  }

  /// Convex outline of a box on screen (a hexagon for non-degenerate boxes).
  static List<Offset> silhouette(Box3 b) =>
      convexHull([for (final (x, y, z) in b.corners) project(x, y, z)]);

  static Rect screenBounds(Box3 b) {
    final pts = [for (final (x, y, z) in b.corners) project(x, y, z)];
    var r = Rect.fromPoints(pts.first, pts.first);
    for (final p in pts) {
      r = r.expandToInclude(Rect.fromPoints(p, p));
    }
    return r;
  }
}

/// Andrew's monotone chain; returns counter-clockwise hull without repeats.
List<Offset> convexHull(List<Offset> points) {
  final pts = [
    ...{...points},
  ]..sort((a, b) => a.dx != b.dx ? a.dx.compareTo(b.dx) : a.dy.compareTo(b.dy));
  if (pts.length < 3) return pts;
  double cross(Offset o, Offset a, Offset b) =>
      (a.dx - o.dx) * (b.dy - o.dy) - (a.dy - o.dy) * (b.dx - o.dx);
  final lower = <Offset>[];
  for (final p in pts) {
    while (lower.length >= 2 &&
        cross(lower[lower.length - 2], lower.last, p) <= 0) {
      lower.removeLast();
    }
    lower.add(p);
  }
  final upper = <Offset>[];
  for (final p in pts.reversed) {
    while (upper.length >= 2 &&
        cross(upper[upper.length - 2], upper.last, p) <= 0) {
      upper.removeLast();
    }
    upper.add(p);
  }
  return [
    ...lower.sublist(0, lower.length - 1),
    ...upper.sublist(0, upper.length - 1),
  ];
}

/// Point-in-convex-polygon test (either winding). Edges count as inside.
bool pointInConvex(List<Offset> poly, Offset p) {
  if (poly.length < 3) return false;
  var sign = 0;
  for (var i = 0; i < poly.length; i++) {
    final a = poly[i], b = poly[(i + 1) % poly.length];
    final c = (b.dx - a.dx) * (p.dy - a.dy) - (b.dy - a.dy) * (p.dx - a.dx);
    if (c.abs() < 1e-9) continue;
    final s = c > 0 ? 1 : -1;
    if (sign == 0) {
      sign = s;
    } else if (s != sign) {
      return false;
    }
  }
  return true;
}

/// True when [a] must be painted before [b] (a is behind b). Boxes are
/// assumed not to interpenetrate; the first separating axis decides.
bool isBehind(Box3 a, Box3 b, {double eps = 1e-6}) {
  if (a.maxX <= b.minX + eps) return true;
  if (b.maxX <= a.minX + eps) return false;
  if (a.maxY <= b.minY + eps) return true;
  if (b.maxY <= a.minY + eps) return false;
  if (a.maxZ <= b.minZ + eps) return true;
  if (b.maxZ <= a.minZ + eps) return false;
  // Volumes intersect: a container (shelf, rack) is painted before the items
  // standing inside its footprint.
  bool containsXY(Box3 o, Box3 i) =>
      o.minX <= i.minX + eps &&
      o.maxX >= i.maxX - eps &&
      o.minY <= i.minY + eps &&
      o.maxY >= i.maxY - eps;
  if (containsXY(a, b)) return true;
  if (containsXY(b, a)) return false;
  return a.depthKey < b.depthKey;
}

/// Topological painter's order. Only pairs whose screen bounds overlap get an
/// edge; ties and (theoretical) cycles fall back to [Box3.depthKey].
List<int> depthOrder(List<Box3> boxes) {
  final n = boxes.length;
  final bounds = [for (final b in boxes) Iso.screenBounds(b).deflate(0.01)];
  final after = List.generate(n, (_) => <int>[]);
  final indegree = List.filled(n, 0);
  for (var i = 0; i < n; i++) {
    for (var j = i + 1; j < n; j++) {
      if (!bounds[i].overlaps(bounds[j])) continue;
      if (isBehind(boxes[i], boxes[j])) {
        after[i].add(j);
        indegree[j]++;
      } else {
        after[j].add(i);
        indegree[i]++;
      }
    }
  }
  final ready = <int>[
    for (var i = 0; i < n; i++)
      if (indegree[i] == 0) i,
  ];
  final done = List.filled(n, false);
  final order = <int>[];
  while (order.length < n) {
    if (ready.isEmpty) {
      // Cycle: release the shallowest remaining node.
      var best = -1;
      for (var i = 0; i < n; i++) {
        if (!done[i] &&
            (best < 0 || boxes[i].depthKey < boxes[best].depthKey)) {
          best = i;
        }
      }
      ready.add(best);
      indegree[best] = 0;
    }
    ready.sort((a, b) => boxes[b].depthKey.compareTo(boxes[a].depthKey));
    final next = ready.removeLast();
    if (done[next]) continue;
    done[next] = true;
    order.add(next);
    for (final m in after[next]) {
      if (!done[m] && --indegree[m] == 0) ready.add(m);
    }
  }
  return order;
}

double clampDouble(double v, double lo, double hi) =>
    math.min(math.max(v, lo), hi);
