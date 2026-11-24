import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import 'api.dart';
import 'desktop_video_player.dart';
import 'models.dart';
import 'transfer_manager.dart';

const bg = Color(0xFF070B16);
const panel = Color(0xFF0D1424);
const panel2 = Color(0xFF111A2D);
const selectedPanel = Color(0xFF162544);
const border = Color(0x1F6E7EA8);
const accent = Color(0xFF7AA2F7);
const purple = Color(0xFF9B8AFB);
const green = Color(0xFF78D7A5);
const red = Color(0xFFE56B7F);
const folderMarkerName = '__overcast_folder__.txt';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  OvercastDesktopVideoPlayerPlatform.registerIfNeeded();
  runApp(const OvercastApp());
}

class OvercastApp extends StatelessWidget {
  const OvercastApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Overcast',
        theme: ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: bg,
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: accent,
            brightness: Brightness.dark,
          ),
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: panel,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(15),
              borderSide: const BorderSide(color: border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(15),
              borderSide: const BorderSide(color: border),
            ),
          ),
        ),
        home: const OvercastHome(),
      );
}

class OvercastHome extends StatefulWidget {
  const OvercastHome({super.key});
  @override
  State<OvercastHome> createState() => _OvercastHomeState();
}

class _OvercastHomeState extends State<OvercastHome>
    with WidgetsBindingObserver {
  late OvercastApi api;
  late TransferManager transferManager;
  SharedPreferences? prefs;
  String server = 'http://192.168.1.9';
  bool connected = false;
  bool loading = true;
  bool grid = true;
  String path = 'home/';
  String section = 'Home';
  String query = '';
  List<OvercastFile> items = [];
  List<OvercastFile> allFiles = [];
  List<TrashEntry> trash = [];
  StorageInfo? storage;
  Timer? heartbeat;
  final search = TextEditingController();
  final FocusNode _keyboardFocusNode = FocusNode();

  // Multi-selection state
  final Set<String> _selectedKeys = <String>{};
  String? _lastSelectedKey;
  bool _mobileSelectionMode = false;

  // Desktop drag-selection (marquee) state
  final GlobalKey _listingAreaKey = GlobalKey();
  final Map<String, GlobalKey> _itemGlobalKeys = <String, GlobalKey>{};
  Offset? _dragStartLocal;
  Offset? _dragCurrentLocal;
  bool _isDragSelecting = false;
  Set<String> _dragBaseSelection = <String>{};

  // Transfer panel UI state
  bool _transferPanelVisible = false;
  bool _transferPanelMinimized = false;

  bool get _isMobilePlatform => Platform.isAndroid || Platform.isIOS;

  bool get _inSelectionMode =>
      _selectedKeys.isNotEmpty || _mobileSelectionMode;

  bool get _isCtrlHeld {
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    return keys.contains(LogicalKeyboardKey.controlLeft) ||
        keys.contains(LogicalKeyboardKey.controlRight) ||
        keys.contains(LogicalKeyboardKey.metaLeft) ||
        keys.contains(LogicalKeyboardKey.metaRight);
  }

  bool get _isShiftHeld {
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    return keys.contains(LogicalKeyboardKey.shiftLeft) ||
        keys.contains(LogicalKeyboardKey.shiftRight);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    api = OvercastApi(server);
    transferManager = TransferManager(
      api: api,
      onUploadCompleted: () => refresh(silent: true),
      onNotify: (msg, {bool error = false}) => _snack(msg, error: error),
    );
    _boot();
  }

  Future<void> _boot() async {
    prefs = await SharedPreferences.getInstance();
    server = prefs?.getString('server') ?? server;
    grid = prefs?.getBool('grid') ?? true;
    api = OvercastApi(server);
    transferManager.updateApi(api);
    await refresh();
    heartbeat = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _checkConnection(),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      transferManager.onAppLifecyclePaused();
    } else if (state == AppLifecycleState.resumed) {
      transferManager.onAppLifecycleResumed();
      _checkConnection();
    }
  }

  Future<void> _checkConnection() async {
    try {
      final ok = await api.isHealthy();
      if (mounted && ok != connected) setState(() => connected = ok);
    } catch (_) {
      if (mounted && connected) setState(() => connected = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    heartbeat?.cancel();
    transferManager.dispose();
    search.dispose();
    _keyboardFocusNode.dispose();
    super.dispose();
  }

  Future<void> refresh({bool silent = false}) async {
    if (!mounted) return;
    if (!silent) {
      setState(() => loading = true);
    }
    try {
      final ok = await api.isHealthy();
      if (section == 'Trash') {
        trash = await api.trashList();
        items = [];
        allFiles = [];
      } else {
        allFiles = await api.files();
        items = allFiles
            .where((f) => f.path == path && !_isFolderMarker(f))
            .toList();
      }
      storage = await api.storage();
      if (!mounted) return;
      setState(() {
        connected = ok;
        loading = false;
        _pruneInvalidSelections();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        connected = false;
        loading = false;
      });
      if (!silent) {
        _snack(api.errorMessage(e), error: true);
      }
    }
  }

  void _pruneInvalidSelections() {
    final validKeys = _currentOrderedKeys().toSet();
    _selectedKeys.removeWhere((k) => !validKeys.contains(k));
    if (_selectedKeys.isEmpty) {
      _mobileSelectionMode = false;
      _lastSelectedKey = null;
    }
  }

  bool _isFolderMarker(OvercastFile f) => f.name == folderMarkerName;

  List<OvercastFile> get filtered {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return items;
    return items.where((f) => f.name.toLowerCase().contains(q)).toList();
  }

  List<String> get childFolders {
    final prefix = path.endsWith('/') ? path : '$path/';
    final result = <String>{};
    final q = query.trim().toLowerCase();
    for (final f in allFiles) {
      if (!f.path.startsWith(prefix) || f.path == prefix) continue;
      final remainder = f.path.substring(prefix.length);
      final slash = remainder.indexOf('/');
      if (slash > 0) {
        final folderName = remainder.substring(0, slash);
        if (q.isEmpty || folderName.toLowerCase().contains(q)) {
          result.add(folderName);
        }
      }
    }
    final list = result.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return list;
  }

  List<String> _currentOrderedKeys() {
    if (section == 'Trash') {
      return trash.map((t) => 'trash:${t.id}').toList();
    }
    final folders = childFolders;
    final files = filtered;
    return <String>[
      ...folders.map((name) => 'folder:$name'),
      ...files.map((f) => 'file:${f.id}'),
    ];
  }

  GlobalKey _keyForItem(String itemKey) {
    return _itemGlobalKeys.putIfAbsent(itemKey, () => GlobalKey());
  }

  List<OvercastFile> _filesUnder(String folderPath) {
    final prefix = folderPath.endsWith('/') ? folderPath : '$folderPath/';
    return allFiles.where((f) => f.path.startsWith(prefix)).toList();
  }

  String _joinPath(String base, String name) {
    final b = base.endsWith('/') ? base : '$base/';
    return '$b$name/';
  }

  // --- Selection Management ---

  void _clearSelection() {
    if (_selectedKeys.isEmpty && !_mobileSelectionMode) return;
    setState(() {
      _selectedKeys.clear();
      _lastSelectedKey = null;
      _mobileSelectionMode = false;
    });
  }

  void _selectAll() {
    final allKeys = _currentOrderedKeys();
    if (allKeys.isEmpty) return;
    setState(() {
      _selectedKeys
        ..clear()
        ..addAll(allKeys);
      _lastSelectedKey = allKeys.last;
    });
  }

  void _handleItemTap(String itemKey, {VoidCallback? onSingleOpen}) {
    _keyboardFocusNode.requestFocus();

    if (_isMobilePlatform) {
      if (_inSelectionMode) {
        setState(() {
          if (_selectedKeys.contains(itemKey)) {
            _selectedKeys.remove(itemKey);
            if (_selectedKeys.isEmpty) {
              _mobileSelectionMode = false;
            }
          } else {
            _selectedKeys.add(itemKey);
          }
          _lastSelectedKey = itemKey;
        });
      } else {
        onSingleOpen?.call();
      }
      return;
    }

    // Desktop click selection behavior (Ctrl+Click, Shift+Click, Single Click)
    final ordered = _currentOrderedKeys();
    final clickedIdx = ordered.indexOf(itemKey);

    setState(() {
      if (_isShiftHeld && _lastSelectedKey != null && clickedIdx >= 0) {
        final anchorIdx = ordered.indexOf(_lastSelectedKey!);
        if (anchorIdx >= 0) {
          final start = math.min(anchorIdx, clickedIdx);
          final end = math.max(anchorIdx, clickedIdx);
          if (!_isCtrlHeld) {
            _selectedKeys.clear();
          }
          for (int i = start; i <= end; i++) {
            _selectedKeys.add(ordered[i]);
          }
          return;
        }
      }

      if (_isCtrlHeld) {
        if (_selectedKeys.contains(itemKey)) {
          _selectedKeys.remove(itemKey);
        } else {
          _selectedKeys.add(itemKey);
        }
        _lastSelectedKey = itemKey;
      } else {
        _selectedKeys
          ..clear()
          ..add(itemKey);
        _lastSelectedKey = itemKey;
      }
    });
  }

  void _toggleCheckboxSelection(String itemKey) {
    _keyboardFocusNode.requestFocus();
    setState(() {
      if (_selectedKeys.contains(itemKey)) {
        _selectedKeys.remove(itemKey);
        if (_selectedKeys.isEmpty) {
          _mobileSelectionMode = false;
        }
      } else {
        _selectedKeys.add(itemKey);
        if (_isMobilePlatform) {
          _mobileSelectionMode = true;
        }
      }
      _lastSelectedKey = itemKey;
    });
  }

  void _handleItemLongPress(String itemKey) {
    setState(() {
      _mobileSelectionMode = true;
      _selectedKeys.add(itemKey);
      _lastSelectedKey = itemKey;
    });
  }

  // --- Desktop Rubber-Band Drag Selection ---

  Rect? get _currentDragRect {
    if (!_isDragSelecting ||
        _dragStartLocal == null ||
        _dragCurrentLocal == null) {
      return null;
    }
    return Rect.fromPoints(_dragStartLocal!, _dragCurrentLocal!);
  }

  void _onDragSelectionStart(Offset localPosition) {
    if (_isMobilePlatform) return;
    _keyboardFocusNode.requestFocus();
    _dragStartLocal = localPosition;
    _dragCurrentLocal = localPosition;
    _isDragSelecting = false;
    _dragBaseSelection =
        _isCtrlHeld ? Set<String>.from(_selectedKeys) : <String>{};
  }

  void _onDragSelectionUpdate(Offset localPosition) {
    if (_isMobilePlatform || _dragStartLocal == null) return;
    _dragCurrentLocal = localPosition;
    final rect = Rect.fromPoints(_dragStartLocal!, _dragCurrentLocal!);

    if (!_isDragSelecting && rect.size.longestSide > 6.0) {
      _isDragSelecting = true;
    }

    if (!_isDragSelecting) return;

    final containerBox =
        _listingAreaKey.currentContext?.findRenderObject() as RenderBox?;
    if (containerBox == null || !containerBox.hasSize) return;

    final newlySelected = Set<String>.from(_dragBaseSelection);
    final ordered = _currentOrderedKeys();

    for (final key in ordered) {
      final itemContext = _itemGlobalKeys[key]?.currentContext;
      if (itemContext == null) continue;
      final itemBox = itemContext.findRenderObject() as RenderBox?;
      if (itemBox == null || !itemBox.attached || !itemBox.hasSize) continue;

      final topLeftGlobal = itemBox.localToGlobal(Offset.zero);
      final bottomRightGlobal = itemBox.localToGlobal(
        Offset(itemBox.size.width, itemBox.size.height),
      );
      final topLeftLocal = containerBox.globalToLocal(topLeftGlobal);
      final bottomRightLocal = containerBox.globalToLocal(bottomRightGlobal);
      final itemRect = Rect.fromPoints(topLeftLocal, bottomRightLocal);

      if (rect.overlaps(itemRect)) {
        newlySelected.add(key);
      }
    }

    setState(() {
      _selectedKeys
        ..clear()
        ..addAll(newlySelected);
    });
  }

  void _onDragSelectionEnd() {
    if (_isDragSelecting) {
      setState(() {
        _isDragSelecting = false;
        _dragStartLocal = null;
        _dragCurrentLocal = null;
      });
    } else {
      _dragStartLocal = null;
      _dragCurrentLocal = null;
    }
  }

  List<OvercastFile> get _selectedFiles {
    final mapById = {for (final f in items) f.id: f};
    final result = <OvercastFile>[];
    for (final key in _selectedKeys) {
      if (key.startsWith('file:')) {
        final id = key.substring(5);
        final file = mapById[id];
        if (file != null) result.add(file);
      }
    }
    return result;
  }

  List<String> get _selectedFolderNames {
    final result = <String>[];
    for (final key in _selectedKeys) {
      if (key.startsWith('folder:')) {
        result.add(key.substring(7));
      }
    }
    return result;
  }

  int get _selectedTotalBytes {
    int sum = 0;
    for (final f in _selectedFiles) {
      sum += f.size;
    }
    for (final folderName in _selectedFolderNames) {
      final folderPath = _joinPath(path, folderName);
      for (final f in _filesUnder(folderPath)) {
        if (!_isFolderMarker(f)) sum += f.size;
      }
    }
    return sum;
  }

  // --- Bulk File Operations ---

  Future<void> _bulkDownloadSelected() async {
    final files = _selectedFiles;
    final folders = _selectedFolderNames;
    if (files.isEmpty && folders.isEmpty) return;

    // If only a single file (and no folder) is selected, download it directly.
    if (files.length == 1 && folders.isEmpty) {
      await _download(files.first);
      return;
    }

    final dir = await _resolveDownloadDirectory();
    final timestamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    final baseName = folders.length == 1 && files.isEmpty
        ? '${folders.first}.zip'
        : 'Overcast-$timestamp.zip';
    final safePath = _uniqueName(dir, baseName);
    final archiveFileName = safePath.split(Platform.pathSeparator).last;

    final folderPaths = folders.map((name) => _joinPath(path, name)).toList();
    final estimatedBytes = _selectedTotalBytes;

    setState(() {
      _transferPanelVisible = true;
      _transferPanelMinimized = false;
    });

    transferManager.enqueueBulkDownload(
      fileIds: files.map((f) => f.id).toList(),
      folderPaths: folderPaths,
      basePath: path,
      archiveName: archiveFileName,
      targetFilePath: safePath,
      estimatedTotalBytes: estimatedBytes,
    );

    _snack('Queued bulk ZIP download ($archiveFileName)');
  }

  Future<void> _bulkDeleteSelected() async {
    if (section == 'Trash') {
      final selectedTrashIds = _selectedKeys
          .where((k) => k.startsWith('trash:'))
          .map((k) => k.substring(6))
          .toList();
      if (selectedTrashIds.isEmpty) return;

      final confirmed = await _confirm(
        'Permanently delete ${selectedTrashIds.length} item${selectedTrashIds.length == 1 ? '' : 's'}?',
        'This will permanently delete ${selectedTrashIds.length} selected item${selectedTrashIds.length == 1 ? '' : 's'} from Trash. This action cannot be undone.',
      );
      if (!confirmed) return;

      try {
        final res = await api.bulkDelete(
          fileIds: selectedTrashIds,
          permanent: true,
        );
        _clearSelection();
        await refresh();
        if (res.failed.isEmpty) {
          _snack('Permanently deleted ${res.deletedCount} items');
        } else {
          _snack(
            'Deleted ${res.deletedCount} items (${res.failed.length} failed)',
            error: true,
          );
        }
      } catch (e) {
        _snack('Bulk delete failed: ${api.errorMessage(e)}', error: true);
      }
      return;
    }

    final files = _selectedFiles;
    final folders = _selectedFolderNames;
    if (files.isEmpty && folders.isEmpty) return;

    final folderPaths = folders.map((name) => _joinPath(path, name)).toList();
    int descendantCount = 0;
    for (final fp in folderPaths) {
      descendantCount += _filesUnder(fp).length;
    }

    final summaryParts = <String>[];
    if (files.isNotEmpty) {
      summaryParts.add('${files.length} file${files.length == 1 ? '' : 's'}');
    }
    if (folders.isNotEmpty) {
      summaryParts.add(
        '${folders.length} folder${folders.length == 1 ? '' : 's'} '
        '($descendantCount item${descendantCount == 1 ? '' : 's'} inside)',
      );
    }

    final confirmed = await _confirm(
      'Move ${files.length + folders.length} selected item${(files.length + folders.length) == 1 ? '' : 's'} to Trash?',
      'You are about to move ${summaryParts.join(' and ')} to Trash.',
    );
    if (!confirmed) return;

    try {
      final res = await api.bulkDelete(
        fileIds: files.map((f) => f.id).toList(),
        folderPaths: folderPaths,
        permanent: false,
      );
      _clearSelection();
      await refresh();
      if (res.failed.isEmpty) {
        _snack(
          'Moved ${res.deletedCount} item${res.deletedCount == 1 ? '' : 's'} to Trash',
        );
      } else {
        _snack(
          'Moved ${res.deletedCount} items to Trash; ${res.failed.length} failed',
          error: true,
        );
      }
    } catch (e) {
      _snack('Bulk delete failed: ${api.errorMessage(e)}', error: true);
      await refresh();
    }
  }

  // --- Settings & File Actions ---

  Future<void> _settings() async {
    final controller = TextEditingController(text: server);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Overcast connection'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Server URL',
            hintText: 'http://192.168.1.9:8000',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null || result.isEmpty) return;
    server = result.replaceFirst(RegExp(r'/*$'), '');
    await prefs?.setString('server', server);
    api = OvercastApi(server);
    transferManager.updateApi(api);
    path = 'home/';
    section = 'Home';
    _clearSelection();
    await refresh();
  }

  Future<void> _pickUploads() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: false,
    );
    if (result == null || result.files.isEmpty) return;

    int queued = 0;
    for (final file in result.files) {
      final p = file.path;
      if (p == null) continue;
      _uploadOne(p, file.name, destination: path);
      queued++;
    }

    if (queued > 0) {
      setState(() {
        _transferPanelVisible = true;
        _transferPanelMinimized = false;
      });
      _snack(
        'Queued $queued file${queued == 1 ? '' : 's'} for background upload',
      );
    }
  }

  Future<void> _createFolder() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('New folder'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Folder name',
            hintText: 'Projects',
          ),
          onSubmitted: (v) => Navigator.pop(context, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) return;
    if (name == folderMarkerName ||
        name.contains('/') ||
        name.contains('\\')) {
      _snack('That is not a valid folder name.', error: true);
      return;
    }
    final folderPath = _joinPath(path, name);
    try {
      await api.uploadBytes(folderPath, folderMarkerName, Uint8List(0));
      await refresh();
      _snack('Created folder $name');
    } catch (e) {
      _snack('Could not create folder: ${api.errorMessage(e)}', error: true);
    }
  }

  Future<void> _pickFolderUpload() async {
    final folder = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Select a folder to upload',
    );
    if (folder == null) return;

    final root = Directory(folder);
    final rootName = root.path
        .split(Platform.pathSeparator)
        .where((p) => p.isNotEmpty)
        .last;
    final files = <File>[];
    final directories = <Directory>[];

    try {
      await for (final entity
          in root.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          files.add(entity);
        } else if (entity is Directory) {
          directories.add(entity);
        }
      }
    } catch (e) {
      _snack('Could not read folder: $e', error: true);
      return;
    }

    final rootPrefix = root.path.endsWith(Platform.pathSeparator)
        ? root.path
        : '${root.path}${Platform.pathSeparator}';
    final destinationRoot = _joinPath(path, rootName);

    setState(() {
      _transferPanelVisible = true;
      _transferPanelMinimized = false;
    });

    for (final file in files) {
      final relative = file.path.startsWith(rootPrefix)
          ? file.path.substring(rootPrefix.length)
          : file.uri.pathSegments.last;
      final parts = relative.split(Platform.pathSeparator);
      final fileName = parts.removeLast();
      final relativeDir = parts.join('/');
      final destination = relativeDir.isEmpty
          ? destinationRoot
          : '$destinationRoot$relativeDir/';
      _uploadOne(file.path, fileName, destination: destination);
    }

    final allDirectories = <Directory>[root, ...directories];
    for (final dir in allDirectories) {
      final dirPrefix = dir.path.endsWith(Platform.pathSeparator)
          ? dir.path
          : '${dir.path}${Platform.pathSeparator}';
      final hasFile = files.any((file) =>
          file.path == dir.path || file.path.startsWith(dirPrefix));
      if (hasFile) continue;

      final relative = dir.path == root.path
          ? ''
          : dir.path
              .substring(rootPrefix.length)
              .replaceAll(Platform.pathSeparator, '/');
      final destination = relative.isEmpty
          ? destinationRoot
          : '$destinationRoot$relative/';
      try {
        await api.uploadBytes(destination, folderMarkerName, Uint8List(0));
      } catch (e) {
        _snack(
          'Could not create empty folder ${dir.path}: ${api.errorMessage(e)}',
          error: true,
        );
      }
    }

    await refresh(silent: true);
    _snack('Queued folder "$rootName" for upload');
  }

  void _uploadOne(
    String filePath,
    String name, {
    required String destination,
  }) {
    transferManager.enqueueUpload(
      localFilePath: filePath,
      fileName: name,
      destinationFolder: destination,
    );
  }

  Future<void> _newText() async {
    final name = TextEditingController(text: 'notes.txt');
    final content = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('New text file'),
        content: SizedBox(
          width: 520,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: 'File name'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: content,
              maxLines: 7,
              decoration: const InputDecoration(labelText: 'Initial content'),
            ),
          ]),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (result == true) {
      try {
        await api.createText(name.text.trim(), path, content.text);
        await refresh();
        _snack('Created ${name.text.trim()}');
      } catch (e) {
        _snack(api.errorMessage(e), error: true);
      }
    }
    name.dispose();
    content.dispose();
  }

  Future<void> _renameFolder(String folderName) async {
    final oldPrefix = _joinPath(path, folderName);
    final controller = TextEditingController(text: folderName);
    final value = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Rename folder'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null || value.isEmpty || value == folderName) return;
    if (value == folderMarkerName ||
        value.contains('/') ||
        value.contains('\\')) {
      _snack('That is not a valid folder name.', error: true);
      return;
    }
    final newPrefix = _joinPath(path, value);
    final descendants = _filesUnder(oldPrefix);
    if (descendants.isEmpty) {
      _snack('Folder is empty and has no marker.', error: true);
      return;
    }
    try {
      for (final f in descendants) {
        final relativePath = f.path.substring(oldPrefix.length);
        await api.moveRename(f.id, '$newPrefix$relativePath', f.name);
      }
      await refresh();
      _snack('Folder renamed');
    } catch (e) {
      _snack('Could not rename folder: ${api.errorMessage(e)}', error: true);
      await refresh();
    }
  }

  Future<void> _moveFolder(String folderName) async {
    final oldPrefix = _joinPath(path, folderName);
    final controller = TextEditingController(text: path);
    final value = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Move folder'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Destination path',
            hintText: 'home/Projects/',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Move'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null || value.isEmpty) return;
    final destinationParent = value.endsWith('/') ? value : '$value/';
    if (destinationParent == oldPrefix ||
        destinationParent.startsWith(oldPrefix)) {
      _snack('A folder cannot be moved inside itself.', error: true);
      return;
    }
    final newPrefix = '$destinationParent$folderName/';
    final descendants = _filesUnder(oldPrefix);
    try {
      for (final f in descendants) {
        final relativePath = f.path.substring(oldPrefix.length);
        await api.moveRename(f.id, '$newPrefix$relativePath', f.name);
      }
      await refresh();
      _snack('Folder moved');
    } catch (e) {
      _snack('Could not move folder: ${api.errorMessage(e)}', error: true);
      await refresh();
    }
  }

  Future<void> _trashFolder(String folderName) async {
    final oldPrefix = _joinPath(path, folderName);
    final descendants = _filesUnder(oldPrefix);
    final yes = await _confirm(
      'Move folder to Trash?',
      'This will move ${descendants.length} item${descendants.length == 1 ? '' : 's'} inside “$folderName” to Trash.',
    );
    if (!yes) return;
    try {
      await api.bulkDelete(folderPaths: [oldPrefix]);
      await refresh();
      _snack('Folder moved to Trash');
    } catch (e) {
      _snack('Could not trash folder: ${api.errorMessage(e)}', error: true);
      await refresh();
    }
  }

  Future<void> _downloadFolder(String folderName) async {
    final folderPath = _joinPath(path, folderName);
    final dir = await _resolveDownloadDirectory();
    final safePath = _uniqueName(dir, '$folderName.zip');
    final archiveName = safePath.split(Platform.pathSeparator).last;

    int totalBytes = 0;
    for (final f in _filesUnder(folderPath)) {
      if (!_isFolderMarker(f)) totalBytes += f.size;
    }

    setState(() {
      _transferPanelVisible = true;
      _transferPanelMinimized = false;
    });

    transferManager.enqueueBulkDownload(
      fileIds: const [],
      folderPaths: [folderPath],
      basePath: path,
      archiveName: archiveName,
      targetFilePath: safePath,
      estimatedTotalBytes: totalBytes,
    );
    _snack('Downloading "$folderName" as ZIP in background');
  }

  Future<void> _showFolderActions(String folderName) async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: panel,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.folder_open_rounded),
            title: const Text('Open'),
            onTap: () {
              Navigator.pop(context);
              _navigateTo(_joinPath(path, folderName));
            },
          ),
          ListTile(
            leading: const Icon(Icons.archive_outlined),
            title: const Text('Download as ZIP'),
            onTap: () {
              Navigator.pop(context);
              _downloadFolder(folderName);
            },
          ),
          ListTile(
            leading: const Icon(Icons.check_box_outlined),
            title: const Text('Select folder'),
            onTap: () {
              Navigator.pop(context);
              _toggleCheckboxSelection('folder:$folderName');
            },
          ),
          ListTile(
            leading: const Icon(Icons.drive_file_rename_outline_rounded),
            title: const Text('Rename'),
            onTap: () {
              Navigator.pop(context);
              _renameFolder(folderName);
            },
          ),
          ListTile(
            leading: const Icon(Icons.drive_file_move_rounded),
            title: const Text('Move'),
            onTap: () {
              Navigator.pop(context);
              _moveFolder(folderName);
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline_rounded, color: red),
            title: const Text('Move to Trash'),
            onTap: () {
              Navigator.pop(context);
              _trashFolder(folderName);
            },
          ),
        ]),
      ),
    );
  }

  Future<void> _rename(OvercastFile f) async {
    final controller = TextEditingController(text: f.name);
    final value = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Rename'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null || value.isEmpty || value == f.name) return;
    try {
      await api.moveRename(f.id, f.path, value);
      await refresh();
      _snack('Renamed successfully');
    } catch (e) {
      _snack(api.errorMessage(e), error: true);
    }
  }

  Future<void> _move(OvercastFile f) async {
    final controller = TextEditingController(text: f.path);
    final value = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Move file'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Destination path',
            hintText: 'home/photos/',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Move'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null || value.isEmpty || value == f.path) return;
    try {
      await api.moveRename(
        f.id,
        value.endsWith('/') ? value : '$value/',
        f.name,
      );
      await refresh();
      _snack('Moved successfully');
    } catch (e) {
      _snack(api.errorMessage(e), error: true);
    }
  }

  Future<void> _trash(OvercastFile f) async {
    final yes = await _confirm(
      'Move to Trash?',
      '“${f.name}” will be moved to Trash.',
    );
    if (!yes) return;
    try {
      await api.trash(f.id);
      _selectedKeys.remove('file:${f.id}');
      await refresh();
      _snack('Moved to Trash');
    } catch (e) {
      _snack(api.errorMessage(e), error: true);
    }
  }

  Future<void> _restore(TrashEntry f) async {
    try {
      await api.restore(f.id);
      _selectedKeys.remove('trash:${f.id}');
      await refresh();
      _snack('Restored ${f.name}');
    } catch (e) {
      _snack(api.errorMessage(e), error: true);
    }
  }

  Future<void> _permanentDelete(TrashEntry f) async {
    final yes = await _confirm(
      'Delete permanently?',
      'This cannot be undone.',
    );
    if (!yes) return;
    try {
      await api.permanentlyDelete(f.id);
      _selectedKeys.remove('trash:${f.id}');
      await refresh();
      _snack('Permanently deleted');
    } catch (e) {
      _snack(api.errorMessage(e), error: true);
    }
  }

  Future<bool> _confirm(String title, String body) async {
    return await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: Text(title),
            content: Text(body),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Continue'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<Directory> _resolveDownloadDirectory() async {
    Directory? dir;
    if (!Platform.isAndroid && !Platform.isIOS) {
      try {
        dir = await getDownloadsDirectory();
      } catch (_) {}
    }
    if (Platform.isAndroid) {
      final androidDownload = Directory('/storage/emulated/0/Download');
      if (await androidDownload.exists()) {
        dir = androidDownload;
      } else {
        try {
          dir = await getExternalStorageDirectory();
        } catch (_) {}
      }
    }
    dir ??= await getApplicationDocumentsDirectory();
    return dir;
  }

  Future<void> _download(OvercastFile f) async {
    final dir = await _resolveDownloadDirectory();
    final safe = _uniqueName(dir, f.name);

    setState(() {
      _transferPanelVisible = true;
      _transferPanelMinimized = false;
    });

    transferManager.enqueueDownload(
      fileId: f.id,
      fileName: f.name,
      totalBytes: f.size,
      targetFilePath: safe,
    );
    _snack('Downloading ${f.name} in background');
  }

  String _uniqueName(Directory dir, String name) {
    final first = File('${dir.path}${Platform.pathSeparator}$name');
    if (!first.existsSync()) return first.path;
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '';
    for (var i = 1; i < 10000; i++) {
      final f = File('${dir.path}${Platform.pathSeparator}$stem ($i)$ext');
      if (!f.existsSync()) return f.path;
    }
    return first.path;
  }

  Future<void> _openPath(String filePath) async {
    try {
      final uri = Uri.file(filePath);
      await launchUrl(uri);
    } catch (_) {
      _snack('Saved to $filePath');
    }
  }

  Future<void> _open(OvercastFile f) async {
    if (f.isText) {
      await _textEditor(f);
    } else if (f.isImage || f.isVideo || f.isAudio) {
      await showDialog(
        context: context,
        builder: (_) => PreviewDialog(api: api, file: f),
      );
    } else if (f.isPdf) {
      await launchUrl(Uri.parse(api.previewUrl(f.id)));
    } else {
      await _download(f);
    }
  }

  Future<void> _textEditor(OvercastFile f) async {
    try {
      final initial = await api.readText(f.id);
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => TextEditorPage(api: api, file: f, initial: initial),
        ),
      );
      await refresh();
    } catch (e) {
      _snack(api.errorMessage(e), error: true);
    }
  }

  void _snack(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: error ? const Color(0xFF5A1E2B) : panel2,
      behavior: SnackBarBehavior.floating,
    ));
  }

  void _navigateTo(String p) {
    setState(() {
      path = p.endsWith('/') ? p : '$p/';
      section = 'Home';
      _selectedKeys.clear();
      _lastSelectedKey = null;
      _mobileSelectionMode = false;
    });
    refresh();
  }

  List<String> _crumbs() {
    final clean = path.replaceFirst(RegExp(r'/$'), '');
    return clean.split('/').where((e) => e.isNotEmpty).toList();
  }

  Future<void> _showActions(OvercastFile f) async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: panel,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.open_in_new_rounded),
            title: const Text('Open'),
            onTap: () {
              Navigator.pop(context);
              _open(f);
            },
          ),
          ListTile(
            leading: const Icon(Icons.download_rounded),
            title: const Text('Download'),
            onTap: () {
              Navigator.pop(context);
              _download(f);
            },
          ),
          ListTile(
            leading: const Icon(Icons.check_box_outlined),
            title: const Text('Select'),
            onTap: () {
              Navigator.pop(context);
              _toggleCheckboxSelection('file:${f.id}');
            },
          ),
          ListTile(
            leading: const Icon(Icons.drive_file_rename_outline_rounded),
            title: const Text('Rename'),
            onTap: () {
              Navigator.pop(context);
              _rename(f);
            },
          ),
          ListTile(
            leading: const Icon(Icons.drive_file_move_rounded),
            title: const Text('Move'),
            onTap: () {
              Navigator.pop(context);
              _move(f);
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline_rounded, color: red),
            title: const Text('Move to Trash'),
            onTap: () {
              Navigator.pop(context);
              _trash(f);
            },
          ),
        ]),
      ),
    );
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    // Ignore shortcuts when typing in search bar
    if (FocusManager.instance.primaryFocus?.context?.widget is EditableText) {
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        _keyboardFocusNode.requestFocus();
        _clearSelection();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (_inSelectionMode) {
        _clearSelection();
        return KeyEventResult.handled;
      }
    } else if (event.logicalKey == LogicalKeyboardKey.keyA && _isCtrlHeld) {
      _selectAll();
      return KeyEventResult.handled;
    } else if (event.logicalKey == LogicalKeyboardKey.delete &&
        _selectedKeys.isNotEmpty) {
      _bulkDeleteSelected();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Focus(
          focusNode: _keyboardFocusNode,
          autofocus: true,
          onKeyEvent: _handleKeyEvent,
          child: SafeArea(
            child: LayoutBuilder(builder: (_, c) {
              final desktop = c.maxWidth >= 900;
              return Stack(
                children: [
                  Row(children: [
                    if (desktop) _sidebar(),
                    Expanded(child: _body(desktop)),
                  ]),
                  _buildFloatingTransferOverlay(desktop),
                ],
              );
            }),
          ),
        ),
      );

  Widget _sidebar() => Container(
        width: 255,
        margin: const EdgeInsets.all(14),
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
        decoration: BoxDecoration(
          color: const Color(0xFF091020),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                gradient: const LinearGradient(colors: [accent, purple]),
              ),
              child: const Icon(Icons.cloud_rounded, color: Colors.white),
            ),
            const SizedBox(width: 12),
            const Text(
              'OVERCAST',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.5,
              ),
            ),
          ]),
          const SizedBox(height: 28),
          _nav(Icons.home_rounded, 'Home'),
          _nav(Icons.delete_outline_rounded, 'Trash'),
          const SizedBox(height: 14),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              'STORAGE',
              style: TextStyle(
                fontSize: 11,
                letterSpacing: 1.3,
                color: Colors.white38,
              ),
            ),
          ),
          const SizedBox(height: 10),
          if (storage != null) _storageCard(),
          const Spacer(),
          Container(
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              color: panel,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: border),
            ),
            child: Row(children: [
              Icon(
                connected ? Icons.cloud_done_rounded : Icons.cloud_off_rounded,
                size: 18,
                color: connected ? green : red,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  connected
                      ? 'Connected to Overcast'
                      : 'Not connected to Overcast',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 8),
          ListTile(
            leading: const Icon(Icons.settings_outlined),
            title: const Text('Settings'),
            dense: true,
            onTap: _settings,
          ),
        ]),
      );

  Widget _storageCard() {
    final s = storage!;
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: panel,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${_bytes(s.used)} used',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 9),
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: LinearProgressIndicator(
              minHeight: 7,
              value: s.fraction,
              backgroundColor: Colors.white10,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${_bytes(s.free)} free of ${_bytes(s.total)}',
            style: const TextStyle(fontSize: 11, color: Colors.white54),
          ),
        ],
      ),
    );
  }

  Widget _nav(IconData icon, String label) {
    final active = section == label;
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: ListTile(
        dense: true,
        selected: active,
        selectedTileColor: const Color(0x187AA2F7),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        leading: Icon(icon, size: 20),
        title: Text(label),
        onTap: () {
          setState(() {
            section = label;
            if (label == 'Home') path = 'home/';
            _selectedKeys.clear();
            _lastSelectedKey = null;
            _mobileSelectionMode = false;
          });
          refresh();
        },
      ),
    );
  }

  Widget _body(bool desktop) => Padding(
        padding: EdgeInsets.fromLTRB(desktop ? 8 : 14, 14, 14, 14),
        child: Column(children: [
          _topbar(),
          if (!desktop) _mobileNav(),
          const SizedBox(height: 14),
          if (_selectedKeys.isNotEmpty || _mobileSelectionMode)
            _selectionToolbar(),
          Expanded(child: _content()),
        ]),
      );

  Widget _topbar() => Row(children: [
        Expanded(
          child: TextField(
            controller: search,
            onChanged: (v) => setState(() => query = v),
            decoration: InputDecoration(
              hintText: 'Search your Overcast',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        search.clear();
                        setState(() => query = '');
                      },
                    ),
            ),
          ),
        ),
        const SizedBox(width: 9),
        ListenableBuilder(
          listenable: transferManager,
          builder: (_, __) {
            final activeCount = transferManager.activeCount;
            final totalCount = transferManager.tasks.length;
            return Badge(
              isLabelVisible: activeCount > 0 || totalCount > 0,
              backgroundColor: activeCount > 0 ? accent : panel2,
              label: Text(
                activeCount > 0 ? '$activeCount' : '$totalCount',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
              child: IconButton.filledTonal(
                onPressed: () {
                  setState(() {
                    if (!_transferPanelVisible) {
                      _transferPanelVisible = true;
                      _transferPanelMinimized = false;
                    } else if (_transferPanelMinimized) {
                      _transferPanelMinimized = false;
                    } else {
                      _transferPanelVisible = false;
                    }
                  });
                },
                tooltip: 'Transfers',
                icon: activeCount > 0
                    ? const Icon(Icons.swap_vert_circle_rounded, color: accent)
                    : const Icon(Icons.swap_vert_rounded),
              ),
            );
          },
        ),
        const SizedBox(width: 5),
        IconButton.filledTonal(
          onPressed: refresh,
          tooltip: 'Refresh',
          icon: const Icon(Icons.refresh_rounded),
        ),
        const SizedBox(width: 5),
        IconButton.filledTonal(
          onPressed: _settings,
          tooltip: 'Settings',
          icon: const Icon(Icons.settings_outlined),
        ),
      ]);

  Widget _selectionToolbar() {
    final count = _selectedKeys.length;
    final totalBytes = _selectedTotalBytes;
    final isTrash = section == 'Trash';

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: selectedPanel,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: accent.withValues(alpha: 0.55)),
      ),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 10,
        runSpacing: 8,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                onPressed: _clearSelection,
                tooltip: 'Clear selection (Esc)',
                icon: const Icon(Icons.close_rounded, size: 20),
                visualDensity: VisualDensity.compact,
              ),
              const SizedBox(width: 6),
              Text(
                '$count selected',
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                ),
              ),
              if (!isTrash && totalBytes > 0) ...[
                const SizedBox(width: 8),
                Text(
                  '(${_bytes(totalBytes)})',
                  style: const TextStyle(color: Colors.white60, fontSize: 12),
                ),
              ],
            ],
          ),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              TextButton.icon(
                onPressed: _selectAll,
                icon: const Icon(Icons.select_all_rounded, size: 18),
                label: const Text('Select all'),
              ),
              if (!isTrash)
                FilledButton.tonalIcon(
                  onPressed: count > 0 ? _bulkDownloadSelected : null,
                  icon: const Icon(Icons.download_rounded, size: 18),
                  label: Text(
                    count > 1 || _selectedFolderNames.isNotEmpty
                        ? 'Download ZIP'
                        : 'Download',
                  ),
                ),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: red.withValues(alpha: 0.85),
                  foregroundColor: Colors.white,
                ),
                onPressed: count > 0 ? _bulkDeleteSelected : null,
                icon: const Icon(Icons.delete_outline_rounded, size: 18),
                label: Text(isTrash ? 'Delete permanently' : 'Delete'),
              ),
              OutlinedButton(
                onPressed: _clearSelection,
                child: const Text('Clear'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _mobileNav() => Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Row(children: [
          Expanded(child: _mobileButton(Icons.home_rounded, 'Home')),
          const SizedBox(width: 8),
          Expanded(child: _mobileButton(Icons.delete_outline_rounded, 'Trash')),
        ]),
      );

  Widget _mobileButton(IconData icon, String label) => OutlinedButton.icon(
        onPressed: () {
          setState(() {
            section = label;
            if (label == 'Home') path = 'home/';
            _selectedKeys.clear();
            _lastSelectedKey = null;
            _mobileSelectionMode = false;
          });
          refresh();
        },
        icon: Icon(icon),
        label: Text(label),
      );

  Widget _content() {
    if (loading) return const Center(child: CircularProgressIndicator());
    if (!connected) return _offline();
    if (section == 'Trash') return _trashView();
    return _homeView();
  }

  Widget _homeView() {
    final folders = childFolders;
    final files = filtered;
    final totalCount = folders.length + files.length;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: _breadcrumbs()),
        PopupMenuButton<String>(
          onSelected: (v) {
            if (v == 'file') _pickUploads();
            if (v == 'folder') _pickFolderUpload();
            if (v == 'text') _newText();
            if (v == 'newfolder') _createFolder();
          },
          itemBuilder: (_) => const [
            PopupMenuItem(
              value: 'file',
              child: ListTile(
                leading: Icon(Icons.upload_file_rounded),
                title: Text('Upload files'),
              ),
            ),
            PopupMenuItem(
              value: 'folder',
              child: ListTile(
                leading: Icon(Icons.drive_folder_upload_rounded),
                title: Text('Upload folder'),
              ),
            ),
            PopupMenuItem(
              value: 'newfolder',
              child: ListTile(
                leading: Icon(Icons.create_new_folder_rounded),
                title: Text('New folder'),
              ),
            ),
            PopupMenuItem(
              value: 'text',
              child: ListTile(
                leading: Icon(Icons.note_add_outlined),
                title: Text('New text file'),
              ),
            ),
          ],
          child: FilledButton.icon(
            onPressed: null,
            icon: const Icon(Icons.add_rounded),
            label: const Text('New'),
          ),
        ),
      ]),
      const SizedBox(height: 14),
      Row(children: [
        Text(
          '$totalCount item${totalCount == 1 ? '' : 's'}',
          style: const TextStyle(color: Colors.white54),
        ),
        const SizedBox(width: 12),
        if (!_isMobilePlatform && totalCount > 0)
          const Text(
            'Tip: Ctrl+Click, Shift+Click, or drag to select multiple',
            style: TextStyle(fontSize: 11, color: Colors.white30),
          ),
        const Spacer(),
        if (totalCount > 0)
          IconButton(
            onPressed: () {
              if (_selectedKeys.length == totalCount) {
                _clearSelection();
              } else {
                _selectAll();
              }
            },
            tooltip: _selectedKeys.length == totalCount
                ? 'Deselect all'
                : 'Select all (Ctrl+A)',
            icon: Icon(
              _selectedKeys.length == totalCount && totalCount > 0
                  ? Icons.deselect_rounded
                  : Icons.select_all_rounded,
              color: _selectedKeys.isNotEmpty ? accent : Colors.white54,
            ),
          ),
        IconButton(
          onPressed: () {
            setState(() => grid = true);
            prefs?.setBool('grid', true);
          },
          tooltip: 'Grid view',
          icon: Icon(
            Icons.grid_view_rounded,
            color: grid ? accent : Colors.white54,
          ),
        ),
        IconButton(
          onPressed: () {
            setState(() => grid = false);
            prefs?.setBool('grid', false);
          },
          tooltip: 'List view',
          icon: Icon(
            Icons.view_list_rounded,
            color: !grid ? accent : Colors.white54,
          ),
        ),
      ]),
      const SizedBox(height: 8),
      Expanded(child: _itemsView(files, folders)),
    ]);
  }

  Widget _breadcrumbs() {
    final crumbs = _crumbs();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: [
        TextButton(
          onPressed: () => _navigateTo('home/'),
          child: const Text('Home'),
        ),
        for (var i = 1; i < crumbs.length; i++) ...[
          const Icon(
            Icons.chevron_right_rounded,
            size: 18,
            color: Colors.white38,
          ),
          TextButton(
            onPressed: () =>
                _navigateTo('${crumbs.take(i + 1).join('/')}/'),
            child: Text(crumbs[i]),
          ),
        ],
      ]),
    );
  }

  Widget _itemsView(List<OvercastFile> data, List<String> folders) {
    if (data.isEmpty && folders.isEmpty) return _empty();

    final listOrGrid = !grid
        ? ListView.separated(
            itemCount: folders.length + data.length,
            separatorBuilder: (_, __) => const SizedBox(height: 7),
            itemBuilder: (_, i) {
              if (i < folders.length) return _folderListCard(folders[i]);
              return _listCard(data[i - folders.length]);
            },
          )
        : GridView.builder(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 230,
              mainAxisExtent: 182,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
            ),
            itemCount: folders.length + data.length,
            itemBuilder: (_, i) {
              if (i < folders.length) return _folderGridCard(folders[i]);
              return _gridCard(data[i - folders.length]);
            },
          );

    final dragRect = _currentDragRect;

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () {
        if (!_isMobilePlatform && _selectedKeys.isNotEmpty) {
          _clearSelection();
        }
      },
      onPanStart: _isMobilePlatform
          ? null
          : (details) => _onDragSelectionStart(details.localPosition),
      onPanUpdate: _isMobilePlatform
          ? null
          : (details) => _onDragSelectionUpdate(details.localPosition),
      onPanEnd: _isMobilePlatform ? null : (_) => _onDragSelectionEnd(),
      onPanCancel: _isMobilePlatform ? null : _onDragSelectionEnd,
      child: Container(
        key: _listingAreaKey,
        child: Stack(
          children: [
            Positioned.fill(child: listOrGrid),
            if (dragRect != null)
              Positioned(
                left: dragRect.left,
                top: dragRect.top,
                width: math.max(0, dragRect.width),
                height: math.max(0, dragRect.height),
                child: IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.16),
                      border: Border.all(color: accent, width: 1.5),
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _selectionIndicator(String itemKey, bool isSelected) {
    final visible = isSelected || _inSelectionMode || !_isMobilePlatform;
    if (!visible) return const SizedBox.shrink();

    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => _toggleCheckboxSelection(itemKey),
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Icon(
          isSelected
              ? Icons.check_circle_rounded
              : Icons.radio_button_unchecked_rounded,
          size: 20,
          color: isSelected ? accent : Colors.white38,
        ),
      ),
    );
  }

  Widget _folderGridCard(String name) {
    final itemKey = 'folder:$name';
    final isSelected = _selectedKeys.contains(itemKey);

    return Card(
      key: _keyForItem(itemKey),
      color: isSelected ? selectedPanel : panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: isSelected ? accent : border,
          width: isSelected ? 1.8 : 1.0,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _handleItemTap(
          itemKey,
          onSingleOpen: () => _navigateTo('$path$name/'),
        ),
        onDoubleTap: _isMobilePlatform
            ? null
            : () => _navigateTo('$path$name/'),
        onLongPress: () => _handleItemLongPress(itemKey),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _selectionIndicator(itemKey, isSelected),
                  IconButton(
                    onPressed: () => _showFolderActions(name),
                    icon: const Icon(Icons.more_horiz_rounded, size: 19),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
              const Expanded(
                child: Center(
                  child: Icon(Icons.folder_rounded, size: 58, color: accent),
                ),
              ),
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const Text(
                'Folder',
                style: TextStyle(fontSize: 11, color: Colors.white54),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _folderListCard(String name) {
    final itemKey = 'folder:$name';
    final isSelected = _selectedKeys.contains(itemKey);

    return Card(
      key: _keyForItem(itemKey),
      color: isSelected ? selectedPanel : panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: isSelected ? accent : border,
          width: isSelected ? 1.8 : 1.0,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _handleItemTap(
          itemKey,
          onSingleOpen: () => _navigateTo('$path$name/'),
        ),
        onDoubleTap:
            _isMobilePlatform ? null : () => _navigateTo('$path$name/'),
        onLongPress: () => _handleItemLongPress(itemKey),
        child: ListTile(
          leading: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _selectionIndicator(itemKey, isSelected),
              const SizedBox(width: 8),
              const Icon(Icons.folder_rounded, color: accent, size: 32),
            ],
          ),
          title: Text(name, style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle:
              const Text('Folder', style: TextStyle(color: Colors.white54)),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!_isMobilePlatform)
                IconButton(
                  tooltip: 'Open folder',
                  onPressed: () => _navigateTo('$path$name/'),
                  icon: const Icon(Icons.folder_open_rounded, size: 19),
                ),
              IconButton(
                onPressed: () => _showFolderActions(name),
                icon: const Icon(Icons.more_horiz_rounded),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _gridCard(OvercastFile f) {
    final itemKey = 'file:${f.id}';
    final isSelected = _selectedKeys.contains(itemKey);

    return Card(
      key: _keyForItem(itemKey),
      color: isSelected ? selectedPanel : panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: isSelected ? accent : border,
          width: isSelected ? 1.8 : 1.0,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _handleItemTap(
          itemKey,
          onSingleOpen: () => _open(f),
        ),
        onDoubleTap: _isMobilePlatform ? null : () => _open(f),
        onLongPress: () => _handleItemLongPress(itemKey),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _selectionIndicator(itemKey, isSelected),
                  IconButton(
                    onPressed: () => _showActions(f),
                    icon: const Icon(Icons.more_horiz_rounded, size: 19),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
              Expanded(child: Center(child: _fileIcon(f, 50))),
              Text(
                f.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              Text(
                '${_bytes(f.size)} • ${f.extension.toUpperCase()}',
                style: const TextStyle(fontSize: 11, color: Colors.white54),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _listCard(OvercastFile f) {
    final itemKey = 'file:${f.id}';
    final isSelected = _selectedKeys.contains(itemKey);

    return Card(
      key: _keyForItem(itemKey),
      color: isSelected ? selectedPanel : panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: isSelected ? accent : border,
          width: isSelected ? 1.8 : 1.0,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _handleItemTap(
          itemKey,
          onSingleOpen: () => _open(f),
        ),
        onDoubleTap: _isMobilePlatform ? null : () => _open(f),
        onLongPress: () => _handleItemLongPress(itemKey),
        child: ListTile(
          leading: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _selectionIndicator(itemKey, isSelected),
              const SizedBox(width: 8),
              _fileIcon(f, 30),
            ],
          ),
          title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${_bytes(f.size)} • ${f.lastEdited ?? ''}',
            style: const TextStyle(color: Colors.white54),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!_isMobilePlatform)
                IconButton(
                  tooltip: 'Open',
                  onPressed: () => _open(f),
                  icon: const Icon(Icons.open_in_new_rounded, size: 19),
                ),
              PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'open') {
                    _open(f);
                  } else if (v == 'download') {
                    _download(f);
                  } else if (v == 'select') {
                    _toggleCheckboxSelection(itemKey);
                  } else if (v == 'rename') {
                    _rename(f);
                  } else if (v == 'move') {
                    _move(f);
                  } else if (v == 'trash') {
                    _trash(f);
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'open', child: Text('Open')),
                  PopupMenuItem(value: 'download', child: Text('Download')),
                  PopupMenuItem(value: 'select', child: Text('Select')),
                  PopupMenuItem(value: 'rename', child: Text('Rename')),
                  PopupMenuItem(value: 'move', child: Text('Move')),
                  PopupMenuItem(value: 'trash', child: Text('Move to Trash')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _fileIcon(OvercastFile f, double size) {
    final color = f.isImage
        ? const Color(0xFF69C5FF)
        : f.isVideo
            ? const Color(0xFFC49BFF)
            : f.isAudio
                ? const Color(0xFFFFB86B)
                : f.isText
                    ? const Color(0xFF78D7A5)
                    : f.isPdf
                        ? red
                        : accent;
    final icon = f.isImage
        ? Icons.image_rounded
        : f.isVideo
            ? Icons.movie_rounded
            : f.isAudio
                ? Icons.audio_file_rounded
                : f.isText
                    ? Icons.description_rounded
                    : f.isPdf
                        ? Icons.picture_as_pdf_rounded
                        : Icons.insert_drive_file_rounded;
    return Container(
      width: size + 22,
      height: size + 22,
      decoration: BoxDecoration(
        color: color.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Icon(icon, size: size, color: color),
    );
  }

  Widget _trashView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              'Trash',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
            ),
            const Spacer(),
            if (trash.isNotEmpty)
              TextButton.icon(
                onPressed: () {
                  if (_selectedKeys.length == trash.length) {
                    _clearSelection();
                  } else {
                    _selectAll();
                  }
                },
                icon: const Icon(Icons.select_all_rounded, size: 18),
                label: Text(
                  _selectedKeys.length == trash.length
                      ? 'Deselect all'
                      : 'Select all',
                ),
              ),
          ],
        ),
        const SizedBox(height: 5),
        Text(
          '${trash.length} item${trash.length == 1 ? '' : 's'}',
          style: const TextStyle(color: Colors.white54),
        ),
        const SizedBox(height: 18),
        Expanded(
          child: trash.isEmpty
              ? _empty(trash: true)
              : ListView.separated(
                  itemCount: trash.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 7),
                  itemBuilder: (_, i) {
                    final f = trash[i];
                    final itemKey = 'trash:${f.id}';
                    final isSelected = _selectedKeys.contains(itemKey);
                    return Card(
                      key: _keyForItem(itemKey),
                      color: isSelected ? selectedPanel : panel,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: BorderSide(
                          color: isSelected ? accent : border,
                          width: isSelected ? 1.8 : 1.0,
                        ),
                      ),
                      child: ListTile(
                        onTap: () => _toggleCheckboxSelection(itemKey),
                        onLongPress: () => _handleItemLongPress(itemKey),
                        leading: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _selectionIndicator(itemKey, isSelected),
                            const SizedBox(width: 8),
                            _fileIcon(f, 30),
                          ],
                        ),
                        title: Text(f.name),
                        subtitle: Text(
                          'Originally in ${f.lastLocation}',
                          style: const TextStyle(color: Colors.white54),
                        ),
                        trailing: Wrap(
                          children: [
                            IconButton(
                              tooltip: 'Restore',
                              onPressed: () => _restore(f),
                              icon: const Icon(
                                Icons.restore_rounded,
                                color: green,
                              ),
                            ),
                            IconButton(
                              tooltip: 'Delete permanently',
                              onPressed: () => _permanentDelete(f),
                              icon: const Icon(
                                Icons.delete_forever_rounded,
                                color: red,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  // --- Background Transfer Manager Floating Overlay ---

  Widget _buildFloatingTransferOverlay(bool desktop) {
    return ListenableBuilder(
      listenable: transferManager,
      builder: (_, __) {
        final tasks = transferManager.tasks;
        final activeCount = transferManager.activeCount;

        if (!_transferPanelVisible || tasks.isEmpty) {
          return const SizedBox.shrink();
        }

        if (_transferPanelMinimized) {
          return Positioned(
            right: 18,
            bottom: 18,
            child: Material(
              color: panel2,
              elevation: 8,
              borderRadius: BorderRadius.circular(24),
              child: InkWell(
                borderRadius: BorderRadius.circular(24),
                onTap: () => setState(() => _transferPanelMinimized = false),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: accent.withValues(alpha: 0.6)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (activeCount > 0)
                        SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.2,
                            value: transferManager.aggregateProgress > 0
                                ? transferManager.aggregateProgress
                                : null,
                          ),
                        )
                      else
                        const Icon(
                          Icons.check_circle_rounded,
                          color: green,
                          size: 18,
                        ),
                      const SizedBox(width: 10),
                      Text(
                        activeCount > 0
                            ? '$activeCount active transfer${activeCount == 1 ? '' : 's'} '
                                '(${(transferManager.aggregateProgress * 100).round()}%)'
                            : '${tasks.length} transfer${tasks.length == 1 ? '' : 's'}',
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Icon(Icons.open_in_full_rounded, size: 16),
                    ],
                  ),
                ),
              ),
            ),
          );
        }

        final width = desktop ? 440.0 : math.min(MediaQuery.of(context).size.width - 24, 420.0);

        return Positioned(
          right: 12,
          bottom: 12,
          width: width,
          child: Material(
            color: const Color(0xFF0A1120),
            elevation: 14,
            borderRadius: BorderRadius.circular(20),
            child: Container(
              constraints: const BoxConstraints(maxHeight: 380),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: accent.withValues(alpha: 0.45)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                    decoration: const BoxDecoration(
                      color: panel2,
                      borderRadius: BorderRadius.vertical(
                        top: Radius.circular(20),
                      ),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.swap_vert_circle_rounded,
                          color: accent,
                          size: 20,
                        ),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Text(
                            activeCount > 0
                                ? 'Transfers ($activeCount active)'
                                : 'Transfers (${tasks.length})',
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 14,
                            ),
                          ),
                        ),
                        if (tasks.any((t) => !t.isActive))
                          TextButton(
                            onPressed: transferManager.clearFinished,
                            child: const Text(
                              'Clear done',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                        IconButton(
                          tooltip: 'Minimize',
                          visualDensity: VisualDensity.compact,
                          onPressed: () =>
                              setState(() => _transferPanelMinimized = true),
                          icon: const Icon(Icons.minimize_rounded, size: 18),
                        ),
                        IconButton(
                          tooltip: 'Hide panel (transfers continue)',
                          visualDensity: VisualDensity.compact,
                          onPressed: () =>
                              setState(() => _transferPanelVisible = false),
                          icon: const Icon(Icons.close_rounded, size: 18),
                        ),
                      ],
                    ),
                  ),
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      padding: const EdgeInsets.all(10),
                      itemCount: tasks.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (_, idx) => _buildTransferItemTile(tasks[idx]),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildTransferItemTile(TransferTask task) {
    final isUpload = task.type == TransferType.upload;
    final pct = (task.progress * 100).clamp(0, 100).round();

    Color statusColor = accent;
    if (task.state == TransferState.completed) {
      statusColor = green;
    } else if (task.state == TransferState.failed ||
        task.state == TransferState.cancelled) {
      statusColor = red;
    }

    final subtitleParts = <String>[
      task.stateLabel,
      if (task.totalBytes > 0)
        '${_bytes(task.transferredBytes)} / ${_bytes(task.totalBytes)}'
      else if (task.transferredBytes > 0)
        _bytes(task.transferredBytes),
      if (task.isActive && task.speedBytesPerSec > 0)
        '${_bytes(task.speedBytesPerSec.round())}/s',
      if (task.isActive && task.etaSeconds != null && task.etaSeconds! > 0)
        'ETA ${_formatEta(task.etaSeconds!)}',
    ];

    return Container(
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: panel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isUpload
                    ? Icons.cloud_upload_rounded
                    : task.type == TransferType.bulkDownload
                        ? Icons.folder_zip_rounded
                        : Icons.cloud_download_rounded,
                size: 19,
                color: statusColor,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  task.fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
              ),
              Text(
                '$pct%',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: statusColor,
                ),
              ),
              const SizedBox(width: 4),
              if (task.canCancel)
                IconButton(
                  tooltip: 'Cancel transfer',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  onPressed: () => transferManager.cancelTransfer(task.id),
                  icon: const Icon(Icons.cancel_outlined, size: 18, color: red),
                ),
              if (task.canRetry)
                IconButton(
                  tooltip: 'Retry transfer',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  onPressed: () => transferManager.retryTransfer(task.id),
                  icon: const Icon(
                    Icons.refresh_rounded,
                    size: 18,
                    color: accent,
                  ),
                ),
              if (task.state == TransferState.completed &&
                  task.localTargetPath != null)
                IconButton(
                  tooltip: 'Open downloaded file',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  onPressed: () => _openPath(task.localTargetPath!),
                  icon: const Icon(
                    Icons.open_in_new_rounded,
                    size: 17,
                    color: green,
                  ),
                ),
              if (!task.isActive)
                IconButton(
                  tooltip: 'Remove from list',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  onPressed: () => transferManager.removeTask(task.id),
                  icon: const Icon(
                    Icons.close_rounded,
                    size: 16,
                    color: Colors.white38,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              minHeight: 5,
              value: task.state == TransferState.preparing ||
                      task.state == TransferState.finalizing
                  ? null
                  : task.progress,
              color: statusColor,
              backgroundColor: Colors.white10,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitleParts.join(' • '),
            style: const TextStyle(fontSize: 11, color: Colors.white60),
          ),
          if (task.errorMessage != null && task.errorMessage!.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              task.errorMessage!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: red),
            ),
          ],
        ],
      ),
    );
  }

  String _formatEta(int seconds) {
    if (seconds < 60) return '${seconds}s';
    final mins = seconds ~/ 60;
    final secs = seconds % 60;
    if (mins < 60) return '${mins}m ${secs}s';
    final hrs = mins ~/ 60;
    final remMins = mins % 60;
    return '${hrs}h ${remMins}m';
  }

  Widget _empty({bool trash = false}) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              trash ? Icons.delete_sweep_rounded : Icons.cloud_queue_rounded,
              size: 76,
              color: Colors.white12,
            ),
            const SizedBox(height: 16),
            Text(
              trash ? 'Trash is empty' : 'Nothing here yet',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 7),
            Text(
              trash
                  ? 'Deleted files will appear here.'
                  : 'Upload something to get started.',
              style: const TextStyle(color: Colors.white54),
            ),
          ],
        ),
      );

  Widget _offline() => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.cloud_off_rounded,
              size: 82,
              color: Colors.white12,
            ),
            const SizedBox(height: 18),
            const Text(
              'Not connected to Overcast',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 7),
            Text(server, style: const TextStyle(color: Colors.white38)),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: refresh,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Try again'),
            ),
          ],
        ),
      );

  String _bytes(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    if (n < 1024 * 1024 * 1024) return '${(n / 1048576).toStringAsFixed(1)} MB';
    return '${(n / 1073741824).toStringAsFixed(2)} GB';
  }
}

