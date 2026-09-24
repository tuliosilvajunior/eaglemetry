import 'package:flutter/material.dart';

import '../core/projection_touch_api.dart';

/// The projection video, with every touch on it forwarded to the phone.
///
/// It wraps the [Texture] and nothing else. That is the whole of the coordinate
/// mapping problem: the texture's own box is exactly the drawn picture, whether
/// the caller sized it with an `AspectRatio` or stretched it edge to edge, so
/// the mapping from this widget's local space into buffer space is one
/// multiplication per axis. There is no letterbox to hit-test, because a
/// letterbox bar is outside this widget by construction. Put this **inside**
/// the box that frames the video, never around it.
///
/// It uses a [Listener], not a [GestureDetector], and that is deliberate: a
/// listener never enters the gesture arena, so it cannot take a drag away from
/// a scroll or a card gesture, and nothing can take a touch away from it. The
/// price is that it also cannot arbitrate — which is why the card that hosts
/// this must not claim a drag of its own over the same pixels. See
/// `CardStageDragSource.handle`.
class ProjectionTouchSurface extends StatefulWidget {
  const ProjectionTouchSurface({
    required this.stack,
    required this.textureId,
    required this.bufferWidth,
    required this.bufferHeight,
    required this.enabled,
    this.touchApi,
    super.key,
  });

  final ProjectionStack stack;
  final int textureId;

  /// The geometry the renderer attached. The same numbers reach the native side
  /// through `setBufferSize`, so the value that is mapped into and the value
  /// that is clamped against cannot drift apart.
  final int bufferWidth;
  final int bufferHeight;

  /// False while this card must not own the phone — hidden tab, paused app.
  /// The binding follows it, so a card nobody is looking at holds nothing.
  final bool enabled;

  final ProjectionTouchApi? touchApi;

  @override
  State<ProjectionTouchSurface> createState() => _ProjectionTouchSurfaceState();
}

class _ProjectionTouchSurfaceState extends State<ProjectionTouchSurface> {
  late final ProjectionTouchApi _api = widget.touchApi ?? ProjectionTouchApi();

