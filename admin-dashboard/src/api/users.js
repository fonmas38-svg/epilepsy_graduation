// User + account administration REST calls (admin + doctor scopes).
import { api } from './client.js';

function qs(params) {
  const entries = Object.entries(params || {}).filter(
    ([, v]) => v !== undefined && v !== null && v !== '',
  );
  if (!entries.length) return '';
  return '?' + entries.map(([k, v]) => `${k}=${encodeURIComponent(v)}`).join('&');
}

export const usersApi = {
  // ---- admin ----
  overview: () => api.get('/admin/overview'),
  listUsers: (params) => api.get('/admin/users' + qs(params)),
  getUser: (id) => api.get(`/admin/users/${id}`),
  createDoctor: (payload) => api.post('/admin/doctors', payload),
  createPatient: (payload) => api.post('/admin/patients', payload),
  createUser: (payload) => api.post('/admin/users', payload),
  updateUser: (id, payload) => api.patch(`/admin/users/${id}`, payload),
  resetPassword: (id, password) =>
    api.post(`/admin/users/${id}/password`, { password: password || null }),
  disableUser: (id) => api.post(`/admin/users/${id}/disable`),
  enableUser: (id) => api.post(`/admin/users/${id}/enable`),
  deleteUser: (id) => api.del(`/admin/users/${id}`),
  audit: (limit = 200) => api.get(`/admin/audit?limit=${limit}`),

  // ---- doctor (also usable by admin) ----
  myPatients: () => api.get('/doctor/patients'),
  createMyPatient: (payload) => api.post('/doctor/patients', payload),
  getPatient: (id) => api.get(`/doctor/patients/${id}`),
  resetPatientPassword: (id, password) =>
    api.post(`/doctor/patients/${id}/password`, { password: password || null }),
};
