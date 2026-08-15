import { useCallback, useEffect, useMemo, useState } from 'react';
import { usersApi } from '../api/users.js';
import { useToast } from '../context/ToastContext.jsx';
import PageHeader from '../components/PageHeader.jsx';
import DataTable from '../components/DataTable.jsx';
import Modal from '../components/Modal.jsx';
import FormField from '../components/FormField.jsx';
import ConfirmDialog from '../components/ConfirmDialog.jsx';
import GeneratedPasswordModal from '../components/GeneratedPasswordModal.jsx';
import { StateBadge, StatusBadge } from '../components/Badge.jsx';
import { formatDateTime } from '../lib/format.js';

// Admin view of every patient. Create adds a patient (optionally assigned to a
// doctor at creation), and per-row actions reset password / disable / delete.
export default function PatientsPage() {
  const toast = useToast();
  const [patients, setPatients] = useState([]);
  const [doctors, setDoctors] = useState([]);
  const [loading, setLoading] = useState(true);
  const [q, setQ] = useState('');
  const [showCreate, setShowCreate] = useState(false);
  const [generated, setGenerated] = useState(null);
  const [confirm, setConfirm] = useState(null);
  const [busy, setBusy] = useState(false);

  const reload = useCallback(async () => {
    setLoading(true);
    try {
      // /doctor/patients (admin) returns patients enriched with live status.
      const [pt, dc] = await Promise.all([usersApi.myPatients(), usersApi.listUsers({ role: 'doctor' })]);
      setPatients(pt.patients || []);
      setDoctors(dc.users || []);
    } catch (e) {
      toast.error(e.message);
    } finally {
      setLoading(false);
    }
  }, [toast]);

  useEffect(() => {
    reload();
  }, [reload]);

  const doctorsById = useMemo(
    () => Object.fromEntries(doctors.map((d) => [d.id, d.name])),
    [doctors],
  );

  const filtered = useMemo(() => {
    const n = q.trim().toLowerCase();
    if (!n) return patients;
    return patients.filter(
      (p) =>
        String(p.name).toLowerCase().includes(n) ||
        String(p.username).toLowerCase().includes(n),
    );
  }, [patients, q]);

  const runConfirm = async () => {
    if (!confirm) return;
    const { type, patient } = confirm;
    setBusy(true);
    try {
      if (type === 'disable') await usersApi.disableUser(patient.id);
      else if (type === 'enable') await usersApi.enableUser(patient.id);
      else if (type === 'delete') await usersApi.deleteUser(patient.id);
      else if (type === 'reset') {
        const res = await usersApi.resetPassword(patient.id, null);
        setGenerated(res.generatedPassword);
      }
      toast.success('تم تنفيذ العملية');
      setConfirm(null);
      if (type !== 'reset') await reload();
    } catch (e) {
      toast.error(e.message);
    } finally {
      setBusy(false);
    }
  };

  return (
    <div>
      <PageHeader
        title="المرضى"
        subtitle="كل حسابات المرضى مع حالتهم الحيّة"
        actions={
          <button className="btn btn--primary" onClick={() => setShowCreate(true)}>
            + مريض جديد
          </button>
        }
      />
      <div className="card">
        <div className="toolbar">
          <input
            className="field__control toolbar__search"
            placeholder="بحث بالاسم أو اسم المستخدم…"
            value={q}
            onChange={(e) => setQ(e.target.value)}
          />
        </div>
        <DataTable
          loading={loading}
          rows={filtered}
          empty="لا يوجد مرضى بعد"
          columns={[
            { key: 'name', header: 'الاسم', render: (p) => <strong>{p.name}</strong> },
            { key: 'username', header: 'اسم المستخدم', render: (p) => <span className="mono">{p.username}</span> },
            { key: 'currentStatus', header: 'الحالة الحيّة', render: (p) => <StatusBadge status={p.currentStatus} /> },
            {
              key: 'doctorIds',
              header: 'الأطباء',
              render: (p) =>
                (p.doctorIds || []).length
                  ? (p.doctorIds || []).map((id) => doctorsById[id] || id).join('، ')
                  : <span className="muted">غير مُسند</span>,
            },
            { key: 'disabled', header: 'الحساب', render: (p) => <StateBadge disabled={p.disabled} /> },
            { key: 'lastUpdated', header: 'آخر تحديث', render: (p) => formatDateTime(p.lastUpdated) },
            {
              key: 'actions',
              header: '',
              render: (p) => (
                <div className="row-actions">
                  <button className="btn btn--ghost btn--sm" onClick={() => setConfirm({ type: 'reset', patient: p })}>
                    كلمة مرور
                  </button>
                  {p.disabled ? (
                    <button className="btn btn--ghost btn--sm" onClick={() => setConfirm({ type: 'enable', patient: p })}>
                      تفعيل
                    </button>
                  ) : (
                    <button className="btn btn--ghost btn--sm" onClick={() => setConfirm({ type: 'disable', patient: p })}>
                      تعطيل
                    </button>
                  )}
                  <button className="btn btn--danger btn--sm" onClick={() => setConfirm({ type: 'delete', patient: p })}>
                    حذف
                  </button>
                </div>
              ),
            },
          ]}
        />
      </div>

      {showCreate && (
        <CreatePatientModal
          doctors={doctors}
          onClose={() => setShowCreate(false)}
          onCreated={(pw) => {
            setShowCreate(false);
            reload();
            if (pw) setGenerated(pw);
            else toast.success('تم إنشاء المريض');
          }}
        />
      )}
      {confirm && (
        <ConfirmDialog
          title={
            { reset: 'إعادة تعيين كلمة المرور', disable: 'تعطيل المريض', enable: 'تفعيل المريض', delete: 'حذف المريض' }[
              confirm.type
            ]
          }
          message={
            {
              reset: `توليد كلمة مرور مؤقتة جديدة للمريض "${confirm.patient.name}"؟`,
              disable: `سيتعذّر على "${confirm.patient.name}" تسجيل الدخول. متابعة؟`,
              enable: `إعادة تفعيل حساب "${confirm.patient.name}"؟`,
              delete: `سيُحذف حساب "${confirm.patient.name}" وكل إسناداته نهائياً. لا يمكن التراجع. متابعة؟`,
            }[confirm.type]
          }
          confirmLabel={{ reset: 'توليد', disable: 'تعطيل', enable: 'تفعيل', delete: 'حذف نهائي' }[confirm.type]}
          danger={confirm.type === 'disable' || confirm.type === 'delete'}
          busy={busy}
          onConfirm={runConfirm}
          onCancel={() => setConfirm(null)}
        />
      )}
      {generated && <GeneratedPasswordModal password={generated} onClose={() => setGenerated(null)} />}
    </div>
  );
}

