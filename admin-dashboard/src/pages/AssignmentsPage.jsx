import { useCallback, useEffect, useMemo, useState } from 'react';
import { usersApi } from '../api/users.js';
import { assignmentsApi } from '../api/assignments.js';
import { useToast } from '../context/ToastContext.jsx';
import PageHeader from '../components/PageHeader.jsx';
import DataTable from '../components/DataTable.jsx';

// The core admin screen: assign ANY patient to ANY doctor. An assignment row is
// exactly what makes a patient visible to a doctor (see users_store visibility
// rule), so adding/removing chips here immediately changes each doctor's view.
export default function AssignmentsPage() {
  const toast = useToast();
  const [patients, setPatients] = useState([]);
  const [doctors, setDoctors] = useState([]);
  const [assignments, setAssignments] = useState([]);
  const [loading, setLoading] = useState(true);
  const [q, setQ] = useState('');
  const [picker, setPicker] = useState({});
  const [busyKey, setBusyKey] = useState('');

  const reload = useCallback(async () => {
    setLoading(true);
    try {
      const [pt, dc, asg] = await Promise.all([
        usersApi.listUsers({ role: 'patient' }),
        usersApi.listUsers({ role: 'doctor' }),
        assignmentsApi.list(),
      ]);
      setPatients(pt.users || []);
      setDoctors(dc.users || []);
      setAssignments(asg.assignments || []);
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

  const byPatient = useMemo(() => {
    const m = {};
    assignments.forEach((a) => {
      (m[a.patientId] ||= []).push(a.doctorId);
    });
    return m;
  }, [assignments]);

  const filtered = useMemo(() => {
    const n = q.trim().toLowerCase();
    if (!n) return patients;
    return patients.filter(
      (p) =>
        String(p.name).toLowerCase().includes(n) ||
        String(p.username).toLowerCase().includes(n),
    );
  }, [patients, q]);

  const assign = async (patientId) => {
    const doctorId = picker[patientId];
    if (!doctorId) return toast.error('اختر طبيباً أولاً');
    setBusyKey(patientId);
    try {
      await assignmentsApi.assign(patientId, doctorId);
      setPicker((p) => ({ ...p, [patientId]: '' }));
      await reload();
      toast.success('تم الإسناد');
    } catch (e) {
      toast.error(e.message);
    } finally {
      setBusyKey('');
    }
  };

  const unassign = async (patientId, doctorId) => {
    setBusyKey(patientId + doctorId);
    try {
      await assignmentsApi.unassign(patientId, doctorId);
      await reload();
      toast.success('تم إلغاء الإسناد');
    } catch (e) {
      toast.error(e.message);
    } finally {
      setBusyKey('');
    }
  };

  return (
    <div>
      <PageHeader
        title="إسناد المرضى للأطباء"
        subtitle="يمكن للمدير إسناد أي مريض لأي طبيب — ويظهر لدى الطبيب فوراً"
      />
      <div className="card">
        <div className="matrix-hint">
          كل مريض يمكن إسناده لأكثر من طبيب. أزِل الإسناد من الشارة (✕)، أو أضِف طبيباً من القائمة.
        </div>
        <div className="toolbar">
          <input
            className="field__control toolbar__search"
            placeholder="بحث عن مريض…"
            value={q}
            onChange={(e) => setQ(e.target.value)}
          />
        </div>
        <DataTable
          loading={loading}
          rows={filtered}
          empty="لا يوجد مرضى"
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
            {
              key: 'doctors',
              header: 'الأطباء المسؤولون',
              render: (p) => {
                const ids = byPatient[p.id] || [];
                if (!ids.length) return <span className="chip chip--empty">غير مُسند</span>;
                return (
                  <div className="chip-list">
                    {ids.map((id) => (
                      <span key={id} className="chip">
                        {doctorsById[id] || id}
                        <button
                          title="إلغاء الإسناد"
                          disabled={busyKey === p.id + id}
                          onClick={() => unassign(p.id, id)}
                        >
                          ✕
                        </button>
                      </span>
                    ))}
                  </div>
                );
              },
            },
            {
              key: 'add',
              header: 'إضافة طبيب',
              render: (p) => {
                const assigned = new Set(byPatient[p.id] || []);
                const avail = doctors.filter((d) => !assigned.has(d.id));
                return (
                  <div className="row-actions">
                    <select
                      className="field__control"
                      style={{ minWidth: 150 }}
                      value={picker[p.id] || ''}
                      onChange={(e) => setPicker((s) => ({ ...s, [p.id]: e.target.value }))}
                    >
                      <option value="">اختر طبيباً…</option>
                      {avail.map((d) => (
                        <option key={d.id} value={d.id}>
                          {d.name}
                        </option>
                      ))}
                    </select>
                    <button
                      className="btn btn--primary btn--sm"
                      disabled={busyKey === p.id || !picker[p.id]}
                      onClick={() => assign(p.id)}
                    >
                      إسناد
                    </button>
                  </div>
                );
              },
            },
          ]}
        />
      </div>
    </div>
  );
}