class TextEditorPage extends StatefulWidget {
  final OvercastApi api;
  final OvercastFile file;
  final String initial;
  const TextEditorPage({
    super.key,
    required this.api,
    required this.file,
    required this.initial,
  });
  @override
  State<TextEditorPage> createState() => _TextEditorPageState();
}

class _TextEditorPageState extends State<TextEditorPage> {
  late final TextEditingController controller =
      TextEditingController(text: widget.initial);
  bool saving = false;
  bool dirty = false;
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> save() async {
    setState(() => saving = true);
    try {
      await widget.api.saveText(widget.file.id, controller.text);
      if (mounted) {
        setState(() {
          saving = false;
          dirty = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(widget.api.errorMessage(e))),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Text(widget.file.name),
          actions: [
            if (dirty)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Center(
                  child: Text(
                    'Unsaved',
                    style: TextStyle(color: Colors.orange),
                  ),
                ),
              ),
            IconButton(
              onPressed: saving ? null : save,
              icon: saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_rounded),
            ),
          ],
        ),
        body: Padding(
          padding: const EdgeInsets.all(18),
          child: TextField(
            controller: controller,
            expands: true,
            maxLines: null,
            minLines: null,
            onChanged: (_) => setState(() => dirty = true),
            textAlignVertical: TextAlignVertical.top,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
            decoration: const InputDecoration(hintText: 'Start typing…'),
          ),
        ),
      );
}

