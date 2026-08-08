import { useEffect, useState } from 'react';
import { usersApi } from '../api/users.js';
import { useToast } from '../context/ToastContext.jsx';
import PageHeader from '../components/PageHeader.jsx';
import StatCard from '../components/StatCard.jsx';
import DataTable from '../components/DataTable.jsx';
import { formatDateTime } from '../lib/format.js';
import { roleLabel } from '../lib/roles.js';

const ACTION_LABELS = {
  login: 'تسجيل دخول',
  seed_admin: 'تهيئة المدير',
  create_doctor: 'إنشاء طبيب',
  create_patient: 'إنشاء مريض',
  create_admin: 'إنشاء مدير',
  create_caregiver: 'إنشاء مقدّم رعاية',
  update_user: 'تعديل حساب',
  reset_password: 'إعادة تعيين كلمة المرور',
  disable_user: 'تعطيل حساب',
  enable_user: 'تفعيل حساب',
  delete_user: 'حذف حساب',
  assign: 'إسناد مريض',
  unassign: 'إلغاء إسناد',
};

export function actionLabel(a) {
  return ACTION_LABELS[a] || a;
}

export default function OverviewPage() {
  const toast = useToast();
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let alive = true;
    usersApi
      .overview()
      .then((res) => alive && setData(res))
      .catch((e) => toast.error(e.message))
      .finally(() => alive && setLoading(false));
    return () => {
      alive = false;
    };
  }, [toast]);

  const counts = data?.counts;
  const byRole = counts?.byRole || {};

  return (
    <div>
      <PageHeader
        title="نظرة عامة على النظام"
        subtitle="ملخّص الحسابات والإسناد وأحدث النشاطات"
      />

      <div className="stat-grid">
        <StatCard label="إجمالي الحسابات" value={counts?.totalUsers ?? '—'} tone="navy" icon="👥" />
        <StatCard label="الأطباء" value={byRole.doctor ?? 0} tone="green" icon="🩺" />
        <StatCard label="المرضى" value={byRole.patient ?? 0} tone="amber" icon="🧑‍⚕️" />
        <StatCard label="عمليات الإسناد" value={counts?.assignments ?? 0} tone="navy" icon="🔗" />
        <StatCard label="حسابات معطّلة" value={counts?.disabled ?? 0} tone="red" icon="🚫" />
      </div>

      <div className="card">
        <h3 style={{ marginTop: 0 }}>أحدث النشاطات</h3>
        <DataTable
          loading={loading}
          rows={data?.recentAudit || []}
          empty="لا يوجد نشاط بعد"
          columns={[
            { key: 'at', header: 'الوقت', render: (r) => formatDateTime(r.at) },
            { key: 'actorRole', header: 'المنفّذ', render: (r) => roleLabel(r.actorRole) },
            { key: 'action', header: 'الإجراء', render: (r) => actionLabel(r.action) },
            { key: 'target', header: 'العنصر', render: (r) => <span className="mono">{r.target || '—'}</span> },
          ]}
        />
      </div>
    </div>
  );
}
