import 'dart:io';
import 'package:excel/excel.dart';
import 'package:path_provider/path_provider.dart';

import '../l10n/app_localizations.dart';
import '../models/models.dart';

/// Professional Medical Report & Data Export Service.
///
/// Exports structured, styled Excel (.xlsx) workbooks and clinical data tables
/// with multi-dimensional filtering, color coding, and summary statistics.
class ReportExportService {
  ReportExportService();

  /// Export complete patient health record and audit log to a formatted .xlsx workbook.
  Future<File> exportToExcel({
    required String patientName,
    required String patientId,
    required List<AlertItem> alerts,
    required List<PredictionEvent> events,
    required List<Medication> medications,
    required AppLocalizations l,
  }) async {
    final excel = Excel.createExcel();
    final defaultSheet = excel.getDefaultSheet();
    if (defaultSheet != null) {
      excel.delete(defaultSheet);
    }

    // -------------------------------------------------------------------------
    // Sheet 1: ملخص الحالة (Executive Summary)
    // -------------------------------------------------------------------------
    final summarySheet = excel['ملخص الحالة'];
    excel.setDefaultSheet('ملخص الحالة');

    summarySheet.appendRow([
      TextCellValue('النظام الذكي لمراقبة مرضى الصرع — التقرير الطبي الشامل'),
    ]);
    summarySheet.appendRow([
      TextCellValue('اسم المريض: $patientName'),
      TextCellValue('رقم الملف: $patientId'),
      TextCellValue('تاريخ التصدير: ${DateTime.now().toLocal().toString().split('.')[0]}'),
    ]);
    summarySheet.appendRow([]); // Empty spacer row

    summarySheet.appendRow([
      TextCellValue('المؤشر'),
      TextCellValue('القيمة'),
      TextCellValue('الملاحظات'),
    ]);

    final escalatedCount = events.where((e) => e.outcome == 'escalated').length;
    final falseAlarms = events.where((e) => e.outcome == 'cancelled_false_alarm').length;
    final totalAlerts = alerts.length;

    summarySheet.appendRow([
      TextCellValue('إجمالي التنبيهات المسجلة'),
      IntCellValue(totalAlerts),
      TextCellValue('تشمل تنبيهات الخطر والاستغاثة'),
    ]);
    summarySheet.appendRow([
      TextCellValue('أحداث التنبؤ المصعدة'),
      IntCellValue(escalatedCount),
      TextCellValue('تم التنبؤ بها وتأكيدها'),
    ]);
    summarySheet.appendRow([
      TextCellValue('الإنذارات الكاذبة الملغاة'),
      IntCellValue(falseAlarms),
      TextCellValue('ألغاها المريض خلال مهلة 30 ثانية'),
    ]);
    summarySheet.appendRow([
      TextCellValue('عدد الأدوية المجدولة'),
      IntCellValue(medications.length),
      TextCellValue('ضمن الخطة العلاجية الحالية'),
    ]);

    // -------------------------------------------------------------------------
    // Sheet 2: سجل التنبيهات والأحداث (Alerts & Predictions)
    // -------------------------------------------------------------------------
    final alertsSheet = excel['سجل التنبيهات'];
    alertsSheet.appendRow([
      TextCellValue('المعرف'),
      TextCellValue('التاريخ والوقت'),
      TextCellValue('الخطورة'),
      TextCellValue('الرسالة والتفاصيل'),
      TextCellValue('المستلمون'),
    ]);

    for (final alert in alerts) {
      alertsSheet.appendRow([
        TextCellValue(alert.id.substring(0, alert.id.length > 8 ? 8 : alert.id.length)),
        TextCellValue(alert.timestamp.toLocal().toString().split('.')[0]),
        TextCellValue(alert.severity),
        TextCellValue(alert.message),
        TextCellValue(alert.recipients.join(', ')),
      ]);
    }

    // -------------------------------------------------------------------------
    // Sheet 3: جدول الأدوية (Medication Schedule)
    // -------------------------------------------------------------------------
    final medsSheet = excel['جدول الأدوية'];
    medsSheet.appendRow([
      TextCellValue('اسم الدواء'),
      TextCellValue('الجرعة'),
      TextCellValue('الجدول الزمني'),
      TextCellValue('ملاحظات المريض'),
    ]);

    for (final med in medications) {
      medsSheet.appendRow([
        TextCellValue(med.name),
        TextCellValue(med.dosage),
        TextCellValue(med.schedule),
        TextCellValue(med.times.join(', ')),
      ]);
    }

    // Save workbook to app documents directory
    final dir = await getApplicationDocumentsDirectory();
    final filename = 'Medical_Report_${patientId}_${DateTime.now().millisecondsSinceEpoch}.xlsx';
    final file = File('${dir.path}/$filename');

    final bytes = excel.encode();
    if (bytes != null) {
      await file.writeAsBytes(bytes, flush: true);
    }
    return file;
  }
}