class PreviewDialog extends StatefulWidget {
  final OvercastApi api;
  final OvercastFile file;
  const PreviewDialog({super.key, required this.api, required this.file});
  @override
  State<PreviewDialog> createState() => _PreviewDialogState();
}

class _PreviewDialogState extends State<PreviewDialog> {
  VideoPlayerController? video;
  AudioPlayer? audio;
  bool audioPlaying = false;
  bool isMuted = false;
  double playbackSpeed = 1.0;
  bool _isScrubbing = false;
  double _scrubMs = 0.0;
  Duration? _nativeDurationOverride;
  bool _pollingNativeDuration = false;
  String? error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  void _onVideoUpdate() {
    if (!mounted) return;
    final v = video;
    if (v != null && v.value.hasError && error == null) {
      setState(() {
        error = v.value.errorDescription ?? 'Video playback failed';
      });
      return;
    }
    if (v != null &&
        Platform.isLinux &&
        v.value.isInitialized &&
        (_nativeDurationOverride == null ||
            _nativeDurationOverride!.inMilliseconds <= 0) &&
        v.value.duration.inMilliseconds <= 0 &&
        !_pollingNativeDuration) {
      _pollingNativeDuration = true;
      OvercastDesktopVideoPlayerPlatform.queryNativeDuration().then((dur) {
        _pollingNativeDuration = false;
        if (mounted && dur != null && dur.inMilliseconds > 0) {
          setState(() => _nativeDurationOverride = dur);
        }
      });
    }
    setState(() {});
  }

