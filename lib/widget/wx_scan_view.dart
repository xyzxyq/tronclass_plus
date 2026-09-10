import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wxscan_live/wxscan_live.dart';

export 'package:wxscan_live/wxscan_live.dart'
    show ScanResult, ScanOutcome, ScanPoint, ScanQuad, WxResolution;

/// 相机权限被拒绝。通过 [WxScanView.onError] 抛给页面，让页面决定怎么提示。
class WxScanPermissionDenied implements Exception {
  const WxScanPermissionDenied();

  @override
  String toString() => '请允许相机权限才能进行扫描二维码';
}

/// 扫码界面对外的把手：手电筒、暂停/继续、当前缩放。
///
/// 是个 [ChangeNotifier]，所以 AppBar 上的手电筒按钮用 [ListenableBuilder]
/// 包一层就会跟着相机实际的状态走，而不是跟着"我们请求了什么"走。
class WxScanViewController extends ChangeNotifier {
  _WxScanViewState? _state;

  bool get isReady => _state?._controller?.value.isInitialized ?? false;

  bool get hasTorch => _state?._hasTorch ?? false;

  bool get torchEnabled =>
      _state?._controller?.value.torchEnabled ?? false;

  double get zoom => _state?._zoom ?? 1;

  Future<void> toggleTorch() async {
    final c = _state?._controller;
    if (c == null) return;
    await c.setTorch(!c.value.torchEnabled);
  }

  /// 暂停解码，相机和预览继续跑（结果页盖上来的时候用这个，不要 dispose）。
  Future<void> pause() async => _state?._pauseScanning();

  /// 继续解码，并把上一帧的框清掉。
  Future<void> resume() async => _state?._resumeScanning();

  void _attach(_WxScanViewState state) => _state = state;

  void _detach(_WxScanViewState state) {
    if (identical(_state, state)) _state = null;
  }

  void _notify() {
    if (_state != null) notifyListeners();
  }
}

/// 相机扫码视图：预览 + 扫描线 + 自动对焦/自动放大 + 一帧多码时的选择。
///
/// 逻辑照搬 wxscan_live 官方 example（`example/lib/scan_page.dart`），
/// 界面换成 App 自己的配色：强调色取 `colorScheme.primary`，取景框是
/// [WxScanLineOverlay]，页面也可以用 [overlayBuilder] 换成别的。
class WxScanView extends StatefulWidget {
  const WxScanView({
    super.key,
    required this.onResult,
    this.controller,
    this.onError,
    this.overlayBuilder,
    this.hint,
    this.resolution = WxResolution.p720,
  });

  /// 扫到一个码。回调前扫描已经暂停，页面处理完调 [WxScanViewController.resume]。
  final void Function(ScanResult result) onResult;

  final WxScanViewController? controller;

  /// 相机起不来时的回调（权限被拒是 [WxScanPermissionDenied]）。
  /// 不传就在画面中间显示一张带"重试"的错误卡片。
  final void Function(Object error)? onError;

  /// 自定义覆盖层；不传用 [WxScanLineOverlay]。
  final WidgetBuilder? overlayBuilder;

  /// 底部提示文案；不传用默认的"将二维码放入框内"。
  final String? hint;

  final WxResolution resolution;

  @override
  State<WxScanView> createState() => _WxScanViewState();
}

class _WxScanViewState extends State<WxScanView> with WidgetsBindingObserver {
  /// 相机。预览尺寸、手电筒、缩放这些状态都在 `_controller.value` 里，
  /// 这边不再镜像一份。
  WxScanController? _controller;
  StreamSubscription<ScanOutcome>? _sub;
  Object? _error;
  bool _hasTorch = false;

  /// 最近一帧的结果，用来画高亮。
  ScanOutcome? _lastFrame;

  /// 一帧里有多个码时冻住的那一帧，非空表示正在等用户选。
  ScanOutcome? _pickFrame;

  /// 冻住的画面（就是被扫的那一帧），所以标记和画面天然对得上。
  Uint8List? _frozenFrame;

  /// 页面正在处理结果，后续帧一律忽略。
  bool _paused = false;

  /// 设备的最大倍率，自动放大用。
  double _maxZoom = 1;

  double get _zoom => _controller?.value.zoom ?? 1;

  /// 连续多少帧"看见了但读不出来"。自动放大要等够帧数，免得画面抖。
  int _undecodableStreak = 0;

  /// 连续多少帧什么都没有；够多就把倍率退回去。
  int _emptyStreak = 0;

  /// 从什么时候开始帧里什么都没有了，[_blindFocus] 用。
  DateTime? _nothingSince;

  /// "解出一个、但看见不止一个"是从什么时候开始的，见 [_kMultiCodeGrace]。
  DateTime? _multiWaitSince;

  DateTime _lastZoomAt = DateTime.fromMillisecondsSinceEpoch(0);
  double _gestureZoomBase = 1;
  DateTime _manualZoomAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _pickExitAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 上一次点按对焦落点（用来画对焦框）和把它收掉的定时器。
  Offset? _focusPoint;
  Timer? _focusTimer;

  DateTime _manualFocusAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastAutoFocusAt = DateTime.fromMillisecondsSinceEpoch(0);
  Offset? _lastAutoFocusPoint;