  /// What was last declared to the native side, so a rebuild at the same size
  /// does not re-send it.
  int _declaredWidth = 0;
  int _declaredHeight = 0;
  bool _bound = false;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(ProjectionTouchSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  @override
  void dispose() {
    // Cannot await in dispose. `unbind` lifts any finger that is still down
    // before it drops the binding, so this cannot leave a stuck press.
    if (_bound) _api.unbind(widget.stack);
    super.dispose();
  }

  void _sync() {
    if (widget.enabled != _bound) {
      _bound = widget.enabled;
      if (_bound) {
        _api.bind(widget.stack);
      } else {
        _api.unbind(widget.stack);
        // The native side lifts every finger on unbind, so the local list has
        // to forget them too — otherwise the next binding resumes mid-gesture.
        _live.clear();
        // The geometry is declared per binding, so it has to be declared again
        // after the next one.
        _declaredWidth = 0;
        _declaredHeight = 0;
      }
    }
    if (!_bound) return;
    if (widget.bufferWidth != _declaredWidth ||
        widget.bufferHeight != _declaredHeight) {
      _declaredWidth = widget.bufferWidth;
      _declaredHeight = widget.bufferHeight;
      _api.setBufferSize(widget.stack, _declaredWidth, _declaredHeight);
    }
  }

  /// Local widget space to buffer space.
  ///
  /// The plain stretch, because the texture box *is* the picture. Clamping is
  /// the native side's job and it does it against the same numbers; doing it
  /// here as well would only hide a mismatch between the two.
  ProjectionTouchPointer _mapPoint(int id, Offset local, Size size) {
    final scaleX = size.width > 0 ? widget.bufferWidth / size.width : 0.0;
    final scaleY = size.height > 0 ? widget.bufferHeight / size.height : 0.0;
    return ProjectionTouchPointer(
      id: id,
      x: local.dx * scaleX,
      y: local.dy * scaleY,
    );
  }

  ProjectionTouchPointer _mapped(PointerEvent event, Size size) =>
      _mapPoint(event.pointer, event.localPosition, size);

  /// Fingers currently down, in the order they went down.
  ///
  /// The index of an id in [keys] is its `actionIndex` on the wire: that is
  /// what `ProjectionTouchPolicy.decideMulti` reads for POINTER_DOWN/UP, and
  /// it always expects the full live list, not just the finger that moved.
  /// Only the Android Auto stack uses this; CarPlay carries one finger and
  /// keeps the single-pointer path in each handler below.
  final Map<int, Offset> _live = {};

  List<ProjectionTouchPointer> _allMapped(Size size) => [
    for (final entry in _live.entries) _mapPoint(entry.key, entry.value, size),
  ];

  void _send(
    int action,
    List<ProjectionTouchPointer> pointers, [
    int actionIndex = 0,
  ]) {
    // A send answers with whether it was accepted; nothing here waits for it.
    // A pointer stream cannot be paced by a channel round trip, and a refusal
    // is already reported on the status stream for anyone who wants to see it.
    _api.send(
      stack: widget.stack,
      action: action,
      pointers: pointers,
      actionIndex: actionIndex,
    );
  }

  RenderBox? _box() {
    if (!_bound) return null;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box;
  }

  void _onDown(PointerDownEvent event) {
    final box = _box();
    if (box == null) return;
    if (widget.stack != ProjectionStack.androidAuto) {
      _send(ProjectionTouchAction.down, [_mapped(event, box.size)]);
      return;
    }
    _live[event.pointer] = event.localPosition;
    final pointers = _allMapped(box.size);
    if (_live.length == 1) {
      _send(ProjectionTouchAction.down, pointers);
    } else {
      _send(
        ProjectionTouchAction.pointerDown,
        pointers,
        _live.keys.toList().indexOf(event.pointer),
      );
    }
  }

  void _onMove(PointerMoveEvent event) {
    final box = _box();
    if (box == null) return;
    if (widget.stack != ProjectionStack.androidAuto) {
      _send(ProjectionTouchAction.move, [_mapped(event, box.size)]);
      return;
    }
    // A move for a finger with no DOWN joins the list instead of forking a
    // second gesture: the native side would refuse a lone second DOWN anyway.
    _live[event.pointer] = event.localPosition;
    _send(ProjectionTouchAction.move, _allMapped(box.size));
  }

  void _onUp(PointerUpEvent event) {
    final box = _box();
    if (box == null) return;
    if (widget.stack != ProjectionStack.androidAuto) {
      _send(ProjectionTouchAction.up, [_mapped(event, box.size)]);
      return;
    }
    // Unknown finger: its DOWN went nowhere (sent while unbound), so there is
    // nothing to lift. Sending UP here would clear the phone's live fingers.
    if (!_live.containsKey(event.pointer)) return;
    _live[event.pointer] = event.localPosition;
    final pointers = _allMapped(box.size);
    if (_live.length == 1) {
      _send(ProjectionTouchAction.up, pointers);
    } else {
      _send(
        ProjectionTouchAction.pointerUp,
        pointers,
        _live.keys.toList().indexOf(event.pointer),
      );
    }
    _live.remove(event.pointer);
  }

  void _onCancel(PointerCancelEvent event) {
    final box = _box();
    if (box == null) return;
    if (widget.stack != ProjectionStack.androidAuto) {
      // Forwarded as a cancel, not quietly swallowed: the native policy turns
      // it into the UP the phone is waiting for.
      _send(ProjectionTouchAction.cancel, [_mapped(event, box.size)]);
      return;
    }
    if (_live.isEmpty) return;
    _live[event.pointer] = event.localPosition;
    // CANCEL rides the same rewrite: the native policy turns it into the UP
    // that lifts the whole gesture at once.
    _send(ProjectionTouchAction.cancel, _allMapped(box.size));
    _live.clear();
  }

  @override
  Widget build(BuildContext context) {
    final texture = Texture(
      textureId: widget.textureId,
      filterQuality: FilterQuality.medium,
    );
    if (!widget.enabled) return texture;
    return Listener(
      // Opaque so a touch on a black frame still reaches the phone: the picture
      // is a texture, and what it happens to be showing is not a hit test.
      behavior: HitTestBehavior.opaque,
      onPointerDown: _onDown,
      onPointerMove: _onMove,
      onPointerUp: _onUp,
      onPointerCancel: _onCancel,
      child: texture,
    );
  }
}