  Duration _effectiveDuration(VideoPlayerController v) {
    if (v.value.duration.inMilliseconds > 0) {
      return v.value.duration;
    }
    if (_nativeDurationOverride != null &&
        _nativeDurationOverride!.inMilliseconds > 0) {
      return _nativeDurationOverride!;
    }
    if (v.value.buffered.isNotEmpty) {
      final end = v.value.buffered.last.end;
      if (end.inMilliseconds > 0) return end;
    }
    return Duration.zero;
  }

  Future<void> _seekVideoTo(VideoPlayerController v, Duration target) async {
    final dur = _effectiveDuration(v);
    Duration clamped = target < Duration.zero ? Duration.zero : target;
    if (dur.inMilliseconds > 0 && clamped > dur) {
      clamped = dur;
    }
    if (Platform.isLinux && v.value.duration.inMilliseconds <= 0) {
      await OvercastDesktopVideoPlayerPlatform.seekNative(clamped);
    } else {
      await v.seekTo(clamped);
    }
  }

  Future<void> _init() async {
    try {
      if (widget.file.isVideo) {
        final v = VideoPlayerController.networkUrl(
          Uri.parse(widget.api.streamUrl(widget.file.id)),
        );
        video = v;
        v.addListener(_onVideoUpdate);
        await v.initialize();
        await v.play();
        if (mounted) setState(() {});
      } else if (widget.file.isAudio) {
        final a = AudioPlayer();
        await a.play(UrlSource(widget.api.streamUrl(widget.file.id)));
        if (mounted) {
          setState(() {
            audio = a;
            audioPlaying = true;
          });
        }
      }
    } catch (e) {
      if (mounted) setState(() => error = widget.api.errorMessage(e));
    }
  }

