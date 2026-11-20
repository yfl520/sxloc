import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/foundation.dart';

import 'android_map_link.dart';
import 'map_link_coordinates.dart';

void registerMapLinkLicenses() {
  LicenseRegistry.addLicense(() async* {
    yield const LicenseEntryWithLineBreaks([
      'gcoord · 百度坐标换算',
    ], mapLinkCoordinateLicense);
  });
}

class MapLinkSelection {
  const MapLinkSelection(this.place, this.datum);
  final MapLinkPlace place;
  final MapLinkDatum datum;
}

/// Preview an incoming Android share; no text input or clipboard access.
class AndroidMapLinkImport extends StatefulWidget {
  const AndroidMapLinkImport({
    super.key,
    required this.initialText,
    this.initialError,
    this.resolver,
  });
  final String initialText;
  final String? initialError;
  final AndroidMapLink? resolver;

  @override
  State<AndroidMapLinkImport> createState() => _AndroidMapLinkImportState();
}

class _AndroidMapLinkImportState extends State<AndroidMapLinkImport> {
  late final _resolver = widget.resolver ?? AndroidMapLink();
  bool _busy = false;
  String? _error;
  MapLinkPlace? _place;
  MapLinkDatum _datum = MapLinkDatum.automatic;
  bool _showDatum = false;

  @override
  void initState() {
    super.initState();
    _error = widget.initialError;
    if (_error == null) {
      unawaited(_resolve());
    }
  }

  @override
  void dispose() {
    _resolver.cancel();
    super.dispose();
  }

  Future<void> _resolve() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _place = null;
    });
    try {
      final place = await _resolver.resolve(widget.initialText);
      if (mounted) setState(() => _place = place);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is MapLinkException ? error.message : '无法解析分享位置',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final place = _place;
    final point = place?.point(_datum);
    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.white,
      navigationBar: CupertinoNavigationBar(
        automaticallyImplyLeading: false,
        middle: const Text('分享位置'),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () => Navigator.pop(context),
          child: const Text('取消', style: TextStyle(fontSize: 14)),
        ),
      ),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: _busy
                  ? const Center(child: CupertinoActivityIndicator(radius: 14))
                  : SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
                      child: place != null && point != null
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  place.title,
                                  style: const TextStyle(
                                    fontSize: 26,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  '${point.latitude.toStringAsFixed(6)}, ${point.longitude.toStringAsFixed(6)}',
                                  style: const TextStyle(
                                    fontSize: 16,
                                    color: Color(0xFF71717A),
                                  ),
                                ),
                                if (place.approximate) ...[
                                  const SizedBox(height: 16),
                                  const Text(
                                    '链接仅包含地图中心',
                                    style: TextStyle(fontSize: 14),
                                  ),
                                ],
                                const SizedBox(height: 24),
                                CupertinoButton(
                                  padding: EdgeInsets.zero,
                                  onPressed: () =>
                                      setState(() => _showDatum = !_showDatum),
                                  child: Row(
                                    children: [
                                      const Text(
                                        '坐标系',
                                        style: TextStyle(fontSize: 14),
                                      ),
                                      const SizedBox(width: 6),
                                      Icon(
                                        _showDatum
                                            ? CupertinoIcons.chevron_up
                                            : CupertinoIcons.chevron_down,
                                        size: 12,
                                      ),
                                    ],
                                  ),
                                ),
                                if (_showDatum)
                                  CupertinoSlidingSegmentedControl<
                                    MapLinkDatum
                                  >(
                                    groupValue: _datum,
                                    children: const {
                                      MapLinkDatum.automatic: Text('自动'),
                                      MapLinkDatum.wgs84: Text('WGS-84'),
                                      MapLinkDatum.gcj02: Text('高德'),
                                      MapLinkDatum.bd09: Text('百度'),
                                    },
                                    onValueChanged: (value) {
                                      if (value != null) {
                                        setState(() => _datum = value);
                                      }
                                    },
                                  ),
                              ],
                            )
                          : Text(
                              _error ?? '未收到地点链接',
                              style: const TextStyle(fontSize: 17, height: 1.5),
                            ),
                    ),
            ),
            if (place != null && point != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
                child: CupertinoButton.filled(
                  borderRadius: BorderRadius.circular(14),
                  onPressed: () =>
                      Navigator.pop(context, MapLinkSelection(place, _datum)),
                  child: const Text('查看地图'),
                ),
              )
            else if (!_busy &&
                widget.initialError == null &&
                widget.initialText.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
                child: CupertinoButton.filled(
                  borderRadius: BorderRadius.circular(14),
                  onPressed: _resolve,
                  child: const Text('重试'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