  /// 倍率正在走向的目标，以及走它的定时器，见 [_stepZoom]。
  double _zoomTarget = 1;
  Timer? _zoomDriver;
  var _zoomBusy = false;

  /// 走到全速的进度 0~1，以及上一步的时刻。两者让加减速都不生硬。
  double _zoomRate = 0;
  DateTime _zoomSteppedAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    widget.controller?._attach(this);
    WidgetsBinding.instance.addObserver(this);
    _boot();
  }

  @override
  void didUpdateWidget(WxScanView old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller?._detach(this);
      widget.controller?._attach(this);
    }
  }

  /// 相机状态变了就重画：转屏、设备确认的手电筒、被夹住的倍率。
  void _onControllerChanged() {
    if (mounted) setState(() {});
    widget.controller?._notify();
  }

  Future<void> _boot() async {
    try {
      // macOS 上 permission_handler 没有实现，插件会自己去问 AVFoundation。
      if (GetPlatform.isMobile) {
        final status = await Permission.camera.request();
        if (!status.isGranted) {
          // 用户可能是在页面已经走掉之后才回答的弹窗。
          if (mounted) _fail(const WxScanPermissionDenied());
          return;
        }
      }

      final controller = WxScanController(resolution: widget.resolution);
      await controller.initialize(
        detectModel: await _loadModel(_kDetectModelAsset),
        srModel: await _loadModel(_kSrModelAsset),
      );
      final hasTorch = await controller.hasTorch();
      final zoom = await controller.zoomRange();
      _maxZoom = zoom.max;
      if (!mounted) {
        controller.dispose();
        return;
      }
      // 确定这个页面会留着这个 controller 之后才接线：先订阅的话，页面
      // 被 pop 掉后 dispose 里没有东西可取消，订阅就漏在那了。
      controller.addListener(_onControllerChanged);
      _sub = controller.scans.listen(_onFrame);
      setState(() {
        _controller = controller;
        _hasTorch = hasTorch;
        _error = controller.value.nativeReady
            ? null
            : '扫码组件加载失败';
      });
      if (_paused) await controller.setScanning(false);
      widget.controller?._notify();
    } catch (e) {
      if (!mounted) return;
      _fail(e);
    }
  }

  void _fail(Object error) {
    final onError = widget.onError;
    if (onError != null) {
      onError(error);
      return;
    }
    setState(() => _error = error is WxScanPermissionDenied
        ? '请允许相机权限才能进行扫描二维码'
        : '$error');
  }

  void _onFrame(ScanOutcome frame) {
    // 选码的时候不要刷新，不然码会随每一帧跳，点都点不中。
    if (!mounted || _paused) return;
    setState(() => _lastFrame = frame);

    if (_pickFrame != null) return;

    if (frame.results.isEmpty) {
      _multiWaitSince = null;
      _autoZoom(frame);
      _autoFocus(frame);
      _blindFocus(frame);
      return;
    }
    // 解出来了，说明放大已经完成了任务，退回去。
    _resetZoom();
    _nothingSince = null;

    // 一帧里好几个码：冻住画面让用户选。必须冻——预览还在跑的话画面
    // 随手抖一直变，而标记属于这一帧，两者永远对不上。
    if (frame.results.length > 1) {
      _multiWaitSince = null;
      _enterPick(frame);
      return;
    }

    // 解出一个，但检测阶段看见了不止一个框：多半是视野里有两个码，另一个
    // 这一帧还没出来（多码时帧率会明显慢）。现在就交结果的话用户根本没有
    // 选的机会，所以等几帧。
    if (frame.candidates.length > 1) {
      final now = DateTime.now();
      _multiWaitSince ??= now;
      // 等不来就按这一个算：另一个可能本来就太小或太糊，根本解不出。
      if (now.difference(_multiWaitSince!) < _kMultiCodeGrace) return;
    }
    _multiWaitSince = null;
    _deliver(frame.results.first);
  }

  /// 进入选码：停扫，并把当前这一帧冻成图片。
  Future<void> _enterPick(ScanOutcome frame) async {
    setState(() => _pickFrame = frame);
    await _controller!.setScanning(false);
    final jpeg = await _controller!.grabFrame();
    if (!mounted || _pickFrame == null) return;
    setState(() => _frozenFrame = jpeg);
  }

  void _exitPick() {
    _multiWaitSince = null;
    setState(() {
      _pickFrame = null;
      _frozenFrame = null;
      // 上一帧的结果也一起清掉，否则在新的一帧到来之前，画面上还留着
      // 进入选码之前那一帧的框，看着像个消不掉的框。
      _lastFrame = null;
    });
    _pickExitAt = DateTime.now();
    _controller!.setScanning(true);
  }

  void _deliver(ScanResult result) {
    _paused = true;
    _controller?.setScanning(false);
    setState(() {
      _pickFrame = null;
      _frozenFrame = null;
    });
    widget.onResult(result);
  }

  Future<void> _pauseScanning() async {
    _paused = true;
    await _controller?.setScanning(false);
  }

  Future<void> _resumeScanning() async {
    _paused = false;
    _multiWaitSince = null;
    if (mounted) {
      setState(() {
        _pickFrame = null;
        _frozenFrame = null;
        _lastFrame = null;
      });
    }
    _resetZoom();
    await _controller?.setScanning(true);
  }

  /// 自动放大：看得见却解不出，通常是码太小，那就替用户"走近点"。
  ///
  /// 依据是 Rust 检测阶段给出的候选框——有框没结果就是看见了没读出来。
  /// 光看结果为空不行，因为视野里根本没码的时候结果也是空的，那时候放大
  /// 纯属捣乱。
  void _autoZoom(ScanOutcome frame) {
    final nowTs = DateTime.now();
    // 用户刚手动缩放过、或者刚从选码退出来，别抢方向盘。
    if (nowTs.difference(_manualZoomAt) < _kManualZoomHold) return;
    if (nowTs.difference(_pickExitAt) < _kPickExitZoomHold) return;
    if (!frame.hasUndecodable) {
      _undecodableStreak = 0;
      // 长时间什么都看不见就把倍率退回去，不然会一直保持放大。
      if (frame.candidates.isEmpty && ++_emptyStreak > 45) _resetZoom();
      return;
    }
    _emptyStreak = 0;
    // 等几帧口径一致再动手；单帧可能是误检。
    if (++_undecodableStreak < 3) return;

    final box = _largestCandidateBox(frame);
    if (box == null) return;
    final frac = math.max(box.w, box.h);
    if (frac <= 0 || frac >= _kZoomTargetFraction) return;

    // 想放这么大，但不能大到把码挤出画面，取小的那个。
    final rel = math.min(_kZoomTargetFraction / frac, _safeZoomHeadroom(box));
    final want = (_zoom * rel)
        .clamp(1.0, math.min(_maxZoom, _kMaxAutoZoom))
        .toDouble();
    if (want <= _zoom * 1.02) return;

    // 这里只定目标。每一帧都会修正它：画面推近，码变大，frac 跟着变大，
    // 目标就降下来迎接当前倍率——所以它自己会收敛，不会冲过头。
    _zoomTarget = want;
    _startZoomDriver();
  }

  /// 把倍率一步步走向 [_zoomTarget]。
  ///
  /// 直接设到目标会让画面一跳，那是"在瞎猜"的观感，还会把用户端稳的码甩
  /// 到别处去。但等步长的匀速走也不行：一秒十个看得见的台阶就是幻灯片，
  /// 而且起步和收尾都是硬的。
  ///
  /// 所以：每 [_kZoomStepEvery] 走一步，每步吃掉剩余距离的固定*比例*，这
  /// 样它自己就会减速进目标，像手的动作。另外两点：算术做在倍率的对数上，
  /// 因为缩放是乘性的，只有在对数上等步长看着才等；速度在 [_kZoomRampIn]
  /// 里渐入，而不是第一步就满速——起步的那一顿就是这么来的。
  void _startZoomDriver() {
    if (_zoomDriver != null) return;
    _zoomRate = 0;
    _zoomSteppedAt = DateTime.now();
    _zoomDriver = Timer.periodic(_kZoomStepEvery, (_) => _stepZoom());
  }

  void _stopZoomDriver() {
    _zoomDriver?.cancel();
    _zoomDriver = null;
    _zoomRate = 0;
  }

  void _stepZoom() {
    // 一次只发一个调用：生效的倍率是设备回给我们的，拿旧值继续走会走过头。
    if (_zoomBusy || _controller == null) return;
    final from = _zoom;
    if ((_zoomTarget / from - 1).abs() < 0.005) {
      _stopZoomDriver();
      return;
    }

    // 实测而不是假设：定时器在负载下会迟到，按 33ms 算的步子等了 90ms 才走
    // 就成了爬。
    final now = DateTime.now();
    final dt = now.difference(_zoomSteppedAt).inMicroseconds / 1e6;
    _zoomSteppedAt = now;
    if (dt <= 0) return;

    _zoomRate =
        math.min(1.0, _zoomRate + dt / (_kZoomRampIn.inMilliseconds / 1000));
    // 这一步吃掉剩余距离的比例。写成指数，这样定时器实际多久响一次，走出
    // 来的观感都一样。
    final k = 1 - math.exp(-dt / (_kZoomSettle.inMilliseconds / 1000));

    final logFrom = math.log(from);
    final next =
        math.exp(logFrom + (math.log(_zoomTarget) - logFrom) * k * _zoomRate);

    _zoomBusy = true;
    _controller!.setZoom(next).then((actual) {
      _zoomBusy = false;
      if (!mounted) return;
      // 设备到头了。再每一步问一次就是一秒三十个平台调用换不来任何东西。
      if ((actual - from).abs() < 0.0005 && _zoomRate >= 1) {
        _zoomTarget = actual;
        _stopZoomDriver();
      }
    });
  }

  /// 对着"看得见却解不出"的码对焦。
  ///
  /// 小码通常也是糊的：它待在画面里的某个角落，而连续自动对焦是按画面中心
  /// 加权的，于是把它背后的墙对清楚了。把焦点指到框上，往往就是解得出和解
  /// 不出的全部差别，而码本来就清楚的时候这一下也不花什么代价。
  ///
  /// 和 [_autoZoom] 分开：两者对付的是同一个麻烦，但手段不同，而且离中心太
  /// 远、放大够不着的码（相机只能绕画面中心放大）照样能对焦。
  void _autoFocus(ScanOutcome frame) {
    if (!frame.hasUndecodable || _controller == null) return;

    // 一帧就够，而放大要等三帧。两者赌的不是一回事：放大误触会把画面甩得
    // 到处跑，丢掉用户正对着的东西；对焦误触最坏也就是镜头往一个没东西的
    // 地方动一下，下一帧就纠正回来，中间不花什么代价。等三帧只会把本来能
    // 读出来的那次读取往后拖。
    final now = DateTime.now();
    if (now.difference(_manualFocusAt) < _kManualFocusHold) return;
    if (now.difference(_lastAutoFocusAt) < _kAutoFocusInterval) return;

    final box = _largestCandidateBox(frame);
    if (box == null) return;
    // 只管小的。占了大半个画面的码本来就在连续对焦看的地方，再指一次只会
    // 让镜头来回拉风箱。
    final frac = math.max(box.w, box.h);
    if (frac <= 0 || frac >= _kAutoFocusMaxFraction) return;

    // 一个没动的码只对一次焦，不是每一秒半来一次：每次请求都会让镜头重新
    // 走一遍，一会儿糊一会儿清比一直定住还糟。
    final point = Offset(box.cx, box.cy);
    final last = _lastAutoFocusPoint;
    if (last != null &&
        (point - last).distance < _kAutoFocusMoved &&
        now.difference(_lastAutoFocusAt) < _kAutoFocusRepeat) {
      return;
    }

    final turns = _controller?.value.previewSize?.quarterTurns ?? 0;
    final (x, y) = _previewFraction(box.cx, box.cy, turns);
    if (x < 0 || x > 1 || y < 0 || y > 1) return;

    _lastAutoFocusAt = now;
    _lastAutoFocusPoint = point;
    unawaited(_controller!.focusAt(x, y));
  }

  /// 什么都没有的时候也要对焦。
  ///
  /// [_autoFocus] 得先有候选框，而糊到检测不出任何东西的画面一个框都没有。
  /// 这是个自锁的状态：没有框，就没人要求对焦，于是框永远不会来。镜头停在
  /// 上次会话留下的位置时打开扫码就是这样，连续自动对焦也救不了——连续对焦
  /// 反应的是"变化"，而端稳在码上方的手机什么都没变。
  ///
  /// 所以别等检测器了。大约一秒的帧里既没有结果也没有候选，这画面就没有价值
  /// 了：对着中心扫一次是唯一能改变它的事，而且此刻并没有正在进行的读取会被
  /// 它打断。
  void _blindFocus(ScanOutcome frame) {
    if (_controller == null) return;
    final now = DateTime.now();
    if (frame.candidates.isNotEmpty) {
      _nothingSince = null;
      return;
    }
    // 这里按时间算而不是按帧数——一帧就是一趟完整的 CNN，帧率随分辨率和机
    // 器变，数帧数在这台手机上是半秒，在那台上就是三秒。
    final since = _nothingSince ??= now;
    if (now.difference(since) < _kBlindFocusAfter) return;

    if (now.difference(_manualFocusAt) < _kManualFocusHold) return;
    // 和 [_autoFocus] 共用一个时钟，这样两者不会同时去驱动镜头：谁有话说，
    // 另一个就让开。
    if (now.difference(_lastAutoFocusAt) < _kBlindFocusInterval) return;

    _lastAutoFocusAt = now;
    // 没有瞄准任何东西，也就没有下一次可以拿来比较的点。
    _lastAutoFocusPoint = null;
    unawaited(_controller!.focusAt(0.5, 0.5));
  }

  void _resetZoom() {
    _undecodableStreak = 0;
    _emptyStreak = 0;
    if (_zoomTarget == 1 && _zoom == 1) return;
    // 沿原路退回去，而不是一帧之内掉回 1x。
    _zoomTarget = 1;
    _startZoomDriver();
  }

  /// 最大的那个候选框，坐标按各自维度归一化到 [0,1]。
  ({double cx, double cy, double w, double h})? _largestCandidateBox(
      ScanOutcome f) {
    if (f.width == 0 || f.height == 0) return null;
    ({double cx, double cy, double w, double h})? best;
    var bestArea = 0.0;
    for (final c in f.candidates) {
      if (c.length < 4) continue;
      var minX = double.infinity, maxX = -double.infinity;
      var minY = double.infinity, maxY = -double.infinity;
      for (final p in c) {
        minX = math.min(minX, p.dx);
        maxX = math.max(maxX, p.dx);
        minY = math.min(minY, p.dy);
        maxY = math.max(maxY, p.dy);
      }
      final w = (maxX - minX) / f.width;
      final h = (maxY - minY) / f.height;
      if (w * h > bestArea) {
        bestArea = w * h;
        best = (
          cx: (minX + maxX) / 2 / f.width,
          cy: (minY + maxY) / 2 / f.height,
          w: w,
          h: h,
        );
      }
    }
    return best;
  }

  /// 还能再放大多少倍而不把码挤出画面。
  ///
  /// 相机只能绕画面*中心*放大，没有指定缩放中心的接口。所以码离中心越远，
  /// 余地越小。倍率 z 时可见区域是以 0.5 为中心、边长 1/z 的窗口，要让码整个
  /// 留在里面就得满足 |c-0.5| + 半边长 <= 1/(2z)。码离中心很远时这个值接近 1,
  /// 意思是不该放大：放了只会把码丢得更远，不如等用户自己挪过去。
  double _safeZoomHeadroom(({double cx, double cy, double w, double h}) box) {
    double axis(double center, double size) {
      final margin = (center - 0.5).abs() + size / 2;
      return margin <= 0 ? _kMaxAutoZoom : 1 / (2 * margin);
    }

    return math.min(axis(box.cx, box.w), axis(box.cy, box.h));
  }

  /// 捏合缩放。单指的 scale 事件忽略掉，否则选码的点按会被当成缩放。
  void _onScaleStart(ScaleStartDetails d) {
    if (d.pointerCount >= 2) _gestureZoomBase = _zoom;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (d.pointerCount < 2 || _controller == null) return;
    final now = DateTime.now();
    // 手势事件来得密，这里节流，别拿它去灌平台调用。
    if (now.difference(_lastZoomAt) < const Duration(milliseconds: 60)) return;

    final want = (_gestureZoomBase * d.scale).clamp(1.0, _maxZoom).toDouble();
    if ((want - _zoom).abs() < 0.02) return;
    _lastZoomAt = now;
    _manualZoomAt = now;
    // 手在上面：自动走位没什么可做的了，留着只会和手指对着拽。
    _stopZoomDriver();
    _zoomTarget = want;
    unawaited(_controller!.setZoom(want));
  }

  /// 点按对焦。
  ///
  /// 预览是把画面转过 [WxPreviewSize.quarterTurns] 再铺满盒子画出来的，所以
  /// 点按要沿反方向还回去：先按转后的尺寸还原 cover，再把旋转还原，剩下的就
  /// 是插件自己那套坐标里的比例。
  ///
  /// 落在画面之外的点按直接丢掉而不是夹到边上（cover 裁掉的部分在盒子外，但
  /// letterbox 的留白是在盒子上的），这样对焦框不会出现在相机根本没看的地方。
  void _onFocusTap(Offset tap, Size box) {
    final size = _controller?.value.previewSize;
    if (size == null || _controller == null) return;

    final m = _coverFit(box, size.rotatedWidth, size.rotatedHeight);
    final rx = (tap.dx - m.dx) / (size.rotatedWidth * m.scale);
    final ry = (tap.dy - m.dy) / (size.rotatedHeight * m.scale);
    if (rx < 0 || rx > 1 || ry < 0 || ry > 1) return;

    final (x, y) = _previewFraction(rx, ry, size.quarterTurns);

    _manualFocusAt = DateTime.now();
    _focusTimer?.cancel();
    setState(() => _focusPoint = tap);
    _focusTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _focusPoint = null);
    });
    unawaited(_controller!.focusAt(x, y));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 退到后台就停扫，回来再继续。观察者是在 initState 里注册的，所以这里
    // 可能在相机还没起来的时候就被调用，甚至永远等不到相机（权限被拒）。
    if (state == AppLifecycleState.resumed) {
      _controller?.setScanning(!_paused);
    } else {
      _controller?.setScanning(false);
    }
  }

  @override
  void dispose() {
    widget.controller?._detach(this);
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    _controller?.removeListener(_onControllerChanged);
    _controller?.dispose();
    _controller = null;
    _focusTimer?.cancel();
    _zoomDriver?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    // 选码时按返回应该是退出选码继续扫，而不是退出整个页面。
    return PopScope(
      canPop: _pickFrame == null,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _exitPick();
      },
      child: ColoredBox(
        color: Colors.black,
        // 缩放手势包住所有东西：放在 Stack 里当一层的话会被上面各层的命中
        // 测试挡掉。它和里面的点按不冲突——手势竞技场会分派，一根手指给点
        // 按，两根给缩放。
        child: GestureDetector(
          behavior: HitTestBehavior.deferToChild,
          onScaleStart: _onScaleStart,
          onScaleUpdate: _onScaleUpdate,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (_controller != null) _buildPreview(_controller!),
              // 只是装饰，没有任何可以按的东西。不加 IgnorePointer 的话
              // CustomPaint 会吃掉落到它上面的每一个点按：RenderCustomPaint
              // 的 hitTestSelf 默认为 true，取景框会把本该给下面那层的点按
              // 全部吞掉。
              IgnorePointer(
                child: widget.overlayBuilder?.call(context) ??
                    const WxScanLineOverlay(),
              ),
              if (_lastFrame != null &&
                  _controller != null &&
                  _pickFrame == null)
                IgnorePointer(
                  child: CustomPaint(
                    painter: _CodeMarkerPainter(
                        frame: _lastFrame!, color: accent),
                  ),
                ),
              if (_controller != null) _buildFocusLayer(),
              if (_focusPoint != null)
                _FocusReticle(at: _focusPoint!, color: accent),
              if (_pickFrame != null) _buildPicker(_pickFrame!, accent),
              if (_error != null) _buildError('${_error!}'),
              _buildHint(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPreview(WxScanController controller) {
    // 预览永远是相对设备自然方向摆正的，屏幕转了多少要在这里补回来，外面
    // 的盒子按补正之后的尺寸来定。两者必须一致，否则 BoxFit.cover 会按错的
    // 比例拉伸。
    final size = controller.value.previewSize;
    if (size == null) return const SizedBox.shrink();
    return ClipRect(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: size.rotatedWidth.toDouble(),
          height: size.rotatedHeight.toDouble(),
          child: RotatedBox(
            quarterTurns: size.quarterTurns,
            child: SizedBox(
              width: size.width.toDouble(),
              height: size.height.toDouble(),
              child: WxScanPreview(controller: controller),
            ),
          ),
        ),
      ),
    );
  }

  /// 接点按对焦的那一层。
  Widget _buildFocusLayer() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final box = Size(constraints.maxWidth, constraints.maxHeight);
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTapUp: (d) => _onFocusTap(d.localPosition, box),
          child: const SizedBox.expand(),
        );
      },
    );
  }

  /// 选码那一层：点标记打开那个码，点别处继续扫。
  Widget _buildPicker(ScanOutcome frame, Color accent) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) {
            final hit = _pickHitTest(d.localPosition, size, frame);
            if (hit != null) {
              _deliver(hit);
            } else {
              _exitPick();
            }
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 冻住的那一帧盖在实时预览上。它就是同一帧、同一尺寸，所以
              // 下面的标记在同一套 cover 映射下天然对齐。
              if (_frozenFrame != null)
                Image.memory(
                  _frozenFrame!,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                ),
              // 显式撑满：命中测试用的是 LayoutBuilder 的尺寸，绘制用的是
              // CustomPaint 的，两者必须一致，否则点按和标记会系统性错位。
              CustomPaint(
                size: Size.infinite,
                painter: _PickPainter(frame: frame, color: accent),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 40),
                    child: _Hint('画面里有多个二维码，点击标记选择'),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildHint() {
    if (_pickFrame != null || _error != null) return const SizedBox.shrink();
    final zoom = _zoom;
    return Align(
      alignment: Alignment.bottomCenter,
      child: SafeArea(
        child: Padding(
          // 横屏的手机取景框下面几乎没有余地，40 会把提示顶到屏幕外面。
          padding: EdgeInsets.only(
              bottom: MediaQuery.sizeOf(context).height < 560 ? 12 : 40),
          child: _Hint(zoom > 1.05
              ? '${zoom.toStringAsFixed(1)} 倍 · 双指缩放'
              : (widget.hint ?? '对准二维码，即可自动扫描')),
        ),
      ),
    );
  }

  Widget _buildError(String message) {
    final theme = Theme.of(context);
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 32),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, color: theme.colorScheme.error, size: 32),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () {
                setState(() => _error = null);
                _boot();
              },
              child: Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 扫描线：整幅画面自上而下扫过，反复。