function CreatePatientModal({ doctors, onClose, onCreated }) {
  const toast = useToast();
  const [username, setUsername] = useState('');
  const [name, setName] = useState('');
  const [password, setPassword] = useState('');
  const [doctorId, setDoctorId] = useState('');
  const [busy, setBusy] = useState(false);

  const submit = async (e) => {
    e?.preventDefault?.();
    if (username.trim().length < 3) return toast.error('اسم المستخدم 3 أحرف على الأقل');
    if (!name.trim()) return toast.error('الاسم مطلوب');
    if (password && password.length < 6) return toast.error('كلمة المرور 6 أحرف على الأقل');
    setBusy(true);
    try {
      const res = await usersApi.createPatient({
        username: username.trim(),
        name: name.trim(),
        password: password || null,
        doctor_id: doctorId || null,
      });
      onCreated(res.generatedPassword);
    } catch (err) {
      toast.error(err.message);
    } finally {
      setBusy(false);
    }
  };

  return (
    <Modal
      title="مريض جديد"
      onClose={onClose}
      footer={
        <>
          <button className="btn btn--ghost" onClick={onClose} disabled={busy}>
            إلغاء
          </button>
          <button className="btn btn--primary" onClick={submit} disabled={busy}>
            {busy ? '…' : 'إنشاء'}
          </button>
        </>
      }
    >
      <form onSubmit={submit}>
        <FormField label="الاسم الكامل" name="name" value={name} onChange={setName} required autoFocus />
        <FormField
          label="اسم المستخدم"
          name="username"
          value={username}
          onChange={setUsername}
          required
          hint="يُستخدم لتسجيل الدخول (3 أحرف على الأقل)"
        />
        <FormField
          label="الطبيب المسؤول"
          name="doctorId"
          as="select"
          value={doctorId}
          onChange={setDoctorId}
          options={[{ value: '', label: 'بدون إسناد (يمكن إسناده لاحقاً)' }, ...doctors.map((d) => ({ value: d.id, label: d.name }))]}
          hint="اختياري — يمكنك الإسناد لاحقاً من صفحة الإسناد"
        />
        <FormField
          label="كلمة المرور"
          name="password"
          type="password"
          value={password}
          onChange={setPassword}
          hint="اتركها فارغة لتوليد كلمة مرور مؤقتة تلقائياً"
        />
        <button type="submit" style={{ display: 'none' }} />
      </form>
    </Modal>
  );
}
