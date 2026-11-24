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
  const [phone, setPhone] = useState('');
  const [email, setEmail] = useState('');
  const [licenseNumber, setLicenseNumber] = useState('');
  const [specialization, setSpecialization] = useState('طب وجراحة المخ والأعصاب');
  const [hospitalAffiliation, setHospitalAffiliation] = useState('');
  const [nationalId, setNationalId] = useState('');
  const [mohVerified, setMohVerified] = useState(false);
  const [mohOverride, setMohOverride] = useState(false);
  const [verifyingMoh, setVerifyingMoh] = useState(false);
  const [busy, setBusy] = useState(false);

  const generateUsername = (fullName) => {
    if (!fullName) return '';
    const clean = fullName.replace(/^(د\.?|الدكتور|دكتور)\s+/i, '').trim();
    const parts = clean.split(/\s+/).filter(Boolean);
    if (!parts.length) return '';
    const translit = parts
      .map((p) => p.toLowerCase().replace(/[^a-z0-9]/g, ''))
      .filter(Boolean);
    const base = translit.length ? translit.join('.') : 'dr.' + Math.floor(1000 + Math.random() * 9000);
    return base.startsWith('dr.') ? base : `dr.${base}`;
  };

  const onNameChange = (val) => {
    setName(val);
    if (!username || username.startsWith('dr.')) {
      setUsername(generateUsername(val));
    }
  };

  const handleVerifyMoh = async () => {
    if (!licenseNumber.trim()) return toast.error('يرجى إدخال رقم الترخيص الطبي أولاً');
    setVerifyingMoh(true);
    try {
      const res = await usersApi.verifyDoctorMoh({
        license_number: licenseNumber.trim(),
        national_id: nationalId.trim() || undefined,
        name: name.trim() || undefined,
      });
      if (res.verified) {
        setMohVerified(true);
        toast.success(res.message || 'تم التحقق من ترخيص وزارة الصحة بنجاح');
      } else {
        setMohVerified(false);
        toast.error(res.message || 'فشل التحقق من ترخيص وزارة الصحة');
      }
    } catch (err) {
      setMohVerified(false);
      toast.error(err.message || 'خطأ أثناء التحقق من السجل');
    } finally {
      setVerifyingMoh(false);
    }
  };

  const submit = async (e) => {
    e?.preventDefault?.();
    if (username.trim().length < 3) return toast.error('اسم المستخدم 3 أحرف على الأقل');
    if (!name.trim()) return toast.error('الاسم مطلوب');
    if (![licenseNumber, specialization, hospitalAffiliation, nationalId].every(v => v.trim())) return toast.error('أكمل بيانات الترخيص والتخصص والمستشفى والهوية');
    if (!/^\+?[0-9]{8,15}$/.test(phone.trim())) return toast.error('أدخل رقم هاتف صالحاً');
    if (password && password.length < 6) return toast.error('كلمة المرور 6 أحرف على الأقل');
    setBusy(true);
    try {
      const res = await usersApi.createDoctor({
        username: username.trim(),
        name: name.trim(),
        password: password || null,
        phone: phone.trim() || undefined,
        email: email.trim() || undefined,
        license_number: licenseNumber.trim() || undefined,
        specialization: specialization.trim() || undefined,
        hospital_affiliation: hospitalAffiliation.trim() || undefined,
        national_id: nationalId.trim() || undefined,
        moh_override: mohOverride,
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
            {busy ? '…' : 'إنشاء الحساب'}
          </button>
        </>
      }
    >
      <form onSubmit={submit}>
        <FormField
          label="الاسم الكامل"
          name="name"
          value={name}
          onChange={onNameChange}
          required
          autoFocus
          hint="سيظهر مسبوقاً برمز 'د.' في كامل النظام"
        />
        <FormField
          label="اسم المستخدم"
          name="username"
          value={username}
          onChange={setUsername}
          required
          hint="يُولد تلقائياً بنمط dr.name ويمكن تعديله"
        />
        <FormField
          label="كلمة المرور"
          name="password"
          type="password"
          value={password}
          onChange={setPassword}
          hint="اتركها فارغة لتوليد كلمة مرور مؤقتة تلقائياً"
        />
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '12px' }}>
          <FormField label="رقم الهاتف" name="phone" required value={phone} onChange={setPhone} />
          <FormField label="البريد الإلكتروني (اختياري)" name="email" type="email" value={email} onChange={setEmail} />
        </div>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '12px' }}>
          <FormField
            label="التخصص الطبي"
            name="specialization"
            required
            value={specialization}
            onChange={setSpecialization}
          />
          <FormField
            label="المستشفى / جهة العمل"
            name="hospitalAffiliation"
            required
            value={hospitalAffiliation}
            onChange={setHospitalAffiliation}
          />
        </div>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '12px' }}>
          <FormField
            label="رقم الترخيص الطبي (MOH)"
            name="licenseNumber"
            required
            value={licenseNumber}
            onChange={setLicenseNumber}
          />
          <FormField
            label="الرقم القومي / الهوية"
            name="nationalId"
            required
            value={nationalId}
            onChange={setNationalId}
          />
        </div>

        <div style={{ margin: '14px 0', padding: '12px', background: '#f8fafc', borderRadius: '8px', border: '1px solid #e2e8f0' }}>
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: '8px' }}>
            <div>
              <span style={{ fontSize: '13px', fontWeight: 'bold' }}>التحقق من وزارة الصحة: </span>
              {mohVerified ? (
                <span style={{ color: '#16a34a', fontWeight: 'bold' }}>✓ معتمد وموثق</span>
              ) : (
                <span style={{ color: '#64748b' }}>غير معتمد حالياً</span>
              )}
            </div>
            <button
              type="button"
              className="btn btn--ghost btn--sm"
              onClick={handleVerifyMoh}
              disabled={verifyingMoh || !licenseNumber.trim()}
            >
              {verifyingMoh ? 'جارِ التحقق…' : 'تحقق من السجل'}
            </button>
          </div>
          <div style={{ marginTop: '8px', display: 'flex', alignItems: 'center', gap: '8px' }}>
            <input
              type="checkbox"
              id="mohOverride"
              checked={mohOverride}
              onChange={(e) => setMohOverride(e.target.checked)}
            />
            <label htmlFor="mohOverride" style={{ fontSize: '12px', color: '#475569', cursor: 'pointer' }}>
              تجاوز التحقق الإداري (Administrative MOH Override)
            </label>
          </div>
        </div>

        <button type="submit" style={{ display: 'none' }} />
      </form>
    </Modal>
  );
}