///
/// 这里原本画的是一个取景方框，框外压暗。但扫描器读的是整帧，那个框等于在
/// 告诉用户去对准一个根本不是扫描区域的地方，压暗还盖掉了一幅完全实时的
/// 画面。剩下的这条线才是诚实的那部分：有东西正在被看，而且看的是全部。
///
/// 照搬 wxscan_live example 的 `_ScanLineOverlay`，颜色换成 App 主题色。
class WxScanLineOverlay extends StatefulWidget {
  const WxScanLineOverlay({super.key});

  @override
  State<WxScanLineOverlay> createState() => _WxScanLineOverlayState();
}

class _WxScanLineOverlayState extends State<WxScanLineOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => CustomPaint(
        painter: _ScanLinePainter(progress: _controller.value, color: accent),
        size: Size.infinite,
      ),
    );
  }
}

class _ScanLinePainter extends CustomPainter {
  _ScanLinePainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height * progress;

    // 顶端淡入、底端淡出，这样回到顶部读起来是"又扫了一遍"，而不是线跳了
    // 一下。
    final fade =
        math.min(progress / 0.12, (1 - progress) / 0.12).clamp(0.0, 1.0);
    if (fade <= 0) return;

    // 线上方的拖尾。整屏高度下一条光秃秃的线显得太细，拖尾是让这一扫有方向
    // 感的东西。
    final trail = math.min(size.height * 0.14, 150.0);
    final top = math.max(y - trail, 0.0);
    if (y > top) {
      final band = Rect.fromLTRB(0, top, size.width, y);
      canvas.drawRect(
        band,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              color.withValues(alpha: 0),
              color.withValues(alpha: 0.16 * fade),
            ],
          ).createShader(band),
      );
    }

    // 线本身，两端渐细，免得在屏幕两侧硬生生断掉。
    final line = Rect.fromLTWH(0, y - 1, size.width, 2);
    canvas.drawRect(
      line,
      Paint()
        ..shader = LinearGradient(
          colors: [
            color.withValues(alpha: 0),
            color.withValues(alpha: fade),
            color.withValues(alpha: 0),
          ],
          stops: const [0.0, 0.5, 1.0],
        ).createShader(line),
    );
  }

  @override
  bool shouldRepaint(_ScanLinePainter old) =>
      old.progress != progress || old.color != color;
}

