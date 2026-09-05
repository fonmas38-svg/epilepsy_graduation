// Patient <-> doctor assignment REST calls (admin scope).
import { api } from './client.js';

export const assignmentsApi = {
  list: () => api.get('/admin/assignments'),
  assign: (patientId, doctorId) =>
    api.post('/admin/assignments', { patient_id: patientId, doctor_id: doctorId }),
  unassign: (patientId, doctorId) =>
    api.del('/admin/assignments', { patient_id: patientId, doctor_id: doctorId }),
};

export const caregiverLinksApi = {
  list: () => api.get('/admin/caregiver-links'),
  link: (patientId, caregiverId) =>
    api.post('/admin/caregiver-links', { patient_id: patientId, caregiver_id: caregiverId }),
  unlink: (patientId, caregiverId) =>
    api.del('/admin/caregiver-links', { patient_id: patientId, caregiver_id: caregiverId }),
};
