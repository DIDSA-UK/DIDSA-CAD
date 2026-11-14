import 'package:material_ui/material_ui.dart';

import '../project_root.dart';
import '../storage_service.dart';
import 'remote_storage_service.dart';
import 'store_client.dart';

/// File > Server projects: the projects on the project store, to open one (the caller then picks the file in it) or to make a new
/// one. Returns the chosen root, or null when cancelled. The store's address and key come from the server settings; when the store
/// is not set or cannot be reached the dialog says so and offers another try.
Future<ServerProjectRoot?> showServerProjectsDialog(BuildContext context, RemoteStorageService remote) {
  return showDialog<ServerProjectRoot>(
    context: context,
    builder: (context) => _ServerProjectsDialog(remote: remote),
  );
}

class _ServerProjectsDialog extends StatefulWidget {
  const _ServerProjectsDialog({required this.remote});

  final RemoteStorageService remote;

  @override
  State<_ServerProjectsDialog> createState() => _ServerProjectsDialogState();
}

class _ServerProjectsDialogState extends State<_ServerProjectsDialog> {
  List<StoreProject>? _projects;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final projects = await widget.remote.listProjects();
      if (!mounted) return;
      setState(() {
        _projects = projects..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        _loading = false;
      });
    } on StorageException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  Future<void> _create() async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => const _NamePromptDialog(
        title: 'New cloud project',
        label: 'Project name',
        confirmText: 'Create',
        fieldKey: ValueKey('new-server-project-name'),
      ),
    );
    if (name == null || name.trim().isEmpty || !mounted) return;
    try {
      final root = await widget.remote.createProject(name.trim());
      if (mounted) Navigator.of(context).pop(root);
    } on StorageException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final projects = _projects;
    return AlertDialog(
      key: const ValueKey('server-projects-dialog'),
      title: const Text('Cloud storage'),
      content: SizedBox(
        width: 360,
        child: _loading
            ? const SizedBox(height: 80, child: Center(child: CircularProgressIndicator()))
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(_error!, key: const ValueKey('server-projects-error'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    ),
                  if (projects != null && projects.isEmpty) const Text('No projects in cloud storage yet.'),
                  if (projects != null && projects.isNotEmpty)
                    Flexible(
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          for (final project in projects)
                            ListTile(
                              key: ValueKey('server-project-${project.name}'),
                              leading: const Icon(Icons.folder_outlined),
                              title: Text(project.name),
                              subtitle: Text(_subtitle(project)),
                              onTap: () => Navigator.of(context).pop(widget.remote.rootFor(project.name)),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        if (_error != null && _projects == null) TextButton(onPressed: _load, child: const Text('Try again')),
        if (_projects != null) TextButton(key: const ValueKey('new-server-project'), onPressed: _create, child: const Text('New project…')),
      ],
    );
  }

  static String _subtitle(StoreProject project) {
    final files = '${project.fileCount} file${project.fileCount == 1 ? '' : 's'}';
    final last = project.lastChange;
    final by = project.lastDevice;
    if (last == null) return files;
    final date = last.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '$files · changed ${date.year}-${two(date.month)}-${two(date.day)}${by == null || by.isEmpty ? '' : ' by $by'}';
  }
}

/// "Copy this project to cloud storage": asks for the new project's name. Null when cancelled.
Future<String?> showCopyToServerDialog(BuildContext context, {required String suggestedName}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _NamePromptDialog(
      dialogKey: const ValueKey('copy-to-server-dialog'),
      title: 'Copy this project to cloud storage',
      message: 'Every file in the folder is copied into a new project in cloud storage. The folder is left as it is.',
      label: 'Project name',
      confirmText: 'Copy',
      initialValue: suggestedName,
      fieldKey: const ValueKey('copy-to-server-name'),
      confirmKey: const ValueKey('copy-to-server-confirm'),
    ),
  );
}

/// A one-field name prompt that owns its controller (a controller disposed by the caller as the dialog closes is still used by the
/// closing animation).
class _NamePromptDialog extends StatefulWidget {
  const _NamePromptDialog({
    required this.title,
    required this.label,
    required this.confirmText,
    required this.fieldKey,
    this.message,
    this.initialValue = '',
    this.dialogKey,
    this.confirmKey,
  });

  final String title;
  final String label;
  final String confirmText;
  final String? message;
  final String initialValue;
  final Key fieldKey;
  final Key? dialogKey;
  final Key? confirmKey;

  @override
  State<_NamePromptDialog> createState() => _NamePromptDialogState();
}

class _NamePromptDialogState extends State<_NamePromptDialog> {
  late final TextEditingController _controller = TextEditingController(text: widget.initialValue);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: widget.dialogKey,
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.message != null) ...[Text(widget.message!), const SizedBox(height: 12)],
          TextField(
            key: widget.fieldKey,
            controller: _controller,
            autofocus: true,
            decoration: InputDecoration(labelText: widget.label),
            onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(key: widget.confirmKey, onPressed: () => Navigator.of(context).pop(_controller.text.trim()), child: Text(widget.confirmText)),
      ],
    );
  }
}

/// Where File > Open looks: this device's folders, or cloud storage.
enum OpenSource { device, cloud }

/// File > Open… when cloud storage is set up: one entry for both places a project can live. Null when cancelled.
Future<OpenSource?> showOpenSourceDialog(BuildContext context, {required String cloudHost}) {
  return showDialog<OpenSource>(
    context: context,
    builder: (context) => SimpleDialog(
      key: const ValueKey('open-source-dialog'),
      title: const Text('Open from'),
      children: [
        ListTile(
          key: const ValueKey('open-source-device'),
          leading: const Icon(Icons.folder_outlined),
          title: const Text('This device'),
          subtitle: const Text('A project folder'),
          onTap: () => Navigator.of(context).pop(OpenSource.device),
        ),
        ListTile(
          key: const ValueKey('open-source-cloud'),
          leading: const Icon(Icons.cloud_outlined),
          title: const Text('Cloud storage'),
          subtitle: Text(cloudHost),
          onTap: () => Navigator.of(context).pop(OpenSource.cloud),
        ),
      ],
    ),
  );
}
