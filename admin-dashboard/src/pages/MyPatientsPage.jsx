import { useCallback, useEffect, useMemo, useState } from 'react';
import { usersApi } from '../api/users.js';
import { useAuth } from '../context/AuthContext.jsx';
import { useToast } from '../context/ToastContext.jsx';
import PageHeader from '../components/PageHeader.jsx';
import DataTable from '../components/DataTable.jsx';
import Modal from '../components/Modal.jsx';
import FormField from '../components/FormField.jsx';
import ConfirmDialog from '../components/ConfirmDialog.jsx';
import GeneratedPasswordModal from '../components/GeneratedPasswordModal.jsx';
import { StatusBadge } from '../components/Badge.jsx';
import { formatDateTime } from '../lib/format.js';

// The doctor's home screen (admins can open it too and see every patient). A
// doctor may create patients — auto-assigned to themselves — and reset their
// passwords, but cannot disable/delete accounts (that stays admin-only).
export default function MyPatientsPage() {
  const toast = useToast();
  const { role } = useAuth();
  const isAdmin = role === 'admin';
  const [patients, setPatients] = useState([]);
  const [loading, setLoading] = useState(true);
  const [q, setQ] = useState('');
  const [showCreate, setShowCreate] = useState(false);
  const [generated, setGenerated] = useState(null);
  const [confirm, setConfirm] = useState(null);
  const [busy, setBusy] = useState(false);

  const reload = useCallback(async () => {
    setLoading(true);
    try {
      const res = await usersApi.myPatients();
      setPatients(res.patients || []);
    } catch (e) {
      toast.error(e.message);
    } finally {
      setLoading(false);
    }
  }, [toast]);

  useEffect(() => {
    reload();
  }, [reload]);

  const filtered = useMemo(() => {
    const n = q.trim().toLowerCase();
    if (!n) return patients;
    return patients.filter(
      (p) =>
        String(p.name).toLowerCase().includes(n) ||
        String(p.username).toLowerCase().includes(n),
    );
  }, [patients, q]);

  const resetPw = async () => {
    if (!confirm) return;
    setBusy(true);
    try {
      const res = await usersApi.resetPatientPassword(confirm.patient.id, null);
      setGenerated(res.generatedPassword);
      setConfirm(null);
    } catch (e) {
      toast.error(e.message);
    } finally {
      setBusy(false);
    }
  };

  return (
    <div>
      <PageHeader
        title="مرضاي"
        subtitle={isAdmin ? 'كل المرضى في النظام' : 'المرضى المُسنَدون إليك'}
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
          empty={isAdmin ? 'لا يوجد مرضى بعد' : 'لا يوجد مرضى مُسنَدون إليك بعد'}
          columns={[
            {
              key: 'name',
              header: 'المريض',
              render: (p) => (
                <div>
                  <strong>{p.name}</strong>
                  <div className="mono">{p.username}</div>
                </div>
              ),
            },
            { key: 'currentStatus', header: 'الحالة الحيّة', render: (p) => <StatusBadge status={p.currentStatus} /> },
            { key: 'lastUpdated', header: 'آخر تحديث', render: (p) => formatDateTime(p.lastUpdated) },
            {
              key: 'actions',
              header: '',
              render: (p) => (
                <div className="row-actions">
                  <button className="btn btn--ghost btn--sm" onClick={() => setConfirm({ patient: p })}>
                    كلمة مرور
                  </button>
                </div>
              ),
            },
          ]}
        />
      </div>

      {showCreate && (
        <CreatePatientModal
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
          title="إعادة تعيين كلمة المرور"
          message={`توليد كلمة مرور مؤقتة جديدة للمريض "${confirm.patient.name}"؟`}
          confirmLabel="توليد كلمة مرور"
          busy={busy}
          onConfirm={resetPw}
          onCancel={() => setConfirm(null)}
        />
      )}
      {generated && <GeneratedPasswordModal password={generated} onClose={() => setGenerated(null)} />}
    </div>
  );
}

function CreatePatientModal({ onClose, onCreated }) {
  const toast = useToast();
  const [username, setUsername] = useState('');
  const [name, setName] = useState('');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);

  const submit = async (e) => {
    e?.preventDefault?.();
    if (username.trim().length < 3) return toast.error('اسم المستخدم 3 أحرف على الأقل');
    if (!name.trim()) return toast.error('الاسم مطلوب');
    if (password && password.length < 6) return toast.error('كلمة المرور 6 أحرف على الأقل');
    setBusy(true);
    try {
      const res = await usersApi.createMyPatient({
        username: username.trim(),
        name: name.trim(),
        password: password || null,
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
      <p className="muted" style={{ marginTop: 0 }}>سيظهر المريض ضمن قائمتك مباشرة.</p>
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
