"""Fixed, pre-provisioned A/B slot storage adapter.

Importing this module performs no filesystem or network operations. This is a
host-testable storage boundary, not a claim about physical LittleFS isolation.
"""

import os

if globals().get('__package__'):
    from .candidate_manifest import (MAX_ASSET_BYTES, MAX_MANIFEST_BYTES,
                                     MAX_TARGETS, MAX_TOTAL_ASSET_BYTES,
                                     _path as _signed_target_path)
    from .public_release_paths import release_asset_name
else:  # MicroPython uses a flat trusted sys.path.
    from candidate_manifest import (MAX_ASSET_BYTES, MAX_MANIFEST_BYTES,
                                    MAX_TARGETS, MAX_TOTAL_ASSET_BYTES,
                                    _path as _signed_target_path)
    from public_release_paths import release_asset_name


class SlotStorageError(Exception):
    """Redacted fixed-slot storage failure."""


def _parts(path):
    if not isinstance(path, str) or not path:
        raise ValueError()
    normalized = path.replace('\\', '/')
    if '//' in normalized:
        raise ValueError()
    windows = (len(normalized) >= 3 and normalized[1] == ':' and normalized[2] == '/')
    if not normalized.startswith('/') and not windows:
        raise ValueError()
    trimmed = normalized.rstrip('/')
    if not trimmed or trimmed == '/' or (windows and len(trimmed) == 2):
        raise ValueError()
    components = trimmed.split('/')
    if (any(part in ('.', '..') for part in components) or
            any(not part for part in components[1:]) or
            (windows and (not components[0][0].isalpha() or len(components[0]) != 2))):
        raise ValueError()
    key_parts = [part.casefold() for part in components] if windows else components
    return trimmed, key_parts


def _join(root, relative):
    separator = '\\' if '\\' in root else '/'
    return root.rstrip('/\\') + separator + relative.replace('/', separator)


def _entry_names(directory, max_entries, allowed=None):
    iterator = None
    try:
        iterator = getattr(os, 'ilistdir', None)
        if callable(iterator):
            iterator = iterator(directory)
        else:
            iterator = iter(os.listdir(directory))
        result = []
        for row in iterator:
            name = row[0] if isinstance(row, tuple) else row
            if isinstance(name, bytes):
                name = name.decode('ascii')
            if not isinstance(name, str) or (allowed is not None and not allowed(name)):
                raise SlotStorageError() from None
            if len(result) >= max_entries:
                raise SlotStorageError() from None
            result.append((name, row if isinstance(row, tuple) else None))
        return result
    except SlotStorageError:
        raise
    except Exception:
        raise SlotStorageError() from None
    finally:
        close = getattr(iterator, 'close', None)
        if callable(close):
            try:
                close()
            except Exception:
                pass


def _stat(path, lstat=False):
    try:
        method = getattr(os, 'lstat', None) if lstat else None
        return (method or os.stat)(path)
    except Exception:
        raise SlotStorageError() from None


def _root_identity(path):
    """Return a usable device/inode pair where the host exposes one."""
    try:
        value = os.stat(path)
        device = getattr(value, 'st_dev', value[2] if len(value) > 2 else None)
        inode = getattr(value, 'st_ino', value[1] if len(value) > 1 else None)
        if type(device) is int and type(inode) is int and inode != 0:
            return device, inode
    except Exception:
        # Lexical canonicalization remains mandatory on minimal MicroPython
        # ports that do not expose stable device/inode values.
        return None
    return None


def _kind(path, row=None):
    # MicroPython ilistdir reports mode bits in row[1]. Zero/unknown type bits
    # fall back to lstat where provided, otherwise stat on the provisioned
    # filesystem. Ports without lstat cannot independently identify symlinks.
    if row is not None and len(row) > 1 and type(row[1]) is int and row[1] & 0o170000:
        mode = row[1]
    else:
        mode = _stat(path, lstat=True)[0]
    kind = mode & 0o170000
    if kind == 0o040000:
        return 'dir'
    if kind == 0o100000:
        return 'file'
    return 'other'


