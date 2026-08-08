// Patient <-> doctor assignment REST calls (admin scope).
import { api } from './client.js';

export const assignmentsApi = {
  list: () => api.get('/admin/assignments'),
  assign: (patientId, doctorId) =>
    api.post('/admin/assignments', { patient_id: patientId, doctor_id: doctorId }),
  unassign: (patientId, doctorId) =>
    api.del('/admin/assignments', { patient_id: patientId, doctor_id: doctorId }),
};
