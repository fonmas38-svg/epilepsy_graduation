import 'dart:convert';

import 'package:csv/csv.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../core/enums.dart';
import '../models/models.dart';

class ReportService {
  String toCsv({
    required PatientProfile patient,
    required List<RiskAssessment> assessments,
    required List<AlertItem> alerts,
  }) {
    final rows = <List<dynamic>>[
      ['Report', 'Epilepsy Monitoring V1'],
      ['Patient', patient.name],
      ['Patient ID', patient.patientId],
      ['Diagnosis', patient.diagnosis],
      [
        'Generated',
        DateFormat('yyyy-MM-dd h:mm a', 'en').format(DateTime.now()),
      ],
      [],
      ['Assessments'],
      ['Timestamp', 'Label', 'Confidence', 'ProcessingMs'],
      ...assessments.map(
        (a) => [
          a.timestamp.toIso8601String(),
          a.label.apiValue,
          a.confidence.toStringAsFixed(3),
          a.processingMs.toStringAsFixed(2),
        ],
      ),
      [],
      ['Alerts'],
      ['Timestamp', 'Severity', 'Message', 'Acknowledged'],
      ...alerts.map(
        (a) => [
          a.timestamp.toIso8601String(),
          a.severity,
          a.displayMessage,
          a.acknowledged,
        ],
      ),
    ];
    return const ListToCsvConverter().convert(rows);
  }

  Future<pw.Document> toPdf({
    required PatientProfile patient,
    required List<RiskAssessment> assessments,
    required List<AlertItem> alerts,
  }) async {
    final doc = pw.Document();
    final fmt = DateFormat('yyyy-MM-dd h:mm a', 'en');
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        build: (context) => [
          pw.Header(
            level: 0,
            child: pw.Text(
              'Epilepsy Monitoring Report',
              style: pw.TextStyle(fontSize: 22),
            ),
          ),
          pw.Text('Patient: ${patient.name}'),
          pw.Text('ID: ${patient.patientId}'),
          pw.Text('Diagnosis: ${patient.diagnosis}'),
          pw.Text('Medications: ${patient.medications.join(", ")}'),
          pw.Text('Current status: ${patient.currentStatus.apiValue}'),
          pw.Text('Generated: ${fmt.format(DateTime.now())}'),
          pw.SizedBox(height: 16),
          pw.Text('Recent assessments', style: pw.TextStyle(fontSize: 16)),
          pw.TableHelper.fromTextArray(
            headers: const ['Time', 'Label', 'Confidence'],
            data: assessments
                .take(20)
                .map(
                  (a) => [
                    fmt.format(a.timestamp),
                    a.label.apiValue,
                    a.confidence.toStringAsFixed(2),
                  ],
                )
                .toList(),
          ),
          pw.SizedBox(height: 16),
          pw.Text('Alerts', style: pw.TextStyle(fontSize: 16)),
          pw.TableHelper.fromTextArray(
            headers: const ['Time', 'Severity', 'Message'],
            data: alerts
                .take(20)
                .map(
                  (a) => [
                    fmt.format(a.timestamp),
                    a.severity,
                    a.displayMessage,
                  ],
                )
                .toList(),
          ),
        ],
      ),
    );
    return doc;
  }

  String assessmentsJson(List<RiskAssessment> assessments) =>
      jsonEncode(assessments.map((e) => e.toMap()).toList());
}
