import { useEffect, useState } from 'react';
import { usersApi } from '../api/users.js';
import { useToast } from '../context/ToastContext.jsx';
import PageHeader from '../components/PageHeader.jsx';
import DataTable from '../components/DataTable.jsx';
import { RoleBadge } from '../components/Badge.jsx';
import { formatDateTime } from '../lib/format.js';
import { actionLabel } from './OverviewPage.jsx';

function detailText(d) {
  if (!d || typeof d !== 'object') return '—';
  const keys = Object.keys(d);
  if (!keys.length) return '—';
  if (d.doctorId) return `طبيب: ${d.doctorId}`;
  if (d.username) return `المستخدم: ${d.username}`;
  return keys.map((k) => `${k}: ${d[k]}`).join('، ');
}

export default function AuditPage() {
  const toast = useToast();
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(true);
  const [limit, setLimit] = useState(200);

  useEffect(() => {
    let alive = true;
    setLoading(true);
    usersApi
      .audit(limit)
      .then((res) => alive && setRows(res.audit || []))
      .catch((e) => toast.error(e.message))
      .finally(() => alive && setLoading(false));
    return () => {
      alive = false;
    };
  }, [limit, toast]);

  return (
    <div>
      <PageHeader
        title="سجل النشاط"
        subtitle="كل العمليات الحسّاسة على الحسابات والإسناد"
        actions={
          <select
            className="field__control"
            value={limit}
            onChange={(e) => setLimit(Number(e.target.value))}
          >
            <option value={50}>آخر 50</option>
            <option value={200}>آخر 200</option>
            <option value={1000}>آخر 1000</option>
          </select>
        }
      />
      <div className="card">
        <DataTable
          loading={loading}
          rows={rows}
          empty="لا يوجد نشاط بعد"
          columns={[
            { key: 'at', header: 'الوقت', render: (r) => formatDateTime(r.at) },
            { key: 'actorRole', header: 'المنفّذ', render: (r) => <RoleBadge role={r.actorRole} /> },
            { key: 'action', header: 'الإجراء', render: (r) => actionLabel(r.action) },
            { key: 'target', header: 'العنصر', render: (r) => <span className="mono">{r.target || '—'}</span> },
            { key: 'detail', header: 'تفاصيل', render: (r) => <span className="muted">{detailText(r.detail)}</span> },
          ]}
        />
      </div>
    </div>
  );
}
