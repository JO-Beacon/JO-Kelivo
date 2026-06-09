import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/providers/settings_provider.dart';
import '../../../core/services/provider_balance_service.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';

class ProviderBalanceBadge extends StatefulWidget {
  const ProviderBalanceBadge({
    super.key,
    required this.providerKey,
    required this.displayName,
    this.style,
    this.color,
    this.iconSize,
  });

  final String providerKey;
  final String displayName;
  final TextStyle? style;
  final Color? color;
  final double? iconSize;

  static void clearCacheFor(String providerKey) {
    _ProviderBalanceBadgeState._cache.removeWhere(
      (key, _) => key.startsWith('$providerKey|'),
    );
  }

  @override
  State<ProviderBalanceBadge> createState() => _ProviderBalanceBadgeState();
}

class _ProviderBalanceBadgeState extends State<ProviderBalanceBadge> {
  static final Map<String, String> _cache = <String, String>{};

  String? _cacheKey;
  String _value = '~';
  String? _error;
  String? _errorCode;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncQuery(notify: false);
  }

  @override
  void didUpdateWidget(covariant ProviderBalanceBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncQuery();
  }

  void _syncQuery({bool notify = true}) {
    final settings = context.read<SettingsProvider>();
    final config = settings.getProviderConfig(
      widget.providerKey,
      defaultName: widget.displayName,
    );
    if (config.balanceEnabled != true) return;

    final key = [
      config.id,
      config.balanceApiPath ?? '',
      config.balanceResultPath ?? '',
      config.apiKey.hashCode,
      config.multiKeyEnabled,
      config.apiKeys?.length ?? 0,
    ].join('|');
    if (_cacheKey == key) return;
    _cacheKey = key;

    final cached = _cache[key];
    if (cached != null) {
      if (mounted && notify) {
        setState(() {
          _value = cached;
          _error = null;
          _errorCode = null;
        });
      } else {
        _value = cached;
        _error = null;
        _errorCode = null;
      }
      return;
    }

    void reset() {
      _value = '~';
      _error = null;
      _errorCode = null;
    }

    if (notify) {
      setState(reset);
    } else {
      reset();
    }
    _fetch(config, key);
  }

  Future<void> _fetch(ProviderConfig config, String key) async {
    try {
      final value = await ProviderBalanceService.fetchBalance(config);
      _cache[key] = value;
      if (!mounted || _cacheKey != key) return;
      setState(() {
        _value = value;
        _error = null;
        _errorCode = null;
      });
    } catch (e) {
      if (!mounted || _cacheKey != key) return;
      setState(() {
        _value = '!';
        if (e is ProviderBalanceException) {
          _error = e.message;
          _errorCode = e.code;
        } else {
          _error = e.toString();
          _errorCode = null;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final config = settings.getProviderConfig(
      widget.providerKey,
      defaultName: widget.displayName,
    );
    if (config.balanceEnabled != true) {
      return const SizedBox.shrink();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncQuery();
    });

    final cs = Theme.of(context).colorScheme;
    final style = widget.style ?? Theme.of(context).textTheme.labelSmall;
    final color = widget.color ?? cs.onSurface.withValues(alpha: 0.62);
    final iconSize = widget.iconSize ?? ((style?.fontSize ?? 12) + 2);
    final child = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Lucide.Coins, size: iconSize, color: color),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            _value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style?.copyWith(color: color),
          ),
        ),
      ],
    );

    if (_error == null) return child;
    final l10n = AppLocalizations.of(context)!;
    final message = _errorCode == 'full_balance_api_url_required'
        ? l10n.providerDetailPageBalanceFullUrlRequired
        : _error!;
    return Tooltip(
      message: l10n.providerDetailPageBalanceError(message),
      child: child,
    );
  }
}
