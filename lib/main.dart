import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:clipboard/clipboard.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Clipboard File Monitor',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const MyHomePage(),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({Key? key}) : super(key: key);

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  String? rootFolder;
  bool monitorClipboard = false;
  Timer? _clipboardTimer;
  String? _lastClipboardContent;
  String _clipboardPreview = '';
  bool _recentlyModified = false;
  Timer? _modificationIndicatorTimer;

  static const String _rootFolderKey = 'root_folder';

  // Map from filename to list of all matching relative paths
  Map<String, List<String>> _duplicateFilePaths = {};
  // Map from filename to set of selected relative paths
  Map<String, Set<String>> _selectedFilePaths = {};
  // Map from filename to last found matches (for chips UI)
  Map<String, List<String>> _lastFileMatches = {};

  @override
  void initState() {
    super.initState();
    _loadSavedRootFolder();
  }

  Future<void> _loadSavedRootFolder() async {
    final prefs = await SharedPreferences.getInstance();
    final savedFolder = prefs.getString(_rootFolderKey);
    if (savedFolder != null) {
      setState(() {
        rootFolder = savedFolder;
      });
    }
  }

  @override
  void dispose() {
    _clipboardTimer?.cancel();
    _modificationIndicatorTimer?.cancel();
    super.dispose();
  }

  void _selectRootFolder() async {
    String? selectedDirectory = await FilePicker.platform.getDirectoryPath();
    if (selectedDirectory != null) {
      // Save to shared preferences
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_rootFolderKey, selectedDirectory);

      setState(() {
        rootFolder = selectedDirectory;
      });
    }
  }

  void _toggleClipboardMonitoring(bool value) {
    setState(() {
      monitorClipboard = value;
    });

    if (monitorClipboard) {
      _startMonitoring();
    } else {
      _stopMonitoring();
    }
  }

  void _startMonitoring() {
    if (rootFolder == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a root folder first')),
      );
      setState(() {
        monitorClipboard = false;
      });
      return;
    }

    // Initial clipboard check
    _updateClipboardPreview();

    // Check clipboard every second
    _clipboardTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _checkClipboard();
    });
  }

  void _stopMonitoring() {
    _clipboardTimer?.cancel();
    _clipboardTimer = null;
  }

  Future<void> _updateClipboardPreview() async {
    final clipboardContent = await FlutterClipboard.paste();
    setState(() {
      _clipboardPreview = clipboardContent;
    });
  }

  void _showModificationIndicator() {
    setState(() {
      _recentlyModified = true;
    });

    _modificationIndicatorTimer?.cancel();
    _modificationIndicatorTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() {
          _recentlyModified = false;
        });
      }
    });
  }

  String? _lastModifiedContent;

  Future<void> _checkClipboard() async {
    final clipboardContent = await FlutterClipboard.paste();
    if (_clipboardPreview != clipboardContent) {
      setState(() {
        _clipboardPreview = clipboardContent;
      });
    }
    if (clipboardContent.isEmpty || clipboardContent == _lastModifiedContent) return;
    if (clipboardContent == _lastClipboardContent) return;
    _lastClipboardContent = clipboardContent;
    final regex = RegExp(r'@([^\s]+)');
    final matches = regex.allMatches(clipboardContent);
    if (matches.isEmpty) return;

    _duplicateFilePaths.clear();
    _lastFileMatches.clear();
    _selectedFilePaths.clear();

    String modifiedContent = clipboardContent;
    bool anyFileFound = false;

    for (final match in matches) {
      final fileName = match.group(1);
      if (fileName != null) {
        final fileInfos = await _findAndReadAllFiles(fileName);
        if (fileInfos.isNotEmpty) {
          anyFileFound = true;
          // Save for chips UI
          _lastFileMatches[fileName] = fileInfos.map((e) => e.$2).toList();
          if (fileInfos.length > 1) {
            _duplicateFilePaths[fileName] = fileInfos.map((e) => e.$2).toList();
            // Select first by default
            _selectedFilePaths[fileName] = {fileInfos.first.$2};
          } else {
            _selectedFilePaths[fileName] = {fileInfos.first.$2};
          }
        }
      }
    }

    // Compose preview from selected files
    for (final fileName in _selectedFilePaths.keys) {
      final selectedPaths = _selectedFilePaths[fileName]!;
      final fileInfos = await _findAndReadAllFiles(fileName);
      for (final (content, relativePath) in fileInfos) {
        if (selectedPaths.contains(relativePath)) {
          final extension = path.extension(fileName).replaceAll('.', '');
          final language = extension.isNotEmpty ? extension : 'text';
          modifiedContent += '\n\n**File: $relativePath**\n```$language\n$content\n```';
        }
      }
    }

    if (anyFileFound) {
      _lastModifiedContent = modifiedContent;
      await FlutterClipboard.copy(modifiedContent);
      setState(() {
        _clipboardPreview = modifiedContent;
      });
      _showModificationIndicator();
    }
  }

  Future<List<(String, String)>> _findAndReadAllFiles(String fileName) async {
    List<(String, String)> result = [];
    if (rootFolder == null) return result;
    final directory = Directory(rootFolder!);
    try {
      final entities = await directory.list(recursive: true).toList();
      for (final entity in entities) {
        if (entity is File && path.basename(entity.path) == fileName) {
          final content = await entity.readAsString();
          final relativePath = path.relative(entity.path, from: rootFolder!);
          result.add((content, relativePath));
        }
      }
    } catch (e) {
      print('Error searching for file: $e');
    }
    return result;
  }

  void _onChipTapped(String fileName, String relativePath) async {
    setState(() {
      final selected = _selectedFilePaths[fileName] ?? <String>{};
      if (selected.contains(relativePath)) {
        selected.remove(relativePath);
      } else {
        selected.add(relativePath);
      }
      // If none selected, reselect first
      if (selected.isEmpty && _duplicateFilePaths[fileName]?.isNotEmpty == true) {
        selected.add(_duplicateFilePaths[fileName]!.first);
      }
      _selectedFilePaths[fileName] = selected;
    });
    // Rebuild clipboard preview with new selection
    await _rebuildClipboardPreview();
  }

  Future<void> _rebuildClipboardPreview() async {
    final clipboardContent = await FlutterClipboard.paste();
    String modifiedContent = clipboardContent;
    for (final fileName in _selectedFilePaths.keys) {
      final selectedPaths = _selectedFilePaths[fileName]!;
      final fileInfos = await _findAndReadAllFiles(fileName);
      for (final (content, relativePath) in fileInfos) {
        if (selectedPaths.contains(relativePath)) {
          final extension = path.extension(fileName).replaceAll('.', '');
          final language = extension.isNotEmpty ? extension : 'text';
          modifiedContent += '\n\n**File: $relativePath**\n```$language\n$content\n```';
        }
      }
    }
    _lastModifiedContent = modifiedContent;
    await FlutterClipboard.copy(modifiedContent);
    setState(() {
      _clipboardPreview = modifiedContent;
    });
    _showModificationIndicator();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Clipboard File Monitor')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Root Folder:',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    rootFolder ?? 'No folder selected',
                    style: TextStyle(
                      color: rootFolder == null ? Colors.grey : Colors.black,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _selectRootFolder,
                  child: const Text('Select Folder'),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Checkbox(
                  value: monitorClipboard,
                  onChanged:
                      (value) => _toggleClipboardMonitoring(value ?? false),
                ),
                const SizedBox(width: 8),
                Text(
                  'Monitor Clipboard',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (_recentlyModified) ...[
                  const SizedBox(width: 16),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.green,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text(
                      'Modified!',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 16),
            Text(
              'Status: ${monitorClipboard ? "Monitoring" : "Not Monitoring"}',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: monitorClipboard ? Colors.green : Colors.red,
              ),
            ),
            const Divider(height: 32),
            Text(
              'Clipboard Preview:',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (_duplicateFilePaths.isNotEmpty)
              ..._duplicateFilePaths.entries.map((entry) {
                final fileName = entry.key;
                final paths = entry.value;
                final selected = _selectedFilePaths[fileName] ?? <String>{};
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Multiple files found for @$fileName:'),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: paths.map((relativePath) {
                          final isSelected = selected.contains(relativePath);
                          return Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4.0),
                            child: ChoiceChip(
                              label: Text(relativePath),
                              selected: isSelected,
                              onSelected: (_) => _onChipTapped(fileName, relativePath),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                );
              }),
            Expanded(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    _clipboardPreview.isEmpty
                        ? 'Clipboard is empty or monitoring is disabled'
                        : _clipboardPreview,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 8),
            Text(
              'How it works:',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            const Text(
              '1. Select a root folder where your files are located\n'
              '2. Enable "Monitor Clipboard"\n'
              '3. Copy text containing @filename references\n'
              '4. The app will automatically append the file contents as markdown code blocks\n'
              '5. The file path relative to root will be shown above each code block',
            ),
          ],
        ),
      ),
    );
  }
}
