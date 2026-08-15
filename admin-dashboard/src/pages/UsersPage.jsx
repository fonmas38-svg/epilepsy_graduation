import { useCallback, useEffect, useMemo, useState } from 'react';
import { usersApi } from '../api/users.js';
import { useToast } from '../context/ToastContext.jsx';
import PageHeader from '../components/PageHeader.jsx';
import DataTable from '../components/DataTable.jsx';
import Modal from '../components/Modal.jsx';
import FormField from '../components/FormField.jsx';
import ConfirmDialog from '../components/ConfirmDialog.jsx';
import GeneratedPasswordModal from '../components/GeneratedPasswordModal.jsx';
import { RoleBadge, StateBadge } from '../components/Badge.jsx';
import { ROLE_LABELS } from '../lib/roles.js';
import { formatDateTime } from '../lib/format.js';

const ROLE_FILTERS = [
  { value: '', label: 'كل الأدوار' },
  { value: 'admin', label: ROLE_LABELS.admin },
  { value: 'doctor', label: ROLE_LABELS.doctor },
  { value: 'patient', label: ROLE_LABELS.patient },
  { value: 'caregiver', label: ROLE_LABELS.caregiver },
];

// The catch-all account list: every role in one table, with a general-purpose
// create (admin/doctor/patient/caregiver), inline rename, password reset, and
// enable/disable/delete. The role-specific pages are convenience views on top
// of the same REST surface this page exercises in full.
export default function UsersPage() {
  const toast = useToast();
  const [users, setUsers] = useState([]);
  const [loading, setLoading] = useState(true);
  const [role, setRole] = useState('');
  const [q, setQ] = useState('');
  const [includeDisabled, setIncludeDisabled] = useState(true);
  const [showCreate, setShowCreate] = useState(false);
  const [edit, setEdit] = useState(null);
  const [generated, setGenerated] = useState(null);
  const [confirm, setConfirm] = useState(null);
  const [busy, setBusy] = useState(false);

  const reload = useCallback(async () => {
    setLoading(true);
    try {
      const res = await usersApi.listUsers({ role: role || undefined, include_disabled: includeDisabled });
      setUsers(res.users || []);
    } catch (e) {
      toast.error(e.message);
    } finally {
      setLoading(false);
    }
  }, [role, includeDisabled, toast]);

  useEffect(() => {
    reload();
  }, [reload]);

  const doctors = useMemo(() => users.filter((u) => u.role === 'doctor'), [users]);

  const filtered = useMemo(() => {
    const n = q.trim().toLowerCase();
    if (!n) return users;
    return users.filter(
      (u) =>
        String(u.name).toLowerCase().includes(n) ||
        String(u.username).toLowerCase().includes(n),
    );
  }, [users, q]);

  const runConfirm = async () => {
    if (!confirm) return;
    const { type, user } = confirm;
    setBusy(true);
    try {
      if (type === 'disable') await usersApi.disableUser(user.id);
      else if (type === 'enable') await usersApi.enableUser(user.id);
      else if (type === 'delete') await usersApi.deleteUser(user.id);
      else if (type === 'reset') {
        const res = await usersApi.resetPassword(user.id, null);
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
        title="كل الحسابات"
        subtitle="إدارة موحّدة لكل المستخدمين على اختلاف أدوارهم"
        actions={
          <button className="btn btn--primary" onClick={() => setShowCreate(true)}>
            + حساب جديد
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
          <select className="field__control" value={role} onChange={(e) => setRole(e.target.value)}>
            {ROLE_FILTERS.map((r) => (
              <option key={r.value} value={r.value}>
                {r.label}
              </option>
            ))}
          </select>
          <label className="nowrap" style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
            <input
              type="checkbox"
              checked={includeDisabled}
              onChange={(e) => setIncludeDisabled(e.target.checked)}
            />
            إظهار المعطّلة
          </label>
        </div>
        <DataTable
          loading={loading}
          rows={filtered}
          empty="لا توجد حسابات مطابقة"
          columns={[
            { key: 'name', header: 'الاسم', render: (u) => <strong>{u.name}</strong> },
            { key: 'username', header: 'اسم المستخدم', render: (u) => <span className="mono">{u.username}</span> },
            { key: 'role', header: 'الدور', render: (u) => <RoleBadge role={u.role} /> },
            { key: 'disabled', header: 'الحالة', render: (u) => <StateBadge disabled={u.disabled} /> },
            { key: 'createdAt', header: 'أُنشئ', render: (u) => formatDateTime(u.createdAt) },
            {
              key: 'actions',
              header: '',
              render: (u) => (
                <div className="row-actions">
                  <button className="btn btn--ghost btn--sm" onClick={() => setEdit(u)}>
                    تعديل
                  </button>
                  <button className="btn btn--ghost btn--sm" onClick={() => setConfirm({ type: 'reset', user: u })}>
                    كلمة مرور
                  </button>
                  {u.disabled ? (
                    <button className="btn btn--ghost btn--sm" onClick={() => setConfirm({ type: 'enable', user: u })}>
                      تفعيل
                    </button>
                  ) : (
                    <button className="btn btn--ghost btn--sm" onClick={() => setConfirm({ type: 'disable', user: u })}>
                      تعطيل
                    </button>
                  )}
                  <button className="btn btn--danger btn--sm" onClick={() => setConfirm({ type: 'delete', user: u })}>
                    حذف
                  </button>
                </div>
              ),
            },
          ]}
        />
      </div>

      {showCreate && (
        <CreateUserModal
          doctors={doctors}
          onClose={() => setShowCreate(false)}
          onCreated={(pw) => {
            setShowCreate(false);
            reload();
            if (pw) setGenerated(pw);
            else toast.success('تم إنشاء الحساب');
          }}
        />
      )}
      {edit && (
        <EditUserModal
          user={edit}
          onClose={() => setEdit(null)}
          onSaved={() => {
            setEdit(null);
            reload();
            toast.success('تم حفظ التعديلات');
          }}
        />
      )}
      {confirm && (
        <ConfirmDialog
          title={
            { reset: 'إعادة تعيين كلمة المرور', disable: 'تعطيل الحساب', enable: 'تفعيل الحساب', delete: 'حذف الحساب' }[
              confirm.type
            ]
          }
          message={
            {
              reset: `توليد كلمة مرور مؤقتة جديدة لـ "${confirm.user.name}"؟`,
              disable: `سيتعذّر على "${confirm.user.name}" تسجيل الدخول. متابعة؟`,
              enable: `إعادة تفعيل حساب "${confirm.user.name}"؟`,
              delete: `سيُحذف حساب "${confirm.user.name}" نهائياً. لا يمكن التراجع. متابعة؟`,
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

function CreateUserModal({ doctors, onClose, onCreated }) {
  const toast = useToast();
  const [role, setRole] = useState('patient');
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
      const res = await usersApi.createUser({
        username: username.trim(),
        name: name.trim(),
        role,
        password: password || null,
        doctor_id: role === 'patient' ? doctorId || null : null,
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
      title="حساب جديد"
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
        <FormField
          label="الدور"
          name="role"
          as="select"
          value={role}
          onChange={setRole}
          options={[
            { value: 'patient', label: ROLE_LABELS.patient },
            { value: 'doctor', label: ROLE_LABELS.doctor },
            { value: 'caregiver', label: ROLE_LABELS.caregiver },
            { value: 'admin', label: ROLE_LABELS.admin },
          ]}
        />
        <FormField label="الاسم الكامل" name="name" value={name} onChange={setName} required autoFocus />
        <FormField
          label="اسم المستخدم"
          name="username"
          value={username}
          onChange={setUsername}
          required
          hint="يُستخدم لتسجيل الدخول (3 أحرف على الأقل)"
        />
        {role === 'patient' && (
          <FormField
            label="الطبيب المسؤول"
            name="doctorId"
            as="select"
            value={doctorId}
            onChange={setDoctorId}
            options={[{ value: '', label: 'بدون إسناد' }, ...doctors.map((d) => ({ value: d.id, label: d.name }))]}
            hint="اختياري"
          />
        )}
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

function EditUserModal({ user, onClose, onSaved }) {
  const toast = useToast();
  const [name, setName] = useState(user.name || '');
  const [username, setUsername] = useState(user.username || '');
  const [busy, setBusy] = useState(false);

  const submit = async (e) => {
    e?.preventDefault?.();
    if (username.trim().length < 3) return toast.error('اسم المستخدم 3 أحرف على الأقل');
    if (!name.trim()) return toast.error('الاسم مطلوب');
    setBusy(true);
    try {
      await usersApi.updateUser(user.id, { name: name.trim(), username: username.trim() });
      onSaved();
    } catch (err) {
      toast.error(err.message);
    } finally {
      setBusy(false);
    }
  };

  return (
    <Modal
      title={`تعديل: ${user.name}`}
      onClose={onClose}
      footer={
        <>
          <button className="btn btn--ghost" onClick={onClose} disabled={busy}>
            إلغاء
          </button>
          <button className="btn btn--primary" onClick={submit} disabled={busy}>
            {busy ? '…' : 'حفظ'}
          </button>
        </>
      }
    >
      <form onSubmit={submit}>
        <FormField label="الاسم الكامل" name="name" value={name} onChange={setName} required autoFocus />
        <FormField label="اسم المستخدم" name="username" value={username} onChange={setUsername} required />
        <button type="submit" style={{ display: 'none' }} />
      </form>
    </Modal>
  );
}