class _SlotAccessor:
    def __init__(self, storage, root):
        self._storage = storage
        self.root = root

    def list_assets(self):
        return self._storage._inspect(self.root)

    def open_asset(self, relative_path):
        try:
            relative_path = _checked_target_path(relative_path)
            return open(_join(self.root, relative_path), 'rb')
        except Exception:
            raise SlotStorageError() from None


def _checked_target_path(path):
    _signed_target_path(path)
    if path != 'app.mpy' and release_asset_name(path) != path.split('/')[-1]:
        raise ValueError()
    return path


class FixedSlotStorage:
    """Bind two trusted pre-created roots and a fixed public release transport."""

    def __init__(self, update_state, root_a, root_b, transport, service=None):
        try:
            normalized_a, parts_a = _parts(root_a)
            normalized_b, parts_b = _parts(root_b)
            if (parts_a == parts_b or
                    (len(parts_a) <= len(parts_b) and parts_b[:len(parts_a)] == parts_a) or
                    (len(parts_b) <= len(parts_a) and parts_a[:len(parts_b)] == parts_b)):
                raise ValueError()
            identity_a = _root_identity(normalized_a)
            identity_b = _root_identity(normalized_b)
            if identity_a is not None and identity_a == identity_b:
                raise ValueError()
            if not callable(getattr(transport, 'fetch_asset', None)):
                raise ValueError()
            if service is not None and not callable(service):
                raise ValueError()
            self._roots = {'A': normalized_a, 'B': normalized_b}
            self._state = update_state
            self._transport = transport
            self._service = service
            for root in self._roots.values():
                self._check_root(root)
        except Exception:
            raise SlotStorageError() from None

    def _check_root(self, root):
        if _kind(root) != 'dir':
            raise SlotStorageError() from None
        lib = _join(root, 'lib')
        if _kind(lib) != 'dir':
            raise SlotStorageError() from None

    def slot_reader(self, slot):
        try:
            root = self._roots[slot]
            self._check_root(root)
            self._inspect(root)
            manifest_path = _join(root, 'manifest.json')
            signature_path = _join(root, 'manifest.sig')
            with open(manifest_path, 'rb') as stream:
                raw = stream.read(MAX_MANIFEST_BYTES + 1)
            with open(signature_path, 'rb') as stream:
                signature = stream.read(65)
            if len(raw) > MAX_MANIFEST_BYTES or len(signature) != 64:
                raise ValueError()
            return raw, signature, _SlotAccessor(self, root)
        except Exception:
            raise SlotStorageError() from None

    def stage_writer(self, slot, candidate, raw_manifest, signature):
        transferred = [0]
        try:
            self._authorized(slot, candidate)
            if (not isinstance(raw_manifest, bytes) or
                    len(raw_manifest) > MAX_MANIFEST_BYTES or
                    not isinstance(signature, bytes) or len(signature) != 64):
                raise ValueError()
            targets = _checked_targets(candidate)
            root = self._roots[slot]
            self._check_root(root)
            self._checkpoint(transferred[0])
            entries = self._inspect(root)
            self._checkpoint(transferred[0])
            self._authorized(slot, candidate)
            # Remove only known staged files. Applied slot is never a target.
            for relative in entries:
                self._checkpoint(transferred[0])
                self._authorized(slot, candidate)
                os.remove(_join(root, relative))
                self._checkpoint(transferred[0])
            self._checkpoint(transferred[0])
            self._authorized(slot, candidate)
            self._write_exact(_join(root, 'manifest.json'), raw_manifest, transferred,
                              slot, candidate)
            self._checkpoint(transferred[0])
            self._authorized(slot, candidate)
            self._write_exact(_join(root, 'manifest.sig'), signature, transferred,
                              slot, candidate)
            for descriptor, asset_name in targets:
                self._checkpoint(transferred[0])
                self._authorized(slot, candidate)
                relative = descriptor.path
                target_path = _join(root, relative)
                stream = open(target_path, 'wb')
                written = [0]

                def writer(piece):
                    self._checkpoint(transferred[0])
                    self._authorized(slot, candidate)
                    if not isinstance(piece, bytes) or not piece or len(piece) > 1024:
                        raise SlotStorageError() from None
                    count = stream.write(piece)
                    if count != len(piece):
                        raise SlotStorageError() from None
                    written[0] += count
                    transferred[0] += count
                    if written[0] > descriptor.size_bytes:
                        raise SlotStorageError() from None
                    self._checkpoint(transferred[0])
                    return count

                def transport_service():
                    self._checkpoint(transferred[0])

                try:
                    self._transport.fetch_asset(
                        candidate.release_id, asset_name, writer,
                        max(1, descriptor.size_bytes),
                        expected_size=descriptor.size_bytes,
                        service=transport_service if self._service is not None else None)
                    if written[0] != descriptor.size_bytes:
                        raise SlotStorageError() from None
                    stream.flush()
                finally:
                    stream.close()
                self._checkpoint(transferred[0])
            self._authorized(slot, candidate)
        except Exception:
            raise SlotStorageError() from None

    def _authorized(self, slot, candidate):
        try:
            state = self._state.state
            if (slot not in ('A', 'B') or slot == state['applied_slot'] or
                    state['phase'] != 'writing' or state['pending_slot'] != slot or
                    state['pending_id'] != candidate.release_id):
                raise ValueError()
        except Exception:
            raise SlotStorageError() from None

    def _checkpoint(self, count):
        if self._service is None:
            return
        try:
            if self._service(count) is False:
                raise ValueError()
        except Exception:
            raise SlotStorageError() from None

    def _inspect(self, root):
        found = []
        root_entries = _entry_names(
            root, 4, lambda name: name in ('lib', 'manifest.json', 'manifest.sig', 'app.mpy'))
        for name, row in root_entries:
            path = _join(root, name)
            if name == 'lib':
                if _kind(path, row) != 'dir':
                    raise SlotStorageError() from None
                for child, child_row in _entry_names(
                        path, MAX_TARGETS - 1,
                        lambda item: _valid_asset_path('lib/' + item)):
                    relative = 'lib/' + child
                    if (_kind(_join(path, child), child_row) != 'file' or
                            _valid_asset_path(relative) is not True or
                            relative in found):
                        raise SlotStorageError() from None
                    found.append(relative)
            elif name in ('manifest.json', 'manifest.sig'):
                if _kind(path, row) != 'file':
                    raise SlotStorageError() from None
            elif name == 'app.mpy' and _kind(path, row) == 'file':
                found.append(name)
            else:
                raise SlotStorageError() from None
        return found

    def _write_exact(self, path, data, transferred, slot, candidate):
        self._checkpoint(transferred[0])
        self._authorized(slot, candidate)
        self._authorized_path(path)
        stream = open(path, 'wb')
        try:
            count = stream.write(data)
            if count != len(data):
                raise SlotStorageError() from None
            stream.flush()
        finally:
            stream.close()
        self._checkpoint(transferred[0])

    def _authorized_path(self, path):
        if not any(path.startswith(root.rstrip('/\\') + ('\\' if '\\' in root else '/'))
                   for root in self._roots.values()):
            raise SlotStorageError() from None


def _valid_asset_path(path):
    try:
        return _checked_target_path(path) == path
    except Exception:
        return False


def _checked_targets(candidate):
    if type(candidate.release_id) is not int or not 0 < candidate.release_id <= 10 ** 20 - 1:
        raise ValueError()
    descriptors = candidate.targets
    if not isinstance(descriptors, tuple) or not 1 <= len(descriptors) <= MAX_TARGETS:
        raise ValueError()
    result, paths, names = [], set(), set()
    total = 0
    for descriptor in descriptors:
        path = _checked_target_path(descriptor.path)
        name = release_asset_name(path)
        size = descriptor.size_bytes
        digest = descriptor.sha256
        if (path != descriptor.path or descriptor.name != name or name in names or
                type(size) is not int or size < 0 or size > MAX_ASSET_BYTES):
            raise ValueError()
        if (not isinstance(digest, str) or len(digest) != 64 or
                any(char not in '0123456789abcdef' for char in digest)):
            raise ValueError()
        if path in paths:
            raise ValueError()
        total += size
        if total > MAX_TOTAL_ASSET_BYTES:
            raise ValueError()
        paths.add(path)
        names.add(name)
        result.append((descriptor, name))
    if 'app.mpy' not in paths:
        raise ValueError()
    return result
