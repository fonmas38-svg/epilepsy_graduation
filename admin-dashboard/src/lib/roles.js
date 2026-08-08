// Role vocabulary + Arabic labels. Mirrors the backend Role literal
// (device|patient|caregiver|doctor|admin). The dashboard only ever manages the
// human roles; `device` is shown read-only if it ever appears.

export const ROLE_LABELS = {
  admin: 'مدير النظام',
  doctor: 'طبيب',
  patient: 'مريض',
  caregiver: 'مقدّم رعاية',
  device: 'جهاز',
};

export const STATUS_LABELS = {
  stable: 'مستقر',
  watch: 'مراقبة',
  high_risk: 'خطر مرتفع',
};

export const STATUS_COLORS = {
  // same palette as the Flutter app's StatusBadge
  stable: '#1B7F4E',
  watch: '#B7791F',
  high_risk: '#B42318',
};

export function roleLabel(role) {
  return ROLE_LABELS[role] || role || '—';
}

export function statusLabel(status) {
  return STATUS_LABELS[status] || (status ? status : 'غير معروف');
}