  String _formatDuration(Duration d) {
    final totalSeconds = d.inSeconds < 0 ? 0 : d.inSeconds;
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    final mm = minutes.toString().padLeft(2, '0');
    final ss = seconds.toString().padLeft(2, '0');
    if (hours > 0) {
      return '$hours:$mm:$ss';
    }
    return '$mm:$ss';
  }

  Future<void> _openExternalVideoPlayer() async {
    final streamUrl = widget.api.streamUrl(widget.file.id);
    await video?.pause();
    await OvercastDesktopVideoPlayerPlatform.openInExternalPlayer(streamUrl);
  }

  @override
  void dispose() {
    video?.removeListener(_onVideoUpdate);
    video?.dispose();
    audio?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog(
        backgroundColor: panel,
        insetPadding: const EdgeInsets.all(22),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1000, maxHeight: 760),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.file.name,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 18,
                        ),
                      ),
                    ),
                    if (widget.file.isVideo &&
                        (Platform.isLinux || Platform.isWindows))
                      TextButton.icon(
                        onPressed: _openExternalVideoPlayer,
                        icon: const Icon(Icons.open_in_new_rounded, size: 18),
                        label: const Text('External Player'),
                      ),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(child: _body()),
              ],
            ),
          ),
        ),
      );

  Widget _body() {
    if (error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline_rounded, size: 54, color: red),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
            ),
            if (widget.file.isVideo) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _openExternalVideoPlayer,
                icon: const Icon(Icons.play_lesson_rounded),
                label: const Text('Open in System Media Player (VLC / Default)'),
              ),
            ],
          ],
        ),
      );
    }
    if (widget.file.isImage) {
      return InteractiveViewer(
        child: Image.network(
          widget.api.previewUrl(widget.file.id),
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) =>
              const Center(child: Text('Preview unavailable')),
        ),
      );
    }
    if (widget.file.isVideo) {
      final v = video;
      if (v == null || !v.value.isInitialized) {
        return const Center(child: CircularProgressIndicator());
      }
      final dur = _effectiveDuration(v);
      final rawPos = v.value.position;
      final maxMs = math.max(dur.inMilliseconds.toDouble(), 1.0);
      final currentMs = _isScrubbing
          ? _scrubMs.clamp(0.0, maxMs)
          : rawPos.inMilliseconds.toDouble().clamp(0.0, maxMs);
      final displayPos = Duration(milliseconds: currentMs.round());

      return Column(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: () {
                v.value.isPlaying ? v.pause() : v.play();
              },
              child: Container(
                color: Colors.black,
                alignment: Alignment.center,
                child: AspectRatio(
                  aspectRatio: v.value.aspectRatio > 0
                      ? v.value.aspectRatio
                      : (16 / 9),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      VideoPlayer(v),
                      if (v.value.isBuffering)
                        const CircularProgressIndicator(),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 5,
              activeTrackColor: accent,
              inactiveTrackColor: Colors.white24,
              thumbColor: accent,
              overlayColor: accent.withValues(alpha: 0.2),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            ),
            child: Slider(
              min: 0.0,
              max: maxMs,
              value: currentMs,
              onChangeStart: (val) {
                setState(() {
                  _isScrubbing = true;
                  _scrubMs = val;
                });
              },
              onChanged: dur.inMilliseconds > 0
                  ? (val) {
                      setState(() {
                        _isScrubbing = true;
                        _scrubMs = val;
                      });
                    }
                  : null,
              onChangeEnd: (val) async {
                final target = Duration(milliseconds: val.round());
                setState(() {
                  _isScrubbing = false;
                });
                await _seekVideoTo(v, target);
              },
            ),
          ),
          Row(
            children: [
              IconButton(
                tooltip: 'Rewind 10s',
                onPressed: () {
                  final target = displayPos - const Duration(seconds: 10);
                  _seekVideoTo(v, target);
                },
                icon: const Icon(Icons.replay_10_rounded),
              ),
              IconButton(
                tooltip: v.value.isPlaying ? 'Pause' : 'Play',
                onPressed: () {
                  v.value.isPlaying ? v.pause() : v.play();
                },
                icon: Icon(
                  v.value.isPlaying
                      ? Icons.pause_circle_filled
                      : Icons.play_circle_fill,
                  size: 42,
                  color: accent,
                ),
              ),
              IconButton(
                tooltip: 'Forward 10s',
                onPressed: () {
                  final target = displayPos + const Duration(seconds: 10);
                  _seekVideoTo(v, target);
                },
                icon: const Icon(Icons.forward_10_rounded),
              ),
              const SizedBox(width: 8),
              Text(
                '${_formatDuration(displayPos)} / ${_formatDuration(dur)}',
                style: const TextStyle(
                  fontSize: 13,
                  color: Colors.white70,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: isMuted ? 'Unmute' : 'Mute',
                onPressed: () {
                  setState(() => isMuted = !isMuted);
                  v.setVolume(isMuted ? 0.0 : 1.0);
                },
                icon: Icon(
                  isMuted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                ),
              ),
              PopupMenuButton<double>(
                tooltip: 'Playback Speed',
                initialValue: playbackSpeed,
                onSelected: (spd) {
                  setState(() => playbackSpeed = spd);
                  v.setPlaybackSpeed(spd);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 0.5, child: Text('0.5x')),
                  PopupMenuItem(value: 1.0, child: Text('1.0x')),
                  PopupMenuItem(value: 1.25, child: Text('1.25x')),
                  PopupMenuItem(value: 1.5, child: Text('1.5x')),
                  PopupMenuItem(value: 2.0, child: Text('2.0x')),
                ],
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Text(
                    '${playbackSpeed}x',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      color: Colors.white70,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      );
    }
    if (widget.file.isAudio) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.audio_file_rounded, size: 100, color: accent),
            const SizedBox(height: 16),
            Text(
              widget.file.name,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 16),
            IconButton(
              onPressed: () async {
                if (audio == null) return;
                if (audioPlaying) {
                  await audio!.pause();
                } else {
                  await audio!.resume();
                }
                setState(() => audioPlaying = !audioPlaying);
              },
              icon: Icon(
                audioPlaying
                    ? Icons.pause_circle_filled
                    : Icons.play_circle_fill,
                size: 58,
              ),
            ),
          ],
        ),
      );
    }
    return const Center(child: Text('No preview available.'));
  }
}
