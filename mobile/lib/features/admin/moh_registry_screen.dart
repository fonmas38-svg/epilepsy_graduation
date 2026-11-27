import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/errors/failure.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/risk_view.dart';
import '../../core/ui/common.dart';
import '../../core/ui/states.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/app_state.dart';
import 'admin_security_guard.dart';

/// Administrator management console for the Ministry of Health (MOH) medical
/// license verification registry.
class MohRegistryScreen extends StatefulWidget {
  const MohRegistryScreen({super.key});

  @override
  State<MohRegistryScreen> createState() => _MohRegistryScreenState();
}

class _MohRegistryScreenState extends State<MohRegistryScreen> {
  final _search = TextEditingController();
  List<Map<String, dynamic>> _records = [];
  String _statusFilter = '';
  bool _loading = true;
  bool _busy = false;
  Failure? _failure;

  bool get ar => AppLocalizations.of(context).isArabic;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failure = null;
    });
    try {
      final rows = await context.read<AppState>().api.getAdminMohRegistry(
        status: _statusFilter.isEmpty ? null : _statusFilter,
        query: _search.text.trim(),
      );
      if (!mounted) return;
      setState(() => _records = rows);
    } catch (e) {
      if (mounted) setState(() => _failure = Failure.from(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openAddDialog() async {
    final verified = await requireAdminVerification(
      context,
      ar
          ? 'إضافة أو تحديث رخصة في السجل الطبي'
          : 'Add or update MOH registry license',
    );
    if (!verified || !mounted) return;

    final license = TextEditingController();
    final nationalId = TextEditingController();
    final nameAr = TextEditingController();
    final nameEn = TextEditingController();
    final spec = TextEditingController(text: 'طب الأعصاب والصرع');
    final hospital = TextEditingController();
    final expiry = TextEditingController(text: '2028-12-31');
    final form = GlobalKey<FormState>();
    String status = 'active';

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => AlertDialog(
          title: Text(ar ? 'تسجيل ترخيص طبي' : 'Register medical license'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Form(
                key: form,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextFormField(
                      controller: license,
                      decoration: InputDecoration(
                        labelText: ar
                            ? 'رقم الترخيص (مثال MOH-123)'
                            : 'License number',
                      ),
                      validator: (v) => v == null || v.trim().length < 2
                          ? (ar ? 'مطلوب' : 'Required')
                          : null,
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: nationalId,
                      decoration: InputDecoration(
                        labelText: ar ? 'رقم الهوية الوطنية' : 'National ID',
                      ),
                      validator: (v) => v == null || v.trim().length < 3
                          ? (ar ? 'مطلوب' : 'Required')
                          : null,
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: nameAr,
                      decoration: InputDecoration(
                        labelText: ar ? 'الاسم بالعربية' : 'Arabic name',
                      ),
                      validator: (v) => v == null || v.trim().isEmpty
                          ? (ar ? 'مطلوب' : 'Required')
                          : null,
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: nameEn,
                      decoration: InputDecoration(
                        labelText: ar ? 'الاسم بالإنجليزية' : 'English name',
                      ),
                      validator: (v) => v == null || v.trim().isEmpty
                          ? (ar ? 'مطلوب' : 'Required')
                          : null,
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: spec,
                      decoration: InputDecoration(
                        labelText: ar ? 'التخصص' : 'Specialization',
                      ),
                      validator: (v) => v == null || v.trim().isEmpty
                          ? (ar ? 'مطلوب' : 'Required')
                          : null,
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: hospital,
                      decoration: InputDecoration(
                        labelText: ar ? 'المستشفى / المركز' : 'Hospital',
                      ),
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      initialValue: status,
                      decoration: InputDecoration(
                        labelText: ar ? 'الحالة' : 'Status',
                      ),
                      items: [
                        DropdownMenuItem(
                          value: 'active',
                          child: Text(ar ? 'ساري' : 'Active'),
                        ),
                        DropdownMenuItem(
                          value: 'suspended',
                          child: Text(ar ? 'موقوف' : 'Suspended'),
                        ),
                        DropdownMenuItem(
                          value: 'expired',
                          child: Text(ar ? 'منتهي' : 'Expired'),
                        ),
                      ],
                      onChanged: (v) => update(() => status = v ?? 'active'),
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: expiry,
                      decoration: InputDecoration(
                        labelText: ar
                            ? 'تاريخ الانتهاء (YYYY-MM-DD)'
                            : 'Expiration date',
                      ),
                      validator: (v) => v == null || v.trim().length < 4
                          ? (ar ? 'مطلوب' : 'Required')
                          : null,
                    ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(ar ? 'إلغاء' : 'Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (form.currentState!.validate()) Navigator.pop(ctx, true);
              },
              child: Text(ar ? 'حفظ' : 'Save'),
            ),
          ],
        ),
      ),
    );

    if (ok == true && mounted) {
      setState(() => _busy = true);
      try {
        await context.read<AppState>().api.upsertAdminMohRecord(
          licenseNumber: license.text.trim(),
          nationalId: nationalId.text.trim(),
          fullNameAr: nameAr.text.trim(),
          fullNameEn: nameEn.text.trim(),
          specialization: spec.text.trim(),
          hospitalAffiliation: hospital.text.trim(),
          status: status,
          expirationDate: expiry.text.trim(),
        );
        if (!mounted) return;
        AppSnack.success(
          context,
          ar ? 'تم حفظ الترخيص بنجاح' : 'License saved',
        );
        await _load();
      } catch (e) {
        if (mounted) {
          AppSnack.error(
            context,
            Failure.from(e).message(AppLocalizations.of(context)),
          );
        }
      } finally {
        if (mounted) setState(() => _busy = false);
      }
    }

    license.dispose();
    nationalId.dispose();
    nameAr.dispose();
    nameEn.dispose();
    spec.dispose();
    hospital.dispose();
    expiry.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(ar ? 'سجل التراخيص الطبية (MOH)' : 'MOH License Registry'),
        actions: [
          IconButton(
            tooltip: ar ? 'تحديث' : 'Refresh',
            onPressed: _loading || _busy ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ResponsiveContent(
        maxWidth: 1000,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 260,
                  child: TextField(
                    controller: _search,
                    onSubmitted: (_) => _load(),
                    decoration: InputDecoration(
                      labelText: ar
                          ? 'بحث برقم الترخيص أو الاسم'
                          : 'Search license or name',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.arrow_forward),
                        onPressed: _load,
                      ),
                    ),
                  ),
                ),
                FilledButton.icon(
                  onPressed: _busy ? null : _openAddDialog,
                  icon: const Icon(Icons.add),
                  label: Text(
                    ar ? 'إضافة / تحديث ترخيص' : 'Add / Update license',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final entry in [
                  ('', ar ? 'الكل' : 'All'),
                  ('active', ar ? 'ساري' : 'Active'),
                  ('suspended', ar ? 'موقوف' : 'Suspended'),
                  ('expired', ar ? 'منتهي' : 'Expired'),
                ])
                  ChoiceChip(
                    label: Text(entry.$2),
                    selected: _statusFilter == entry.$1,
                    onSelected: (_) {
                      setState(() => _statusFilter = entry.$1);
                      _load();
                    },
                  ),
              ],
            ),
            const SizedBox(height: 16),
            if (_loading || _busy) const LinearProgressIndicator(),
            if (_failure != null) ...[
              Text(_failure!.message(AppLocalizations.of(context))),
              TextButton(
                onPressed: _load,
                child: Text(ar ? 'إعادة المحاولة' : 'Retry'),
              ),
            ],
            if (!_loading && _failure == null && _records.isEmpty)
              EmptyState(
                title: ar ? 'لا توجد تراخيص مطابقة' : 'No matching licenses',
              ),
            ..._records.map((r) {
              final st = '${r['status'] ?? ''}';
              final color = switch (st) {
                'active' => AppColors.accent(
                  context,
                  AccentTone.green,
                ).container,
                'suspended' => AppColors.of(context, RiskView.danger).container,
                _ => AppColors.of(context, RiskView.caution).container,
              };
              return Card(
                margin: const EdgeInsets.symmetric(vertical: 5),
                child: ListTile(
                  leading: const Icon(Icons.verified_outlined),
                  title: Text(
                    '${r['fullNameAr'] ?? ''} (${r['licenseNumber'] ?? ''})',
                  ),
                  subtitle: Text(
                    '${r['specialization'] ?? ''} · ${r['hospitalAffiliation'] ?? ''}\n${ar ? 'الهوية' : 'ID'}: ${r['nationalId'] ?? ''} · ${ar ? 'الانتهاء' : 'Exp'}: ${r['expirationDate'] ?? ''}',
                  ),
                  trailing: Chip(label: Text(st), backgroundColor: color),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}