/// 相机画面上的一行提示。
///
/// 它得有自己的底：光秃秃的文字在墙面上还看得清，遇到稍微花一点的东西就没
/// 了，而相机看到的大多是花的。
class _Hint extends StatelessWidget {
  const _Hint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    // 不要在这里包 Center：外面是 Align(bottomCenter)，给的是松约束，
    // Center 会把自己撑到整个高度，提示就跑到屏幕正中去了。水平居中交给
    // 外面的 Align，这里只管自己那一小块。
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.white, fontSize: 13),
      ),
    );
  }
}

/// 相机在被告知对焦位置时画的四个角。
///
/// 先大一圈，然后收到点上，给一个小脉冲再淡出。这是点按被接受的唯一信号：
/// 本来就清楚的码对焦是看不出来的，而看着毫无反应的点按会被当成没点中。
class _FocusReticle extends StatefulWidget {
  const _FocusReticle({required this.at, required this.color});

  final Offset at;
  final Color color;

  @override
  State<_FocusReticle> createState() => _FocusReticleState();
}

class _FocusReticleState extends State<_FocusReticle>
    with SingleTickerProviderStateMixin {
  static const double _size = 78;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..forward();

  @override
  void didUpdateWidget(_FocusReticle old) {
    super.didUpdateWidget(old);
    // 第二次点按复用的是同一个 widget，所以要重新播一遍，而不是停在终点。
    if (widget.at != old.at) _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  double _scaleAt(double t) {
    if (t < 0.24) {
      return 1.5 - 0.5 * Curves.easeOutCubic.transform(t / 0.24);
    }
    if (t < 0.46) {
      final p = (t - 0.24) / 0.22;
      return 1.0 - 0.08 * math.sin(p * math.pi);
    }
    return 1.0;
  }

  double _opacityAt(double t) {
    if (t < 0.06) return t / 0.06;
    if (t < 0.72) return 1.0;
    return 1.0 - (t - 0.72) / 0.28;
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final t = _controller.value;
          final scale = _scaleAt(t);
          return Stack(
            children: [
              Positioned(
                left: widget.at.dx - _size / 2,
                top: widget.at.dy - _size / 2,
                child: Opacity(
                  opacity: _opacityAt(t).clamp(0.0, 1.0),
                  child: Transform.scale(
                    scale: scale,
                    child: CustomPaint(
                      size: const Size(_size, _size),
                      // 线宽按反方向缩放，这样角张开多大，线看着都一样粗。
                      painter: _FocusCornersPainter(
                        strokeScale: 1 / scale,
                        color: widget.color,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _FocusCornersPainter extends CustomPainter {
  const _FocusCornersPainter({required this.strokeScale, required this.color});

  final double strokeScale;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final arm = size.width * 0.28;
    final path = Path();
    for (final (cx, cy, sx, sy) in [
      (0.0, 0.0, 1.0, 1.0),
      (size.width, 0.0, -1.0, 1.0),
      (size.width, size.height, -1.0, -1.0),
      (0.0, size.height, 1.0, -1.0),
    ]) {
      path
        ..moveTo(cx + sx * arm, cy)
        ..lineTo(cx, cy)
        ..lineTo(cx, cy + sy * arm);
    }

    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2 * strokeScale
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_FocusCornersPainter old) =>
      old.strokeScale != strokeScale || old.color != color;
}

/// 帧坐标到屏幕坐标的映射。
///
/// 预览是 BoxFit.cover 铺满盒子的，所以这里也照这个来。绘制和命中测试必须共
/// 用同一个，否则画出来的标记和真正点得中的位置会互相偏离。
({double scale, double dx, double dy}) _coverFit(Size size, int fw, int fh) {
  final scale = math.max(size.width / fw, size.height / fh);
  return (
    scale: scale,
    dx: (size.width - fw * scale) / 2,
    dy: (size.height - fh * scale) / 2,
  );
}

/// 被扫的这一帧里的一个点，换成 `focusAt` 要的那套比例坐标。
///
/// 帧是相对屏幕摆正的；纹理里的画面是相对设备摆正的，后者比前者顺时针多转了
/// [WxPreviewSize.quarterTurns]，所以这里往回转。
(double, double) _previewFraction(double fx, double fy, int quarterTurns) =>
    switch (quarterTurns) {
      1 => (fy, 1 - fx),
      2 => (1 - fx, 1 - fy),
      3 => (1 - fy, fx),
      _ => (fx, fy),
    };

const double _kPickRadius = 22;

Offset _pickCenter(ScanResult r, Size box, ScanOutcome f) {
  final m = _coverFit(box, f.width, f.height);
  final c = r.corners.centre;
  return Offset(c.dx * m.scale + m.dx, c.dy * m.scale + m.dy);
}

ScanResult? _pickHitTest(Offset tap, Size box, ScanOutcome frame) {
  ScanResult? best;
  var bestDist = double.infinity;
  for (final r in frame.results) {
    if (r.corners.isEmpty) continue;
    final d = (_pickCenter(r, box, frame) - tap).distance;
    if (d < bestDist) {
      bestDist = d;
      best = r;
    }
  }
  return bestDist <= _kPickRadius * 2 ? best : null;
}

/// 一帧多码时的选择层：压暗画面，每个码画出轮廓和一个可以点的圆点。
class _PickPainter extends CustomPainter {
  const _PickPainter({required this.frame, required this.color});

  final ScanOutcome frame;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (frame.width == 0 || frame.height == 0) return;
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = Colors.black.withValues(alpha: 0.5),
    );

    final m = _coverFit(size, frame.width, frame.height);
    Offset at(ScanPoint p) =>
        Offset(p.dx * m.scale + m.dx, p.dy * m.scale + m.dy);

    for (final r in frame.results) {
      if (r.corners.isEmpty) continue;
      final path = Path();
      for (var i = 0; i < r.corners.length; i++) {
        final p = at(r.corners[i]);
        if (i == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      path.close();
      canvas.drawPath(path, Paint()..color = color.withValues(alpha: 0.18));
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke,
      );
      final c = _pickCenter(r, size, frame);
      canvas.drawCircle(
          c, _kPickRadius + 6, Paint()..color = color.withValues(alpha: 0.25));
      canvas.drawCircle(c, _kPickRadius, Paint()..color = color);
      final arrow = Paint()
        ..color = Colors.white
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke;
      canvas.drawLine(c.translate(-4, -7), c.translate(4, 0), arrow);
      canvas.drawLine(c.translate(4, 0), c.translate(-4, 7), arrow);
    }
  }

  @override
  bool shouldRepaint(_PickPainter old) =>
      old.frame != frame || old.color != color;
}

/// 把解出来的码的四个角画出来，帧坐标按 BoxFit.cover 的方式映射到屏幕坐标。
class _CodeMarkerPainter extends CustomPainter {
  _CodeMarkerPainter({required this.frame, required this.color});

  final ScanOutcome frame;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (frame.results.isEmpty || frame.width == 0 || frame.height == 0) return;

    // 被扫的帧和预览的尺寸可以不一样，所以这里也要过一遍 cover 映射，和命中
    // 测试共用。
    final m = _coverFit(size, frame.width, frame.height);

    for (final r in frame.results) {
      if (r.corners.isEmpty) continue;
      final path = Path();
      for (var i = 0; i < r.corners.length; i++) {
        final p = Offset(
            r.corners[i].dx * m.scale + m.dx, r.corners[i].dy * m.scale + m.dy);
        if (i == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      path.close();
      canvas.drawPath(
        path,
        Paint()..color = color.withValues(alpha: 0.25),
      );
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..strokeWidth = 3
          ..style = PaintingStyle.stroke,
      );
      final c = r.corners.centre;
      canvas.drawCircle(
        Offset(c.dx * m.scale + m.dx, c.dy * m.scale + m.dy),
        8,
        Paint()..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_CodeMarkerPainter old) =>
      old.frame != frame || old.color != color;
}

const _kDetectModelAsset = 'assets/models/detect.tflite';
const _kSrModelAsset = 'assets/models/sr.tflite';

/// CNN 权重。两个页面都要用，所以只读一次留着——加起来一兆多，每开一次相机
/// 都从 asset 里搬一遍没有必要。
final Map<String, Future<Uint8List>> _modelCache = {};

Future<Uint8List> _loadModel(String path) =>
    _modelCache[path] ??= rootBundle.load(path).then((data) =>
        // offset 和 length 不是可选的：打包后的 asset 可能只是某个大缓冲区
        // 里的一段，不带参数的 asUint8List() 会读过头。
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));

/// 自动放大的目标：让码占到画面短边的这个比例。
const double _kZoomTargetFraction = 0.45;

/// 倍率多久走一步。一秒三十步：已经细到看不出台阶，又不至于把平台调用打满。
const Duration _kZoomStepEvery = Duration(milliseconds: 33);

/// 走完剩余距离的时间常数，决定这一步吃掉多少。
const Duration _kZoomSettle = Duration(milliseconds: 420);

/// 速度渐入的时长，起步才不会一顿。
const Duration _kZoomRampIn = Duration(milliseconds: 260);

/// 自动放大的上限。再往上就该让用户自己动手了。
const double _kMaxAutoZoom = 4.0;

/// 超过这个比例的码就不自动对焦了：它已经在连续对焦看的地方。
const double _kAutoFocusMaxFraction = 0.45;

/// 用户手动对过焦之后，自动对焦让开多久。
const Duration _kManualFocusHold = Duration(seconds: 2);

/// 两次自动对焦之间至少隔多久。
const Duration _kAutoFocusInterval = Duration(milliseconds: 1500);

/// 目标移动超过这么多（归一化坐标）才算换了地方，值得再对一次。
const double _kAutoFocusMoved = 0.06;

/// 目标没动的话，多久之后才再对一次。
const Duration _kAutoFocusRepeat = Duration(seconds: 4);

/// 连续这么久什么都没检测到，就对着中心盲对一次焦。
const Duration _kBlindFocusAfter = Duration(seconds: 1);

/// 盲对焦之间至少隔多久。
const Duration _kBlindFocusInterval = Duration(seconds: 2);

/// 用户手动缩放之后，自动放大让开多久。
const Duration _kManualZoomHold = Duration(seconds: 5);

/// 刚退出选码之后，自动放大让开多久。
const Duration _kPickExitZoomHold = Duration(seconds: 3);

/// 解出一个码、但检测看见不止一个时，多等这么久看第二个出不出得来。
/// 等不到就按这一个算，免得用户干看着。
const Duration _kMultiCodeGrace = Duration(milliseconds: 700);
