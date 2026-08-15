import { useCallback, useEffect, useMemo, useState } from 'react';
import { usersApi } from '../api/users.js';
import { assignmentsApi } from '../api/assignments.js';
import { useToast } from '../context/ToastContext.jsx';
import PageHeader from '../components/PageHeader.jsx';
import DataTable from '../components/DataTable.jsx';
import Modal from '../components/Modal.jsx';
import FormField from '../components/FormField.jsx';
import ConfirmDialog from '../components/ConfirmDialog.jsx';
import GeneratedPasswordModal from '../components/GeneratedPasswordModal.jsx';
import { StateBadge } from '../components/Badge.jsx';
import { formatDateTime } from '../lib/format.js';

const CONFIRM = {
  reset: {
    title: 'إعادة تعيين كلمة المرور',
    label: 'توليد كلمة مرور',
    danger: false,
    msg: (d) => `توليد كلمة مرور مؤقتة جديدة للطبيب "${d.name}"؟`,
  },
  disable: {
    title: 'تعطيل الطبيب',
    label: 'تعطيل',
    danger: true,
    msg: (d) => `سيتعذّر على "${d.name}" تسجيل الدخول حتى إعادة التفعيل. متابعة؟`,
  },
  enable: {
    title: 'تفعيل الطبيب',
    label: 'تفعيل',
    danger: false,
    msg: (d) => `إعادة تفعيل حساب "${d.name}"؟`,
  },
  delete: {
    title: 'حذف الطبيب',
    label: 'حذف نهائي',
    danger: true,
    msg: (d) => `سيُحذف حساب "${d.name}" وكل إسناداته نهائياً. لا يمكن التراجع. متابعة؟`,
  },
};

export default function DoctorsPage() {
  const toast = useToast();
  const [doctors, setDoctors] = useState([]);
  const [pcount, setPcount] = useState({});
  const [loading, setLoading] = useState(true);
  const [q, setQ] = useState('');
  const [showCreate, setShowCreate] = useState(false);
  const [generated, setGenerated] = useState(null);
  const [confirm, setConfirm] = useState(null);
  const [busy, setBusy] = useState(false);

  const reload = useCallback(async () => {
    setLoading(true);
    try {
      const [du, asg] = await Promise.all([
        usersApi.listUsers({ role: 'doctor' }),
        assignmentsApi.list(),
      ]);
      setDoctors(du.users || []);
      const c = {};
      (asg.assignments || []).forEach((a) => {
        c[a.doctorId] = (c[a.doctorId] || 0) + 1;
      });
      setPcount(c);
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
    if (!n) return doctors;
    return doctors.filter(
      (d) =>
        String(d.name).toLowerCase().includes(n) ||
        String(d.username).toLowerCase().includes(n),
    );
  }, [doctors, q]);

  const runConfirm = async () => {
    if (!confirm) return;
    const { type, doctor } = confirm;
    setBusy(true);
    try {
      if (type === 'disable') await usersApi.disableUser(doctor.id);
      else if (type === 'enable') await usersApi.enableUser(doctor.id);
      else if (type === 'delete') await usersApi.deleteUser(doctor.id);
      else if (type === 'reset') {
        const res = await usersApi.resetPassword(doctor.id, null);
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
        title="الأطباء"
        subtitle="إنشاء حسابات الأطباء وإدارتها"
        actions={
          <button className="btn btn--primary" onClick={() => setShowCreate(true)}>
            + طبيب جديد
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
          empty="لا يوجد أطباء بعد"
          columns={[
            { key: 'name', header: 'الاسم', render: (d) => <strong>{d.name}</strong> },
            { key: 'username', header: 'اسم المستخدم', render: (d) => <span className="mono">{d.username}</span> },
            { key: 'patients', header: 'عدد المرضى', render: (d) => pcount[d.id] || 0 },
            { key: 'disabled', header: 'الحالة', render: (d) => <StateBadge disabled={d.disabled} /> },
            { key: 'createdAt', header: 'أُنشئ', render: (d) => formatDateTime(d.createdAt) },
            {
              key: 'actions',
              header: '',
              render: (d) => (
                <div className="row-actions">
                  <button className="btn btn--ghost btn--sm" onClick={() => setConfirm({ type: 'reset', doctor: d })}>
                    كلمة مرور
                  </button>
                  {d.disabled ? (
                    <button className="btn btn--ghost btn--sm" onClick={() => setConfirm({ type: 'enable', doctor: d })}>
                      تفعيل
                    </button>
                  ) : (
                    <button className="btn btn--ghost btn--sm" onClick={() => setConfirm({ type: 'disable', doctor: d })}>
                      تعطيل
                    </button>
                  )}
                  <button className="btn btn--danger btn--sm" onClick={() => setConfirm({ type: 'delete', doctor: d })}>
                    حذف
                  </button>
                </div>
              ),
            },
          ]}
        />
      </div>

      {showCreate && (
        <CreateDoctorModal
          onClose={() => setShowCreate(false)}
          onCreated={(pw) => {
            setShowCreate(false);
            reload();
            if (pw) setGenerated(pw);
            else toast.success('تم إنشاء الطبيب');
          }}
        />
      )}
      {confirm && (
        <ConfirmDialog
          title={CONFIRM[confirm.type].title}
          message={CONFIRM[confirm.type].msg(confirm.doctor)}
          confirmLabel={CONFIRM[confirm.type].label}
          danger={CONFIRM[confirm.type].danger}
          busy={busy}
          onConfirm={runConfirm}
          onCancel={() => setConfirm(null)}
        />
      )}
      {generated && <GeneratedPasswordModal password={generated} onClose={() => setGenerated(null)} />}
    </div>
  );
}

function CreateDoctorModal({ onClose, onCreated }) {
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
      const res = await usersApi.createDoctor({
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
      title="طبيب جديد"
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
