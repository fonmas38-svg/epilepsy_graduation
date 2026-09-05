import { useCallback, useEffect, useMemo, useState } from 'react';
import { usersApi } from '../api/users.js';
import { assignmentsApi, caregiverLinksApi } from '../api/assignments.js';
import { useToast } from '../context/ToastContext.jsx';
import PageHeader from '../components/PageHeader.jsx';
import DataTable from '../components/DataTable.jsx';

export default function AssignmentsPage() {
  const toast = useToast();
  const [tab, setTab] = useState('doctors'); // 'doctors' | 'caregivers'
  const [patients, setPatients] = useState([]);
  const [doctors, setDoctors] = useState([]);
  const [caregivers, setCaregivers] = useState([]);
  const [assignments, setAssignments] = useState([]);
  const [caregiverLinks, setCaregiverLinks] = useState([]);
  const [loading, setLoading] = useState(true);
  const [q, setQ] = useState('');
  const [picker, setPicker] = useState({});
  const [cgPicker, setCgPicker] = useState({});
  const [busyKey, setBusyKey] = useState('');

  const reload = useCallback(async () => {
    setLoading(true);
    try {
      const [pt, dc, cg, asg, cl] = await Promise.all([
        usersApi.listUsers({ role: 'patient' }),
        usersApi.listUsers({ role: 'doctor' }),
        usersApi.listUsers({ role: 'caregiver' }),
        assignmentsApi.list(),
        caregiverLinksApi.list(),
      ]);
      setPatients(pt.users || []);
      setDoctors(dc.users || []);
      setCaregivers(cg.users || []);
      setAssignments(asg.assignments || []);
      setCaregiverLinks(cl.links || []);
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

  const caregiversById = useMemo(
    () => Object.fromEntries(caregivers.map((c) => [c.id, c.name])),
    [caregivers],
  );

  const byPatient = useMemo(() => {
    const m = {};
    assignments.forEach((a) => {
      (m[a.patientId] ||= []).push(a.doctorId);
    });
    return m;
  }, [assignments]);

  const byPatientCaregivers = useMemo(() => {
    const m = {};
    caregiverLinks.forEach((c) => {
      (m[c.patientId] ||= []).push(c.caregiverId);
    });
    return m;
  }, [caregiverLinks]);

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
      toast.success('تم إسناد الطبيب بنجاح');
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
      toast.success('تم إلغاء إسناد الطبيب');
    } catch (e) {
      toast.error(e.message);
    } finally {
      setBusyKey('');
    }
  };

  const linkCaregiver = async (patientId) => {
    const caregiverId = cgPicker[patientId];
    if (!caregiverId) return toast.error('اختر مرافقاً أولاً');
    setBusyKey('cg_' + patientId);
    try {
      await caregiverLinksApi.link(patientId, caregiverId);
      setCgPicker((p) => ({ ...p, [patientId]: '' }));
      await reload();
      toast.success('تم ربط فرد الأسرة / المرافق بالمريض');
    } catch (e) {
      toast.error(e.message);
    } finally {
      setBusyKey('');
    }
  };

  const unlinkCaregiver = async (patientId, caregiverId) => {
    setBusyKey('cg_' + patientId + caregiverId);
    try {
      await caregiverLinksApi.unlink(patientId, caregiverId);
      await reload();
      toast.success('تم فك ربط المرافق عن المريض');
    } catch (e) {
      toast.error(e.message);
    } finally {
      setBusyKey('');
    }
  };

  return (
    <div>
      <PageHeader
        title="إسناد وربط الحسابات"
        subtitle="إدارة إسناد الأطباء وربط أفراد الأسرة والمرافقين بالمرضى"
      />

      <div style={{ display: 'flex', gap: '8px', marginBottom: '16px' }}>
        <button
          className={`btn ${tab === 'doctors' ? 'btn--primary' : 'btn--ghost'}`}
          onClick={() => setTab('doctors')}
        >
          👨‍⚕️ إسناد الأطباء للمرضى ({assignments.length})
        </button>
        <button
          className={`btn ${tab === 'caregivers' ? 'btn--primary' : 'btn--ghost'}`}
          onClick={() => setTab('caregivers')}
        >
          👨‍👩‍👧‍👦 ربط الأسرة والمرافقين ({caregiverLinks.length})
        </button>
      </div>

      <div className="card">
        <div className="matrix-hint">
          {tab === 'doctors'
            ? 'كل مريض يمكن إسناده لطبيب أو أكثر. أزِل الإسناد بالنقر على (✕) في الشارة، أو أضِف طبيباً من القائمة.'
            : 'ربط أفراد الأسرة يسمح للمرافق بالاطلاع على تنبيهات المريض واستقبال موقعه وإرسال الرسائل الفورية.'}
        </div>
        <div className="toolbar">
          <input
            className="field__control toolbar__search"
            placeholder="بحث عن مريض…"
            value={q}
            onChange={(e) => setQ(e.target.value)}
          />
        </div>

        {tab === 'doctors' ? (
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
                header: 'الأطباء المشرفون',
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
                header: 'إسناد لطبيب',
                render: (p) => {
                  const assigned = new Set(byPatient[p.id] || []);
                  const avail = doctors.filter((d) => !assigned.has(d.id));
                  return (
                    <div className="row-actions">
                      <select
                        className="field__control"
                        style={{ minWidth: 160 }}
                        value={picker[p.id] || ''}
                        onChange={(e) => setPicker((s) => ({ ...s, [p.id]: e.target.value }))}
                      >
                        <option value="">اختر طبيباً…</option>
                        {avail.map((d) => (
                          <option key={d.id} value={d.id}>
                            {d.name} ({d.username})
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
        ) : (
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
                key: 'caregivers',
                header: 'أفراد الأسرة / المرافقون المرتبطون',
                render: (p) => {
                  const ids = byPatientCaregivers[p.id] || [];
                  if (!ids.length) return <span className="chip chip--empty">لا يوجد مرافق مرتبط</span>;
                  return (
                    <div className="chip-list">
                      {ids.map((id) => (
                        <span key={id} className="chip" style={{ borderColor: 'rgba(56, 189, 248, 0.4)' }}>
                          {caregiversById[id] || id}
                          <button
                            title="إلغاء الربط"
                            disabled={busyKey === 'cg_' + p.id + id}
                            onClick={() => unlinkCaregiver(p.id, id)}
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
                key: 'addCaregiver',
                header: 'ربط مرافق جديد',
                render: (p) => {
                  const linked = new Set(byPatientCaregivers[p.id] || []);
                  const avail = caregivers.filter((c) => !linked.has(c.id));
                  return (
                    <div className="row-actions">
                      <select
                        className="field__control"
                        style={{ minWidth: 160 }}
                        value={cgPicker[p.id] || ''}
                        onChange={(e) => setCgPicker((s) => ({ ...s, [p.id]: e.target.value }))}
                      >
                        <option value="">اختر مرافقاً…</option>
                        {avail.map((c) => (
                          <option key={c.id} value={c.id}>
                            {c.name} ({c.username})
                          </option>
                        ))}
                      </select>
                      <button
                        className="btn btn--primary btn--sm"
                        disabled={busyKey === 'cg_' + p.id || !cgPicker[p.id]}
                        onClick={() => linkCaregiver(p.id)}
                      >
                        ربط
                      </button>
                    </div>
                  );
                },
              },
            ]}
          />
        )}
      </div>
    </div>
  );
}
